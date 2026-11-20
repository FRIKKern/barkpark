defmodule Barkpark.Content.Papers.SavedCheckScopeTest do
  @moduledoc """
  A checked write's saved row is checked for its scope inside the write's
  transaction, before the caller's own check, and fails closed:

    * a row whose project is not one of its workspace's is refused
      (`scope_unowned`), with or without a token;
    * a row in a workspace the writing token may not write in is refused
      (`write_forbidden`), on the upsert path and the block-op batch path; the
      rule is `WriteGate.may_write?/2` on the token's `WriteCaller` (its
      permission writes, and its home, a seat allowing write, or an armed
      operator allowlist naming it);
    * the write's `may_write:` predicate is asked, inside the transaction,
      about the saved row's own workspace; a no refuses;
    * a refusal leaves no row, history, change event or job, and an existing
      row is unchanged;
    * the view check refuses a row in a dataset with no `paper` schema, not
      the seeded one (`scope_unresolved`).

  A row in the token's own workspace and project is written and answered.
  The rows are written through `Content`, not through an HTTP door.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, LabelFixtures, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Content.Papers.BpmlView
  alias Barkpark.Plugins.Bulldocs.Web.WriteGate
  alias Barkpark.Tenancy.Membership
  alias BarkparkWeb.Plugs.AssignWriteCaller

  @ds "production"

  setup do
    LabelFixtures.register_tags!(@ds)
    %{a: tenant!(), b: tenant!()}
  end

  defp tenant! do
    ws = TenancyFixtures.create_workspace!()
    {:ok, project} = Tenancy.create_project_with_dataset(ws, %{name: "saved scope #{ws.slug}"})
    raw = "saved-scope-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "saved scope", @ds, ["admin"], ws.id)
    %{ws: ws, project: project, token: token}
  end

  defp slug, do: "saved-scope-#{System.unique_integer([:positive])}"

  defp blocks(text) do
    [
      %{"id" => "h", "type" => "heading", "level" => 2, "text" => "Saved scope"},
      %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
    ]
  end

  defp attrs(slug, ws_id, project_id) do
    LabelFixtures.paper_attrs(%{
      "slug" => slug,
      "blocks" => blocks("Visible."),
      "workspace_id" => ws_id,
      "project_id" => project_id
    })
  end

  defp checked(nil), do: checked_by(WriteGate.write_check(%{}))

  defp checked(token),
    do:
      checked_by(
        WriteGate.write_check(%{write_caller: AssignWriteCaller.build(token), api_token: token})
      )

  defp seatless! do
    raw = "saved-scope-op-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "saved scope op", @ds, ["admin"], nil)
    token
  end

  defp arm(ids) do
    prev = Application.get_env(:barkpark, :operator_token_ids, [])
    Application.put_env(:barkpark, :operator_token_ids, ids)
    on_exit(fn -> Application.put_env(:barkpark, :operator_token_ids, prev) end)
  end

  defp upsert(slug, ws, opts),
    do: Content.upsert_paper(attrs(slug, ws.ws.id, ws.project.id), opts)

  defp checked_by(may_write),
    do: [before_commit: BpmlView.saved_check(make_ref()), may_write: may_write]

  defp trace(slug) do
    %{
      rows:
        Repo.all(
          from d in Document,
            where: d.doc_id in ^[slug, "drafts." <> slug],
            select: {d.workspace_id, d.project_id, d.content, d.updated_at}
        ),
      history: length(Content.list_revisions(slug, "paper", @ds, [])),
      events: Repo.aggregate(from(e in MutationEvent, where: e.doc_id == ^slug), :count),
      jobs: Repo.aggregate(Oban.Job, :count)
    }
  end

  defp code({:error, {:view_refused, %{code: code}}}), do: code
  defp code(other), do: other

  test "a row in the token's own workspace and project is written", c do
    slug = slug()
    result = Content.upsert_paper(attrs(slug, c.b.ws.id, c.b.project.id), checked(c.b.token))
    assert {:ok, %Document{workspace_id: ws, project_id: proj}} = result
    assert {ws, proj} == {c.b.ws.id, c.b.project.id}
  end

  test "a pinned token writes in its home without a seat row; a seatless token does not", c do
    Repo.delete_all(from m in Membership, where: m.principal_id == ^c.b.token.id)
    assert Tenancy.Auth.authorize(c.b.token, c.b.ws.id, :write) != :ok
    assert {:ok, %Document{workspace_id: ws}} = upsert(slug(), c.b, checked(c.b.token))
    assert ws == c.b.ws.id

    slug = slug()
    before = trace(slug)
    assert code(upsert(slug, c.b, checked(seatless!()))) == "write_forbidden"
    assert trace(slug) == before
  end

  test "a seatless token on the armed operator allowlist writes; off it, refused", c do
    op = seatless!()
    arm([op.id])
    assert {:ok, %Document{workspace_id: ws}} = upsert(slug(), c.a, checked(op))
    assert ws == c.a.ws.id

    for ids <- [[], [seatless!().id]] do
      arm(ids)
      slug = slug()
      before = trace(slug)
      assert code(upsert(slug, c.a, checked(op))) == "write_forbidden"
      assert trace(slug) == before
    end
  end

  test "a row under another workspace's project is refused and leaves nothing", c do
    for writer <- [c.b.token, nil] do
      slug = slug()
      before = trace(slug)
      result = Content.upsert_paper(attrs(slug, c.b.ws.id, c.a.project.id), checked(writer))
      assert code(result) == "scope_unowned"
      assert trace(slug) == before
    end
  end

  test "a row in a workspace the token may not write in is refused and leaves nothing", c do
    slug = slug()
    before = trace(slug)
    result = Content.upsert_paper(attrs(slug, c.a.ws.id, c.a.project.id), checked(c.b.token))
    assert code(result) == "write_forbidden"
    assert trace(slug) == before
  end

  test "a block-op batch on a row the token may not write in is refused, the row unchanged",
       c do
    slug = slug()
    {:ok, _} = Content.upsert_paper(attrs(slug, c.a.ws.id, c.a.project.id))
    before = trace(slug)

    op = %{
      "op" => "insert-after",
      "afterId" => "p",
      "block" => %{"id" => "p2", "type" => "paragraph", "content" => []}
    }

    scope = [workspace_id: c.a.ws.id, project_id: c.a.project.id]
    result = Content.apply_paper_block_ops(slug, [op], @ds, scope ++ checked(c.b.token))

    assert code(result) == "write_forbidden"
    assert trace(slug) == before
  end

  test "a predicate saying no for the saved row's workspace refuses, leaving nothing", c do
    test = self()

    deny = fn ws_id ->
      send(test, {:asked, ws_id, Repo.in_transaction?()})
      false
    end

    slug = slug()
    before = trace(slug)
    result = Content.upsert_paper(attrs(slug, c.a.ws.id, c.a.project.id), checked_by(deny))
    assert code(result) == "write_forbidden"
    assert trace(slug) == before
    assert_received {:asked, ws_id, true}
    assert ws_id == c.a.ws.id

    {:ok, _} = Content.upsert_paper(attrs(slug, c.a.ws.id, c.a.project.id))
    before = trace(slug)
    block = %{"id" => "p3", "type" => "paragraph", "content" => []}
    op = %{"op" => "insert-after", "afterId" => "p", "block" => block}
    scope = [workspace_id: c.a.ws.id, project_id: c.a.project.id]
    result = Content.apply_paper_block_ops(slug, [op], @ds, scope ++ checked_by(deny))
    assert code(result) == "write_forbidden"
    assert trace(slug) == before
    assert_received {:asked, ^ws_id, true}
  end

  test "the view check refuses a row in a dataset with no paper schema (scope_unresolved)", c do
    # The seeded `paper` schemas are `production`'s; a dataset outside it with
    # none registered resolves no reader schema for any scope.
    ds = "saved-scope-noschema"

    row =
      Repo.insert!(%Document{
        doc_id: slug(),
        type: "paper",
        dataset: ds,
        title: "Saved scope",
        status: "published",
        rev: Content.Writer.generate_rev(),
        content: %{"blocks" => blocks("Visible.")},
        workspace_id: c.b.ws.id,
        project_id: c.b.project.id
      })

    assert Content.Papers.reader_schema(row, "paper", ds, []) == nil
    assert code(BpmlView.saved_check(make_ref()).(row)) == "scope_unresolved"
  end
end
