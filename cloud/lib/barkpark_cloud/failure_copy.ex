defmodule BarkparkCloud.FailureCopy do
  @moduledoc """
  Server-side humanization of raw internal deploy/provision failure strings —
  the Elixir twin of `app.js` `failureCopy()` (#939), which mapped *builder*-set
  `failure_reason` values in the browser.

  #939 only covered the builder-reported subset. The deploy reaper
  (`Registry.reap_stale_deployments/0`) and the provision path
  (`Registry.fail_job/3`, `Registry.claim_next_job/1`,
  `Registry.reap_stale_provision_jobs/0`) write an adjacent, unmapped subset of
  the SAME class of jargon (e.g. `"exceeded max deploy claim attempts (stale
  builder lease)"`, `"exceeded max provision attempts (3)"`). Those surface
  verbatim in the dashboard's deploy-fail row and provision banner, and in the
  `bp` CLI's `sites` output.

  This maps that jargon to human copy at the JSON serialization boundary
  (`Web.Router.deployment_json/1` and `merge_job_status/4`), so:

    * the stored `failure_reason` / `error` stays RAW — logs, ops, and the
      `provision_failed` email alert keep the honest internal reason. (Wave 26
      S3 / charter D310: that email now LEADS with `humanize/1`'s class and
      keeps the scrubbed capture verbatim below it. "Keeps the honest reason"
      is still exactly true; "does not classify" no longer is.);
    * every read surface (dashboard + CLI) renders human copy with NO client
      change;
    * unrecognized reasons pass through unchanged (graceful fallback — never
      drop information).

  Substring match on the RAW reason, mirroring `failureCopy()`. The two strings
  #939 already humanizes client-side are mapped here too so the CLI matches the
  dashboard, and because the client pass is idempotent over this output (a
  humanized "…no build source…" re-maps to the identical string; the rest pass
  through).

  ## Provider-error classes (coherence arc D58)

  The Hetzner/provisioner layer emits raw provider jargon
  (`SERVER_LIMIT_EXCEEDED`, `resource_unavailable`, `unauthorized`,
  `hetzner dns upsert "…"` failures, `dial tcp: i/o timeout`, …) that reached the
  dashboard and CLI verbatim. Those are folded into five human classes —
  capacity, auth, dns, network and refused — matched case-insensitively (provider
  casing is inconsistent) so no surface ever renders an ALL_CAPS code. The
  REFUSED class was split out of network in wave 28 (D321(3)): a
  `connection refused` is a peer that ANSWERED and said no — nothing was
  listening on that port — so the network class's "retry usually fixes this" was
  the advice most likely to waste the person's time. Its remediation is a cause
  check, not a retry, and it is matched BEFORE the network class. The stored value
  stays RAW, so the timeline's forensic fold and the `provision_failed` email
  keep the honest reason. Two surfaces humanize: the JSON boundary, and — since
  wave 26 S3 (D310) — the `provision_failed` alert email, which prepends the
  class and retains the scrubbed capture in full below it. The DNS class is
  checked BEFORE the generic capacity class because a DNS step that failed on a
  zone quota is a domain problem, not a server-capacity one. All output copy is
  idempotent under a second `humanize` pass (none of it re-matches a class
  token).

  ### The DNS class is keyed on the PRODUCER'S vocabulary (wave 25 S1)

  It used to read `contains("zone create") or (contains("dns") and
  (contains("quota") or contains("failed")))`. NO producer in this tree emits
  `zone create`, `dns zone` or `dns record` as an ERROR (`grep -rn` found them
  only in this clause, its fixtures, and `bp cloud hetzner dns` HELP TEXT), so
  the class was simultaneously DEAD on the real corpus and, via its `dns` +
  `failed` leg, a catch-all for any string that merely mentions `dns`. The four
  shapes the tree can actually emit are exactly two verb-anchored prefixes in
  three READ-ONLY files:

    * `hetzner dns <upsert|change-ttl|delete|resolve|list> %q` —
      `internal/hetzner/dns.go:74,114,137,156`, `internal/cli/cloud/dns.go:279,319,359`
    * `hcloud zone rrset <set-records|change-ttl|delete|list> %q` —
      `internal/cli/cloud/dns_cloud.go:146,151,169,197`

  `@dns_step` is anchored on the VERB rather than on the bare `hetzner dns`
  prefix: the bare form is only safe because of a space character, which is not
  a guarantee.

  ### A fallback-ladder AGGREGATE is classified PER SUB-ERROR (wave 25 S1)

  `CreateWithFallback` (`internal/cli/cloud/provider.go:569`, READ-ONLY) folds
  every candidate's failure into ONE string —

      create "acme-dns-site-ac4e1f2a" failed on all 5 candidate type/locations:
        - cx22/fsn1: … resource_unavailable …
        - cx23/fsn1: … resource_unavailable …

  — so a substring scan of the WHOLE concatenation answers a question nobody
  asked: it fires on any token ANY candidate happened to mention, and on the
  header's own literal `failed`, and on the user's own slug (the `%q` is
  `base.Name`, which carries the site slug verbatim through
  `Barkpark.provisioning_subdomain/1` and the non-admin `POST /v1/sites`). A
  site named `acme-dns-site` therefore had EVERY provisioning failure, forever,
  reported as a domain failure while Hetzner was simply out of capacity.

  So an aggregate is SPLIT: each sub-error is classified on its own and the
  classes are folded. On a TIE — or when no sub-error classifies — the raw
  string passes through (scrubbed) rather than a confident wrong cause being
  invented; a person reading jargon is better off than a person retrying a
  domain they never touched (charter D295).

  ## Typed refusals are NEVER humanized (site-spawner W11)

  `humanize/1` matches SUBSTRINGS and replaces the WHOLE string. That is safe
  over reaper/provider jargon (a closed set of strings we emit ourselves) and
  actively dangerous over a refusal that interpolates a PRODUCER-CONTROLLED
  name: nine of the prebuilt extractor's typed messages
  (`Barkpark.Sites.PrebuiltArtifact` — `E_ABSOLUTE_PATH`, `E_PATH_TRAVERSAL`,
  `E_BAD_NAME`, `E_UNSAFE_PARENT`, `E_WRITE_FAILED`) carry the offending tar
  entry name. Driven through the real deploy pipeline,

      the instance refused the deploy (HTTP 400): E_ABSOLUTE_PATH — entry
      "/quota/index.html" is an absolute path — refused

  matched the capacity clause and rendered as "Hetzner ran out of server
  capacity", and a `../timeout/` PATH TRAVERSAL — a security event — rendered as
  "A network step timed out." Eight of nine ordinary static-site slugs collide
  (`/quota`, `/timeout`, `/unauthorized`, `/dns/failed.html`, …), and the token
  list CANNOT be made safe: the tokens are single common English words and the
  input is user-authored paths.

  So `typed_refusal?/1` is checked FIRST and such a reason passes through
  VERBATIM. A reason is typed when it carries an `E_*` extractor code or the
  `box_refusal/2` prefix — in both cases the box has already said, precisely and
  in human words, what it refused and why; canned provider copy could only
  replace a true statement with a false one. This also keeps `failure_reason`
  and the raw `detail` in the same JSON payload from contradicting each other.

  ### The browser's second pass does NOT need the same guard (reviewed W11)

  `cloud/priv/static/app.js` runs its own `failureCopy()` over whatever this
  module already rendered, so the natural worry is that the dashboard re-mangles
  a typed refusal after the API has stopped doing so. It does not, and the reason
  is structural rather than lucky: every clause over there matches a LONG,
  DISTINCTIVE phrase — `"no build source"`, `"artifact_url is empty"`,
  `"unsupported artifact scheme"`, and `isGithubPushBlocked/1`'s
  `"github push builds"` / `"can't be built yet"` — never a single common English
  word, so no producer-authored tar entry name can collide with one. That is the
  exact property this module's reaper/provider token list LACKS. If a short token
  is ever added to `app.js`, it needs this guard mirrored there.

  ## Secret scrubbing at the display boundary (wave 13 S2)

  A failure reason is frequently a REMOTE CAPTURE — an `ssh` stderr fold, a
  provider HTTP body, a build log tail — so it can carry a credential that the
  control plane never chose to print. `provision_error`, `deprovision_error`,
  the provision step/console folds, the deploy console + detail, and the
  `provision_failed` alert email all render that capture to a PERSON. There is no
  server-side boundary between the capture and their eye, so `scrub/1` is applied
  at every one of those serialization points.

  Three properties, each of which is a test in `failure_copy_test.exs`:

    * **Post-classification, never pre.** `humanize/1` is
      `reason |> classify() |> strip_ansi() |> scrub()`. Scrubbing FIRST would shift
      classification — `"client_secret=timeout"` loses its `timeout` token to the
      redaction and stops reading as the network class. Scrubbing LAST is also
      free of risk over a matched class, because every class arm returns a
      LITERAL and a literal has no secret shape.
    * **The scrub WRAPS the `cond`, it never sits inside one arm.** Nesting it in
      the `typed_refusal?/1` arm makes it a no-op for exactly the strings that
      carry secrets most often — an unclassified remote capture like
      `ssh: remote said Authorization: Bearer …` falls through the terminal arm.
    * **It redacts SUBSTRINGS; it never replaces the string.** A typed refusal
      keeps its `E_*` code and its entry name, with `[redacted]` only where the
      token was — the box's precise sentence is never laundered into canned copy.

  The pattern set is deliberately narrow on the bare-token clause: a naive
  `\\b[A-Za-z0-9]{40,}\\b` eats a 40-char git SHA, costing a person the commit
  they deployed. Every pattern carries POSITIVE and NEGATIVE rows in the
  table-driven test (git SHA, UUID, hostname, semver, base64 digest).

  The DB stays RAW by design: only the JSON/email boundary scrubs, so ops
  recovery via `Repo.get(ProvisionJob, id).console` and the logs is unaffected.

  ## ONE order, and `raw/1` is the only way to spell it (deploy-reliability W8 S6)

  `scrub/1`'s key clause keeps the key and redacts up to the NEXT DELIMITER, and
  a colour code parks a non-delimiter byte (`m`) immediately left of the key, so
  over a colourised `\\e[31mapi_key=…\\e[0m` the clause never fires at all.
  Measured on 2,000 fresh 24-char alnum secrets (the SUB-32-CHAR stratum — the
  bare-entropy clause catches 32+ regardless of order, where the same experiment
  leaks only 2/2000):

      scrub |> strip_ansi  →  LEAKED 2000/2000
      strip_ansi |> scrub  →  LEAKED 0/2000

  So the strip ALWAYS precedes the scrub. `raw/1` is that composition and is THE
  raw-log boundary: every path that renders a capture verbatim calls it rather
  than hand-rolling the pipe, because a hand-rolled pipe is exactly what shipped
  backwards at `router.ex`'s `failure_reason_raw` and at
  `notifications/event_email.ex` (which stripped nothing at all).

  `humanize/1` is `classify |> strip_ansi |> scrub` — the strip sits BETWEEN, not
  before, so the classifier still reads the producer-anchored prefix with its
  escape run intact while the terminal pass-through arm (UNCLASSIFIED is a
  designed, COUNTED bucket in this ledger, not a corner) gets the same
  strip-then-scrub protection `raw/1` gives. W2 S4's `classify |> scrub |>
  strip_ansi` was safe for a MATCHED class — the arms return literals — and
  leaked identically on the arm that returns the reason itself.

  Provider-prefixed credentials (including our own `bppat_`/`bpcs_`) are
  order-INDEPENDENT — that clause matches the token itself — so the order only
  decides whether the key-shaped secrets survive. Never use a `bppat_`, a
  `BARKPARK_TOKEN=` (the `_` satisfies the key clause's lookbehind) or a
  trailing-ANSI shape as evidence about the order: all three close either way.
  Pinned end-to-end, through the real route, by `failure_raw_boundary_test.exs`;
  a unit test over `scrub`/`strip_ansi` cannot tell a fixed call site from a
  broken one.
  """

  # An extractor refusal code: `E_` followed by SCREAMING_SNAKE. Anchored on a
  # word boundary so a provider code that merely ENDS in `…E_…`
  # (`SERVER_LIMIT_EXCEEDED`, `RESOURCE_UNAVAILABLE`) can't match — `_` is a word
  # character, so there is no boundary inside those.
  @typed_code ~r/\bE_[A-Z][A-Z0-9_]*\b/

  # `BarkparkCloud.Sites.Deploy.box_refusal/2`'s prefix: the box answered and said
  # no, in its own words.
  @box_refusal "the instance refused the deploy"

  @doc """
  Whether a raw failure reason already carries a typed refusal — an `E_*`
  extractor code or the box-refusal prefix — and therefore must reach the user
  unrewritten.
  """
  @spec typed_refusal?(term()) :: boolean()
  def typed_refusal?(reason) when is_binary(reason) do
    String.contains?(reason, @box_refusal) or Regex.match?(@typed_code, reason)
  end

  def typed_refusal?(_other), do: false

  @redaction "[redacted]"

  # STATUS PROSE in a value position — never a credential. A remote capture says
  # "no bearer token found", "token: expired", "api_key: not set" far more often
  # than it says "token: <a live token>", and redacting the word `expired` tells
  # a person a secret leaked when none did. Every entry is an ordinary English
  # word that no generated credential can be, so this guard costs the scrub no
  # coverage; it is anchored with `\b` so it can only skip the WHOLE value.
  @prose_value "(?:token|tokens|credential|credentials|value|header|auth|expired|missing|invalid|unset|unknown|empty|none|null|nil|set|required|absent|not)\\b"

  # The secret shapes a remote capture can carry, most specific first. Each entry
  # is `{pattern, replacement}` and every one carries POSITIVE and NEGATIVE rows
  # in `failure_copy_test.exs`'s table — a pattern without both is not shippable,
  # because the failure mode here is silent COPY LOSS (a redacted git SHA reads
  # exactly like a redacted token) rather than a crash.
  @secret_patterns [
    # `Authorization: Bearer sk-live-…`. The scheme word is kept so the line
    # still says what KIND of credential was refused; everything after it goes.
    #
    # The `@prose_value` guard is why this does not maul English: "no bearer
    # token found in the request" is a COMMON failure string and an unguarded
    # `bearer\s+\S+` rendered it "no bearer [redacted] found" — a redaction
    # where no secret ever was, which is its own small lie on the person's
    # screen. The guard is a stop-list of words no credential can be, so it
    # weakens the redaction for nothing.
    {~r/\b(bearer\s+)(?!#{@prose_value})\S+/i, "\\1#{@redaction}"},

    # `client_secret=…`, `token: …`, `api-key=…`. The KEY and its separator are
    # kept (they name what leaked); the value is redacted up to the next
    # delimiter. `authorization` is deliberately absent — the Bearer clause above
    # already owns that line and keeps the scheme word.
    #
    # Same `@prose_value` guard, same reason: "token: expired" and
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
    {~r/(?<![A-Za-z0-9])((?:client[_-]?secret|secret[_-]?key|access[_-]?key|api[_-]?key|auth[_-]?token|private[_-]?key|secret|token|password|passwd)\s*[=:]\s*)["']?(?![=:])(?!#{@prose_value})[^\s"',;)]+/i,
     "\\1#{@redaction}"},

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
    {~r/\b(?:(?:sk|pk|rk|ghp|gho|ghu|ghs|github_pat|xox[baprs]|hcloud)[-_]|(?:bppat|bpcs)_)[A-Za-z0-9\-_]{8,}/,
     @redaction},

    # An AWS access key id: `AKIA` + 16 uppercase alphanumerics, no separator, so
    # it needs its own clause (the prefixed clause above requires a `-`/`_`, and
    # the bare-token clause below requires a lowercase letter).
    {~r/\bAKIA[0-9A-Z]{16}\b/, @redaction},

    # A bare high-entropy token. NARROW ON PURPOSE: 32+ alphanumerics that mix
    # lower, upper AND digits, and never a 40-char lowercase-hex git SHA. The
    # naive `\b[A-Za-z0-9]{40,}\b` passes the whole cloud suite while silently
    # eating the commit a person deployed; the mixed-case requirement alone also
    # spares a UUID segment, a lowercase `sha256:` digest, a hostname and a
    # semver, all of which are negatives in the table.
    {~r/\b(?![a-f0-9]{40}\b)(?=[A-Za-z0-9]*[a-z])(?=[A-Za-z0-9]*[A-Z])(?=[A-Za-z0-9]*[0-9])[A-Za-z0-9]{32,}\b/,
     @redaction}
  ]

  @doc """
  Redact secret-shaped SUBSTRINGS from a string bound for a person's screen or
  inbox. Non-binaries pass through unchanged.

  This never replaces the whole string: the surrounding sentence — a typed
  refusal's `E_*` code, a provider's own words, the offending tar entry — is
  what makes the failure actionable, and `#{@redaction}` sits only where the
  credential was. Idempotent: `#{@redaction}` carries no secret shape of its own.

  Applied at the display boundary only. The stored row keeps the raw bytes so
  ops recovery from the DB and the logs is unaffected.
  """
  @spec scrub(term()) :: term()
  def scrub(text) when is_binary(text) do
    Enum.reduce(@secret_patterns, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def scrub(other), do: other

  # A terminal control sequence: ESC (0x1B) followed by either a CSI parameter
  # run terminated by a final byte (`\e[31m`, `\e[22m`, `\e[2K`), an OSC string
  # terminated by BEL or ST, or a bare two-byte escape. Anchored on the REAL
  # 0x1B byte — the literal four-character text `\x1B` appears in zero rows; the
  # bytes appear in 1,366.
  # Ordered: OSC first (it swallows a payload), then CSI, then a bare two-byte
  # escape as the fallback — PCRE alternation is ordered, so the specific arms
  # always win over the catch-all.
  @ansi ~r/\x1B(?:\][^\x07\x1B]*(?:\x07|\x1B\\)|\[[0-?]*[ -\/]*[@-~]|[ -~])/

  @doc """
  Strip terminal control sequences from a string bound for a person's screen, an
  inbox, or a JSON payload.

  Remote build output is captured from a PTY, so an Astro `BUILD failed (exit 12)`
  reason arrives as `\\e[31m\\e[1m04:34:24\\e[22m [ERROR] …`. 1,366 of 17,395 failed
  rows carry real 0x1B bytes (verified with `position(chr(27) in failure_reason)`)
  and NOTHING stripped them anywhere — not this module, not the CLI's
  `siteFailure`, not the console's `failureCopy()`. They render as `[31m[1m` in
  a browser, as raw colour in a terminal that then keeps that colour, and as
  mojibake in an email.

  Applied at the display boundary only, beside `scrub/1`: the stored row keeps
  the raw bytes so ops recovery from the DB and the logs is unaffected.
  Non-binaries pass through unchanged. Idempotent.
  """
  @spec strip_ansi(term()) :: term()
  def strip_ansi(text) when is_binary(text), do: Regex.replace(@ansi, text, "")

  def strip_ansi(other), do: other

  @doc """
  THE raw-log boundary: `strip_ansi/1` then `scrub/1`, in that order, for every
  path that renders a capture VERBATIM without classifying it first.

  Call this instead of composing the two by hand. The composition is not
  commutative and the wrong way round is silently safe-LOOKING: `scrub |>
  strip_ansi` returns a field with no escape bytes in it and the secret still
  in cleartext, because `scrub/1`'s key clause redacts up to the next delimiter
  and a colour code parks a non-delimiter byte immediately left of the key. Over
  2,000 fresh sub-32-char colourised `api_key=` values that order leaked
  2000/2000 and this one leaked 0/2000.

  Non-binaries pass through unchanged (both steps no-op). Idempotent.
  """
  @spec raw(term()) :: term()
  def raw(text), do: text |> strip_ansi() |> scrub()

  @doc """
  Map a raw internal deploy/provision failure string to human-facing copy, with
  secret-shaped substrings redacted.

  The scrub runs AFTER classification and WRAPS the whole `cond` — see the
  moduledoc for why either change is a live regression. Passes `nil` and
  non-binary reasons through unchanged; unrecognized reasons pass through
  scrubbed.

  deploy-reliability W8 S6: `strip_ansi/1` runs BETWEEN `classify/1` and
  `scrub/1`, not after both. It cannot run FIRST — the classifier's prefixes are
  anchored on the producer's template and an escape run can sit between the
  prefix and the text (`BUILD failed (exit 12): \\e[22m`), so stripping first
  would change what the classifier reads. It cannot run LAST either, which is
  what W1 S2 shipped: this function's TERMINAL arm returns the reason itself
  ("unrecognized reasons pass through scrubbed"), so on that arm the scrub was
  facing colourised bytes and a colourised `api_key=` reached the reader in
  cleartext with the escapes tidied off it. Between is the only position that is
  right on BOTH arms — a matched class returns a literal, over which every step
  is a no-op, and the pass-through arm gets exactly `raw/1`'s protection.
  """
  @spec humanize(term()) :: term()
  def humanize(nil), do: nil

  def humanize(reason) when is_binary(reason),
    do: reason |> classify() |> strip_ansi() |> scrub()

  def humanize(other), do: other

  # Every DNS-step error shape the tree can emit, VERB-ANCHORED. The producers
  # are READ-ONLY (`internal/**`) and are exactly two `fmt.Errorf` prefixes:
  #
  #   hetzner dns <upsert|change-ttl|delete|resolve|list> %q  —
  #     internal/hetzner/dns.go:74,92,107,114,137,156
  #     internal/cli/cloud/dns.go:279,283,319,323,359
  #   hcloud zone rrset <set-records|change-ttl|delete|list> %q —
  #     internal/cli/cloud/dns_cloud.go:146,151,169,197
  #     internal/cli/cloud/dns.go:434
  #
  # Anchoring on the VERB rather than the bare `hetzner dns` prefix is the point:
  # the bare form only avoids matching `hetzner dnssomething` because of one
  # space character, and a space is not a guarantee.
  @dns_step ~r/\b(?:hetzner dns (?:upsert|change-ttl|delete|resolve|list)|hcloud zone rrset (?:set-records|change-ttl|delete|list))\b/

  # The fallback-ladder aggregate's TWO markers. BOTH are required: the header
  # phrase alone can appear inside a longer operator note, and the `"\n  - "`
  # separator alone is ordinary list formatting. Requiring both is also what
  # makes every pre-existing assertion byte-identical BY CONSTRUCTION — no string
  # in the unit suite carries either marker, so the aggregate arm is unreachable
  # for all of them.
  #
  # DELIBERATELY UNANCHORED. `CreateWithFallback`'s aggregate is WRAPPED by its
  # callers before it is stored (`internal/cli/cloud/restore_driver.go:137`
  # returns `resurrect create %q: %w`; `warmpool_assign.go:30` returns
  # `create warm server %q: %w`), so a `^`-anchored header would be a selector
  # that cannot reach the very strings this arm exists for.
  @aggregate_header ~r/create "[^"]*" failed on all \d+ candidate type\/locations:/i
  @aggregate_separator "\n  - "

  @doc false
  @spec aggregate?(term()) :: boolean()
  def aggregate?(reason) when is_binary(reason) do
    Regex.match?(@aggregate_header, reason) and
      String.contains?(reason, @aggregate_separator)
  end

  def aggregate?(_other), do: false

  # The class fold: raw jargon → human copy, or the reason unchanged. Private —
  # every caller goes through `humanize/1` so nothing can reach a surface having
  # skipped the scrub.
  #
  # A typed refusal is checked before the aggregate split for the same reason it
  # is checked first inside `classify_atomic/1`: it is already precise, already
  # human, and interpolates a producer-controlled name.
  defp classify(reason) when is_binary(reason) do
    if not typed_refusal?(reason) and aggregate?(reason) do
      classify_aggregate(reason)
    else
      classify_atomic(reason)
    end
  end

  # Split the aggregate on the producer's own separator, drop the header, and
  # classify each candidate's error ALONE. A sub-error `classify_atomic/1`
  # returns unchanged did not classify, so it casts no vote.
  defp classify_aggregate(reason) do
    reason
    |> String.split(@aggregate_separator)
    |> Enum.drop(1)
    |> Enum.flat_map(fn sub ->
      case classify_atomic(sub) do
        ^sub -> []
        copy -> [copy]
      end
    end)
    |> Enum.frequencies()
    |> fold_classes(reason)
  end

  # THE TIE RULE (charter D295, ratified — do NOT replace this with
  # majority-then-first-appearance): a STRICT plurality wins; a tie, or no votes
  # at all, falls through to the RAW pass-through. Naming one of two equally
  # supported causes is how a person ends up retrying the wrong thing.
  defp fold_classes(votes, reason) do
    case Enum.sort_by(votes, fn {_copy, n} -> -n end) do
      [] -> reason
      [{copy, _n}] -> copy
      [{copy, n}, {_runner_up, m} | _] when n > m -> copy
      _tied -> reason
    end
  end

  defp classify_atomic(reason) when is_binary(reason) do
    # Provider casing is inconsistent (`SERVER_LIMIT_EXCEEDED` vs
    # `resource_unavailable`); the provider-class clauses match this lowered
    # copy. The internal-jargon clauses above keep matching the raw `reason`
    # (their exact strings are known) so their behavior is unchanged.
    down = String.downcase(reason)

    cond do
      # site-spawner W11: a typed refusal is already precise and already human —
      # and it interpolates a producer-controlled entry name, so any substring
      # clause below could replace a traversal refusal with unrelated provider
      # copy. Checked FIRST, before any token can see it. See the moduledoc.
      typed_refusal?(reason) ->
        reason

      # dwb-webhook fail-fast interim: a GitHub push was recorded as a
      # born-`failed` deployment because source builds need the GitHub App
      # integration (gh-1, human-gated). Blocked-tone, names the workaround.
      # Checked FIRST — the raw reason is a known exact string; its output does
      # not re-match any clause (no "github push builds" token), so a second
      # client-side `failureCopy()` pass is idempotent.
      String.contains?(down, "github push builds") ->
        "GitHub pushes are recorded but can't be built yet — deploy this commit with bp deploy. Automatic GitHub builds are coming."

      # site-spawner D28: the STATIC twin of "no build source". A content-bound
      # site builds from a Barkpark dataset, so its missing build source is a
      # missing CONTENT BINDING — telling its owner to "connect a repo or run bp
      # deploy" would name neither the cause nor the cure. Checked BEFORE the
      # generic clause below (whose "no build source" token this string does not
      # carry, but the ordering keeps the intent explicit). The output re-matches
      # no clause, so a second client-side `failureCopy()` pass is idempotent.
      String.contains?(reason, "no content binding") ->
        "This site isn't bound to any content yet. Create it with --dataset <workspace>/<project>/<dataset>."

      String.contains?(reason, "no build source") ->
        "This site has no build source yet. Connect a repo or run bp deploy."

      String.contains?(reason, "artifact_url is empty") or
          String.contains?(reason, "unsupported artifact scheme") ->
        "The build source couldn't be fetched."

      # Deploy reaper: an over-budget "building" row that never finished within
      # its lease. Checked before the generic "exceeded max … attempts" clause,
      # which this string also matches.
      String.contains?(reason, "stale builder lease") or
          String.contains?(reason, "deploy claim attempts") ->
        "The build didn't finish after several attempts and was stopped. Deploy again to retry."

      # Provision / deprovision claim + reaper: "exceeded max provision attempts (3)",
      # "exceeded max deprovision attempts (3)".
      String.contains?(reason, "exceeded max") and String.contains?(reason, "attempts") ->
        "This didn't finish after several attempts. Try again in a moment."

      # ── Azure provider classes (provider-neutral hosting) ──
      # Matched on Azure-specific tokens so they never collide with the Hetzner
      # classes below (e.g. Azure's "QuotaExceeded" is caught here, while
      # Hetzner's spaced "account quota exceeded" falls through to the generic
      # capacity class). Each names the EXACT Azure Portal fix. All three are
      # idempotent under a second pass (their output re-maps to itself or misses
      # every class).

      # Missing RBAC role: the service principal authenticated but lacks the role
      # to act on the subscription (`AuthorizationFailed`, "does not have
      # authorization/permission"). Checked before the generic auth class.
      String.contains?(down, "authorizationfailed") or
        String.contains?(down, "does not have authorization") or
          String.contains?(down, "does not have permission") ->
        "Your Azure service principal is missing a role. In the Azure Portal → Subscriptions → your subscription → Access control (IAM) → Add role assignment, grant it the Contributor role, then reconnect."

      # Quota exceeded per VM family: the subscription's vCPU quota for a specific
      # size family is exhausted (`QuotaExceeded`, quota + family/vcpu). Checked
      # before the generic capacity class.
      String.contains?(down, "quotaexceeded") or
          (String.contains?(down, "quota") and
             (String.contains?(down, "family") or String.contains?(down, "vcpu"))) ->
        "Your Azure subscription's vCPU quota for this VM family is exhausted. In the Azure Portal → Subscriptions → your subscription → Usage + quotas, filter to the family and choose Request increase, then retry."

      # Region capacity: the region/zone has no capacity for the requested size
      # right now (`SkuNotAvailable`, `AllocationFailed`, `ZonalAllocationFailed`).
      String.contains?(down, "skunotavailable") or
        String.contains?(down, "allocationfailed") or
          String.contains?(down, "zonalallocationfailed") ->
        "This Azure region has no capacity for this VM size right now. In the Azure Portal → Virtual machines, pick another region or size — or retry shortly, since capacity is transient per region and size."

      # DNS: a domain/zone step failed on the provider. Checked BEFORE capacity
      # so a DNS step that failed on a zone quota reads as a domain problem, not
      # a server-capacity one — but ONLY for the verb-anchored producers below.
      # A zone-quota capture that carries no producer verb still falls to the
      # capacity arm, which is why that arm's copy names no resource.
      #
      # Keyed on the producer's REAL vocabulary (see the moduledoc). The three
      # tokens this clause used to carry — `zone create`, `dns zone`,
      # `dns record` — are DELETED: no producer emits them, and the `dns` +
      # `failed` leg they were bundled with turned the clause into "does this
      # string mention dns anywhere", which the user's own slug can satisfy.
      Regex.match?(@dns_step, down) ->
        "Securing the domain failed on the provider side."

      # Capacity / quota: a resource ceiling somewhere on the provider side
      # (`SERVER_LIMIT_EXCEEDED`, `resource_unavailable`, or a bare `quota`).
      #
      # THE COPY NAMES NEITHER A PROVIDER NOR A RESOURCE, BECAUSE THIS PREDICATE
      # CAN DISTINGUISH NEITHER. It is a bare substring test over a string, and
      # `humanize/1` is arity 1 — there is no provider argument anywhere in the
      # seam, so every caller's Hetzner AND Azure captures land here alike. The
      # resource is just as blind: the DNS clause above is VERB-anchored (wave
      # 25 narrowed it, correctly), so a verb-less zone-quota capture such as
      # `hetzner dns: zone quota reached for this account` reaches THIS arm. The
      # copy it used to get — "Hetzner ran out of SERVER capacity for this size"
      # — named the right provider, the wrong resource and the wrong remedy: a
      # zone ceiling is not cleared by waiting for a server to free up.
      String.contains?(down, "quota") or
        String.contains?(down, "server_limit_exceeded") or
          String.contains?(down, "resource_unavailable") ->
        "A capacity or quota limit was reached at the hosting provider — it may be servers, addresses, DNS zones or another resource. Try again shortly, or check your account's limits with the provider."

      # Auth / token: the provider rejected our stored credentials.
      String.contains?(down, "unauthorized") or String.contains?(down, "invalid token") ->
        "The hosting provider rejected our credentials. We're on it — try again shortly."

      # Refused: the peer ANSWERED and said no — an RST, nothing listening on the
      # port we dialled. Split out of the network class in wave 28 (D321(3)),
      # which fused it with `timeout` and therefore told a person to retry: the
      # one remedy that cannot work, because a closed port stays closed until
      # something starts listening. Checked BEFORE the timeout arm; an
      # `econnrefused` capture that ALSO carries `timeout` (a dial that retried
      # until the deadline) is still a refusal, and the refusal is the actionable
      # half. The copy carries no token any earlier arm matches, does not repeat
      # `connection refused` (so a second pass is idempotent), and does not carry
      # `@box_refusal`'s phrase.
      String.contains?(down, "connection refused") or String.contains?(down, "econnrefused") ->
        "Nothing is listening on the port we dialled — the service on the box is down or hasn't finished starting. Check the instance's health in the console."

      # Network / timeout: a transient network step failed; a retry usually clears it.
      String.contains?(down, "timeout") ->
        "A network step timed out. Retry usually fixes this."

      true ->
        reason
    end
  end

  @doc """
  The per-kind remediation copy the connect endpoint returns when the
  verify-before-save preflight can't authenticate a provider credential. Names
  the EXACT console/portal fix so the user can act without a support round-trip.
  Falls back to a provider-agnostic line for an unknown kind.
  """
  @spec connect_remediation(String.t()) :: String.t()
  def connect_remediation("hetzner") do
    "We couldn't reach Hetzner with that API token. Create a fresh Read & Write token in the Hetzner Cloud Console → your project → Security → API tokens, then paste it here."
  end

  def connect_remediation("azure") do
    "We couldn't authenticate to Azure with those details. In the Azure Portal → App registrations → your app, re-check the Directory (tenant) ID, Application (client) ID and Subscription ID, and that the client secret under Certificates & secrets hasn't expired — then reconnect."
  end

  def connect_remediation("cloudflare") do
    "We couldn't reach Cloudflare with that API token. Create a token with Zone · DNS · Edit (and DNS · Read) permissions in the Cloudflare dashboard → My Profile → API Tokens → Create Token, then paste it here."
  end

  def connect_remediation(_kind) do
    "We couldn't verify those credentials with the provider. Double-check them and try again."
  end

  @doc """
  The per-kind remediation copy `POST /v1/launch` returns when a launch names a
  provider the team hasn't connected yet (provider-neutral hosting, charter
  Decision 4/9). Azure PROVISIONS from the team's connected service-principal, so a
  launch without one is a dead end unless we point the user at Providers → connect
  first — failing at the button, never mid-provision. Falls back to a
  provider-agnostic line for an unknown kind.
  """
  @spec provider_not_connected_remediation(String.t()) :: String.t()
  def provider_not_connected_remediation("azure") do
    "Connect your Azure account first. In Barkpark Cloud → Providers → Azure, add your service-principal details (tenant, client, secret, subscription) — we verify them before saving — then launch again."
  end

  def provider_not_connected_remediation(_kind) do
    "Connect this provider under Barkpark Cloud → Providers first, then launch again."
  end

  @doc """
  The server-owned reason a provider LACKS a capability — the honest-degradation
  copy the fleet/console and CLI render next to a disabled action so a missing
  capability is visible WITH a reason, never a dead button or fake parity (the
  wish's "degrade visibly with a reason"; charter Decision 8/16). Keyed on
  `(kind, capability)`; the terminal default clause GUARANTEES every false
  capability in `providers_capabilities.json` has a reason — no gap can reach a
  surface reason-less, even for a capability key added later (S9's facet split).

  Ownership lives HERE, not in the SPA or CLI, so both surfaces read one copy
  through the `GET /v1/providers/capabilities` conduit and can never drift.
  """
  @spec capability_gap_reason(String.t(), String.t()) :: String.t()

  # Azure lifecycle facets. Azure now honours archive (S14b: the PORTABLE
  # bp-bundle-v1 — no snapshot substrate needed), resurrect (S14d: a bundle
  # archived on Hetzner or Azure restores onto a fresh Azure box), decommission
  # and audit. Its ONE remaining gap is ADOPT (a snapshot-based clone-swap),
  # named specifically so the console can say WHY, not just "no". The dead
  # archive/resurrect gap clauses are gone: live capabilities never degrade.
  def capability_gap_reason("azure", "adopt") do
    "Adopt is a snapshot-based clone-swap on Hetzner; Azure has no equivalent yet, so the same verb would quietly mean something different."
  end

  # Hetzner pause: a stopped Hetzner server still bills for its resources, so we
  # don't offer a pause that lies about cost — archive releases it instead.
  def capability_gap_reason("hetzner", "pause") do
    "Hetzner boxes can't be paused — a stopped server still bills. Archive it to stop paying and resurrect it later."
  end

  # Catalog: the provider doesn't publish a normalized size-and-region catalog
  # here, so provisioning falls back to fixed defaults (generic across kinds).
  def capability_gap_reason(_kind, "catalog") do
    "This provider doesn't publish a size-and-region catalog here yet, so provisioning uses fixed defaults."
  end

  # Generic per-capability fallbacks — reached by any (kind, capability) pair
  # not named above, so a new provider or a newly-false capability still degrades
  # with human copy.
  def capability_gap_reason(_kind, "lifecycle") do
    "Lifecycle actions (archive, decommission, resurrect, adopt) aren't available on this provider yet."
  end

  def capability_gap_reason(_kind, "pause") do
    "Pausing isn't available on this provider yet."
  end

  def capability_gap_reason(_kind, "labels") do
    "Labels aren't available on this provider yet."
  end

  def capability_gap_reason(_kind, "core") do
    "Core provisioning isn't available on this provider yet."
  end

  def capability_gap_reason(_kind, capability) when is_binary(capability) do
    "The #{capability} capability isn't available on this provider yet."
  end

  @doc """
  The server-owned remediation for a non-ok domain-status stage (charter S13 —
  `BarkparkCloud.DomainStatus`). Keyed on `(kind, stage)` where `kind` is
  `"platform"` (the provisioning FQDN) or `"custom"` (an attached `custom_host`)
  and `stage` is one of `"dns_found"`, `"points_here"`, `"tls"`, `"serving"`.

  The cert story genuinely differs by kind: the PLATFORM FQDN's certificate is
  issued and renewed by the provision-time Caddy automatically, while a CUSTOM
  host's certificate is requested on demand by the attach step
  (`/v1/tls/ask` — `registry.ex` `domain_registered?/1` deliberately excludes the
  platform FQDN), so the two `pending` stories point the operator at different
  things. Every OTHER stage's copy is kind-agnostic. The terminal default clause
  GUARANTEES no non-ok stage is ever reason-less — the console (S13b) and CLI
  read this one copy through the domain-status envelope, so they can't drift.
  """
  @spec domain_stage_remediation(String.t(), String.t()) :: String.t()

  def domain_stage_remediation(_kind, "dns_found") do
    "This domain isn't resolving publicly yet. If you just launched or attached it, DNS records take up to a minute to propagate — give it a moment and re-check."
  end

  def domain_stage_remediation(_kind, "points_here") do
    "This domain resolves, but not to this instance's address. It's pointed automatically when the instance is provisioned; if it persists, re-attach the domain or contact support."
  end

  # PLATFORM cert: provision-time Caddy issues + renews it automatically.
  def domain_stage_remediation("platform", "tls") do
    "The TLS certificate for this domain is issued and renewed automatically by the platform. If it isn't ready, it's usually still being issued on first HTTPS request — give it ~60s and re-check."
  end

  # CUSTOM cert: requested on demand by the attach step (/v1/tls/ask).
  def domain_stage_remediation("custom", "tls") do
    "The certificate for your custom domain is requested on demand when it's attached. If it isn't ready, give it ~60s and re-check; if it persists, re-attach the domain."
  end

  def domain_stage_remediation(_kind, "serving") do
    "The domain and certificate check out, but this instance isn't returning a healthy response yet. If it just launched it may still be booting — check the instance status, then re-check."
  end

  # Terminal default: any stage (including a skipped, still-pending one) gets a
  # reason so no non-ok stage is ever rendered reason-less.
  def domain_stage_remediation(_kind, _stage) do
    "This check hasn't passed yet. It runs after the earlier steps succeed — resolve those first, then re-check."
  end
end
