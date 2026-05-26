defmodule Barkpark.ContentResolveReadDatasetMemoTest do
  @moduledoc """
  Per-request memoization of `resolve_read_dataset_id/2` (barkpark-5znv).

  A single public read fans `resolve_read_dataset_id` across `schema_public?` +
  `list_documents` + `schema_hash_for_dataset` (~9 calls) — all for the immutable
  `{project_id, dataset}` pair. Before the memo each call paid up to 3 DB
  roundtrips (`get_default_workspace` + `get_default_project` + `get_dataset`).
  The memo collapses the repeats to the first call within a process.

  These tests are NOT async: they attach a process-global :telemetry handler that
  counts tenancy-table reads, so they must own the Repo's telemetry stream for
  the duration.

  The guardrail proven elsewhere (content_dataset_id_authoritative_test,
  content_cross_project_dataset_scope_test) is that the RESOLVED id is correct.
  Here we prove it is the SAME id AND computed once.
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

  describe "default-project route (no :project_id in opts)" do
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
          for _ <- 1..9, do: Content.resolve_read_dataset_id("production", [])
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
      assert Content.resolve_read_dataset_id("production", []) == dataset_id

      # A second resolve in this same process must NOT hit the DB.
      {_id, warm_reads} =
        count_tenancy_reads(fn -> Content.resolve_read_dataset_id("production", []) end)

      assert warm_reads == 0, "a warmed memo must not re-query within the same process"

      # A DIFFERENT process shares no Process dictionary, so it recomputes —
      # this is exactly what keeps the memo from going stale across requests /
      # ecto.reset test DBs (no global cache). Run inside the same sandboxed
      # connection so the seeded rows are visible.
      parent = self()

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Barkpark.Repo, parent, self())
          count_tenancy_reads(fn -> Content.resolve_read_dataset_id("production", []) end)
        end)

      {fresh_id, fresh_reads} = Task.await(task)

      assert fresh_id == dataset_id, "a fresh process resolves the same correct id"

      assert fresh_reads > 0,
             "a fresh process must recompute (proves the memo is per-process, not a global cache)"
    end
  end

  describe "explicit :project_id route" do
    test "repeated resolves with an explicit project_id hit get_dataset once" do
      ws = create_workspace!()
      proj = create_project!(ws)
      {:ok, ds} = Tenancy.get_or_create_dataset(proj, "production")
      scope = [workspace_id: ws.id, project_id: proj.id]

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
end
