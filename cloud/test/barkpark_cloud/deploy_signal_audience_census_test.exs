defmodule BarkparkCloud.DeploySignalAudience.GoReader do
  @moduledoc """
  SIDE B, pull half: the request path a Go client method actually sends, read
  off `internal/cloudclient` SOURCE.

  A deploy-health READ is only as reachable as the route it hits, and the route
  is not in the registry's gift — it is in the Go call. So the path is DERIVED:
  the `(ctx, "METHOD", <expr>, …)` call in the method body, with `<expr>`
  resolved through its `path :=` / `path +=` assignments, every string literal
  kept and every dynamic term rendered `*` (a path parameter). The query string
  is cut: `?from=&to=` is not part of the route.

  Prior art for parsing Go from inside an Elixir test is green on main
  (`payload_key_set_census_test.exs`), and CI runs this suite from `cloud/` over
  a full checkout, so the sibling tree is on disk.

  `walker: :broken` selects a deliberately naive extractor — one that only
  matches a bare string literal argument, which NO call in this package has —
  so the census can be shown to LOSE its Side B rather than be trusted on a
  green it cannot fail.
  """

  # `c.do(ctx, "GET", <expr>, true, nil)` and `c.rolloutRequest(ctx, "GET", <expr>)`
  # alike: the method literal followed by the path expression.
  @call_re ~r/\(ctx,\s*"(GET|POST|PUT|PATCH|DELETE)",\s*([^\n]+)/

  # The BROKEN walker, preserved on purpose (the `naive_grep_callers/2` idiom):
  # it demands the path be a bare literal in the call, which is true of exactly
  # zero calls in this package — every one concatenates or passes a variable.
  @broken_call_re ~r/\(ctx,\s*"(GET|POST|PUT|PATCH|DELETE)",\s*"([^"]*)"\)/

  @doc """
  The Go source at `file`.

  A missing or renamed file is a NAMED refusal, never `""`: an empty source
  derives no path for any reader, and "no reader resolves to operator" is
  exactly how this census would pass while measuring nothing.
  """
  @spec source(binary()) :: binary()
  def source(file) do
    unless File.regular?(file) do
      raise ArgumentError,
            "DeploySignalAudience.GoReader: Go reader source not found at #{file}. " <>
              "The client moved or was renamed — re-point @sources in the census. " <>
              "Refusing to derive an audience from a source that does not exist."
    end

    File.read!(file)
  end

  @doc """
  `{:ok, %{method:, path:, line:}}` for `func` in `file`, or `{:error, reason}`.

  `path` carries `*` where the Go code splices a value, so it lines up with the
  router's `:param` segments after the same normalisation.
  """
  @spec request_path(binary(), binary(), keyword()) ::
          {:ok, %{method: binary(), path: binary(), line: pos_integer()}} | {:error, atom()}
  def request_path(file, func, opts \\ []), do: request_path_in(source(file), func, opts)

  @doc """
  `request_path/3` over SOURCE TEXT that is already in hand.

  The candidate derivation (see `CandidateReader`) needs to run the same
  extractor over a MUTATED copy of a real source — the only way to show in this
  file, rather than in a PR comment nobody re-runs, that the derived set SHRINKS
  when the source loses a method. Reading the disk a second time cannot do that,
  so the text is the parameter and `request_path/3` is the thin file wrapper.
  """
  @spec request_path_in(binary(), binary(), keyword()) ::
          {:ok, %{method: binary(), path: binary(), line: pos_integer()}} | {:error, atom()}
  def request_path_in(src, func, opts \\ []) do
    case body(src, func) do
      {:ok, body, line} ->
        re = if opts[:walker] == :broken, do: @broken_call_re, else: @call_re

        case Regex.run(re, body) do
          [_, method, rest] ->
            {:ok, %{method: method, path: resolve(body, rest), line: line}}

          nil ->
            {:error, :no_request_call}
        end

      :error ->
        {:error, :func_not_found}
    end
  end

  defp body(src, func) do
    re = ~r/^func \([^)]*\) #{Regex.escape(func)}\(.*?^\}/ms

    case Regex.run(re, src, return: :index) do
      [{start, len}] ->
        prefix = binary_part(src, 0, start)
        {:ok, binary_part(src, start, len), length(String.split(prefix, "\n"))}

      _ ->
        :error
    end
  end

  # The path argument is the FIRST comma-separated chunk after the method
  # literal. A bare identifier is resolved through the body's assignments.
  defp resolve(body, rest) do
    expr = rest |> String.split(",") |> hd() |> String.trim() |> String.trim_trailing(")")

    raw =
      if Regex.match?(~r/^[a-zA-Z_]\w*$/, expr) do
        assignments(body, expr)
      else
        render(expr)
      end

    raw |> String.split("?") |> hd()
  end

  defp assignments(body, var) do
    body
    |> String.split("\n")
    |> Enum.reduce("", fn line, acc ->
      case Regex.run(~r/^\s*#{Regex.escape(var)}\s*(:?=|\+=)\s*(.+?)\s*$/, line) do
        [_, ":=", expr] -> render(expr)
        [_, "=", expr] -> render(expr)
        [_, "+=", expr] -> acc <> render(expr)
        _ -> acc
      end
    end)
  end

  # Every string literal kept verbatim; every other term is a spliced value and
  # becomes `*`. `esc(siteID)` and `q.Encode()` are both "a value goes here".
  defp render(expr) do
    expr
    |> String.split("+")
    |> Enum.map_join("", fn term ->
      case Regex.run(~r/^"([^"]*)"$/, String.trim(term)) do
        [_, lit] -> lit
        _ -> "*"
      end
    end)
  end
end

defmodule BarkparkCloud.DeploySignalAudience.ExReader do
  @moduledoc """
  SIDE B, push half: the recipient POPULATION a notification path resolves, read
  off `notifications.ex` SOURCE.

  A push signal's audience is whoever its recipient resolver returns, so the
  resolver is derived from the sending function's body (the house naming rule:
  a recipient resolver is `*_emails`), and then the resolver's OWN body is read
  to classify the population it draws from:

    * `:platform_allowlist` — the body's source is the `:platform_admin_emails`
      config allowlist. That population is EMPTY BY CONSTRUCTION on prod: no
      User field carries operator-ness, no route or console writes the key, and
      `config.exs` hard-defaults it to `[]`.
    * `:team_members` — the body draws team membership rows. A team with an
      owner always has at least that one member.
    * `:unknown` — anything else. Fails CLOSED: the census refuses to answer
      rather than assume a population.

  The config KEY NAME is read as SOURCE TEXT. Nothing here calls
  `Application.get_env/2` — a config-reading guard would be vacuous in CI, where
  the allowlist is `[]` by default and the answer would be the same whatever
  production does.
  """

  @resolver_re ~r/\b([a-z_]+_emails)\(/
  # The BROKEN walker: a resolver naming convention this tree does not use.
  @broken_resolver_re ~r/\b(recipients_for_[a-z_]+)\(/

  @doc "The Elixir source at `file` — a missing file is a NAMED refusal."
  @spec source(binary()) :: binary()
  def source(file) do
    unless File.regular?(file) do
      raise ArgumentError,
            "DeploySignalAudience.ExReader: Elixir reader source not found at #{file}. " <>
              "The module moved or was renamed — re-point @sources in the census. " <>
              "Refusing to derive an audience from a source that does not exist."
    end

    File.read!(file)
  end

  @doc """
  `{:ok, %{resolver:, population:, line:}}` for the sending function `func` in
  `file`, or `{:error, reason}`.
  """
  @spec recipient_population(binary(), binary(), keyword()) ::
          {:ok, %{resolver: binary(), population: atom(), line: pos_integer()}}
          | {:error, atom()}
  def recipient_population(file, func, opts \\ []) do
    src = source(file)

    case body(src, func) do
      {:ok, fun_body, line} ->
        re = if opts[:walker] == :broken, do: @broken_resolver_re, else: @resolver_re

        case Regex.run(re, fun_body) || hop(src, fun_body, re) do
          [_, resolver] ->
            {:ok, %{resolver: resolver, population: classify(src, resolver), line: line}}

          nil ->
            {:error, :no_recipient_resolver}
        end

      :error ->
        {:error, :func_not_found}
    end
  end

  # ONE HOP, AND ONLY ONE. `deliver_deploy_rate_notices/1` is a per-team LOOP
  # whose send is a private helper (`send_deploy_rate_notice/3`); the resolver is
  # in the helper, not in the arm. Without a hop this census could only watch
  # senders that happen to inline their own recipient lookup, which is a shape
  # accident rather than a rule — and a sender it cannot read is a sender it is
  # green over BY CONSTRUCTION, the exact fail-open this file is closing.
  #
  # The hop is bounded at depth one and takes the FIRST callee that resolves, so
  # it cannot wander: a resolver two helpers deep still reports
  # `:no_recipient_resolver` and reds, which is the honest answer.
  defp hop(src, fun_body, re) do
    fun_body
    |> then(&Regex.scan(~r/\b([a-z_][a-z0-9_]*)\(/, &1))
    |> Enum.map(fn [_, callee] -> callee end)
    |> Enum.uniq()
    |> Enum.find_value(fn callee ->
      case body(src, callee) do
        {:ok, callee_body, _line} -> Regex.run(re, callee_body)
        :error -> nil
      end
    end)
  end

  defp classify(src, resolver) do
    case body(src, resolver) do
      {:ok, resolver_body, _line} ->
        cond do
          resolver_body =~ ":platform_admin_emails" -> :platform_allowlist
          resolver_body =~ ~r/list_team_member_emails|Membership/ -> :team_members
          true -> :unknown
        end

      :error ->
        :unknown
    end
  end

  # A `def name(...) ... end` block, or a one-line `def name(...), do: expr`.
  defp body(src, func) do
    inline = ~r/^  defp? #{Regex.escape(func)}\(.*,\s*do:.*$/m
    block = ~r/^  defp? #{Regex.escape(func)}[\s(].*?^  end$/ms

    case Regex.run(inline, src, return: :index) || Regex.run(block, src, return: :index) do
      [{start, len}] ->
        prefix = binary_part(src, 0, start)
        {:ok, binary_part(src, start, len), length(String.split(prefix, "\n"))}

      _ ->
        :error
    end
  end
end

defmodule BarkparkCloud.DeploySignalAudience.ConsoleReader do
  @moduledoc """
  SIDE B, console half: the operator console's deploy cards and the route each
  one is painted from, read off `cloud/priv/static/app.js` SOURCE.

  A rendered card is a SURFACE, and a surface's audience is whoever can reach
  the route behind it. The operator page mounts its cards in `operatorPageHtml()`
  and paints each one in `operatorRefresh()`, so both halves are derived: the
  card ids and headings from the first, the `operatorPaint("#<id>", <expr>, …)`
  path expression from the second, with `<expr>` resolved through the file's own
  `var NAME = "/v1/…"` declarations (and through a path-building function's
  `return NAME + …`, which is how the census card's window query is spliced).

  The query string is cut the same way `GoReader` cuts it: `?from=&to=` is not
  part of the route.

  `walker: :broken` selects a deliberately naive card extractor — one that
  matches `card('…')` with SINGLE quotes, which this file never writes — so this
  half can be shown to LOSE rather than be trusted on a green it cannot fail.
  """

  # `card("op-brake-body", "Rollout brake", "…")` inside `operatorPageHtml/0`.
  @card_re ~r/card\("(op-[a-z-]+-body)",\s*"([^"]+)"/
  # The BROKEN walker: single-quoted card ids, a form this file never writes.
  @broken_card_re ~r/card\('(op-[a-z-]+-body)',\s*'([^']+)'/

  # `operatorPaint("#op-brake-body", OPERATOR_AUTOUPDATE, function (data) {`
  @paint_re ~r/operatorPaint\("#(op-[a-z-]+-body)",\s*([^,]+),/

  @doc "The JS source at `file` — a missing file is a NAMED refusal, never `\"\"`."
  @spec source(binary()) :: binary()
  def source(file) do
    unless File.regular?(file) do
      raise ArgumentError,
            "DeploySignalAudience.ConsoleReader: console source not found at #{file}. " <>
              "The console bundle moved or was renamed — re-point @app_js in the census. " <>
              "Refusing to derive a surface count from a source that does not exist."
    end

    File.read!(file)
  end

  @doc """
  `[{card_id, heading}]` for every card `operatorPageHtml/0` mounts, in source
  order. An empty list from the REAL walker is a refusal, not a count of zero:
  zero cards found is how this census would publish "no zero-viewer surfaces"
  while the console renders five.
  """
  @spec cards(binary(), keyword()) :: [{binary(), binary()}]
  def cards(src, opts \\ []) do
    body = body!(src, "operatorPageHtml")
    re = if opts[:walker] == :broken, do: @broken_card_re, else: @card_re
    found = Regex.scan(re, body) |> Enum.map(fn [_, id, heading] -> {id, heading} end)

    if found == [] and opts[:walker] != :broken do
      raise ArgumentError,
            "DeploySignalAudience.ConsoleReader: operatorPageHtml/0 mounts ZERO cards. " <>
              "The card grammar changed — re-teach @card_re. Refusing to publish a " <>
              "zero-viewer count derived from an empty extraction."
    end

    found
  end

  @doc """
  `%{card_id => route_path}` for every `operatorPaint/2..4` call in
  `operatorRefresh/0`, with the path expression resolved and its query cut.
  """
  @spec paints(binary()) :: %{binary() => binary()}
  def paints(src) do
    body = body!(src, "operatorRefresh")

    Regex.scan(@paint_re, body)
    |> Map.new(fn [_, id, expr] -> {id, resolve(src, expr)} end)
  end

  # A `var NAME = "/v1/…";` declaration, a `name()` path builder, or a literal.
  defp resolve(src, expr) do
    expr = String.trim(expr)

    raw =
      cond do
        match = Regex.run(~r/^"([^"]*)"$/, expr) -> Enum.at(match, 1)
        Regex.match?(~r/^[A-Za-z_]\w*$/, expr) -> const(src, expr)
        match = Regex.run(~r/^([A-Za-z_]\w*)\(/, expr) -> builder(src, Enum.at(match, 1))
        true -> ""
      end

    raw |> String.split("?") |> hd()
  end

  defp const(src, name) do
    case Regex.run(~r/^\s*var #{Regex.escape(name)}\s*=\s*"([^"]*)"/m, src) do
      [_, lit] -> lit
      _ -> ""
    end
  end

  # A path builder returns its base constant plus a query: `return NAME + "?…"`.
  defp builder(src, name) do
    case body!(src, name) do
      body ->
        case Regex.run(~r/return\s+([A-Z_][A-Z0-9_]*)\s*\+/, body) do
          [_, const_name] -> const(src, const_name)
          _ -> ""
        end
    end
  end

  # A top-level `  function name(…) { … }` block, closed at its own indentation.
  defp body!(src, func) do
    re = ~r/^  function #{Regex.escape(func)}\(.*?^  \}/ms

    case Regex.run(re, src) do
      [body] ->
        body

      _ ->
        raise ArgumentError,
              "DeploySignalAudience.ConsoleReader: function #{func}/0 not found in the " <>
                "console source. It was renamed or re-indented — re-point the census. " <>
                "Refusing to derive an empty body."
    end
  end
end

defmodule BarkparkCloud.DeploySignalAudience.CandidateReader do
  @moduledoc """
  THE CANDIDATE SET — what a deploy-health signal LOOKS LIKE in source, derived,
  so that a signal nobody registered is still seen (dr-w19-audience-registry-fail-open).

  `@signals` is a DECLARATION, and wave 18's census admitted in its own moduledoc
  that the declaration FAILS OPEN: an instrument that never gets a row is
  invisible, so the census goes green over it forever. This module is the other
  half — it does not ask "is the declared reader reachable", it asks "is there a
  reader in source that LOOKS like a deploy-health signal and has no row at all".

  ## The two derivation rules, both structural

    * PULL — an EXPORTED method on `*Client` anywhere in `internal/cloudclient`
      (test files excluded) whose DERIVED request path matches
      `deploy-ledger|deployments|autoupdate|census`, and whose method is `GET`.
      The `GET` narrowing is not convenience: a SIGNAL is something a human
      READS. `POST /v1/operator/autoupdate/halt` is an ACT — pulling the fleet
      brake — and an act has an actor, not an audience. Including the write
      verbs would file `RolloutHalt` and `Deploy` as unregistered signals and
      make the stated-reason table a list of things that were never signals.
    * PUSH — a PUBLIC `deliver_*` / `dispatch_*` function in `notifications.ex`
      whose body NAMES a deploy event: `:deployment_failed`,
      `:deployment_refused`, `:deployment_abandoned`, `deploy_failure_rate`,
      `deploy_health` or `fleet_digest`. The event vocabulary is the tree's own
      (`@chat_default_on`, the `EmailSettings.event_enabled?/2` arms), read as
      SOURCE TEXT — nothing here calls into the module.

  ## Why the reader takes SOURCE TEXT

  A derivation is only worth the name if it MOVES when the source moves, and the
  only way to prove that inside this file is to run the same extractor over a
  mutated copy of the real source and watch the set shrink. So every public
  function here takes `{label, source}` pairs; `go_sources/1` is the thin
  disk wrapper. The shrink proof is a test, not a PR comment.

  ## The positive control

  An extractor that finds NOTHING is a broken extractor, never a clean repo.
  `go_methods/2` and `ex_senders/2` RAISE on an empty read rather than return
  `[]`, because `[]` candidates is how this whole guard would pass while
  measuring nothing — the exact failure mode it exists to close.
  """

  # An exported method on the client receiver. Unexported helpers (`do`, `url`,
  # `rolloutRequest`, `postSiteDeploy`) are plumbing, not a signal a command
  # calls; they are reached THROUGH an exported method, which is the one that
  # gets a row.
  @go_method_re ~r/^func \(c \*Client\) ([A-Z]\w*)\(/m

  # The deploy-health route vocabulary, per the task row.
  @deploy_path_re ~r/deploy-ledger|deployments|autoupdate|census/

  # A public sender. `defp` helpers (`dispatch_waiting_email/3`,
  # `send_deploy_rate_notice/3`) are called BY one of these.
  @ex_sender_re ~r/^  def (deliver_[a-z0-9_]+|dispatch_[a-z0-9_]+)[\s(]/m

  # The deploy event vocabulary, as the tree spells it.
  @deploy_event_re ~r/:deployment_(?:failed|refused|abandoned)\b|deploy_failure_rate|deploy_health|fleet_digest/

  @type candidate :: %{
          file: binary(),
          func: binary(),
          line: pos_integer(),
          kind: :pull | :push,
          sends: binary()
        }

  @doc """
  `{label, source}` for every non-test `.go` file under `dir`.

  The label is the repo-relative path the registry uses, so a candidate and a
  `@signals` reader row compare as equals.
  """
  @spec go_sources(binary(), binary()) :: [{binary(), binary()}]
  def go_sources(dir, label_prefix) do
    unless File.dir?(dir) do
      raise ArgumentError,
            "DeploySignalAudience.CandidateReader: Go client package not found at #{dir}. " <>
              "The package moved or was renamed — re-point @candidate_go_dir in the census. " <>
              "Refusing to derive an EMPTY candidate set from a directory that does not exist."
    end

    files =
      dir
      |> File.ls!()
      |> Enum.filter(&(String.ends_with?(&1, ".go") and not String.ends_with?(&1, "_test.go")))
      |> Enum.sort()

    if files == [] do
      raise ArgumentError,
            "DeploySignalAudience.CandidateReader: zero non-test .go files under #{dir}. " <>
              "A package with no source is a BROKEN SCAN, not a clean repo."
    end

    Enum.map(files, fn f -> {label_prefix <> "/" <> f, File.read!(Path.join(dir, f))} end)
  end

  @doc """
  Every exported `*Client` method in `src`, with its line.

  Per FILE this may legitimately be `[]` — `retry.go` carries backpressure
  notices and no client method at all. The emptiness that means a BROKEN SCAN is
  a CORPUS-wide zero, and `go_candidates/1` is where that is refused.
  """
  @spec client_methods(binary()) :: [%{func: binary(), line: pos_integer()}]
  def client_methods(src) do
    Regex.scan(@go_method_re, src, return: :index)
    |> Enum.map(fn [{start, _}, {fs, fl}] ->
      %{
        func: binary_part(src, fs, fl),
        line: length(String.split(binary_part(src, 0, start), "\n"))
      }
    end)
  end

  @doc """
  The `:pull` candidates across `sources`.

  THE POSITIVE CONTROL LIVES HERE. A corpus in which the extractor finds ZERO
  exported client methods RAISES: `[]` candidates would make every downstream
  assertion vacuously true, which is the precise way this guard would pass while
  measuring nothing.
  """
  @spec go_candidates([{binary(), binary()}]) :: [candidate()]
  def go_candidates(sources) do
    scanned = for {label, src} <- sources, do: {label, src, client_methods(src)}
    total = scanned |> Enum.map(fn {_, _, m} -> length(m) end) |> Enum.sum()

    if total == 0 do
      raise ArgumentError,
            "DeploySignalAudience.CandidateReader: zero exported *Client methods across " <>
              "#{length(sources)} source(s) (#{Enum.map_join(sources, ", ", &elem(&1, 0))}). " <>
              "An extractor that finds nothing is a BROKEN EXTRACTOR, never a clean source — " <>
              "`func (c *Client) Name(` is the shape it reads, and the tree stopped having it."
    end

    for {label, src, methods} <- scanned,
        %{func: func, line: line} <- methods,
        {:ok, %{method: method, path: path}} <-
          [BarkparkCloud.DeploySignalAudience.GoReader.request_path_in(src, func)],
        method == "GET",
        Regex.match?(@deploy_path_re, path) do
      %{file: label, func: func, line: line, kind: :pull, sends: "#{method} #{path}"}
    end
    |> Enum.sort_by(&{&1.file, &1.func})
  end

  @doc """
  Every PUBLIC `deliver_*` / `dispatch_*` function in `src`, with its line.

  RAISES on zero, for the same reason `go_methods/2` does.
  """
  @spec ex_senders(binary(), binary()) :: [%{func: binary(), line: pos_integer()}]
  def ex_senders(label, src) do
    hits =
      Regex.scan(@ex_sender_re, src, return: :index)
      |> Enum.map(fn [{start, _}, {fs, fl}] ->
        %{
          func: binary_part(src, fs, fl),
          line: length(String.split(binary_part(src, 0, start), "\n")) + 1
        }
      end)

    if hits == [] do
      raise ArgumentError,
            "DeploySignalAudience.CandidateReader: zero public deliver_*/dispatch_* functions " <>
              "in #{label}. An extractor that finds nothing is a BROKEN EXTRACTOR, never a " <>
              "clean source — the notification module stopped having the shape it reads."
    end

    hits
  end

  @doc "The `:push` candidates in one `{label, source}` pair."
  @spec ex_candidates({binary(), binary()}) :: [candidate()]
  def ex_candidates({label, src}) do
    for %{func: func, line: line} <- ex_senders(label, src),
        {:ok, fun_body} <- [body(src, func)],
        event = names_deploy_event(fun_body),
        event != nil do
      %{file: label, func: func, line: line, kind: :push, sends: "names #{event}"}
    end
    |> Enum.sort_by(& &1.func)
  end

  defp names_deploy_event(fun_body) do
    case Regex.run(@deploy_event_re, fun_body) do
      [hit | _] -> hit
      nil -> nil
    end
  end

  # A `def name(...) ... end` block, or a one-line `def name(...), do: expr`.
  defp body(src, func) do
    inline = ~r/^  def #{Regex.escape(func)}\(.*,\s*do:.*$/m
    block = ~r/^  def #{Regex.escape(func)}[\s(].*?^  end$/ms

    case Regex.run(inline, src) || Regex.run(block, src) do
      [match | _] -> {:ok, match}
      _ -> :error
    end
  end
end

defmodule BarkparkCloud.DeploySignalAudienceCensusTest do
  @moduledoc """
  THE EMPTY-AUDIENCE CENSUS — every deploy-health signal declares the credential
  population that can receive it, and a signal whose whole audience is empty BY
  CONSTRUCTION REDS (deploy-reliability wave 18).

  ## The defect

  For seventeen waves this epic built deploy-health instruments and addressed
  every one of them to the platform-operator population — which nobody is in and
  nobody can join. `PLATFORM_ADMIN_EMAILS` is unset on prod; the `User` schema
  has no platform field, so operator-ness is not storable; `mix
  barkpark_cloud.create_admin` touches the allowlist zero times; no route,
  LiveView or console action writes `:platform_admin_emails`; the only
  production writer is one `System.get_env/1` in `runtime.exs`, read once at
  boot; and `config.exs` hard-defaults it to `[]`. An instrument addressed there
  reports to nobody, and every gate over it is green.

  ## The shape — two sides, and Side B is DERIVED

  SIDE A: `@signals`, a committed registry — `{name, kind, readers}`. It is a
  DECLARATION and nothing more; it can be wrong, and being wrong is the point of
  Side B.

  SIDE B: for a `:pull` reader, the request path its Go method actually sends,
  parsed from `internal/cloudclient` source and resolved through the SHARED
  router lens (`test/support/router_tier_lens.ex`) to the tier the route
  enforces. For a `:push` reader, the recipient resolver its body calls and the
  population that resolver draws from, parsed from `notifications.ex`.

  THE ASSERTION: a signal every one of whose readers lands on a no-human tier —
  `operator` or `worker` (pull), see `@empty_pull_tiers` — or on the platform
  allowlist (push) has an EMPTY AUDIENCE BY CONSTRUCTION
  and must be allowlisted with a reason NAMING ITS CLOSER — or it reds, naming
  the signal and the reader's `file:line`.

  Nothing here reads `PLATFORM_ADMIN_EMAILS`, or any `Application.get_env`. A
  config-reading guard is vacuous by construction: the CI value is `[]` whatever
  prod does, so it would either red always or pass always, and neither is
  information. The judgment is STRUCTURAL — derived from source text.

  ## The limit of the claim — read this before trusting a green

  This proves an AUDIENCE SHAPE, not DELIVERY. A green here does NOT prove any
  route returns 200, that a credential satisfying the tier exists, that mail was
  accepted by a relay, or that a human ever read the signal. A `worker`-tier
  reader is a MACHINE population; since dr-w19-s5 this census calls that
  population empty for a HUMAN signal, but it still does not judge whether the
  machine's secret is provisioned anywhere.

  Nor does it judge WHO within a population may see WHICH row. A push signal
  resolving `team_members` is REACHABLE; whether it fans one team's rows into
  another team's inbox is a TENANCY question this file cannot see, because it
  reads the resolver's source text and nothing else. It would have gone green on
  a fleet-wide digest exactly as readily as on the per-team one that shipped —
  that ruling is made in `deliver_fleet_digest/1`'s own doc, not here.

  ## SIDE C — the registry no longer fails open (dr-w19-audience-registry-fail-open)

  This moduledoc used to end: "the registry FAILS OPEN: an unregistered signal is
  invisible to this file… Nothing syntactic closes that hole." Something now
  does. `CandidateReader` derives, from the same sources, what a deploy-health
  signal LOOKS LIKE — an exported `*Client` GET whose derived path matches
  `deploy-ledger|deployments|autoupdate|census`, or a public `deliver_*` /
  `dispatch_*` in `notifications.ex` whose body names a deploy event — and a
  candidate with no `@signals` row REDS, naming its `file:line`.

  That is a NARROWER claim than "no deploy signal can hide". The derivation sees
  the two shapes it reads and no others: a deploy-health read issued from
  `internal/cli`, from the Studio, or over a path that spells the resource some
  other way is still invisible here, and a sender whose recipient resolver is two
  helpers deep still reports `:no_recipient_resolver`. What changed is that the
  DEFAULT flipped: an instrument in the shapes this epic actually builds now
  reaches the census by landing in source, not by someone remembering to add a
  row. On its first run it found four, three of which had never been registered,
  and one of those three — `site_build_log` — turned out to be addressed to
  nobody. That finding is CLOSED: `dr-w19-site-build-log-is-operator-only`
  re-pointed the route at the team-scoped door its siblings use, the rot assertion
  below reddened on the stale allowlist row, and the row was deleted by name.

  And the boundary still MOVES LOUDLY: when a reader is re-pointed at a reachable
  route, or a signal's last reachable reader is taken away, the diff says so on
  the PR that did it.
  """

  use ExUnit.Case, async: true

  alias BarkparkCloud.DeploySignalAudience.CandidateReader
  alias BarkparkCloud.DeploySignalAudience.ConsoleReader
  alias BarkparkCloud.DeploySignalAudience.ExReader
  alias BarkparkCloud.DeploySignalAudience.GoReader
  alias BarkparkCloud.RouterTierLens, as: Lens

  @self __ENV__.file

  # The reader sources, as FULL literals so `cloud-path-escape-check.sh` resolves
  # them: `internal/cloudclient/**` is already a declared CLOUD_PATH (dr-w10-s4),
  # so a Go-side edit re-runs this census. No `internal/cli/**` source is read
  # here, on purpose — the CLI is NOT in the dispatcher's path set, and a guard
  # reading it would publish a green required context over a guard that never ran.
  @cloudclient Path.expand("../../../internal/cloudclient/client.go", __DIR__)
  @deliveries Path.expand("../../../internal/cloudclient/deliveries.go", __DIR__)
  @notifications Path.expand("../../lib/barkpark_cloud/notifications.ex", __DIR__)

  # Added by dr-w19-audience-registry-fail-open: the candidate derivation below
  # found `SiteBuildLog` sending GET /v1/sites/*/deployments/*/build-log with no
  # row anywhere in this file, so its source joins @sources in the same commit
  # as the row that names it.
  @site_build_log Path.expand("../../../internal/cloudclient/site_build_log.go", __DIR__)

  # Added by task-801c6c33769ca01d (bp sites logs prints the build BYTES): the
  # candidate derivation found `SiteBuildLogBytes` sending
  # GET /v1/sites/*/deployments/*/build-log/bytes with no row, so its source joins
  # @sources in the same commit as the reader row that names it (below).
  @site_build_log_bytes Path.expand(
                          "../../../internal/cloudclient/site_build_log_bytes.go",
                          __DIR__
                        )

  # The console bundle. `cloud/priv/static/**` is a CLOUD_PATH, so a console edit
  # re-runs this census — which is the point of counting its cards here rather
  # than in a number frozen into prose.
  @app_js Path.expand("../../priv/static/app.js", __DIR__)

  # The candidate corpus. A DIRECTORY, walked, not a file list: a new Go source
  # file in this package must be scanned the day it lands, and a list would have
  # to be edited for that to happen — which is the fail-open shape this slice is
  # closing, one level up.
  @candidate_go_dir Path.expand("../../../internal/cloudclient", __DIR__)

  @sources %{
    "internal/cloudclient/client.go" => @cloudclient,
    "internal/cloudclient/deliveries.go" => @deliveries,
    "internal/cloudclient/site_build_log.go" => @site_build_log,
    "internal/cloudclient/site_build_log_bytes.go" => @site_build_log_bytes,
    "cloud/lib/barkpark_cloud/notifications.ex" => @notifications
  }

  # ---------------------------------------------------------------------------
  # SIDE A — THE SIGNAL REGISTRY. A declaration, checked against derivation.
  # ---------------------------------------------------------------------------
  @signals [
    %{
      name: "fleet_deploy_census",
      kind: :pull,
      what:
        "the cross-site deploy census: failure class, site counts and the failure RATE with its denominator — THE deploy-reliability headline read",
      readers: [%{file: "internal/cloudclient/client.go", func: "FleetDeployCensus"}]
    },
    %{
      name: "site_deployment_history",
      kind: :pull,
      what:
        "one site's production deployment ledger, keyset-paged — how a team audits its own deploy failures",
      readers: [
        %{file: "internal/cloudclient/client.go", func: "ListDeployments"},
        # SAME ROUTE, SECOND READER (dr-w19-audience-registry-fail-open). The
        # candidate derivation found `ListSpawnSiteDeployments` sending the same
        # GET /v1/sites/*/deployments with no row; it is not a second SIGNAL —
        # one route, one audience — so it is a second reader of this one.
        %{file: "internal/cloudclient/client.go", func: "ListSpawnSiteDeployments"}
      ]
    },
    %{
      name: "fleet_rollout_state",
      kind: :pull,
      what:
        "whether the fleet autoupdate rollout is halted — the brake's position, read before and after a deploy wave",
      readers: [%{file: "internal/cloudclient/client.go", func: "RolloutStatus"}]
    },
    %{
      name: "platform_delivery_record",
      kind: :pull,
      what:
        "THE CROWN read, `bp cloud deliveries <sha>`: the platform's own per-sha delivery record — what was delivered, on whose run, and the clocks around it",
      readers: [%{file: "internal/cloudclient/deliveries.go", func: "PlatformDeliveries"}]
    },
    %{
      name: "site_deployment_detail",
      kind: :pull,
      what:
        "ONE deployment's row: its status, its clocks and its failure class — the read a team makes when the ledger page says a deploy failed and the question is which one",
      readers: [%{file: "internal/cloudclient/client.go", func: "SpawnSiteDeployment"}]
    },
    %{
      name: "site_build_log",
      kind: :pull,
      what:
        "the BUILD LOG of one deployment — the only deploy-health read that carries the failure's own words rather than a class label, and the last stop before a human guesses. Two doors onto the one signal: the SCRUBBED record (user-tier) and the raw BYTES (operator-tier)",
      readers: [
        %{file: "internal/cloudclient/site_build_log.go", func: "SiteBuildLog"},
        # SAME SIGNAL, SECOND DOOR (task-801c6c33769ca01d). `SiteBuildLogBytes`
        # sends GET /v1/sites/*/deployments/*/build-log/bytes — a DISTINCT route
        # from the record's /build-log, but onto the SAME signal: one deployment's
        # build log. The bytes door is deliberately operator-gated because raw,
        # never-scrubbed bytes can carry secrets, so Side B derives tier `operator`
        # (empty) for THIS reader while the record reader stays `user(s)`. That is
        # NOT an empty-audience finding: the build-log signal REACHES a human over
        # the scrubbed record door, and the raw-bytes door is a superset-privilege
        # escalation, not a signal addressed to nobody — which is exactly why the
        # empty-audience arm reds only when EVERY reader of a signal is empty.
        %{file: "internal/cloudclient/site_build_log_bytes.go", func: "SiteBuildLogBytes"}
      ]
    },
    %{
      name: "site_deploy_rate_alert",
      kind: :push,
      what:
        "the DEPLOY FAILURE RATE alert: one email per red episode when a team's deploy failure rate crosses the verdict threshold for N consecutive ticks",
      readers: [
        %{file: "cloud/lib/barkpark_cloud/notifications.ex", func: "deliver_deploy_rate_notices"}
      ]
    },
    %{
      name: "fleet_operator_digest",
      kind: :push,
      what:
        "the daily FLEET-UPDATE digest email: the curator's judgment over every instance, pushed to an inbox",
      readers: [
        %{file: "cloud/lib/barkpark_cloud/notifications.ex", func: "deliver_fleet_digest"}
      ]
    },
    %{
      name: "site_deploy_failure_alert",
      kind: :push,
      what:
        "the deployment-failure alert raised by the fenced transition / stale reaper / failed-deployment writer",
      readers: [%{file: "cloud/lib/barkpark_cloud/notifications.ex", func: "dispatch_event"}]
    }
  ]

  # WHY THE DIGEST *RECEIPT* READ IS NOT A SEVENTH ROW (dr-w20-bl). The daily
  # digest's Delivery receipt is now provably readable by the team it belongs to
  # over GET /v1/notifications/deliveries?event=fleet_digest, tier `user`, pinned
  # in `router_notifications_test.exs` — but that read is NOT a distinct signal
  # and does not get a row here, for two reasons that are structural rather than
  # editorial:
  #
  #   * it is the SAME signal as `fleet_operator_digest`, seen from the receiving
  #     end. That row's audience already derives `team_members` and is already
  #     off the allowlist; a second row over one signal would inflate
  #     `@signal_floor` without widening what the census can see.
  #   * Side B for a `:pull` signal is derived from a Go reader in
  #     `internal/cloudclient` (`@sources`), and NO Go source sends
  #     /v1/notifications/deliveries — `grep -rn "notifications/deliveries"
  #     internal/` is empty. A row naming a reader that does not exist fails
  #     `path_of/1`'s `Map.fetch!` or the extractor, which is a red about this
  #     file rather than about an audience. When a `bp` command grows that read,
  #     THAT is the commit that registers it.

  # THE ANTI-VACUITY FLOOR. A deleted registry row, or a Go/Elixir syntax change
  # that quietly empties Side B, would otherwise be a silent green: zero signals
  # examined is zero empty audiences found. Committed, and lowered only in the
  # same commit as the signal that went away.
  # Raised 5 -> 6 by dr-w27-bl-fleet-rollout-state-has-no-human-reader, which
  # registered `bp cloud deliveries` — the crown read this census was FAILING
  # OPEN over. Lowered only in the same commit as the signal that goes away.
  # Raised 6 -> 9 by dr-w19-audience-registry-fail-open: the candidate derivation
  # below found three deploy-health signals with no row at all — one deployment's
  # detail read, the build log, and the deploy-failure-RATE alert — and registering
  # them is what the derivation is for. Lowered only in the same commit as the
  # signal that goes away.
  @signal_floor 9
  # Raised 6 -> 10 in the same commit: three new signals plus the second reader
  # (`ListSpawnSiteDeployments`) the derivation found on an already-registered route.
  # Raised 10 -> 11 by task-801c6c33769ca01d: `SiteBuildLogBytes`, the second door
  # (raw bytes) onto the `site_build_log` signal. Lowered only in the same commit
  # as the reader that goes away.
  @reader_floor 11

  # THE CANDIDATE FLOOR. Side C's own anti-vacuity number: a derivation that
  # finds FEWER candidates than the registry has rows has stopped reading the
  # source, and zero candidates is zero unregistered candidates — a silent green
  # over the exact hole this arm closes. Committed, and lowered only in the same
  # commit as the reader that went away.
  @candidate_floor 8

  # THE PULL-SIDE EMPTY TIERS. `operator` was the whole list until dr-w19-s5,
  # and that made the census's green on a `worker`-tier reader VACUOUS: `worker`
  # is a MACHINE population whose secret (`WORKER_TOKEN`) is held by the
  # provisioner, not by any account. No human credential satisfies it — a
  # `bp cloud rollout status` on the real prod owner token 401s today — so a
  # deploy-health signal readable ONLY over a worker-tier route is exactly as
  # unreachable to a person as an operator-tier one, and this census exists to
  # say so rather than to grade the router.
  #
  # The moduledoc's older sentence ("a `worker`-tier reader is a MACHINE
  # population and this census does not judge whether its secret is provisioned
  # anywhere") is now narrowed by construction: the census does not judge the
  # PROVISIONING, but it no longer calls the tier reachable.
  @empty_pull_tiers ["operator", "worker"]

  # ---------------------------------------------------------------------------
  # THE ALLOWLIST — today's empty audiences, each WITH ITS CLOSER.
  # ---------------------------------------------------------------------------
  # This guard ships in the SAME round as the slices that fix what it finds, so
  # it declares today's truth honestly instead of reddening on arrival. When a
  # closer merges, its row goes stale and this file reds IN THE GOOD DIRECTION —
  # the rot assertion below is what makes that happen.
  #
  # MERGE ORDER, W18 REVIEW — READ BEFORE MERGING THIS FILE. `fleet_deploy_census`
  # is closed by dr-w18-s1, which is in flight in the SAME wave. The rot assertion
  # is therefore ARMED, not hypothetical: whichever of the two merges SECOND takes
  # the red, and the fix is the same either way — delete the `fleet_deploy_census`
  # row in that PR. This file and dr-w18-s1 are deliberately NOT co-merged, because
  # a guard and its fix in one diff can never demonstrate the fail-before state.
  # The other row is NOT armed: dr-w18-s3 counts the digest's loss but leaves its
  # AUDIENCE the platform allowlist, so that row's closer is a later slice.
  @empty_audience_allowlist %{
    # `fleet_deploy_census` used to sit here: its only reader sent
    # GET /v1/operator/deploy-ledger/census, gated on the `:platform_admin_emails`
    # allowlist that is unset on prod and unsettable through any route, console
    # action or User field — ZERO accounts could read the epic's headline number.
    # Its named CLOSER (dr-w18-s1) is THIS branch: the client now reads the
    # team-scoped GET /v1/deploy-ledger/census, tier `user`, which every member of
    # every team can reach. The "allowlist cannot rot" test reds on an excuse that
    # stopped being true and ordered this deletion by name, so the row is gone in
    # the same commit as the reader that closed it.
    #
    # `fleet_operator_digest` used to sit here too: `deliver_fleet_digest/1`
    # resolved its recipients through `platform_admin_emails/0`, so the daily
    # digest took its `:no_admins` arm every single day and nobody ever received
    # one. Its named CLOSER (dr-w19-fleet-digest-audience-still-empty) is THIS
    # branch: the digest is now partitioned by team and addressed to each team's
    # own membership rows, so Side B reclassifies it `team_members` with no test
    # edit at all. The rot assertion below reddened in its own words ("This is
    # the GOOD direction: its closer landed. Delete the allowlist row.") and the
    # row is gone in the same commit as the re-address that closed it.
    # `site_build_log` used to sit here, and it was FOUND BY THE DERIVATION, NOT BY
    # A HUMAN (dr-w19-audience-registry-fail-open) — it had no row in this file at
    # all until the candidate set named it, and the census had been green over it
    # for nine waves. Its reader sends GET /v1/sites/*/deployments/*/build-log,
    # which the router enforced at tier `operator`: the `:platform_admin_emails`
    # allowlist, unset on prod and unsettable through any route, console action or
    # User field. So the ONE deploy-health read that carries a failed build's
    # ACTUAL LOG TEXT, rather than a failure-class label, was readable by zero
    # accounts while its sibling reads on the same resource
    # (GET /v1/sites/*/deployments/*, tier `user(s)`) answered every member of the
    # owning team. Its named CLOSER (dr-w19-site-build-log-is-operator-only) is
    # THIS branch: the route now goes through `with_team_site(conn, {:ability,
    # "read"}, …)` — the sibling's own door — so Side B derives tier `user(s)` and
    # the rot assertion below reddened in its own words ("This is the GOOD
    # direction: its closer landed. Delete the allowlist row."). The row is gone in
    # the same commit as the re-point that closed it.
    "fleet_rollout_state" =>
      "EMPTY BY CONSTRUCTION — but the CONSTRUCTION MOVED, and so did the reason. " <>
        "`platform_admin_emails/0` reads `[]` when the config key is unset, so the " <>
        "gate still resolves to zero accounts by construction; what changed is WHY. " <>
        "This row used to read " <>
        "'`RolloutStatus` sends GET /v1/admin/autoupdate, tier `worker`' — the " <>
        "machine population that holds `WORKER_TOKEN`, which no human account holds. " <>
        "isu-backlog-operator-principal repointed the three rollout verbs at the " <>
        "operator door (GET/POST /v1/operator/autoupdate*, the same trio the console " <>
        "calls), so Side B now derives tier `operator` from source with no edit here. " <>
        "The row's own prediction that repointing 'reds this census harder' is " <>
        "REFUTED: dr-w19-s5 had already put `operator` in @empty_pull_tiers, so the " <>
        "verdict is unchanged and only the REASON moved. What is left is not a " <>
        "missing verb or a wrong door — it is that `:platform_admin_emails` is unset " <>
        "on the live control plane, so the human-shaped door has nobody behind it. " <>
        "Charter D30 rules that allowlist a PERMANENT HUMAN GATE. " <>
        "CLOSER: gr-ops-platform-admin-emails — set PLATFORM_ADMIN_EMAILS on the live " <>
        "control plane and the operator door opens for a real person; when it lands, " <>
        "delete this row."
  }

  # ---------------------------------------------------------------------------
  # THE ZERO-VIEWER CONSOLE SURFACES (dr-w27-bl-fleet-rollout-state-has-no-human-reader)
  # ---------------------------------------------------------------------------
  # The operator console mounts a page of deploy cards behind
  # `Auth.require_platform_operator/2` on every route it reads. That principal is
  # the `:platform_admin_emails` allowlist — the same population `fleet_rollout_state`
  # is allowlisted for above — so every one of those cards is RENDERED CODE WITH
  # ZERO POSSIBLE VIEWERS, and the count belongs in a census rather than in prose.
  #
  # THE FILING SAID FOUR. It is FIVE on main: `operatorPageHtml/0`'s own comment
  # still says "five cards" while the block comment above `OPERATOR_FLEET` says
  # "FOUR cards", and the fifth — "Deploy ledger", painted from
  # GET /v1/operator/deploy-ledger/census — is the one the older sentence predates.
  # This pin is DERIVED from source on every run and the number below is only the
  # floor-and-ceiling it must still equal, so a card added or deleted reds HERE.
  @operator_console_card_pin 5

  # ---------------------------------------------------------------------------
  # SIDE B — the derivation
  # ---------------------------------------------------------------------------

  defp path_of(%{file: file}), do: Map.fetch!(@sources, file)

  # A router path with `:param` segments, rendered the way GoReader renders a
  # spliced Go value, so the two can be compared.
  defp pattern(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn seg -> if String.starts_with?(seg, ":"), do: "*", else: seg end)
  end

  defp audience(%{kind: :pull}, reader, opts) do
    case GoReader.request_path(path_of(reader), reader.func, opts) do
      {:ok, %{method: method, path: path, line: line}} ->
        case route_for(method, path) do
          {:ok, route_path} ->
            case Lens.tier_of(method, route_path) do
              {:ok, tier} ->
                {:ok,
                 %{
                   where: "#{reader.file}:#{line}",
                   sends: "#{method} #{path}",
                   resolves: tier,
                   empty?: tier in @empty_pull_tiers
                 }}

              {:error, why} ->
                {:error, {reader, line, {:tier, why}}}
            end

          {:error, why} ->
            {:error, {reader, line, {:route, why, "#{method} #{path}"}}}
        end

      {:error, why} ->
        {:error, {reader, 0, why}}
    end
  end

  defp audience(%{kind: :push}, reader, opts) do
    case ExReader.recipient_population(path_of(reader), reader.func, opts) do
      {:ok, %{resolver: resolver, population: population, line: line}} ->
        {:ok,
         %{
           where: "#{reader.file}:#{line}",
           sends: "recipients <- #{resolver}/*",
           resolves: Atom.to_string(population),
           empty?: population == :platform_allowlist
         }}

      {:error, why} ->
        {:error, {reader, 0, why}}
    end
  end

  defp route_for(method, pattern) do
    matches =
      Lens.route_keys()
      |> Enum.filter(fn {m, p} -> m == method and pattern(p) == pattern end)

    case matches do
      [{_m, p}] -> {:ok, p}
      [] -> {:error, :no_such_route}
      many -> {:error, {:ambiguous, length(many)}}
    end
  end

  defp derive(opts \\ []) do
    Enum.map(@signals, fn signal ->
      derived = Enum.map(signal.readers, &audience(signal, &1, opts))
      {signal, derived}
    end)
  end

  defp ok_audiences(derived), do: for({:ok, a} <- derived, do: a)

  # ---------------------------------------------------------------------------

  test "the registry is a real declaration: floors, unique names, resolvable sources" do
    assert length(@signals) >= @signal_floor, """
    the signal registry declares #{length(@signals)} signal(s); the floor is #{@signal_floor}.
    A deleted row is a signal this census stops watching — lower the floor in the
    SAME commit as the signal that went away, or put the row back.
    """

    readers = Enum.flat_map(@signals, & &1.readers)

    assert length(readers) >= @reader_floor,
           "the registry declares #{length(readers)} reader(s); the floor is #{@reader_floor}"

    assert length(Enum.uniq_by(@signals, & &1.name)) == length(@signals)

    for signal <- @signals do
      assert signal.kind in [:pull, :push], "#{signal.name}: unknown kind #{inspect(signal.kind)}"

      assert byte_size(signal.what) > 60,
             "#{signal.name}: a signal row must say what the signal IS, in words a reader " <>
               "can check against the code"

      for reader <- signal.readers do
        assert Map.has_key?(@sources, reader.file),
               "#{signal.name}: reader file #{reader.file} is not in @sources"
      end
    end
  end

  test "SIDE B derives an audience for EVERY declared reader — a reader it cannot read REDS" do
    derived = derive()

    failures =
      for {signal, results} <- derived,
          {:error, {reader, line, why}} <- results,
          do: "  #{signal.name}: #{reader.file}:#{line} #{reader.func} — #{inspect(why)}"

    assert failures == [], """
    #{length(failures)} declared reader(s) could not be resolved to an audience. An
    unresolved reader is a signal this census is green over BY CONSTRUCTION — teach
    the extractor the idiom, or fix the registry row:

    #{Enum.join(failures, "\n")}
    """

    rows =
      for {signal, results} <- derived, a <- ok_audiences(results) do
        "  #{String.pad_trailing(signal.name, 26)} #{String.pad_trailing(a.sends, 44)} " <>
          "-> #{String.pad_trailing(a.resolves, 18)} #{a.where}"
      end

    IO.puts("""

    deploy-health signal audience census
      signals declared : #{length(@signals)}
      readers derived  : #{length(rows)}
    #{Enum.join(rows, "\n")}
    """)

    assert length(rows) >= @reader_floor
  end

  test "a signal whose EVERY reader is empty-by-construction REDS unless it is allowlisted" do
    offenders =
      for {signal, results} <- derive(),
          audiences = ok_audiences(results),
          audiences != [],
          Enum.all?(audiences, & &1.empty?),
          not Map.has_key?(@empty_audience_allowlist, signal.name) do
        "  #{signal.name} (#{signal.kind}) — every reader lands on an empty population:\n" <>
          Enum.map_join(audiences, "\n", fn a ->
            "      #{a.where}  sends #{a.sends}  -> #{a.resolves}"
          end)
      end

    assert offenders == [], """
    #{length(offenders)} deploy-health signal(s) have an audience that is EMPTY BY
    CONSTRUCTION: every reader resolves to a population no person is in — the
    platform-operator allowlist, which no account is in and none can join
    (PLATFORM_ADMIN_EMAILS is unset on prod, no User field carries operator-ness,
    and nothing but runtime.exs writes the key), or the `worker` machine tier,
    whose token no human account holds. A signal reported there is a signal nobody
    receives.

    #{Enum.join(offenders, "\n")}

    Fix: give the signal a reader with a reachable audience (a team-scoped route,
    a team-resolved recipient set). If it must stay operator-only for now, add it
    to @empty_audience_allowlist WITH the task that closes it.
    """
  end

  test "the allowlist cannot rot: a row whose audience is no longer empty REDS" do
    derived = derive()

    for {name, _reason} <- @empty_audience_allowlist do
      signal = Enum.find(@signals, &(&1.name == name))

      assert signal != nil,
             "@empty_audience_allowlist names #{name}, which is no longer a declared " <>
               "signal. Delete the allowlist row."

      audiences =
        derived
        |> Enum.find_value(fn {s, results} -> if s.name == name, do: ok_audiences(results) end)

      assert Enum.all?(audiences, & &1.empty?), """
      @empty_audience_allowlist excuses `#{name}` as empty-by-construction, but at
      least one of its readers now resolves to a REACHABLE audience:

      #{Enum.map_join(audiences, "\n", fn a -> "      #{a.where}  sends #{a.sends}  -> #{a.resolves}#{if a.empty?, do: "  (still empty)", else: "  <- REACHABLE"}" end)}

      This is the GOOD direction: its closer landed. Delete the allowlist row.
      """
    end
  end

  test "every allowlist reason is a RULING that names its closer" do
    for {name, reason} <- @empty_audience_allowlist do
      assert byte_size(reason) > 60, "#{name}: a reason this short is not a ruling"

      # The closer is a bp TASK SLUG or a PR number. The slug pattern is
      # `dr-w<N>-<rest>` — widened from `dr-w\d+-s\d+` in the w18 review, because
      # a closer is not always a numbered slice of the wave that found the hole:
      # `fleet_operator_digest`'s real closer was
      # `dr-w19-fleet-digest-audience-still-empty`, a filed follow-up. Still
      # anchored on a filed slug prefix, so free prose cannot satisfy it.
      #
      # dr-w19-s5 admits the `gr-ops-` prefix as well, for the same reason the
      # `dr-w\d+-` form was widened: `fleet_rollout_state`'s only real closer is
      # a HUMAN GATE (`gr-ops-platform-admin-emails` — set the env var on the
      # live control plane), and no amount of code closes it. Forcing a `dr-w`
      # slug there would have made the row name a closer that cannot close it,
      # which is the junk drawer this assertion exists to prevent.
      assert reason =~ ~r/CLOSER: (dr-w\d+-[a-z0-9-]+|gr-ops-[a-z0-9-]+|PR #\d+)/,
             "#{name}: an empty-audience row must name the task or PR that closes it — " <>
               "an allowlist without closers is a junk drawer"

      assert reason =~ ~r/EMPTY BY CONSTRUCTION/,
             "#{name}: the row must state the census evidence, not just an intention"
    end

    # If this ever reads zero, the allowlist has stopped being able to say
    # "this one is empty" and every row above is decoration.
    assert map_size(@empty_audience_allowlist) > 0
  end

  test "ANTI-VACUITY: the BROKEN walker derives a DIFFERENT (empty) Side B" do
    real = derive() |> Enum.flat_map(fn {_s, r} -> ok_audiences(r) end)
    broken = derive(walker: :broken) |> Enum.flat_map(fn {_s, r} -> ok_audiences(r) end)

    assert length(real) >= @reader_floor

    assert broken == [], """
    the BROKEN walker still derived #{length(broken)} audience(s). It is kept alive
    on purpose (the `naive_grep_callers/2` idiom) to prove this census can LOSE its
    Side B: a walker that stopped matching would report zero empty audiences and
    pass, which is exactly the vacuous green this file exists to not have.
    """

    refute real == broken
  end

  test "FAIL-CLOSED: a missing or renamed source is a NAMED refusal, never a tier" do
    gone = Path.expand("../../../internal/cloudclient/client_renamed.go", __DIR__)

    assert_raise ArgumentError, ~r/Go reader source not found at .*client_renamed\.go/, fn ->
      GoReader.request_path(gone, "FleetDeployCensus")
    end

    gone_ex = Path.expand("../../lib/barkpark_cloud/notifications_renamed.ex", __DIR__)

    assert_raise ArgumentError,
                 ~r/Elixir reader source not found at .*notifications_renamed\.ex/,
                 fn -> ExReader.recipient_population(gone_ex, "deliver_fleet_digest") end

    assert_raise ArgumentError, ~r/router source not found at .*router_renamed\.ex/, fn ->
      Lens.source(Path.expand("../../lib/barkpark_cloud/web/router_renamed.ex", __DIR__))
    end

    # A renamed FUNCTION is a refusal too — never a derived tier.
    assert GoReader.request_path(@cloudclient, "FleetDeployCensusRenamed") ==
             {:error, :func_not_found}

    assert ExReader.recipient_population(@notifications, "deliver_fleet_digest_renamed") ==
             {:error, :func_not_found}
  end

  # The needles are CALL shapes, not words: this file and the lens both DISCUSS
  # `Application.get_env` and the env var in prose, and a word-match would red on
  # its own moduledoc. A call is what makes a guard vacuous, and a call has an
  # open paren (or, for the env var, quotes around it). The patterns are written
  # with escapes so this assertion does not contain its own needle — the
  # self-referential trap that a plain string match walks straight into.
  @runtime_read_needles [
    {~r/Application\.get_env\(/,
     "reads config at runtime. config.exs hard-defaults :platform_admin_emails to [], " <>
       "so a config-reading guard is vacuous in CI by construction — derive the " <>
       "judgment from source instead."},
    {~r/System\.get_env\(/, "reads the environment at runtime; the same vacuity applies."},
    {~r/"PLATFORM_ADMIN_[A-Z]+"/,
     "reads the env var as a literal. The population's emptiness is derived " <>
       "STRUCTURALLY here (the config KEY NAME as source text, in ExReader), never " <>
       "from the value CI happens to hold."}
  ]

  test "the derivation is STRUCTURAL: no runtime read of the allowlist anywhere in this census" do
    lens = Path.expand("../support/router_tier_lens.ex", __DIR__)

    for file <- [@self, lens] do
      assert File.regular?(file),
             "the structural-derivation scan cannot read #{file}. A scan over a file " <>
               "that is not there passes over nothing — fix the path rather than let " <>
               "this assertion go vacuous."

      src = File.read!(file)

      for {needle, why} <- @runtime_read_needles do
        refute src =~ needle, "#{file} #{why}"
      end
    end
  end

  test "c1 — the fleet brake's position is UNREADABLE, and the census names the fenced act" do
    name = "fleet_rollout_state"
    reason = Map.fetch!(@empty_audience_allowlist, name)

    audiences =
      derive()
      |> Enum.find_value(fn {s, results} -> if s.name == name, do: ok_audiences(results) end)

    # DERIVED, not declared: the door the Go client actually knocks on, and the
    # tier router.ex actually enforces on it.
    assert [%{sends: sends, resolves: tier, empty?: true}] = audiences

    assert sends == "GET /v1/operator/autoupdate", """
    the fleet brake's reader now sends #{sends}. If that is a REACHABLE door the
    row above is stale and must be deleted; if it is another empty one, say so.
    """

    assert tier == "operator"
    assert tier in @empty_pull_tiers

    # The RECORD, by name. This is what the criterion buys when the reader path
    # cannot be opened by any code change in this repo: the census says WHICH
    # door, WHICH population, and WHICH act outside this tree would open it.
    assert reason =~ "/v1/operator/autoupdate",
           "#{name}: the row must name the door its reader knocks on"

    assert reason =~ ":platform_admin_emails",
           "#{name}: the row must name the population behind that door"

    assert reason =~ "CLOSER: gr-ops-platform-admin-emails",
           "#{name}: the row must name the act that would make the brake readable"

    assert reason =~ "PERMANENT HUMAN GATE", """
    #{name}: the row must say the closer is a FENCED, non-code act. Without that
    sentence a reader is sent hunting for a slice to write, and there is none —
    setting PLATFORM_ADMIN_EMAILS on the live control plane is the whole remedy.
    """
  end

  test "c2 — every operator console deploy card is a ZERO-VIEWER surface, and the count is published" do
    src = ConsoleReader.source(@app_js)
    cards = ConsoleReader.cards(src)
    paints = ConsoleReader.paints(src)

    assert length(cards) == @operator_console_card_pin, """
    the operator console mounts #{length(cards)} deploy card(s); the pin is
    #{@operator_console_card_pin}. A card added or removed changes the honest
    zero-viewer count — move the pin in the SAME commit, and say which card.
    """

    assert Enum.sort(Enum.map(cards, &elem(&1, 0))) == Enum.sort(Map.keys(paints)), """
    a card is mounted that nothing paints, or a paint targets no mounted card:
      mounted : #{inspect(Enum.map(cards, &elem(&1, 0)))}
      painted : #{inspect(Map.keys(paints))}
    """

    rows =
      for {id, heading} <- cards do
        path = Map.fetch!(paints, id)
        {:ok, route} = route_for("GET", path)
        {:ok, tier} = Lens.tier_of("GET", route)
        %{id: id, heading: heading, path: path, tier: tier, empty?: tier in @empty_pull_tiers}
      end

    reachable = Enum.reject(rows, & &1.empty?)

    assert reachable == [], """
    #{length(reachable)} operator console card(s) now read a REACHABLE route. That
    is the GOOD direction — the surface grew a viewer — but the published
    zero-viewer count below is now wrong. Re-state it:

    #{Enum.map_join(reachable, "\n", fn r -> "      #{r.id} (#{r.heading}) reads GET #{r.path} -> #{r.tier}" end)}
    """

    IO.puts("""

    operator console deploy cards — ZERO-VIEWER SURFACES
      cards mounted : #{length(rows)}  (every one gated on :platform_admin_emails, which is [] on prod)
    #{Enum.map_join(rows, "\n", fn r -> "      #{String.pad_trailing(r.id, 16)} #{String.pad_trailing(r.heading, 18)} GET #{String.pad_trailing(r.path, 38)} -> #{r.tier}" end)}

      THE NUMBER THIS CENSUS PUBLISHES ABOUT READERSHIP
        deploy-health signals with an empty audience : #{map_size(@empty_audience_allowlist)}
        operator console cards with zero viewers    : #{length(rows)}
    """)
  end

  test "ANTI-VACUITY: the BROKEN console walker derives NO cards" do
    src = ConsoleReader.source(@app_js)

    assert length(ConsoleReader.cards(src)) == @operator_console_card_pin

    assert ConsoleReader.cards(src, walker: :broken) == [], """
    the BROKEN card walker still found cards. It is kept alive on purpose to
    prove this half can LOSE: a walker that stopped matching would publish a
    zero-viewer count of zero and pass.
    """
  end

  test "FAIL-CLOSED: a missing console source, or a renamed function, is a NAMED refusal" do
    gone = Path.expand("../../priv/static/app_renamed.js", __DIR__)

    assert_raise ArgumentError, ~r/console source not found at .*app_renamed\.js/, fn ->
      ConsoleReader.source(gone)
    end

    src = ConsoleReader.source(@app_js)

    # A RENAMED function is a refusal too — never an empty card list, which would
    # publish a zero-viewer count of zero and read as "no such surfaces exist".
    mangled =
      String.replace(src, "  function operatorPageHtml(", "  function operatorPageHtmlGone(")

    refute mangled == src, "the control did not mangle anything — re-point it"

    assert_raise ArgumentError, ~r|function operatorPageHtml/0 not found|, fn ->
      ConsoleReader.cards(mangled)
    end

    mangled_paint =
      String.replace(src, "  function operatorRefresh(", "  function operatorRefreshGone(")

    refute mangled_paint == src

    assert_raise ArgumentError, ~r|function operatorRefresh/0 not found|, fn ->
      ConsoleReader.paints(mangled_paint)
    end
  end

  # ---------------------------------------------------------------------------
  # SIDE C — THE CANDIDATE SET, and the registry's own fail-open
  # ---------------------------------------------------------------------------
  # `@signals` is a DECLARATION, and this file's moduledoc has said since wave 18
  # that the declaration FAILS OPEN: "an unregistered signal is invisible to this
  # file… Nothing syntactic closes that hole." This is the syntactic thing that
  # closes it. `CandidateReader` derives, from source, what a deploy-health
  # signal LOOKS like — a GET on a `deploy-ledger|deployments|autoupdate|census`
  # path, or a public notification sender naming a deploy event — and a candidate
  # with no row anywhere in `@signals` REDS, naming its `file:line`.
  #
  # WHAT IT FOUND ON ITS FIRST RUN, and what happened to each:
  #   * `ListSpawnSiteDeployments` — same GET /v1/sites/*/deployments as the
  #     registered `ListDeployments`. One route, one audience: it became a SECOND
  #     READER of `site_deployment_history`, not a second signal.
  #   * `SpawnSiteDeployment` — GET /v1/sites/*/deployments/*. Registered as
  #     `site_deployment_detail`; derives tier `user`, reachable.
  #   * `SiteBuildLog` — GET /v1/sites/*/deployments/*/build-log. Registered as
  #     `site_build_log`, and it WAS the FINDING: the route was operator-gated, so
  #     the one deploy-health read that carries a failed build's actual log text
  #     was addressed to a population of zero. CLOSED by
  #     dr-w19-site-build-log-is-operator-only — the route now takes
  #     `with_team_site(conn, {:ability, "read"}, …)`, derives tier `user(s)`, and
  #     is reachable by every member of the team that owns the site. Its allowlist
  #     row is deleted; the rot assertion is what ordered that deletion.
  #   * `deliver_deploy_rate_notices` — the deploy-failure-RATE alert. Registered
  #     as `site_deploy_rate_alert`; reaches `team_member_emails/1` through one
  #     hop, so its audience is `team_members` and it is reachable.
  #
  # THE EXCUSE DOOR, and why it is empty today. A candidate that is genuinely NOT
  # a signal gets a row here saying so in words. Nothing needs one right now —
  # every candidate the derivation found got a real registry row instead, which
  # is the better answer — and the door is kept because the alternative is that
  # the next true non-signal has no honest way through except weakening the
  # extractor. Its mechanism is proven by the fake-candidate tests below, not by
  # a decorative live row.
  @unregistered_candidate_reasons %{}

  defp candidate_go_sources,
    do: CandidateReader.go_sources(@candidate_go_dir, "internal/cloudclient")

  defp candidate_ex_source,
    do: {"cloud/lib/barkpark_cloud/notifications.ex", File.read!(@notifications)}

  defp candidates do
    CandidateReader.go_candidates(candidate_go_sources()) ++
      CandidateReader.ex_candidates(candidate_ex_source())
  end

  # A candidate is REGISTERED when some `@signals` row names its exact
  # `{file, func}`. Nothing else counts: a signal whose name merely resembles the
  # method is not a row that points at it.
  defp unregistered(candidates, signals, reasons) do
    registered =
      for signal <- signals, reader <- signal.readers, into: MapSet.new() do
        {reader.file, reader.func}
      end

    Enum.reject(candidates, fn c ->
      MapSet.member?(registered, {c.file, c.func}) or
        Map.has_key?(reasons, {c.file, c.func})
    end)
  end

  test "SIDE C — a deploy-health candidate with NO registry row REDS, naming file:line" do
    found = candidates()

    rows =
      for c <- found do
        "  #{String.pad_trailing("#{c.file}:#{c.line}", 46)} #{String.pad_trailing(c.func, 28)} " <>
          "#{c.kind} #{c.sends}"
      end

    IO.puts("""

    deploy-health CANDIDATE set, derived from source
      candidates : #{length(found)}  (#{Enum.count(found, &(&1.kind == :pull))} pull, #{Enum.count(found, &(&1.kind == :push))} push)
    #{Enum.join(rows, "\n")}
    """)

    assert length(found) >= @candidate_floor, """
    the derivation found #{length(found)} candidate(s); the floor is #{@candidate_floor}.
    A derivation that finds FEWER candidates than the registry has rows has stopped
    reading the source — teach the extractor the new idiom, or lower the floor in
    the SAME commit as the reader that went away.
    """

    missing = unregistered(found, @signals, @unregistered_candidate_reasons)

    assert missing == [], """
    #{length(missing)} deploy-health signal(s) exist in SOURCE with no row in
    `@signals` at all. The census is green over them BY CONSTRUCTION — it cannot
    judge the audience of a signal it has never heard of, which is the fail-open
    this arm exists to close:

    #{Enum.map_join(missing, "\n", fn c -> "      #{c.file}:#{c.line}  #{c.func}  (#{c.kind}) #{c.sends}" end)}

    Fix: add a `@signals` row naming that `{file, func}` — and raise
    `@signal_floor`/`@reader_floor` with it — or, if it is genuinely not a signal,
    add a `@unregistered_candidate_reasons` row that says SO IN WORDS.
    """
  end

  test "SIDE C RED-ON-DEMAND: a fake candidate with no row REDS and names its file:line" do
    fake = %{
      file: "internal/cloudclient/client.go",
      func: "ListPhantomDeployments",
      line: 4242,
      kind: :pull,
      sends: "GET /v1/sites/*/deployments/phantom"
    }

    missing = unregistered([fake | candidates()], @signals, @unregistered_candidate_reasons)

    assert [%{func: "ListPhantomDeployments", line: 4242}] = missing,
           "a candidate absent from @signals must survive the registered filter — " <>
             "if it does not, the arm above is green because it cannot see anything"

    # The red the real assertion prints MUST carry the location, because
    # "something is unregistered" is not actionable and `file:line` is.
    rendered = "#{hd(missing).file}:#{hd(missing).line}"
    assert rendered == "internal/cloudclient/client.go:4242"
  end

  test "SIDE C EXCUSE DOOR: a stated reason — and only a stated reason — lets a candidate through" do
    fake = %{
      file: "internal/cloudclient/client.go",
      func: "ListPhantomDeployments",
      line: 4242,
      kind: :pull,
      sends: "GET /v1/sites/*/deployments/phantom"
    }

    key = {fake.file, fake.func}

    assert unregistered([fake], @signals, %{}) == [fake]

    assert unregistered([fake], @signals, %{key => "not a signal: a phantom, by construction"}) ==
             []

    # The excuse is keyed on the EXACT {file, func}. A reason filed against a
    # different method does not silence this one — otherwise one row could quietly
    # excuse a whole file.
    assert unregistered([fake], @signals, %{
             {fake.file, "SomeOtherMethod"} => "an excuse for a different method"
           }) == [fake]
  end

  test "MUTATION: the PULL derivation SHRINKS when the Go source loses a method" do
    sources = candidate_go_sources()
    before = CandidateReader.go_candidates(sources)

    assert Enum.any?(before, &(&1.func == "SiteBuildLog")),
           "the mutation below removes `SiteBuildLog`; if it is not in the baseline set " <>
             "this test measures nothing"

    mutated =
      Enum.map(sources, fn {label, src} ->
        {label, String.replace(src, "func (c *Client) SiteBuildLog(", "func (c *Client) zz(")}
      end)

    after_ = CandidateReader.go_candidates(mutated)

    assert length(after_) == length(before) - 1, """
    deleting one deploy-health Go method changed the candidate count from
    #{length(before)} to #{length(after_)}. A derived set that does not move when its
    SOURCE moves is a hand-written list wearing a derivation's clothes.
    """

    assert Enum.map(after_, & &1.func) == Enum.map(before, & &1.func) -- ["SiteBuildLog"]
  end

  test "MUTATION: the PUSH derivation SHRINKS when a notifications sender goes away" do
    {label, src} = candidate_ex_source()
    before = CandidateReader.ex_candidates({label, src})

    assert Enum.any?(before, &(&1.func == "deliver_deploy_rate_notices"))

    mutated =
      String.replace(src, "  def deliver_deploy_rate_notices(", "  defp zz_deploy_rate_notices(")

    after_ = CandidateReader.ex_candidates({label, mutated})

    assert length(after_) == length(before) - 1, """
    removing one public deploy-event sender changed the push candidate count from
    #{length(before)} to #{length(after_)}.
    """

    refute Enum.any?(after_, &(&1.func == "deliver_deploy_rate_notices"))
  end

  test "POSITIVE CONTROL: the extractor REFUSES an empty read rather than returning []" do
    # A corpus with no exported client method. `[]` here would make every
    # assertion above vacuously true — zero candidates is zero unregistered
    # candidates — so it is a RAISE.
    assert_raise ArgumentError, ~r/zero exported \*Client methods across/, fn ->
      CandidateReader.go_candidates([{"scratch/empty.go", "package cloudclient\n"}])
    end

    # And the real Elixir module, fed to the Go extractor, is exactly that shape:
    # a file that exists, is non-empty, and carries nothing the scanner reads.
    assert_raise ArgumentError, ~r/zero exported \*Client methods across/, fn ->
      CandidateReader.go_candidates([{"notifications.ex", File.read!(@notifications)}])
    end

    assert_raise ArgumentError, ~r/zero public deliver_\*\/dispatch_\* functions/, fn ->
      CandidateReader.ex_candidates({"scratch/empty.ex", "defmodule X do\nend\n"})
    end

    # A missing package directory is a NAMED refusal, never an empty scan.
    assert_raise ArgumentError, ~r/Go client package not found/, fn ->
      CandidateReader.go_sources(@candidate_go_dir <> "-gone", "internal/cloudclient")
    end

    # CONTROL ON THE CONTROL: the same extractor over the REAL corpus does NOT
    # raise and does NOT return []. Without this, the four refusals above are
    # consistent with an extractor that refuses everything.
    live = CandidateReader.go_candidates(candidate_go_sources())
    assert length(live) > 0
  end

  # THE MODULEDOC, AND NOTHING ELSE. The test below used to read the WHOLE FILE
  # into `src` — so every `assert src =~ "..."` matched ITS OWN ASSERTION
  # LITERAL, and the guard was VACUOUS on main for all three of its probes.
  # Measured, not assumed (dr-w19-audience-registry-fail-open): deleting the
  # sentence from the moduledoc left the test GREEN. Scoping the read to the
  # moduledoc is what makes the probe about the doc rather than about itself.
  defp moduledoc_text do
    src = File.read!(@self)

    # The LAST `@moduledoc` before `use ExUnit.Case` — this file carries four of
    # them (the three readers, then the census), and a non-greedy match from the
    # front lands on `GoReader`'s.
    [head, _] = String.split(src, "\n  use ExUnit.Case", parts: 2)

    head
    |> String.split("  @moduledoc \"\"\"\n")
    |> List.last()
    |> String.split("\n  \"\"\"")
    |> hd()
  end

  test "the moduledoc states the LIMIT of the claim" do
    src = moduledoc_text()

    # THE CONTROL ON THE PROBE. If `src` ever grows back into the whole file,
    # these assertions start matching themselves and stop measuring anything.
    refute src =~ "assert src =~",
           "the limit probe is reading its own assertions again — scope it to the moduledoc"

    assert byte_size(src) < byte_size(File.read!(@self)) / 2

    # WHITESPACE-TOLERANT, because the moduledoc is HARD-WRAPPED at 80 columns and
    # "does NOT prove any route returns 200" is split across two lines in it. The
    # old whole-file probe matched the ASSERTION LITERAL and never the doc, which
    # is how a probe for a sentence that is not literally present stayed green.
    assert src =~ ~r/This proves an AUDIENCE SHAPE,\s+not DELIVERY/
    assert src =~ ~r/does NOT prove any\s+route returns 200/

    # dr-w19-audience-registry-fail-open RETRACTED the old admission — "the
    # registry FAILS OPEN: an unregistered signal is invisible to this file" —
    # and this assertion used to grep for exactly that sentence. IT WOULD HAVE
    # STAYED GREEN ON THE RETRACTION: the retraction QUOTES the sentence it
    # retracts, three lines above the correction, so the old probe matched its
    # own obituary and reported that the file still admitted a hole it had just
    # closed. A guard must probe the NEW text.
    assert src =~ "the registry no longer fails open"
    assert src =~ "This moduledoc used to end:"

    # And the NEW claim carries its own limit, which is narrower than "no deploy
    # signal can hide": the derivation reads two shapes and is blind to the rest.
    assert src =~ ~r/The derivation sees\s+the two shapes it reads and no others/
  end
end
