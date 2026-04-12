FROM elixir:1.19-alpine AS build

RUN apk add --no-cache git

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config/config.exs config/prod.exs config/runtime.exs config/
COPY lib lib
COPY priv priv

RUN mix compile
RUN mix release

# ── Runtime ──────────────────────────────────────────────────────────────────

FROM alpine:3.20

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

COPY --from=build /app/_build/prod/rel/sanity_api ./

RUN mkdir -p /app/uploads

ENV PHX_SERVER=true
ENV PHX_HOST=localhost
ENV PORT=4000
ENV DATABASE_URL=ecto://postgres:postgres@db/sanity_api_prod
ENV SECRET_KEY_BASE=placeholder_will_be_overridden

EXPOSE 4000

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

CMD ["/app/entrypoint.sh"]
