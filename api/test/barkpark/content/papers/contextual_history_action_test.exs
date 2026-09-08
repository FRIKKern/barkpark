defmodule Barkpark.Content.Papers.ContextualHistoryActionTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Repo.IdempotencyStore
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "production"
  @principal "user:contextual-action"

  test "image undo and redo preserve every other source field and immutable receipts" do
    {slug, original} = seed!()
    {ref, forward} = change!(slug, "image", "src", "/after.png")
    predecessor = row!(original, ref)
    undo_id = Ecto.UUID.generate()
    opts = revision_opts(slug)

    assert {:ok, undo, :applied} = action(slug, ref, "undo", undo_id, opts)
    assert current(slug).content["blocks"] === original.content["blocks"]
    assert undo.contextual_history["action"] == "redo"
    assert row!(original, ref).response_body === predecessor.response_body

    assert {:ok, ^undo, :replayed} = action(slug, ref, "undo", undo_id, opts)
    assert current(slug).content["rev"] == undo.rev

    assert {:ok, redo, :applied} = action(slug, undo_id, "redo")
    assert redo.contextual_history["action"] == "undo"
    assert image(current(slug))["src"] == "/after.png"
    assert Map.delete(image(current(slug)), "src") === Map.delete(image(original), "src")
    assert forward.contextual_history["action"] == "undo"
  end

  test "caption undo restores absence, redo restores an explicit empty string" do
    {slug, original} = seed!()
    {ref, _} = change!(slug, "figure", "caption", "")
    undo_id = Ecto.UUID.generate()

    assert {:ok, _, :applied} = action(slug, ref, "undo", undo_id)
    assert current(slug).content["blocks"] === original.content["blocks"]
    refute Map.has_key?(figure(current(slug)), "caption")
    assert {:ok, _, :applied} = action(slug, undo_id, "redo")
    assert Map.fetch!(figure(current(slug)), "caption") === ""
  end

  test "a block form receipt authorizes an undo and redo chain without replacing source metadata" do
    {slug, original} = seed!()
    history_ref = Ecto.UUID.generate()
    undo_id = Ecto.UUID.generate()

    resolver = fn _blocks ->
      {:ok,
       [
         %{
           "op" => "patch-block",
           "id" => "figure",
           "patch" => %{"caption" => "Form caption"}
         }
       ]}
    end

    assert {:ok, forward, :applied} =
             Content.apply_paper_block_form_once(
               slug,
               "figure_caption_form:v1",
               %{"block_id" => "figure", "caption" => "Form caption"},
               @dataset,
               history_ref,
               @principal,
               resolver,
               if_rev: original.content["rev"] || 0,
               contextual_history: true
             )

    predecessor = row!(original, history_ref)
    assert String.starts_with?(predecessor.scope, "paper_block_form:v1:")

    assert Jason.decode!(predecessor.response_body)["contextual_history"] ==
             forward.contextual_history

    assert figure(current(slug))["caption"] == "Form caption"
    assert image(current(slug)) === image(original)

    assert {:ok, undo, :applied} = action(slug, history_ref, "undo", undo_id)
    refute Map.has_key?(figure(current(slug)), "caption")
    assert image(current(slug)) === image(original)
    assert row!(original, history_ref).response_body === predecessor.response_body

    assert {:ok, redo, :applied} = action(slug, undo_id, "redo")
    assert figure(current(slug))["caption"] == "Form caption"
    assert image(current(slug)) === image(original)
    assert redo.contextual_history["action"] == "undo"
    assert undo.contextual_history["action"] == "redo"
  end

  test "an unrelated edit survives a history step at the fresh revision" do
    {slug, _} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    change!(slug, "image", "alt", "New authored description")

    assert {:ok, _, :applied} = action(slug, ref, "undo")
    assert image(current(slug))["src"] == "/before.png"
    assert image(current(slug))["alt"] == "New authored description"
  end

  test "same-field conflict rejects without consuming the receipt or writing" do
    {slug, _} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    change!(slug, "image", "src", "/newer.png")
    before = current(slug)

    assert {:error, :history_conflict} = action(slug, ref, "undo")
    assert current(slug).content === before.content
    change!(slug, "image", "src", "/after.png")
    assert {:ok, _, :applied} = action(slug, ref, "undo")
  end

  test "a consumed ref cannot be applied again after an ABA source cycle" do
    {slug, _} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    undo_id = Ecto.UUID.generate()
    assert {:ok, _, :applied} = action(slug, ref, "undo", undo_id)
    assert {:ok, _, :applied} = action(slug, undo_id, "redo")
    before = current(slug)

    assert {:error, :history_ref_consumed} = action(slug, ref, "undo")
    assert current(slug).content === before.content
  end

  test "foreign principal, foreign paper, wrong action and unknown refs cannot write" do
    {slug, _} = seed!()
    {other_slug, _} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    before = current(slug)
    other_before = current(other_slug)

    assert {:error, _} =
             Content.apply_paper_contextual_history_once(
               slug,
               ref,
               "undo",
               @dataset,
               Ecto.UUID.generate(),
               "user:foreign",
               revision_opts(slug)
             )

    assert {:error, _} = action(other_slug, ref, "undo")
    assert {:error, _} = action(slug, ref, "redo")
    assert {:error, _} = action(slug, Ecto.UUID.generate(), "undo")
    assert current(slug).content === before.content
    assert current(other_slug).content === other_before.content
  end

  test "the same slug in another workspace cannot resolve the original history" do
    {slug, _} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    workspace = TenancyFixtures.create_workspace!()
    project = TenancyFixtures.create_project!(workspace)
    {_slug, other} = seed!(slug, workspace_id: workspace.id, project_id: project.id)
    opts = [workspace_id: workspace.id, project_id: project.id, if_rev: other.content["rev"] || 0]

    assert {:error, _} =
             Content.apply_paper_contextual_history_once(
               slug,
               ref,
               "undo",
               @dataset,
               Ecto.UUID.generate(),
               @principal,
               opts
             )

    assert Content.get_paper(slug, @dataset, opts).content === other.content
  end

  test "a completed action request cannot replay different history input" do
    {slug, _} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    request_id = Ecto.UUID.generate()
    opts = revision_opts(slug)
    assert {:ok, _, :applied} = action(slug, ref, "undo", request_id, opts)
    before = current(slug)

    assert {:error, :idempotency_payload_mismatch} = action(slug, ref, "redo", request_id, opts)

    assert {:error, :idempotency_payload_mismatch} =
             action(slug, Ecto.UUID.generate(), "undo", request_id, opts)

    assert current(slug).content === before.content
  end

  test "expired unswept receipts are not authority" do
    {slug, paper} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    row = row!(paper, ref)

    row
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -3601, :second))
    |> Repo.update!()

    before = current(slug)

    assert {:error, _} = action(slug, ref, "undo")
    assert current(slug).content === before.content
    assert Repo.get(IdempotencyStore.Key, row.key_hash)
  end

  test "completion failure rolls back source, action and consumption, then allows retry" do
    {slug, _} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    before = current(slug)
    count = Repo.aggregate(IdempotencyStore.Key, :count)
    request_id = Ecto.UUID.generate()

    opts =
      Keyword.put(revision_opts(slug), :before_idempotency_complete, fn ->
        Repo.delete_all(IdempotencyStore.Key)
      end)

    assert {:error, _} = action(slug, ref, "undo", request_id, opts)
    assert current(slug).content === before.content
    assert Repo.aggregate(IdempotencyStore.Key, :count) == count
    assert {:ok, _, :applied} = action(slug, ref, "undo", request_id)
  end

  test "legacy and malformed receipts cannot supply history authority" do
    for mode <- [:legacy, :malformed, :missing_envelope, :malformed_envelope] do
      {slug, paper} = seed!()
      {ref, _} = change!(slug, "image", "src", "/after.png")
      row = row!(paper, ref)
      receipt = Jason.decode!(row.response_body)

      receipt =
        case mode do
          :legacy -> Map.delete(receipt, "contextual_history")
          :malformed -> put_in(receipt, ["contextual_history", "field"], "locked")
          :missing_envelope -> Map.take(receipt, ["contextual_history"])
          :malformed_envelope -> Map.put(receipt, "rev", "not-a-revision")
        end

      row |> Ecto.Changeset.change(response_body: Jason.encode!(receipt)) |> Repo.update!()
      before = current(slug)
      before_rows = Repo.aggregate(IdempotencyStore.Key, :count)

      assert {:error, _} = action(slug, ref, "undo")
      assert current(slug).content === before.content
      assert Repo.aggregate(IdempotencyStore.Key, :count) == before_rows
    end
  end

  test "a physical scope change after the action claim cannot reuse old-scope authority" do
    {slug, paper} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    other_project = TenancyFixtures.create_project!(paper.workspace_id)
    before = current(slug)
    before_rows = Repo.aggregate(IdempotencyStore.Key, :count)

    opts =
      revision_opts(slug)
      |> Keyword.put(:workspace_id, paper.workspace_id)
      |> Keyword.put(:after_idempotency_claim, fn ->
        Repo.get!(Barkpark.Content.Document, paper.id)
        |> Ecto.Changeset.change(project_id: other_project.id)
        |> Repo.update!()
      end)

    assert {:error, _} = action(slug, ref, "undo", Ecto.UUID.generate(), opts)
    assert current(slug).content === before.content
    assert current(slug).project_id == before.project_id
    assert Repo.aggregate(IdempotencyStore.Key, :count) == before_rows
  end

  test "a committed doc id and type rename after prefetch rejects history on the same row" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      workspace = TenancyFixtures.create_workspace!()
      project = TenancyFixtures.create_project!(workspace)
      {slug, paper} = seed!(nil, workspace_id: workspace.id, project_id: project.id)
      history_ref = Ecto.UUID.generate()
      request_id = Ecto.UUID.generate()
      renamed_doc_id = "renamed-#{slug}"
      renamed_type = "session"
      scope_opts = [workspace_id: workspace.id, project_id: project.id]

      owned_hashes = [
        paper_key_hash(paper, history_ref),
        paper_key_hash(paper, request_id),
        history_consumption_hash(paper, history_ref)
      ]

      try do
        assert {:ok, forward, :applied} =
                 Content.apply_paper_block_ops_once(
                   slug,
                   [
                     %{
                       "op" => "patch-block",
                       "id" => "image",
                       "patch" => %{"src" => "/after.png"}
                     }
                   ],
                   @dataset,
                   history_ref,
                   @principal,
                   scope_opts ++
                     [if_rev: paper.content["rev"] || 0, contextual_history: true]
                 )

        changed_content = Repo.get!(Barkpark.Content.Document, paper.id).content

        opts =
          scope_opts ++
            [
              if_rev: forward.rev,
              after_idempotency_claim: fn ->
                Task.async(fn ->
                  Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                    Repo.get!(Barkpark.Content.Document, paper.id)
                    |> Ecto.Changeset.change(doc_id: renamed_doc_id, type: renamed_type)
                    |> Repo.update!()
                  end)
                end)
                |> Task.await(5_000)
              end
            ]

        assert {:error, :not_found} = action(slug, history_ref, "undo", request_id, opts)

        stored = Repo.get!(Barkpark.Content.Document, paper.id)
        assert stored.doc_id == renamed_doc_id
        assert stored.type == renamed_type
        assert stored.content === changed_content
        refute Repo.get(IdempotencyStore.Key, paper_key_hash(paper, request_id))
        refute Repo.get(IdempotencyStore.Key, history_consumption_hash(paper, history_ref))
      after
        Repo.delete_all(from(k in IdempotencyStore.Key, where: k.key_hash in ^owned_hashes))
        assert {:ok, _workspace} = Tenancy.delete_workspace(workspace)
      end
    end)
  end

  test "history cannot mint a positional identity to target an id-less replacement" do
    {slug, paper} = seed!()

    canonical =
      Enum.map(paper.content["blocks"], fn
        %{"id" => "figure"} = block -> put_in(block, ["child", "id"], "figure-child-0")
        block -> block
      end)

    paper
    |> Ecto.Changeset.change(content: Map.put(paper.content, "blocks", canonical))
    |> Repo.update!()

    {ref, _} = change!(slug, "figure-child-0", "src", "/after.png")
    saved = current(slug)

    unstable =
      Enum.map(saved.content["blocks"], fn
        %{"id" => "figure"} = block -> Map.update!(block, "child", &Map.delete(&1, "id"))
        block -> block
      end)

    saved
    |> Ecto.Changeset.change(content: Map.put(saved.content, "blocks", unstable))
    |> Repo.update!()

    before = current(slug)
    before_rows = Repo.aggregate(IdempotencyStore.Key, :count)

    assert {:error, _} = action(slug, ref, "undo")
    assert current(slug).content === before.content
    assert Repo.aggregate(IdempotencyStore.Key, :count) == before_rows
  end

  test "history never promotes a legacy body tree while reversing a field" do
    {slug, _} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    saved = current(slug)

    legacy_content =
      saved.content
      |> Map.delete("blocks")
      |> Map.put("body", %{"blocks" => saved.content["blocks"], "metadata" => "keep"})

    saved |> Ecto.Changeset.change(content: legacy_content) |> Repo.update!()
    before = current(slug)
    before_rows = Repo.aggregate(IdempotencyStore.Key, :count)

    assert {:error, _} = action(slug, ref, "undo")
    assert current(slug).content === before.content
    assert Repo.aggregate(IdempotencyStore.Key, :count) == before_rows
  end

  test "contextual history cannot borrow an unrelated canvas run context" do
    {slug, _} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    before = current(slug)
    before_rows = Repo.aggregate(IdempotencyStore.Key, :count)

    opts =
      Keyword.put(revision_opts(slug), :canvas_run_context, %{
        container_kind: "document",
        container_run_ids: ["intro"]
      })

    assert {:error, _} = action(slug, ref, "undo", Ecto.UUID.generate(), opts)
    assert current(slug).content === before.content
    assert Repo.aggregate(IdempotencyStore.Key, :count) == before_rows
  end

  test "invalid requests and stale revisions fail without writing" do
    {slug, _} = seed!()
    {ref, _} = change!(slug, "image", "src", "/after.png")
    before = current(slug)

    assert {:error, _} = action(slug, ref, "undo", ref)
    assert {:error, _} = action(slug, "not-a-uuid", "undo")
    assert {:error, _} = action(slug, ref, "sideways")
    assert {:error, _} = action(slug, ref, "undo", Ecto.UUID.generate(), [])
    assert {:error, _} = action(slug, ref, "undo", Ecto.UUID.generate(), if_rev: -1)
    assert current(slug).content === before.content
  end

  defp action(slug, ref, action, request_id \\ Ecto.UUID.generate(), opts \\ nil) do
    Content.apply_paper_contextual_history_once(
      slug,
      ref,
      action,
      @dataset,
      request_id,
      @principal,
      opts || revision_opts(slug)
    )
  end

  defp change!(slug, id, field, value) do
    ref = Ecto.UUID.generate()

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [%{"op" => "patch-block", "id" => id, "patch" => %{field => value}}],
               @dataset,
               ref,
               @principal,
               Keyword.put(revision_opts(slug), :contextual_history, true)
             )

    {ref, receipt}
  end

  defp revision_opts(slug), do: [if_rev: current(slug).content["rev"] || 0]
  defp current(slug), do: Content.get_paper(slug)
  defp figure(paper), do: Enum.find(paper.content["blocks"], &(&1["id"] == "figure"))
  defp image(paper), do: figure(paper)["child"]

  defp row!(paper, ref) do
    Repo.get!(IdempotencyStore.Key, paper_key_hash(paper, ref))
  end

  defp paper_key_hash(paper, request_id) do
    deterministic_hash({
      "paper_ops:v1",
      paper.id,
      paper.workspace_id,
      paper.project_id,
      paper.dataset_id,
      paper.dataset,
      @principal,
      request_id
    })
  end

  defp history_consumption_hash(paper, history_ref) do
    deterministic_hash({
      "paper_contextual_history_consumption:v1",
      paper.id,
      paper.workspace_id,
      paper.project_id,
      paper.dataset_id,
      paper.dataset,
      @principal,
      history_ref
    })
  end

  defp deterministic_hash(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp seed!(slug \\ nil, scope_attrs \\ []) do
    slug = slug || "history-action-#{System.unique_integer([:positive])}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        slug: slug,
        blocks: [
          %{"id" => "intro", "type" => "paragraph", "text" => "Keep this paragraph."},
          %{
            "id" => "figure",
            "type" => "figure",
            "child" => %{
              "id" => "image",
              "type" => "image",
              "src" => "/before.png",
              "alt" => "Authored description",
              "title" => "Authored title"
            }
          }
        ]
      })

    assert {:ok, paper} = Content.upsert_paper(Map.merge(attrs, Map.new(scope_attrs)))
    {slug, paper}
  end
end
