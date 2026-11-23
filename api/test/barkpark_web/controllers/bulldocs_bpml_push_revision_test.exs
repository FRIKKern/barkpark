defmodule BarkparkWeb.BulldocsBpmlPushRevisionTest do
  @moduledoc """
  A BPML push that writes records two revisions in its transaction: the
  Paper as it stood before the push (`PushRevision.before_action/0`) and as
  the push left it (`PushRevision.after_action/0`). A push that writes
  nothing, or is refused, records neither, and a row that fails to insert
  takes the write back with it; the sync route answers that server fault 500
  `internal_error`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, LabelFixtures, Repo}
  alias Barkpark.Content.{Document, Revision}
  alias Barkpark.Content.Papers.PushRevision

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
    resp = get(scoped_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(resp, "x-paper-rev")
    {response(resp, 200), rev}
  end

  defp sync(slug, bpml, rev) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})
  end

  defp row(slug),
    do: Repo.one!(from d in Document, where: d.doc_id == ^slug and d.type == "paper")

  defp revisions(slug),
    do: Repo.all(from r in Revision, where: r.doc_id == ^slug, order_by: [asc: r.inserted_at])

  defp push_revisions(slug),
    do: Enum.filter(revisions(slug), &(&1.action in PushRevision.actions()))

  setup do
    LabelFixtures.register_tags!(@ds)
    :ok
  end

  test "an applied push records the Paper as it stood before and as the push left it" do
    slug = paper!(blocks())
    before = row(slug)
    {bpml, rev} = pull(slug)

    assert json_response(sync(slug, String.replace(bpml, "Plain.", "Plain, edited."), rev), 200)
    now = row(slug)

    assert [pushed, left] = push_revisions(slug)

    assert {pushed.action, left.action} ==
             {PushRevision.before_action(), PushRevision.after_action()}

    for {stored, doc} <- [{pushed, before}, {left, now}] do
      assert {stored.content, stored.rev, stored.title} == {doc.content, doc.rev, doc.title}
      assert stored.type == "paper"
      assert stored.document_id == nil
      assert {stored.dataset, stored.dataset_id} == {doc.dataset, doc.dataset_id}
      assert {stored.workspace_id, stored.project_id} == {doc.workspace_id, doc.project_id}
    end

    # The document's revision pointer stays where it was.
    assert now.current_revision_id == before.current_revision_id
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

  test "a batch its before_commit check refuses rolls both revisions back with the write" do
    slug = paper!(blocks())
    count = length(revisions(slug))
    before = row(slug)
    op = %{"op" => "append-block", "block" => %{"id" => "p2", "type" => "paragraph"}}
    opts = [push_revisions: true, before_commit: fn _ -> {:error, :refused} end]

    assert {:error, :refused} = Content.apply_paper_block_ops(slug, [op], @ds, opts)
    assert length(revisions(slug)) == count
    assert row(slug).rev == before.rev
  end

  test "a push row that fails to insert rolls the write and the other row back" do
    slug = paper!(blocks())
    count = length(revisions(slug))
    before = row(slug)
    # A dataset that does not exist: the after row's insert fails its foreign key.
    gone = %Document{before | dataset_id: Ecto.UUID.generate()}

    assert {:error, {:push_revision_failed, after_action}} =
             Repo.transaction(fn ->
               before |> Ecto.Changeset.change(title: "Written.") |> Repo.update!()
               PushRevision.record(before, gone, @ds, push_revisions: true)
             end)

    assert after_action == PushRevision.after_action()
    assert length(revisions(slug)) == count
    assert row(slug).title == before.title
  end

  # A trigger in this test's own sandbox transaction (the DDL rolls back with
  # it) fails the insert of the revision row with `action` on its foreign key.
  defp fail_insert!(action) do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION push_revision_test_fail() RETURNS trigger AS $$
    BEGIN
      IF NEW.action = '#{action}' THEN
        RAISE EXCEPTION 'planted' USING ERRCODE = 'foreign_key_violation',
          CONSTRAINT = 'revisions_dataset_id_fkey';
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER push_revision_test_fail BEFORE INSERT ON revisions
    FOR EACH ROW EXECUTE FUNCTION push_revision_test_fail()
    """)
  end

  for action <- PushRevision.actions() do
    @action action
    test "through the sync route, a #{action} row that fails to insert answers 500 and writes nothing" do
      slug = paper!(blocks())
      count = length(revisions(slug))
      before = row(slug)
      {bpml, rev} = pull(slug)
      fail_insert!(@action)

      resp = sync(slug, String.replace(bpml, "Plain.", "Plain, edited."), rev)

      # A server fault, in the repo's server-error shape.
      assert json_response(resp, 500)["error"]["code"] == "internal_error"
      assert length(revisions(slug)) == count
      assert {row(slug).content, row(slug).rev} == {before.content, before.rev}
    end
  end

  test "history reads find it under its Paper's dataset only, and a restore restores the state before" do
    slug = paper!(blocks())
    before = row(slug)
    {bpml, rev} = pull(slug)
    assert json_response(sync(slug, String.replace(bpml, "Plain.", "Plain, edited."), rev), 200)
    [pushed, left] = push_revisions(slug)

    assert pushed.id in Enum.map(Content.list_revisions(slug, "paper", @ds), & &1.id)
    assert Content.list_revisions(slug, "paper", "other-dataset") == []
    assert {:ok, %Revision{}} = Content.get_revision(pushed.id, @ds)
    assert {:error, :not_found} = Content.get_revision(pushed.id, "other-dataset")
    # The lookup by `_rev` never answers with either row.
    for %{id: id, rev: rev} <- [pushed, left] do
      refute match?({:ok, %Revision{id: ^id}}, Content.get_revision_by_rev(rev, @ds))
    end

    assert {:ok, restored} = Content.restore_revision(pushed.id, "paper", @ds)
    assert restored.content["blocks"] == before.content["blocks"]
  end
end
