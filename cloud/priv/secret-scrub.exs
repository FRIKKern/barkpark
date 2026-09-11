# secret-scrub.exs — THE pattern set. One file, two OTP apps.
#
# WHAT THIS IS
# ------------
# The secret-shape patterns, the redaction string and the ANSI-run source that
# BOTH `BarkparkCloud.FailureCopy` (the control plane's display boundary) and
# `Barkpark.Sites.BuildLogScrub` (the box's recorded-build-log WRITE boundary)
# compile at build time via `@external_resource`. It is data, evaluated once per
# compile; it defines nothing and starts nothing.
#
# WHY A FILE AND NOT A SECOND COPY
# --------------------------------
# `api/` and `cloud/` are separate OTP apps with no dependency either way, so a
# box-side scrub could only reuse this set by COPYING it. A copy of a redaction
# table is the worst kind of copy: the two halves drift in SILENCE (a redacted
# token and a leaked one look identical until someone reads the bytes), and the
# half nobody is looking at is the half that goes stale. The task this file was
# cut for (dr-bl-recorder-http-read-path, c2) forbids a second pattern set
# outright. So the set moves OUT of the module that owned it and both modules
# read the SAME bytes. Each side carries a LOCK TEST that re-reads this file at
# test time and fails if its own compiled set has drifted from it.
#
# WHY IT LIVES UNDER cloud/priv/
# ------------------------------
# Not aesthetics — the control-plane image build. `cloud/`'s Dockerfile COPYs
# mix.exs/mix.lock/config/lib/priv and NOTHING above `cloud/`, so a compile-time
# read from `cloud/lib` can only ever resolve under `cloud/` (D841/D842 —
# the audit-actions table lived in `design/` once and broke every cp deploy;
# `scripts/cloud-path-escape-check.sh` now makes that class fatal). `api/`, by
# contrast, already reads above its own tree at compile time
# (`tooling/pds/pre-gate-papers.json`, `design/`) and its Dockerfile COPYs those
# paths in explicitly. So the ONE location both apps can read is under
# `cloud/priv/`, and api/Dockerfile carries the matching COPY.
#
# THE SET ITSELF IS VERBATIM. Everything below the rule was moved out of
# `failure_copy.ex` unchanged — the patterns, their order, and every comment
# explaining why a clause is shaped the way it is. Read those before editing
# one: each guard was measured, and most of them exist because an earlier,
# wider version destroyed copy a person needed (a redacted git SHA reads exactly
# like a redacted token).
#
# `vectors` at the bottom is the CROSS-APP BEHAVIOUR LOCK: the same input must
# fold to the same bytes on both sides. One pattern set is not enough on its
# own, because each app carries its own small engine; the vectors are what makes
# the two engines answer identically. Every vector is `raw/1`
# (`strip_ansi |> scrub`) — the raw-capture order, measured.
# ---------------------------------------------------------------------------

redaction = "[redacted]"

# STATUS PROSE in a value position — never a credential. A remote capture says
# "no bearer token found", "token: expired", "api_key: not set" far more often
# than it says "token: <a live token>", and redacting the word `expired` tells
# a person a secret leaked when none did. Every entry is an ordinary English
# word that no generated credential can be, so this guard costs the scrub no
# coverage; it is anchored with `\b` so it can only skip the WHOLE value.
prose_value = "(?:token|tokens|credential|credentials|value|header|auth|expired|missing|invalid|unset|unknown|empty|none|null|nil|set|required|absent|not)\\b"

# The secret shapes a remote capture can carry, most specific first. Each entry
# is `{pattern, replacement}` and every one carries POSITIVE and NEGATIVE rows
# in `failure_copy_test.exs`'s table — a pattern without both is not shippable,
# because the failure mode here is silent COPY LOSS (a redacted git SHA reads
# exactly like a redacted token) rather than a crash.
patterns = [
  # `Authorization: Bearer sk-live-…`. The scheme word is kept so the line
  # still says what KIND of credential was refused; everything after it goes.
  #
  # The `prose_value` guard is why this does not maul English: "no bearer
  # token found in the request" is a COMMON failure string and an unguarded
  # `bearer\s+\S+` rendered it "no bearer [redacted] found" — a redaction
  # where no secret ever was, which is its own small lie on the person's
  # screen. The guard is a stop-list of words no credential can be, so it
  # weakens the redaction for nothing.
  {~r/\b(bearer\s+)(?!#{prose_value})\S+/i, "\\1#{redaction}"},

  # A DB URL's USERINFO — `ecto://user:PASS@host/db`. The SCHEME and everything
  # from the `@` on are kept (they name the host that refused); only the
  # `user:pass` is redacted.
  #
  # This clause is the one the Go runner has carried all along
  # (`ectoUserinfoRe`, `internal/cli/cloud/warmpool.go`) and this boundary never
  # grew. It is NOT reachable by any clause above it: `DATABASE_URL` is not one
  # of the key clause's key words, so a `DATABASE_URL=ecto://…` env fold never
  # matched there, and the password sits behind a `//` that the bare-token
  # clause cannot see (a real DB password usually carries a `-`/`_`/symbol, so
  # it is not a contiguous 32+ alnum run either). A migrate failure is the most
  # common way this capture is produced, and it shipped in cleartext.
  #
  # `postgres`/`postgresql` ride along because `deploy.sh` writes the `ecto://`
  # spelling but Ecto/psql errors echo the other two back.
  {~r{\b(ecto|postgres|postgresql)://[^\s:/@]+:[^\s@]+@}, "\\1://#{redaction}@"},

  # `client_secret=…`, `token: …`, `api-key=…`. The KEY and its separator are
  # kept (they name what leaked); the value is redacted up to the next
  # delimiter. `authorization` is deliberately absent — the Bearer clause above
  # already owns that line and keeps the scheme word.
  #
  # Same `prose_value` guard, same reason: "token: expired" and
  # "no api_key: set in the config file" are status prose, not credentials.
  #
  # The left edge is `(?<![A-Za-z0-9])`, NOT `\b`. `_` is a word character, so
  # `\b` cannot fire between the `_` and the `TOKEN` in `BARKPARK_TOKEN=…` —
  # which made every `[A-Z_]*TOKEN=` env fold invisible to this clause, and an
  # env fold is the single most common way a provisioner capture carries a
  # live credential. The lookbehind excludes only alphanumerics, so
  # `BARKPARK_TOKEN=`, `MY_SECRET=` and `DEPLOY_TOKEN=` all match while
  # `xtoken=` (a longer word merely ENDING in `token`) still does not.
  #
  # `(?![=:])` in the value position is the price of that widening. Reaching
  # past `_` puts every `*_token`/`*_password` identifier in a captured stack
  # trace or source echo inside this clause's reach, and `=` is not in the
  # value's stop set — so `hashed_password == before` would render
  # "hashed_password =[redacted] before", copy loss where no secret ever was.
  # A COMPARISON is not an assignment. A real value never STARTS with `=` or
  # `:`, so the guard costs no redaction (`token=abc==` still redacts whole).
  # `<` joins `=`/`:` in the value-position stop set for the same reason they
  # are there: it marks copy that is NOT a credential. The provisioner
  # deliberately narrates the provider-key hand-off as
  # `printf 'ANTHROPIC_API_KEY=<your-key>\n' >> …` — the agent key is the one
  # secret Barkpark never copies, so the developer pastes it themselves — and
  # that line reaches the console fold like any other capture. Redacting
  # `<your-key>` into `[redacted]` destroyed the only copy telling the person
  # what to type, which is the same class of copy loss as the `hashed_password
  # == before` case the `(?![=:])` guard already fixes. A real credential never
  # STARTS with `<`, so this costs the redaction nothing.
  {~r/(?<![A-Za-z0-9])((?:client[_-]?secret|secret[_-]?key|access[_-]?key|api[_-]?key|auth[_-]?token|private[_-]?key|secret|token|password|passwd)\s*[=:]\s*)["']?(?![=:<])(?!#{prose_value})[^\s"',;)]+/i,
   "\\1#{redaction}"},

  # Provider-prefixed credentials: Stripe/OpenAI `sk-`/`pk-`, GitHub `ghp_`/
  # `github_pat_`, Slack `xoxb-`, AWS `AKIA…`, Hetzner `hcloud_`, and — since
  # deploy-reliability W2 S4 — BARKPARK'S OWN `bppat_` (PAT, `auth.ex`) and
  # `bpcs_` (scoped chat/MCP session token, `auth.ex`). These carry hyphens and
  # underscores, so the bare-token clause below (which is `[A-Za-z0-9]` only)
  # cannot see them.
  #
  # Our own prefixes are the load-bearing addition, not a tidy-up. A minted PAT
  # is `bppat_` + `Base.url_encode64(32 bytes, padding: false)`, and ~94% of
  # those 43-char bodies contain a `-` or `_` that breaks the bare-token
  # clause's contiguous-alnum run — so before this clause knew the prefix, a
  # real token measured 94.3% LEAKED through `scrub/1` in four of six shapes
  # (`BARKPARK_TOKEN=…`, `export BARKPARK_TOKEN=…`, bare in prose, and a
  # colourised `token=…`), and the ~6% that redacted did so by accident of the
  # alphabet. Matching the TOKEN — not the syntax around it — is what makes
  # this hole close independently of env-var spelling, prose and colour codes.
  #
  # Our prefixes require `_` specifically (the vendor arm keeps `[-_]`): every
  # Barkpark credential is minted with an underscore, and `bpcs-mint-refused`
  # — a real sentinel in `api/lib/barkpark_web/studio/claude_chat.ex` — is
  # copy a person needs to read, not a secret. `bp-` alone is deliberately
  # absent: every provisioned site is named `bp-<slug>-<hash>`.
  # `bp_<kind>_` is the MINTED BOX CREDENTIAL family — `bp_admin_…` (every
  # provisioned site's per-instance admin token, `setup.GenerateAdminToken`),
  # `bp_read_…`, and any sibling kind minted later. It was the conspicuous gap
  # in this arm: `bppat_`/`bpcs_` are the tokens a PERSON mints, while
  # `bp_<kind>_` is the one the CONTROL PLANE mints for every box it builds —
  # the credential most likely to be in a provisioner capture in the first
  # place. The Go side has never been blind to it (`adminTokenRe` in
  # `internal/provisioner/console.go`, `builderTokenRe` in
  # `internal/builder/console.go` — the latter is exactly `bp_[a-z]+_`), so
  # this clause brings the display boundary level with the two worker-side
  # scrubs rather than trusting them to have caught it upstream.
  #
  # `_` after `bp` is load-bearing and NOT a tidy-up: `bp-` is the site-name
  # prefix (`bp-<slug>-<hash>.barkpark.cloud`), pinned as a negative below. The
  # `[a-z]+` kind keeps that separation exact — a hostname can never enter this
  # clause, because a hostname's separator is a hyphen.
  {~r/\b(?:(?:sk|pk|rk|ghp|gho|ghu|ghs|github_pat|xox[baprs]|hcloud)[-_]|(?:bppat|bpcs)_|bp_[a-z]+_)[A-Za-z0-9\-_]{8,}/,
   redaction},

  # An AWS access key id: `AKIA` + 16 uppercase alphanumerics, no separator, so
  # it needs its own clause (the prefixed clause above requires a `-`/`_`, and
  # the bare-token clause below requires a lowercase letter).
  {~r/\bAKIA[0-9A-Z]{16}\b/, redaction},

  # A bare high-entropy token. NARROW ON PURPOSE: 32+ alphanumerics that mix
  # lower, upper AND digits, and never a 40-char lowercase-hex git SHA. The
  # naive `\b[A-Za-z0-9]{40,}\b` passes the whole cloud suite while silently
  # eating the commit a person deployed; the mixed-case requirement alone also
  # spares a UUID segment, a lowercase `sha256:` digest, a hostname and a
  # semver, all of which are negatives in the table.
  {~r/\b(?![a-f0-9]{40}\b)(?=[A-Za-z0-9]*[a-z])(?=[A-Za-z0-9]*[A-Z])(?=[A-Za-z0-9]*[0-9])[A-Za-z0-9]{32,}\b/,
   redaction}
]


# A terminal control sequence: ESC (0x1B) followed by either a CSI parameter
# run terminated by a final byte (`\e[31m`, `\e[22m`, `\e[2K`), an OSC string
# terminated by BEL or ST, or a bare two-byte escape. Anchored on the REAL
# 0x1B byte — the literal four-character text `\x1B` appears in zero rows; the
# bytes appear in 1,366.
# Ordered: OSC first (it swallows a payload), then CSI, then a bare two-byte
# escape as the fallback — PCRE alternation is ordered, so the specific arms
# always win over the catch-all.
#
# Held as a SOURCE STRING, not only as a compiled regex, because `strip_ansi/1`
# needs the same run in two patterns (below) and a second hand-copied literal
# is a drift hazard: the day someone teaches one arm about DCS, the other keeps
# the old vocabulary and the boundary silently splits in two.
ansi_run = "\x1B(?:\\][^\x07\x1B]*(?:\x07|\x1B\\\\)|\\[[0-?]*[ -/]*[@-~]|[ -~])"

%{
  redaction: redaction,
  prose_value: prose_value,
  ansi_run: ansi_run,
  patterns: patterns,
  # {label, input, expected `raw/1` output}
  vectors: [
    {"a colourised env fold of our OWN pat token",
     "\e[31m\e[1m04:34:24\e[22m [build] BARKPARK_TOKEN=bppat_7Kd-Qm2xTf9Zb_LpV4nA1sJhR0yWuEcG3iOtXvB exported",
     "04:34:24 [build] BARKPARK_TOKEN=[redacted] exported"},
    {"a CSI welded against the key — the weld case", "run\e[0mapi_key=s3cretValueGoesHere1",
     "run api_key=[redacted]"},
    {"bearer STATUS PROSE is not a credential", "no bearer token found in the request",
     "no bearer token found in the request"},
    {"a 40-char git SHA is copy, not a secret",
     "deployed 3f1a2b7c9d0e4f5a6b8c1d2e3f4a5b6c7d8e9f01 to prod",
     "deployed 3f1a2b7c9d0e4f5a6b8c1d2e3f4a5b6c7d8e9f01 to prod"},
    {"a DB URL's userinfo", "ecto://deploy:hunter2swordfish@db.internal:5432/barkpark_prod",
     "ecto://[redacted]@db.internal:5432/barkpark_prod"},
    {"an ordinary build line is byte-identical", "npm ERR! build failed (exit 12)",
     "npm ERR! build failed (exit 12)"}
  ]
}
