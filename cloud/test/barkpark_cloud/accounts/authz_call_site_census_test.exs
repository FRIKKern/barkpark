defmodule BarkparkCloud.Accounts.AuthzCallSiteCensusTest do
  @moduledoc """
  THE TRIPWIRE UNDER `Authz`'s CORRECTED MODULEDOC (pws-s7). The moduledoc used
  to say "`authorize/3` is the single entry point and is TOTAL … never raises".
  Both halves were false: `authorize/3` has zero callers in `cloud/lib`, and the
  entry points DID raise outside the resolved domain. The sentence is now three
  clauses — total over RESOLVED inputs, total at the CLAUSE level too (as of
  2026-09-13), and unreachable by three named guards anyway — and this file is
  what stops each clause from drifting back into a phantom.

    * ARM 1 — DOMAIN CENSUS (runtime, measured). Drives all five public entry
      points (`role/2`, `team_admin?/2`, `team_owner?/2`, `authorize/3`,
      `can_grant?/3`) over the hostile input set and asserts the MEASURED
      matrix: denial for resolved inputs, and — since `get_membership/2` was
      totalised through `Repo.uuid_or_nil/1` plus a catch-all — denial for the
      unresolved ones too (`""`, `"not-a-uuid"`, `nil`, on BOTH the team and the
      user side). It used to assert `Ecto.Query.CastError` / `FunctionClauseError`
      there, deliberately, so the fix could not land silently; it reddened
      exactly as designed and was flipped in the same change that totalised the
      clause. Mutation-proven: delete the `Map.get(@action_min, action, [])`
      default and the unknown-action cell reds; drop the catch-all or the
      `uuid_or_nil` guard on `get_membership/2` and the unresolved cells red.

    * ARM 2 — SOURCE CENSUS (static, the load-bearing arm). Every qualified
      `Authz.{role,team_admin?,team_owner?,can_grant?,authorize}` /
      `Accounts.{team_role,team_admin?,get_membership}` call site in `cloud/lib`
      must carry one of the guard forms the moduledoc names, or the census reds
      by file:line. This is the tripwire for the third clause: "no request path
      reaches that" is only true while every call site keeps its guard.

  WHAT ARM 2 CANNOT DO — read this before citing it. A static census proves
  LEXICAL PAIRING: that a recognised guard form sits in the same function, in
  binding or branch position, ahead of the call. It does NOT prove the guard
  FIRES, does not prove the branch is reachable, and does not prove totality.
  A `cond` whose `is_nil(current_team)` arm is dead code still classifies as
  guarded here. (Charter D68's warning, inherited verbatim: a source census is a
  drift alarm, never a proof of behaviour.) The behavioural proof of the third
  clause lives in the request-level tests — chiefly
  `test/barkpark_cloud/web/router_team_switcher_test.exs:72`, which loops
  `[foreign.id, "not-a-uuid", ""]` through the only attacker-controlled surface.

  MUTATION PROOF, recorded here because this file is the durable venue the merge
  carries (re-run either mutation to reproduce):

      ARM 1 — replace `Map.get(@action_min, action, [])` in `Authz.authorize/3`
        with `Map.fetch!(@action_min, action)` (i.e. delete the `, []` default).
        Observed, 2026-08-19, worktree off origin/main 2b8605d082:

          1) test ARM 1 — domain census authorize/3 denies unknown, string and
             nil actions (BarkparkCloud.Accounts.AuthzCallSiteCensusTest)
             ** (KeyError) key :nope not found in: %{read: ["owner", "admin",
                "member"], launch: ["owner", "admin"], …}
             (barkpark_cloud) lib/barkpark_cloud/accounts/authz.ex:134
          7 tests, 1 failure                        (green again on revert)

      ARM 2 — add ONE unguarded probe call site to `cloud/lib`: the line
        `_probe = Accounts.team_admin?(conn.assigns.current_user,
        conn.params["team"])` at the top of `get "/v1/templates"` in
        `router.ex`, a route with no `is_nil(current_team)` branch. Observed,
        same tree:

          1) test ARM 2 — source census every membership call site in cloud/lib
             carries a guard (BarkparkCloud.Accounts.AuthzCallSiteCensusTest)
             UNGUARDED membership call site(s):
               lib/barkpark_cloud/web/router.ex:1184  team_admin?  team arg:
                 conn.params["team"]
          7 tests, 1 failure                        (green again on revert)
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.Authz

  ## ---------------------------------------------------------------- fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "pws7-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "pws7-team-#{n}"})
    team
  end

  ## ------------------------------------------------------------------ ARM 1

  describe "ARM 1 — domain census" do
    test "resolved inputs are TOTAL across all five entry points" do
      user = user_fixture()
      team = team_fixture()
      stranger = user_fixture()
      {:ok, _} = Accounts.add_member(team, user, "member")

      # A team the actor holds no grant in, expressed as a struct AND as a uuid
      # string — both are "resolved" shapes per the moduledoc's first clause.
      for t <- [team, team.id], actor <- [stranger, stranger.id] do
        assert Authz.role(actor, t) == nil
        refute Authz.team_admin?(actor, t)
        refute Authz.team_owner?(actor, t)
        assert Authz.authorize(actor, t, :read) == {:error, :forbidden}
        assert Authz.can_grant?(actor, t, "member") == {:error, :forbidden}
      end

      # A member is denied everything above their grant, never raised at.
      for action <- [:launch, :delete_barkpark, :connect_provider, :manage_members] do
        assert Authz.authorize(user, team, action) == {:error, :forbidden}
      end

      assert Authz.authorize(user, team, :read) == :ok
    end

    test "authorize/3 denies unknown, string and nil actions" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "owner")

      # MUTATION CELL: drop the `, []` default in Map.get(@action_min, action, [])
      # and this line reds with a KeyError instead of a denial.
      for action <- [:nope, :Read, "read", nil, 7, {:read, :write}] do
        assert Authz.authorize(user, team, action) == {:error, :forbidden},
               "an owner must still be DENIED the unrecognised action #{inspect(action)}"
      end
    end

    test "UNRESOLVED inputs are DENIED, never raised at — the totalised clause, measured" do
      user = user_fixture()

      # Every entry point funnels into Accounts.get_membership/2, which now
      # cast-guards its binary clause through Repo.uuid_or_nil/1 and carries a
      # catch-all, so the whole declared @spec domain lands on "no membership".
      #
      # IF THIS TEST REDS: someone de-totalised get_membership/2 (or dropped its
      # catch-all / cast guard). Do NOT delete these assertions and do NOT
      # narrow them back to a raise without rewriting Authz's moduledoc SECOND
      # clause in the same change — that clause and this arm move together.
      unresolved = [
        {"empty string team", ""},
        {"malformed team", "not-a-uuid"},
        {"nil team", nil}
      ]

      entry_points = [
        {"role/2", fn user, team -> Authz.role(user, team) end, nil},
        {"team_admin?/2", fn user, team -> Authz.team_admin?(user, team) end, false},
        {"team_owner?/2", fn user, team -> Authz.team_owner?(user, team) end, false},
        {"authorize/3", fn user, team -> Authz.authorize(user, team, :read) end,
         {:error, :forbidden}},
        {"can_grant?/3", fn user, team -> Authz.can_grant?(user, team, "member") end,
         {:error, :forbidden}}
      ]

      for {label, team} <- unresolved, {name, call, expected} <- entry_points do
        got =
          try do
            {:returned, call.(user, team)}
          rescue
            e -> {:raised, e}
          end

        assert got == {:returned, expected},
               "#{name} must DENY #{label} with #{inspect(expected)}, got #{inspect(got)}"
      end

      # The same totality on the USER side of the seam — the other half of the
      # declared @spec domain, and the half nothing pinned before.
      team = team_fixture()

      for bad_user <- ["", "not-a-uuid", nil] do
        assert Accounts.get_membership(team, bad_user) == nil,
               "get_membership/2 must return nil for user #{inspect(bad_user)}"
      end
    end

    test "@type team still admits bare binaries — the domain the clause now covers" do
      # This pin used to record a CONTRADICTION (`""` is a binary and it raised).
      # get_membership/2 is now total over the declared domain, so the type and
      # the behaviour agree; the pin stays because the arm above is only a
      # totality claim as long as the type keeps admitting bare binaries. Narrow
      # the typespec and the arm above silently stops proving anything.
      {:ok, specs} = Code.Typespec.fetch_types(Authz)

      team_type =
        Enum.find_value(specs, fn
          {:type, {:team, _, _} = t} -> t
          _ -> nil
        end)

      assert team_type, "Authz must keep declaring @type team"
      rendered = team_type |> Code.Typespec.type_to_quoted() |> Macro.to_string()
      assert rendered =~ "binary()", "@type team still admits bare binaries: #{rendered}"
    end
  end

  ## ------------------------------------------------------------------ ARM 2

  # The membership seam: every qualified call that reads a grant.
  @call_regex ~r/\b(Authz|Accounts)\.(role|team_admin\?|team_owner\?|can_grant\?|authorize|team_role|get_membership)\(/

  # Functions that hand back a REAL Team (or nil), i.e. that launder an id
  # before it can reach get_membership/2. Binding a variable from one of these
  # is guard form (3) / the resolve_team lane in Authz's moduledoc.
  @resolvers ~w(get_team primary_team list_user_teams current_team_scoped with_team_role with_team_site)

  # The ONLY sanctioned unguarded shapes: functions whose `team` parameter is
  # the CALLER's problem — a library forwarder, never a request path. Pinned
  # EXACTLY, because each one is a mouth of the raising domain the moduledoc
  # describes; a new forwarder is a new hole and must red here first.
  #
  #   * `Authz.role/2` is the funnel itself — the single point through which
  #     every entry point reaches `Accounts.get_membership/2`, and precisely
  #     what makes the seam "latently non-total at the clause level".
  #   * `Accounts.add_member_as/4` and `create_personal_access_token/3` are
  #     public context functions with an untyped `team` param; both are reached
  #     from request paths only through guarded call sites censused above.
  @forwarders [
    {"lib/barkpark_cloud/accounts/authz.ex", "role", "team"},
    {"lib/barkpark_cloud/accounts.ex", "add_member_as", "team"},
    {"lib/barkpark_cloud/accounts.ex", "create_personal_access_token", "team"}
  ]

  # Index of the team argument, per called function.
  @team_arg_index %{
    "role" => 1,
    "team_admin?" => 1,
    "team_owner?" => 1,
    "can_grant?" => 1,
    "authorize" => 1,
    "team_role" => 1,
    "get_membership" => 0
  }

  describe "ARM 2 — source census" do
    test "every membership call site in cloud/lib carries a guard" do
      sites = census()

      assert length(sites) > 10,
             "the census found #{length(sites)} call sites — the regex or the tree moved"

      unguarded = Enum.filter(sites, &(&1.guard == :unguarded))

      assert unguarded == [],
             "UNGUARDED membership call site(s):\n" <>
               Enum.map_join(unguarded, "\n", fn s ->
                 "  #{s.file}:#{s.line}  #{s.fun}  team arg: #{s.arg}"
               end) <>
               "\n\nEvery such call must pass a %Team{}-bound expression, sit under an " <>
               "is_nil(current_team) branch or a `team &&` short-circuit, or bind its team " <>
               "from one of #{inspect(@resolvers)}. See Authz's moduledoc."
    end

    test "the library-forwarder allowlist is exactly the pinned set" do
      found =
        census()
        |> Enum.filter(&(&1.guard == :library_forwarder))
        |> Enum.map(&{&1.file, &1.enclosing, &1.arg})
        |> Enum.uniq()
        |> Enum.sort()

      assert found == Enum.sort(@forwarders),
             "the set of UNGUARDED-BY-DESIGN forwarders moved.\n" <>
               "  found:  #{inspect(found)}\n  pinned: #{inspect(@forwarders)}\n" <>
               "A new forwarder widens the raising domain of the whole seam — guard it, " <>
               "or pin it here with a reason."
    end

    test "the census can see a call site at all (the instrument is not vacuous)" do
      sites = census()

      # A same-file pin of OUR OWN instrument, not a claim about foreign code:
      # if the extractor silently stops matching, these disappear and the
      # zero-unguarded assertion above passes for the wrong reason.
      assert Enum.any?(sites, &(&1.fun == "get_membership")),
             "no get_membership/2 call site found — the extractor is broken"

      assert Enum.any?(sites, &(&1.guard == :nil_checked)),
             "no is_nil(current_team)-guarded call site found — the classifier is broken"

      assert Enum.any?(sites, &(&1.guard == :team_struct_head)),
             "no %Team{}-head-guarded call site found — the classifier is broken"
    end
  end

  ## ------------------------------------------------------------ the extractor

  defp census do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&sites_in/1)
  end

  defp sites_in(file) do
    lines = file |> File.read!() |> String.split("\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, idx} ->
      case Regex.run(@call_regex, line, return: :index) do
        nil ->
          []

        [{start, len}, _mod, {fstart, flen}] ->
          [site(file, lines, line, idx, start + len, fstart, flen)]
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp site(file, lines, line, idx, paren_at, fstart, flen) do
    fun = binary_part(line, fstart, flen)
    args = line |> String.slice(paren_at..-1//1) |> split_args()
    arg = Enum.at(args, Map.fetch!(@team_arg_index, fun))

    if is_nil(arg) or arg == "" do
      nil
    else
      block = enclosing_block(lines, idx)
      enclosing = enclosing_name(block)

      %{
        file: file,
        line: idx,
        fun: fun,
        arg: arg,
        enclosing: enclosing,
        guard: classify(file, block, enclosing, arg)
      }
    end
  end

  # `a, b, c)` → ["a", "b", "c"], respecting nesting and strings. The input
  # starts just past the opening paren.
  defp split_args(rest), do: split_args(rest, 0, false, "", [])

  defp split_args("", _depth, _instr, cur, acc), do: finish_args(cur, acc)

  defp split_args(<<c::utf8, rest::binary>>, depth, instr, cur, acc) do
    ch = <<c::utf8>>

    cond do
      instr and ch == "\"" -> split_args(rest, depth, false, cur <> ch, acc)
      instr -> split_args(rest, depth, true, cur <> ch, acc)
      ch == "\"" -> split_args(rest, depth, true, cur <> ch, acc)
      ch in ["(", "[", "{"] -> split_args(rest, depth + 1, false, cur <> ch, acc)
      ch in ["]", "}"] -> split_args(rest, depth - 1, false, cur <> ch, acc)
      ch == ")" and depth == 0 -> finish_args(cur, acc)
      ch == ")" -> split_args(rest, depth - 1, false, cur <> ch, acc)
      ch == "," and depth == 0 -> split_args(rest, depth, false, "", [cur | acc])
      true -> split_args(rest, depth, false, cur <> ch, acc)
    end
  end

  defp finish_args(cur, acc),
    do: [cur | acc] |> Enum.reverse() |> Enum.map(&String.trim/1)

  # The enclosing unit: nearest preceding `def`/`defp`, or a Plug.Router verb
  # macro (`post "/v1/…" do`), up to and including the call line.
  @unit_regex ~r/^\s*(def|defp)\s|^\s*(get|post|put|patch|delete|match)\s+["~:]/

  defp enclosing_block(lines, idx) do
    head =
      lines
      |> Enum.take(idx)
      |> Enum.with_index(1)
      |> Enum.filter(fn {l, _} -> Regex.match?(@unit_regex, l) end)
      |> List.last()

    start = if head, do: elem(head, 1), else: max(idx - 40, 1)
    Enum.slice(lines, (start - 1)..(idx - 1))
  end

  defp enclosing_name([head | _]) do
    case Regex.run(~r/^\s*defp?\s+([a-z_][a-zA-Z0-9_?!]*)/, head) do
      [_, name] -> name
      nil -> String.trim(head)
    end
  end

  defp enclosing_name([]), do: ""

  ## The guard forms, in the order the moduledoc lists them.
  defp classify(file, block, enclosing, arg) do
    var = base_var(arg)
    head = List.first(block) || ""
    body = Enum.join(block, "\n")
    effective = resolve_binding(body, var, arg)

    cond do
      String.starts_with?(arg, "%Team{") ->
        :team_struct_literal

      team_struct_head?(head, var) ->
        :team_struct_head

      String.contains?(effective, "current_team") and nil_checked?(body) ->
        :nil_checked

      String.contains?(effective, "current_team") and truthy_guarded?(body, var) ->
        :truthy_guarded

      resolver_bound?(body, var) ->
        :resolved_binding

      forwarder?(file, enclosing, arg) ->
        :library_forwarder

      true ->
        :unguarded
    end
  end

  # "team.id" → "team"; "conn.assigns.current_team" is kept whole.
  defp base_var(arg) do
    if String.contains?(arg, "current_team"),
      do: arg,
      else: arg |> String.split(".") |> List.first() |> String.trim()
  end

  # One level of local binding: `team = conn.assigns.current_team`.
  defp resolve_binding(body, var, arg) do
    case Regex.run(~r/^\s*#{Regex.escape(var)}\s*=\s*(.+)$/m, body) do
      [_, rhs] -> arg <> " " <> rhs
      nil -> arg
    end
  end

  defp team_struct_head?(head, var) do
    Regex.match?(~r/%Team\{[^}]*\}\s*=\s*#{Regex.escape(var)}\b/, head) or
      Regex.match?(~r/#{Regex.escape(var)}\s*=\s*%Team\{/, head)
  end

  defp nil_checked?(body), do: Regex.match?(~r/is_nil\(\s*conn\.assigns[^)]*current_team/, body)

  defp truthy_guarded?(body, var) do
    v = var |> String.split(".") |> List.first()
    Regex.match?(~r/\b#{Regex.escape(v)}\s*&&/, body)
  end

  # The var is bound — by `=`, `<-`, a `fn` head, or a case/with clause head —
  # in a block that resolves teams through one of @resolvers.
  defp resolver_bound?(body, var) do
    v = var |> String.split(".") |> List.first()

    resolves? = Enum.any?(@resolvers, &String.contains?(body, &1))

    bound? =
      Regex.match?(~r/\b#{Regex.escape(v)}\s*(=|<-)/, body) or
        Regex.match?(~r/fn[^)\n]*\b#{Regex.escape(v)}\b[^)\n]*->/, body) or
        Regex.match?(~r/^\s*#{Regex.escape(v)}\s*->/m, body)

    resolves? and bound?
  end

  defp forwarder?(file, enclosing, arg), do: {file, enclosing, arg} in @forwarders
end
