defmodule Barkpark.Tenancy.ListWorkspacesForTotalityTest do
  @moduledoc """
  TOTALITY of `Barkpark.Tenancy.list_workspaces_for/1` — the workspace
  enumeration behind the Studio scope switcher, the `/api/workspaces` index and
  the self-mint workspace resolve. It must DENY with the empty list on a
  malformed or absent principal id, never raise.

  Before the `Repo.uuid_or_nil/1` seam the bare-binary clause accepted ANY
  binary and reached the query, where the `:binary_id` comparison raised
  **`Ecto.Query.CastError`** (mapped to 400 by `phoenix_ecto`). Note the
  module: `Ecto.Query.CastError`, NOT `Ecto.CastError` — the latter fires ZERO
  times on this path, so a test asserting it would be vacuous.
  `Repo.uuid_or_nil/1`'s own docstring names the wrong one; the exception this
  file rescues is the one that actually fires.

  Each malformed row is its OWN test so it reds INDIVIDUALLY under mutation
  (restore `tenancy.ex` to origin/main, keep this file). The rows are NOT
  uniform in what they prove, and saying so is the point:

    * `"not-a-uuid"` / `""` as a bare binary, and `%ApiToken{id: "not-a-uuid"}`
      — REDs on pre-fix code. These are the real crashes.
    * `%ApiToken{id: nil}` — GREEN on pre-fix code too. Pre-fix it denied by
      luck of clause ORDER (it delegated to the raw-binary arity, missed the
      `is_binary` guard and fell to the terminal `[]`); post-fix it denies by
      RULE at the normalisation seam. Pinned as a REGRESSION row, labelled as
      one rather than counted as a catch.

  The CONTROL rows are green in BOTH runs — a matrix where every row reds is a
  blanket deny, not a totality proof.

  Slugs are namespaced + UUID-suffixed: every agent in this repo shares one
  test database, so a fixed slug collides and no assertion here counts rows it
  did not insert.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth
  alias Barkpark.Tenancy.Workspace

  defp unique_slug(prefix), do: prefix <> "-" <> (Ecto.UUID.generate() |> binary_part(0, 8))

  defp workspace(prefix) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: unique_slug(prefix), name: "LWF #{prefix}"})
    ws
  end

  defp user(prefix) do
    {:ok, u} =
      Accounts.register_user(%{
        email: prefix <> "-" <> Ecto.UUID.generate() <> "@example.com",
        password: "correct horse battery"
      })

    u
  end

  # A persisted token row, so its id is a real DB-generated UUID.
  defp token(ws) do
    {:ok, tok} =
      Barkpark.Auth.create_token(
        "lwf-" <> Ecto.UUID.generate(),
        "lwf token",
        "test",
        ["read"],
        ws.id
      )

    tok
  end

  # ---------------------------------------------------------------------------
  # MALFORMED — one row per test. The first three RED on origin/main.
  # ---------------------------------------------------------------------------

  describe "malformed principal ids DENY with [] instead of raising" do
    test "a bare non-UUID binary denies (pre-fix: Ecto.Query.CastError from the binary_id compare)" do
      assert Tenancy.list_workspaces_for("not-a-uuid") == []
    end

    test "a bare EMPTY STRING denies (it satisfied is_binary/1 and reached the query)" do
      assert Tenancy.list_workspaces_for("") == []
    end

    test "an %ApiToken{} carrying a non-UUID id denies (the struct arm delegated unguarded)" do
      assert Tenancy.list_workspaces_for(%ApiToken{id: "not-a-uuid"}) == []
    end

    test "a %User{} carrying a non-UUID id denies (the \"user\"-typed clause, same seam)" do
      assert Tenancy.list_workspaces_for(%Barkpark.Accounts.User{id: "not-a-uuid"}) == []
    end

    # REGRESSION PIN, not a catch: green before the seam too, by clause order.
    test "REGRESSION: an %ApiToken{id: nil} denies — now by rule, not by clause order" do
      assert Tenancy.list_workspaces_for(%ApiToken{id: nil}) == []
    end

    test "REGRESSION: a %User{id: nil} denies" do
      assert Tenancy.list_workspaces_for(%Barkpark.Accounts.User{id: nil}) == []
    end

    test "REGRESSION: nil denies" do
      assert Tenancy.list_workspaces_for(nil) == []
    end

    test "REGRESSION: a non-binary, non-principal term denies" do
      assert Tenancy.list_workspaces_for(42) == []
    end
  end

  # ---------------------------------------------------------------------------
  # CONTROLS — green in BOTH runs. Without these the matrix above is satisfied
  # by `def list_workspaces_for(_), do: []`.
  # ---------------------------------------------------------------------------

  describe "controls: a well-formed principal still resolves its real memberships" do
    # `Auth.create_token/5` mints the "api_token" membership in the same
    # transaction, so the token below already holds exactly one grant.
    test "a token member sees exactly its own workspace" do
      ws = workspace("ctl-tok")
      tok = token(ws)

      assert [%Workspace{id: id}] = Tenancy.list_workspaces_for(tok)
      assert id == ws.id
    end

    test "the same token id passed as a BARE binary resolves identically (api_token reading)" do
      ws = workspace("ctl-bare")
      tok = token(ws)

      assert Tenancy.list_workspaces_for(tok.id) |> Enum.map(& &1.id) == [ws.id]
    end

    test "a user member sees exactly its own workspace" do
      ws = workspace("ctl-usr")
      u = user("ctl-usr")
      {:ok, _} = Auth.create_membership(ws.id, u.id, "member", "user")

      assert Tenancy.list_workspaces_for(u) |> Enum.map(& &1.id) == [ws.id]
    end

    test "a well-formed UUID with NO membership row denies — the join, not the cast" do
      assert Tenancy.list_workspaces_for(Ecto.UUID.generate()) == []
    end

    test "kind isolation survives the shared query: an api_token grant is invisible to a %User{}" do
      ws_user = workspace("ctl-kind-u")
      ws_token = workspace("ctl-kind-t")
      u = user("ctl-kind")

      {:ok, _} = Auth.create_membership(ws_user.id, u.id, "member", "user")
      # The SAME principal_id, granted as an api_token elsewhere (no FK on
      # principal_id, so a coincidentally-shared id is representable).
      {:ok, _} = Auth.create_membership(ws_token.id, u.id, "owner", "api_token")

      ids = Tenancy.list_workspaces_for(u) |> Enum.map(& &1.id)
      assert ids == [ws_user.id]
      refute ws_token.id in ids
    end
  end

  # ---------------------------------------------------------------------------
  # SHAPE — the enumeration is ONE INNER JOIN, not a scan-and-filter.
  #
  # Every behavioural row above is ALSO satisfied by the shape the moved
  # function's doc forbids:
  #
  #     list_workspaces() |> Enum.filter(&Auth.member?(principal, &1.id))
  #
  # It returns the same list, so no assertion on the RESULT can see it. What
  # separates them is the number of queries: the INNER JOIN starts from the
  # membership rows and issues exactly ONE; the filter starts from EVERY
  # workspace and issues 1 + N (the fail-open shape — the tenant boundary
  # becomes the filter's correctness rather than the join's reachability).
  # Run-measured under the mutation: 1 -> 1 + (workspace count), and because
  # this suite's DB is shared, N is every workspace any agent has seeded.
  # ---------------------------------------------------------------------------

  describe "shape: the enumeration is a single INNER JOIN, not a workspace scan" do
    test "one repo query regardless of how many workspaces the principal is NOT in" do
      ws = workspace("shape-member")
      u = user("shape")
      {:ok, _} = Auth.create_membership(ws.id, u.id, "member", "user")

      # Non-member workspaces: the filter shape would read each one back and
      # ask member?/2 about it; the join never sees them at all.
      for i <- 1..3, do: workspace("shape-other-#{i}")

      {result, queries} = count_queries(fn -> Tenancy.list_workspaces_for(u) end)

      assert Enum.map(result, & &1.id) == [ws.id]

      assert queries == 1,
             "the enumeration issued #{queries} queries — it must be ONE INNER JOIN. " <>
               "More than one means it was rewritten as list_workspaces() |> " <>
               "Enum.filter(&member?/2): N+1, and FAIL-OPEN in shape."
    end
  end

  # Count [:barkpark, :repo, :query] emissions raised BY THIS PROCESS while
  # `fun` runs. Returns {result, query_count}. Self-pid filtered because this
  # suite is async and other tests share the repo.
  defp count_queries(fun) do
    test_pid = self()
    handler_id = {:lwf_query_counter, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == test_pid, do: send(test_pid, :repo_query)
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_query_count(0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_query_count(n) do
    receive do
      :repo_query -> drain_query_count(n + 1)
    after
      0 -> n
    end
  end
end
