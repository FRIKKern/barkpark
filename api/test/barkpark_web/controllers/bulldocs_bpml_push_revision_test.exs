defmodule BarkparkWeb.BulldocsBpmlPushRevisionTest do
  @moduledoc """
  A BPML push that writes records one revision, action "bpml-push", holding
  the Paper as it stood before the push. A push that writes nothing, or is
  refused, records none.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, LabelFixtures, Repo}
  alias Barkpark.Content.{Document, Revision}

  @ds "production"
  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp t(v), do: %{"type" => "text", "value" => v}

  defp paper!(blocks) do
    slug = "bpml-push-revision-#{System.unique_integer([:positive])}"
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))
    content = paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html")
    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
    slug
  end

  defp blocks do
    [
      %{"id" => "lede", "type" => "paragraph", "role" => "lede", "content" => [t("Lede.")]},
      %{"id" => "p1", "type" => "paragraph", "content" => [t("Plain.")]}
    ]
  end

  defp pull(slug) do
    resp = get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(resp, "x-paper-rev")
    {response(resp, 200), rev}
  end

  defp sync(slug, bpml, rev) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})
  end

  defp row(slug),
    do: Repo.one!(from d in Document, where: d.doc_id == ^slug and d.type == "paper")

  defp revisions(slug),
    do: Repo.all(from r in Revision, where: r.doc_id == ^slug, order_by: [asc: r.inserted_at])

  defp push_revisions(slug), do: Enum.filter(revisions(slug), &(&1.action == "bpml-push"))

  setup do
    LabelFixtures.register_tags!(@ds)
    :ok
  end

  test "an applied push records one revision holding the Paper as it stood before" do
    slug = paper!(blocks())
    before = row(slug)
    {bpml, rev} = pull(slug)

    assert json_response(sync(slug, String.replace(bpml, "Plain.", "Plain, edited."), rev), 200)

    assert [pushed] = push_revisions(slug)
    assert pushed.content == before.content
    assert pushed.rev == before.rev
    assert pushed.title == before.title
    assert pushed.type == "paper"
    assert pushed.document_id == nil
    assert {pushed.dataset, pushed.dataset_id} == {before.dataset, before.dataset_id}
    assert {pushed.workspace_id, pushed.project_id} == {before.workspace_id, before.project_id}

    # The document's revision pointer does not move back to the old state.
    assert row(slug).current_revision_id == before.current_revision_id
  end

  test "an unchanged push, a stale push (412) and a refused push (422) record none" do
    slug = paper!(blocks())
    count = length(revisions(slug))
    {bpml, rev} = pull(slug)

    assert json_response(sync(slug, bpml, rev), 200)
    assert sync(slug, String.replace(bpml, "Plain.", "Stale."), "0").status == 412

    refused = String.replace(bpml, "Lede.", "Lede, edited.")
    assert json_response(sync(slug, refused, rev), 422)["error"]["code"] == "bpml_unshown"

    assert length(revisions(slug)) == count
  end

  test "a batch its before_commit check refuses rolls the revision back with the write" do
    slug = paper!(blocks())
    count = length(revisions(slug))
    op = %{"op" => "append-block", "block" => %{"id" => "p2", "type" => "paragraph"}}
    opts = [before_revision: "bpml-push", before_commit: fn _ -> {:error, :refused} end]

    assert {:error, :refused} = Content.apply_paper_block_ops(slug, [op], @ds, opts)
    assert length(revisions(slug)) == count
  end

  test "history reads find it under its Paper's dataset only, and a restore restores the state before" do
    slug = paper!(blocks())
    before = row(slug)
    {bpml, rev} = pull(slug)
    assert json_response(sync(slug, String.replace(bpml, "Plain.", "Plain, edited."), rev), 200)
    [pushed] = push_revisions(slug)

    assert pushed.id in Enum.map(Content.list_revisions(slug, "paper", @ds), & &1.id)
    assert Content.list_revisions(slug, "paper", "other-dataset") == []
    assert {:ok, %Revision{}} = Content.get_revision(pushed.id, @ds)
    assert {:error, :not_found} = Content.get_revision(pushed.id, "other-dataset")

    assert {:ok, restored} = Content.restore_revision(pushed.id, "paper", @ds)
    assert restored.content["blocks"] == before.content["blocks"]
  end
end
