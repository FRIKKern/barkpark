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

    * `Auth.require_*` in the route body;
    * `with_team_role(conn, "role")`;
    * a helper the body delegates the whole `conn` to (depth 2);
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

  # The tier vocabulary the route table uses. `user*` (ticket-or-Bearer) and
  # `user(s)` (session-or-PAT) are `user` with a footnote; `admin(d)` (session
  # team-admin OR a PAT carrying the `deploy` ability) is a tier of its OWN —
  # deliberately NOT folded into `admin` by normalize_tier/1, because a
  # deploy-PAT holder needs no role at all and telling them "admin" is its own lie.
  @tier_tokens ~w[user user* user(s) admin admin(d) owner worker operator agent]

  # Every guard idiom the router uses, mapped to the tier column it justifies. A
  # guard MISSING from this map is treated as UNRESOLVED, never as a pass — a new
  # guard therefore reds instead of quietly widening a census's blind spot.
  @guard_tier %{
    "require_user" => "user",
    "require_user_or_pat" => "user",
    "require_ability" => "user",
    "require_team_role" => "user",
    "require_team_admin" => "admin",
    "require_primary_team_admin" => "admin",
    "require_primary_team_owner" => "owner",
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
    "require_user_or_pat+ability:deploy+forbidden:admin" => "admin(d)"
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

  # ALL clauses of a multi-clause helper are joined, never just the first: a
  # `defp with_team_site(conn, nil, _fun), do: …` head would otherwise shadow the
  # clause that actually carries the gate, and every route delegating to it would
  # silently fall out of the census.
  defp close_block({:def, name}, lines, routes, defs),
    do:
      {routes,
       Map.update(defs, name, Enum.join(lines, "\n"), &(&1 <> "\n" <> Enum.join(lines, "\n")))}

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

  @doc """
  The guard key a body composes, walking the four idioms (see the moduledoc).
  `defs` are the helper bodies a route may delegate to; `depth` bounds the walk.
  """
  @spec guard_in(binary(), map(), non_neg_integer()) :: binary() | nil
  def guard_in(body, defs, depth) do
    cond do
      match = Regex.run(~r/Auth\.(require_\w+)/, body) ->
        elevate(Enum.at(match, 1), body)

      match = Regex.run(~r/with_team_role\(conn,\s*"(\w+)"/, body) ->
        "with_team_role:" <> Enum.at(match, 1)

      depth < 2 ->
        ~r/(?<![\w.])(\w+)\(conn\b/
        |> Regex.scan(body)
        |> Enum.find_value(fn [_, name] ->
          case Map.fetch(defs, name) do
            {:ok, helper_body} -> guard_in(helper_body, defs, depth + 1)
            :error -> nil
          end
        end)

      true ->
        nil
    end
  end

  # ── The refusal lens ───────────────────────────────────────────────────────
  #
  # `guard_in/3` returns the FIRST `Auth.require_*` hit and stops, which is right
  # for the ~155 routes whose gate IS that call — and wrong for seven whose gate
  # continues in a `cond` BELOW it. POST /v1/env-vars calls `Auth.require_user`
  # and then 403s any non-team-admin two branches later; read by the outer guard
  # alone it censuses as `user`.
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

  @doc "`user*` / `user(s)` are footnoted `user`; `admin(d)` is its own tier."
  @spec normalize_tier(binary()) :: binary()
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
