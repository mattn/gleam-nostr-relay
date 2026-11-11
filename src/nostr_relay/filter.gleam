//// Subscription filters (NIP-01).

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nostr_relay/event.{type Event}

pub type Filter {
  Filter(
    ids: Option(List(String)),
    authors: Option(List(String)),
    kinds: Option(List(Int)),
    /// Tag name (single letter) to accepted values.
    tags: List(#(String, List(String))),
    since: Option(Int),
    until: Option(Int),
    limit: Option(Int),
  )
}

pub fn empty() -> Filter {
  Filter(
    ids: None,
    authors: None,
    kinds: None,
    tags: [],
    since: None,
    until: None,
    limit: None,
  )
}

pub fn from_dynamic(data: Dynamic) -> Result(Filter, String) {
  use fields <- result.try(
    decode.run(data, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error("filter must be an object"),
  )
  dict.to_list(fields)
  |> list.try_fold(empty(), fn(f, entry) {
    let #(key, value) = entry
    case key {
      "ids" ->
        strings(value, key) |> result.map(fn(v) { Filter(..f, ids: Some(v)) })
      "authors" ->
        strings(value, key)
        |> result.map(fn(v) { Filter(..f, authors: Some(v)) })
      "kinds" ->
        decode.run(value, decode.list(decode.int))
        |> result.replace_error("kinds must be an array of integers")
        |> result.map(fn(v) { Filter(..f, kinds: Some(v)) })
      "since" ->
        integer(value, key) |> result.map(fn(v) { Filter(..f, since: Some(v)) })
      "until" ->
        integer(value, key) |> result.map(fn(v) { Filter(..f, until: Some(v)) })
      "limit" ->
        integer(value, key) |> result.map(fn(v) { Filter(..f, limit: Some(v)) })
      "#" <> name ->
        case string.byte_size(name) == 1 {
          True ->
            strings(value, key)
            |> result.map(fn(v) { Filter(..f, tags: [#(name, v), ..f.tags]) })
          // Only single-letter tags are indexed; ignore the rest.
          False -> Ok(f)
        }
      _ -> Ok(f)
    }
  })
}

fn strings(value: Dynamic, key: String) -> Result(List(String), String) {
  decode.run(value, decode.list(decode.string))
  |> result.replace_error(key <> " must be an array of strings")
}

fn integer(value: Dynamic, key: String) -> Result(Int, String) {
  decode.run(value, decode.int)
  |> result.replace_error(key <> " must be an integer")
}

/// Whether an event matches the filter (`limit` is ignored).
pub fn matches(f: Filter, ev: Event) -> Bool {
  contains(f.ids, ev.id)
  && contains(f.authors, ev.pubkey)
  && contains(f.kinds, ev.kind)
  && option.map(f.since, fn(s) { ev.created_at >= s }) |> option.unwrap(True)
  && option.map(f.until, fn(u) { ev.created_at <= u }) |> option.unwrap(True)
  && list.all(f.tags, fn(t) {
    let #(name, values) = t
    list.any(ev.tags, fn(tag) {
      case tag {
        [n, v, ..] -> n == name && list.contains(values, v)
        _ -> False
      }
    })
  })
}

fn contains(values: Option(List(a)), x: a) -> Bool {
  case values {
    None -> True
    Some(vs) -> list.contains(vs, x)
  }
}

pub fn matches_any(filters: List(Filter), ev: Event) -> Bool {
  list.any(filters, matches(_, ev))
}
