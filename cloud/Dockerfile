# Barkpark Cloud control plane — multi-stage build.
#
# Stage 1 assembles a self-contained OTP release with MIX_ENV=prod. No DB is
# touched at build time (runtime.exs reads DATABASE_URL et al. at boot), and NO
# secrets are baked — every value arrives via the runtime environment.
#
# Stage 2 is a slim Debian runtime that carries only the release + the shared
# libs the BEAM needs. The base image's Debian codename MUST match the builder's
# (both bookworm) so the OpenSSL/libstdc++ ABI lines up.
#
# Single platform on purpose (YAGNI — no multi-arch buildx). To target ARM64
# (e.g. a Hetzner CAX box) instead of x86, build with
# `docker build --platform linux/arm64 .` — both base tags are multi-arch
# manifests, so the same Dockerfile resolves the right arch with no edits.

# ── Stage 1: build the release ────────────────────────────────────────────────
# Pinned: Elixir 1.18.4 on OTP 27.3.4, Debian bookworm. The -slim variant keeps
# the builder lean; we add the toolchain (build-essential, git) explicitly.
FROM hexpm/elixir:1.18.4-erlang-27.3.4.13-debian-bookworm-20260623-slim AS build

# git: some hex/rebar deps fetch from git refs. build-essential: native NIFs
# (bcrypt_elixir compiles C). Cleaned in the same layer to keep the stage small.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Deps first, as their own layer — re-fetched only when mix.exs/mix.lock change.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# App config + source. runtime.exs is copied too: it is read at BOOT, not build.
COPY config config
COPY lib lib
COPY priv priv

RUN mix compile

# Pre-compressed siblings for the served static set. Re-measured off this tree
# (gzip -9, not the wave-11 figures — app.js/app.css/index.html have been
# rewritten since): index.html 33,912 -> 8,869, app.js 1,429,808 -> 451,848,
# app.css 341,573 -> 107,320, styleguide.html 52,722 -> 12,097. index.html is
# the SPA shell and therefore the FIRST request of every cold boot: compressing
# the assets it pulls while shipping the shell itself uncompressed would leave
# 25,043 bytes on the critical path. The router's
# `at: "/"` Plug.Static carries `gzip: true`, which serves `<file>.gz` when the
# request says `accept-encoding: gzip`; the edge in front of us compresses
# nothing (measured: live responses have no `content-encoding` and no `vary`),
# so without this the console ships the full 1.19 MB on every cold boot.
#
# WHY HERE, AND WHY THERE IS NO STALENESS GUARD ANYWHERE. A .gz that drifts
# from its source is a silent lie: Plug.Static's etag comes from the file it
# SERVES, so a stale sibling and a fresh source answer the same URL with
# different bytes and different etags in the same second, and `no-cache` does
# not help (revalidation is answered 304 off the stale etag). There is no sound
# runtime check for this — so the shape removes the possibility instead of
# detecting it. This RUN reads exactly the bytes `COPY priv priv` just laid
# down, in the same build; Docker keys this layer on the one above it, so any
# change to app.js/app.css invalidates COPY priv and re-runs this. Source and
# sibling therefore cannot disagree. Keep it that way: do not move this before
# `COPY priv priv`, and do not commit the .gz (cloud/.gitignore ignores `*.gz`,
# and scripts/cloud-static-gz-guard.sh reds if one is ever tracked).
#
# It sits AFTER `mix compile` on purpose, to keep the compile layer cache-warm
# when only the SPA bundle changes. `mix release` still picks the siblings up:
# mix symlinks _build/prod/lib/barkpark_cloud/priv at the source `priv`, so
# files created in priv after compile are inside the release tree.
#
# The files are named EXPLICITLY. `gzip priv/static/*` would also compress
# __app.test.mjs, __css_check.mjs and __fixtures__/ — none of which are in the
# Plug.Static `only:` allowlist, so those .gz files would be pure image weight.
# `-k` keeps the originals (identity requests still need them); `-9` is the
# build-time-cost-is-free setting. styleguide.html joined the line under
# cch-cloud-static-gzip-html: it is in the same allowlist and the same
# `gzip: true` plug serves its sibling the moment one exists, 52,722 -> 12,097
# (−77.1%). It is deliberately NOT justified by the cold boot — a developer
# opening the styleguide is the only request that pays — so it was landed on
# its own row rather than smuggled in under the shell's urgency.
# scripts/cloud-static-gz-guard.sh's GZ_ASSETS is the list this line must
# satisfy; the two move in the same commit or the guard reds.
RUN gzip -9 -k priv/static/index.html priv/static/styleguide.html priv/static/app.js priv/static/app.css

RUN mix release

# ── Stage 2: slim runtime ─────────────────────────────────────────────────────
# Same Debian codename (bookworm) as the builder so the BEAM's dynamically
# linked libs (openssl, libstdc++, ncurses) match. -slim variant, date-pinned
# for reproducibility within the bookworm line.
FROM debian:bookworm-20260623-slim AS runtime

# Runtime shared libs the BEAM links against; ca-certificates for any outbound
# TLS (e.g. the Stripe gateway once a human wires a real HTTP client).
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# The BEAM wants a UTF-8 locale.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Run as an unprivileged user, not root.
RUN useradd --create-home --shell /bin/bash app
USER app

# Copy ONLY the assembled release from the build stage.
COPY --from=build --chown=app:app /app/_build/prod/rel/barkpark_cloud ./

# The JSON API listens on 4100 (runtime.exs default; overridable via PORT).
ENV PORT=4100
EXPOSE 4100

# Migrate, then start. `eval` boots just enough to run the migrator and exits;
# `start` then brings up the full supervision tree (Repo + Bandit). All secrets
# (DATABASE_URL, REGISTRY_ENCRYPTION_KEY, STRIPE_SECRET_KEY, …) come from the
# environment at this point — none are present in the image.
CMD ["/bin/sh", "-c", "/app/bin/barkpark_cloud eval 'BarkparkCloud.Release.migrate()' && /app/bin/barkpark_cloud start"]
