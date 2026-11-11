import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/string
import gleeunit
import nostr_relay/event.{type Event, Event}
import nostr_relay/filter
import nostr_relay/json_util

pub fn main() -> Nil {
  gleeunit.main()
}

const event_with_escapes =
  "{\"kind\":1,\"id\":\"fb1888e17a1e8a11e7bd30ca2696736f69b004900e1b8e186b67f0687f74f916\",\"pubkey\":\"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9\",\"created_at\":1700000000,\"tags\":[[\"e\",\"aaaa\"],[\"p\",\"bbbb\"],[\"t\",\"gleam\"]],\"content\":\"hi \\\"there\\\"\\\\\\n\\ttab\\u0008\\u000c\\r\u{65E5}\u{672C}\u{8A9E} \\u0001 end\",\"sig\":\"f1a8c9d5e1afcde99f206a5ebee3f3600b95a3a8d0a8c86c2290d99b481bd77ff755a801669273bbee45a6d6f13827e221cfb29122b9a641f0ad83cdb3f2d646\"}"

const event_plain =
  "{\"kind\":1,\"id\":\"8e39f6f58eaa259d9139c9af21822f9e214e0d3315a996d3271724a04f64bbb6\",\"pubkey\":\"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9\",\"created_at\":1700000000,\"tags\":[],\"content\":\"plain\\nline\",\"sig\":\"25a7a983cfc38abe86c85aaf2c849c395c9d98dfe16b83114c2b8d43dfed86aca95d42ef84666ac051a7027ceeb7c7aa62b36f29ef8b4581a0c9806dee9b5c31\"}"

fn parse(s: String) -> Event {
  let assert Ok(ev) = json.parse(s, event.decoder())
  ev
}

pub fn validate_event_with_escapes_test() {
  let ev = parse(event_with_escapes)
  // nak (current go-nostr) leaves \b, \f and \u{1} unescaped.
  assert event.compute_id(ev, json_util.Minimal) == ev.id
  assert event.compute_id(ev, json_util.Nip01) != ev.id
  assert event.validate(ev) == Ok(Nil)
}

pub fn validate_plain_event_test() {
  assert event.validate(parse(event_plain)) == Ok(Nil)
}

pub fn tampered_content_test() {
  let ev = parse(event_plain)
  assert event.validate(Event(..ev, content: "tampered"))
    == Error("invalid: event id does not match")
}

pub fn tampered_signature_test() {
  let ev = parse(event_plain)
  let sig = string.drop_end(ev.sig, 2) <> "00"
  assert event.validate(Event(..ev, sig:))
    == Error("invalid: signature verification failed")
}

pub fn uppercase_id_rejected_test() {
  let ev = parse(event_plain)
  assert event.validate(Event(..ev, id: string.uppercase(ev.id)))
    == Error("invalid: bad event id format")
}

pub fn to_json_roundtrip_test() {
  let ev = parse(event_with_escapes)
  assert json.parse(event.to_json(ev), event.decoder()) == Ok(ev)
}

pub fn escape_modes_test() {
  let s = "a\"b\\c\nd\te\u{8}f\u{1}"
  assert json_util.escape(s, json_util.Nip01) == "a\\\"b\\\\c\\nd\\te\\bf\u{1}"
  assert json_util.escape(s, json_util.Strict)
    == "a\\\"b\\\\c\\nd\\te\\bf\\u0001"
  assert json_util.escape(s, json_util.Minimal)
    == "a\\\"b\\\\c\\nd\\te\u{8}f\u{1}"
  assert json_util.escape("日本語", json_util.Strict) == "日本語"
}

pub fn classify_test() {
  assert event.classify(0) == event.Replaceable
  assert event.classify(1) == event.Regular
  assert event.classify(3) == event.Replaceable
  assert event.classify(10_002) == event.Replaceable
  assert event.classify(20_001) == event.Ephemeral
  assert event.classify(30_023) == event.Addressable
  assert event.classify(40_000) == event.Regular
}

pub fn tag_index_test() {
  let ev = parse(event_with_escapes)
  assert event.tag_index(ev) == ["e:aaaa", "p:bbbb", "t:gleam"]
}

fn filter_of(s: String) -> filter.Filter {
  let assert Ok(d) = json.parse(s, decode.dynamic)
  let assert Ok(f) = filter.from_dynamic(d)
  f
}

pub fn filter_decode_test() {
  let f =
    filter_of(
      "{\"kinds\":[1],\"#t\":[\"gleam\"],\"limit\":5,\"#long\":[\"x\"]}",
    )
  assert f.kinds == Some([1])
  assert f.limit == Some(5)
  assert f.tags == [#("t", ["gleam"])]
  let assert Ok(d) = json.parse("{\"kinds\":[\"x\"]}", decode.dynamic)
  assert filter.from_dynamic(d) == Error("kinds must be an array of integers")
}

pub fn filter_match_test() {
  let ev = parse(event_with_escapes)
  assert filter.matches(filter_of("{}"), ev)
  assert filter.matches(filter_of("{\"kinds\":[1,2],\"#e\":[\"aaaa\"]}"), ev)
  assert filter.matches(
    filter_of("{\"authors\":[\"" <> ev.pubkey <> "\"]}"),
    ev,
  )
  assert !filter.matches(filter_of("{\"kinds\":[2]}"), ev)
  assert !filter.matches(filter_of("{\"#e\":[\"bbbb\"]}"), ev)
  assert !filter.matches(filter_of("{\"ids\":[]}"), ev)
  assert filter.matches(
    filter_of("{\"since\":1700000000,\"until\":1700000000}"),
    ev,
  )
  assert !filter.matches(filter_of("{\"since\":1700000001}"), ev)
}

pub fn expiration_test() {
  let ev = Event(..parse(event_plain), tags: [["expiration", "100"]])
  assert event.is_expired(ev, 100)
  assert !event.is_expired(ev, 99)
}
