defmodule Barkpark.Sync.ApplierTest do
  @moduledoc """
  End-to-end parse + apply + echo-dedup + cursor, WITHOUT a network. A real
  mutation event is manufactured locally (Content.create_document → the
  mutation_events row → ListenController.format_event), run through the SSE
  parser, and applied into a DIFFERENT local workspace via the public Applier.
  Re-applying the same event proves the cursor echo-dedup (skipped, no new
  mutation_events row).
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{DraftId, MutationEvent}
  alias Barkpark.Repo
  alias Barkpark.Sync
  alias Barkpark.Sync.{Applier, Cursor, DeadLetter, SSE}

  @dataset "test"

  setup do
    ws_src = create_workspace!()
    proj_src = create_project!(ws_src)
    ws_dst = create_workspace!()
    proj_dst = create_project!(ws_dst)

    {:ok, src_doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "p1", "title" => "Hello", "content" => %{"body" => "hi"}},
        @dataset,
        workspace_id: ws_src.id,
        project_id: proj_src.id
      )

    # The freshest mutation_events row for the just-written source doc.
    event_row =
      Repo.one!(
        from e in MutationEvent,
          where: e.doc_id == ^src_doc.doc_id and e.dataset == ^@dataset,
          order_by: [desc: e.id],
          limit: 1
      )

    frame = BarkparkWeb.ListenController.format_event(event_row, @dataset)
    {[event], ""} = SSE.parse_frames(frame)

    ctx = %{
      source: "src-#{System.unique_integer([:positive])}",
      dataset: @dataset,
      scope: [workspace_id: ws_dst.id, project_id: proj_dst.id]
    }

    %{event: event, ctx: ctx, ws_dst: ws_dst, proj_dst: proj_dst, src_doc: src_doc}
  end

  test "applies an incoming document into the target workspace and advances the cursor",
       %{event: event, ctx: ctx, ws_dst: ws_dst, proj_dst: proj_dst} do
    assert Cursor.get(ctx.source, ctx.dataset) == 0

    assert {:ok, :applied} = Applier.apply_event(event, ctx)

    # The doc landed in the DESTINATION workspace (draft-prefixed).
    assert {:ok, landed} =
             Content.get_document(DraftId.draft_id("p1"), "post", @dataset,
               workspace_id: ws_dst.id,
               project_id: proj_dst.id
             )

    assert landed.title == "Hello"
    assert landed.content["body"] == "hi"

    # Cursor advanced to the event id.
    assert Cursor.get(ctx.source, ctx.dataset) == event.id
  end

  test "re-applying the same envelope is skipped with no new mutation_events row (echo-dedup)",
       %{event: event, ctx: ctx} do
    assert {:ok, :applied} = Applier.apply_event(event, ctx)

    landed_id = DraftId.draft_id("p1")

    count_after_first =
      Repo.aggregate(
        from(e in MutationEvent, where: e.doc_id == ^landed_id and e.dataset == ^@dataset),
        :count
      )

    assert {:ok, :skipped} = Applier.apply_event(event, ctx)

    count_after_second =
      Repo.aggregate(
        from(e in MutationEvent, where: e.doc_id == ^landed_id and e.dataset == ^@dataset),
        :count
      )

    assert count_after_first == count_after_second
  end

  test "Sync.apply_frames drains raw bytes and returns the carried remainder",
       %{ctx: ctx, src_doc: src_doc} do
    event_row =
      Repo.one!(
        from e in MutationEvent,
          where: e.doc_id == ^src_doc.doc_id and e.dataset == ^@dataset,
          order_by: [desc: e.id],
          limit: 1
      )

    frame = BarkparkWeb.ListenController.format_event(event_row, @dataset)

    {results, rest} = Sync.apply_frames(frame <> "id: 999\nevent: mutation\ndata: {", ctx)

    assert [{event_id, {:ok, :applied}}] = results
    assert is_integer(event_id)
    # The trailing partial frame is carried, not applied.
    assert rest =~ "id: 999"
  end

  describe "Cursor" do
    test "round-trips and advances monotonically" do
      source = "cur-#{System.unique_integer([:positive])}"
      assert Cursor.get(source, @dataset) == 0

      assert :ok = Cursor.put(source, @dataset, 5)
      assert Cursor.get(source, @dataset) == 5

      # A lower value never rewinds the high-water mark.
      assert :ok = Cursor.put(source, @dataset, 3)
      assert Cursor.get(source, @dataset) == 5

      assert :ok = Cursor.put(source, @dataset, 9)
      assert Cursor.get(source, @dataset) == 9
    end
  end

  describe "gating" do
    test "enabled?/0 is false with no source configured" do
      prev = Application.get_env(:barkpark, Barkpark.Sync)
      on_exit(fn -> restore_env(prev) end)

      Application.put_env(:barkpark, Barkpark.Sync, enabled: false)
      refute Sync.enabled?()
    end

    test "enabled?/0 is true only with full url+token+dataset+workspace and enabled true" do
      prev = Application.get_env(:barkpark, Barkpark.Sync)
      on_exit(fn -> restore_env(prev) end)

      # Full creds but enabled false → dormant.
      Application.put_env(:barkpark, Barkpark.Sync,
        url: "http://remote",
        token: "t",
        dataset: "production",
        workspace: "gyldendal",
        enabled: false
      )

      refute Sync.enabled?()

      # Partial creds + enabled true → still dormant (missing token).
      Application.put_env(:barkpark, Barkpark.Sync,
        url: "http://remote",
        dataset: "production",
        workspace: "gyldendal",
        enabled: true
      )

      refute Sync.enabled?()

      # Missing workspace + enabled true → dormant (workspace is required so
      # sync never degrades to a NULL/global write).
      Application.put_env(:barkpark, Barkpark.Sync,
        url: "http://remote",
        token: "t",
        dataset: "production",
        enabled: true
      )

      refute Sync.enabled?()

      # Full creds + enabled true → live.
      Application.put_env(:barkpark, Barkpark.Sync,
        url: "http://remote",
        token: "t",
        dataset: "production",
        workspace: "gyldendal",
        enabled: true
      )

      assert Sync.enabled?()
    end
  end

  describe "drain halts on error (cursor-gap guard)" do
    test "apply_frames stops at the first failed event and never advances the cursor past it",
         %{ctx: ctx, ws_dst: ws_dst, proj_dst: proj_dst} do
      # Three frames: a valid one (id 10), a malformed one with NO id: line
      # (apply → {:error, :missing_event_id}), then a valid one (id 20). The
      # drain must apply #10, halt on the bad frame, and NEVER apply #20 —
      # otherwise the high-water cursor would skip the gap on replay.
      good1 =
        "id: 10\nevent: mutation\n" <>
          ~s(data: {"result":{"_id":"g1","_type":"post","_draft":false,"title":"One","content":{"body":"x"}},"type":"post"}\n\n)

      bad =
        "event: mutation\n" <>
          ~s(data: {"result":{"_id":"g2","_type":"post","_draft":false,"title":"Two","content":{"body":"y"}},"type":"post"}\n\n)

      good2 =
        "id: 20\nevent: mutation\n" <>
          ~s(data: {"result":{"_id":"g3","_type":"post","_draft":false,"title":"Three","content":{"body":"z"}},"type":"post"}\n\n)

      {results, _rest} = Sync.apply_frames(good1 <> bad <> good2, ctx)

      assert [{10, {:ok, :applied}}, {nil, {:error, :missing_event_id}}] = results

      # Cursor sits at the last success (10), NOT 20.
      assert Cursor.get(ctx.source, ctx.dataset) == 10

      # The post-error doc was never written.
      assert {:error, :not_found} =
               Content.get_document(DraftId.draft_id("g3"), "post", @dataset,
                 workspace_id: ws_dst.id,
                 project_id: proj_dst.id
               )
    end
  end

  describe "unresolved workspace guard" do
    test "apply_event refuses to write (no NULL/global scope) when the workspace slug does not resolve",
         %{event: event} do
      settings = %Sync.Settings{
        source: "unres-#{System.unique_integer([:positive])}",
        dataset: @dataset,
        workspace: "no-such-workspace-#{System.unique_integer([:positive])}"
      }

      ctx = Sync.context(settings)
      assert ctx.scope == :unresolved
      assert {:error, :unresolved_workspace} = Applier.apply_event(event, ctx)
    end
  end

  describe "dead-letter unblocks the cursor (no silent loss)" do
    test "a poison event is recorded + dead-lettered at max_attempts, then the cursor advances past it",
         %{ctx: base_ctx} do
      ctx = Map.put(base_ctx, :max_attempts, 1)

      # POISON: a createOrReplace for a `type:task` doc whose content fails the
      # task-kind contract (no valid `kind`/`lifecycle_status`) → the public
      # Content.apply_mutations returns {:error, {:invalid_task_content, _}}.
      poison =
        "id: 7\nevent: mutation\n" <>
          ~s(data: {"result":{"_id":"poison","_type":"task","title":"x","content":{"kind":"nope"}},"type":"task"}\n\n)

      {results, _rest} = Sync.apply_frames(poison, ctx)

      # max_attempts:1 → the first failed apply immediately crosses the threshold.
      assert [{7, {:ok, :dead_lettered}}] = results

      # Durable, queryable, with the ORIGINAL envelope preserved.
      assert [row] = DeadLetter.list_dead(ctx.source, ctx.dataset)
      assert row.event_id == 7
      assert row.status == "dead"
      assert row.envelope["result"]["_id"] == "poison"

      # Cursor advanced PAST the poison (only after the durable DL write).
      assert Cursor.get(ctx.source, ctx.dataset) == 7

      # A following good frame now applies — the poison no longer blocks.
      good =
        "id: 8\nevent: mutation\n" <>
          ~s(data: {"result":{"_id":"g8","_type":"post","_draft":false,"title":"Eight","content":{"body":"z"}},"type":"post"}\n\n)

      {[{8, {:ok, :applied}}], ""} = Sync.apply_frames(good, ctx)
      assert Cursor.get(ctx.source, ctx.dataset) == 8
    end

    test "below max_attempts a poison halts and does NOT advance the cursor (invariant #3)",
         %{ctx: base_ctx} do
      ctx = Map.put(base_ctx, :max_attempts, 3)

      poison =
        "id: 5\nevent: mutation\n" <>
          ~s(data: {"result":{"_id":"poison2","_type":"task","title":"x","content":{"kind":"nope"}},"type":"task"}\n\n)

      {[{5, {:error, _}}], _} = Sync.apply_frames(poison, ctx)
      assert Cursor.get(ctx.source, ctx.dataset) == 0
      assert DeadLetter.list_dead(ctx.source, ctx.dataset) == []
    end
  end

  defp restore_env(nil), do: Application.delete_env(:barkpark, Barkpark.Sync)
  defp restore_env(prev), do: Application.put_env(:barkpark, Barkpark.Sync, prev)
end
