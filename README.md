# gleam-nostr-relay

A [Nostr](https://github.com/nostr-protocol/nostr) relay written in [Gleam](https://gleam.run), running on the BEAM.

- WebSocket server built on [mist](https://hex.pm/packages/mist)
- BIP-340 Schnorr signature verification implemented in pure Gleam (no NIFs)
- PostgreSQL storage via [pog](https://hex.pm/packages/pog)
- Each connection is its own BEAM process; new events are fanned out by a small hub actor and matched against subscriptions in the connection processes

## Supported NIPs

- NIP-01: Basic protocol (including replaceable, ephemeral and addressable events)
- NIP-09: Event deletion
- NIP-11: Relay information document
- NIP-40: Expiration timestamp
- NIP-45: Event counts
- NIP-70: Protected events (rejected, since there is no NIP-42 auth)

## Running

```sh
docker compose up --build
```

The relay listens on port 8080. Configuration is done with environment variables:

| Variable | Default |
| --- | --- |
| `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/nostr` |
| `PORT` | `8080` |
| `WEB_ROOT` | `public` |
| `RELAY_NAME` | `gleam-nostr-relay` |
| `RELAY_DESCRIPTION` | `A Nostr relay implemented in Gleam` |
| `RELAY_PUBKEY` / `RELAY_CONTACT` / `RELAY_ICON` | (unset) |

## Development

```sh
gleam test
gleam run
```

## License

MIT

## Author

Yasuhiro Matsumoto (a.k.a. mattn)
