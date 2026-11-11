//// Nostr events (NIP-01).

import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import nostr_relay/json_util
import nostr_relay/schnorr

pub type Event {
  Event(
    id: String,
    pubkey: String,
    created_at: Int,
    kind: Int,
    tags: List(List(String)),
    content: String,
    sig: String,
  )
}

pub type Kind {
  Regular
  Replaceable
  Ephemeral
  Addressable
}

pub fn decoder() -> decode.Decoder(Event) {
  use id <- decode.field("id", decode.string)
  use pubkey <- decode.field("pubkey", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use kind <- decode.field("kind", decode.int)
  use tags <- decode.field("tags", decode.list(decode.list(decode.string)))
  use content <- decode.field("content", decode.string)
  use sig <- decode.field("sig", decode.string)
  decode.success(Event(id:, pubkey:, created_at:, kind:, tags:, content:, sig:))
}

pub fn from_dynamic(data: Dynamic) -> Result(Event, Nil) {
  decode.run(data, decoder()) |> result.replace_error(Nil)
}

pub fn classify(kind: Int) -> Kind {
  case kind {
    0 | 3 -> Replaceable
    _ if kind >= 10_000 && kind < 20_000 -> Replaceable
    _ if kind >= 20_000 && kind < 30_000 -> Ephemeral
    _ if kind >= 30_000 && kind < 40_000 -> Addressable
    _ -> Regular
  }
}

fn tags_json(tags: List(List(String)), escape: fn(String) -> String) -> String {
  "["
  <> string.join(
    list.map(tags, fn(tag) {
      "["
      <> string.join(list.map(tag, fn(s) { "\"" <> escape(s) <> "\"" }), ",")
      <> "]"
    }),
    ",",
  )
  <> "]"
}

/// The NIP-01 serialization whose sha256 is the event id.
pub fn serialize_for_id(ev: Event, mode: json_util.Mode) -> String {
  let escape = json_util.escape(_, mode)
  "[0,\""
  <> ev.pubkey
  <> "\","
  <> int.to_string(ev.created_at)
  <> ","
  <> int.to_string(ev.kind)
  <> ","
  <> tags_json(ev.tags, escape)
  <> ",\""
  <> escape(ev.content)
  <> "\"]"
}

pub fn compute_id(ev: Event, mode: json_util.Mode) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(serialize_for_id(ev, mode)))
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Whether the id matches the event. Strings with unusual control characters
/// are checked against every serialization clients are known to use.
pub fn id_matches(ev: Event) -> Bool {
  compute_id(ev, json_util.Nip01) == ev.id
  || {
    has_ambiguous_strings(ev)
    && {
      compute_id(ev, json_util.Strict) == ev.id
      || compute_id(ev, json_util.Minimal) == ev.id
    }
  }
}

fn has_ambiguous_strings(ev: Event) -> Bool {
  json_util.has_ambiguous_control(ev.content)
  || list.any(ev.tags, list.any(_, json_util.has_ambiguous_control))
}

/// Serialize an event as a JSON object.
pub fn to_json(ev: Event) -> String {
  "{\"id\":\""
  <> ev.id
  <> "\",\"pubkey\":\""
  <> ev.pubkey
  <> "\",\"created_at\":"
  <> int.to_string(ev.created_at)
  <> ",\"kind\":"
  <> int.to_string(ev.kind)
  <> ",\"tags\":"
  <> tags_json(ev.tags, json_util.escape(_, json_util.Strict))
  <> ",\"content\":"
  <> json_util.quote(ev.content)
  <> ",\"sig\":\""
  <> ev.sig
  <> "\"}"
}

pub fn is_lower_hex(s: String, len: Int) -> Bool {
  string.byte_size(s) == len && do_is_lower_hex(bit_array.from_string(s))
}

fn do_is_lower_hex(bits: BitArray) -> Bool {
  case bits {
    <<>> -> True
    <<c, rest:bits>> if c >= 0x30 && c <= 0x39 -> do_is_lower_hex(rest)
    <<c, rest:bits>> if c >= 0x61 && c <= 0x66 -> do_is_lower_hex(rest)
    _ -> False
  }
}

fn decode_hex(s: String) -> BitArray {
  let assert Ok(bits) = bit_array.base16_decode(s)
  bits
}

/// Check the shape of the event, its id and its signature.
/// The error message is suitable for an `OK` response.
pub fn validate(ev: Event) -> Result(Nil, String) {
  use <- check(is_lower_hex(ev.id, 64), "invalid: bad event id format")
  use <- check(is_lower_hex(ev.pubkey, 64), "invalid: bad pubkey format")
  use <- check(is_lower_hex(ev.sig, 128), "invalid: bad signature format")
  use <- check(ev.kind >= 0 && ev.kind <= 65_535, "invalid: kind out of range")
  use <- check(ev.created_at >= 0, "invalid: bad created_at")
  use <- check(id_matches(ev), "invalid: event id does not match")
  use <- check(
    schnorr.verify(decode_hex(ev.pubkey), decode_hex(ev.id), decode_hex(ev.sig)),
    "invalid: signature verification failed",
  )
  Ok(Nil)
}

fn check(cond: Bool, msg: String, next: fn() -> Result(Nil, String)) {
  case cond {
    True -> next()
    False -> Error(msg)
  }
}

/// The first value of the first tag with the given name.
pub fn tag_value(ev: Event, name: String) -> Result(String, Nil) {
  list.find_map(ev.tags, fn(tag) {
    case tag {
      [n, v, ..] if n == name -> Ok(v)
      _ -> Error(Nil)
    }
  })
}

pub fn has_tag(ev: Event, name: String) -> Bool {
  list.any(ev.tags, fn(tag) {
    case tag {
      [n, ..] -> n == name
      _ -> False
    }
  })
}

/// The `d` tag value used to identify addressable events ("" if missing).
pub fn d_tag(ev: Event) -> String {
  tag_value(ev, "d") |> result.unwrap("")
}

/// NIP-40 expiration timestamp.
pub fn expiration(ev: Event) -> Result(Int, Nil) {
  tag_value(ev, "expiration") |> result.try(int.parse)
}

pub fn is_expired(ev: Event, now: Int) -> Bool {
  case expiration(ev) {
    Ok(exp) -> exp <= now
    Error(Nil) -> False
  }
}

/// `name:value` entries for every single-letter tag, used for tag filters.
pub fn tag_index(ev: Event) -> List(String) {
  ev.tags
  |> list.filter_map(fn(tag) {
    case tag {
      [n, v, ..] ->
        case string.byte_size(n) == 1 {
          True -> Ok(n <> ":" <> v)
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> list.unique
}
