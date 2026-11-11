//// Runtime configuration from environment variables and the NIP-11 document.

import envoy
import gleam/int
import gleam/json
import gleam/list
import gleam/result

pub const version = "0.1.0"

pub const supported_nips = [1, 9, 11, 40, 45, 70]

pub const max_message_length = 524_288

pub const max_subscriptions = 20

pub const max_filters = 10

pub const max_limit = 500

pub const default_limit = 500

pub const max_event_tags = 2000

pub const max_content_length = 102_400

/// Events with created_at further in the future than this are rejected.
pub const created_at_upper_limit = 900

pub type Config {
  Config(
    port: Int,
    database_url: String,
    web_root: String,
    name: String,
    description: String,
    pubkey: String,
    contact: String,
    icon: String,
  )
}

pub fn from_env() -> Config {
  let get = fn(name, default) { envoy.get(name) |> result.unwrap(default) }
  Config(
    port: envoy.get("PORT") |> result.try(int.parse) |> result.unwrap(8080),
    database_url: get(
      "DATABASE_URL",
      "postgres://postgres:postgres@localhost:5432/nostr",
    ),
    web_root: get("WEB_ROOT", "public"),
    name: get("RELAY_NAME", "gleam-nostr-relay"),
    description: get("RELAY_DESCRIPTION", "A Nostr relay implemented in Gleam"),
    pubkey: get("RELAY_PUBKEY", ""),
    contact: get("RELAY_CONTACT", ""),
    icon: get("RELAY_ICON", ""),
  )
}

/// NIP-11 relay information document.
pub fn nip11(cfg: Config) -> String {
  let optional =
    [#("pubkey", cfg.pubkey), #("contact", cfg.contact), #("icon", cfg.icon)]
    |> list.filter(fn(kv) { kv.1 != "" })
    |> list.map(fn(kv) { #(kv.0, json.string(kv.1)) })
  json.object(
    list.flatten([
      [
        #("name", json.string(cfg.name)),
        #("description", json.string(cfg.description)),
      ],
      optional,
      [
        #("software", json.string("https://github.com/mattn/gleam-nostr-relay")),
        #("version", json.string(version)),
        #("supported_nips", json.array(supported_nips, json.int)),
        #(
          "limitation",
          json.object([
            #("max_message_length", json.int(max_message_length)),
            #("max_subscriptions", json.int(max_subscriptions)),
            #("max_filters", json.int(max_filters)),
            #("max_limit", json.int(max_limit)),
            #("default_limit", json.int(default_limit)),
            #("max_event_tags", json.int(max_event_tags)),
            #("max_content_length", json.int(max_content_length)),
            #("created_at_upper_limit", json.int(created_at_upper_limit)),
            #("auth_required", json.bool(False)),
            #("payment_required", json.bool(False)),
          ]),
        ),
      ],
    ]),
  )
  |> json.to_string
}
