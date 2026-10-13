defmodule Barkpark.Content.DirectPublishTest do
  @moduledoc """
  task-6e2552cdeb223fa2: `{"createOrReplace": doc, "publish": true}` writes the
  document straight to its published row: one row write, one revision, one
  event and one audit row, and no draft round trip. The publish gates still
  run.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo}
  alias Barkpark.Audit.Event
  alias Barkpark.Content.{Document, MutationEvent, Revision}

  @ds "production"
  @type_name "direct_pub"

  setup do
    {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Direct",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "body", "type" => "text"},
            %{
              "name" => "related",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => @type_name}
            }
          ]
        },
        @ds,
        workspace_id: ws.id
      )

    %{opts: [source: :api, workspace_id: ws.id], ws: ws}
  end

  defp direct(id, fields \\ %{}) do
    %{
      "createOrReplace" =>
        Map.merge(%{"_id" => id, "_type" => @type_name, "title" => "Title #{id}"}, fields),
      "publish" => true
    }
  end

  defp rows(id) do
    docs =
      Repo.all(from(d in Document, where: d.doc_id in [^id, ^"drafts.#{id}"], select: d.doc_id))

    %{
      docs: Enum.sort(docs),
      revisions: Repo.aggregate(from(r in Revision, where: r.doc_id == ^id), :count),
      events:
        Repo.all(
          from(e in MutationEvent, where: e.doc_id in [^id, ^"drafts.#{id}"], select: e.mutation)
        ),
      audits:
        Repo.all(
          from(a in Event,
            where: a.subject in [^id, ^"drafts.#{id}"] and a.category == "content_mutation",
            select: a.action
          )
        )
    }
  end

  test "lands the published row with one revision, event and audit row", %{opts: opts} do
    assert {:ok, {_tx, [result]}} =
             Content.apply_mutations([direct("dp-one", %{"body" => "hello"})], @ds, opts)

    assert result.id == "dp-one"
    assert result.operation == "createOrReplace"

    assert %{docs: ["dp-one"], revisions: 1, events: ["publish"], audits: ["document.publish"]} =
             rows("dp-one")

    assert {:ok, doc} = Content.get_document("dp-one", @type_name, @ds, opts)
    assert doc.status == "published"
    assert doc.content["body"] == "hello"
  end

  test "replaces an existing published row and deletes a pending draft", %{opts: opts} do
    {:ok, _} = Content.apply_mutations([direct("dp-two")], @ds, opts)

    {:ok, _} =
      Content.apply_mutations(
        [%{"createOrReplace" => %{"_id" => "dp-two", "_type" => @type_name, "title" => "draft"}}],
        @ds,
        opts
      )

    assert rows("dp-two").docs == ["dp-two", "drafts.dp-two"]

    {:ok, _} = Content.apply_mutations([direct("dp-two", %{"title" => "second"})], @ds, opts)

    assert rows("dp-two").docs == ["dp-two"]
    assert {:ok, doc} = Content.get_document("dp-two", @type_name, @ds, opts)
    assert doc.title == "second"
  end

  test "ifRevisionID is checked against the published row", %{opts: opts} do
    {:ok, {_tx, [first]}} = Content.apply_mutations([direct("dp-rev")], @ds, opts)
    rev = first.document["_rev"]

    stale =
      put_in(direct("dp-rev", %{"title" => "x"}), ["createOrReplace", "ifRevisionID"], "stale")

    assert {:error, {:rev_mismatch, _}} = Content.apply_mutations([stale], @ds, opts)

    fresh = put_in(direct("dp-rev", %{"title" => "y"}), ["createOrReplace", "ifRevisionID"], rev)
    assert {:ok, _} = Content.apply_mutations([fresh], @ds, opts)
  end

  test "the publish gates still run", %{opts: opts} do
    assert {:error, {:empty_list_members, _}} =
             Content.apply_mutations([direct("dp-gate", %{"related" => [nil]})], @ds, opts)

    assert rows("dp-gate").docs == []
  end

  test "a dry run writes nothing", %{opts: opts} do
    assert {:ok, {_tx, [_]}} =
             Content.apply_mutations([direct("dp-dry")], @ds, [dry_run: true] ++ opts)

    assert %{docs: [], revisions: 0, events: [], audits: []} = rows("dp-dry")
  end

  test "system types and papers are refused, and the flag must be a boolean", %{opts: opts} do
    task = %{
      "createOrReplace" => %{"_id" => "dp-task", "_type" => "task", "title" => "t"},
      "publish" => true
    }

    assert {:error, {:direct_publish_unsupported, "task"}} =
             Content.apply_mutations([task], @ds, opts)

    bad = Map.put(direct("dp-bad"), "publish", "yes")
    assert {:error, {:invalid_publish_flag, "yes"}} = Content.apply_mutations([bad], @ds, opts)
  end
end
