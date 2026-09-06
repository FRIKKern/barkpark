defmodule Barkpark.Content.Papers.DocumentStepsIdentityTest do
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias Barkpark.Repo
  alias Barkpark.Content.Document
  alias Barkpark.Repo.IdempotencyStore

  @dataset "production"
  @doc_type "legacy_beta_steps"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Legacy Beta steps",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}],
          "layout" => [%{"kind" => "field", "name" => "title"}]
        },
        @dataset
      )

    :ok
  end

  test "a fenced child edit addresses projected legacy step identities and persists them" do
    {doc, legacy} = legacy_steps_doc!(unique("accepted"))
    projected = Content.ensure_block_ids(legacy["blocks"])
    child = projected |> hd() |> Map.fetch!("steps") |> hd() |> Map.fetch!("children") |> hd()

    assert {:ok, %{block_id: child_id, rev: rev} = receipt} =
             Content.apply_document_block_op(
               doc.doc_id,
               @doc_type,
               %{
                 "op" => "patch-block",
                 "id" => child["id"],
                 "patch" => %{"text" => "After"}
               },
               @dataset,
               if_rev: doc.rev
             )

    assert child_id == child["id"]
    refute rev == doc.rev
    refute Map.has_key?(receipt, :no_op)

    {:ok, saved} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    steps = hd(saved.content["blocks"])
    row = hd(steps["steps"])
    assert steps["parent-meta"] == %{"keep" => true}
    assert row["row-meta"] == [1, 2]
    assert hd(row["children"])["text"] == "After"

    assert saved.content["blocks"] ==
             put_in(
               projected,
               [Access.at(0), "steps", Access.at(0), "children", Access.at(0), "text"],
               "After"
             )
  end

  test "projection reserves authored ids across the full tree before minting a steps child" do
    {doc, legacy} =
      legacy_steps_doc!(unique("cross-tree"), [
        %{"id" => "block-1-step-0-0", "type" => "paragraph", "text" => "Outside"}
      ])

    projected = Content.ensure_block_ids(legacy["blocks"])
    [outside, steps] = projected
    child = steps |> Map.fetch!("steps") |> hd() |> Map.fetch!("children") |> hd()

    assert outside["id"] == "block-1-step-0-0"
    assert child["id"] == "block-1-step-0-0-1"

    assert {:ok, _receipt} =
             Content.apply_document_block_op(
               doc.doc_id,
               @doc_type,
               %{
                 "op" => "patch-block",
                 "id" => child["id"],
                 "patch" => %{"text" => "Child after"}
               },
               @dataset,
               if_rev: doc.rev
             )

    {:ok, saved} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    [saved_outside, saved_steps] = saved.content["blocks"]
    assert saved_outside["text"] == "Outside"

    assert get_in(saved_steps, ["steps", Access.at(0), "children", Access.at(0), "text"]) ==
             "Child after"
  end

  test "hidden authored aliases reserve ids without becoming projected or targetable" do
    blocks = [
      %{
        "type" => "steps",
        "steps" => [
          %{
            "children" => [%{"type" => "paragraph", "text" => "Visible"}],
            "blocks" => [
              %{"id" => "block-0-step-0-0", "type" => "paragraph", "text" => "Shadow"}
            ]
          }
        ]
      }
    ]

    [projected] = Content.ensure_block_ids(blocks)
    [row] = projected["steps"]
    assert hd(row["children"])["id"] == "block-0-step-0-0-1"
    assert row["blocks"] == hd(blocks)["steps"] |> hd() |> Map.fetch!("blocks")
  end

  test "safe projection and identified ops refuse explicit legacy duplicates without rewriting ids" do
    duplicate = "legacy-duplicate"

    {doc, legacy} =
      legacy_steps_doc!(unique("ambiguous"), [
        %{"id" => duplicate, "type" => "paragraph", "text" => "Outside"}
      ])

    legacy =
      put_in(
        legacy,
        ["blocks", Access.at(1), "steps", Access.at(0), "children", Access.at(0), "id"],
        duplicate
      )
      |> put_in(["blocks", Access.at(1), "id"], "steps-explicit")
      |> put_in(["blocks", Access.at(1), "steps", Access.at(0), "id"], "row-explicit")

    Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [content: legacy])

    assert Content.ensure_block_ids(legacy["blocks"]) == legacy["blocks"]

    assert {:error, {:duplicate_id, ^duplicate}} =
             Content.project_block_ids_safely(legacy["blocks"])

    assert {:error, {:duplicate_id, ^duplicate}} =
             Content.apply_document_block_op(
               doc.doc_id,
               @doc_type,
               %{"op" => "patch-block", "id" => duplicate, "patch" => %{"text" => "Wrong"}},
               @dataset,
               if_rev: doc.rev
             )

    assert {:error, {:duplicate_id, ^duplicate}} =
             Content.apply_document_block_form_once(
               doc.doc_id,
               @doc_type,
               "block_form:v1",
               %{"block_id" => duplicate},
               @dataset,
               Ecto.UUID.generate(),
               "user:ambiguous",
               fn _blocks -> flunk("resolver ran for an ambiguous projected tree") end,
               if_rev: doc.rev
             )

    assert_stored_exact(doc, legacy)
  end

  test "stale, malformed, and missing-target identified ops preserve legacy storage exactly" do
    for {label, op, if_rev} <- [
          {"stale", projected_patch("After"), "stale"},
          {"malformed", %{}, :current},
          {"missing", %{"op" => "patch-block", "id" => "missing", "patch" => %{}}, :current}
        ] do
      {doc, legacy} = legacy_steps_doc!(unique(label))
      expected_rev = if(if_rev == :current, do: doc.rev, else: if_rev)

      assert {:error, _reason} =
               Content.apply_document_block_op(doc.doc_id, @doc_type, op, @dataset,
                 if_rev: expected_rev
               )

      assert_stored_exact(doc, legacy)
    end
  end

  test "an identified no-op returns a truthful receipt without persisting projected ids" do
    {doc, legacy} = legacy_steps_doc!(unique("noop"))

    assert {:ok,
            %{
              no_op: true,
              written_doc_id: written_doc_id,
              written_row_id: written_row_id,
              rev: rev
            }} =
             Content.apply_document_block_op(
               doc.doc_id,
               @doc_type,
               %{"op" => "remove-block", "id" => "already-absent"},
               @dataset,
               if_rev: doc.rev
             )

    assert written_doc_id == doc.doc_id
    assert written_row_id == doc.id
    assert rev == doc.rev
    assert_stored_exact(doc, legacy)
  end

  test "the keyless legacy path does not project identities" do
    {doc, legacy} = legacy_steps_doc!(unique("keyless"))

    assert {:error, {:block_not_found, "block-0-step-0-0", "patch-block"}} =
             Content.apply_document_block_op(
               doc.doc_id,
               @doc_type,
               projected_patch("Must not land"),
               @dataset
             )

    assert_stored_exact(doc, legacy)
  end

  test "canonical and form exact-once no-ops replay without writes, effects, or resolver reruns" do
    {canonical, canonical_legacy} = legacy_steps_doc!(unique("canonical-once"))
    {form, form_legacy} = legacy_steps_doc!(unique("form-once"))
    install_after_write_probe!()
    subscribe(canonical)
    subscribe(form)

    request_id = Ecto.UUID.generate()
    op = %{"op" => "remove-block", "id" => "already-absent"}

    assert {:error, {:rev_mismatch, _}} =
             Content.apply_document_block_op_once(
               canonical.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:canonical",
               if_rev: "stale"
             )

    assert {:ok, %{no_op: true, rev: canonical_rev} = receipt, :applied} =
             Content.apply_document_block_op_once(
               canonical.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:canonical",
               if_rev: canonical.rev
             )

    assert canonical_rev == canonical.rev

    assert {:ok, ^receipt, :replayed} =
             Content.apply_document_block_op_once(
               canonical.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:canonical",
               if_rev: canonical.rev
             )

    parent = self()
    form_request_id = Ecto.UUID.generate()

    resolver = fn blocks ->
      send(parent, {:resolved_once, blocks})
      {:ok, op}
    end

    assert {:ok, %{no_op: true} = form_receipt, :applied} =
             Content.apply_document_block_form_once(
               form.doc_id,
               @doc_type,
               "block_form:v1",
               %{"block_id" => "block-0"},
               @dataset,
               form_request_id,
               "user:form",
               resolver,
               if_rev: form.rev
             )

    assert_receive {:resolved_once, resolved}
    assert resolved == Content.ensure_block_ids(form_legacy["blocks"])

    assert {:ok, ^form_receipt, :replayed} =
             Content.apply_document_block_form_once(
               form.doc_id,
               @doc_type,
               "block_form:v1",
               %{"block_id" => "block-0"},
               @dataset,
               form_request_id,
               "user:form",
               fn _ -> flunk("resolver reran on replay") end,
               if_rev: form.rev
             )

    refute_receive {:doc_updated, _}, 50
    refute_receive %{event: :after_save}, 50
    assert_stored_exact(canonical, canonical_legacy)
    assert_stored_exact(form, form_legacy)
  end

  test "an exact-once meaningful remove with a nil block receipt still replays" do
    {doc, _legacy} = legacy_steps_doc!(unique("remove-once"))
    request_id = Ecto.UUID.generate()
    op = %{"op" => "remove-block", "id" => "block-0-step-0-0"}

    assert {:ok, %{block: nil} = receipt, :applied} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:remove",
               if_rev: doc.rev
             )

    refute Map.has_key?(receipt, :no_op)

    assert {:ok, ^receipt, :replayed} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:remove",
               if_rev: doc.rev
             )

    key =
      Repo.one!(
        from(k in IdempotencyStore.Key,
          where: like(k.scope, "document_op:v1:%")
        )
      )

    malformed =
      key.response_body |> Jason.decode!() |> Map.put("no_op", "true") |> Jason.encode!()

    Repo.update_all(from(k in IdempotencyStore.Key, where: k.key_hash == ^key.key_hash),
      set: [response_body: malformed]
    )

    assert {:error, :idempotency_receipt_invalid} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:remove",
               if_rev: doc.rev
             )
  end

  test "a published-row no-op receipt cannot replay after a draft becomes authoritative" do
    {draft, _legacy} = legacy_steps_doc!(unique("published-noop"))
    published_id = Content.published_id(draft.doc_id)
    {:ok, published} = Content.publish_document(published_id, @doc_type, @dataset)
    request_id = Ecto.UUID.generate()
    op = %{"op" => "remove-block", "id" => "already-absent"}

    assert {:ok, %{no_op: true, written_row_id: published_row_id}, :applied} =
             Content.apply_document_block_op_once(
               published.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:published",
               if_rev: published.rev
             )

    assert published_row_id == published.id

    {:ok, replacement} =
      Content.upsert_document(
        @doc_type,
        %{
          "doc_id" => published.doc_id,
          "title" => published.title,
          "content" => published.content
        },
        @dataset
      )

    refute replacement.id == published.id

    assert {:error, :idempotency_target_replaced} =
             Content.apply_document_block_op_once(
               published.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:published",
               if_rev: published.rev
             )
  end

  defp legacy_steps_doc!(id, prefix_blocks \\ []) do
    {:ok, doc} =
      Content.create_document(@doc_type, %{"doc_id" => id, "title" => "Legacy"}, @dataset)

    legacy = %{
      "title" => "Legacy",
      "blocks" =>
        prefix_blocks ++
          [
            %{
              "type" => "steps",
              "parent-meta" => %{"keep" => true},
              "steps" => [
                %{
                  "title" => "First",
                  "row-meta" => [1, 2],
                  "children" => [%{"type" => "paragraph", "text" => "Before"}]
                }
              ]
            }
          ]
    }

    Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [content: legacy])
    {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    {stored, legacy}
  end

  defp projected_patch(text) do
    %{
      "op" => "patch-block",
      "id" => "block-0-step-0-0",
      "patch" => %{"text" => text}
    }
  end

  defp assert_stored_exact(doc, legacy) do
    {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert stored.rev == doc.rev
    assert stored.content == legacy
  end

  defp subscribe(doc) do
    Phoenix.PubSub.subscribe(
      Barkpark.PubSub,
      Broadcast.doc_topic(
        Content.published_id(doc.doc_id),
        @doc_type,
        doc.workspace_id,
        @dataset
      )
    )
  end

  defp install_after_write_probe! do
    parent = self()
    previous = Application.get_env(:barkpark, :after_write_listeners)
    Application.put_env(:barkpark, :after_write_listeners, [fn event -> send(parent, event) end])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :after_write_listeners, previous),
        else: Application.delete_env(:barkpark, :after_write_listeners)
    end)
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
