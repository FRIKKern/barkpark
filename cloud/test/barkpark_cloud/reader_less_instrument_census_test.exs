defmodule BarkparkCloud.ReaderLessInstrumentCensus.ReaderScan do
  @moduledoc """
  SIDE B of the deletion law: the READERS an instrument key actually has, read
  off the consumer trees' SOURCE.

  ## The definition, ruled in charter D453

  A READER IS A CODE PATH THAT NAMES THE KEY.

  Not "the bytes reach a human". `census.Raw = body` (`internal/cloudclient/
  client.go:2261`) piped to `fmt.Fprintln` (`internal/cli/cloud_deploy_census_cmd.go:222`)
  really does put the control plane's exact bytes — `coalesced_attempts`
  included — in a terminal under `-o json`. It is still TRANSPORT, not
  readership, on three grounds: no Go field, render or test names the key, so
  deleting it reds nothing reader-side; the DEFAULT `-o table` render omits it;
  and a byte pipe prints absence and presence IDENTICALLY, i.e. that "reader"
  structurally cannot lose (D397). A verbatim passthrough is a pipe, and a pipe
  is not an audience.

  ## The corpus — POSITIVELY declared, five trees, three casings

  `@roots` is a positive declaration. A SUBTRACTIVE corpus ("everything except
  …") is how D441's went vacuous, and D442's went dark for a different reason:
  IT OMITTED `api/`. The instance half of every control-plane instrument lives
  there — `internal/agent/report.go:639` holds the probe and
  `api/lib/barkpark_web/router.ex:1633` MOUNTS the route it probes — so a corpus
  without `api/` cannot see the reader half of a cross-tree instrument and
  scores it dark by construction. `test "the api/ half of the corpus is
  LOAD-BEARING"` measures exactly that: dropping `api/` loses real reader files
  for a key that has them.

  Three casings, always: `queued_stall_seconds`, `queuedStallSeconds`,
  `QueuedStallSeconds`. The wire is snake, the JS/Go locals are camel, the Go
  struct fields are Pascal — a snake-only sweep scores every Go struct field
  ZERO and calls a decoded key dark.

  ## What is NOT a reader — and the direction this errs in

  A COMMENT is not a code path. `cloud_deploy_census_cmd.go:538` said
  *"`coalesced_attempts` now lands on the row but is not in this envelope"* —
  false on main (`deploy_ledger.ex:893` emits it inside `census/3`) — and D442
  scored that one comment as this key's single "reader hit". A sentence about a
  key cannot stop the key from being deleted, so it is not readership.

  The stripper is line-anchored: a line whose FIRST non-space characters are
  `//`, `#`, `*`, `/*` or `<!--` is dropped. It therefore still counts a
  TRAILING comment on a code line, and still counts a block-comment body line
  that starts with a word. That is deliberate and it is the SAFE direction: an
  over-counted reader can only ever PROTECT an instrument from deletion. It
  never authorises one. The unsafe direction — under-counting, i.e. deleting an
  instrument something reads — is the one this bias cannot produce. The cost is
  named honestly below: an over-count can also MASK the loss of a real reader on
  a `:has_reader` row.

  `.json` is not in `@extensions`. A JSON fixture naming a key is DATA, not a
  code path, by the same rule that refuses the comment — and admitting it would
  drag `api/priv/codex_app_server_schema/**` (a vendored protocol schema) into
  the corpus as a phantom audience.

  ## SUBSTRING, not identifier-boundary — and why, measured

  A boundary-anchored match (`(?<![A-Za-z0-9_])name(?![A-Za-z0-9_])`) was the
  first cut and it LOST THE CENSUS'S OWN CONTROL: `internal/agent/report.go:639`
  reads `const requestStatsPath = "/v1/instance/request-stats"`, and the trailing
  `Path` makes `requestStats` fail the right-hand boundary. A compound identifier
  built out of the key's name is still a code path that names the key — that is
  how Go names a route constant and how Pascal fields compose. So the match is a
  plain SUBSTRING over the three casings. It over-counts (a longer identifier
  that merely embeds the name scores as a reader), and that is the same safe
  direction the comment stripper errs in: an over-count can only PROTECT an
  instrument from deletion, never authorise one.

  FILED, NOT FIXED — the `tls_mode` bias, named with its sites. `tls_mode` IS a
  schema field (it is in the 223 the reflection below returns), so it is
  admission-relevant, and the substring rule scores it FOUR readers:
  `internal/runtime/runtime.go:147` (`func tlsModeForServing(mode string) string`),
  `internal/runtime/runtime.go:279` (`TLSMode: tlsModeForServing(...)`),
  `internal/runtime/runtime_test.go:774` and `:775`. Every one of the four is the
  compound `tlsModeForServing`; ZERO would survive an identifier-boundary anchor.
  So `tls_mode`'s entire "audience" is one differently-named function. This slice
  RECORDS that and changes NOTHING about matching semantics — flipping the rule
  here would re-rule readership for every key at once, inside a change whose only
  claim is that it is faster.

  ## COMPILED PATTERNS — why, measured

  `hits/2` compiles one `:binary.compile_pattern/1` per key plus one for the
  union, instead of re-deriving the variant list on every line/key pair. Measured
  on this tree (3313 corpus files, macOS 10-core host, LOAD AVERAGE QUOTED
  because it is most of the variance — this host carried 56 sessions while these
  numbers were taken):

      keys  implementation  result
      7     uncompiled      1.87s                                  (load avg 8.8)
      7     compiled        0.69s                                  (load avg 30.0)
      223   uncompiled      DID NOT FINISH IN 240s, 207.67s CPU    (load avg 8.8)
      223   compiled        FINISHED, 15.42s CPU                   (load avg 30.0)

  Read that table with its right-hand column: the compiled 7-key run was 2.7x
  faster than the uncompiled one WHILE THE HOST WAS UNDER 3.4x THE LOAD. The
  uncompiled row got the quiet host and still lost.

  WHAT THIS COSTS THE FILE, said rather than discovered: keeping the oracle means
  the census pays for a second, uncompiled full-corpus pass in the equivalence
  test. The file went 13 tests / 4.8s (load avg 8.8) to 14 tests / 6.4s (load avg
  20.4) — a ~1.3x multiple here, and 11.9s at load avg 31, so the honest band is
  1.3-2.5x and the variance is the host, not the code.
  `.github/workflows/cloud.yml` sets no `timeout-minutes`, so the GitHub default
  of 360 minutes applies and this is free in CI.

  So the rewrite is a floor of ~15x, and at 223 keys it is the difference
  between an instrument and one that cannot be run at all. THE 223 IS NOT
  HYPOTHETICAL: it is `length(distinct schema fields across the 29 loaded
  `BarkparkCloud.*` Ecto schemas)`, i.e. the key set a derived-admission arm
  would scan.

  Do NOT quote "9.4s" for the compiled 223-key scan; it is not reproducible, and
  the corpus-growth story attached to it is wrong — the corpus grew from 3310 to
  3313 files, THREE files, not ~75. The spread between one measurement and the
  next is HOST LOAD, which is why every figure above carries its load average.

  ## Two corrections a derived arm must inherit

  1. THE REFLECTION MODULE IS `BarkparkCloud.Registry.Barkpark` — no dot after
     `Barkpark`. `Barkpark.Cloud.Registry.Barkpark` does not exist and raises
     `UndefinedFunctionError`, so a derived arm written against it fails at the
     first call rather than reporting a wrong number.
  2. THREE OF THE SEVEN REGISTER KEYS ARE NOT SCHEMA FIELDS — `publish_clock`,
     `failure_class` and `request_stats` are absent from the 223; only
     `coalesced_attempts`, `queued_self_seconds`, `queued_pickup_seconds` and
     `queued_stall_seconds` are present. A schema-derived admission arm can
     therefore sit BESIDE the hand-typed `@register` and can NEVER subsume it:
     derivation alone would drop three instruments this census is watching.

  The derived arm itself is DEFERRED out of this slice — see the task, and PR
  #11169, which owns this file's tail.
  """

  # The repo root, walked with `Path.dirname/1` rather than a parent-relative
  # path literal. THIS IS NOT COSMETIC AND IT IS NOT FREE — read the DISPATCH
  # BLINDNESS paragraph in the census's own moduledoc.
  # `scripts/cloud-path-escape-check.sh` resolves every parent-relative string
  # literal in `cloud/**` against `CLOUD_PATHS`; `internal`, `web`, `js` and
  # `api` are not declared there, and the declaration lives in a file this slice
  # does not own (dr-w26-s4). A parent-relative literal naming those trees fails
  # that gate on arrival — measured, not assumed: writing one here reds it with
  # `UNCOVERED repo-root read: internal`, which is exactly the honest complaint
  # the moduledoc records and files rather than silences.
  #
  # Walking with `Path.dirname/1` does not BUY dispatch coverage — it only stops
  # a gate from failing over a declaration this slice cannot make. The gap is
  # real and is written down where a reader will find it.
  @repo_root __DIR__ |> Path.dirname() |> Path.dirname() |> Path.dirname()

  # THE READER CORPUS. Positively declared; five trees.
  @roots ~w(internal cloud/priv/static web js api)

  @extensions ~w(.go .ex .exs .heex .ts .tsx .js .mjs .cjs .jsx .html .css)

  # Refused by name: build output and vendored dependencies are not code anyone
  # in this repo can be said to have written a reader in.
  @refused_dirs ~w(node_modules _build deps dist .next .git coverage cover)

  @comment_starts ["//", "#", "*", "/*", "<!--"]

  @type hit :: %{file: binary(), line: pos_integer(), text: binary()}

  @doc "The repo root this scan is anchored to."
  @spec repo_root() :: binary()
  def repo_root, do: @repo_root

  @doc "The declared corpus roots."
  @spec roots() :: [binary()]
  def roots, do: @roots

  @doc "The declared source extensions."
  @spec extensions() :: [binary()]
  def extensions, do: @extensions

  @doc """
  The three casings of an instrument key: snake, camel, Pascal.

      iex> variants("queued_stall_seconds")
      ["queued_stall_seconds", "queuedStallSeconds", "QueuedStallSeconds"]
  """
  @spec variants(binary()) :: [binary()]
  def variants(key) do
    parts = String.split(key, "_")
    pascal = parts |> Enum.map_join(&String.capitalize/1)
    camel = hd(parts) <> (parts |> tl() |> Enum.map_join(&String.capitalize/1))

    [key, camel, pascal] |> Enum.uniq()
  end

  @doc """
  Every corpus file, as repo-relative paths.

  A root that does not exist is a NAMED refusal, never an empty list: "no files
  under `api/`" and "no reader under `api/`" are the same green, and only one of
  them is true.
  """
  @spec files(keyword()) :: [binary()]
  def files(opts \\ []) do
    opts
    |> Keyword.get(:roots, @roots)
    |> Enum.flat_map(fn root ->
      abs = Path.join(@repo_root, root)

      unless File.dir?(abs) do
        raise ArgumentError,
              "ReaderScan: declared corpus root #{root} does not exist at #{abs}. " <>
                "A missing tree scans zero files and reports every instrument reader-less. " <>
                "Re-point @roots rather than deriving a deletion from an absent corpus."
      end

      abs
      |> walk()
      |> Enum.map(&Path.relative_to(&1, @repo_root))
    end)
    |> Enum.sort()
  end

  @doc """
  `%{key => [hit]}` — every non-comment line in the corpus naming any casing of
  any key. One pass over the corpus for all keys at once.

  The patterns are COMPILED ONCE, per key and for the union — see the
  moduledoc's "COMPILED PATTERNS" section for the measurement that forced it.
  `hits_uncompiled/2` is the byte-for-byte oracle this must agree with, and
  `test "COMPILED == UNCOMPILED, on file:line"` is where that agreement is
  asserted rather than assumed.
  """
  @spec hits([binary()], keyword()) :: %{binary() => [hit()]}
  def hits(keys, opts \\ [])

  # REVIEW ADDITION (cch-w61 review): the empty key set. The uncompiled oracle
  # returns `%{}` for it (`String.contains?(source, [])` is simply false);
  # `:binary.compile_pattern([])` RAISES ArgumentError. Without this clause the
  # two implementations diverge at exactly the boundary the equivalence test
  # claims they agree on, and a derived-admission arm that reflected zero fields
  # would crash the census instead of reporting an empty one.
  def hits([], _opts), do: %{}

  def hits(keys, opts) do
    keys = Enum.uniq(keys)
    table = Enum.map(keys, &{&1, :binary.compile_pattern(variants(&1))})
    all = keys |> Enum.flat_map(&variants/1) |> Enum.uniq() |> :binary.compile_pattern()

    empty = Map.new(keys, &{&1, []})

    opts
    |> files()
    |> Enum.reduce(empty, fn file, acc ->
      source = File.read!(Path.join(@repo_root, file))

      # Binary prefilter: most files name none of the keys, and one compiled
      # Aho-Corasick pass over the whole source is far cheaper than a per-line
      # regex — or than re-compiling the same literal list per file.
      if :binary.match(source, all) != :nomatch do
        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reduce(acc, fn {line, n}, acc -> record(line, n, file, table, acc) end)
      else
        acc
      end
    end)
  end

  @doc """
  THE ORACLE: `hits/2` exactly as it shipped before 2026-08-09 — uncompiled
  `String.contains?/2` over the raw variant lists, re-compiling the pattern on
  every one of the ~1.3M line/key pairs it walks.

  It is kept, and kept SLOW, for one reason: an optimisation that changes what
  the census SEES is not an optimisation, it is a silent re-ruling on which
  instruments are reader-less. The equivalence test runs both over the seven
  register keys and compares FILE:LINE SETS, so a rewrite that quietly narrows
  the match reds by name instead of shipping as a speed-up.

  Do not call this from the census itself. At 223 keys it does not finish inside
  four minutes.
  """
  @spec hits_uncompiled([binary()], keyword()) :: %{binary() => [hit()]}
  def hits_uncompiled(keys, opts \\ []) do
    keys = Enum.uniq(keys)
    table = Map.new(keys, &{&1, variants(&1)})
    all = table |> Map.values() |> List.flatten() |> Enum.uniq()

    empty = Map.new(keys, &{&1, []})

    opts
    |> files()
    |> Enum.reduce(empty, fn file, acc ->
      source = File.read!(Path.join(@repo_root, file))

      if String.contains?(source, all) do
        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reduce(acc, fn {line, n}, acc ->
          if comment?(line) do
            acc
          else
            Enum.reduce(table, acc, fn {key, vs}, acc ->
              if String.contains?(line, vs) do
                Map.update!(acc, key, &[%{file: file, line: n, text: String.trim(line)} | &1])
              else
                acc
              end
            end)
          end
        end)
      else
        acc
      end
    end)
  end

  @doc """
  True when the line's first non-space characters open a comment.

  Line-anchored on purpose — see the moduledoc's account of what this misses and
  which direction the miss errs in.
  """
  @spec comment?(binary()) :: boolean()
  def comment?(line) do
    trimmed = String.trim_leading(line)
    trimmed != "" and Enum.any?(@comment_starts, &String.starts_with?(trimmed, &1))
  end

  defp record(line, n, file, table, acc) do
    if comment?(line) do
      acc
    else
      Enum.reduce(table, acc, fn {key, pattern}, acc ->
        if :binary.match(line, pattern) != :nomatch do
          Map.update!(acc, key, &[%{file: file, line: n, text: String.trim(line)} | &1])
        else
          acc
        end
      end)
    end
  end

  defp walk(dir) do
    dir
    |> File.ls!()
    |> Enum.reject(&(&1 in @refused_dirs))
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      cond do
        File.dir?(path) -> walk(path)
        Path.extname(path) in @extensions -> [path]
        true -> []
      end
    end)
  end
end

defmodule BarkparkCloud.ReaderLessInstrumentCensus.Stay do
  @moduledoc """
  THE STAY PREDICATE — re-derived, never inherited (charter D452).

  An instrument may be reader-less and still stay, but only for a stated reason,
  and rider 1 ("an open PR names it") is DEAD AS WRITTEN. Re-derived on
  2026-08-09 against the three PRs the epic's own table stayed instruments for:

      #10811  OPEN  DIRTY  36 check-runs  25 SUCCESS + 11 SKIPPED  0 failures  newest 2026-08-08T11:42:08Z
      #11007  OPEN  DIRTY  36 check-runs  29 SUCCESS +  7 SKIPPED  0 failures  newest 2026-08-08T16:39:37Z
      #11008  OPEN  DIRTY  32 check-runs  25 SUCCESS +  7 SKIPPED  0 failures  newest 2026-08-08T16:40:46Z

  All three are 100% success-or-skipped with ZERO failures, and NONE of them can
  merge. GitHub attaches a PR's checks to its HEAD sha and never re-fires them
  when the BASE advances: `origin/main` moved to `0239dd4ee` at
  2026-08-08T23:48:12Z, hours after the newest of those runs. #10811's rollup
  literally reads `Required-check spec gate SUCCESS` on a PR that is
  CONFLICTING. A green check-run is therefore not evidence the PR is alive; it
  is evidence about a tree that no longer exists.

  RULED, and implemented here as `stayed?/1`:

      state == "OPEN"
        AND mergeStateStatus != "DIRTY"
        AND deciding_check_at > base_moved_at

  `clauses/1` returns the three legs separately, because a stay that fails must
  say WHICH leg refused — "not stayed" alone would let a DIRTY PR and a stale
  green be confused for one another, which is precisely the confusion that let
  three dead PRs hold instruments alive for a wave.

  NOT THE MERGE PREDICATE. #11009 is UNSTABLE and must still land. This function
  answers one question only: may a reader-less instrument keep its life on the
  strength of this PR.
  """

  @type facts :: %{
          required(:state) => binary(),
          required(:merge_state_status) => binary(),
          required(:deciding_check_at) => DateTime.t(),
          required(:base_moved_at) => DateTime.t()
        }

  @doc "The three legs, named, as `{leg, boolean}`."
  @spec clauses(facts()) :: [{atom(), boolean()}]
  def clauses(f) do
    [
      open: f.state == "OPEN",
      not_conflicting: f.merge_state_status != "DIRTY",
      check_newer_than_base: DateTime.compare(f.deciding_check_at, f.base_moved_at) == :gt
    ]
  end

  @doc "True only when all three legs hold."
  @spec stayed?(facts()) :: boolean()
  def stayed?(f), do: f |> clauses() |> Enum.all?(fn {_leg, ok?} -> ok? end)

  @doc "The legs that refused, by name."
  @spec refusals(facts()) :: [atom()]
  def refusals(f), do: for({leg, false} <- clauses(f), do: leg)
end

defmodule BarkparkCloud.ReaderLessInstrumentCensusTest do
  @moduledoc """
  THE READER-LESS INSTRUMENT CENSUS — the deletion law, as code that can lose
  (deploy-reliability wave 26, charter D452 + D453 + D454 + D456 + D459).

  ## The defect this exists to end

  Twenty-five waves of this epic could ADD an instrument and could not SUBTRACT
  one. The law was ratified as PROSE (D442) and no wave shipped it, so the
  register of what nobody reads was a table in a markdown file that went stale
  about three of its own rows before it was even merged. A pipeline that only
  accretes has no way to be wrong about an instrument: every number it ever
  built is still there, still green, still unread.

  ## The shape — a declaration checked against a derivation

  SIDE A: `@register`, committed. Every row names its `key`, `what` it reports,
  the `surface` its bytes appear on, the `audience` that can read that surface,
  a REQUIRED `reason`, a `disposition`, and — when reader-less — a `stay`.

  SIDE B: `ReaderScan` derives the key's readers from five trees of source.

  THE ASSERTIONS, and both directions can lose:

    * a `:has_reader` row whose derived readers are EMPTY reds — a reader was
      taken away and nothing else said so;
    * a `:stay` or `:deleted` row whose derived readers are NON-EMPTY reds as
      ROT — the row's excuse stopped being true, and the fix is to delete the
      ROW (this is the good direction);
    * a `:stay` row whose stay does not hold TODAY reds — rider-1 stays are
      re-derived at build time, never read off a table;
    * a `:deleted` row whose key still appears in `cloud/lib` reds — a deletion
      that did not happen is not a deletion.

  ## COUNTING WHICH HUMAN (D456)

  Every row names `surface` AND `audience`, and `audience` is not decoration.
  On 2026-08-08 the fleet took a 4h55m five-site outage and something DID
  report it: `notification_deliveries` carries exactly 30 rows in the window —
  18 `alert/email/deployment_failed` and 12 `alert/email/agent_unreachable`, all
  `status=sent`, ALL TO ONE ADDRESS, `frikk@guerrilla.no`, the tenant's own
  user. Not one platform recipient. `deployment_failed` would score as
  "instrumented, has a reader" under any law that counts code paths alone, while
  being — from the seat of the party who could act — exactly as blind as no
  instrument at all. So a reader column that names only a surface is a lie of
  omission, and this register refuses to have one.

  ## THIS GUARD'S OWN BLINDNESS — read it before trusting a green (D459)

  This census asks whether the NAME appears anywhere in the corpus, so a struct
  field that still carries the name but has stopped decoding the key still
  scores as a reader. A green row here means "some code path names this key",
  never "this key is decoded". THE HOLE IS STILL HERE and this file does not
  close it.

  What HAS changed is that the go-tag census next door no longer shares it.
  `Go.all_tags/1` is a file-global union of NAMES, so `@go_tag_floor` measured
  vocabulary and not coverage: turning `SiteDeleteResult.Status` into
  `json:"-"` — the reader STOPS DECODING a live envelope key — left that census
  green with `go test ./internal/cloudclient/...` green too, mutation-proved.
  `payload_key_set_census_test.exs` now carries a SITE arm
  (`@go_tag_sites`, dr-w26-bl-go-tag-arm-is-36-percent-blind): every name
  declared more than once is pinned at its exact multiplicity, and the register
  plus the name floor are asserted to partition all 516 tag sites, so no tag
  site in internal/cloudclient can be deleted without a red. That closes the
  DECLARATION half — a key that stops being declared is now seen. It does NOT
  close this file's half: a key still declared but never read is invisible to
  both. `dr-w23-s6-register-per-struct-unread` remains the slice for pinning a
  key to the struct that is supposed to decode it, and it is not this wave — so
  the remaining blindness is written down instead of covered over.

  Two further limits, stated rather than discovered later:

    * DISPATCH. `.github/workflows/cloud.yml` dispatches this suite on
      `cloud/**` and the paths declared in `scripts/cloud-path-escape-check.sh`.
      `internal/`, `web/`, `js/` and `api/` are NOT declared there, so a commit
      that adds a reader ONLY in those trees does not re-run this census; the
      ROT is caught on the next cloud-touching commit, not on the commit that
      caused it. That declaration lives in a file dr-w26-s4 owns, so it is filed
      (`dr-w26-followup-reader-corpus-dispatch`), not smuggled into this slice.
    * FAILING OPEN. An instrument nobody registered is invisible here, exactly
      as `deploy_signal_audience_census_test.exs` admits of its own registry.
      Nothing syntactic closes that hole. `queued_seconds` is the honest
      example: it is emitted by `platform_delivery.ex:356`, has zero readers in
      all five trees, and is NOT in the register below because its disposition
      is a later slice's call, not this one's — filed as
      `dr-w26-followup-queued-seconds-disposition`.
  """

  use ExUnit.Case, async: true

  alias BarkparkCloud.ReaderLessInstrumentCensus.ReaderScan
  alias BarkparkCloud.ReaderLessInstrumentCensus.Stay

  @cloud_lib Path.join([ReaderScan.repo_root(), "cloud", "lib"])

  # ---------------------------------------------------------------------------
  # SIDE A — THE INSTRUMENT REGISTER
  #
  # `reason` is REQUIRED on every row: a register whose rows do not say why they
  # are there decays into a junk drawer, and a junk drawer cannot order a
  # deletion. `surface` is where the bytes land; `audience` is WHICH HUMAN can
  # be at that surface (D456).
  # ---------------------------------------------------------------------------
  @register [
    %{
      key: "publish_clock",
      what:
        "the publish→web clock: how long a human's publish waited before the bytes it produced were live",
      surface:
        "GET /v1/sites/:id/deployments — a sibling node on the JSON body (was router.ex:7110)",
      audience:
        "a SESSION-authenticated member of the site's own team, and nobody else: the route is session-only (D219), so no PAT, no CI credential and no platform seat could ever read it — and no client, page or script in five trees ever decoded the node",
      reason:
        "ruled the epic's vital in W11, written in W12, given a production caller in W14, and read by zero code paths in thirteen waves. Zero readers across all five corpus trees, no open PR names it, and its stay under any rider is empty. THE FIRST DELETION (dr-w26-s6).",
      disposition: :deleted,
      stay: nil
    },
    %{
      key: "coalesced_attempts",
      what:
        "how many deploy attempts the ledger collapsed into one row — the denominator that decides whether a failure rate is measuring deploys or measuring coalescing",
      surface:
        "GET /v1/deploy-ledger/census — emitted inside DeployLedger.census/3 (deploy_ledger.ex:893)",
      audience:
        "the terminal, as of dr-w23-s4: internal/cloudclient/client.go decodes the node into `DeployCensus.CoalescedAttempts *DeployCoalescedAttempts` and internal/cli/cloud_deploy_census_cmd.go renders it on the basis line of every `-o table` deploy census. A WHOLE reader, unlike the queued_* legs below: this key has a real writer too (auto_deploy_worker.ex:412, ~31,697 rows), so the rendered number means something.",
      reason:
        "RE-DECLARED (was `:stay`). THE CLOSER LANDED, which is the good direction this register exists to detect: dr-w23-s4 added the typed decode and the render, so the row derives 13 readers and correctly redded as :rot under `:stay`. The old reason is preserved as the record because it is the more interesting half — D442 scored this key \'1 reader hit\', and that hit was the COMMENT at cloud_deploy_census_cmd.go:538 asserting `coalesced_attempts` \'is not in this envelope\', which was FALSE on main (deploy_ledger.ex:893 emits it inside census/3). The true reader count was 0, a comment was being counted as readership, and the comment was wrong about the very fact it was being counted for. dr-w23-s4 deletes that comment and replaces the window-independent frozen sentence beside it with this window\'s own measured count — or, before @coalesced_counter_since, with the producer\'s own refusal rendered as a named absence and never as a 0.",
      disposition: :has_reader,
      stay:
        {:data,
         "KEPT AS THE RECORD, not as a live stay (this row is now `:has_reader`, so the stay-validity test no longer reads it). The COLUMN is data, not an instrument: deployments.coalesced_attempts (deployment.ex:206) is written by auto_deploy_worker.ex:412 across ~31,697 rows. \'`coalesced_attempts` is deletable\' must never have become \'drop the column\' — and now nothing is deletable here at all, because the emission has a reader."}
    },
    %{
      key: "queued_self_seconds",
      what:
        "the queue leg a delivery spent waiting on ITSELF — the self-inflicted half of a deploy's queue wait",
      surface:
        "PlatformDelivery.to_json/1 (platform_delivery.ex:357), on the deliveries envelope",
      audience:
        "the terminal, as of dr-w26-s3: internal/cloudclient/deliveries.go:89 decodes the leg and internal/cli/cloud_deliveries_cmd.go:450 renders it. HALF a reader, and the register says which half — see `reason`.",
      reason:
        "RE-DECLARED 2026-08-09 (was `:stay`). The READER landed — internal/cloudclient/deliveries.go:89-91 decodes all three legs as *int and cloud_deliveries_cmd.go:450 renders them — so this row derives 5 readers and correctly redded as :rot under `:stay`. THE WRITER NEVER DID: cloud/lib/barkpark_cloud/platform_delivery.ex carries cast (:144), schema field (:173), validate (:249) and to_json emit (:452) and NO producer anywhere in cloud/lib computes a value (`grep -rn queued_self_seconds cloud/lib | grep -v platform_delivery.ex` is EMPTY), so the column is emitted ALWAYS-NULL and the terminal renders a hole. This census measures READERSHIP only, which is why `:has_reader` is true here while the number is still meaningless — the honest fact a plain green would hide. dr-w26-s5, the slice the old stay named as the writer's closer, DOES NOT EXIST (`bp task get dr-w26-s5` -> not_found), so nothing is queued to fill it. Deleting the row instead would have taken the guard with it (@register_floor 7 trips and the :780 pin fails); re-declaring keeps it and ADDS the :lost_reader direction.",
      disposition: :has_reader,
      stay:
        {:slice, ["dr-w26-s3", "dr-w26-s5"],
         "KEPT AS THE RECORD, not as a live stay (this row is now `:has_reader`, so the stay-validity test no longer reads it, but the :780 pin does). dr-w26-s3 built the reader and LANDED. dr-w26-s5 was named as the writer and was never filed as a task at all — `bp task get dr-w26-s5` returns not_found and FTS finds only s6, the w26 charter and the w26 paper. A stay naming a closer that does not exist is exactly the failure this register exists to catch, and the register could not catch it: nothing here derives task existence."}
    },
    %{
      key: "queued_pickup_seconds",
      what: "the queue leg spent waiting for a runner to pick the delivery up",
      surface:
        "PlatformDelivery.to_json/1 (platform_delivery.ex:358), on the deliveries envelope",
      audience:
        "the terminal, as of dr-w26-s3: internal/cloudclient/deliveries.go:90 decodes the leg, cloud_deliveries_cmd.go:450 renders it — same half-a-reader state as its sibling",
      reason:
        "RE-DECLARED 2026-08-09 (was `:stay`), same measured state as queued_self_seconds: the READER landed (internal/cloudclient/deliveries.go:90) and the WRITER never did — platform_delivery.ex casts, stores, validates and emits the column and no producer in cloud/lib computes it, so it is emitted always-null. `:has_reader` is a readership claim, not a claim that the number means anything. dr-w26-s5, the writer's named closer, is not a filed task.",
      disposition: :has_reader,
      stay:
        {:slice, ["dr-w26-s3", "dr-w26-s5"],
         "KEPT AS THE RECORD (the :780 pin still reads it). dr-w26-s3 built the reader and landed; dr-w26-s5 was never filed — `bp task get dr-w26-s5` returns not_found."}
    },
    %{
      key: "queued_stall_seconds",
      what:
        "the queue leg that is neither self-inflicted nor pickup — the stall nobody owns, which is the one worth alerting on",
      surface:
        "PlatformDelivery.to_json/1 (platform_delivery.ex:359), on the deliveries envelope",
      audience:
        "the terminal, as of dr-w26-s3: internal/cloudclient/deliveries.go:91 decodes the leg, cloud_deliveries_cmd.go:450 renders it — and this is the leg whose absence a platform operator would most need, which is why an always-null render is worse here than anywhere else",
      reason:
        "RE-DECLARED 2026-08-09 (was `:stay`), same measured state as its two siblings: reader landed (internal/cloudclient/deliveries.go:91), writer never did (no producer in cloud/lib writes the column; platform_delivery.ex only casts/stores/validates/emits it), so the operator is shown a blank where the unowned stall should be. dr-w26-s5, named as the writer's closer, is not a filed task.",
      disposition: :has_reader,
      stay:
        {:slice, ["dr-w26-s3", "dr-w26-s5"],
         "KEPT AS THE RECORD (the :780 pin still reads it). dr-w26-s3 built the reader and landed; dr-w26-s5 was never filed — `bp task get dr-w26-s5` returns not_found."}
    },
    %{
      key: "failure_class",
      what: "the ledger's NAMED cause for a failed deployment (DeployLedger.classify/1)",
      surface:
        "GET /v1/sites/:id/deployments and its per-deployment sibling; rendered in the status header by `bp cloud site status`",
      audience:
        "the site's own team, in their terminal — internal/cloudclient/client.go:1207 decodes it into SiteDeployment.FailureClass and internal/cli/cloud_site_cmd.go:1983 renders it. A HUMAN-facing reader, held here as the register's positive control.",
      reason:
        "a register with no reachable instrument in it cannot demonstrate that the derivation works at all — a census where every row is reader-less passes identically when the scanner is broken. This row is the one that reds if ReaderScan stops finding anything.",
      disposition: :has_reader,
      stay: nil
    },
    %{
      key: "request_stats",
      what:
        "the instance's own request rate and p95, probed each beat by the agent's ReqStatsProbe",
      surface:
        "GET /v1/instance/request-stats on the INSTANCE, mounted at api/lib/barkpark_web/router.ex:1633",
      audience:
        "the fleet agent (a machine) on the read side, and the instance operator through the vitals it feeds — held here for a second reason: it is the row that proves the corpus needs api/",
      reason:
        "its two halves live in DIFFERENT trees: internal/agent/report.go:639 names the route it probes, api/lib/barkpark_web/router.ex:1633 mounts it, and five more api/ files name the identifier. D442's corpus omitted api/ entirely, so a key whose readership lives there scored dark by construction. This row makes that concrete and testable.",
      disposition: :has_reader,
      stay: nil
    },
    %{
      key: "coverage_cohorts",
      what:
        "the coverage partition over BOTH never-live cohorts — deferred rows AND the failed-terminating tail the deferral clock is blind to — COVERED / never covered / too young / unreadable, per environment",
      surface:
        "GET /v1/deploy-ledger/census — emitted at the TOP LEVEL of DeployLedger.census/3; and the DAILY DIGEST EMAIL, whose deploy-health block renders the partition beside the rate",
      audience:
        "a human, every morning, WITHOUT being asked to go and look: DailyDigestWorker runs at 06:00 UTC and digest_email.ex renders the sentence. Second surface: the operator's terminal — internal/cloudclient/client.go decodes CoverageCohorts and internal/cli/cloud_deploy_census_cmd.go renders it.",
      reason:
        "REGISTERED AT BIRTH, in the same commit as the key (dr-w32-s3). This census FAILS OPEN — the register is hand-typed and nothing derives the emitted set — so a key that ships without its row is a key this guard silently does not cover. The row is here because the gauge the epic's wind-down rests on must not be the next instrument nobody reads: its reader ships in the same PR rather than being promised to a later slice.",
      disposition: :has_reader,
      stay: nil
    },
    %{
      key: "never_covered_sites",
      what:
        "WHICH {site, environment} pairs are never-covered — the named tail behind the count `coverage_cohorts` reports, bounded at 20 rows and carrying its own unbounded total and truncation marker",
      surface:
        "GET /v1/deploy-ledger/census — emitted on the `coverage_cohorts` node of DeployLedger.census/3, beside the counts it names",
      audience:
        "the operator with a never-covered count in front of them and no idea which site to look at: internal/cloudclient/client.go decodes DeployCoverageSite and internal/cli/cloud_deploy_census_cmd.go's renderDeployCoverageSites prints slug, environment and row count, plus the cut marker when the tail is longer than the list.",
      reason:
        "REGISTERED AT BIRTH, in the same commit as the key (dr-w34-s1) — the doctrine `coverage_cohorts` established one wave earlier. The count it names shipped ANONYMOUS for two waves: `coverage_cohorts/2` already SELECTED site_id and discarded it in the merge, so the never-covered split could be built by environment and never by site. A naming that shipped without a reader would be the same defect one level down — a list nobody can see is not an improvement on a number nobody can act on.",
      disposition: :has_reader,
      stay: nil
    }
  ]

  # THE ANTI-VACUITY FLOOR. A deleted register row would otherwise be a silent
  # green — zero instruments examined is zero reader-less instruments found.
  # Lowered only in the same commit as the instrument that went away.
  @register_floor 8

  # The corpus floor, per root. A `find` that silently returns nothing (a moved
  # tree, a refused-dirs change that eats a whole root) reports every instrument
  # reader-less, which is the deletion law's most dangerous failure mode.
  @corpus_floor 400

  # ---------------------------------------------------------------------------
  # THE THREE STAYED PRs — re-derived 2026-08-09 with `gh pr view`, and the base
  # movement re-derived with `git log -1 origin/main`. Facts, not verdicts: the
  # verdict is computed by `Stay.stayed?/1` below.
  # ---------------------------------------------------------------------------
  @base_moved_at ~U[2026-08-08 23:48:12Z]
  @base_head "0239dd4ee662dd30c4d8da0c6b9a149638224b1d"

  @stayed_prs [
    %{
      pr: 10811,
      names: "coalesced_attempts",
      state: "OPEN",
      merge_state_status: "DIRTY",
      check_runs: 36,
      failures: 0,
      deciding_check_at: ~U[2026-08-08 11:42:08Z],
      base_moved_at: @base_moved_at
    },
    %{
      pr: 11007,
      names: "the delivery timeline's queue legs",
      state: "OPEN",
      merge_state_status: "DIRTY",
      check_runs: 36,
      failures: 0,
      deciding_check_at: ~U[2026-08-08 16:39:37Z],
      base_moved_at: @base_moved_at
    },
    %{
      pr: 11008,
      names: "platform_deliveries rollback/no-op",
      state: "OPEN",
      merge_state_status: "DIRTY",
      check_runs: 32,
      failures: 0,
      deciding_check_at: ~U[2026-08-08 16:40:46Z],
      base_moved_at: @base_moved_at
    }
  ]

  setup_all do
    keys = Enum.map(@register, & &1.key)
    {:ok, hits: ReaderScan.hits(keys), keys: keys}
  end

  # ---------------------------------------------------------------------------
  # THE REGISTER ITSELF
  # ---------------------------------------------------------------------------

  test "every row carries a REQUIRED reason and names both its SURFACE and its AUDIENCE" do
    assert length(@register) >= @register_floor,
           "the register shrank to #{length(@register)} rows (floor #{@register_floor}). " <>
             "Lower the floor in the same commit as the instrument that went away, or restore the row."

    for row <- @register do
      for field <- [:key, :what, :surface, :audience, :reason] do
        value = Map.fetch!(row, field)

        assert is_binary(value) and String.trim(value) != "",
               "#{row.key}: #{field} is empty. Every row states why it is here, where its bytes " <>
                 "land, and WHICH HUMAN can be at that surface — a row missing any of the three " <>
                 "cannot order or refuse a deletion."
      end

      assert row.disposition in [:has_reader, :stay, :deleted],
             "#{row.key}: unknown disposition #{inspect(row.disposition)}"

      # The audience column is the D456 lesson: a surface with no named
      # population is how `deployment_failed` scored as instrumented while
      # every one of its 30 alerts went to one tenant address.
      refute row.audience == row.surface,
             "#{row.key}: audience must name a POPULATION, not repeat the surface."
    end
  end

  test "the corpus is FIVE trees including api/, and it searches snake, camel and Pascal" do
    assert ReaderScan.roots() == ~w(internal cloud/priv/static web js api)

    assert "api" in ReaderScan.roots(),
           "api/ is the tree D442's corpus omitted, and omitting it is why a cross-tree " <>
             "instrument scores dark by construction."

    assert ReaderScan.variants("queued_stall_seconds") ==
             ["queued_stall_seconds", "queuedStallSeconds", "QueuedStallSeconds"]

    files = ReaderScan.files()

    assert length(files) >= @corpus_floor,
           "the corpus collapsed to #{length(files)} files (floor #{@corpus_floor}). " <>
             "A corpus that scans nothing reports every instrument reader-less."

    for root <- ReaderScan.roots() do
      assert Enum.any?(files, &String.starts_with?(&1, root <> "/")),
             "corpus root #{root} contributed ZERO files — it moved, or @extensions no longer " <>
               "covers anything in it."
    end
  end

  test "the scanner CAN find a reader: the control at internal/agent/report.go", ctx do
    control = ReaderScan.hits(["request_stats"])["request_stats"]

    assert Enum.any?(control, &(&1.file == "internal/agent/report.go" and &1.line == 639)),
           """
           the control is missing. internal/agent/report.go:639 reads

               const requestStatsPath = "/v1/instance/request-stats"

           — a code path in `internal/` that NAMES the sibling route. It is the
           control for every zero this census reports out of that same tree: if
           this line cannot be found, a zero is a grep artefact, not an absence.

           found instead: #{inspect(Enum.take(control, 5))}
           """

    # And the register's own positive control resolves.
    assert ctx.hits["failure_class"] != [],
           "failure_class has no derived reader — the derivation is broken, not the instrument."
  end

  test "the api/ half of the corpus is LOAD-BEARING" do
    with_api = ReaderScan.hits(["request_stats"])["request_stats"]

    without_api =
      ReaderScan.hits(["request_stats"], roots: ReaderScan.roots() -- ["api"])["request_stats"]

    api_files =
      with_api |> Enum.filter(&String.starts_with?(&1.file, "api/")) |> Enum.map(& &1.file)

    assert api_files != [],
           "no api/ reader found for request_stats — either the route moved or api/ is not " <>
             "actually being scanned, and D442's blind spot is back."

    assert length(without_api) < length(with_api),
           """
           dropping api/ changed nothing, so the corpus's api/ half is decorative.
           This test exists because D442's corpus OMITTED api/ and therefore
           could not see the reader half of a cross-tree instrument.
           """
  end

  test "COMPILED == UNCOMPILED, on file:line — the speed-up did not re-rule readership", ctx do
    slow = ReaderScan.hits_uncompiled(ctx.keys)

    per_key =
      Enum.map(ctx.keys, fn key ->
        fast_set = MapSet.new(ctx.hits[key], &"#{&1.file}:#{&1.line}")
        slow_set = MapSet.new(slow[key], &"#{&1.file}:#{&1.line}")

        {key, fast_set, slow_set}
      end)

    divergent =
      Enum.reject(per_key, fn {_key, fast, slow} -> MapSet.equal?(fast, slow) end)

    assert divergent == [],
           """
           the compiled scanner and the uncompiled oracle DISAGREE on which
           lines name a key. Sets compared, not counts — two scanners can hit
           the same number of lines and not the same lines.

           #{Enum.map_join(divergent, "\n\n", fn {key, fast, slow} -> """
             #{key}: compiled #{MapSet.size(fast)} vs oracle #{MapSet.size(slow)}
               only compiled: #{inspect(Enum.sort(MapSet.difference(fast, slow)))}
               only oracle:   #{inspect(Enum.sort(MapSet.difference(slow, fast)))}
             """ end)}
           """

    # And the comparison is not vacuously green over empty sets: the register
    # carries keys with real, non-trivial hit sets, so agreement means something.
    assert Enum.count(per_key, fn {_key, fast, _slow} -> MapSet.size(fast) > 10 end) >= 2,
           "no key derived more than 10 readers, so set equality proves almost nothing here: " <>
             inspect(Enum.map(per_key, fn {k, f, _} -> {k, MapSet.size(f)} end))
  end

  test "COMPILED == UNCOMPILED at the EMPTY key set — the one input that raises" do
    # Set equality over the seven register keys says nothing about zero keys,
    # and zero keys is not hypothetical: a derived-admission arm that reflects
    # an empty field list would hand exactly this in. `:binary.compile_pattern/1`
    # raises on `[]`, so without the guarding clause `hits/2` would crash where
    # the oracle returns an empty map.
    assert ReaderScan.hits([]) == %{}
    assert ReaderScan.hits([]) == ReaderScan.hits_uncompiled([])
  end

  # ---------------------------------------------------------------------------
  # THE TWO DIRECTIONS
  # ---------------------------------------------------------------------------

  test "an instrument declared to HAVE a reader still has one", ctx do
    assert violations(@register, ctx.hits, :lost_reader) == [],
           """
           a `:has_reader` row derives ZERO readers. Its reader was taken away and
           nothing else said so.

           #{fmt(violations(@register, ctx.hits, :lost_reader))}
           """
  end

  test "a reader-less row that GAINED a reader reds as ROT — delete the row", ctx do
    assert violations(@register, ctx.hits, :rot) == [],
           """
           a row declared reader-less (`:stay` or `:deleted`) now derives readers.
           THIS IS THE GOOD DIRECTION: its closer landed, or the deletion was
           reverted. Delete the register row, or re-declare it `:has_reader`.

           #{fmt(violations(@register, ctx.hits, :rot))}
           """
  end

  test "MUTATION: a fake reader-less instrument declared `:has_reader` REDS" do
    fake = %{
      key: "publish_clock_shadow_metric",
      what: "a metric nothing emits and nothing reads",
      surface: "nowhere",
      audience: "nobody at all",
      reason: "the mutation that proves this census can lose",
      disposition: :has_reader,
      stay: nil
    }

    register = @register ++ [fake]
    hits = ReaderScan.hits(Enum.map(register, & &1.key))

    assert hits["publish_clock_shadow_metric"] == []

    lost = violations(register, hits, :lost_reader)

    # AMONG, not SOLE: the injected row must be FOUND, not be the only finding.
    # A genuine reader-less row elsewhere in the register is a real finding, and
    # must not read as this instrument breaking.
    assert Enum.any?(
             lost,
             &match?(%{key: "publish_clock_shadow_metric", kind: :lost_reader}, &1)
           ),
           """
           the injected reader-less row did NOT surface as a :lost_reader
           violation. The census cannot see a metric nothing emits and nothing
           reads — the instrument is broken, whatever else it found.

           #{fmt(lost)}
           """
  end

  test "MUTATION: a reader-less row given a REAL reader reds as ROT" do
    # `failure_class` genuinely has readers (client.go:1207, cloud_site_cmd.go).
    # Declaring it `:stay` is exactly the shape of a stale allowlist row.
    rotten = %{
      key: "failure_class",
      what: "the ledger's named failure cause",
      surface: "GET /v1/sites/:id/deployments",
      audience: "the site's own team",
      reason: "the mutation that proves a stale stay cannot hide behind a green",
      disposition: :stay,
      stay: {:data, "a stay that stopped being true"}
    }

    register = Enum.reject(@register, &(&1.key == "failure_class")) ++ [rotten]
    hits = ReaderScan.hits(Enum.map(register, & &1.key))

    rots = violations(register, hits, :rot)
    v = Enum.find(rots, &(&1.key == "failure_class"))

    # AMONG, not SOLE: a second, genuine stale stay elsewhere in the register is
    # a real finding — it must not make this positive control read as instrument
    # failure. `v` stays BOUND so the reader assertion still interrogates the
    # injected row itself, not "some row somewhere".
    assert v,
           """
           the injected stale stay (`failure_class` declared `:stay` while it
           genuinely has readers) did NOT surface as a :rot violation. The
           census cannot catch a stay that stopped being true.

           #{fmt(rots)}
           """

    assert v.kind == :rot
    assert v.readers > 0
  end

  test "the comment stripper refuses a comment and keeps the code line" do
    assert ReaderScan.comment?("// `coalesced_attempts` now lands on the row")
    assert ReaderScan.comment?("  # a prose mention")
    assert ReaderScan.comment?("   * a block-comment continuation")
    refute ReaderScan.comment?("  CoalescedAttempts int `json:\"coalesced_attempts\"`")
  end

  # ---------------------------------------------------------------------------
  # THE STAY
  # ---------------------------------------------------------------------------

  test "RE-DERIVED: all three stayed PRs FAIL the predicate, though their checks are 100% green" do
    for pr <- @stayed_prs do
      assert pr.failures == 0,
             "#{pr.pr}: this test's premise is that the checks are GREEN — re-derive it."

      refute Stay.stayed?(pr),
             """
             #{pr.pr} passes the re-derived stay, which contradicts the measurement
             this predicate was written from. Re-derive with `gh pr view #{pr.pr}`.
             """

      assert :not_conflicting in Stay.refusals(pr),
             "#{pr.pr}: expected mergeStateStatus DIRTY (re-derived 2026-08-09)."

      assert :check_newer_than_base in Stay.refusals(pr),
             """
             #{pr.pr}: its deciding check (#{pr.deciding_check_at}) is expected to PREDATE
             the base movement to #{String.slice(@base_head, 0, 9)} (#{@base_moved_at}).
             GitHub attaches checks to the head sha and never re-fires them when the base
             advances, which is why #{pr.check_runs} green check-runs prove nothing about
             whether this PR can still land.
             """
    end

    # The counterfactual: a PR that IS alive passes. Without this the predicate
    # could be `false` and every assertion above would still hold.
    alive = %{
      state: "OPEN",
      merge_state_status: "UNSTABLE",
      deciding_check_at: DateTime.add(@base_moved_at, 3600, :second),
      base_moved_at: @base_moved_at
    }

    assert Stay.stayed?(alive)
  end

  test "every `:stay` row's stay is valid TODAY, and no stay is a bare PR reference" do
    for %{disposition: :stay} = row <- @register do
      case row.stay do
        {:data, why} ->
          assert String.trim(why) != "", "#{row.key}: a :data stay must say what the data IS."

        {:slice, slices, why} ->
          assert slices != [] and Enum.all?(slices, &(&1 != "")),
                 "#{row.key}: a :slice stay must NAME the slices that close it."

          assert String.trim(why) != "", "#{row.key}: a :slice stay must say what they build."

        {:pr, facts} ->
          assert Stay.stayed?(facts),
                 """
                 #{row.key}: its PR stay does NOT hold today — refused by #{inspect(Stay.refusals(facts))}.
                 Rider 1 is re-derived at build time, never inherited: re-derive it, or delete
                 the instrument.
                 """

        other ->
          flunk("#{row.key}: unknown stay #{inspect(other)}")
      end
    end
  end

  test "the three queued_* columns are IN the register, with the stay naming s3 and s5" do
    for key <- ~w(queued_self_seconds queued_pickup_seconds queued_stall_seconds) do
      row = Enum.find(@register, &(&1.key == key))

      assert row, """
      #{key} is not in the register. D454 rules that the three queued_* columns are
      NOT exempted — exempting the reader-less rows a wave is actively building for
      is exactly how D441's corpus went vacuous.
      """

      assert {:slice, slices, _why} = row.stay
      assert "dr-w26-s3" in slices and "dr-w26-s5" in slices
    end
  end

  # ---------------------------------------------------------------------------
  # THE DELETION
  # ---------------------------------------------------------------------------

  test "a `:deleted` row's key is ABSENT from cloud/lib — a deletion that did not happen is not one" do
    for %{disposition: :deleted} = row <- @register do
      variants = ReaderScan.variants(row.key)

      residue =
        @cloud_lib
        |> ex_files()
        |> Enum.flat_map(fn file ->
          file
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _n} ->
            not ReaderScan.comment?(line) and Enum.any?(variants, &String.contains?(line, &1))
          end)
          |> Enum.map(fn {line, n} ->
            "#{Path.relative_to(file, ReaderScan.repo_root())}:#{n}: #{String.trim(line)}"
          end)
        end)

      assert residue == [],
             """
             #{row.key} is declared DELETED but cloud/lib still emits it:

             #{Enum.join(residue, "\n")}

             Either finish the deletion or take the row back to `:stay` WITH a stay
             that holds today.
             """
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  # The two directions, as data so the mutation tests can drive them.
  defp violations(register, hits, :lost_reader) do
    for %{disposition: :has_reader} = row <- register,
        Map.get(hits, row.key, []) == [],
        do: %{key: row.key, kind: :lost_reader, readers: 0, sample: []}
  end

  defp violations(register, hits, :rot) do
    for %{disposition: d} = row <- register,
        d in [:stay, :deleted],
        found = Map.get(hits, row.key, []),
        found != [],
        do: %{
          key: row.key,
          kind: :rot,
          readers: length(found),
          sample: found |> Enum.take(3) |> Enum.map(&"#{&1.file}:#{&1.line}")
        }
  end

  defp fmt([]), do: "(none)"

  defp fmt(violations) do
    Enum.map_join(violations, "\n", fn v ->
      "  #{v.key} (#{v.kind}, #{v.readers} reader(s)) #{Enum.join(v.sample, ", ")}"
    end)
  end

  defp ex_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      cond do
        File.dir?(path) -> ex_files(path)
        Path.extname(path) in [".ex", ".exs", ".heex"] -> [path]
        true -> []
      end
    end)
  end
end
