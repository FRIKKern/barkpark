defmodule BarkparkWeb.PublicPaperPickerCasesTest do
  @moduledoc """
  task-e0349ff201949166: `/papers/<slug>` answers with two pickers, the
  revision plug's query (`PaperRevisionHeaders`) and the reader's resolver
  (`Content.get_public_paper/2`). Each case asserts that the body and the
  `x-barkpark-paper-revision` header name the same row, or that a 404 mints
  no validator. It pins what #29009 left unpinned: the tie order (oldest
  `inserted_at`, then `id`) and the Default seat read by `is_default`, not by
  the `default` slug. Adopted from the #29009 review's hunt.
  """
  use BarkparkWeb.ConnCase, async: false
  import Ecto.Query, only: [from: 2]
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @rev "x-barkpark-paper-revision"

  setup do
    {ws, p1} = Barkpark.TenancyFixtures.ensure_default_scope!()
    p2 = Barkpark.TenancyFixtures.create_project!(ws)
    other = Barkpark.TenancyFixtures.create_workspace!()
    ds = Content.paper_default_dataset()

    for p <- [p1, p2] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "paper",
            "title" => "Papers",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          ds,
          workspace_id: ws.id,
          project_id: p.id
        )
    end

    Barkpark.LabelFixtures.register_tags!(ds)

    %{
      ws: ws,
      p1: p1,
      p2: p2,
      other: other,
      ds: ds,
      slug: "hunt-#{System.unique_integer([:positive])}"
    }
  end

  defp paper!(c, p, text) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => c.slug,
          "title" => "T",
          "dataset" => c.ds,
          "workspace_id" => c.ws.id,
          "project_id" => p.id,
          "blocks" => [
            %{"id" => "h-1", "type" => "heading", "text" => "Title"},
            %{
              "id" => "b-1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => text}]
            }
          ]
        })
      )

    doc = Repo.reload!(doc)
    move!(doc, released_revision_id: doc.current_revision_id)
    %{doc | released_revision_id: doc.current_revision_id}
  end

  defp move!(doc, set),
    do: {1, _} = Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: set)

  defp served(conn, c) do
    conn = get(conn, "/papers/#{c.slug}")
    {html_response(conn, 200), get_resp_header(conn, @rev), get_resp_header(conn, "etag")}
  end

  defp nf(conn, path) do
    {404, headers, _} = assert_error_sent(404, fn -> get(conn, path) end)
    refute List.keymember?(headers, @rev, 0)
    refute List.keymember?(headers, "etag", 0)
  end

  @t0 ~U[2026-01-01 00:00:00.000000Z]
  @t1 ~U[2026-01-02 00:00:00.000000Z]

  test "A tie: p1 older", %{conn: conn} = c do
    a = paper!(c, c.p1, "Aaa words")
    b = paper!(c, c.p2, "Bbb words")
    move!(a, inserted_at: @t0)
    move!(b, inserted_at: @t1)
    {body, rev, _} = served(conn, c)
    assert body =~ "Aaa words"
    assert rev == [a.released_revision_id]
  end

  test "B tie: p2 older", %{conn: conn} = c do
    a = paper!(c, c.p1, "Aaa words")
    b = paper!(c, c.p2, "Bbb words")
    move!(a, inserted_at: @t1)
    move!(b, inserted_at: @t0)
    {body, rev, _} = served(conn, c)
    assert body =~ "Bbb words"
    assert rev == [b.released_revision_id]
  end

  test "C tie: equal inserted_at, id decides", %{conn: conn} = c do
    a = paper!(c, c.p1, "Aaa words")
    b = paper!(c, c.p2, "Bbb words")
    move!(a, inserted_at: @t0)
    move!(b, inserted_at: @t0)
    {body, rev, _} = served(conn, c)

    [win] =
      Enum.sort_by([a, b], & &1.id)
      |> Enum.take(1)

    assert rev == [win.released_revision_id]
    assert body =~ if(win.id == a.id, do: "Aaa words", else: "Bbb words")
  end

  test "D1 unpublished lone row: 404 no validator", %{conn: conn} = c do
    a = paper!(c, c.p1, "Aaa words")
    move!(a, status: "draft")
    nf(conn, "/papers/#{c.slug}")
  end

  test "D2 older unpublished + newer published", %{conn: conn} = c do
    a = paper!(c, c.p1, "Aaa words")
    b = paper!(c, c.p2, "Bbb words")
    move!(a, inserted_at: @t0, status: "draft")
    move!(b, inserted_at: @t1)
    {body, rev, _} = served(conn, c)
    assert body =~ "Bbb words"
    assert rev == [b.released_revision_id]
  end

  test "E other workspace older + default newer", %{conn: conn} = c do
    a = paper!(c, c.p1, "Aaa words")
    b = paper!(c, c.p2, "Bbb words")
    move!(a, inserted_at: @t0, workspace_id: c.other.id, project_id: nil)
    move!(b, inserted_at: @t1)
    {body, rev, _} = served(conn, c)
    assert body =~ "Bbb words"
    assert rev == [b.released_revision_id]
  end

  test "E2 other workspace lone row: 404 no validator", %{conn: conn} = c do
    a = paper!(c, c.p1, "Aaa words")
    move!(a, workspace_id: c.other.id, project_id: nil)
    nf(conn, "/papers/#{c.slug}")
  end

  test "F global older + default newer", %{conn: conn} = c do
    a = paper!(c, c.p1, "Aaa words")
    b = paper!(c, c.p2, "Bbb words")
    move!(a, inserted_at: @t0, workspace_id: nil, project_id: nil)
    move!(b, inserted_at: @t1)
    {body, rev, _} = served(conn, c)
    assert body =~ "Bbb words"
    assert rev == [b.released_revision_id]
  end

  test "G default seat whose slug is not default", %{conn: conn} = c do
    a = paper!(c, c.p1, "Aaa words")

    Repo.update_all(from(w in Barkpark.Tenancy.Workspace, where: w.id == ^c.ws.id),
      set: [slug: "renamed-#{System.unique_integer([:positive])}"]
    )

    {body, rev, _} = served(conn, c)
    assert body =~ "Aaa words"
    assert rev == [a.released_revision_id]
  end

  test "H owned newer + unowned older", %{conn: conn} = c do
    a = paper!(c, c.p1, "Aaa words")
    b = paper!(c, c.p2, "Bbb words")
    move!(a, inserted_at: @t0)
    move!(b, inserted_at: @t1, owner_id: Ecto.UUID.generate())
    {body, rev, _} = served(conn, c)
    assert body =~ "Aaa words"
    assert rev == [a.released_revision_id]
  end

  test "H2 all owned: 404 no validator", %{conn: conn} = c do
    a = paper!(c, c.p1, "Aaa words")
    b = paper!(c, c.p2, "Bbb words")
    move!(a, owner_id: Ecto.UUID.generate())
    move!(b, owner_id: Ecto.UUID.generate())
    nf(conn, "/papers/#{c.slug}")
  end

  test "I other dataset door: 404 no validator", %{conn: conn} = c do
    _ = paper!(c, c.p1, "Aaa words")
    nf(conn, "/d/nosuchds/papers/#{c.slug}")
  end

  test "J drafts. spelling: 404 no validator", %{conn: conn} = c do
    _ = paper!(c, c.p1, "Aaa words")
    nf(conn, "/papers/drafts.#{c.slug}")
  end

  test "K never-found slug: 404 no validator", %{conn: conn} do
    nf(conn, "/papers/no-such-#{System.unique_integer([:positive])}")
  end
end
