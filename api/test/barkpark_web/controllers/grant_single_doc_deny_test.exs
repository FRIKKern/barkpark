defmodule BarkparkWeb.GrantSingleDocDenyTest do
  @moduledoc """
  ag-deny-matrix — the SINGLE-DOC cells: `QueryController.show`
  (`/v1/data/doc/:ds/:type/:id`) and `QueryController.backlinks`
  (`/v1/data/backlinks/:ds/:id`), both on the flat `:api_grant_read` scope.

  A grantee scoped to (dataset "granted", type "post") must be served the
  in-scope doc/backlinks and DENIED (404 / empty envelope, never the doc) for an
  id outside the grant ladder, with an unowned-token positive control that DOES
  see the out-of-scope material.

  ## Both cells ENFORCE (backlinks sealed by `ag-backlinks-grant-leak`)

  `show` was always grant-narrowed — `Content.get_document/4` applies
  `maybe_scope_to_grants`, so an uncovered dataset OR type 404s (proven live
  below). `backlinks` originally LEAKED: `reverse_referencers` → `resolve_doc`
  + `docs_by_id` (graph.ex) applied only tenancy/owner scope, so a grantee read
  referencers for an uncovered dataset — the deny below was committed
  `@tag :skip` in #2145 as the executable reproduction. `ag-backlinks-grant-leak`
  sealed the shared graph helpers (`resolve_doc`/`scope_query` now apply
  `Scope.maybe_scope_to_grants/2`); the deny is un-skipped and LIVE, protecting
  the fix.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Repo

  @password "correct-horse-battery"
  @granted_ds "granted"
  @other_ds "other"

  setup do
    {ws, project} = ensure_default_scope!()

    for {type, ds} <- [{"post", @granted_ds}, {"post", @other_ds}, {"note", @granted_ds}] do
      Content.upsert_schema(
        %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
        ds
      )
    end

    seed = fn id, type, ds, title ->
      {:ok, _} = create_document_in!(ws, project, type, %{"_id" => id, "title" => title}, ds)
      {:ok, _} = Content.publish_document(id, type, ds)
    end

    # in-scope target (granted/post) + a granted/post referencer
    seed.("target-in", "post", @granted_ds, "in-scope target")
    seed.("ref-in", "post", @granted_ds, "in-scope referencer")

    Content.add_edges([%{from_id: "ref-in", to_id: "target-in", kind: "references"}],
      dataset: @granted_ds
    )

    # out-of-scope target (other/post) + an other/post referencer
    seed.("target-out", "post", @other_ds, "out-of-scope target")
    seed.("ref-out", "post", @other_ds, "out-of-scope referencer")

    Content.add_edges([%{from_id: "ref-out", to_id: "target-out", kind: "references"}],
      dataset: @other_ds
    )

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

  defp auth(conn, raw), do: put_req_header(conn, "authorization", "Bearer #{raw}")

  defp grantee(%{ws: ws, project: project}) do
    user = register_user()
    {raw, _} = insert_token!(%{owner_user_id: user.id})
    bind_grant!(ws, user, %{project_id: project.id, dataset: @granted_ds, type: "post"})
    raw
  end

  # ── show ──────────────────────────────────────────────────────────────────

  describe "QueryController.show — grant-narrowed single-doc read" do
    test "in-scope id is served; out-of-scope id (uncovered dataset) 404s", ctx do
      raw = grantee(ctx)

      in_resp = build_conn() |> auth(raw) |> get("/v1/data/doc/#{@granted_ds}/post/target-in")
      assert json_response(in_resp, 200)["result"]["_id"] == "target-in"

      out_resp = build_conn() |> auth(raw) |> get("/v1/data/doc/#{@other_ds}/post/target-out")
      assert out_resp.status == 404
    end

    test "out-of-scope id (uncovered TYPE, same dataset) 404s", ctx do
      raw = grantee(ctx)
      # a note lives in the granted dataset but the grant covers type post only
      {:ok, _} =
        create_document_in!(
          ctx.ws,
          ctx.project,
          "note",
          %{"_id" => "n1", "title" => "n"},
          @granted_ds
        )

      {:ok, _} = Content.publish_document("n1", "note", @granted_ds)

      resp = build_conn() |> auth(raw) |> get("/v1/data/doc/#{@granted_ds}/note/n1")
      assert resp.status == 404
    end

    test "positive control: an unowned token DOES see the out-of-scope doc", ctx do
      _ = ctx
      {raw, _} = insert_token!(%{})
      resp = build_conn() |> auth(raw) |> get("/v1/data/doc/#{@other_ds}/post/target-out")
      assert json_response(resp, 200)["result"]["_id"] == "target-out"
    end
  end

  # ── backlinks ───────────────────────────────────────────────────────────────

  describe "QueryController.backlinks — grant-narrowed reverse references" do
    defp backlink_titles(resp) do
      resp |> json_response(200) |> get_in(["result", "backlinks"]) |> Enum.map(& &1["title"])
    end

    test "in-scope target returns its referencer (positive control)", ctx do
      raw = grantee(ctx)
      resp = build_conn() |> auth(raw) |> get("/v1/data/backlinks/#{@granted_ds}/target-in")
      assert "in-scope referencer" in backlink_titles(resp)
    end

    # ag-backlinks-grant-leak SEALED: reverse_referencers now grant-narrows via
    # the shared graph helpers (resolve_doc/scope_query), so an uncovered-dataset
    # target resolves to nil → [] backlinks. (Was committed @tag :skip in #2145 as
    # the executable reproduction; unskipped + fixed in this PR.)
    test "out-of-scope target (uncovered dataset) returns empty backlinks", ctx do
      raw = grantee(ctx)
      resp = build_conn() |> auth(raw) |> get("/v1/data/backlinks/#{@other_ds}/target-out")
      assert backlink_titles(resp) == []
    end

    test "positive control: an unowned token DOES see the out-of-scope backlinks", ctx do
      _ = ctx
      {raw, _} = insert_token!(%{})
      resp = build_conn() |> auth(raw) |> get("/v1/data/backlinks/#{@other_ds}/target-out")
      assert "out-of-scope referencer" in backlink_titles(resp)
    end
  end
end
