//// WebSocket protocol handling (NIP-01, NIP-09, NIP-40, NIP-45, NIP-70).

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/set
import gleam/string
import gleam/time/timestamp
import mist
import nostr_relay/config
import nostr_relay/event.{type Event}
import nostr_relay/filter.{type Filter}
import nostr_relay/hub
import nostr_relay/json_util
import nostr_relay/store
import pog

pub type Context {
  Context(db: pog.Connection, hub: Subject(hub.Message))
}

pub type State {
  State(inbox: Subject(Event), subs: Dict(String, List(Filter)))
}

pub fn now() -> Int {
  let #(s, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  s
}

pub fn on_init(
  ctx: Context,
) -> #(State, option.Option(process.Selector(Event))) {
  let inbox = process.new_subject()
  process.send(ctx.hub, hub.Register(inbox))
  let selector = process.new_selector() |> process.select(inbox)
  #(State(inbox:, subs: dict.new()), Some(selector))
}

pub fn on_close(ctx: Context, state: State) -> Nil {
  process.send(ctx.hub, hub.Unregister(state.inbox))
}

pub fn handle(
  ctx: Context,
  state: State,
  msg: mist.WebsocketMessage(Event),
  conn: mist.WebsocketConnection,
) -> mist.Next(State, Event) {
  case msg {
    mist.Text(text) -> mist.continue(handle_text(ctx, state, text, conn))
    mist.Binary(_) -> {
      send(conn, notice("error: binary messages are not supported"))
      mist.continue(state)
    }
    mist.Custom(ev) -> {
      deliver(state, ev, conn)
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn send(conn: mist.WebsocketConnection, text: String) -> Nil {
  let _ = mist.send_text_frame(conn, text)
  Nil
}

fn notice(msg: String) -> String {
  "[\"NOTICE\"," <> json_util.quote(msg) <> "]"
}

fn ok(id: String, accepted: Bool, msg: String) -> String {
  "[\"OK\","
  <> json_util.quote(id)
  <> ","
  <> json.to_string(json.bool(accepted))
  <> ","
  <> json_util.quote(msg)
  <> "]"
}

fn closed(sub_id: String, msg: String) -> String {
  "[\"CLOSED\","
  <> json_util.quote(sub_id)
  <> ","
  <> json_util.quote(msg)
  <> "]"
}

fn event_msg(sub_id: String, raw: String) -> String {
  "[\"EVENT\"," <> json_util.quote(sub_id) <> "," <> raw <> "]"
}

fn deliver(state: State, ev: Event, conn: mist.WebsocketConnection) -> Nil {
  case event.is_expired(ev, now()) {
    True -> Nil
    False -> {
      let raw = event.to_json(ev)
      dict.each(state.subs, fn(sub_id, filters) {
        case filter.matches_any(filters, ev) {
          True -> send(conn, event_msg(sub_id, raw))
          False -> Nil
        }
      })
    }
  }
}

fn handle_text(
  ctx: Context,
  state: State,
  text: String,
  conn: mist.WebsocketConnection,
) -> State {
  case string.byte_size(text) > config.max_message_length {
    True -> {
      send(conn, notice("error: message too large"))
      state
    }
    False ->
      case json.parse(text, decode.list(decode.dynamic)) {
        Error(_) -> {
          send(conn, notice("error: invalid message, expected a JSON array"))
          state
        }
        Ok([cmd, ..args]) ->
          case decode.run(cmd, decode.string), args {
            Ok("EVENT"), [ev] -> {
              handle_event(ctx, ev, conn)
              state
            }
            Ok("REQ"), [sub_id, ..filters] ->
              with_sub_id(sub_id, conn, state, fn(sub_id) {
                handle_req(ctx, state, sub_id, filters, conn)
              })
            Ok("COUNT"), [sub_id, ..filters] ->
              with_sub_id(sub_id, conn, state, fn(sub_id) {
                handle_count(ctx, sub_id, filters, conn)
                state
              })
            Ok("CLOSE"), [sub_id] ->
              with_sub_id(sub_id, conn, state, fn(sub_id) {
                State(..state, subs: dict.delete(state.subs, sub_id))
              })
            Ok(other), _ -> {
              send(
                conn,
                notice("error: unknown or malformed command: " <> other),
              )
              state
            }
            Error(_), _ -> {
              send(conn, notice("error: invalid command"))
              state
            }
          }
        Ok([]) -> {
          send(conn, notice("error: empty message"))
          state
        }
      }
  }
}

fn with_sub_id(
  value: Dynamic,
  conn: mist.WebsocketConnection,
  state: State,
  next: fn(String) -> State,
) -> State {
  case decode.run(value, decode.string) {
    Ok(id) ->
      case id != "" && string.byte_size(id) <= 64 {
        True -> next(id)
        False -> {
          send(conn, closed(id, "error: invalid subscription id"))
          state
        }
      }
    Error(_) -> {
      send(conn, notice("error: subscription id must be a string"))
      state
    }
  }
}

fn parse_filters(filters: List(Dynamic)) -> Result(List(Filter), String) {
  case filters {
    [] -> Error("error: at least one filter is required")
    _ ->
      case list.length(filters) > config.max_filters {
        True -> Error("error: too many filters")
        False ->
          list.try_map(filters, filter.from_dynamic)
          |> result.map_error(fn(e) { "error: " <> e })
      }
  }
}

fn handle_req(
  ctx: Context,
  state: State,
  sub_id: String,
  raw_filters: List(Dynamic),
  conn: mist.WebsocketConnection,
) -> State {
  let too_many =
    !dict.has_key(state.subs, sub_id)
    && dict.size(state.subs) >= config.max_subscriptions
  case parse_filters(raw_filters), too_many {
    Error(msg), _ -> {
      send(conn, closed(sub_id, msg))
      State(..state, subs: dict.delete(state.subs, sub_id))
    }
    Ok(_), True -> {
      send(conn, closed(sub_id, "error: too many subscriptions"))
      state
    }
    Ok(filters), False -> {
      let ts = now()
      let result =
        list.try_fold(filters, set.new(), fn(seen, f) {
          let limit =
            option.unwrap(f.limit, config.default_limit)
            |> int.clamp(0, config.max_limit)
          case limit {
            0 -> Ok(seen)
            _ -> {
              use rows <- result.map(store.query(ctx.db, f, ts, limit))
              list.fold(rows, seen, fn(seen, raw) {
                case set.contains(seen, raw) {
                  True -> seen
                  False -> {
                    send(conn, event_msg(sub_id, raw))
                    set.insert(seen, raw)
                  }
                }
              })
            }
          }
        })
      case result {
        Ok(_) -> {
          send(conn, "[\"EOSE\"," <> json_util.quote(sub_id) <> "]")
          State(..state, subs: dict.insert(state.subs, sub_id, filters))
        }
        Error(msg) -> {
          send(conn, closed(sub_id, msg))
          State(..state, subs: dict.delete(state.subs, sub_id))
        }
      }
    }
  }
}

fn handle_count(
  ctx: Context,
  sub_id: String,
  raw_filters: List(Dynamic),
  conn: mist.WebsocketConnection,
) -> Nil {
  case parse_filters(raw_filters) |> result.try(store.count(ctx.db, _, now())) {
    Ok(n) ->
      send(
        conn,
        "[\"COUNT\","
          <> json_util.quote(sub_id)
          <> ",{\"count\":"
          <> int.to_string(n)
          <> "}]",
      )
    Error(msg) -> send(conn, closed(sub_id, msg))
  }
}

fn handle_event(
  ctx: Context,
  data: Dynamic,
  conn: mist.WebsocketConnection,
) -> Nil {
  case event.from_dynamic(data) {
    Error(Nil) -> {
      let id =
        decode.run(data, decode.at(["id"], decode.string)) |> result.unwrap("")
      send(conn, ok(id, False, "invalid: malformed event"))
    }
    Ok(ev) ->
      case accept(ctx, ev) {
        Ok(msg) -> send(conn, ok(ev.id, True, msg))
        Error(msg) -> send(conn, ok(ev.id, False, msg))
      }
  }
}

fn accept(ctx: Context, ev: Event) -> Result(String, String) {
  let ts = now()
  use <- guard(
    list.length(ev.tags) > config.max_event_tags,
    "invalid: too many tags",
  )
  use <- guard(
    string.byte_size(ev.content) > config.max_content_length,
    "invalid: content too long",
  )
  use <- guard(
    ev.created_at > ts + config.created_at_upper_limit,
    "invalid: created_at is too far in the future",
  )
  use _ <- result.try(event.validate(ev))
  use <- guard(event.is_expired(ev, ts), "invalid: event has expired")
  // NIP-70: without NIP-42 auth we cannot tell who is publishing.
  use <- guard(
    event.has_tag(ev, "-"),
    "auth-required: protected events are not accepted by this relay",
  )
  case event.classify(ev.kind) {
    event.Ephemeral -> {
      process.send(ctx.hub, hub.Broadcast(ev))
      Ok("")
    }
    _ -> {
      use saved <- result.try(store.save(ctx.db, ev))
      case saved {
        store.Saved -> {
          use _ <- result.try(case ev.kind {
            5 -> store.apply_deletion(ctx.db, ev)
            _ -> Ok(Nil)
          })
          process.send(ctx.hub, hub.Broadcast(ev))
          Ok("")
        }
        store.Duplicate -> Ok("duplicate: already have this event")
        store.HaveNewer -> Error("duplicate: have a newer event")
        store.AlreadyDeleted ->
          Error("blocked: event was deleted by its author")
      }
    }
  }
}

fn guard(cond: Bool, msg: String, next: fn() -> Result(String, String)) {
  case cond {
    True -> Error(msg)
    False -> next()
  }
}
