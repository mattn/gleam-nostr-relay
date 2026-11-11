import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import logging
import mist.{type Connection, type ResponseData}
import nostr_relay/config.{type Config}
import nostr_relay/hub
import nostr_relay/relay.{type Context, Context}
import nostr_relay/store

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)
  let cfg = config.from_env()

  let assert Ok(db) = store.connect(cfg.database_url)
  migrate(db, 30)
  let assert Ok(hub) = hub.start()
  let ctx = Context(db:, hub:)

  process.spawn(fn() { expire_loop(ctx) })

  let assert Ok(_) =
    mist.new(fn(req) { handle_request(cfg, ctx, req) })
    |> mist.bind("0.0.0.0")
    |> mist.port(cfg.port)
    |> mist.start

  logging.log(
    logging.Info,
    "gleam-nostr-relay listening on port " <> int.to_string(cfg.port),
  )
  process.sleep_forever()
}

/// The database may come up after the relay, so retry for a while.
fn migrate(db, attempts: Int) -> Nil {
  case store.migrate(db) {
    Ok(Nil) -> Nil
    Error(e) if attempts > 1 -> {
      logging.log(
        logging.Warning,
        "migration failed, retrying: " <> string.inspect(e),
      )
      process.sleep(2000)
      migrate(db, attempts - 1)
    }
    Error(e) -> panic as { "migration failed: " <> string.inspect(e) }
  }
}

fn expire_loop(ctx: Context) -> Nil {
  process.sleep(3_600_000)
  case store.delete_expired(ctx.db, relay.now()) {
    Ok(n) if n > 0 ->
      logging.log(
        logging.Info,
        "deleted " <> int.to_string(n) <> " expired events",
      )
    Ok(_) -> Nil
    Error(e) -> logging.log(logging.Warning, e)
  }
  expire_loop(ctx)
}

fn header_contains(req: Request(a), name: String, value: String) -> Bool {
  request.get_header(req, name)
  |> result.map(fn(v) { string.contains(string.lowercase(v), value) })
  |> result.unwrap(False)
}

fn handle_request(
  cfg: Config,
  ctx: Context,
  req: Request(Connection),
) -> Response(ResponseData) {
  case
    header_contains(req, "upgrade", "websocket"),
    header_contains(req, "accept", "application/nostr+json")
  {
    True, _ ->
      mist.websocket(
        request: without_deflate(req),
        on_init: fn(_conn) { relay.on_init(ctx) },
        on_close: relay.on_close(ctx, _),
        handler: fn(state, msg, conn) { relay.handle(ctx, state, msg, conn) },
      )
    False, True -> nip11(cfg, req)
    False, False -> static(cfg, req)
  }
}

/// Do not negotiate permessage-deflate: gramps (used by mist) inflates each
/// frame on its own, so compressed messages split into continuation frames
/// (as sent by go-nostr/nak) arrive corrupted and are silently dropped.
fn without_deflate(req: Request(Connection)) -> Request(Connection) {
  request.Request(
    ..req,
    headers: list.filter(req.headers, fn(h) {
      string.lowercase(h.0) != "sec-websocket-extensions"
    }),
  )
}

fn nip11(cfg: Config, req: Request(Connection)) -> Response(ResponseData) {
  let resp =
    response.new(200)
    |> response.set_header("access-control-allow-origin", "*")
    |> response.set_header("access-control-allow-headers", "*")
    |> response.set_header("access-control-allow-methods", "GET, OPTIONS")
  case req.method {
    http.Options -> resp |> response.set_body(mist.Bytes(bytes_tree.new()))
    _ ->
      resp
      |> response.set_header("content-type", "application/nostr+json")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(config.nip11(cfg))),
      )
  }
}

fn static(cfg: Config, req: Request(Connection)) -> Response(ResponseData) {
  let file = case req.path {
    "/" -> Ok("index.html")
    "/" <> name ->
      case string.contains(name, "..") || string.contains(name, "/") {
        True -> Error(Nil)
        False -> Ok(name)
      }
    _ -> Error(Nil)
  }
  let body =
    result.try(file, fn(name) {
      mist.send_file(cfg.web_root <> "/" <> name, offset: 0, limit: None)
      |> result.map(fn(body) { #(body, content_type(name)) })
      |> result.replace_error(Nil)
    })
  case body {
    Ok(#(body, content_type)) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(body)
    Error(Nil) ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found")))
  }
}

fn content_type(name: String) -> String {
  case string.split(name, ".") |> list.last {
    Ok("html") -> "text/html; charset=utf-8"
    Ok("js") -> "text/javascript; charset=utf-8"
    Ok("css") -> "text/css; charset=utf-8"
    Ok("svg") -> "image/svg+xml"
    Ok("png") -> "image/png"
    Ok("ico") -> "image/x-icon"
    _ -> "application/octet-stream"
  }
}
