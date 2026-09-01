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
  def request_path(file, func, opts \\ []) do
    src = source(file)

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

        case Regex.run(re, fun_body) do
          [_, resolver] ->
            {:ok, %{resolver: resolver, population: classify(src, resolver), line: line}}

          nil ->
            {:error, :no_recipient_resolver}
        end

      :error ->
        {:error, :func_not_found}
    end
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

  And the registry FAILS OPEN: an unregistered signal is invisible to this file,
  exactly as `router_head_fence_census_test.exs` admits of its own deny-list.
  Nothing syntactic closes that hole — a new instrument reaches this census only
  when someone adds its row. What this file buys is that the boundary MOVES
  LOUDLY: when a reader is re-pointed at a reachable route, or a signal's last
  reachable reader is taken away, the diff says so on the PR that did it.
  """

  use ExUnit.Case, async: true

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
  @notifications Path.expand("../../lib/barkpark_cloud/notifications.ex", __DIR__)

  @sources %{
    "internal/cloudclient/client.go" => @cloudclient,
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
      readers: [%{file: "internal/cloudclient/client.go", func: "ListDeployments"}]
    },
    %{
      name: "fleet_rollout_state",
      kind: :pull,
      what:
        "whether the fleet autoupdate rollout is halted — the brake's position, read before and after a deploy wave",
      readers: [%{file: "internal/cloudclient/client.go", func: "RolloutStatus"}]
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

  # THE ANTI-VACUITY FLOOR. A deleted registry row, or a Go/Elixir syntax change
  # that quietly empties Side B, would otherwise be a silent green: zero signals
  # examined is zero empty audiences found. Committed, and lowered only in the
  # same commit as the signal that went away.
  @signal_floor 5
  @reader_floor 5

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

  test "the moduledoc states the LIMIT of the claim" do
    src = File.read!(@self)

    assert src =~ "This proves an AUDIENCE SHAPE, not DELIVERY"
    assert src =~ "the registry FAILS OPEN: an unregistered signal is invisible"
    assert src =~ "does NOT prove any route returns 200"
  end
end
