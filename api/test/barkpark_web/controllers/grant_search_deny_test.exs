defmodule BarkparkWeb.GrantSearchDenyTest do
  @moduledoc """
  ag-deny-matrix — the SEARCH surface cell.

  `SearchController.search` rides `:api_grant_read` and threads `scope_opts/1`,
  so a grant-derived caller carries `grant_scoped: true` into
  `Content.search_documents/3`. This suite proves the DENY: a grantee's search
  over the granted dataset returns the in-scope hit and NEVER an out-of-scope
  document that matches the SAME query (a different type the grant doesn't
  cover), with an unowned-token positive control that DOES see both.

  ## SEALED (ag-search-grant-leak)

  The deny probe (2026-07-10) first proved the search surface did NOT honour the
  grant: `grant_scoped` was dropped in `QueryPipeline`'s `retriever_opts`
  (query_pipeline.ex ~99-116) and the Postgres `DocumentsRetriever` never called
  `maybe_scope_to_grants`, so a grantee's search returned out-of-scope hits.
  `ag-search-grant-leak` threads `grant_scoped` through `retriever_opts` and
  applies `Barkpark.Content.Scope.maybe_scope_to_grants/2` once on the retriever
  base query — the deny below is now LIVE (un-skipped) and green, protecting the
  fix. The positive control anchors the fixture.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Repo

  @password "correct-horse-battery"
  @ds "granted"
  # A rare term so nothing else in the seeded corpus matches.
  @term "zzqqxxsearchterm"

  setup do
    {ws, project} = ensure_default_scope!()

    for type <- ["post", "note"] do
      Content.upsert_schema(
        %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
        @ds
      )
    end

    seed = fn id, type, title ->
      {:ok, _} = create_document_in!(ws, project, type, %{"_id" => id, "title" => title}, @ds)
      {:ok, _} = Content.publish_document(id, type, @ds)
    end

    # Both match @term; the grant covers type "post" only, so the note is the
    # out-of-scope hit that a grant-narrowed search must drop.
    seed.("hit-post", "post", "#{@term} in-scope post")
    seed.("hit-note", "note", "#{@term} out-of-scope note")

    {:ok, ws: ws, project: project}
  end

  defp register_user do
    email = "grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp insert_token!(attrs) do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(
        Map.merge(
          %{
            token_hash: ApiToken.hash_token(raw),
            label: "t",
            dataset: "test",
            permissions: ["read"]
          },
          attrs
        )
      )
      |> Repo.insert()

    {raw, token}
  end

  defp titles(result), do: result["documents"] |> Enum.map(& &1["title"]) |> Enum.sort()

  defp search(conn, raw, q) do
    conn
    |> put_req_header("authorization", "Bearer #{raw}")
    |> get("/v1/data/search/#{@ds}?q=#{q}")
    |> json_response(200)
  end

  test "an unowned service token sees BOTH matching docs (positive control)", %{} do
    {raw, _} = insert_token!(%{})
    titles = titles(search(scoped_conn(), raw, @term))
    assert "#{@term} in-scope post" in titles
    assert "#{@term} out-of-scope note" in titles
  end

  # SEALED by ag-search-grant-leak: QueryPipeline now threads `grant_scoped`
  # into retriever_opts and the DocumentsRetriever base query applies
  # `Scope.maybe_scope_to_grants/2`, so a grantee's search is grant-narrowed.
  test "an owned-token grantee sees the in-scope post and NEVER the out-of-scope note",
       %{ws: ws, project: project} do
    user = register_user()
    {raw, _} = insert_token!(%{owner_user_id: user.id})
    bind_grant!(ws, user, %{project_id: project.id, dataset: @ds, type: "post"})

    result = search(scoped_conn(), raw, @term)
    titles = titles(result)

    # positive control: the in-grant document IS found
    assert "#{@term} in-scope post" in titles
    # DENY: the out-of-scope note (same query, uncovered type) is excluded
    refute "#{@term} out-of-scope note" in titles
  end
end
