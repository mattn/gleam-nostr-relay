//// BIP-340 Schnorr signature verification over secp256k1, written in pure
//// Gleam on top of the BEAM's arbitrary precision integers.
////
//// Only verification is needed by a relay, so there is no signing code and
//// no constant-time concerns.

import gleam/bit_array
import gleam/crypto
import gleam/int

/// Field prime.
const p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F

/// Group order.
const n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

const gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798

const gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

/// A point in Jacobian coordinates (X, Y, Z) representing (X/Z^2, Y/Z^3).
type Point {
  Infinity
  Jacobian(x: Int, y: Int, z: Int)
}

/// Verify a BIP-340 signature.
///
/// `pubkey` is the 32-byte x-only public key, `sig` the 64-byte signature and
/// `msg` the message (32 bytes for Nostr event ids, but any length is allowed).
pub fn verify(pubkey: BitArray, msg: BitArray, sig: BitArray) -> Bool {
  case pubkey, sig {
    <<px:big-size(256)>>, <<r:big-size(256), s:big-size(256)>> ->
      case px < p && r < p && s < n {
        False -> False
        True ->
          case lift_x(px) {
            Error(Nil) -> False
            Ok(#(x, y)) -> {
              let e =
                tagged_hash("BIP0340/challenge", <<
                  r:big-size(256),
                  x:big-size(256),
                  msg:bits,
                >>)
                |> to_int
                |> fn(v) { v % n }
              // R = s*G - e*P = s*G + (n - e)*P
              let point =
                double_mul(
                  s,
                  Jacobian(gx, gy, 1),
                  { n - e } % n,
                  Jacobian(x, y, 1),
                )
              case to_affine(point) {
                Error(Nil) -> False
                Ok(#(rx, ry)) -> ry % 2 == 0 && rx == r
              }
            }
          }
      }
    _, _ -> False
  }
}

fn to_int(bits: BitArray) -> Int {
  let assert <<v:big-size(256)>> = bits
  v
}

/// tagged_hash(tag, x) = sha256(sha256(tag) || sha256(tag) || x)
fn tagged_hash(tag: String, data: BitArray) -> BitArray {
  let t = crypto.hash(crypto.Sha256, bit_array.from_string(tag))
  crypto.hash(crypto.Sha256, <<t:bits, t:bits, data:bits>>)
}

/// The point with x coordinate `x` and an even y coordinate.
fn lift_x(x: Int) -> Result(#(Int, Int), Nil) {
  let c = fmod(x * x % p * x + 7)
  let y = pow_mod(c, { p + 1 } / 4, p)
  case y * y % p == c {
    False -> Error(Nil)
    True ->
      case y % 2 == 0 {
        True -> Ok(#(x, y))
        False -> Ok(#(x, p - y))
      }
  }
}

fn fmod(a: Int) -> Int {
  let r = a % p
  case r < 0 {
    True -> r + p
    False -> r
  }
}

fn pow_mod(base: Int, exp: Int, m: Int) -> Int {
  do_pow_mod(base % m, exp, m, 1)
}

fn do_pow_mod(base: Int, exp: Int, m: Int, acc: Int) -> Int {
  case exp {
    0 -> acc
    _ -> {
      let acc = case int.bitwise_and(exp, 1) {
        1 -> acc * base % m
        _ -> acc
      }
      do_pow_mod(base * base % m, int.bitwise_shift_right(exp, 1), m, acc)
    }
  }
}

fn to_affine(pt: Point) -> Result(#(Int, Int), Nil) {
  case pt {
    Infinity -> Error(Nil)
    Jacobian(x, y, z) -> {
      let zinv = pow_mod(z, p - 2, p)
      let zinv2 = zinv * zinv % p
      Ok(#(x * zinv2 % p, y * zinv2 % p * zinv % p))
    }
  }
}

fn double(pt: Point) -> Point {
  case pt {
    Infinity -> Infinity
    Jacobian(_, 0, _) -> Infinity
    Jacobian(x, y, z) -> {
      // dbl-2009-l for a = 0
      let a = x * x % p
      let b = y * y % p
      let c = b * b % p
      let xb = x + b
      let d = fmod(2 * { xb * xb - a - c })
      let e = 3 * a % p
      let f = e * e % p
      let x3 = fmod(f - 2 * d)
      let y3 = fmod(e * { d - x3 } - 8 * c)
      let z3 = 2 * y * z % p
      Jacobian(x3, y3, z3)
    }
  }
}

fn add(p1: Point, p2: Point) -> Point {
  case p1, p2 {
    Infinity, _ -> p2
    _, Infinity -> p1
    Jacobian(x1, y1, z1), Jacobian(x2, y2, z2) -> {
      let z1z1 = z1 * z1 % p
      let z2z2 = z2 * z2 % p
      let u1 = x1 * z2z2 % p
      let u2 = x2 * z1z1 % p
      let s1 = y1 * z2 % p * z2z2 % p
      let s2 = y2 * z1 % p * z1z1 % p
      let h = fmod(u2 - u1)
      let r = fmod(s2 - s1)
      case h, r {
        0, 0 -> double(p1)
        0, _ -> Infinity
        _, _ -> {
          let hh = h * h % p
          let hhh = hh * h % p
          let v = u1 * hh % p
          let x3 = fmod(r * r - hhh - 2 * v)
          let y3 = fmod(r * { v - x3 } - s1 * hhh)
          let z3 = h * z1 % p * z2 % p
          Jacobian(x3, y3, z3)
        }
      }
    }
  }
}

/// Compute a*P + b*Q with Shamir's trick (a single shared doubling chain).
fn double_mul(a: Int, pa: Point, b: Int, pb: Point) -> Point {
  let pab = add(pa, pb)
  do_double_mul(a, pa, b, pb, pab, 255, Infinity)
}

fn do_double_mul(
  a: Int,
  pa: Point,
  b: Int,
  pb: Point,
  pab: Point,
  bit: Int,
  acc: Point,
) -> Point {
  case bit < 0 {
    True -> acc
    False -> {
      let acc = double(acc)
      let ba = int.bitwise_and(int.bitwise_shift_right(a, bit), 1)
      let bb = int.bitwise_and(int.bitwise_shift_right(b, bit), 1)
      let acc = case ba, bb {
        1, 1 -> add(acc, pab)
        1, _ -> add(acc, pa)
        _, 1 -> add(acc, pb)
        _, _ -> acc
      }
      do_double_mul(a, pa, b, pb, pab, bit - 1, acc)
    }
  }
}
