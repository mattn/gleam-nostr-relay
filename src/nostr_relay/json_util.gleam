//// JSON string helpers.
////
//// NIP-01 defines an exact serialization for computing event ids, so we do
//// not rely on a general purpose JSON encoder for strings.

import gleam/bit_array
import gleam/list
import gleam/string

/// How control characters are escaped.
///
/// Clients disagree on the serialization used for event ids when strings
/// contain control characters other than `\n`, `\r` and `\t`, so the relay
/// accepts any of these.
pub type Mode {
  /// NIP-01 as written: `\b` and `\f` are escaped, other control characters
  /// are written as-is.
  Nip01
  /// `JSON.stringify` (nostr-tools) and older go-nostr: `\b`, `\f`, and
  /// `\u00XX` for other control characters. Always valid JSON.
  Strict
  /// Current go-nostr: only `"`, `\`, `\n`, `\r` and `\t` are escaped.
  Minimal
}

pub fn escape(s: String, mode: Mode) -> String {
  let bits = bit_array.from_string(s)
  case needs_escape(bits, mode) {
    False -> s
    True -> {
      let assert Ok(out) =
        do_escape(bits, mode, [])
        |> list.reverse
        |> bit_array.concat
        |> bit_array.to_string
      out
    }
  }
}

/// Quote and escape a string for JSON output.
pub fn quote(s: String) -> String {
  "\"" <> escape(s, Strict) <> "\""
}

/// Whether the string contains control characters on which the escaping
/// modes disagree.
pub fn has_ambiguous_control(s: String) -> Bool {
  do_has_control(bit_array.from_string(s))
}

fn do_has_control(bits: BitArray) -> Bool {
  case bits {
    <<>> -> False
    <<b, _:bits>> if b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D -> True
    <<_, rest:bits>> -> do_has_control(rest)
    _ -> False
  }
}

fn needs_escape(bits: BitArray, mode: Mode) -> Bool {
  case bits {
    <<>> -> False
    <<b, rest:bits>> ->
      case escape_byte(b, mode) {
        Ok(_) -> True
        Error(Nil) -> needs_escape(rest, mode)
      }
    _ -> False
  }
}

fn escape_byte(b: Int, mode: Mode) -> Result(BitArray, Nil) {
  case b, mode {
    0x22, _ -> Ok(<<"\\\"":utf8>>)
    0x5C, _ -> Ok(<<"\\\\":utf8>>)
    0x0A, _ -> Ok(<<"\\n":utf8>>)
    0x0D, _ -> Ok(<<"\\r":utf8>>)
    0x09, _ -> Ok(<<"\\t":utf8>>)
    0x08, Nip01 | 0x08, Strict -> Ok(<<"\\b":utf8>>)
    0x0C, Nip01 | 0x0C, Strict -> Ok(<<"\\f":utf8>>)
    _, Strict if b < 0x20 ->
      Ok(<<"\\u00":utf8, hex_digit(b / 16), hex_digit(b % 16)>>)
    _, _ -> Error(Nil)
  }
}

fn do_escape(
  bits: BitArray,
  mode: Mode,
  acc: List(BitArray),
) -> List(BitArray) {
  case bits {
    <<>> -> acc
    <<b, rest:bits>> -> {
      let piece = case escape_byte(b, mode) {
        Ok(seq) -> seq
        Error(Nil) -> <<b>>
      }
      do_escape(rest, mode, [piece, ..acc])
    }
    _ -> acc
  }
}

fn hex_digit(n: Int) -> Int {
  case n < 10 {
    True -> 0x30 + n
    False -> 0x61 + n - 10
  }
}

/// Encode a list of strings as a JSON array.
pub fn string_array(items: List(String)) -> String {
  "[" <> string.join(list.map(items, quote), ",") <> "]"
}
