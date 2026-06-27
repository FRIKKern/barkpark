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
