FROM elixir:1.19-alpine AS build

# build-base (gcc/make/musl-dev) is REQUIRED to compile native NIFs — argon2_elixir
# (password hashing) builds a C NIF, so a `git`-only image fails `mix deps.compile`.
RUN apk add --no-cache git build-base

WORKDIR /app

ENV MIX_ENV=prod

# Optional: skip the libvips-backed image dep (vix). Default unset → built (prod
# parity). Staging can pass `--build-arg BARKPARK_SKIP_IMAGE=1` to avoid the
# musl/libvips precompiled-NIF mismatch on alpine; media renditions then fall
# back to the ImageMagick CLI backend.
ARG BARKPARK_SKIP_IMAGE
ENV BARKPARK_SKIP_IMAGE=${BARKPARK_SKIP_IMAGE}

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config/config.exs config/prod.exs config/runtime.exs config/
COPY lib lib
COPY priv priv

RUN mix compile
RUN mix release

# ── Runtime ──────────────────────────────────────────────────────────────────

# MUST match the build stage's alpine (elixir:1.19-alpine = 3.23): the crypto
# NIF compiled there links the build OpenSSL, so an older runtime alpine
# (e.g. 3.20) fails at boot with "EVP_PKEY_sign_message_init: symbol not found".
FROM alpine:3.23

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

COPY --from=build /app/_build/prod/rel/barkpark ./

RUN mkdir -p /app/uploads

ENV PHX_SERVER=true
ENV PHX_HOST=localhost
ENV PORT=4000
ENV DATABASE_URL=ecto://postgres:postgres@db/barkpark_prod
ENV SECRET_KEY_BASE=placeholder_will_be_overridden

EXPOSE 4000

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

CMD ["/app/entrypoint.sh"]
