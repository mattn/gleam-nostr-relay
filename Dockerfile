FROM ghcr.io/gleam-lang/gleam:v1.19.2-erlang-alpine AS build

WORKDIR /app
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY src src
RUN gleam export erlang-shipment

FROM erlang:29-alpine

LABEL org.opencontainers.image.source=https://github.com/mattn/gleam-nostr-relay \
      org.opencontainers.image.description="A Nostr relay implemented in Gleam" \
      org.opencontainers.image.licenses=MIT

RUN addgroup -S relay && adduser -S -G relay relay
COPY --from=build /app/build/erlang-shipment /app
COPY public /app/public

USER relay
WORKDIR /app
ENV PORT=8080 \
    WEB_ROOT=/app/public
EXPOSE 8080

# Set DATABASE_URL (postgres://user:pass@host:port/db).
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
