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
  there — `internal/agent/report.go` holds the probe (`const requestStatsPath`)
  and `api/lib/barkpark_web/router.ex` MOUNTS the route it probes — so a corpus
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
  first cut and it LOST THE CENSUS'S OWN CONTROL: `internal/agent/report.go`
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

  THE DERIVED ARM NOW EXISTS. It was deferred out of the slice that wrote this
  section while a foreign PR (11169, head b730fbe7a) held this file's tail; that
  PR reached a terminal state on 2026-08-09 without landing, and the arm was
  built on top of what actually shipped. It lives in
  `BarkparkCloud.ReaderLessInstrumentCensus.SchemaCorpus` and in the
  DERIVED ADMISSION block of the test module below, and it inherited both
  corrections above — plus a third the filing could not have known: the DARK
  control it named (`update_unavailable_reason`) gained readers before the arm
  was written, so the arm re-derives its controls rather than inheriting them.
  """

  # The repo root, in the house form every other census here uses
  # (`Path.expand("../..", __DIR__)` and friends). Two facts, both MEASURED on
  # 2026-09-11 (lead-deploy-r8), so the next reader does not re-derive them:
  #
  #   * `scripts/cloud-path-escape-check.sh` does NOT see this literal. Its
  #     resolver normalises `cloud/test/barkpark_cloud/../../..` to the EMPTY
  #     path and `continue`s past it, so `--list-escapes` lists nothing for this
  #     file (the earlier claim that a parent-relative literal here "reds the
  #     gate on arrival" was true only of a literal NAMING a tree, e.g.
  #     `"../../../internal"`; a root-resolving one is skipped). The previous
  #     `Path.dirname/1` walk therefore bought nothing and hid nothing.
  #   * Dispatch coverage for `internal`, `web`, `js` and `api` comes from
  #     `@roots` below, not from any literal: since #17522 the Cloud gate's
  #     census tier DERIVES its path set from this file's `@roots` line
  #     (`cloud-path-escape-check.sh --census-source` names this file, and its
  #     harness proves a synthetic `@roots` takes). Edit `@roots` and the
  #     dispatch condition follows; that is the seam, and it is the only one.
  @repo_root Path.expand("../../..", __DIR__)

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

  NOT THE MERGE PREDICATE, and this moduledoc no longer tries to be one. The
  sentence that stood here ruled on a PR in prose, and went stale: prose has no
  way to be re-checked. A PR's disposition belongs in a register row or in a
  live query, never in a paragraph. This function answers one question only: may
  a reader-less instrument keep its life on the strength of this PR.
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

defmodule BarkparkCloud.ReaderLessInstrumentCensus.SchemaCorpus do
  @moduledoc """
  SIDE A, DERIVED — the admission the hand-typed `@register` could never make.

  The register is a DECLARATION: a key is examined only because a human typed a
  row for it, so an instrument nobody registered is invisible (the FAILING OPEN
  bullet in the census's own moduledoc). This module derives the other half: the
  set of persisted field names the control plane actually has, straight off the
  Ecto schemas, and hands it to the same `ReaderScan` the register uses.

  ## The derivation, and what it is NOT

  `modules/0` reflects over `Application.spec(:barkpark_cloud, :modules)` and
  keeps every `BarkparkCloud.*` module that exports `__schema__/1`.
  `field_names/1` unions their `__schema__(:fields)`. Both are computed AT BUILD
  TIME, every run, from the compiled application — never transcribed. That is
  the whole point: a transcribed corpus is a snapshot that silently stops
  matching the tree, which is the defect this epic exists to end.

  It does NOT subsume the register and must never be made to. Three of the
  register's keys — `publish_clock`, `failure_class`, `request_stats` — are not
  schema fields at all; they are envelope nodes. A schema-derived admission
  therefore sits BESIDE the hand-typed register, and swapping one for the other
  would drop instruments this census is watching.

  ## THE EXEMPTION PATTERN, STATED VERBATIM

  Some persisted fields are reader-less BY DESIGN and a "give it a reader"
  disposition would be actively wrong for them: secret material whose entire
  purpose is that no consumer tree ever names it. Until now that class was
  invoked and never written down — a prior brief spoke of "a DERIVED
  secret-class exemption (19 rows by pattern)" without anywhere stating the
  pattern, which makes the number unreproducible and the split unauditable.

  So here is the pattern, and it is the code below, not a paraphrase of it:

      A field is SECRET-CLASS iff its name contains the substring "encrypted",
      OR ends with "_hash", OR ends with "_secret", OR ends with
      "_recovery_codes".

  Nothing else. It is deliberately narrow and deliberately DUMB: it keys on the
  name, so a reviewer can apply it by eye, and it cannot be tuned to hit a
  target count because the count is never asserted anywhere. THE MEMBERSHIP IS
  THE EVIDENCE AND THE COUNT IS A CONSEQUENCE — `partition/2` returns all three
  sets and the census PRINTS them, so a pattern that starts swallowing
  non-secrets is visible in the printed list on the very next run.

  ## The three sets

    * DARK      — a schema field name no code path in the five reader trees names.
    * EXEMPT    — the secret-class subset of DARK, by the pattern above.
    * RESIDUAL  — DARK minus EXEMPT: the fields that owe an explanation.

  A residual field is NOT a defect. It is a QUESTION, and the census's answer is
  that every one of them must carry a stated, individual disposition in the test
  module's `@residual_dispositions`. `faults/1` refuses three ways at once: a
  residual field with no disposition, a disposition for a field that stopped
  being residual, and two dispositions with identical text — the last being the
  only mechanical defence against 50 placeholder sentences wearing the costume
  of an audit.
  """

  @type partition :: %{dark: [binary()], exempt: [binary()], residual: [binary()]}

  @doc """
  Every loaded `BarkparkCloud.*` Ecto schema module, sorted.

  Reflected, never listed. A hand-listed corpus is how a derivation quietly
  stops covering a schema somebody added last week.
  """
  @spec modules() :: [module()]
  def modules do
    :barkpark_cloud
    |> Application.spec(:modules)
    |> Kernel.||([])
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :__schema__, 1) and
        match?(["BarkparkCloud" | _], Module.split(mod))
    end)
    |> Enum.sort()
  end

  @doc "The distinct field NAMES across the given schema modules, sorted."
  @spec field_names([module()]) :: [binary()]
  def field_names(mods) do
    mods
    |> Enum.flat_map(fn mod -> mod |> apply(:__schema__, [:fields]) |> Enum.map(&to_string/1) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The exemption pattern, as the single function that implements it. See the
  moduledoc for the sentence this is the code of.

      iex> secret_class?("smtp_password_encrypted")
      true
      iex> secret_class?("device_code_hash")
      true
      iex> secret_class?("cf_key_path")
      false
  """
  @spec secret_class?(binary()) :: boolean()
  def secret_class?(name) when is_binary(name) do
    String.contains?(name, "encrypted") or
      String.ends_with?(name, "_hash") or
      String.ends_with?(name, "_secret") or
      String.ends_with?(name, "_recovery_codes")
  end

  @doc """
  `%{dark: …, exempt: …, residual: …}` for a field set and a `ReaderScan.hits/2`
  map. A field absent from `hits` is treated as dark, so a scan that skipped a
  key errs toward reporting MORE work, never less.
  """
  @spec partition([binary()], %{binary() => list()}) :: partition()
  def partition(fields, hits) do
    dark = fields |> Enum.filter(&(Map.get(hits, &1, []) == [])) |> Enum.sort()
    {exempt, residual} = Enum.split_with(dark, &secret_class?/1)

    %{dark: dark, exempt: exempt, residual: residual}
  end

  @doc """
  Every way the derived admission can be WRONG, as `{kind, detail}` data so the
  mutation arms can drive it with mutated inputs instead of asserting on a
  message string.

  `input` carries `:modules`, `:fields`, `:hits`, `:dispositions`, `:floors`
  (`%{modules: n, fields: n, disposition_bytes: n}`) and `:controls`
  (`%{module: Mod, lit: name, dark: name}`).

  THE FLOORS ARE ON THE INPUTS, BY NAME. A reflection that silently returned
  three modules would produce a tiny dark set, a tiny residual set, and a green
  run — "fewer keys examined" reads identically to "fewer keys in trouble". So
  the control module and both control FIELDS are required to be present by
  their own names, and the counts carry a floor underneath them.
  """
  @spec faults(map()) :: [{atom(), binary()}]
  def faults(input) do
    %{
      modules: mods,
      fields: fields,
      hits: hits,
      dispositions: dispositions,
      floors: floors,
      controls: controls
    } = input

    %{residual: residual} = partition(fields, hits)
    lit_hits = Map.get(hits, controls.lit, [])
    dark_hits = Map.get(hits, controls.dark, [])

    disposed = dispositions |> Map.keys() |> Enum.sort()
    texts = Map.values(dispositions)

    List.flatten([
      if(length(mods) >= floors.modules,
        do: [],
        else: [
          {:module_corpus_too_small,
           "the reflection returned #{length(mods)} schema modules, floor #{floors.modules}. " <>
             "A shrunken reflection examines fewer keys and reports fewer problems."}
        ]
      ),
      if(controls.module in mods,
        do: [],
        else: [
          {:module_control_missing,
           "#{inspect(controls.module)} is not among the reflected schema modules. It owns " <>
             "the dark control field, so without it the dark half of this arm measures nothing."}
        ]
      ),
      if(length(fields) >= floors.fields,
        do: [],
        else: [
          {:field_corpus_too_small,
           "the reflection returned #{length(fields)} distinct field names, floor " <>
             "#{floors.fields}."}
        ]
      ),
      if(controls.lit in fields,
        do: [],
        else: [{:lit_control_absent, "#{controls.lit} is not a schema field any more"}]
      ),
      if(controls.dark in fields,
        do: [],
        else: [{:dark_control_absent, "#{controls.dark} is not a schema field any more"}]
      ),
      if(lit_hits != [],
        do: [],
        else: [
          {:lit_control_went_dark,
           "#{controls.lit} derived ZERO readers. It has real ones, so this is the SCANNER " <>
             "failing, and every zero in the dark set below is a grep artefact."}
        ]
      ),
      if(dark_hits == [],
        do: [],
        else: [
          {:dark_control_went_lit,
           "#{controls.dark} derived #{length(dark_hits)} reader(s): " <>
             inspect(Enum.take(dark_hits, 3)) <>
             ". Either the scanner now matches everything, or a secret-class column really is " <>
             "named in a consumer tree — and the second reading is a finding, not a green."}
        ]
      ),
      for name <- residual -- disposed do
        {:undisposed,
         "#{name} is reader-less and carries no disposition. Say what it is and why nothing " <>
           "reads it, or delete the column."}
      end,
      for name <- disposed -- residual do
        {:stale_disposition,
         "#{name} carries a disposition but is no longer residual — it gained a reader, became " <>
           "secret-class, or left the schema. Delete the entry; a disposition for a field that " <>
           "no longer owes one is the allowlist rot this census exists to catch."}
      end,
      for {name, text} <- dispositions,
          byte_size(String.trim(text)) < floors.disposition_bytes do
        {:thin_disposition,
         "#{name}: its disposition is #{byte_size(String.trim(text))} bytes, floor " <>
           "#{floors.disposition_bytes}. A disposition names the reader it has instead, or the " <>
           "reason it must not have one."}
      end,
      texts
      |> Enum.frequencies()
      |> Enum.filter(fn {_text, n} -> n > 1 end)
      |> Enum.map(fn {text, n} ->
        keys = for {k, v} <- dispositions, v == text, do: k

        {:boilerplate_disposition,
         "#{n} fields share one disposition verbatim (#{Enum.join(Enum.sort(keys), ", ")}): " <>
           String.slice(text, 0, 60) <>
           "… An allowlist with the same sentence pasted beside every row is still an allowlist."}
      end)
    ])
  end
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

    * DISPATCH — STILL OPEN, and now routed rather than merely filed.
      `.github/workflows/cloud.yml` dispatches this suite on `cloud/**` and the
      paths declared in `scripts/cloud-path-escape-check.sh`. `internal/` IS
      declared there; `web/`, `js/` and `api/` are NOT, so a commit that adds a
      reader ONLY in those three trees does not re-run this census, and the ROT
      is caught on the next cloud-touching commit rather than on the commit that
      caused it. The direction is safe — a LATE red, never a false green.

      THE OBVIOUS FIX WAS MEASURED AND REFUSED, which is why this paragraph is
      still here. Declaring `api/**`, `web/**` and `js/**` was built and costed
      on this tree: over 60 days / 5008 commits on main it moves dispatch from
      1641 to 3874 commits, i.e. 33% -> 77% of all commits running the
      Postgres-backed Cloud `test` job, with `api/**` alone accounting for 1438.
      Paying that to re-run ONE census file is the wrong shape: the census does
      not need the whole Cloud suite dispatched, it needs ITSELF dispatched. So
      the remedy moved to a job-level path condition on this test plus a
      census-only tier in the ratchet, re-filed for the gates lane 2026-09-10.
      The number is recorded here so the next reader does not re-derive it and
      reach the same dead end.
    * FAILING OPEN. An instrument nobody registered is invisible here, exactly
      as `deploy_signal_audience_census_test.exs` admits of its own registry.
      Nothing syntactic closes that hole. `queued_seconds` WAS the honest
      example, and it stopped being one: it is emitted by
      `platform_delivery.ex:356`, and the claim that stood here — zero readers in
      all five trees — is false today. `internal/cli/cloud_deliveries_cmd.go:398`
      and `:401` read it and `internal/cloudclient/deliveries.go` decodes it, so
      it is registered below as `:has_reader`. The hole this bullet names is
      real; the example it used had been overtaken. Filed as
      `dr-w26-followup-queued-seconds-disposition`.
  """

  use ExUnit.Case, async: true

  alias BarkparkCloud.ReaderLessInstrumentCensus.ReaderScan
  alias BarkparkCloud.ReaderLessInstrumentCensus.Stay
  alias BarkparkCloud.ReaderLessInstrumentCensus.SchemaCorpus

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
        "ruled the epic's vital in W11, written in W12, given a production caller in W14, and read by zero code paths in thirteen waves. Zero readers across all five corpus trees, no open PR names it, and its stay under any rider is empty. THE FIRST DELETION (dr-w26-s6-reader-less-instrument-guard-and-the-first-deletion).",
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
        "the terminal, as of dr-w23-s4-census-table-stops-hiding: internal/cloudclient/client.go decodes the node into `DeployCensus.CoalescedAttempts *DeployCoalescedAttempts` and internal/cli/cloud_deploy_census_cmd.go renders it on the basis line of every `-o table` deploy census. A WHOLE reader, unlike the queued_* legs below: this key has a real writer too (auto_deploy_worker.ex:412, ~31,697 rows), so the rendered number means something.",
      reason:
        "RE-DECLARED (was `:stay`). THE CLOSER LANDED, which is the good direction this register exists to detect: dr-w23-s4-census-table-stops-hiding added the typed decode and the render, so the row derives 13 readers and correctly redded as :rot under `:stay`. The old reason is preserved as the record because it is the more interesting half — D442 scored this key \'1 reader hit\', and that hit was the COMMENT at cloud_deploy_census_cmd.go:538 asserting `coalesced_attempts` \'is not in this envelope\', which was FALSE on main (deploy_ledger.ex:893 emits it inside census/3). The true reader count was 0, a comment was being counted as readership, and the comment was wrong about the very fact it was being counted for. dr-w23-s4-census-table-stops-hiding deletes that comment and replaces the window-independent frozen sentence beside it with this window\'s own measured count — or, before @coalesced_counter_since, with the producer\'s own refusal rendered as a named absence and never as a 0.",
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
        "the terminal, as of dr-w26-s3-deliveries-reader-stops-lying-about-carried: internal/cloudclient/deliveries.go:89 decodes the leg and internal/cli/cloud_deliveries_cmd.go:450 renders it. HALF a reader, and the register says which half — see `reason`.",
      reason:
        "RE-DECLARED 2026-08-09 (was `:stay`). The READER landed — internal/cloudclient/deliveries.go:89-91 decodes all three legs as *int and cloud_deliveries_cmd.go:450 renders them — so this row derives 5 readers and correctly redded as :rot under `:stay`. THE WRITER NEVER DID: cloud/lib/barkpark_cloud/platform_delivery.ex carries cast (:144), schema field (:173), validate (:249) and to_json emit (:452) and NO producer anywhere in cloud/lib computes a value (`grep -rn queued_self_seconds cloud/lib | grep -v platform_delivery.ex` is EMPTY), so the column is emitted ALWAYS-NULL and the terminal renders a hole. This census measures READERSHIP only, which is why `:has_reader` is true here while the number is still meaningless — the honest fact a plain green would hide. The slice the old stay named as the writer's closer is dr-w26-s5-crown-gets-its-writer; its disposition is a live fact this file does not restate. Deleting the row instead would have taken the guard with it (@register_floor 7 trips and the :780 pin fails); re-declaring keeps it and ADDS the :lost_reader direction.",
      disposition: :has_reader,
      stay:
        {:slice,
         [
           "dr-w26-s3-deliveries-reader-stops-lying-about-carried",
           "dr-w26-s5-crown-gets-its-writer"
         ],
         "KEPT AS THE RECORD, not as a live stay (this row is now `:has_reader`, so the stay-validity test no longer reads it, but the :780 pin does). dr-w26-s3-deliveries-reader-stops-lying-about-carried built the reader and LANDED. dr-w26-s5-crown-gets-its-writer was named as the writer. The sentence that stood here ruled it unfiled, on the strength of a lookup by the slug's STEM — the family-wave-slice part with the descriptive tail cut off. That stem resolves to nothing, because every id on this board carries the tail. The row exists under its full slug. That is why the TIER 1 guard below refuses a truncated id: the census drew a verdict from an instrument that could not see the thing it was ruling on, which is the exact failure this register exists to catch."}
    },
    %{
      key: "queued_seconds",
      what: "the whole queue wait: run created until a runner picked the job up",
      surface:
        "PlatformDelivery.to_json/1 (platform_delivery.ex:356), on the deliveries envelope",
      audience:
        "the terminal: internal/cloudclient/deliveries.go decodes the leg and " <>
          "internal/cli/cloud_deliveries_cmd.go:398/:401 renders it, naming the gap " <>
          "between the run being created and a runner picking the job up",
      reason:
        "REGISTERED BY dr-w27-s3-census-arms-survive-their-own-success, and the point is WHY it was not registered before. " <>
          "The FAILING-OPEN bullet in this module's moduledoc used this key as its honest example of the hole — " <>
          "an instrument nobody registered is invisible to this census — on the strength of `zero readers in all five trees`. " <>
          "That was true when written and false by the time it was read: the readers above are on origin/main today. " <>
          "The example outlived its own measurement, which is the same decay the TIER 2 guard now refuses in prose. " <>
          "Registering it does NOT close the failing-open hole — nothing syntactic derives the emitted set, so the hole is real — " <>
          "it removes the one stale illustration that made the hole look smaller than it is.",
      disposition: :has_reader,
      stay: nil
    },
    %{
      key: "queued_pickup_seconds",
      what: "the queue leg spent waiting for a runner to pick the delivery up",
      surface:
        "PlatformDelivery.to_json/1 (platform_delivery.ex:358), on the deliveries envelope",
      audience:
        "the terminal, as of dr-w26-s3-deliveries-reader-stops-lying-about-carried: internal/cloudclient/deliveries.go:90 decodes the leg, cloud_deliveries_cmd.go:450 renders it — same half-a-reader state as its sibling",
      reason:
        "RE-DECLARED 2026-08-09 (was `:stay`), same measured state as queued_self_seconds: the READER landed (internal/cloudclient/deliveries.go:90) and the WRITER never did — platform_delivery.ex casts, stores, validates and emits the column and no producer in cloud/lib computes it, so it is emitted always-null. `:has_reader` is a readership claim, not a claim that the number means anything. dr-w26-s5-crown-gets-its-writer is the writer's named closer; its disposition is a live fact, not a claim carried here.",
      disposition: :has_reader,
      stay:
        {:slice,
         [
           "dr-w26-s3-deliveries-reader-stops-lying-about-carried",
           "dr-w26-s5-crown-gets-its-writer"
         ],
         "KEPT AS THE RECORD (the :780 pin still reads it). dr-w26-s3-deliveries-reader-stops-lying-about-carried built the reader; dr-w26-s5-crown-gets-its-writer is the writer's named closer. Neither disposition is restated here — a slug is a pointer, and this file stopped ruling on pointers."}
    },
    %{
      key: "queued_stall_seconds",
      what:
        "the queue leg that is neither self-inflicted nor pickup — the stall nobody owns, which is the one worth alerting on",
      surface:
        "PlatformDelivery.to_json/1 (platform_delivery.ex:359), on the deliveries envelope",
      audience:
        "the terminal, as of dr-w26-s3-deliveries-reader-stops-lying-about-carried: internal/cloudclient/deliveries.go:91 decodes the leg, cloud_deliveries_cmd.go:450 renders it — and this is the leg whose absence a platform operator would most need, which is why an always-null render is worse here than anywhere else",
      reason:
        "RE-DECLARED 2026-08-09 (was `:stay`), same measured state as its two siblings: reader landed (internal/cloudclient/deliveries.go:91), writer never did (no producer in cloud/lib writes the column; platform_delivery.ex only casts/stores/validates/emits it), so the operator is shown a blank where the unowned stall should be. dr-w26-s5-crown-gets-its-writer is named as the writer's closer; its disposition is a live fact, not a claim carried here.",
      disposition: :has_reader,
      stay:
        {:slice,
         [
           "dr-w26-s3-deliveries-reader-stops-lying-about-carried",
           "dr-w26-s5-crown-gets-its-writer"
         ],
         "KEPT AS THE RECORD (the :780 pin still reads it). dr-w26-s3-deliveries-reader-stops-lying-about-carried built the reader; dr-w26-s5-crown-gets-its-writer is the writer's named closer. Neither disposition is restated here — a slug is a pointer, and this file stopped ruling on pointers."}
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
        "its two halves live in DIFFERENT trees: internal/agent/report.go names the route it probes (`const requestStatsPath`), api/lib/barkpark_web/router.ex mounts it, and five more api/ files name the identifier. D442's corpus omitted api/ entirely, so a key whose readership lives there scored dark by construction. This row makes that concrete and testable.",
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
        "REGISTERED AT BIRTH, in the same commit as the key (dr-w32-s3-coverage-gauge-and-the-failed-tail). This census FAILS OPEN — the register is hand-typed and nothing derives the emitted set — so a key that ships without its row is a key this guard silently does not cover. The row is here because the gauge the epic's wind-down rests on must not be the next instrument nobody reads: its reader ships in the same PR rather than being promised to a later slice.",
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
        "REGISTERED AT BIRTH, in the same commit as the key (dr-w34-s1-coverage-envelope-window-and-sites) — the doctrine `coverage_cohorts` established one wave earlier. The count it names shipped ANONYMOUS for two waves: `coverage_cohorts/2` already SELECTED site_id and discarded it in the merge, so the never-covered split could be built by environment and never by site. A naming that shipped without a reader would be the same defect one level down — a list nobody can see is not an improvement on a number nobody can act on.",
      disposition: :has_reader,
      stay: nil
    },
    %{
      key: "claim_leg",
      what:
        "WHICH population holds a hostname another tenant just asked for — the leg `Registry.claim_leg/2` returns (`admin_credential`, `recent_usage_sample`, `active_subscription`, `agent_reporting`, `active_job`, `within_grace`), i.e. whether a refusal means `somebody is paying for that name` or `a job is mid-flight, wait a minute`",
      surface:
        "POST /v1/barkparks/:id/domain, on the 409 body beside `error: \"taken\"` — merged in by persist_and_enqueue_domain/4 from Registry.provisioning_fqdn_claim_disclosure/2. Its SECOND surface is the one it has always had: the Logger.info line in provisioning_fqdn_taken?/2, which carries the fuller sentence",
      audience:
        "the team admin who typed the hostname, in their own browser — POST /v1/barkparks/:id/domain is require_current_team_admin, so the population is the asking team\'s own owners and admins, the only people who can act on the refusal. NOT the holder, who is routinely a different team and is told nothing: the operator sentence that names the holding row stays in the log, and the wire carries a coarse category plus a caller-safe remedy. The console is NOT yet in that audience — cloud/priv/static/app.js attachDomainFailureCopy answers every `taken` with the fixed string `That domain is already in use.` and drops the body\'s other keys, so today the leg reaches a human through the raw API response only",
      reason:
        "REGISTERED AT BIRTH, in the same commit as the key (dr-w26-bl-claim-leg-refusal-reaches-no-human), by the doctrine `coverage_cohorts` established. The defect this key closes is the one this whole register exists to name: `claim_leg/2` wrote a careful per-leg sentence and the only path it had to a human was a server log with no UI, no alert and no CLI surface, while the API rendered six distinct refusals as one word. Registering it at birth is also the honest way to record what did NOT ship — the console render — as a register row rather than as a promise in a comment.",
      disposition: :stay,
      stay:
        {:slice, ["dr-w26-bl-console-relays-the-claim-leg"],
         "READER-LESS ACROSS THE FIVE ROOTS, and the register says exactly where the gap is rather than dressing the API response up as readership. The key is emitted and a person CAN see it (curl, or any direct API client), but no code path in internal/, cloud/priv/static, web, js or api names it: the console\'s attachDomainFailureCopy branches on `error` and returns a fixed sentence for `taken`, so it neither decodes nor renders the leg, and there is no Go cloudclient verb for POST /v1/barkparks/:id/domain at all. The named closer relays the leg in the console the way the already_attached arm one line above it already relays `detail`. That edit is in cloud/priv/static/app.js, outside this slice\'s fence, which is why it is a stay and not a co-merged half."}
    }
  ]

  # THE ANTI-VACUITY FLOOR. A deleted register row would otherwise be a silent
  # green — zero instruments examined is zero reader-less instruments found.
  # Moved only in the same commit as the instrument that arrived or went away.
  #
  # RE-DERIVED 2026-09-10 (dr-w27-bl-register-floor-lags-the-register). It stood
  # at 9 while `@register` carried 10 rows, so the floor had a row of SLACK:
  # deleting any single row — including `queued_seconds`, the row the wave
  # before it had just added — still satisfied `>=` and the register shrank
  # silently. That is precisely the deletion the floor exists to refuse.
  #
  # HAND-TYPED, and compared with `==`, for two reasons:
  #
  #   * `@register_floor length(@register)` would read the expected value off
  #     the very thing it guards. That assertion can never fail, in either
  #     direction, and a guard that cannot lose measures nothing.
  #   * `>=` is how the slack got here in the first place: it is silent when the
  #     register GROWS, so the floor lags every addition until somebody notices.
  #     Under `==` an addition reds too, and the co-edit is forced at the moment
  #     the row lands rather than a wave later. (Same lesson as the payload
  #     census's `@go_tag_pinned`, which shipped one tag of slack under `>=`.)
  #
  # RAISED 10 -> 11 in the commit that added `claim_leg`
  # (dr-w26-bl-claim-leg-refusal-reaches-no-human). That co-edit is the `==`
  # comparison doing the work it was tightened for: under `>=` the addition
  # would have been silent and the floor would have lagged by one again.
  @register_floor 11

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

    # The DERIVED corpus, reflected once for the whole file. Both sides are
    # computed here and never transcribed: the module list, the field list and
    # the reader scan over all of them.
    schema_modules = SchemaCorpus.modules()
    schema_fields = SchemaCorpus.field_names(schema_modules)

    {:ok,
     hits: ReaderScan.hits(keys),
     keys: keys,
     schema_modules: schema_modules,
     schema_fields: schema_fields,
     schema_hits: ReaderScan.hits(schema_fields)}
  end

  # ---------------------------------------------------------------------------
  # THE REGISTER ITSELF
  # ---------------------------------------------------------------------------

  test "every row carries a REQUIRED reason and names both its SURFACE and its AUDIENCE" do
    assert length(@register) == @register_floor,
           "the register carries #{length(@register)} rows, the PIN is EXACTLY " <>
             "#{@register_floor}. FEWER: an instrument left the register — restore the row, or " <>
             "lower the pin in the same commit as the instrument that went away. MORE: an " <>
             "instrument arrived — raise the pin in the same commit, so the floor can never " <>
             "again lag the register it guards."

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

  # THE CONTROL IS ANCHORED ON THE CONST'S TEXT, NEVER ON ITS LINE NUMBER.
  # This arm used to assert `&1.line == 639`. Lines inserted ABOVE the const
  # moved it to :659 and the arm redded over an edit that touched nothing it
  # measures — while its own `found instead:` list carried the correct line the
  # whole time. THE SCANNER WAS NEVER BLIND; ONLY THE PIN WAS STALE.
  #
  # A pin that cannot tell "I am reading the wrong window" from "the thing is
  # gone" will eventually read the wrong window (task-29644998e128dd9f). So the
  # line is RESOLVED by reading report.go, and the two failures the single
  # number used to conflate now print different sentences:
  #
  #   the control TEXT is gone from report.go  -> a finding about internal/
  #   the SCANNER missed a line that IS there  -> a finding about this census
  #
  # THIS DERIVATION WEAKENS NOTHING, and the distinction matters because the
  # floors in the sibling payload census must NOT be derived: those bound a
  # count they measure, so deriving them can never red. This resolves an
  # ANCHOR — the const's own source text, which is what the arm was always
  # about — and the assertion still requires the scanner to have reached that
  # exact line independently.
  @control_file "internal/agent/report.go"
  @control_text ~S(const requestStatsPath = "/v1/instance/request-stats")

  # {:ok, line} | {:error, why} — never raises, so the arm says WHICH half broke
  # instead of dying inside a helper.
  defp control_line do
    case File.read(Path.join(ReaderScan.repo_root(), @control_file)) do
      {:ok, src} ->
        src
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {l, _} -> String.contains?(l, @control_text) end)
        |> case do
          [{_, line}] ->
            {:ok, line}

          [] ->
            {:error, "the control text does not occur in #{@control_file} at all"}

          many ->
            {:error,
             "the control text occurs #{length(many)}x in #{@control_file} (lines " <>
               "#{Enum.map_join(many, ", ", fn {_, l} -> l end)}) — an ambiguous anchor " <>
               "proves nothing about WHICH site the scanner reached"}
        end

      {:error, reason} ->
        {:error, "#{@control_file} could not be read: #{inspect(reason)}"}
    end
  end

  test "the scanner CAN find a reader: the control at internal/agent/report.go", ctx do
    control = ReaderScan.hits(["request_stats"])["request_stats"]

    # HALF ONE — the control itself. A red here says `internal/` moved and this
    # census is uninstrumented. It is NOT a statement about the scanner.
    line =
      case control_line() do
        {:ok, line} ->
          line

        {:error, why} ->
          flunk("""
          THE CONTROL TEXT IS GONE, so this census has no positive control at all.

          expected, in #{@control_file}:

              #{@control_text}

          #{why}

          Re-point @control_text at whatever code path in `internal/` now NAMES
          the sibling route. Do NOT delete this arm and do NOT pin a line number
          back into it — without a control, every zero this census reports is
          indistinguishable from a grep artefact.
          """)
      end

    # HALF TWO — the scanner. The text exists at a known line; the scanner must
    # have reached it independently.
    assert Enum.any?(control, &(&1.file == @control_file and &1.line == line)),
           """
           THE SCANNER MISSED A LINE THAT IS THERE. #{@control_file}:#{line} reads

               #{@control_text}

           — a code path in `internal/` that NAMES the sibling route. It is the
           control for every zero this census reports out of that same tree: if
           this line cannot be found, a zero is a grep artefact, not an absence.

           The line was RESOLVED by reading #{@control_file}, never transcribed,
           so this failure is about the SCANNER and can never be a stale pin.

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

      assert "dr-w26-s3-deliveries-reader-stops-lying-about-carried" in slices and
               "dr-w26-s5-crown-gets-its-writer" in slices
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

  # ---------------------------------------------------------------------------
  # THE DERIVED ADMISSION — the third column
  #
  # The register above is a DECLARATION and admits a key only because a human
  # typed a row. This arm derives the persisted field set from the compiled
  # schemas and asks the same question of every one of them at once. It sits
  # BESIDE the register, never in place of it: `publish_clock`, `failure_class`
  # and `request_stats` are envelope nodes, not schema fields, so derivation
  # alone would drop three instruments this census is watching.
  #
  # NOTHING HERE IS TRANSCRIBED. The module set, the field set, the dark set,
  # the exempt set and the residual set are all computed on every run, and the
  # test PRINTS their membership. No count is asserted as an equality anywhere:
  # earlier drafts of this arm carried "49 dark" and "30 residual" from a brief,
  # and by the time the arm was built the true figures were different in three
  # places at once — so a count pinned here would be measuring the calendar.
  # The floors below are FLOORS, and they are on the INPUTS.
  # ---------------------------------------------------------------------------

  # THE TWO CONTROLS, RE-DERIVED 2026-09-11 AGAINST ORIGIN/MAIN — NOT INHERITED.
  #
  # The brief that filed this arm named `update_unavailable_reason` as the free
  # DARK control and warned, correctly, that a sibling slice was about to give
  # it a reader and move the control. IT MOVED. Re-derived on this tree the key
  # is read by `cloud/priv/static/__app.test.mjs` (`hooks.updateBadge` and
  # `hooks.updateRefusalReason` both take it), so it is no longer dark — and it
  # is exactly the right LIT control instead: a schema field with real readers,
  # whose zero would mean the scanner had stopped finding anything at all.
  #
  # The DARK control is `smtp_password_encrypted`. It is chosen for a structural
  # reason rather than a measured one, because a control picked only for being
  # dark today is a control with an expiry date: an SMTP password is secret
  # material, so its name appearing in `internal/`, `cloud/priv/static`, `web`,
  # `js` or `api` would be a FINDING and not a maintenance chore. It is dark
  # today, it is dark by design, and the day it goes lit somebody needs to know.
  #
  # The two together pin BOTH directions: a scanner that finds nothing reds on
  # the lit control, a scanner that finds everything reds on the dark one.
  @schema_module_control BarkparkCloud.Notifications.EmailSettings
  @schema_lit_control "update_unavailable_reason"
  @schema_dark_control "smtp_password_encrypted"

  # Floors, not pins. The reflection returned 30 modules / 265 distinct field
  # names on 2026-09-11; a corpus that halves is a broken reflection, and a
  # corpus that grows is Tuesday.
  @schema_module_floor 20
  @schema_field_floor 180

  # A disposition shorter than this is a placeholder. 60 bytes is roughly one
  # clause — enough to be a sentence about THIS field, not enough to be "n/a".
  @disposition_floor 60

  # THE RESIDUAL DISPOSITIONS. One entry per reader-less, non-secret-class
  # schema field, and each one says WHAT the field is and WHY no consumer tree
  # names it. They are asserted DISTINCT (see `:boilerplate_disposition`),
  # because the only failure mode a floor cannot catch is fifty copies of the
  # same sentence. Every claim below is anchored at file+function or file:line
  # in `cloud/lib`.
  @residual_dispositions %{
    "alerted_at" =>
      "the deploy-rate episode LATCH: notifications.ex:769 refuses a second notice while it is non-nil, and every non-red reading clears it (notifications.ex:845). Its audience is the suppressor itself — a human sees the mail, not the latch that rationed it.",
    "apply_arming_checked_at" =>
      "the staleness stamp for the apply-arming probe, written at registry.ex:4786 and :5259. barkpark.ex:330 says it plainly: it records HOW STALE the arming reading is, and only the arming decision in cloud/lib consults it. No envelope carries it.",
    "autoupdate_halted" =>
      "the fleet-wide autoupdate kill switch, read by Registry.autoupdate_halted?/0 (registry.ex:5405) and flipped by set_autoupdate_halted/1. It gates a worker and has no wire surface at all — an operator throws it by function call, which is why nothing in five trees names it.",
    "box_refusal_code" =>
      "the BOX's own code word for a refusal (sites/deploy.ex:1750). It is TRANSLATED, not dark: deploy_ledger.ex:1202 buckets it into the ledger's named cause, and that cause is `failure_class` — a registered row with real readers. The raw code word reaching a terminal would add vocabulary nobody outside the box owns.",
    "build_sha256" =>
      "the digest of what is actually BEING SERVED, stamped from report.served_sha256 (sites/deploy.ex:1356) rather than from the staged artifact, per charter D188. It is compared server-side to detect drift; a rendered hex digest tells a human nothing the drift verdict does not.",
    "cf_cert_path" =>
      "the on-disk path of the Cloudflare Origin-CA certificate, written by cloudflare/origin_ca.ex:87 and declared at site.ex:247. A filesystem path ON THE CONTROL-PLANE BOX: relaying it to any consumer tree discloses the control plane's own layout, so darkness is the correct state and not a gap.",
    "cf_key_path" =>
      "the PRIVATE-KEY half of the Origin-CA pair (origin_ca.ex:88). Same class as its cert sibling and one degree worse: the string names where a private key sits on disk. The exemption pattern does not catch it — the name says `path`, not `secret` — which is precisely why it needs a stated disposition rather than a silent pass.",
    "cf_domain" =>
      "the zone-side hostname the A record was created under (web/router.ex:14581). The human-facing name is the site's own domain; this is Cloudflare-side bookkeeping, and the only path that reads it back is teardown (web/router.ex:15224), which reports the failure in an operator sentence, not a field.",
    "cf_record_id" =>
      "the opaque Cloudflare record handle, kept for exactly one purpose: DELETE the A record at teardown (web/router.ex:8672 pairs it with cf_zone_id). A vendor handle no caller outside cloud/lib could act on if it had it.",
    "cf_zone_id" =>
      "the Cloudflare zone handle. Its absence from the consumer trees is a DECLARED refusal rather than an oversight: web/router.ex:5381 states that vendor error bodies can carry account/zone internals and that they are not relayed to callers. A render here would reopen what that code deliberately closes.",
    "coalesced_last_at" =>
      "the timestamp half of the coalescing pair whose COUNT is registered and rendered above. auto_deploy_worker.ex:498 writes it inside an update_all and deployment.ex:688 keeps both out of the changeset on purpose. The count is what the census basis line needs; the last-at is a write-side breadcrumb for a query, not a number for a person.",
    "consecutive_red" =>
      "the tick counter that decides WHEN to alert: notifications.ex:763 compares it with DeployRateAlert.consecutive_ticks() and notifications.ex:840 increments it. It is an input to a threshold whose OUTPUT is the mail; rendering the counter would publish the threshold's internals without telling anyone anything new.",
    "content_binding_checked_at" =>
      "EMITTED AND UNDECODED, which makes it the most interesting row here: web/router.ex:13854 puts it on the sites envelope, so the bytes leave the building, and no code path in five trees names it. Unlike its neighbours this one is a candidate for a console render, not for a deletion.",
    "content_binding_verdict" =>
      "the raw verdict string, translated at web/router.ex:13852 by content_bound_from_verdict/1 into the boolean `content_bound` that consumers DO read. site.ex:211 defaults it to \"never_checked\". The coarse boolean is the read surface; this is its input, in the same shape as box_refusal_code.",
    "deferral_actual_gap_s" =>
      "the gap that ACTUALLY elapsed between a deferred deployment and its predecessor (sites/deploy.ex:2080). deferral_pacing.ex:183 SELECTs it into the pacing aggregate, so its audience reads the aggregate and never the per-row leg.",
    "deferral_scheduled_s" =>
      "the window the backoff ladder ASKED for (sites/deploy.ex:2079). The PAIR is the instrument — scheduled against actual is the whole question of whether the ladder is obeyed — and deferral_pacing.ex:181 requires both non-nil before either counts, which is why neither is read alone.",
    "demand_class" =>
      "the only residual field with TWO owners: Registry.Site carries the operator's classification (registry.ex:8376 is its sole writer and says so) and Registry.Deployment carries a copy stamped at insert by stamp_demand_class/2 (registry.ex:8386) so the class is recomputed rather than remembered. Two columns, one vocabulary, zero consumer readers — the fix would be one render, not two deletions.",
    "expiry_warned_at" =>
      "the send-once claim for PAT expiry mail: accounts.ex:1251 stamps it inside `UPDATE … WHERE expiry_warned_at IS NULL`, and accounts.ex:1235 documents that the update's own row count is what decides who won. A field whose entire meaning is that exactly one writer wins has nothing to say to a reader.",
    "failed_attempts" =>
      "the wrong-code lockout counter on a login token (accounts.ex:1918 increments it, accounts.ex:109 calls it a hard cap rather than a rate limiter). It is withheld deliberately: telling a caller how many guesses remain is a gift to the party doing the guessing.",
    "grace_ends_at" =>
      "the past-due grace anchor. billing.ex:909 states it is written here and nowhere else, and entitlement is computed FROM it server-side; billing.ex:900 records that anchoring on it rather than on current_period_end was itself the fix. The customer is shown the entitlement decision, not the clock behind it.",
    "graced_poll_refusals" =>
      "transient box 5xx swallowed by the poll loop (registry.ex:9152), bumped by the fragment at registry.ex:9115. It is FOLDED, not dark: registry.ex:9176 reports it as the `polls:` leg of a grace summary, and the summary is the surface.",
    "graced_start_retries" =>
      "the sibling leg — START triggers retried across an UNTYPED 5xx (registry.ex:9153, bumped at registry.ex:9130) — folded as `starts:` at registry.ex:9177. Same fold as the poll counter, different cause, and they are kept apart because a swallowed poll and a retried start fail for different reasons.",
    "invited_by_id" =>
      "a foreign key to the inviting user, set at accounts.ex:1421. An identifier, not an instrument: the invitation mail carries the inviter's NAME, and a bare user id on the wire is a disclosure with no use to the recipient.",
    "last_graced_at" =>
      "the moment either grace counter was last bumped (registry.ex:9116 and :9131 stamp the same `now`). deployment.ex:694 keeps it out of the changeset alongside the two counters. Shape-wise it is coalesced_last_at's twin — a write-side breadcrumb — but for the grace ladder rather than for coalescing.",
    "last_pct" =>
      "the failure PERCENTAGE the stored verdict was taken from (notifications.ex:852). It is kept so a later reading can be compared with the one that actually fired; deploy_rate_alert_state.ex:34 says exactly that. The number a human sees is in the mail.",
    "last_sample" =>
      "the SAMPLE SIZE behind last_pct (notifications.ex:853). The pair is the honesty of the instrument: 100% failure over two deploys is not the finding that 100% over two hundred is, and the row stores both so that distinction survives to the next tick.",
    "onboarding_completed_at" =>
      "the source of a boolean. accounts.ex:3171 derives `completed?: not is_nil(...)` and puts THAT on the envelope, beside the timestamp under a different key. The column is the authority; the boolean is the surface, and the surface is what consumers named.",
    "onboarding_state" =>
      "a free-form map holding `last_step` and `acked` (accounts.ex:3182, :3192). Nothing validates its shape, so a consumer naming the column would be depending on a structure no changeset defends. Its readers are the accounts.ex helpers that own the shape.",
    "pending_email" =>
      "the STAGED new address during a verified email change (accounts.ex:1836). Deliberately not echoed anywhere: the staged address is disclosed only TO ITSELF, in the confirmation code mail at accounts.ex:1854. Putting it on a body would let a hijacked session read the address it is being moved to.",
    "provider_uid" =>
      "the OAuth provider's durable subject id, the JOIN KEY for external identities (accounts.ex:145 calls it the durable key, accounts.ex:192 matches on it). Publishing it would let any caller correlate one person's accounts across providers, which is a privacy loss with no product gain.",
    "refreshed_at" =>
      "the warm-pool staleness stamp that ORDERS refresh eligibility: registry.ex:3377 filters on it and registry.ex:3380 orders `asc_nulls_first` so the stalest box refreshes first. Its consumer is the ORDER BY clause; there is no seat where a human wants this timestamp.",
    "refunded_at" =>
      "RESERVED, and the schema says so verbatim at subscription.ex:47 — a column standing ahead of the deferred refund seam. The honest disposition is that it is not an instrument yet: it is not emitted, nothing computes it, and giving it a reader before it has a writer would manufacture an audience for a hole.",
    "result_ip" =>
      "the box IP the provision worker ECHOED BACK (registry.ex:2081). registry.ex:2809 is explicit that it is stamped only when the worker echoed the ip it was told to configure, so the column is a CONSISTENCY check between two halves of a provision, not an address anyone is meant to dial.",
    "session_token_id" =>
      "the parentage of a derived token: accounts.ex:1572 scopes the sweep by it rather than by user_id + context, so revoking one browser session takes its own \"sse\" children and nobody else's. The client holds the token; the row id is the server's bookkeeping.",
    "trial_ends_at" =>
      "the durable team-ledger end of trial, read at billing.ex:1370 to anchor a subscription's current_period_end. What reaches the customer is the anchored period on the subscription; this is the team-side stamp the anchor was computed from.",
    "trial_notice_1d_sent_at" =>
      "the one-day trial notice claim, taken through claim_notice/3 at trial_expiry_worker.ex:223. Like every other claim column here its value is the RACE it wins, not the timestamp it holds: two workers on the same minute is exactly what it refuses.",
    "trial_notice_3d_sent_at" =>
      "the three-day sibling, and it encodes a SUPPRESSION RULE rather than just a send: trial_expiry_worker.ex:224 burns this claim when the one-day notice goes out, so a team that hit 1-day first can never be mailed the 3-day copy afterwards.",
    "trial_started_at" =>
      "the atomic trial claim — billing.ex:1384 matches `WHERE trial_started_at IS NULL` so Postgres serializes two concurrent starts and exactly one wins (billing.ex:1330). Downstream needs the END of the trial, which is a different column; this one exists to be contended over.",
    "two_factor_confirmed_at" =>
      "the ONLY \"is 2FA on?\" check in the system — accounts.ex:2526, :2593 and :2624 all branch on it being nil. It stays server-side because it is the AUTHORITY, and an authority copied to a client stops being one; what a client may know is the boolean the session already implies.",
    "two_factor_last_step" =>
      "the OTP replay guard: accounts.ex:2607 refuses any step not strictly greater than the stored one, inside the update_all that makes the refusal atomic. Publishing the last accepted step would hand an attacker the exact window to aim the next guess at.",
    "unreachable_alerted_at" =>
      "the unreachable-episode latch, and the one whose value DOES reach a human — indirectly: notifications.ex:1236 measures the episode's LENGTH from it when the verdict clears, and the length goes in the recovery mail. The latch is server state; the duration is the product.",
    "unreachable_observed_at" =>
      "when the unreachable sweep last actually RAN (notifications.ex:1324). It is what separates \"clear\" from \"unmeasured\" in the three-way vocabulary at deploy_rate_alert_state.ex:58 — freshness OF the measurement rather than the measurement, and a consumer that rendered it would be reporting on the sweeper.",
    "unreachable_peak_rows" =>
      "the high-water ROW count across the episode: notifications.ex:1299 keeps `max(reading, existing)`. A peak is only meaningful over a whole episode, so it is stored rather than recomputed from a window that may no longer contain its own maximum.",
    "unreachable_peak_sites" =>
      "the high-water count of distinct SITES, kept beside the row peak at notifications.ex:1300. The two diverge on purpose — one site flapping forty times is not forty sites down — and keeping both is what lets the recovery mail say which of the two happened.",
    "unreachable_verdict" =>
      "the stored state of the unreachable machine, one of episode/clear/unmeasured (deploy_rate_alert_state.ex:58, written at notifications.ex:1296/:1306/:1314). A human is sent the TRANSITION, never the state: the mail fires on the edge, so the resting value has no audience.",
    "vercel_claim_minted_at" =>
      "the TTL anchor for a Vercel claim, read at vercel.ex:150 to decide whether the minted claim is still fresh and re-stamped at vercel.ex:201. The caller already holds the claim; the freshness decision is the control plane's to make.",
    "vercel_project_id" =>
      "the vendor project handle, turned into the boolean `deployed:` on the status node at vercel.ex:124 and used as the claim test at vercel.ex:134. The id is the EVIDENCE and the boolean is the ANSWER; handing out the handle would expose a vendor-side object no caller can act on.",
    "waiting_alerted_at" =>
      "the waiting-episode latch. notifications.ex:901 names removing its nil check as the mutation that breaks the sweep, and notifications.ex:953 measures the episode from it. Same shape as its unreachable twin, on the other of the two independent sweeps this row carries.",
    "waiting_longest_seconds" =>
      "the DEEPEST wait seen during the episode, handed straight to send_waiting_recovery/3 at notifications.ex:954. notifications.ex:909 explains why it lives on the row: the deepest wait may have drained away before the episode ended, so recomputing it at recovery time would under-report the worst moment.",
    "waiting_observed_at" =>
      "when the WAITING sweep last ran (notifications.ex:1032). It draws the same clear-versus-unmeasured line its unreachable counterpart draws and is kept separately because the two sweeps run independently: one can be fresh while the other is stale, and a single shared stamp would hide that.",
    "waiting_verdict" =>
      "the waiting machine's stored state — waiting/clear/unmeasured (deploy_rate_alert_state.ex:50). Its vocabulary is deliberately NOT the unreachable one: \"waiting\" describes a queue that is moving too slowly, \"episode\" describes an outage, and collapsing the two would lose the distinction the two sweeps exist to keep."
  }

  defp derived_input(ctx, overrides) do
    Map.merge(
      %{
        modules: ctx.schema_modules,
        fields: ctx.schema_fields,
        hits: ctx.schema_hits,
        dispositions: @residual_dispositions,
        floors: %{
          modules: @schema_module_floor,
          fields: @schema_field_floor,
          disposition_bytes: @disposition_floor
        },
        controls: %{
          module: @schema_module_control,
          lit: @schema_lit_control,
          dark: @schema_dark_control
        }
      },
      overrides
    )
  end

  defp fmt_faults([]), do: "(none)"

  defp fmt_faults(faults),
    do: Enum.map_join(faults, "\n", fn {kind, detail} -> "  [#{kind}] #{detail}" end)

  test "DERIVED ADMISSION: every reader-less schema field is exempt by the STATED pattern or carries its own disposition",
       ctx do
    part = SchemaCorpus.partition(ctx.schema_fields, ctx.schema_hits)

    # THE MEMBERSHIP IS THE EVIDENCE. Printed every run, so a pattern that
    # starts swallowing non-secrets, or a reflection that starts missing a
    # schema, is visible in the output of the run that caused it — not in a
    # number somebody has to remember the previous value of.
    IO.puts("""

    DERIVED ADMISSION (reflected #{length(ctx.schema_modules)} BarkparkCloud.* Ecto schemas, \
    #{length(ctx.schema_fields)} distinct field names)

      DARK (#{length(part.dark)}): #{Enum.join(part.dark, " ")}

      EXEMPT — secret-class by the stated pattern (#{length(part.exempt)}): \
    #{Enum.join(part.exempt, " ")}

      RESIDUAL — owes a disposition (#{length(part.residual)}): #{Enum.join(part.residual, " ")}
    """)

    faults = SchemaCorpus.faults(derived_input(ctx, %{}))

    assert faults == [],
           """
           THE DERIVED ADMISSION REFUSES.

           #{fmt_faults(faults)}

           dark #{length(part.dark)} / exempt #{length(part.exempt)} / residual #{length(part.residual)};
           #{length(ctx.schema_modules)} schema modules, #{length(ctx.schema_fields)} field names.
           """
  end

  test "MUTATION: a reflection that silently returns FEWER modules cannot go green", ctx do
    # The failure this guards is not "zero modules" — that would be loud. It is
    # a reflection that drops SOME modules and hands back a smaller, plausible
    # corpus: fewer keys examined, fewer residual fields, and a green run.
    shrunk = Enum.reject(ctx.schema_modules, &(&1 == @schema_module_control))
    fields = SchemaCorpus.field_names(shrunk)

    refute @schema_dark_control in fields,
           "this mutation's premise is that dropping #{inspect(@schema_module_control)} takes " <>
             "#{@schema_dark_control} with it — re-derive which module owns the dark control."

    faults = SchemaCorpus.faults(derived_input(ctx, %{modules: shrunk, fields: fields}))

    assert Enum.any?(faults, &match?({:module_control_missing, _}, &1)),
           "a corpus missing #{inspect(@schema_module_control)} went green:\n#{fmt_faults(faults)}"

    assert Enum.any?(faults, &match?({:dark_control_absent, _}, &1)),
           "the dark control vanished from the field set and nothing said so:\n#{fmt_faults(faults)}"

    # And the floor underneath the controls bites too, on a corpus small enough
    # to be obviously broken rather than merely incomplete.
    tiny = Enum.take(ctx.schema_modules, 3)

    tiny_faults =
      SchemaCorpus.faults(
        derived_input(ctx, %{modules: tiny, fields: SchemaCorpus.field_names(tiny)})
      )

    assert Enum.any?(tiny_faults, &match?({:module_corpus_too_small, _}, &1))
    assert Enum.any?(tiny_faults, &match?({:field_corpus_too_small, _}, &1))
  end

  test "MUTATION: the DARK control gaining a reader reds — a scanner that finds everything loses too",
       ctx do
    assert ctx.schema_hits[@schema_dark_control] == [],
           "#{@schema_dark_control} is no longer dark on this tree. Either a secret-class column " <>
             "is now named in a consumer tree — a finding — or the control must be re-derived."

    lit =
      Map.put(ctx.schema_hits, @schema_dark_control, [
        %{file: "internal/cli/invented.go", line: 1, text: "smtpPasswordEncrypted := cfg.Get()"}
      ])

    faults = SchemaCorpus.faults(derived_input(ctx, %{hits: lit}))

    assert Enum.any?(faults, &match?({:dark_control_went_lit, _}, &1)),
           "the dark control went lit and the admission stayed green:\n#{fmt_faults(faults)}"
  end

  test "MUTATION: the LIT control going dark reds — a scanner that finds nothing loses", ctx do
    assert ctx.schema_hits[@schema_lit_control] != [],
           "#{@schema_lit_control} derives no readers, so it cannot serve as the lit control. " <>
             "RE-DERIVE: this key was the DARK control when this arm was filed and it moved."

    blinded = Map.put(ctx.schema_hits, @schema_lit_control, [])
    faults = SchemaCorpus.faults(derived_input(ctx, %{hits: blinded}))

    assert Enum.any?(faults, &match?({:lit_control_went_dark, _}, &1)),
           "a scanner that found nothing for #{@schema_lit_control} went green:\n#{fmt_faults(faults)}"
  end

  test "MUTATION: an undisposed residual field, a stale disposition and a boilerplate one all red",
       ctx do
    part = SchemaCorpus.partition(ctx.schema_fields, ctx.schema_hits)
    [victim | _] = part.residual

    dropped = Map.delete(@residual_dispositions, victim)

    assert Enum.any?(
             SchemaCorpus.faults(derived_input(ctx, %{dispositions: dropped})),
             &match?({:undisposed, _}, &1)
           ),
           "dropping #{victim}'s disposition left the admission green"

    # A disposition for a field that is not residual: the allowlist-rot
    # direction, and the one a `residual ⊆ disposed` check alone would miss.
    stale = Map.put(@residual_dispositions, @schema_lit_control, String.duplicate("x", 80))

    assert Enum.any?(
             SchemaCorpus.faults(derived_input(ctx, %{dispositions: stale})),
             &match?({:stale_disposition, _}, &1)
           ),
           "a disposition for #{@schema_lit_control}, which has readers, was accepted"

    # Two fields, one sentence — the failure nothing but distinctness catches.
    [a, b | _] = part.residual
    pasted = Map.put(@residual_dispositions, b, Map.fetch!(@residual_dispositions, a))

    assert Enum.any?(
             SchemaCorpus.faults(derived_input(ctx, %{dispositions: pasted})),
             &match?({:boilerplate_disposition, _}, &1)
           ),
           "#{b} copied #{a}'s disposition verbatim and the admission stayed green"

    # And a placeholder short enough to be no explanation at all.
    thin = Map.put(@residual_dispositions, victim, "n/a")

    assert Enum.any?(
             SchemaCorpus.faults(derived_input(ctx, %{dispositions: thin})),
             &match?({:thin_disposition, _}, &1)
           )
  end

  test "the derived admission does NOT subsume the hand-typed register", ctx do
    register_keys = Enum.map(@register, & &1.key)
    missing = register_keys -- ctx.schema_fields

    assert "publish_clock" in missing and "failure_class" in missing and
             "request_stats" in missing,
           """
           at least one of the three envelope-only register keys turned up in the schema
           field set. That would be a real change — but it must NOT be read as licence to
           replace the register with the derivation: the register's reason for existing is
           that a key can be an instrument without ever being a column.

           register keys absent from the schema corpus: #{inspect(missing)}
           """
  end

  # ── THE TWO OFFLINE GUARDS (dr-w27-s3-census-arms-survive-their-own-success) ──────────────────────────────────────
  #
  # This census kept going stale in its own PROSE. Three separate paragraphs
  # adjudicated a PR or a task in a sentence — "#11009 is UNSTABLE and must
  # still land", "dr-w26-s5-crown-gets-its-writer was never filed as a task at all", "queued_seconds
  # has zero readers in all five trees" — and every one of them was FALSE by the
  # time anyone read it. A sentence has no way to be re-checked; a register row
  # does. These two guards make the file refuse the shape of that mistake.
  #
  # They are OFFLINE by construction: they read this file's own bytes and ask
  # nothing of the network, so they cannot answer differently on a runner than
  # on a laptop.
  describe "the file cannot adjudicate in prose" do
    @source_path Path.join(
                   ReaderScan.repo_root(),
                   "cloud/test/barkpark_cloud/reader_less_instrument_census_test.exs"
                 )

    # A task id as this board spells one: family, wave, slice, then a DESCRIPTIVE
    # TAIL. The tail is the part that was being dropped.
    @task_id ~r/\b(?:dr|cch)-w\d+-(?:s\d+[a-z]?|bl|hg|r\d+)(?:-[a-z][a-z0-9-]*)?\b/
    @full_slug ~r/\b(?:dr|cch)-w\d+-(?:s\d+[a-z]?|bl|hg|r\d+)-[a-z][a-z0-9-]*\b/

    # A citation is a thing whose disposition lives elsewhere: a task id, or a PR.
    @citation ~r/(?:\b(?:dr|cch)-w\d+-(?:s\d+[a-z]?|bl|hg|r\d+)(?:-[a-z][a-z0-9-]*)?\b|#\d{3,6})/

    # Words that RULE on a citation. Prose may CITE freely; it may not ADJUDICATE.
    @verdicts [
      "does not exist",
      "doesn't exist",
      "not_found",
      "never filed",
      "was never filed",
      "is not a filed task",
      "is open",
      "is closed",
      "is merged",
      "must still land",
      "is unstable"
    ]

    # THE GUARD DOES NOT SCAN ITSELF, and that is not a loophole — it is the only
    # way it can exist. This block NAMES the stale sentences as examples and
    # LISTS the verdict words in `@verdicts`; scanning itself would red forever
    # on its own definition. Everything above the marker is scanned, which is
    # the whole census: register, moduledocs, comments and assertions.
    defp scannable_source do
      @source_path
      |> File.read!()
      |> String.split(~s(# ── THE TWO OFFLINE GUARDS), parts: 2)
      |> hd()
    end

    test "TIER 1: every task id is a FULL slug — a truncated id names nothing" do
      source = scannable_source()

      truncated =
        @task_id
        |> Regex.scan(source)
        |> Enum.map(&hd/1)
        |> Enum.uniq()
        |> Enum.reject(&Regex.match?(@full_slug, &1))

      assert truncated == [],
             "truncated task ids found — a bare id resolves to not_found and invites a " <>
               "false 'never filed' verdict: #{inspect(truncated)}"
    end

    test "TIER 2: a citation is never followed by a verdict word" do
      source = scannable_source()

      offences =
        @citation
        |> Regex.scan(source, return: :index)
        |> Enum.map(fn [{start, len}] ->
          {binary_part(source, start, len), window_after(source, start + len, 80)}
        end)
        |> Enum.filter(fn {_cite, window} ->
          down = String.downcase(window)
          Enum.any?(@verdicts, &String.contains?(down, &1))
        end)
        |> Enum.map(fn {cite, window} -> "#{cite} -> #{String.trim(window)}" end)

      assert offences == [],
             "prose adjudicates a citation within 80 bytes. Carry the disposition as a " <>
               "REGISTER ROW, which can be re-checked, not as a sentence, which cannot:\n" <>
               Enum.join(offences, "\n")
    end

    # An 80-BYTE window, trimmed back to a valid UTF-8 boundary — this file is
    # full of em dashes, and a naive binary_part/3 would split one and raise.
    defp window_after(source, offset, size) do
      max = byte_size(source) - offset
      take = min(size, max)
      shrink(binary_part(source, offset, take))
    end

    defp shrink(bin) do
      if String.valid?(bin) or bin == "",
        do: bin,
        else: shrink(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end
end
