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
# 1.18.4, so the self-host image is built on the Elixir the suite actually
# exercises (task-729be45412588f07). `elixir:1.19-alpine` was smoke-booted only.
# scripts/toolchain-skew-check.sh reds if this line and those matrices part ways.
#
# GLIBC, NOT MUSL — and this is the BUILD stage on purpose (task-f4cff88ca65aca30).
# api/mix.exs sets `include_erts: true`, so the release SHIPS the ERTS assembled
# here. An ERTS (and the argon2/expty NIFs beside it) linked against musl cannot
# run on a glibc runtime, so the two stages are ONE libc decision: moving only the
# runtime stage would produce an image that cannot start at all. Both move.
#
# WHY (the boot crash this closes): OTP 27's erts sizes the alternate signal stack
# from the COMPILE-TIME macro —
#   erts/emulator/sys/unix/sys_signal_stack.c, sys_sigaltstack():
#       ss.ss_size = SIGSTKSZ;
#       if (sigaltstack(&ss, NULL) < 0)
#           ERTS_INTERNAL_ERROR("Failed to set alternate signal stack");
# musl fixes that macro at 8192 (`bits/signal.h: #define SIGSTKSZ 8192`), while the
# Linux kernel requires a signal stack large enough for the CPU's XSAVE buffer and
# advertises that minimum via AT_MINSIGSTKSZ. On AMX-capable hosts (Intel Xeon
# Platinum 8573C / Emerald Rapids — the ONLY runner CPU that crashed, 3/3, vs 0/7 on
# EPYC 7763 / EPYC 9V74 / Xeon 8370C) the TILEDATA xsave area alone is 8 KB, so the
# kernel minimum exceeds musl's static 8192 and sigaltstack() fails at BEAM boot:
#   sys/unix/sys_signal_stack.c:101:sys_sigaltstack(): Internal error: Failed to set
#   alternate signal stack -> Aborted (core dumped)
# glibc >= 2.34 redefines the SIGSTKSZ macro ITSELF as sysconf(_SC_SIGSTKSZ), which
# is auxv-derived, so the IDENTICAL erts source sizes the stack correctly there.
# bookworm ships glibc 2.36. Upstream OTP has since fixed erts to consult
# sysconf(_SC_MINSIGSTKSZ) (commits 3a9458717644 / fc35c2496cea, "Respect Linux
# kernel's AT_MINSIGSTKSZ ..."), but that lives only on maint/master: NO released
# tag carries it — checked 27.3.4, 27.3.4.3-.6, 28.0, 28.1, 28.1.1, 28.1.2, 28.2,
# 28.2.1, 28.3 — so "bump OTP" was not an available fix. Do not move this back to
# alpine without an OTP release that carries that erts change.
#
# The tag matches cloud/Dockerfile's builder, which has been building this same
# codebase on glibc: same Elixir 1.18.4, same OTP 27 line, same bookworm
# date pin, so the two images share one proven base rather than inventing a second.
FROM hexpm/elixir:1.18.4-erlang-27.3.4.13-debian-bookworm-20260623-slim AS build

# build-essential (gcc/make/libc-dev) is REQUIRED to compile native NIFs —
# argon2_elixir (password hashing) builds a C NIF, so a `git`-only image fails
# `mix deps.compile`. cmake is required by expty's vendored libuv.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends git build-essential cmake \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Kept from the alpine era as a cheap floor, not because bookworm needs it today:
# bookworm's cmake is 3.25, which still accepts `cmake_minimum_required(VERSION 3.x)`
# below 3.5 (expty's vendored libuv declares one). alpine 3.24's cmake 4.x refused
# it outright. Harmless here; keeps the build working if the base ever moves to a
# cmake 4.x distro.
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
#   cloud/priv/secret-scrub.exs      ← Sites.BuildLogScrub, the recorded build log's
#                                      WRITE-boundary scrubber. It is the SAME file
#                                      BarkparkCloud.FailureCopy compiles — one pattern
#                                      set, two apps, because a copied redaction table
#                                      drifts in silence. It sits under cloud/priv/
#                                      rather than at the repo root because the CONTROL
#                                      PLANE's image COPYs cloud/ and nothing above it
#                                      (D841/D842), so cloud/lib cannot read any higher;
#                                      api/ can, and this is that line. No fallback: the
#                                      module refuses to compile without it, so a missing
#                                      COPY fails the build instead of shipping a scrub
#                                      that redacts nothing.
#   VERSION                          ← Barkpark.BuildInfo tier 3, the checked-in
#                                      release marker. `.git` is EXCLUDED from this
#                                      build context (api/Dockerfile.dockerignore),
#                                      so BuildInfo's `git describe` tier CANNOT fire
#                                      here — without this file every compose/tarball
#                                      install reports release "unknown", which
#                                      SelfUpdate.Checker.parse_release/1 refuses,
#                                      permanently killing the update check on the one
#                                      install shape it exists for, and renders
#                                      "Barkpark vunknown · unknown" in the Studio nav
#                                      (task-2ab4f5f0a07e887a). BuildInfo's @repo_root
#                                      resolves to `/` inside the release (it sits at
#                                      /app/lib/barkpark/), hence the `/VERSION` target.
COPY VERSION /VERSION
COPY design /design
COPY tooling/pds /tooling/pds
COPY cloud/priv/secret-scrub.exs /cloud/priv/secret-scrub.exs
COPY api/assets assets

# ── Build identity overrides (Barkpark.BuildInfo tiers 1 and the commit/date
# hatches) ───────────────────────────────────────────────────────────────────
# Placed AFTER `mix deps.compile` on purpose: an ENV change invalidates every
# later layer, and the commit sha changes on every build. Ahead of the deps
# layer these three would re-fetch and re-compile the whole dependency tree on
# each commit.
#
# EMPTY IS THE CORRECT DEFAULT and is NOT the docker-compose `${FOO:-}` trap:
# BuildInfo's env reader treats "" exactly as unset, so an unpassed arg falls
# through to the COPYed VERSION file above rather than pinning anything. A
# release pipeline that knows better passes them:
#
#   docker build -f api/Dockerfile \
#     --build-arg BARKPARK_BUILD_VERSION="$(git describe --tags --match 'v[0-9]*')" \
#     --build-arg BARKPARK_BUILD_COMMIT="$(git rev-parse --short HEAD)" \
#     --build-arg BARKPARK_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -t barkpark-api .
#
# BARKPARK_BUILD_VERSION accepts A.B.C or A.B.C.D; only the first three
# segments ever reach the update check.
# ARG ONLY — NEVER `ENV BARKPARK_BUILD_VERSION=${BARKPARK_BUILD_VERSION}`.
# Docker already exposes a build ARG to every later RUN as an environment
# variable, so `mix compile` sees these without an ENV line, and the ENV form is
# actively wrong twice over: it would bake the value into the RUNTIME image, and
# scripts/env-census.py's "Dockerfile ENV SHADOW" check reds on exactly that
# (measured: the ENV form took `compose-smoke.sh census` from its pre-existing
# 2-miss FAIL to a 3-shadow FAIL as well).
ARG BARKPARK_BUILD_VERSION=""
ARG BARKPARK_BUILD_COMMIT=""
ARG BARKPARK_BUILD_DATE=""

COPY api/lib lib
COPY api/priv priv

# Every compile-time asset the modules above read from OUTSIDE api/ must be in the
# build context BEFORE `mix compile`, or the module compiles against nothing and
# says so nowhere. Fail the image here, by name, instead. Add a line per asset
# when a new @external_resource points outside api/.
# #15234 (the register) is on main, so the promised line is here: the pre-gate
# register is now asserted by name, exactly as the 2026-09-02 note said it would be.
RUN set -e; for f in \
      /VERSION \
      /design/status-manifest.json \
      /cloud/priv/secret-scrub.exs \
      /tooling/pds/pre-gate-papers.json; do \
      [ -f "$f" ] || { echo "compile-time asset missing from the build context: $f (add its COPY above)"; exit 1; }; \
    done

RUN mix compile
RUN mix release

# ── Runtime ──────────────────────────────────────────────────────────────────

# MUST match the build stage's distro RELEASE, not merely its libc family: the
# crypto NIF compiled there links the build OpenSSL, so a runtime on an older
# Debian (e.g. bullseye) fails at boot the same way the alpine-3.20 runtime once
# did with "EVP_PKEY_sign_message_init: symbol not found". Same codename, same
# date pin, both bookworm — the two stages are ONE decision. See the build stage
# for why this family is glibc and not musl (task-f4cff88ca65aca30).
FROM debian:bookworm-20260623-slim

# Mirrors what the alpine runtime installed, name-for-name, plus the two things
# alpine gave for free and debian-slim does not:
#   libstdc++6   <- libstdc++      (the BEAM and several NIFs link it)
#   openssl      <- openssl        (crypto NIF)
#   libncurses6  <- ncurses-libs   (erlexec / the release's console)
#   ca-certificates  — alpine's minirootfs carries ca-certificates-bundle as a musl
#                      dependency, so the trust store was implicitly present; on
#                      debian-slim it is NOT, and every outbound TLS call (webhooks,
#                      revalidation) would fail with an unknown CA without it.
#   wget         — docker-compose.yml's api healthcheck is
#                    ["CMD-SHELL", "wget -q -O /dev/null http://localhost:4000/api/schemas || exit 1"]
#                  and scripts/compose-smoke.sh's green arm runs the same binary via
#                  `compose exec -T api wget`. busybox supplied it on alpine; debian-slim
#                  ships no wget and no curl, so WITHOUT this line the container boots
#                  fine and then reports health=unhealthy forever. GNU wget accepts the
#                  same `-q -O /dev/null <url>` and exits non-zero on an HTTP error
#                  status, which is exactly what both callers assert.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 ca-certificates wget \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# LOCALE — a REGRESSION GUARD, not decoration. musl has no locale support and
# treats filenames as UTF-8 unconditionally, so on the alpine runtime the BEAM
# reported `file:native_name_encoding() = utf8` with no locale configured at all
# (MEASURED: `docker run elixir:1.18.4-otp-27-alpine erl -eval file:native_name_encoding()`
# -> utf8). glibc derives it from the locale, and with none set the C locale gives
# LATIN1 — Elixir prints "the VM is running with native name encoding of latin1
# which may cause Elixir to malfunction as it expects utf8" and non-ASCII paths
# (uploads, Paper slugs) break. Moving to glibc without this line would have
# traded a boot crash for a silent encoding change.
#
# C.UTF-8 is built into Debian's glibc 2.36, so this needs NO `locales` package and
# no locale-gen (cloud/Dockerfile predates that and generates en_US.UTF-8 instead).
# MEASURED on this image: LANG alone still yields latin1 — LC_ALL is the one erts
# reads — so both are set and LC_ALL is the load-bearing half.
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

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
