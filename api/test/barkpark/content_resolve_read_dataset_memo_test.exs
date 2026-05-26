defmodule Barkpark.ContentResolveReadDatasetMemoTest do
  @moduledoc """
  Per-request memoization of `resolve_read_dataset_id/2` (barkpark-5znv),
  gated to opt-in callers (barkpark-sknf).

  A single public HTTP read fans `resolve_read_dataset_id` across
  `schema_public?` + `list_documents` + `schema_hash_for_dataset` (~9 calls)
  — all for the immutable `{project_id, dataset}` pair. Before the memo each
  call paid up to 3 DB roundtrips (`get_default_workspace` +
  `get_default_project` + `get_dataset`). The memo collapses the repeats to
  the first call within a process.

  The 5znv memo originally fired on every caller — fine for one-process
  Phoenix requests, but a LiveView pid lives for the whole session and an
  Oban worker pid is reused across jobs, so a memoized `dataset_id` could
  outlive the underlying dataset row (e.g. via workspace cascade-delete) and
  pin reads to a deleted id forever. sknf gates the memo behind an explicit
  `memoize: true` opt that ONLY HTTP request controllers pass via
  `ScopeHelpers.scope_opts(conn)`. LV / worker / mix-task / retriever callers
  resolve fresh every time.

  These tests are NOT async: they attach a process-global :telemetry handler that
  counts tenancy-table reads, so they must own the Repo's telemetry stream for
  the duration.

  The guardrail proven elsewhere (content_dataset_id_authoritative_test,
  content_cross_project_dataset_scope_test) is that the RESOLVED id is correct.
  Here we prove it is the SAME id AND (with `memoize: true`) computed once.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Tenancy}

  # Default Ecto telemetry event for a repo with `otp_app: :barkpark`.
  @repo_query_event [:barkpark, :repo, :query]
  @tenancy_sources ~w(workspaces projects datasets)

  # Count, within `fun`, the number of Repo queries that touch a tenancy table
  # (workspaces / projects / datasets). One process owns the counter via an
  # Agent; the telemetry handler only counts queries fired from THIS test pid.
  defp count_tenancy_reads(fun) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      @repo_query_event,
      fn _event, _measurements, %{source: source}, _config ->
        if self() == test_pid and source in @tenancy_sources do
          Agent.update(counter, &(&1 + 1))
        end
      end,
      nil
    )

    try do
      result = fun.()
      {result, Agent.get(counter, & &1)}
    after
      :telemetry.detach(handler_id)
      Agent.stop(counter)
    end
  end

  describe "request path (memoize: true) — default-project route" do
    setup do
      # DataCase.ensure_default_tenancy/0 already seeds the Default
      # workspace/project; add a resolvable dataset so the resolve returns a
      # non-nil id (exercises the full get_default_project + get_dataset chain
      # that the memo collapses).
      {_ws, proj} = ensure_default_scope!()
      {:ok, ds} = Tenancy.get_or_create_dataset(proj, "production")
      {:ok, dataset_id: ds.id}
    end

    test "repeated resolves within one process return the SAME id and hit the DB once",
         %{dataset_id: dataset_id} do
      {ids, reads} =
        count_tenancy_reads(fn ->
          for _ <- 1..9,
              do: Content.resolve_read_dataset_id("production", memoize: true)
        end)

      # Correctness: every call resolves to the SAME, correct dataset_id.
      assert Enum.uniq(ids) == [dataset_id],
             "memoized resolve must return the same dataset_id every call"

      # Memoization: the 3-roundtrip chain (get_default_workspace +
      # get_default_project + get_dataset) runs at most once, not 9x.
      assert reads <= 3,
             "expected the default-project resolve chain to run at most once " <>
               "(<=3 tenancy reads) across 9 calls, got #{reads}"
    end

    test "a fresh process recomputes (the memo is per-process, not global)",
         %{dataset_id: dataset_id} do
      # First call in THIS process warms the memo.
      assert Content.resolve_read_dataset_id("production", memoize: true) == dataset_id

      # A second resolve in this same process must NOT hit the DB.
      {_id, warm_reads} =
        count_tenancy_reads(fn ->
          Content.resolve_read_dataset_id("production", memoize: true)
        end)

      assert warm_reads == 0, "a warmed memo must not re-query within the same process"

      # A DIFFERENT process shares no Process dictionary, so it recomputes —
      # this is exactly what keeps the memo from going stale across requests /
      # ecto.reset test DBs (no global cache). Run inside the same sandboxed
      # connection so the seeded rows are visible.
      parent = self()

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Barkpark.Repo, parent, self())

          count_tenancy_reads(fn ->
            Content.resolve_read_dataset_id("production", memoize: true)
          end)
        end)

      {fresh_id, fresh_reads} = Task.await(task)

      assert fresh_id == dataset_id, "a fresh process resolves the same correct id"

      assert fresh_reads > 0,
             "a fresh process must recompute (proves the memo is per-process, not a global cache)"
    end
  end

  describe "request path (memoize: true) — explicit :project_id route" do
    test "repeated resolves with an explicit project_id hit get_dataset once" do
      ws = create_workspace!()
      proj = create_project!(ws)
      {:ok, ds} = Tenancy.get_or_create_dataset(proj, "production")
      scope = [workspace_id: ws.id, project_id: proj.id, memoize: true]

      {ids, reads} =
        count_tenancy_reads(fn ->
          for _ <- 1..9, do: Content.resolve_read_dataset_id("production", scope)
        end)

      assert Enum.uniq(ids) == [ds.id]

      # With an explicit project_id there is no default-project lookup; only the
      # single get_dataset roundtrip, memoized to one.
      assert reads <= 1,
             "explicit-project resolve must memoize get_dataset to one read, got #{reads}"
    end
  end

  describe "LV/worker path (no memoize opt) — sknf staleness gate" do
    setup do
      {_ws, proj} = ensure_default_scope!()
      {:ok, ds} = Tenancy.get_or_create_dataset(proj, "production")
      {:ok, project: proj, dataset: ds}
    end

    test "every resolve fetches fresh — no memo write on the no-opt path",
         %{dataset: ds} do
      # 9 resolves without `memoize: true` (the LV / Oban / mix-task shape):
      # each call MUST hit the DB. We don't pin an exact count (3 reads * 9 calls
      # = 27 in the default-project route), but it MUST be strictly more than
      # the memoized ceiling (3) — proving no cross-call caching.
      {ids, reads} =
        count_tenancy_reads(fn ->
          for _ <- 1..9, do: Content.resolve_read_dataset_id("production", [])
        end)

      assert Enum.uniq(ids) == [ds.id]

      assert reads > 3,
             "no-memoize path must NOT collapse reads to the memoized ceiling " <>
               "(got #{reads}; memoized would be <=3)"
    end

    test "a pre-seeded Process dict entry from a prior call is NOT consulted",
         %{dataset: ds} do
      # Simulate the staleness scenario: an earlier `memoize: true` call (or a
      # rogue cache write) put a bogus id in the Process dict under the same
      # memo key. A subsequent no-memoize call MUST ignore that entry and
      # resolve fresh from the DB.
      stale_id = "00000000-0000-0000-0000-000000000000"

      Process.put(
        {:barkpark_request_memo, {:resolve_read_dataset_id, nil, "production"}},
        stale_id
      )

      # No memoize opt → must NOT consult the cached value.
      assert Content.resolve_read_dataset_id("production", []) == ds.id,
             "no-memoize path must not read the Process dict cache"
    end

    test "staleness proof: cached id stays uncached; row change is reflected next call",
         %{project: proj, dataset: ds} do
      # The deletion+recreate-with-new-id scenario, condensed to its essence:
      # call once on the no-memoize path, then mutate the row, then call again.
      # If the memo were still firing, call #2 would return the call #1 id even
      # after the underlying row changed.
      assert Content.resolve_read_dataset_id("production", []) == ds.id

      # Mutate the dataset id underneath the resolver by deleting + recreating.
      # `delete_all` + `get_or_create_dataset` gives us a NEW uuid for the same
      # ({project_id, dataset}) pair, mimicking a cascade-delete + workspace
      # recreate from the user's perspective.
      Barkpark.Repo.delete!(ds)
      {:ok, fresh_ds} = Tenancy.get_or_create_dataset(proj, "production")
      refute fresh_ds.id == ds.id, "test setup: expected a different uuid post-recreate"

      # The next no-memoize call MUST reflect the new row id. With the pre-sknf
      # memo this would have stuck on the old (now-deleted) id forever.
      assert Content.resolve_read_dataset_id("production", []) == fresh_ds.id,
             "no-memoize path must reflect the current DB on every call"
    end
  end

  describe "ScopeHelpers seam" do
    test "scope_opts(%Conn{}) opts in to memoization" do
      assigns = %{current_workspace: %{id: "ws-1"}, current_project: %{id: "p-1"}}
      conn = %Plug.Conn{assigns: assigns}
      opts = BarkparkWeb.ScopeHelpers.scope_opts(conn)
      assert Keyword.get(opts, :memoize) == true
      assert Keyword.get(opts, :workspace_id) == "ws-1"
      assert Keyword.get(opts, :project_id) == "p-1"
    end

    test "scope_opts(%Socket{}) does NOT opt in to memoization" do
      assigns = %{current_workspace: %{id: "ws-1"}, current_project: %{id: "p-1"}}
      socket = %Phoenix.LiveView.Socket{assigns: assigns}
      opts = BarkparkWeb.ScopeHelpers.scope_opts(socket)
      refute Keyword.has_key?(opts, :memoize),
             "LV socket must NOT carry :memoize — long-lived process, staleness risk"

      assert Keyword.get(opts, :workspace_id) == "ws-1"
      assert Keyword.get(opts, :project_id) == "p-1"
    end
  end
end
