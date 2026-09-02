defmodule BarkparkCloud.ConsoleReaderCensus do
  @moduledoc """
  THE EXTRACTORS — both sides of the wire-vs-reader census, derived from SOURCE
  TEXT at run time, never committed as numbers.

  ## SIDE A — what the plane MINTS

  The comment-stripped union of `error:`/`code:` string-KEY literals over
  `cloud/lib/barkpark_cloud/web/router.ex` and `cloud/lib/barkpark_cloud/web/auth.ex`.
  Comment stripping matters in BOTH directions: the router's doc comments quote
  refusal shapes (`##   -> 401 {error: ...}`) that are documentation, not
  emitters. Only FULL-LINE comments are stripped; a code named solely in a
  trailing inline comment would still count as minted — that failure mode is
  LOUD (a phantom code demands classification on a PR), never silent.

  ## SIDE B — what the console READS (charter D873, the two-part rule)

  A code is READ iff EITHER:

    (i)  it appears as a WHOLE quoted string literal on a comment-stripped line
         of `cloud/priv/static/app.js` (`"role_too_high"` in a comparison, a
         details-map key, a copy-arm dispatch), OR
    (ii) it is a BARE identifier key of the `var ERRORS = {` block.

  Part (ii) exists because a bare ERRORS key is the STANDARD reader pattern in
  this codebase — `suspended: "This instance is suspended..."` carries no quotes
  around the slug — and a quoted-only scan is BLIND to it. Measured at D873
  time: thirteen minted codes, including all five D871 curated keys, are
  bare-key-only readers; a one-part rule would have false-redded every past and
  future correct ERRORS fix. JS comment stripping (full-line `//`, block-comment
  lines, trailing ` // ` tails) keeps a slug that is merely DISCUSSED in a
  comment from counting as read.

  ## Fail-closed

  A missing or renamed source file, an extraction that comes back empty, or an
  ERRORS block the parser cannot find is a NAMED raise — never an empty set. An
  empty Side A reads as "nothing is unread" and an empty Side B reads as
  "nothing is read"; the first is a vacuous green, and this census refuses both
  rather than measure nothing.
  """

  @code_re ~r/\b(?:error|code):\s*"([a-z0-9_]+)"/
  @quoted_re ~r/["']([a-z0-9_]+)["']/
  @errors_open ~r/var ERRORS = \{/
  @errors_close ~r/^\s*\};/
  @errors_key_re ~r/^\s*([a-zA-Z_][a-zA-Z0-9_]*):\s/

  @doc "The source at `file` — a missing file is a NAMED refusal, never an empty set."
  @spec source!(binary(), binary()) :: binary()
  def source!(file, what) do
    unless File.regular?(file) do
      raise ArgumentError,
            "ConsoleReaderCensus: #{what} source not found at #{file}. " <>
              "The file moved or was renamed — re-point the census @sources. " <>
              "Refusing to derive a census side from a source that does not exist."
    end

    File.read!(file)
  end

  @doc """
  Elixir source with FULL-LINE comments blanked. A line whose first non-space
  bytes are `#` is a comment unless they are `\#{` (string interpolation split
  across lines — not a comment opener).
  """
  @spec strip_ex_comments(binary()) :: [binary()]
  def strip_ex_comments(src) do
    src
    |> String.split("\n")
    |> Enum.map(fn line ->
      t = String.trim_leading(line)

      if String.starts_with?(t, "#") and not String.starts_with?(t, "\#{"),
        do: "",
        else: line
    end)
  end

  @doc """
  JS source with comments blanked: full-line `//`, block-comment body lines
  (leading `*` or `/*`), and trailing ` // ` tails (the space-guarded form spares
  `https://` URLs inside string literals).
  """
  @spec strip_js_comments(binary()) :: [binary()]
  def strip_js_comments(src) do
    src
    |> String.split("\n")
    |> Enum.map(fn line ->
      t = String.trim_leading(line)

      cond do
        String.starts_with?(t, "//") -> ""
        String.starts_with?(t, "/*") -> ""
        String.starts_with?(t, "* ") or t == "*" or t == "*/" -> ""
        true -> Regex.replace(~r{\s//\s.*$}, line, "")
      end
    end)
  end

  @doc """
  SIDE A for one Elixir source: every `error:`/`code:` string-key literal on the
  comment-stripped lines. An empty extraction is a NAMED refusal — the emitter
  grammar changed, and a census over zero emitters proves nothing.
  """
  @spec emitted_codes(binary(), binary()) :: MapSet.t()
  def emitted_codes(src, what) do
    codes =
      src
      |> strip_ex_comments()
      |> Enum.flat_map(fn line ->
        Regex.scan(@code_re, line) |> Enum.map(fn [_, c] -> c end)
      end)
      |> MapSet.new()

    if MapSet.size(codes) == 0 do
      raise ArgumentError,
            "ConsoleReaderCensus: extracted ZERO error:/code: literals from #{what}. " <>
              "Either the emitter grammar changed (re-teach @code_re) or the wrong " <>
              "file is being read. Refusing to treat an empty Side A as truth."
    end

    codes
  end

  @doc "SIDE B part (i): every whole quoted slug literal on comment-stripped JS lines."
  @spec quoted_slugs([binary()]) :: MapSet.t()
  def quoted_slugs(js_lines) do
    js_lines
    |> Enum.flat_map(fn line ->
      Regex.scan(@quoted_re, line) |> Enum.map(fn [_, c] -> c end)
    end)
    |> MapSet.new()
  end

  @doc """
  SIDE B part (ii): the bare identifier keyset of the `var ERRORS = {` block.
  A missing block or an empty keyset is a NAMED refusal — the reader map moved,
  and pretending it is empty would mark every curated reader unread.
  """
  @spec errors_keyset([binary()]) :: MapSet.t()
  def errors_keyset(js_lines) do
    block =
      js_lines
      |> Enum.drop_while(&(not Regex.match?(@errors_open, &1)))
      |> Enum.take_while(&(not Regex.match?(@errors_close, &1)))

    if block == [] do
      raise ArgumentError,
            "ConsoleReaderCensus: the `var ERRORS = {` block was not found in app.js. " <>
              "The reader map moved or was renamed — re-teach @errors_open. " <>
              "Refusing to treat a lost ERRORS map as an empty keyset."
    end

    keys =
      block
      |> Enum.flat_map(fn line ->
        Regex.scan(@errors_key_re, line) |> Enum.map(fn [_, k] -> k end)
      end)
      |> MapSet.new()

    if MapSet.size(keys) == 0 do
      raise ArgumentError,
            "ConsoleReaderCensus: the ERRORS block was found but yielded ZERO bare keys. " <>
              "The key grammar changed — re-teach @errors_key_re rather than let " <>
              "every bare-key reader count as unread."
    end

    keys
  end

  @doc "The reconciliation: minted codes that are neither read nor classified."
  @spec unclassified(MapSet.t(), MapSet.t(), MapSet.t()) :: [binary()]
  def unclassified(emitted, read, classified) do
    emitted |> MapSet.difference(read) |> MapSet.difference(classified) |> Enum.sort()
  end

  @doc "The rot arm: classified codes that ARE read — their rows must be deleted."
  @spec rotted(MapSet.t(), MapSet.t()) :: [binary()]
  def rotted(read, classified) do
    MapSet.intersection(read, classified) |> Enum.sort()
  end

  @doc """
  THE D881 SEAL — classified rows whose reason still literally reads "READER OWED"
  (SPACE-only, case-insensitive), returned as sorted unique codes.

  A SETTLED classification names its reachability class, its disposition, and a
  flip condition; it never carries the unpaid-debt phrase "READER OWED". The
  wave-74 seal claim is that after the deploy/github payments ZERO census rows
  read it — so an empty return IS the seal, and any code returned is a proven
  reachable-dishonest survivor that owes either a curated reader (paid + rows
  deleted via the rot arm) or a reword to a settled ruling.

  The match is SPACE-only and scans the passed `.reason` strings ONLY — never the
  source file. That is load-bearing: the moduledoc's own lowercase "reader owed"
  and the HYPHENATED "reader-owed" flip phrases (the debt a code WOULD accrue if a
  callback consumer shipped, or if a rename admitted a slug) are legitimate and
  must survive. A `[\\s-]` class or a `File.read!` scan would false-red on them.
  """
  @spec reader_owed([%{optional(any) => any}]) :: [binary()]
  def reader_owed(classified) do
    classified
    |> Enum.filter(&(&1.reason =~ ~r/READER OWED/i))
    |> Enum.map(& &1.code)
    |> Enum.uniq()
    |> Enum.sort()
  end
end

defmodule BarkparkCloud.ConsoleReaderCensusTest do
  @moduledoc """
  THE WIRE-VS-READER CENSUS — every typed refusal code the control plane mints
  is either READ by the console or CLASSIFIED with a reachability ruling, and
  the boundary between those sets can only move LOUDLY (charter D867/D873,
  cloud-console-hardening wave 73, task cch-w64-bl-124-typed-wire-codes-have-no-console-reader).

  ## The defect this guards

  The plane mints far more typed refusal codes than the console reads. The
  unread remainder is NOT uniformly a defect — most are machine-tier
  (worker/agent/webhook) or CLI-only codes whose silence in app.js is honest —
  but for three waves the map separating "honest silence" from "reader owed"
  was a hand re-derivation that drifted every time it was made (waves 64, 72
  and 73 each counted a different total). This file makes the map an ENFORCED
  INVARIANT: a new unclassified code reds the Cloud gate on the PR that ships
  it, and a classified code that gains a reader reds until its rows are deleted.

  ## The shape — both sides DERIVED, assertions SET-RELATIONSHIP only

  SIDE A (minted): the comment-stripped union of error:/code: string-key
  literals over router.ex + auth.ex, re-derived every run.

  SIDE B (read): the D873 two-part rule — whole quoted slug literals on
  comment-stripped app.js lines UNION the bare identifier keyset of the
  `var ERRORS = {` block (see `BarkparkCloud.ConsoleReaderCensus` for the rule
  and its reason: bare ERRORS keys are the STANDARD reader pattern and are
  invisible to a quoted-only scan).

  THE ASSERTIONS are set relationships and nothing else:

      (minted -- read -- classified) == []     # every code is read or ruled on
      (read INTERSECT classified)    == []     # the rot arm
      (classified -- minted)         == []     # no row outlives its emitter

  NO count literal is committed anywhere in this file — both sides move with
  the tree, and a totals literal would turn every unrelated emitter PR into a
  merge conflict on a number (the shared-line collision trap).

  ## CLASSIFIED — the frozen map, one row per emit site

  `@classified` holds one `%{code, site, reason}` row per emit site, grouped in
  per-arm comment blocks and alphabetical by code within each block, so a
  round-2/3 reader diff deletes ITS OWN rows without textually colliding with a
  neighbour's. Reasons name the reachability class, the disposition, and the
  condition that would flip the ruling. Router sites are cited by FUNCTION NAME
  or route head, never line number — the deploy_not_started line-cite had
  already drifted 13923 -> 13956 inside one wave.

  ## The limit of the claim — read this before trusting a green

  This proves READERSHIP SHAPE, not copy quality. A green does NOT prove any
  reader renders a TRUE sentence, that a fallback is well-chosen, or that a
  classified route's gate is correctly tiered — it proves the map between
  minted codes and console readers is total and current. Side B counts a slug
  quoted ANYWHERE in app.js as read, so a slug quoted for an unrelated purpose
  would be a false "read" this file cannot see. And the reachability REASONS
  are rulings, not derivations: the census reds when their subject codes gain
  readers or leave the wire, but a reason whose prose goes stale without either
  happening is caught by review (the wave-73 HIGH-FLIP-RISK second-review law),
  not by this file.

  ## Mutation proof (wave 73, run before merge)

  Injecting a synthetic `error: "zz_census_mutation_probe"` emitter into
  router.ex reds the reconciliation NAMING that code; reverting restores green;
  an emptied extraction raises the named refusal instead of passing. The
  anti-vacuity tests below keep a weaker form of that proof running on every CI
  pass.
  """

  use ExUnit.Case, async: true

  alias BarkparkCloud.ConsoleReaderCensus, as: Census

  # Every compile-time/read path resolves INSIDE cloud/ (wave 69's #11723
  # docker-context lesson): this file lives at cloud/test/barkpark_cloud/, so
  # ../../ is cloud/ itself. No sibling tree outside cloud/ is read.
  @router Path.expand("../../lib/barkpark_cloud/web/router.ex", __DIR__)
  @auth Path.expand("../../lib/barkpark_cloud/web/auth.ex", __DIR__)
  @app_js Path.expand("../../priv/static/app.js", __DIR__)

  # ---------------------------------------------------------------------------
  # CLASSIFIED — the frozen reachability map. ONE row per emit site, per-arm
  # blocks, alphabetical by code within each block. A reader-adding diff DELETES
  # every row of the code it starts reading (the rot arm orders it by name).
  # Sites cite function names / route heads, never line numbers.
  # ---------------------------------------------------------------------------
  @classified [
    # ------------------------------------------------------------------ deploy arm
    # Round 2 (D874, wave 74 cch-w72-bl) PAID: deploy_not_started (curated ERRORS
    # entry, D879 copy) + instance_not_live (fifth fence slug) + no_content_binding
    # (curated ERRORS entry, D878) gained readers — their four rows were deleted
    # in the same diff, rot arm run red first.
    %{
      code: "artifact_conflict",
      site:
        "router.ex settle_deployment_artifact (POST /v1/sites/:id/deployments/:dep_id/artifact)",
      reason:
        "CLI-only: the prebuilt artifact chain is driven by bp deploy over a PAT; " <>
          "app.js has zero callers of the artifact route. A re-upload with a different " <>
          "digest is a machine-visible 409. Flip: the console grows an artifact upload."
    },
    %{
      code: "artifact_digest_mismatch",
      site:
        "router.ex receive_deployment_artifact (POST /v1/sites/:id/deployments/:dep_id/artifact)",
      reason:
        "CLI-only: bp's prebuilt upload declares a sha the received bytes must hash to; " <>
          "no console surface uploads artifacts. Flip: a console artifact upload ships."
    },
    %{
      code: "artifact_too_large",
      site:
        "router.ex receive_deployment_artifact (POST /v1/sites/:id/deployments/:dep_id/artifact)",
      reason:
        "CLI-only: size ceiling on the bp prebuilt upload path; zero app.js callers " <>
          "of the artifact route. Flip: a console artifact upload ships."
    },
    %{
      code: "build_in_progress",
      site: "router.ex promote_deployment (POST /v1/sites/:id/deployments/:dep_id/promote)",
      reason:
        "Console-reachable STATUS-READ: runPromote drives this route (the rollback/" <>
          "redeploy buttons) and promoteFailure classifies the 409 by STATUS alone " <>
          "with an honest in-flight sentence — a reader Side B cannot see, since no " <>
          "slug literal exists. Flip: a second 409 code joins the promote route " <>
          "(status-alone would then conflate two causes)."
    },
    %{
      code: "deployment_not_queued",
      site:
        "router.ex upload_deployment_artifact (POST /v1/sites/:id/deployments/:dep_id/artifact)",
      reason:
        "CLI-only: an artifact upload against a deployment no longer in queued state; " <>
          "the whole artifact chain has zero console callers. Flip: console upload ships."
    },
    %{
      code: "empty_artifact",
      site:
        "router.ex receive_deployment_artifact (POST /v1/sites/:id/deployments/:dep_id/artifact)",
      reason:
        "CLI-only: a zero-byte body on the bp prebuilt upload; zero console " <>
          "callers of the artifact route. Flip: a console artifact upload ships."
    },
    %{
      code: "invalid_cursor",
      site: "router.ex GET /v1/sites/:id/deployments",
      reason:
        "Guard-shielded from the console: app.js requests the deployments list without " <>
          "a cursor param, so only a hand-built or CLI/PAT request can send a bad one. " <>
          "Flip: console keyset pagination for deployments ships."
    },
    %{
      code: "not_prebuilt",
      site:
        "router.ex upload_deployment_artifact (POST /v1/sites/:id/deployments/:dep_id/artifact)",
      reason:
        "CLI-only: artifact upload against a deployment whose source is not prebuilt; " <>
          "zero console callers of the artifact chain. Flip: console upload ships."
    },
    %{
      code: "prebuilt_not_enabled",
      site: "router.ex deploy_static_site (POST /v1/sites/:id/deploy)",
      reason:
        "CLI-only (relabeled D878, wave 74): the arm keys on request-body `source`, " <>
          "and NO console deploy caller sends one — runDeploy ships {git_ref}, " <>
          "createAndDeploy ships {} — so the default box-build never resolves to " <>
          "prebuilt from the console. Flip: a console UI that starts sending source."
    },
    %{
      code: "unknown_source",
      site: "router.ex deploy_static_site (POST /v1/sites/:id/deploy)",
      reason:
        "CLI-only (relabeled D878, wave 74): the arm keys on request-body `source` " <>
          "(default \"box-build\" when absent, always in Registry.Deployment.sources()), " <>
          "and NO console deploy caller sends one — runDeploy ships {git_ref}, " <>
          "createAndDeploy ships {}. Only a CLI/PAT or hand-built request can carry an " <>
          "unrecognized source. Flip: a console UI that starts sending source."
    },
    %{
      code: "upload_failed",
      site:
        "router.ex receive_deployment_artifact (POST /v1/sites/:id/deployments/:dep_id/artifact)",
      reason:
        "CLI-only: storage-side write failure on the bp prebuilt upload; zero console " <>
          "callers of the artifact route. Flip: a console artifact upload ships."
    },

    # ------------------------------------------------------------------ github arm
    # Round 3 (D883, wave 75) PAID repo_not_in_installation — its fallback was a
    # measured transience lie, so it gained the curated ERRORS reader and its row
    # was deleted (rot arm ran red first). github_error stays CLASSIFICATION-STANDS:
    # its three sites are all admin-gated at the console and its fallbacks overclaim
    # nothing (the slug is genuinely ambiguous). The zero-caller / guard-shield
    # classifications below stay until their flip conditions fire.
    %{
      code: "github_error",
      site: "router.ex GET /v1/github/repos",
      reason:
        "Classification stands (D883): the route is require_user, but the ONLY " <>
          "console affordance that calls it is the #site-github button, rendered " <>
          "solely for authority===\"grant\" (admin) — a member never reaches this " <>
          "emit from the console, and the admin reader (openSiteGithub) renders the " <>
          "caller fallback \"Couldn't load your repositories.\" github_error is " <>
          "genuinely ambiguous (outage, rate-limit, and token-death are " <>
          "indistinguishable at the emit), so that fallback overclaims no cause and " <>
          "paints nothing permanent. Flip: github_error gains an ERRORS key OR a " <>
          "member console affordance to GET /v1/github/repos ships."
    },
    %{
      code: "github_error",
      site: "router.ex POST /v1/github/repos (create_repo_from_template github_error 502)",
      reason:
        "Classification stands (D883): admin-gated (require_team_admin) create-repo " <>
          "path; the console newCreateRepo reader renders its caller fallback " <>
          "\"Please try again.\" The slug is the same genuinely-ambiguous upstream " <>
          "verdict (outage/rate-limit/token-death indistinguishable), so the fallback " <>
          "overclaims nothing. NOT the vercel_reason 502 route — it is minted bare in " <>
          "the create_repo_from_template case arm. Flip: github_error gains an ERRORS " <>
          "key OR a member affordance to GET /v1/github/repos ships."
    },
    %{
      code: "github_error",
      site: "router.ex connect_site_github",
      reason:
        "Classification stands (D883): admin-gated (require_team_admin) connect-flow " <>
          "site of the same slug; the submitSiteGithub reader renders its caller " <>
          "fallback \"Please try again.\" github_error is genuinely ambiguous " <>
          "(outage/rate-limit/token-death indistinguishable at the emit), so the " <>
          "fallback overclaims no cause and paints nothing permanent. Flip: " <>
          "github_error gains an ERRORS key OR a member affordance to GET " <>
          "/v1/github/repos ships."
    },
    %{
      code: "installation_id_required",
      site: "router.ex POST /v1/github/installations",
      reason:
        "Unreachable from every shipped surface: zero callers of the installations " <>
          "route in app.js, internal/, or js/ (w73 zero-caller proof), because no " <>
          "GitHub App setup_action callback consumer was ever built. Flip: the " <>
          "callback consumer ships (cch-w73-bl-github-install-callback-loop-open)."
    },
    %{
      code: "installation_not_found",
      site: "router.ex POST /v1/github/installations",
      reason:
        "Unreachable from every shipped surface: same zero-caller proof as its " <>
          "sibling — no App-install callback consumer exists, no setup_action route, " <>
          "no installation_id reader anywhere. Conditioned on that absence. Flip: a " <>
          "callback consumer ships and this becomes a reader-owed row."
    },
    %{
      code: "invalid_name",
      site: "router.ex POST /v1/github/repos (bare 422 pre-check, not valid_repo_name?)",
      reason:
        "Classification stands (D883): admin-gated (require_team_admin) new-repo path; " <>
          "the router's OWN valid_repo_name? pre-check mints this bare 422 (NOT the " <>
          "vercel_reason 502 route), and newCreateRepo renders its caller fallback " <>
          "\"Please try again.\" — an honest, non-permanent sentence for a name the " <>
          "console form fed through its own input. Flip: a wave rules per-slug copy owed."
    },
    %{
      code: "repo_full_name_required",
      site: "router.ex connect_site_github",
      reason:
        "Guard-shielded: the console connect select is built only when repos.length " <>
          "is nonzero and always submits a member of it; no CLI/SDK caller sends the " <>
          "connect body at all. Flip: a caller that can submit an empty full_name ships."
    },
    # repo_not_in_installation was PAID in Round 3 (D883, wave 75): its fallback
    # ("Please try again.") was a transience lie on a permanent-until-regranted
    # state, so it gained the curated ERRORS reader
    # ("GitHub's app can no longer see that repository — grant it access on GitHub,
    # then reconnect.") and this row was deleted in the same diff. The rot arm
    # asserts the deletion — a stray row here would red the moment the reader shipped.
    %{
      code: "repo_required",
      site: "router.ex POST /v1/sites/:id/github",
      reason:
        "Guard-shielded: the console github card submits the repo chosen in its own " <>
          "picker, never an empty body; only a hand-built request omits repo. Flip: " <>
          "a caller that can submit without a repo ships."
    },
    %{
      code: "unknown_template",
      site: "router.ex POST /v1/github/repos (bare 422 / create_repo_from_template)",
      reason:
        "Classification stands (D883): guard-shielded TOCTOU on the admin create-repo " <>
          "path; the template is chosen from the server's own list and this bare 422 " <>
          "is minted by the router's own pre-check / the create_repo_from_template " <>
          "case arm (NOT the vercel_reason 502 route). Only a template removed between " <>
          "list and submit (or a raw request) mints it, and newCreateRepo renders its " <>
          "caller fallback \"Please try again.\" Flip: templates become mutable at a " <>
          "cadence where the race is measured in the wild."
    },
    %{
      code: "unknown_template",
      site: "router.ex go_live (POST /v1/launch)",
      reason:
        "Guard-shielded TOCTOU sibling on the launch path: the console launch flow " <>
          "submits a template it just listed from /v1/templates. A reader for this " <>
          "slug would have to be true at BOTH emit sites (the rot arm couples them)."
    },

    # ------------------------------------------------------------------ domains arm
    # The read half of this arm (instance_no_origin, domain_not_pointed,
    # invalid_domain, taken, already_attaching) is Side-B read and needs no rows.
    %{
      code: "cloudflare_bind_failed",
      site: "router.ex do_bind_cloudflare (deploy path via maybe_bind_cloudflare)",
      reason:
        "Console-UNREACHABLE today: no console deploy body sets `via` (runDeploy ships " <>
          "{git_ref}, createAndDeploy {}), so maybe_bind_cloudflare short-circuits " <>
          "{:cont} and this arm never fires. Were it to, do_bind_cloudflare's 502 " <>
          "returns on the SYNCHRONOUS POST /v1/sites/:id/deploy response — before any " <>
          "deployment row is minted — so runDeploy's non-201 branch paints the deploy " <>
          "caller's fallback (friendly), NOT the async deployRefusalCopy rail. Flip: a " <>
          "console domain-binding UI starts sending via."
    },
    %{
      code: "cloudflare_credential_unreadable",
      site: "router.ex bind_cloudflare",
      reason:
        "Console-UNREACHABLE today: no console deploy body sets `via`, so " <>
          "maybe_bind_cloudflare returns {:cont} and bind_cloudflare's credential " <>
          "fail-closed 409 never fires from the console. It surfaces on the SYNCHRONOUS " <>
          "POST /v1/sites/:id/deploy response (a plug step halting before any deployment " <>
          "row), where the deploy caller's fallback renders — deployRefusalCopy never " <>
          "sees it. Flip: a console provider/domain UI starts sending via."
    },
    %{
      code: "cloudflare_domain_required",
      site: "router.ex maybe_bind_cloudflare",
      reason:
        "Console-UNREACHABLE today: maybe_bind_cloudflare only reaches this 422 when " <>
          "`via` == \"cloudflare\", and no console deploy body sets via (runDeploy " <>
          "{git_ref}, createAndDeploy {}). It returns on the SYNCHRONOUS deploy response " <>
          "before any deployment row is minted, so the deploy caller's fallback renders, " <>
          "not the async deployRefusalCopy rail. Flip: a console UI starts sending via."
    },
    %{
      code: "cloudflare_orphan_cleanup_failed",
      site: "router.ex do_bind_cloudflare (orphan_guard, the post-write box-liveness re-check)",
      reason:
        "Console-UNREACHABLE today, same fence as cloudflare_bind_failed: no console " <>
          "deploy body sets `via`, so maybe_bind_cloudflare short-circuits {:cont} and " <>
          "orphan_guard never runs from the console. Were it to: this 502 is the " <>
          "honesty-edge case where the box was deprovisioned mid-write AND the cleanup " <>
          "delete of the record just written also failed — the SYNCHRONOUS POST " <>
          "/v1/sites/:id/deploy response, before any deployment row is minted, so " <>
          "runDeploy's non-201 branch paints the deploy caller's generic fallback, not " <>
          "the async deployRefusalCopy rail. Its sibling 409 (the cleanup delete " <>
          "SUCCEEDING) reuses instance_not_live, already read. Flip: a console " <>
          "domain-binding UI starts sending via."
    },
    %{
      code: "cloudflare_zone_missing",
      site: "router.ex bind_cloudflare",
      reason:
        "Console-UNREACHABLE today: no console deploy body sets `via`, so " <>
          "bind_cloudflare's zone-missing 422 never fires from the console. It surfaces " <>
          "on the SYNCHRONOUS POST /v1/sites/:id/deploy response ahead of any minted " <>
          "deployment row — the deploy caller's fallback renders, never the async " <>
          "deployRefusalCopy rail. Flip: a console UI starts sending via."
    },
    %{
      code: "domain_required",
      site: "router.ex POST /v1/barkparks/:id/domain (success arm calls attach_custom_domain)",
      reason:
        "Modal-guard-shielded: the console attach-domain modal refuses to submit an " <>
          "empty input (the guard comment ships beside the modal), so only a raw " <>
          "request reaches this 422. Flip: the modal guard is removed or bypassed."
    },
    %{
      code: "domain_required",
      site: "router.ex POST /v1/sites/:id/domains",
      reason:
        "CLI-only sibling site: the sites-domains route has zero app.js callers — " <>
          "site domain attach is a bp verb today. Flip: a console site-domain form " <>
          "ships and starts submitting this route."
    },
    %{
      code: "domain_taken",
      site: "router.ex POST /v1/sites/:id/domains",
      reason:
        "CLI-only: same zero-console-caller route as its sibling row; the CLI renders " <>
          "the slug in its own dialect. Flip: a console site-domain form ships."
    },
    %{
      code: "no_cloudflare_provider",
      site: "router.ex bind_cloudflare",
      reason:
        "Console-UNREACHABLE today: no console deploy body sets `via`, so " <>
          "bind_cloudflare's no-provider 409 never fires from the console. It returns on " <>
          "the SYNCHRONOUS deploy response — maybe_bind_cloudflare halts before any " <>
          "deployment row — so the deploy caller's fallback renders, not the async " <>
          "deployRefusalCopy rail. Flip: a console provider-connect UI starts sending via."
    },

    # ------------------------------------------------------------------ fleet-support arm
    # cch-w72-bl-add-support-reachability-unpinned closes against these rows.
    %{
      code: "already_provisioning",
      site: "router.ex do_fleet_provision_support",
      reason:
        "Console-reachable race arm: a second add-support provision while the first " <>
          "job is in flight is a 409 only a duplicate submit can mint; renders the " <>
          "add-support card's fallback copy. Flip: measured in the wild as confusing."
    },
    %{
      code: "invalid_parent",
      site: "router.ex POST /v1/fleet/supports (register-only mode)",
      reason:
        "CLI-only at this site: bp cloud support add always sends parent_id, and the " <>
          "console add-support card takes the provision path, not register-only. " <>
          "Flip: the console starts registering supports without provisioning."
    },
    %{
      code: "invalid_parent",
      site: "router.ex fleet_provision_support",
      reason:
        "Raw-API-only at this site: submitAddSupport only ever sends a MAIN's id " <>
          "because the add-support card filters support rows out via the isSupportBp " <>
          "guard — a support-as-parent needs a hand-built request. Flip: the picker " <>
          "starts offering support rows (w73 second-review pin)."
    },
    %{
      code: "not_a_support",
      site: "router.ex DELETE /v1/fleet/supports/:id",
      reason:
        "CLI-only: zero console DELETE /v1/fleet/supports call sites exist in app.js " <>
          "(w73 zero-caller sweep) — support removal is a bp verb. Flip: a console " <>
          "remove-support control ships and this needs a reader ruling."
    },

    # ------------------------------------------------------------------ worker-agent mass
    # Machine tiers: require_worker matches the shared WORKER_TOKEN, require_agent
    # an agent credential, the builder token its own secret, and the webhook
    # routes verify an HMAC. No human browser session satisfies any of them, so
    # every row's flip condition is the same: the route's tier changes.
    %{
      code: "bad_signature",
      site: "router.ex POST /v1/webhooks/github/:site_id",
      reason:
        "Machine-only: GitHub is the caller and the refusal is an HMAC verdict on " <>
          "its payload; no console surface posts webhooks. Flip: route re-tiered."
    },
    %{
      code: "bad_signature",
      site: "router.ex POST /v1/sites/webhooks/content-publish/:site_id",
      reason:
        "Machine-only: the content-publish webhook is signed by the instance and " <>
          "verified here; a human never posts it. Flip: route re-tiered."
    },
    %{
      code: "bad_signature",
      site: "router.ex POST /v1/relay/chat-blocked/:barkpark_id",
      reason:
        "Machine-only: the chat-blocked relay is instance-signed; the console never " <>
          "posts relay events. Flip: route re-tiered."
    },
    %{
      code: "claim_token_required",
      site: "router.ex POST /v1/internal/warm-servers/:name/refreshed",
      reason:
        "Machine-only: /v1/internal/* is require_worker (shared WORKER_TOKEN held by " <>
          "the provisioner, never by an account). Flip: route re-tiered."
    },
    %{
      code: "conflict",
      site: "router.ex POST /v1/internal/provision-jobs/:id/succeed",
      reason:
        "Machine-only: require_worker job-settle route; a terminal-state 409 is the " <>
          "provisioner's own protocol answer. Flip: route re-tiered."
    },
    %{
      code: "conflict",
      site: "router.ex POST /v1/internal/provision-jobs/:id/fail",
      reason:
        "Machine-only: require_worker job-settle sibling; same terminal-state 409 " <>
          "protocol answer to the provisioner. Flip: route re-tiered."
    },
    %{
      code: "conflict",
      site: "router.ex POST /v1/internal/provision-jobs/:id/release",
      reason:
        "Machine-only: require_worker claim-release sibling; protocol answer to the " <>
          "provisioner, no human surface. Flip: route re-tiered."
    },
    %{
      code: "conflict",
      site: "router.ex POST /v1/internal/deprovision-jobs/:id/succeed",
      reason:
        "Machine-only: require_worker deprovision-settle route; provisioner protocol " <>
          "answer. Flip: route re-tiered."
    },
    %{
      code: "conflict",
      site: "router.ex POST /v1/internal/deprovision-jobs/:id/fail",
      reason:
        "Machine-only: require_worker deprovision-settle sibling; provisioner " <>
          "protocol answer. Flip: route re-tiered."
    },
    %{
      code: "conflict",
      site: "router.ex POST /v1/internal/attach-domain-jobs/:id/succeed",
      reason:
        "Machine-only: require_worker attach-domain-settle route; provisioner " <>
          "protocol answer. Flip: route re-tiered."
    },
    %{
      code: "conflict",
      site: "router.ex POST /v1/internal/attach-domain-jobs/:id/fail",
      reason:
        "Machine-only: require_worker attach-domain-settle sibling; provisioner " <>
          "protocol answer. Flip: route re-tiered."
    },
    %{
      code: "deliveries_required",
      site: "router.ex POST /v1/internal/platform-deliveries",
      reason:
        "Machine-only: require_worker CI-reporter route recording platform deploy " <>
          "deliveries; no human caller. Flip: route re-tiered."
    },
    %{
      code: "illegal_transition",
      site: "router.ex POST /v1/builder/deployments/:id/transition",
      reason:
        "Machine-only: the builder token drives the deploy state machine; an illegal " <>
          "edge is a builder-protocol answer. Flip: route re-tiered."
    },
    %{
      code: "illegal_transition",
      site: "router.ex POST /v1/agent/deployments/:id/transition",
      reason:
        "Machine-only: require_agent twin of the builder transition route; same " <>
          "protocol answer to the agent runtime. Flip: route re-tiered."
    },
    %{
      code: "invalid_payload",
      site: "router.ex POST /v1/relay/chat-blocked/:barkpark_id",
      reason:
        "Machine-only: instance-signed relay route; a malformed relay body is the " <>
          "instance's protocol answer, never a person's. Flip: route re-tiered."
    },
    %{
      code: "invalid_row",
      site: "router.ex POST /v1/internal/platform-deliveries",
      reason:
        "Machine-only: require_worker CI-reporter payload validation, per-row; no " <>
          "human caller exists. Flip: route re-tiered."
    },
    %{
      code: "invalid_signature",
      site: "router.ex POST /v1/billing/webhook",
      reason:
        "Machine-only: Stripe is the caller and the refusal is a signature verdict " <>
          "on its event; the console never posts billing webhooks. Flip: re-tiered."
    },
    %{
      code: "invalid_step",
      site: "router.ex POST /v1/internal/provision-jobs/:id/step",
      reason:
        "Machine-only: require_worker step-progress route; a bad step name is the " <>
          "provisioner's own bug surfacing to itself. Flip: route re-tiered."
    },
    %{
      code: "invalid_webhook",
      site: "router.ex POST /v1/billing/webhook",
      reason:
        "Machine-only: Stripe-facing parse refusal on the billing webhook route; no " <>
          "human surface posts it. Flip: route re-tiered."
    },
    %{
      code: "invalid_window",
      site: "router.ex GET /v1/operator/deploy-ledger/census",
      reason:
        "Operator-tier: gated on the platform-admin allowlist (charter D30's " <>
          "permanent human gate) and read by the Go client, not app.js. Flip: a " <>
          "console operator census view ships."
    },
    %{
      code: "invalid_window",
      site: "router.ex GET /v1/deploy-ledger/census",
      reason:
        "CLI-only sibling: the team-scoped census is the Go client's read " <>
          "(FleetDeployCensus); app.js never requests the deploy-ledger census. " <>
          "Flip: a console deploy-health view ships."
    },
    %{
      code: "ip_required",
      site: "router.ex POST /v1/internal/provision-jobs/:id/succeed",
      reason:
        "Machine-only: require_worker settle payload validation — the provisioner " <>
          "must report the box IP; no human caller. Flip: route re-tiered."
    },
    %{
      code: "method_not_allowed",
      site: "router.ex refuse_head_on_side_effecting_gets",
      reason:
        "Probe-only: a 405 minted exclusively for HEAD requests against " <>
          "side-effecting GETs; browsers' fetch paths here never issue HEAD — " <>
          "monitors and crawlers do. Flip: the console starts preflighting with HEAD."
    },
    %{
      code: "no_pending",
      site: "router.ex POST /v1/agent/deployments/claim",
      reason:
        "Machine-only: require_agent claim route; an empty queue is the agent " <>
          "runtime's normal poll answer. Flip: route re-tiered."
    },
    %{
      code: "no_queued",
      site: "router.ex POST /v1/builder/claim",
      reason:
        "Machine-only: builder-token claim route; an empty queue is the builder's " <>
          "normal poll answer. Flip: route re-tiered."
    },
    %{
      code: "null_column",
      site: "router.ex POST /v1/internal/platform-deliveries",
      reason:
        "Machine-only: require_worker CI-reporter constraint surface; a nulled " <>
          "column is the reporter's own payload bug. Flip: route re-tiered."
    },
    %{
      code: "observed_epoch_required",
      site: "router.ex POST /v1/builder/deployments/:id/transition",
      reason:
        "Machine-only: builder transition CAS payload validation; protocol answer " <>
          "to the builder. Flip: route re-tiered."
    },
    %{
      code: "observed_epoch_required",
      site: "router.ex POST /v1/agent/deployments/:id/transition",
      reason:
        "Machine-only: require_agent twin of the builder CAS validation; protocol " <>
          "answer to the agent runtime. Flip: route re-tiered."
    },
    %{
      code: "read_failed",
      site: "router.ex GET /v1/deliveries",
      reason:
        "CLI/PAT/worker-only: require_user_or_pat_or_worker + read ability, and " <>
          "app.js never calls the platform-deliveries read (it reads " <>
          "/v1/notifications/deliveries, a different route). The worker principal " <>
          "added by task-e2acb66e9ed0da09 is a CI reader, not a browser, so it does " <>
          "not make this code console-reachable. Flip: a console " <>
          "platform-deliveries view ships."
    },
    %{
      code: "record_failed",
      site: "router.ex POST /v1/internal/platform-deliveries",
      reason:
        "Machine-only: require_worker CI-reporter write failure (500-class); the " <>
          "reporter retries, no human sees it. Flip: route re-tiered."
    },
    %{
      code: "secret_unreadable",
      site: "router.ex POST /v1/webhooks/github/:site_id",
      reason:
        "Machine-only: the stored webhook secret failed to decrypt while verifying " <>
          "GitHub's delivery — surfaced to the webhook caller, not a person. Flip: " <>
          "route re-tiered."
    },
    %{
      code: "secret_unreadable",
      site: "router.ex POST /v1/sites/webhooks/content-publish/:site_id",
      reason:
        "Machine-only: decrypt failure on the content-publish webhook's secret; " <>
          "answered to the instance caller. Flip: route re-tiered."
    },
    %{
      code: "secret_unreadable",
      site: "router.ex POST /v1/relay/chat-blocked/:barkpark_id",
      reason:
        "Machine-only: decrypt failure on the relay route's secret; answered to the " <>
          "instance caller. Flip: route re-tiered."
    },
    %{
      code: "stale_claim",
      site: "router.ex POST /v1/internal/provision-jobs/:id/succeed",
      reason:
        "Machine-only: require_worker claim-epoch CAS refusal; provisioner protocol " <>
          "answer. Flip: route re-tiered."
    },
    %{
      code: "stale_claim",
      site: "router.ex POST /v1/internal/provision-jobs/:id/fail",
      reason:
        "Machine-only: require_worker CAS refusal, fail-settle sibling. Flip: " <>
          "route re-tiered."
    },
    %{
      code: "stale_claim",
      site: "router.ex POST /v1/internal/provision-jobs/:id/release",
      reason:
        "Machine-only: require_worker CAS refusal, release sibling. Flip: route " <>
          "re-tiered."
    },
    %{
      code: "stale_claim",
      site: "router.ex POST /v1/internal/deprovision-jobs/:id/succeed",
      reason:
        "Machine-only: require_worker CAS refusal on deprovision settle. Flip: " <>
          "route re-tiered."
    },
    %{
      code: "stale_claim",
      site: "router.ex POST /v1/internal/deprovision-jobs/:id/fail",
      reason:
        "Machine-only: require_worker CAS refusal, deprovision fail sibling. Flip: " <>
          "route re-tiered."
    },
    %{
      code: "stale_claim",
      site: "router.ex POST /v1/internal/attach-domain-jobs/:id/succeed",
      reason:
        "Machine-only: require_worker CAS refusal on attach-domain settle. Flip: " <>
          "route re-tiered."
    },
    %{
      code: "stale_claim",
      site: "router.ex POST /v1/internal/attach-domain-jobs/:id/fail",
      reason:
        "Machine-only: require_worker CAS refusal, attach-domain fail sibling. " <>
          "Flip: route re-tiered."
    },
    %{
      code: "stale_epoch",
      site: "router.ex POST /v1/builder/deployments/:id/transition",
      reason:
        "Machine-only: builder CAS refusal on the deploy state machine; protocol " <>
          "answer to the builder. Flip: route re-tiered."
    },
    %{
      code: "stale_epoch",
      site: "router.ex POST /v1/agent/deployments/:id/transition",
      reason:
        "Machine-only: require_agent CAS twin; protocol answer to the agent " <>
          "runtime. Flip: route re-tiered."
    },
    %{
      code: "team_id_required",
      site: "router.ex POST /v1/internal/barkparks",
      reason:
        "Machine-only: require_worker internal registration route; payload " <>
          "validation answered to the provisioner. Flip: route re-tiered."
    },
    %{
      code: "worker_id_required",
      site: "router.ex POST /v1/builder/claim",
      reason:
        "Machine-only: builder claim payload validation; protocol answer to the " <>
          "builder fleet. Flip: route re-tiered."
    },
    %{
      code: "worker_id_required",
      site: "router.ex POST /v1/builder/deployments/:id/transition",
      reason:
        "Machine-only: builder transition payload validation sibling. Flip: route " <>
          "re-tiered."
    },
    %{
      code: "worker_id_required",
      site: "router.ex POST /v1/agent/deployments/claim",
      reason:
        "Machine-only: require_agent claim payload validation twin. Flip: route " <>
          "re-tiered."
    },
    %{
      code: "worker_id_required",
      site: "router.ex POST /v1/agent/deployments/:id/transition",
      reason:
        "Machine-only: require_agent transition payload validation twin. Flip: " <>
          "route re-tiered."
    },

    # ------------------------------------------------------------------ auth + billing
    %{
      code: "accept_failed",
      site: "router.ex POST /v1/invitations/accept",
      reason:
        "Console-reachable changeset residue on the invite-accept page; renders the " <>
          "accept caller's fallback copy — honest but unspecific. Flip: a wave " <>
          "measures the arm and rules per-slug copy owed."
    },
    %{
      code: "cancel_failed",
      site: "router.ex POST /v1/billing/cancel",
      reason:
        "Console-reachable upstream-billing fault: the cancel call ships reason: " <>
          "inspect(reason), which the D855 fence law refuses to relay; the billing " <>
          "caller's fallback renders. Flip: a wave rules a curated cancel-fault arm."
    },
    %{
      code: "email_mismatch",
      site: "router.ex POST /v1/invitations/accept",
      reason:
        "Console-reachable STATUS-READ: submitInviteAccept routes every non-200 through " <>
          "inviteTerminalFrom, whose `if (status === 403) return \"wrong_account\"` arm " <>
          "paints the dedicated wrong-email card ('This invitation is for a different " <>
          "email… Sign in with the invited address') — 403 is the accept route's SOLE " <>
          "403 arm, so the status is the reader, never the slug. Flip: a second 403 arm " <>
          "joins the route."
    },
    %{
      code: "email_required",
      site: "router.ex POST /v1/teams/:id/invitations",
      reason:
        "Guard-shielded: the invite form does not submit an empty email, so only a " <>
          "raw request mints this; the wave-72 curated invitation arm covers the " <>
          "reachable refusals. Flip: the form guard is removed."
    },
    %{
      code: "expired_or_invalid",
      site: "router.ex POST /v1/auth/device/poll",
      reason:
        "CLI-only at this site: the device poll loop is bp login's transport; the " <>
          "console never polls. Flip: the console gains a polling flow."
    },
    %{
      code: "expired_or_invalid",
      site: "router.ex POST /v1/auth/device/inspect",
      reason:
        "Console-reachable but STATUS-KEYED: the /activate page keys on the 404 " <>
          "status and renders its designed terminal state, never the slug — an " <>
          "honest reader that Side B cannot see because it reads no literal. Flip: " <>
          "the page starts keying on the body."
    },
    %{
      code: "expired_or_invalid",
      site: "router.ex POST /v1/auth/device/approve",
      reason:
        "Console-reachable but STATUS-KEYED: approve/deny key on r.status 404 and " <>
          "render the gone state — the same honest status-read as inspect. Flip: " <>
          "the handler starts keying on the body."
    },
    %{
      code: "invalid_or_expired",
      site: "router.ex GET /v1/invitations/:token",
      reason:
        "Console-reachable: the invite landing read for a dead token; the landing " <>
          "renders its designed dead-invite state via the caller's handling. Flip: " <>
          "a wave measures the paint and rules otherwise."
    },
    %{
      code: "invalid_or_expired",
      site: "router.ex POST /v1/invitations/accept",
      reason:
        "Console-reachable sibling on the accept submit; same dead-token state, " <>
          "same caller handling. A reader for this slug must be true at both sites."
    },
    %{
      code: "invalid_role",
      site: "router.ex POST /v1/teams/:id/invitations",
      reason:
        "Guard-shielded: the invite role comes from a fixed picker; only a raw " <>
          "request submits an unknown role. Flip: roles become free-text or the " <>
          "picker drifts from the server's set."
    },
    %{
      code: "invalid_role",
      site: "router.ex PATCH /v1/teams/:id/members/:user_id",
      reason:
        "Guard-shielded sibling on the member-role change; same fixed picker " <>
          "shield, same raw-request remainder. Flip: picker drift."
    },
    %{
      code: "invalid_token",
      site: "router.ex POST /v1/auth/reset",
      reason:
        "Console-reachable: a stale emailed reset token submitted from the reset " <>
          "form; the form caller's fallback renders. Flip: a wave rules the " <>
          "expired-link sentence owed (a strong curated-copy candidate)."
    },
    %{
      code: "invalid_token",
      site: "router.ex POST /v1/auth/verify-email",
      reason:
        "Email-link flow, no app.js caller: verify-email is driven from the mailed " <>
          "link's landing, not the SPA. Flip: the SPA claims the verify flow."
    },
    %{
      code: "locked",
      site: "router.ex POST /v1/account/email/confirm",
      reason:
        "No console caller: app.js never calls the email-confirm route (no " <>
          "account/email literal exists) — the flow is CLI/raw-API today. Flip: the " <>
          "console grows an email-change confirm step."
    },
    %{
      code: "no_pending_email",
      site: "router.ex POST /v1/account/email/confirm",
      reason:
        "No console caller: same route as its sibling row — confirm without a " <>
          "pending change is a raw-API state. Flip: console email-change ships."
    },
    %{
      code: "provider_not_enabled",
      site: "router.ex GET /v1/auth/oauth/:provider",
      reason:
        "Guard-shielded: the login page only offers providers listed by " <>
          "/v1/auth/oauth/providers; a disabled provider needs a hand-typed URL. " <>
          "Flip: the list and the gate drift apart."
    },
    %{
      code: "recipient_not_member",
      site: "router.ex test_email (POST /v1/notifications/test)",
      reason:
        "Console-reachable: the notifications test-send refuses a recipient outside " <>
          "the team; renders the test caller's fallback copy. Flip: a wave rules " <>
          "the not-a-member sentence owed."
    },
    %{
      code: "send_failed",
      site: "router.ex test_email (POST /v1/notifications/test)",
      reason:
        "Console-reachable 502-class upstream mail fault; the 5xx honesty law " <>
          "renders the server-fault sentence, which is the true one. Flip: a wave " <>
          "rules mail-specific copy owed."
    },
    %{
      code: "slow_down",
      site: "router.ex POST /v1/auth/device/poll",
      reason:
        "CLI-only: the poll pacing answer belongs to bp login's loop; the console " <>
          "never polls the device route. Flip: a console polling flow ships."
    },
    %{
      code: "ticket_mint_failed",
      site: "router.ex POST /v1/auth/sse-ticket",
      reason:
        "Console-reachable 500-class fault while minting the SSE ticket; the 5xx " <>
          "honesty law renders the server-fault sentence — honest. Flip: a wave " <>
          "rules events-specific copy owed."
    },

    # ------------------------------------------------------------------ misc / instance
    %{
      code: "already_provisioning",
      site: "router.ex POST /v1/barkparks/:id/retry",
      reason:
        "Console-reachable race arm: Retry while a provision job is already in " <>
          "flight is a 409 the retry button can mint on a double-click; the retry " <>
          "caller's fallback renders. Flip: measured as confusing in the wild."
    },
    %{
      code: "app_token_unsupported",
      site: "router.ex POST /v1/barkparks/:id/app-token (instance_deprovisioning? guard family)",
      reason:
        "Console-reachable capability gap: an instance too old to mint app tokens; " <>
          "the studio-link caller's fallback renders. Flip: a wave rules an " <>
          "update-your-instance sentence owed."
    },
    %{
      code: "bad_action",
      site: "router.ex handle_onboarding_action (POST /v1/onboarding)",
      reason:
        "Guard-shielded: the console onboarding submits fixed action verbs; an " <>
          "unknown action is a raw-request state. Flip: onboarding actions drift " <>
          "between client and server."
    },
    %{
      code: "catalog_unavailable",
      site: "router.ex with_provider_catalog",
      reason:
        "Console-reachable upstream fault: the provider catalog fetch failed; the " <>
          "5xx honesty law renders the server-fault sentence — honest. Flip: a " <>
          "wave rules provider-specific copy owed."
    },
    %{
      code: "enqueue_failed",
      site: "router.ex do_resurrect",
      reason:
        "Console-reachable 500-class fault enqueuing the resurrect job; the 5xx " <>
          "honesty law renders the server-fault sentence. Flip: a wave rules " <>
          "resurrect-specific copy owed."
    },
    %{
      code: "env_required",
      site: "router.ex POST /v1/sites/:id/env",
      reason:
        "Guard-shielded: the console env editor always submits the env field; an " <>
          "absent body is a raw-request state. Flip: the editor stops sending the " <>
          "field or a bodyless caller ships."
    },
    %{
      code: "instance_rate_limited",
      site: "router.ex revoke_app_token_on_instance",
      reason:
        "Console-reachable relay of the instance's own limiter during token " <>
          "revoke; the revoke caller's fallback renders. Flip: a wave rules a " <>
          "try-again-shortly sentence owed."
    },
    %{
      code: "instance_refused",
      site: "router.ex POST /v1/barkparks/:id/push-relay",
      reason:
        "CLI-only: the push-relay route has zero app.js callers — relay setup is " <>
          "a bp verb today. Flip: a console push-relay control ships."
    },
    %{
      code: "invalid_bundle_ref",
      site: "router.ex resurrect (POST /v1/resurrect)",
      reason:
        "Guard-shielded TOCTOU: the console resurrect submits a bundle ref from " <>
          "its own archives list; only a vanished archive or raw request mints " <>
          "this. Flip: archives become mutable under the picker."
    },
    %{
      code: "invalid_provider",
      site: "router.ex go_live (POST /v1/launch)",
      reason:
        "Guard-shielded: the launch flow submits a provider from /v1/providers; " <>
          "an unknown provider is a raw-request state. Flip: provider list and " <>
          "gate drift."
    },
    %{
      code: "invalid_provider",
      site: "router.ex resurrect (POST /v1/resurrect)",
      reason:
        "Guard-shielded sibling on the resurrect path; same listed-provider " <>
          "shield. A reader must be true at both sites (rot arm couples them)."
    },
    %{
      code: "invalid_settings",
      site: "router.ex PATCH /v1/sites/:id",
      reason:
        "Effectively guard-shielded: the only console PATCH /v1/sites/:id caller is the " <>
          "theme select, which submits siteThemePatchBody(val) for a member of the fixed " <>
          "SITE_THEMES list, so the changeset never fails; and were it to, the map ships " <>
          "under SINGULAR `detail` (errors(cs)) which no friendly() rung reads — the " <>
          "details rung is plural and the string-fence requires a string. Flip: a rename " <>
          "to details or a fence admission — then this becomes reader-owed."
    },
    %{
      code: "invalid_url",
      site: "router.ex POST /v1/barkparks/:id/site-url (instance_deprovisioning? guard family)",
      reason:
        "Console-reachable: the site-url form submits a URL the server judges " <>
          "malformed; the form caller's fallback renders. Flip: a wave rules a " <>
          "what-a-valid-url-is sentence owed."
    },
    %{
      code: "no_archives",
      site: "router.ex resurrect (POST /v1/resurrect)",
      reason:
        "Guard-shielded TOCTOU: the console offers resurrect against its own " <>
          "archives list; an empty vault at submit time is a race or a raw " <>
          "request. Flip: measured in the wild."
    },
    %{
      code: "no_bootstrap",
      site: "router.ex POST /v1/barkparks/:id/site-url",
      reason:
        "Console-reachable capability gap: an instance without the bootstrap " <>
          "capability refuses the site-url write; the caller's fallback renders. " <>
          "Flip: a wave rules an update-your-instance sentence owed."
    },
    %{
      code: "no_bootstrap",
      site: "router.ex GET /v1/barkparks/:id/bootstrap",
      reason:
        "Console-reachable sibling on the bootstrap read; same capability gap, " <>
          "same fallback render. A reader must be true at all three sites."
    },
    %{
      code: "no_bootstrap",
      site: "router.ex POST /v1/barkparks/:id/vercel-deploy",
      reason:
        "Console-reachable sibling on the vercel-deploy path; same capability " <>
          "gap. The rot arm couples all three rows to any future reader."
    },
    %{
      code: "no_webhook",
      site: "router.ex POST /v1/barkparks/:id/site-url",
      reason:
        "Console-reachable capability gap: the instance exposes no webhook " <>
          "capability for the site-url flow; the caller's fallback renders. Flip: " <>
          "a wave rules capability-gap copy owed."
    },
    %{
      code: "not_deployable",
      site: "router.ex POST /v1/barkparks/:id/vercel-deploy",
      reason:
        "Console-reachable refusal on the vercel-deploy button for an instance " <>
          "with nothing deployable; the caller's fallback renders. Flip: a wave " <>
          "rules the nothing-to-deploy sentence owed."
    },
    %{
      code: "not_retryable",
      site: "router.ex POST /v1/barkparks/:id/retry",
      reason:
        "Console-reachable TOCTOU: Retry against an instance that left its failed " <>
          "state between paint and click; the retry caller's fallback renders. " <>
          "Flip: measured as confusing in the wild."
    },
    %{
      code: "provider_unverified",
      site: "router.ex connect_provider_request",
      reason:
        "Console-reachable: connecting a provider whose credential fails " <>
          "verification; the connect caller's fallback renders. Flip: a wave " <>
          "rules a credential-check sentence owed."
    },
    %{
      code: "push_relay_unsupported",
      site: "router.ex POST /v1/barkparks/:id/push-relay",
      reason:
        "CLI-only: same zero-console-caller route as instance_refused — relay " <>
          "setup is a bp verb. Flip: a console push-relay control ships."
    },
    %{
      code: "revoke_refused",
      site: "router.ex revoke_app_token_on_instance",
      reason:
        "Console-reachable relay of the instance refusing the token revoke; the " <>
          "revoke caller's fallback renders. Flip: a wave rules revoke-specific " <>
          "copy owed."
    },
    %{
      code: "revoke_unsupported",
      site: "router.ex revoke_app_token_on_instance",
      reason:
        "Console-reachable capability gap: an instance too old to revoke app " <>
          "tokens; the revoke caller's fallback renders. Flip: a wave rules an " <>
          "update-your-instance sentence owed."
    },
    %{
      code: "steps_incomplete",
      site: "router.ex handle_onboarding_action (POST /v1/onboarding)",
      reason:
        "Guard-shielded: the console disables onboarding completion until every " <>
          "step is done; completing early is a raw-request state. Flip: the " <>
          "disable guard is removed."
    },
    %{
      code: "teardown_failed",
      site: "router.ex DELETE /v1/sites/:id",
      reason:
        "Console-reachable STATUS-READ: siteDeleteFailureCopy (the wave-67 destroy " <>
          "tier) classifies DELETE refusals by status and RELAYS the plane's detail " <>
          "verbatim — a status-keyed reader Side B cannot see. Honest today. Flip: " <>
          "a wave rules slug-keyed teardown copy owed."
    },
    %{
      code: "unknown_kind",
      site: "router.ex with_provider_catalog",
      reason:
        "Guard-shielded: the console passes fixed provider kinds; an unknown kind " <>
          "is a raw-request state. Flip: kinds drift between client and server."
    },
    %{
      code: "unknown_step",
      site: "router.ex handle_onboarding_action (POST /v1/onboarding)",
      reason:
        "Guard-shielded: the console submits steps from its own onboarding model; " <>
          "an unknown step is a raw-request or drift state. Flip: step names " <>
          "drift between client and server."
    },
    %{
      code: "url_required",
      site: "router.ex POST /v1/barkparks/:id/site-url",
      reason:
        "Guard-shielded: the site-url form requires input before submit; an empty " <>
          "URL is a raw-request state. Flip: the form guard is removed."
    },
    %{
      code: "vercel_error",
      site: "router.ex POST /v1/barkparks/:id/vercel-deploy",
      reason:
        "Console-reachable upstream fault relayed from Vercel; the 5xx honesty " <>
          "law renders the server-fault sentence — honest. Flip: a wave rules " <>
          "Vercel-specific copy owed."
    },
    %{
      code: "webhook_gone",
      site: "router.ex instance_capability_404",
      reason:
        "Console-reachable through the webhook panel's proxy: the instance's own " <>
          "coded 404 for a deleted webhook, discriminated server-side; the panel " <>
          "caller's fallback renders. Flip: a wave rules the deleted-webhook " <>
          "sentence owed."
    }
  ]

  # ---------------------------------------------------------------------------
  # Derivation, shared by the tests below.
  # ---------------------------------------------------------------------------

  defp emitted do
    router = Census.emitted_codes(Census.source!(@router, "router.ex"), "router.ex")
    auth = Census.emitted_codes(Census.source!(@auth, "auth.ex"), "auth.ex")
    MapSet.union(router, auth)
  end

  defp read do
    js_lines = Census.source!(@app_js, "app.js") |> Census.strip_js_comments()
    MapSet.union(Census.quoted_slugs(js_lines), Census.errors_keyset(js_lines))
  end

  defp classified_codes, do: MapSet.new(@classified, & &1.code)

  # ---------------------------------------------------------------------------

  test "both sides derive non-vacuously: every source contributes" do
    router_codes = Census.emitted_codes(Census.source!(@router, "router.ex"), "router.ex")
    auth_codes = Census.emitted_codes(Census.source!(@auth, "auth.ex"), "auth.ex")
    js_lines = Census.source!(@app_js, "app.js") |> Census.strip_js_comments()
    quoted = Census.quoted_slugs(js_lines)
    keyset = Census.errors_keyset(js_lines)

    # Anchors, not counts: one known-stable code per extraction proves the
    # extractor is reading the real thing, without committing a total.
    assert MapSet.member?(router_codes, "not_found"),
           "router.ex extraction no longer contains `not_found` — the extractor " <>
             "or the file has changed shape; distrust every set derived from it"

    assert MapSet.member?(auth_codes, "unauthorized"),
           "auth.ex extraction no longer contains `unauthorized` — the extractor " <>
             "or the file has changed shape"

    assert MapSet.member?(keyset, "forbidden"),
           "the ERRORS keyset no longer contains `forbidden` — the block parse " <>
             "has slipped off the real map"

    assert MapSet.size(quoted) > 0,
           "zero whole quoted slug literals extracted from app.js — the comment " <>
             "stripper or the quote regex has broken; Side B is blind"
  end

  test "every minted code is READ by the console or CLASSIFIED with a ruling" do
    missing = Census.unclassified(emitted(), read(), classified_codes())

    assert missing == [], """
    #{length(missing)} typed refusal code(s) are on the wire with NO console reader
    and NO classification row:

    #{Enum.map_join(missing, "\n", &"      #{&1}")}

    Every code a PR mints must either be read (a whole quoted literal in app.js,
    or a bare key of the ERRORS map — charter D873) or carry a %{code, site,
    reason} row in @classified naming its reachability class, its disposition,
    and the condition that would flip the ruling. Add the reader or add the row —
    and if you add the row, put it in the right per-arm block, alphabetically.
    """
  end

  test "the rot arm: a CLASSIFIED code that gains a reader must leave the map" do
    rotted = Census.rotted(read(), classified_codes())

    assert rotted == [], """
    #{length(rotted)} classified code(s) are now READ by the console:

    #{Enum.map_join(rotted, "\n", &"      #{&1}")}

    This is the GOOD direction: a reader landed for a code the map called unread.
    Delete EVERY @classified row for each code above in the same diff as the
    reader — the map's whole value is that it never describes a state that has
    stopped being true.
    """
  end

  test "THE SEAL (D881): no CLASSIFIED row still reads READER OWED" do
    owed = Census.reader_owed(@classified)

    assert owed == [], """
    #{length(owed)} classified code(s) still carry the unpaid-debt phrase READER OWED
    in their reason:

    #{Enum.map_join(owed, "\n", &"      #{&1}")}

    The seal: after the deploy/github payments, ZERO census rows read READER OWED —
    every survivor a settled classification with a named flip condition. Either PAY
    the code (ship a curated ERRORS reader and delete its rows via the rot arm) or
    REWORD the reason to a settled classification-stands ruling. The phrase is the
    debt marker; a green here is the seal.
    """
  end

  test "no CLASSIFIED row outlives its emitter" do
    gone = MapSet.difference(classified_codes(), emitted()) |> Enum.sort()

    assert gone == [], """
    #{length(gone)} classified code(s) are no longer minted anywhere in
    router.ex/auth.ex:

    #{Enum.map_join(gone, "\n", &"      #{&1}")}

    Delete their @classified rows — a ruling about a code that left the wire is
    dead weight that teaches the next reader a false map.
    """
  end

  test "every CLASSIFIED row is a RULING: reason floor, function-name sites, no duplicates" do
    for row <- @classified do
      assert is_binary(row.code) and row.code != "", "a @classified row has no code"

      assert is_binary(row.site) and byte_size(row.site) > 10,
             "#{row.code}: the site must name where the code is minted"

      refute row.site =~ ~r/\.exs?:\d/,
             "#{row.code}: cite the emit site by FUNCTION NAME or route head, never " <>
               "a line number — line cites drifted twice in one wave (13923 -> 13956)"

      assert byte_size(row.reason) > 40,
             "#{row.code} @ #{row.site}: a reason this short cannot name a " <>
               "reachability class, a disposition, AND a flip condition"
    end

    keys = Enum.map(@classified, &{&1.code, &1.site})

    assert length(Enum.uniq(keys)) == length(keys),
           "duplicate {code, site} rows in @classified — one row per emit site, " <>
             "so that a reader diff deletes exactly its own rows"
  end

  test "ANTI-VACUITY: the census can lose — a synthetic minted code reds by name" do
    synthetic = "zz_census_mutation_probe"
    minted = MapSet.put(emitted(), synthetic)

    missing = Census.unclassified(minted, read(), classified_codes())

    assert synthetic in missing,
           "a code injected into Side A did NOT surface as unclassified — the " <>
             "reconciliation has gone vacuous and every green from it is noise"

    # And the rot arm can lose too: a classified code that is also read fires.
    rotted = Census.rotted(MapSet.put(read(), "not_a_support"), classified_codes())

    assert "not_a_support" in rotted,
           "a classified code injected into Side B did NOT trip the rot arm — " <>
             "the allowlist could rot silently"

    # And the D881 seal guard can lose too: a row carrying the debt phrase in a
    # LOCAL list (never the module attribute) surfaces by code.
    probe = %{
      code: "zz_owed_probe",
      site: "synthetic seal probe site",
      reason: "READER OWED: injected debt"
    }

    assert "zz_owed_probe" in Census.reader_owed(@classified ++ [probe]),
           "a synthetic READER OWED row injected into a LOCAL classified list did " <>
             "NOT surface through reader_owed/1 — the seal guard has gone vacuous " <>
             "and its green proves nothing"
  end

  test "FAIL-CLOSED: a missing source, an empty extraction, a lost ERRORS map all raise by name" do
    gone = Path.expand("../../lib/barkpark_cloud/web/router_renamed.ex", __DIR__)

    assert_raise ArgumentError, ~r/source not found at .*router_renamed\.ex/, fn ->
      Census.source!(gone, "router.ex")
    end

    assert_raise ArgumentError, ~r/extracted ZERO error/, fn ->
      Census.emitted_codes("defmodule Empty do\nend\n", "a codeless source")
    end

    assert_raise ArgumentError, ~r/var ERRORS = \{` block was not found/, fn ->
      Census.errors_keyset(["var SOMETHING_ELSE = {", "  a: 1", "};"])
    end

    assert_raise ArgumentError, ~r/yielded ZERO bare keys/, fn ->
      Census.errors_keyset(["var ERRORS = {"])
    end
  end

  test "the header records the D873 two-part rule and the census limits" do
    src = File.read!(__ENV__.file)

    assert src =~ "bare ERRORS keys are the STANDARD reader pattern",
           "the moduledoc must state the reason for Side B's two-part rule"

    assert src =~ "This proves READERSHIP SHAPE, not copy quality",
           "the moduledoc must state the limit of the claim"
  end
end
