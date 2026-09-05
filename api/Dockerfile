# Build context is the REPO ROOT (not api/): the release needs `design/` and
# `api/assets/` at COMPILE time, both of which live outside api/. Build with:
#
#   docker build -f api/Dockerfile -t barkpark-api .
#
# `api/Dockerfile.dockerignore` is the BuildKit per-Dockerfile ignore file and
# takes precedence over the root `.dockerignore` (which excludes api/ wholesale
# for the web image).
# PINNED to the TESTED toolchain, not a floating minor: `.tool-versions` says
# elixir 1.18.4-otp-27 and elixir.yml's mix-test / mix-prod-compile matrices run
# 1.18.4, so the self-host image is now built on the Elixir the suite actually
# exercises (task-729be45412588f07). `elixir:1.19-alpine` was smoke-booted only.
# scripts/toolchain-skew-check.sh reds if this line and those matrices part ways.
FROM elixir:1.18.4-otp-27-alpine AS build

# build-base (gcc/make/musl-dev) is REQUIRED to compile native NIFs — argon2_elixir
# (password hashing) builds a C NIF, so a `git`-only image fails `mix deps.compile`.
# cmake is required by expty's vendored libuv.
RUN apk add --no-cache git build-base cmake

# alpine 3.24 ships cmake 4.x, which refuses projects declaring
# `cmake_minimum_required(VERSION 3.x)` below 3.5 — expty's vendored libuv does.
# This floor keeps that build compatible.
ENV CMAKE_POLICY_VERSION_MINIMUM=3.5

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY api/mix.exs api/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY api/config/config.exs api/config/prod.exs api/config/runtime.exs config/

# Compile-time reads that live OUTSIDE api/:
#   design/status-manifest.json      ← Render.StatusVocab (resolves to /design at runtime path depth)
#   api/assets/**                    ← Render.Stylesheet (File.read! + @external_resource)
#   tooling/pds/pre-gate-papers.json ← the pre-gate Paper register (#15234), read at
#                                      compile by @external_resource (#15331). Without
#                                      this COPY the module compiles with an EMPTY
#                                      register and the pre-gate badge is silently
#                                      off on every Docker-built instance while a full
#                                      checkout (prod) works — task-527b… sibling class.
COPY design /design
COPY tooling/pds /tooling/pds
COPY api/assets assets

COPY api/lib lib
COPY api/priv priv

# Every compile-time asset the modules above read from OUTSIDE api/ must be in the
# build context BEFORE `mix compile`, or the module compiles against nothing and
# says so nowhere. Fail the image here, by name, instead. Add a line per asset
# when a new @external_resource points outside api/.
# NOTE: /tooling/pds/pre-gate-papers.json joins this list the moment #15234
# (the register) is on main — until then an assertion on it would red every
# image build for a file nobody has merged yet (lead-papers, 2026-09-02).
RUN set -e; for f in \
      /design/status-manifest.json; do \
      [ -f "$f" ] || { echo "compile-time asset missing from the build context: $f (add its COPY above)"; exit 1; }; \
    done

RUN mix compile
RUN mix release

# ── Runtime ──────────────────────────────────────────────────────────────────

# MUST match the build stage's alpine: the crypto NIF compiled there links the
# build OpenSSL, so an older runtime alpine (e.g. 3.20) fails at boot with
# "EVP_PKEY_sign_message_init: symbol not found".
#
# MEASURED, not assumed (task-729be45412588f07, `docker run` on linux/arm64):
#
#   elixir:1.18.4-otp-27-alpine  alpine 3.24.1  openssl-3.5.8-r0  Elixir 1.18.4/OTP 27
#   elixir:1.19-alpine           alpine 3.23.5  openssl-3.5.8-r0  Elixir 1.19.5/OTP 28
#   alpine:3.24                  alpine 3.24.1  openssl-3.5.8-r0
#
# So pinning the build stage down to the suite-tested Elixir moved its alpine UP
# a minor, and this line moved with it. Read the table before touching either:
# the two stages are one decision, and the build tag is what picks the alpine.
FROM alpine:3.24

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

COPY --from=build /app/_build/prod/rel/barkpark ./

RUN mkdir -p /app/uploads

# NOTHING that prod's runtime.exs REQUIRES may be baked here: a placeholder
# SECRET_KEY_BASE / DATABASE_URL / PHX_HOST shadows the boot-time raise, so the
# container starts and then 500s at the first request instead of refusing with
# a readable message. Only genuinely image-level facts stay.
ENV PHX_SERVER=true
ENV PORT=4000

EXPOSE 4000

COPY api/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

CMD ["/app/entrypoint.sh"]
