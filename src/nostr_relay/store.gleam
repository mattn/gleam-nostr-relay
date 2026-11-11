//// PostgreSQL event storage.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import nostr_relay/event.{type Event}
import nostr_relay/filter.{type Filter}
import pog

pub type SaveResult {
  Saved
  Duplicate
  /// A newer version of a replaceable/addressable event is already stored.
  HaveNewer
  /// The event was deleted by its author (NIP-09).
  AlreadyDeleted
}

pub fn connect(database_url: String) -> Result(pog.Connection, String) {
  use config <- result.try(
    pog.url_config(process.new_name("nostr_relay_db"), database_url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  // pog does not percent-decode the userinfo part of the URL.
  let config =
    pog.Config(
      ..config,
      user: percent_decode(config.user),
      password: option.map(config.password, percent_decode),
      pool_size: 10,
    )
  pog.start(config)
  |> result.map(fn(started) { started.data })
  |> result.replace_error("failed to start database pool")
}

fn percent_decode(s: String) -> String {
  uri.percent_decode(s) |> result.unwrap(s)
}

const schema = [
  "CREATE TABLE IF NOT EXISTS event (
    id text PRIMARY KEY,
    pubkey text NOT NULL,
    created_at bigint NOT NULL,
    kind integer NOT NULL,
    tagvalues text[] NOT NULL,
    d_tag text,
    expiration bigint,
    raw text NOT NULL
  )",
  "CREATE INDEX IF NOT EXISTS event_pubkey_idx ON event (pubkey)",
  "CREATE INDEX IF NOT EXISTS event_created_at_idx ON event (created_at DESC)",
  "CREATE INDEX IF NOT EXISTS event_kind_idx ON event (kind)",
  "CREATE INDEX IF NOT EXISTS event_replace_idx ON event (pubkey, kind, d_tag)",
  "CREATE INDEX IF NOT EXISTS event_tagvalues_idx ON event USING gin (tagvalues)",
  "CREATE INDEX IF NOT EXISTS event_expiration_idx ON event (expiration) WHERE expiration IS NOT NULL",
]

pub fn migrate(db: pog.Connection) -> Result(Nil, pog.QueryError) {
  list.try_each(schema, fn(sql) {
    pog.query(sql) |> pog.execute(db) |> result.replace(Nil)
  })
}

/// Store an event, handling replaceable/addressable semantics and NIP-09
/// deletions. Ephemeral events must not be passed here.
pub fn save(db: pog.Connection, ev: Event) -> Result(SaveResult, String) {
  let d_tag = case event.classify(ev.kind) {
    event.Addressable -> Some(event.d_tag(ev))
    _ -> None
  }
  pog.transaction(db, fn(tx) {
    use deleted <- result.try(is_deleted(tx, ev))
    case deleted {
      True -> Ok(AlreadyDeleted)
      False ->
        case event.classify(ev.kind) {
          event.Replaceable | event.Addressable -> replace(tx, ev, d_tag)
          _ -> insert(tx, ev, d_tag)
        }
    }
  })
  |> result.map_error(fn(err) {
    case err {
      pog.TransactionRolledBack(e) -> describe(e)
      pog.TransactionQueryError(e) -> describe(e)
    }
  })
}

fn describe(err: pog.QueryError) -> String {
  "error: database error: " <> string.inspect(err)
}

fn is_deleted(tx: pog.Connection, ev: Event) -> Result(Bool, pog.QueryError) {
  pog.query(
    "SELECT count(*) FROM event WHERE kind = 5 AND pubkey = $1 AND tagvalues && $2",
  )
  |> pog.parameter(pog.text(ev.pubkey))
  |> pog.parameter(pog.array(pog.text, ["e:" <> ev.id]))
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(tx)
  |> result.map(fn(r) { r.rows != [0] })
}

fn insert(
  tx: pog.Connection,
  ev: Event,
  d_tag: Option(String),
) -> Result(SaveResult, pog.QueryError) {
  pog.query(
    "INSERT INTO event (id, pubkey, created_at, kind, tagvalues, d_tag, expiration, raw)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (id) DO NOTHING",
  )
  |> pog.parameter(pog.text(ev.id))
  |> pog.parameter(pog.text(ev.pubkey))
  |> pog.parameter(pog.int(ev.created_at))
  |> pog.parameter(pog.int(ev.kind))
  |> pog.parameter(pog.array(pog.text, event.tag_index(ev)))
  |> pog.parameter(pog.nullable(pog.text, d_tag))
  |> pog.parameter(pog.nullable(
    pog.int,
    option.from_result(event.expiration(ev)),
  ))
  |> pog.parameter(pog.text(event.to_json(ev)))
  |> pog.execute(tx)
  |> result.map(fn(r) {
    case r.count {
      0 -> Duplicate
      _ -> Saved
    }
  })
}

fn replace(
  tx: pog.Connection,
  ev: Event,
  d_tag: Option(String),
) -> Result(SaveResult, pog.QueryError) {
  let d = option.unwrap(d_tag, "")
  // Serialize writers of the same replaceable slot.
  use _ <- result.try(
    pog.query(
      "SELECT count(*) FROM (SELECT pg_advisory_xact_lock(hashtext($1))) s",
    )
    |> pog.parameter(pog.text(
      ev.pubkey <> ":" <> int.to_string(ev.kind) <> ":" <> d,
    ))
    |> pog.execute(tx),
  )
  use newer <- result.try(
    pog.query(
      "SELECT count(*) FROM event
       WHERE pubkey = $1 AND kind = $2 AND coalesce(d_tag, '') = $3
         AND (created_at > $4 OR (created_at = $4 AND id <= $5))",
    )
    |> pog.parameter(pog.text(ev.pubkey))
    |> pog.parameter(pog.int(ev.kind))
    |> pog.parameter(pog.text(d))
    |> pog.parameter(pog.int(ev.created_at))
    |> pog.parameter(pog.text(ev.id))
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(tx),
  )
  case newer.rows {
    [0] -> {
      use _ <- result.try(
        pog.query(
          "DELETE FROM event
           WHERE pubkey = $1 AND kind = $2 AND coalesce(d_tag, '') = $3",
        )
        |> pog.parameter(pog.text(ev.pubkey))
        |> pog.parameter(pog.int(ev.kind))
        |> pog.parameter(pog.text(d))
        |> pog.execute(tx),
      )
      insert(tx, ev, d_tag)
    }
    _ -> Ok(HaveNewer)
  }
}

/// Apply a NIP-09 deletion request: remove the referenced events that were
/// published by the same author.
pub fn apply_deletion(db: pog.Connection, ev: Event) -> Result(Nil, String) {
  let ids =
    list.filter_map(ev.tags, fn(tag) {
      case tag {
        ["e", id, ..] -> Ok(id)
        _ -> Error(Nil)
      }
    })
  let addrs =
    list.filter_map(ev.tags, fn(tag) {
      case tag {
        ["a", addr, ..] ->
          case string.split(addr, ":") {
            [kind, pubkey, ..rest] ->
              case int.parse(kind), pubkey == ev.pubkey {
                Ok(k), True -> Ok(#(k, string.join(rest, ":")))
                _, _ -> Error(Nil)
              }
            _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  use _ <- result.try(case ids {
    [] -> Ok(Nil)
    _ ->
      pog.query(
        "DELETE FROM event WHERE pubkey = $1 AND kind <> 5 AND id = ANY($2)",
      )
      |> pog.parameter(pog.text(ev.pubkey))
      |> pog.parameter(pog.array(pog.text, ids))
      |> pog.execute(db)
      |> result.replace(Nil)
      |> result.map_error(describe)
  })
  list.try_each(addrs, fn(addr) {
    let #(kind, d) = addr
    pog.query(
      "DELETE FROM event
       WHERE pubkey = $1 AND kind = $2 AND coalesce(d_tag, '') = $3
         AND created_at <= $4",
    )
    |> pog.parameter(pog.text(ev.pubkey))
    |> pog.parameter(pog.int(kind))
    |> pog.parameter(pog.text(d))
    |> pog.parameter(pog.int(ev.created_at))
    |> pog.execute(db)
    |> result.replace(Nil)
    |> result.map_error(describe)
  })
}

type Where {
  Where(clauses: List(String), params: List(pog.Value), next: Int)
}

fn add(w: Where, clause: fn(String) -> String, value: pog.Value) -> Where {
  Where(
    clauses: [clause("$" <> int.to_string(w.next)), ..w.clauses],
    params: [value, ..w.params],
    next: w.next + 1,
  )
}

fn add_list(
  w: Where,
  values: Option(List(a)),
  clause: fn(String) -> String,
  to_value: fn(a) -> pog.Value,
) -> Where {
  case values {
    None -> w
    Some([]) -> Where(..w, clauses: ["FALSE", ..w.clauses])
    Some(vs) -> add(w, clause, pog.array(to_value, vs))
  }
}

fn where(f: Filter, now: Int, w: Where) -> Where {
  let w =
    add(
      w,
      fn(n) { "(expiration IS NULL OR expiration > " <> n <> ")" },
      pog.int(now),
    )
  let w = add_list(w, f.ids, fn(n) { "id = ANY(" <> n <> ")" }, pog.text)
  let w =
    add_list(w, f.authors, fn(n) { "pubkey = ANY(" <> n <> ")" }, pog.text)
  let w = add_list(w, f.kinds, fn(n) { "kind = ANY(" <> n <> ")" }, pog.int)
  let w = case f.since {
    Some(s) -> add(w, fn(n) { "created_at >= " <> n }, pog.int(s))
    None -> w
  }
  let w = case f.until {
    Some(u) -> add(w, fn(n) { "created_at <= " <> n }, pog.int(u))
    None -> w
  }
  list.fold(f.tags, w, fn(w, tag) {
    let #(name, values) = tag
    add_list(
      w,
      Some(list.map(values, fn(v) { name <> ":" <> v })),
      fn(n) { "tagvalues && " <> n },
      pog.text,
    )
  })
}

fn sql_where(w: Where) -> String {
  w.clauses |> list.reverse |> string.join(" AND ")
}

fn with_params(q: pog.Query(t), w: Where) -> pog.Query(t) {
  w.params |> list.reverse |> list.fold(q, pog.parameter)
}

/// Stored events matching the filter as raw JSON, newest first.
pub fn query(
  db: pog.Connection,
  f: Filter,
  now: Int,
  limit: Int,
) -> Result(List(String), String) {
  let w = where(f, now, Where([], [], 1))
  pog.query(
    "SELECT raw FROM event WHERE "
    <> sql_where(w)
    <> " ORDER BY created_at DESC, id ASC LIMIT $"
    <> int.to_string(w.next),
  )
  |> with_params(w)
  |> pog.parameter(pog.int(limit))
  |> pog.returning(decode.at([0], decode.string))
  |> pog.execute(db)
  |> result.map(fn(r) { r.rows })
  |> result.map_error(describe)
}

/// Number of stored events matching any of the filters (NIP-45).
pub fn count(
  db: pog.Connection,
  filters: List(Filter),
  now: Int,
) -> Result(Int, String) {
  let #(w, parts) =
    list.fold(filters, #(Where([], [], 1), []), fn(acc, f) {
      let #(w, parts) = acc
      let fw = where(f, now, Where([], w.params, w.next))
      #(fw, ["(" <> sql_where(fw) <> ")", ..parts])
    })
  pog.query(
    "SELECT count(*) FROM event WHERE "
    <> string.join(list.reverse(parts), " OR "),
  )
  |> with_params(w)
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(db)
  |> result.map(fn(r) { list.first(r.rows) |> result.unwrap(0) })
  |> result.map_error(describe)
}

/// Remove events whose NIP-40 expiration has passed.
pub fn delete_expired(db: pog.Connection, now: Int) -> Result(Int, String) {
  pog.query(
    "DELETE FROM event WHERE expiration IS NOT NULL AND expiration <= $1",
  )
  |> pog.parameter(pog.int(now))
  |> pog.execute(db)
  |> result.map(fn(r) { r.count })
  |> result.map_error(describe)
}
