defmodule BarkparkCloud.RouterTierLens do
  @moduledoc """
  THE route-to-tier resolver, read off `router.ex` SOURCE — one implementation,
  shared. Extracted from `RouterModuledocTableTest` (dr-w18-s4) so a second
  census can ask "what credential tier does this route enforce?" without a
  re-implementation drifting from the one the route-table tripwire trusts.

  A 25-line re-implementation resolves the obvious routes and is unproven over
  the ~160 others and over the COMPOSED guard keys (`require_user` plus a
  post-guard refusal, the `require_user_or_pat` + `deploy`-ability disjunction)
  that the real resolver handles. Hence extraction, not a third copy.

  ## What it resolves, and what it refuses to

  Four guard idioms, because the naive "`Auth.require_*` on the next line" regex
  reaches barely two thirds of the table and is vacuously green over the rest:

    * `Auth.require_*` in the route body — a CALL, never a mention: full-line
      comments are stripped first, so prose about `Auth.require_ability/2` above a
      `cond` is not read as that route's gate;
    * `with_team_role(conn, "role")`;
    * a helper the body delegates the whole `conn` to (depth 2), resolved PER CALL
      SITE: when the helper gates on a mode argument (`with_team_site(conn,
      :session, …)` vs `with_team_site(conn, {:ability, "write"}, …)`), the literal
      the CALLER passes selects the branch. Reading the textually-first
      `Auth.require_*` out of a joined multi-clause helper gave all eleven
      /v1/sites delegators one answer, whichever of the three modes they passed;
    * a POST-GUARD ELEVATION — an `Auth.forbidden(conn, required: "…")` BELOW a
      permissive guard, which is the tier the route actually enforces. The
      signal is a REFUSAL, never a mention: a `team_admin?` that SCOPES a query
      narrows what you see and must not be read as a tier.

  A guard this module cannot resolve returns `nil`, and a guard missing from
  `guard_tier/0` is UNMAPPED — never a pass. Callers must treat both as a
  refusal to answer.

  ## The limit of the claim

  This answers "which guard does this route body invoke", read from source text.
  It does NOT prove the route returns 200, that the guard is the RIGHT guard, or
  that any credential satisfying that tier exists in production.
  """

  @default_source Path.expand("../../lib/barkpark_cloud/web/router.ex", __DIR__)

  # The tier vocabulary the route table uses. `user*` (ticket-or-Bearer) is
  # `user` with a footnote — same credential, presented two ways. `user(s)`
  # (session OR Personal Access Token) is a tier of its OWN, for the same reason
  # `admin(d)` is: it names a DIFFERENT credential, not a footnote on `user`.
  # Folding it down is how the eleven `with_team_site` routes, six of which a PAT
  # reaches and five of which turn one away, all read `user` — and how the
  # /v1/tokens rows advertised PAT-reachable management the code has never
  # allowed. `admin(d)` (session team-admin OR a PAT carrying the `deploy`
  # ability) stays its own tier too: a deploy-PAT holder needs no role at all and
  # telling them "admin" is its own lie.
  # `user(s)+worker` is a tier of its own for the SAME reason `user(s)` is: it
  # names a DIFFERENT credential set, not a footnote. GET /v1/deliveries admits
  # a session, a read-ability PAT, OR the faceless WORKER token — the principal
  # that WRITES the row (task-e2acb66e9ed0da09). Folding it to `user(s)` would
  # tell a CLI author the route is human-only, which is how the record ended up
  # with no API read path for its own writer; folding it to `worker` would tell
  # a human it is machine-only and delete the D385/D412 PAT reachability from
  # the contract. Both halves have to stay sayable in ONE cell.
  @tier_tokens ~w[user user* user(s) user(s)+worker admin admin(d) owner worker operator agent]

  # Every guard idiom the router uses, mapped to the tier column it justifies. A
  # guard MISSING from this map is treated as UNRESOLVED, never as a pass — a new
  # guard therefore reds instead of quietly widening a census's blind spot.
  @guard_tier %{
    "require_user" => "user",

    # SESSION OR PAT — a different credential from `require_user`, and the whole
    # point of the `(s)`. `require_ability` never stands alone: it is always the
    # second half of a `require_user_or_pat |> require_ability(ab)` pipe, so it
    # carries the same credential kind. The ABILITY is documented in the row's
    # description column; the tier column names the credential.
    "require_user_or_pat" => "user(s)",
    "require_ability" => "user(s)",

    # SESSION OR PAT OR THE WORKER TOKEN — the disjunction that lets the
    # principal which WRITES the platform delivery record read it back
    # (task-e2acb66e9ed0da09). It is NOT `require_user_or_pat` with a footnote:
    # the worker is faceless (no current_user / no current_team) and clamped to
    # `["read"]`, so this key must map to its own tier or the route table would
    # advertise a human-only read on a route a machine reaches.
    "require_user_or_pat_or_worker" => "user(s)+worker",
    "require_team_role" => "user",
    "require_team_admin" => "admin",
    "require_current_team_admin" => "admin",
    "require_current_team_owner" => "owner",
    "require_platform_operator" => "operator",
    "require_worker" => "worker",
    "require_agent" => "agent",
    "with_team_role:member" => "user",
    "with_team_role:admin" => "admin",
    "with_team_role:owner" => "owner",

    # POST-GUARD ELEVATIONS. Seven routes call a permissive `Auth.require_*` and
    # then refuse a plain member from a `cond` BELOW it (see `elevate/2`). The
    # outer guard is not the tier those routes enforce, so the composed key —
    # base guard + the elevation the body performs — is what gets mapped here.
    "require_user+forbidden:admin" => "admin",
    "require_user_or_pat+ability:deploy+forbidden:admin" => "admin(d)",

    # THE CONJUNCTION, and it is a DIFFERENT tier from the disjunction above.
    # GET /v1/barkparks/:id/credentials (cloud-agent onramp) accepts either
    # credential kind, but it enforces the team-admin ROLE on both AND requires
    # `root` of a PAT — it hands back the plaintext instance admin token. So
    # every caller that reaches it IS a team admin, and the honest tier column
    # is a plain `admin`: `admin(d)` would advertise the deploy-PAT bargain
    # ("no role needed") on a route that grants no such thing.
    "require_user_or_pat+ability:root+forbidden:admin" => "admin"
  }

  @decl_re ~r/^\s*(get|post|put|patch|delete)[\s(]+"([^"]+)"/
  @def_re ~r/^\s*defp?\s+(\w+)\(/
  @block_end_re ~r/^  end\s*$/
  # `post("/v1/launch", do: go_live(conn))` — a one-line body, no `end` of its own.
  @inline_body_re ~r/\bdo:/

  @doc "The router source path this lens defaults to."
  @spec default_source_path() :: binary()
  def default_source_path, do: @default_source

  @doc "The guard-key -> tier map. A key absent from it is UNMAPPED, never a pass."
  @spec guard_tier() :: %{binary() => binary()}
  def guard_tier, do: @guard_tier

  @doc "The tier vocabulary the route table is allowed to use."
  @spec tier_tokens() :: [binary()]
  def tier_tokens, do: @tier_tokens

  @doc """
  The router source text.

  A missing file is a NAMED refusal, never an empty string: an empty source
  resolves every route to `nil`, which a caller could read as "no route is
  operator-gated" — the exact vacuous green this lens exists to make impossible.
  """
  @spec source(binary()) :: binary()
  def source(path \\ @default_source) do
    unless File.regular?(path) do
      raise ArgumentError,
            "RouterTierLens: router source not found at #{path}. The router moved or " <>
              "was renamed; re-point @default_source. Refusing to resolve tiers from a " <>
              "source that does not exist."
    end

    File.read!(path)
  end

  @doc """
  ONE pass over the source, sliced into `{routes, defs}`: route bodies keyed by
  `{METHOD, path}`, and function bodies keyed by name (the helpers a route body
  delegates its gate to). Cached per test process.
  """
  @spec blocks(binary()) :: {map(), map()}
  def blocks(path \\ @default_source) do
    case Process.get({:router_tier_lens_blocks, path}) do
      nil ->
        result =
          path
          |> source()
          |> String.split("\n")
          |> Enum.reduce({nil, [], %{}, %{}}, &scan_line/2)
          |> then(fn {_open, _acc, routes, defs} -> {routes, defs} end)

        Process.put({:router_tier_lens_blocks, path}, result)
        result

      cached ->
        cached
    end
  end

  @doc "Every `{METHOD, path}` the router declares."
  @spec route_keys(binary()) :: [{binary(), binary()}]
  def route_keys(path \\ @default_source) do
    {routes, _defs} = blocks(path)
    Map.keys(routes)
  end

  defp scan_line(line, {open, acc, routes, defs}) do
    cond do
      open != nil and Regex.match?(@block_end_re, line) ->
        {routes, defs} = close_block(open, Enum.reverse([line | acc]), routes, defs)
        {nil, [], routes, defs}

      open != nil ->
        {open, [line | acc], routes, defs}

      match = Regex.run(@decl_re, line) ->
        [_, verb, path] = match
        open_block({:route, {String.upcase(verb), path}}, line, routes, defs)

      match = Regex.run(@def_re, line) ->
        [_, name] = match
        open_block({:def, name}, line, routes, defs)

      true ->
        {nil, [], routes, defs}
    end
  end

  # A one-line `..., do: expr` block closes immediately; anything else stays open
  # until the module-level `  end` that closes it.
  defp open_block(key, line, routes, defs) do
    if Regex.match?(@inline_body_re, line) do
      {routes, defs} = close_block(key, [line], routes, defs)
      {nil, [], routes, defs}
    else
      {key, [line], routes, defs}
    end
  end

  defp close_block({:route, key}, lines, routes, defs),
    do: {Map.put_new(routes, key, Enum.join(lines, "\n")), defs}

  # EVERY clause of a multi-clause helper is kept, in source order, and each one
  # stays WHOLE: a `defp with_team_site(conn, nil, _fun), do: …` head must not
  # shadow the clause that carries the gate (that would drop every delegating
  # route out of the census) — but the clauses must not be BLENDED into one blob
  # either. The blend is how `with_team_site/3`'s `:session` branch answered for
  # its `{:ability, ab}` callers: joined, the textually-first `Auth.require_*`
  # wins for everyone, and eleven /v1/sites routes censused as one tier no
  # matter which credential mode they actually passed.
  defp close_block({:def, name}, lines, routes, defs),
    do:
      {routes,
       Map.update(defs, name, [Enum.join(lines, "\n")], &(&1 ++ [Enum.join(lines, "\n")]))}

  @doc """
  The guard a route body literally composes, elevations included — or `nil` when
  the route does not exist or no idiom resolves.
  """
  @spec raw_route_guard(binary(), binary(), binary()) :: binary() | nil
  def raw_route_guard(method, path, source_path \\ @default_source) do
    {routes, defs} = blocks(source_path)

    case Map.fetch(routes, {method, path}) do
      {:ok, body} -> guard_in(body, defs, 0)
      :error -> nil
    end
  end

  @doc "A composed guard key stripped back to its base guard (`a+b` -> `a`)."
  @spec base_guard(binary() | nil) :: binary() | nil
  def base_guard(nil), do: nil
  def base_guard(guard), do: guard |> String.split("+") |> hd()

  # `with_team_site(conn, {:ability, "write"}, fn conn, site ->` — the delegated
  # helper's name, then everything the call says AFTER `conn`. The tail is what
  # makes a delegation resolvable per call site rather than per helper.
  @delegate_re ~r/(?<![\w.])(\w+)\(conn\b([^\n]*)/

  # A `case` branch head that patterns on a mode: `:session ->`, `{:ability, ab} ->`.
  @mode_branch_re ~r/^\s*(:\w+|\{:\w+[^}]*\})\s*->/

  @doc """
  The guard key a body composes, walking the four idioms (see the moduledoc).
  `defs` are the helper CLAUSE LISTS a route may delegate to; `depth` bounds the
  walk. A delegation resolves PER CALL SITE — see `mode_of/1` and `delegate/5`.
  """
  @spec guard_in(binary(), map(), non_neg_integer()) :: binary() | nil
  def guard_in(body, defs, depth) do
    # A guard is a CALL, never a MENTION — the same doctrine the refusal lens
    # already states. `PATCH /v1/sites/:id` carries the prose "the same way
    # `Auth.require_ability/2` does" in a comment above its `cond`, and reading
    # that sentence as its gate resolved the route off documentation, one edit
    # away from answering for the whole family. Full-line comments go first.
    body = uncommented(body)

    cond do
      match = Regex.run(~r/Auth\.(require_\w+)/, body) ->
        elevate(Enum.at(match, 1), body)

      match = Regex.run(~r/with_team_role\(conn,\s*"(\w+)"/, body) ->
        "with_team_role:" <> Enum.at(match, 1)

      depth < 2 ->
        @delegate_re
        |> Regex.scan(body)
        |> Enum.find_value(fn [_, name, rest] ->
          case Map.fetch(defs, name) do
            {:ok, clauses} -> delegate(name, clauses, defs, depth + 1, mode_of(rest))
            :error -> nil
          end
        end)

      true ->
        nil
    end
  end

  # ── Per-call-site delegation ───────────────────────────────────────────────
  #
  # A helper whose gate is a `case` on one of its own arguments carries ONE
  # `Auth.require_*` per branch, and which branch runs is decided by the CALLER,
  # never by source order. `with_team_site/3` is the live instance:
  #
  #     defp with_team_site(conn, fun), do: with_team_site(conn, :session, fun)
  #     defp with_team_site(conn, auth, fun) do
  #       conn =
  #         case auth do
  #           :session -> Auth.require_user(conn, [])
  #           {:ability, ab} -> conn |> Auth.require_user_or_pat([]) |> Auth.require_ability(ab)
  #         end
  #
  # Read first-hit-wins, that hands `require_user` to all ELEVEN delegating
  # /v1/sites routes — including the six that a PAT carrying the right ability
  # reaches, which is precisely the distinction the route table exists to state.
  # So the literal at the call site selects the branch, and a call naming no mode
  # is resolved through the helper's own default-filling clause — `:session`,
  # read out of the source, never assumed.

  @doc """
  The mode a call site passes to a delegated helper, read off the call tail:
  `{:tuple, "ability"}`, `{:tag, "session"}`, or `:default` when it named none.
  """
  @spec mode_of(binary()) :: {:tag, binary()} | {:tuple, binary()} | :default
  def mode_of(rest) do
    cond do
      m = Regex.run(~r/^\s*,\s*\{:(\w+)\b/, rest) -> {:tuple, Enum.at(m, 1)}
      m = Regex.run(~r/^\s*,\s*:(\w+)\b/, rest) -> {:tag, Enum.at(m, 1)}
      true -> :default
    end
  end

  # The clauses a call in `mode` can actually reach, each narrowed to the branch
  # that mode selects. When the helper branches on a mode and NONE of its
  # branches matches, the answer is `[]` — an honest refusal that surfaces as
  # `no_guard_found`, never a neighbouring branch's guard lent to a caller who
  # could not have reached it.
  defp delegate(name, clauses, defs, depth, mode) do
    mode = if mode == :default, do: default_mode(name, clauses), else: mode

    reachable =
      case {mode, Enum.flat_map(clauses, &List.wrap(branch_of(&1, mode)))} do
        {:default, _} -> clauses
        {_, [_ | _] = branches} -> branches
        {_, []} -> if Enum.any?(clauses, &branching?/1), do: [], else: clauses
      end

    Enum.find_value(reachable, &guard_in(&1, defs, depth))
  end

  # The mode a call that named none actually gets, read from the helper's own
  # default-filling clause — `with_team_site(conn, fun), do: with_team_site(conn,
  # :session, fun)` says `:session` in bytes, so nothing here has to assume it.
  defp default_mode(name, clauses) do
    self_call = ~r/#{Regex.escape(name)}\(conn\b([^\n]*)/

    clauses
    |> Enum.find_value(fn clause ->
      case Regex.run(self_call, uncommented(clause)) do
        [_, rest] ->
          case mode_of(rest) do
            :default -> nil
            mode -> mode
          end

        nil ->
          nil
      end
    end)
    |> Kernel.||(:default)
  end

  defp branching?(clause),
    do: clause |> String.split("\n") |> Enum.any?(&Regex.match?(@mode_branch_re, &1))

  # The `case` branch `mode` selects, as text: the branch head plus every line
  # indented under it. `nil` when this clause carries no branch for that mode.
  defp branch_of(clause, mode) do
    lines = String.split(clause, "\n")

    case Enum.find_index(lines, &branch_head?(&1, mode)) do
      nil -> nil
      i -> take_branch(lines, i)
    end
  end

  defp branch_head?(line, {:tag, name}), do: Regex.match?(~r/^\s*:#{name}\s*->/, line)

  defp branch_head?(line, {:tuple, name}),
    do: Regex.match?(~r/^\s*\{:#{name}\b[^}]*\}\s*->/, line)

  defp branch_head?(_line, :default), do: false

  defp take_branch(lines, i) do
    head = Enum.at(lines, i)
    indent = indent_of(head)

    rest =
      lines
      |> Enum.drop(i + 1)
      |> Enum.take_while(fn l -> String.trim(l) == "" or indent_of(l) > indent end)

    Enum.join([head | rest], "\n")
  end

  defp indent_of(line), do: byte_size(line) - byte_size(String.trim_leading(line))

  # FULL-LINE comments only. A trailing `#` cannot be stripped safely from Elixir
  # source (`"#{x}"`, the literal `"#"`), and a half-right stripper is worse than
  # none: it would silently eat the guard it was meant to preserve.
  defp uncommented(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.join("\n")
  end

  # ── The refusal lens ───────────────────────────────────────────────────────
  #
  # `guard_in/3` returns the FIRST `Auth.require_*` hit and stops, which is right
  # for the ~155 routes whose gate IS that call — and wrong for the handful whose
  # gate continues in a `cond` BELOW it. POST /v1/resurrect calls
  # `Auth.require_user` and then 403s any non-team-admin two branches later; read
  # by the outer guard alone it censuses as `user`. (The example here used to be
  # POST /v1/env-vars, deleted with the team env-var feature — cch-w53-bl,
  # Option A, 2026-09-02.)
  #
  # THE SIGNAL IS A REFUSAL, NOT A MENTION: `GET /v1/notifications/deliveries`
  # calls `Accounts.team_admin?/2` too, but the boolean SCOPES a query — it
  # narrows what you see, it never refuses you. So the lens keys on an
  # `Auth.forbidden/2` carrying a `required:` tier, which is only ever emitted
  # from a branch that halts with a 403.
  #
  # `+ability:deploy` is load-bearing: the `require_user_or_pat` routes are a
  # DISJUNCTION — a PAT needs only the `deploy` ability, a session needs
  # team-admin — so they resolve to `admin(d)`, never to `admin`.
  defp elevate(base, body) do
    case Regex.run(~r/Auth\.forbidden\(conn,\s*required:\s*"(\w+)"/, body) do
      [_, required] -> base <> ability_suffix(body) <> "+forbidden:" <> required
      nil -> base
    end
  end

  defp ability_suffix(body) do
    case Regex.run(~r/Auth\.require_ability\(conn,\s*"(\w+)"\)/, body) do
      [_, ability] -> "+ability:" <> ability
      nil -> ""
    end
  end

  @doc "`user*` is a footnoted `user`; `user(s)` and `admin(d)` are their own tiers."
  @spec normalize_tier(binary()) :: binary()
  def normalize_tier("user(s)"), do: "user(s)"
  # BEFORE the `"user" <> _` catch-all, which would otherwise flatten this to a
  # plain `user` and make the census compare `user` against `user(s)+worker`.
  def normalize_tier("user(s)+worker"), do: "user(s)+worker"
  def normalize_tier("user" <> _), do: "user"
  def normalize_tier(tier), do: tier

  @doc """
  The credential tier a route ENFORCES: `{:ok, tier}`, or an error naming why the
  lens will not answer — `{:error, :route_not_found}`, `{:error, :no_guard_found}`
  or `{:error, {:unmapped_guard, key}}`. Never a default tier.
  """
  @spec tier_of(binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, atom() | {atom(), binary()}}
  def tier_of(method, path, source_path \\ @default_source) do
    {routes, _defs} = blocks(source_path)

    cond do
      not Map.has_key?(routes, {method, path}) ->
        {:error, :route_not_found}

      guard = raw_route_guard(method, path, source_path) ->
        case Map.fetch(@guard_tier, guard) do
          {:ok, tier} -> {:ok, tier}
          :error -> {:error, {:unmapped_guard, guard}}
        end

      true ->
        {:error, :no_guard_found}
    end
  end
end
