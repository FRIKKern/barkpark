defmodule Barkpark.Papers.PublicPaperScopeTest do
  @moduledoc """
  P0 cross-workspace read-leak guard for the PUBLIC `/papers/:slug` surface
  (barkpark-w9dg).

  Papers are stamped `workspace_id` on write and slugs are PER-WORKSPACE (the
  Wave-2 uniqueness flip lifted the old global `(doc_id, type, dataset)` index
  to a per-workspace `(doc_id, type, dataset_id)` one). Before this fix,
  `BulldocsLive.mount` called the bare `Content.get_paper(slug)` which runs
  UNSCOPED — `scope_to_workspace(query, nil, …)` returns the query untouched —
  so `Repo.one` resolved the slug across EVERY tenant. Any unauthenticated
  visitor could read any workspace's paper by slug, and on a same-slug
  collision the resolved row was non-deterministic.

  The fix routes the public surface through `Content.get_public_paper/2`, which
  resolves the slug ONLY within the seeded **Default** (public) workspace — the
  one deterministic public tenant (where the flat, unauthenticated paper
  ingest lands by Default fallback).

  These tests stand up the Default workspace plus a SEPARATE non-Default
  workspace, give each a paper under the SAME slug, and prove:

    1. `get_public_paper/2` resolves DETERMINISTICALLY to the Default-workspace
       (intentionally-public) paper, and
    2. it NEVER exposes the other workspace's paper for that slug, and
    3. a slug that exists ONLY in a non-Default workspace returns `nil` (not the
       private paper) from the public surface, and
    4. fail-closed: with no seeded Default workspace the public read is `nil`,
       never an unscoped all-tenant read.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Tenancy

  @slug "2026-05-25-leak-probe"

  @doc """
  Simulate "no seeded Default tenant" without an FK-entangled teardown: vacate
  the seat (`workspaces.is_default`, task-566dc5be4871353b) and nothing else.

  NO RENAME (task-8051eddcd3c9f30f). This used to also rename the Default's
  slug "so the row is unreachable by name" — nothing resolves the Default by
  name any more. The rename was a key-modifying UPDATE (`slug` has a unique
  index), i.e. FOR UPDATE on the SHARED Default row, taken while this test's
  sandbox transaction already held audit(Default) from the setup's
  `upsert_paper`. Every concurrent async test that wrote a row referencing the
  Default holds FOR KEY SHARE on it (the FK check) and then emits audit, so
  the two orders met and Postgres raised 40P01 — in this test or in theirs.
  Vacating updates only `is_default` (partial unique index, not a key column):
  FOR NO KEY UPDATE, which KEY SHARE does not block.

  Public so `Barkpark.Papers.PublicPaperScopeLockOrderTest` (below) runs the
  same statements on unboxed connections.
  """
  def retire_default_workspace! do
    vacate_default_seat!()
  end

  describe "get_public_paper/2 cross-workspace isolation" do
    setup do
      # The seeded Default workspace/project IS the public tenant.
      {default_ws, default_proj} = ensure_default_scope!()

      # A second, NON-Default workspace — its papers must never surface on the
      # public /papers/:slug read.
      other_ws = create_workspace!()
      other_proj = create_project!(other_ws)

      # Two papers under the SAME slug — one public (Default), one private
      # (other workspace). The per-workspace uniqueness flip lets them coexist.
      {:ok, public_paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => @slug,
            "body_html" => "<article id=\"public\">PUBLIC default-workspace paper</article>",
            "workspace_id" => default_ws.id,
            "project_id" => default_proj.id
          })
        )

      {:ok, private_paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => @slug,
            "body_html" => "<article id=\"private\">PRIVATE other-workspace paper</article>",
            "workspace_id" => other_ws.id,
            "project_id" => other_proj.id
          })
        )

      %{
        default_ws: default_ws,
        default_proj: default_proj,
        other_ws: other_ws,
        other_proj: other_proj,
        public_paper: public_paper,
        private_paper: private_paper
      }
    end

    test "resolves DETERMINISTICALLY to the Default (public) paper", ctx do
      paper = Content.get_public_paper(@slug)

      refute is_nil(paper)
      assert paper.workspace_id == ctx.default_ws.id
      assert paper.id == ctx.public_paper.id
      assert get_in(paper.content, ["body_html"]) =~ "PUBLIC default-workspace paper"
    end

    test "NEVER exposes the non-Default workspace's paper for the same slug", ctx do
      paper = Content.get_public_paper(@slug)

      # The leak: before the fix this could resolve to the other workspace's row.
      refute paper.workspace_id == ctx.other_ws.id
      refute paper.id == ctx.private_paper.id
      refute get_in(paper.content, ["body_html"]) =~ "PRIVATE other-workspace paper"
    end

    test "a slug that exists ONLY in a non-Default workspace returns nil publicly",
         ctx do
      private_only_slug = "2026-05-25-private-only"

      {:ok, _private_only} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => private_only_slug,
            "body_html" => "<article>private only</article>",
            "workspace_id" => ctx.other_ws.id,
            "project_id" => ctx.other_proj.id
          })
        )

      # The private paper IS stored (proves the slug exists) — read it with its
      # OWN workspace+project scope (dataset resolution is project-scoped)...
      assert %{} =
               Content.get_paper(private_only_slug, Content.paper_default_dataset(),
                 workspace_id: ctx.other_ws.id,
                 project_id: ctx.other_proj.id
               )

      # ...but the PUBLIC surface must not see it.
      assert Content.get_public_paper(private_only_slug) == nil
    end

    test "fail-closed: no seeded Default workspace → public read is nil, not unscoped",
         ctx do
      fail_slug = "2026-05-25-failclosed"

      lone_ws = create_workspace!()
      lone_proj = create_project!(lone_ws)

      {:ok, _paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => fail_slug,
            "body_html" => "<article>lone</article>",
            "workspace_id" => lone_ws.id,
            "project_id" => lone_proj.id
          })
        )

      retire_default_workspace!()

      assert Tenancy.get_default_workspace() == nil

      # Even though a paper with this slug exists in lone_ws, the public read
      # must NOT fall back to an unscoped all-tenant resolve — fail closed.
      assert Content.get_public_paper(fail_slug) == nil
      # ...and the public lookup of the EARLIER public-tenant slug now also
      # returns nil (its workspace is no longer the resolvable Default).
      assert Content.get_public_paper(@slug) == nil

      _ = ctx
    end
  end
end

defmodule Barkpark.Papers.PublicPaperScopeLockOrderTest do
  @moduledoc """
  task-8051eddcd3c9f30f — retiring the shared Default workspace in a test must
  not deadlock with a concurrent writer to that workspace.

  Two transactions on the Default workspace `ws`, each on its own unboxed
  connection, in the order the async suite interleaves them:

      P: Audit.emit(ws)              ── holds audit(ws)       (the fail-closed
                                                                setup's upsert_paper)
                                        T: INSERT … workspace_id = ws
                                           ── FK check: FOR KEY SHARE on
                                              workspaces(ws)  (a task birth)
      P: retire_default_workspace!() ── wants a lock on workspaces(ws)
                                        T: Audit.emit(ws)   ── wants audit(ws)

  Every writer takes the workspace-row lock (KEY SHARE, from its FK check)
  BEFORE audit(ws). A slug RENAME of the row is a key-modifying UPDATE, so it
  wants FOR UPDATE, which conflicts with KEY SHARE: P waits on T, T waits on
  P, Postgres raises 40P01. Vacating the seat alone updates only the
  `is_default` column (covered by a partial unique index, so not a key
  column): FOR NO KEY UPDATE, which KEY SHARE does not block.

  Deterministic: T does not request audit(ws) until P is either blocked on a
  lock (pg_stat_activity) or has finished retiring. Both transactions roll
  back, so nothing is committed.
  """
  use ExUnit.Case, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Audit
  alias Barkpark.Papers.PublicPaperScopeTest
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Ecto.Adapters.SQL.Sandbox

  defp emit!(ws_id, subject) do
    {:ok, _} =
      Audit.emit(%{
        category: "content_mutation",
        action: "document.lock_order_probe",
        subject: subject,
        workspace_id: ws_id
      })

    :ok
  end

  # A deadlock victim's Postgrex error is returned, not raised, so the test
  # can assert on it.
  defp in_rolled_back_txn(fun) do
    Repo.transaction(fn ->
      fun.()
      Repo.rollback(:done)
    end)
  rescue
    e in Postgrex.Error -> {:postgres_error, e.postgres[:code]}
  end

  defp waiting_on_lock?(pid) do
    %{rows: [[type]]} =
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid])

    type == "Lock"
  end

  # Poll until P is blocked on a lock (true) or reports it finished (false).
  defp await_p_blocked_or_done(p_pid, deadline_ms) do
    receive do
      :p_retired -> false
    after
      20 ->
        cond do
          waiting_on_lock?(p_pid) -> true
          deadline_ms <= 0 -> flunk("P neither blocked nor finished retiring")
          true -> await_p_blocked_or_done(p_pid, deadline_ms - 20)
        end
    end
  end

  test "retiring the Default does not deadlock with a writer that holds its key share" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    {ws, _proj} = ensure_default_scope!()
    parent = self()

    p =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        in_rolled_back_txn(fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          emit!(ws.id, "fail-closed-setup")
          send(parent, {:p_holds_audit, pid})

          receive do
            :go_p -> :ok
          end

          PublicPaperScopeTest.retire_default_workspace!()
          send(parent, :p_retired)
        end)
      end)

    assert_receive {:p_holds_audit, p_pid}, 5_000

    t =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        in_rolled_back_txn(fn ->
          {:ok, _} =
            Tenancy.create_project(ws, %{
              slug: "lock-order-#{System.unique_integer([:positive])}",
              name: "lock order probe"
            })

          send(parent, :t_holds_key_share)

          receive do
            :go_t -> :ok
          end

          emit!(ws.id, "task-birth")
        end)
      end)

    assert_receive :t_holds_key_share, 5_000
    send(p.pid, :go_p)

    p_blocked? = await_p_blocked_or_done(p_pid, 5_000)
    send(t.pid, :go_t)

    results = [Task.await(p, 15_000), Task.await(t, 15_000)]

    refute Enum.any?(results, &match?({:postgres_error, :deadlock_detected}, &1)),
           "the two transactions deadlocked (40P01): #{inspect(results)}"

    assert results == [{:error, :done}, {:error, :done}]

    refute p_blocked?,
           "retire_default_workspace!/0 waited on a writer's KEY SHARE of the Default " <>
             "row while holding audit(ws) — it takes a key-modifying row lock"
  end
end
