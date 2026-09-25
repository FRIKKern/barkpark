defmodule BarkparkWeb.WorkspaceImportIntoDatasetTest do
  @moduledoc """
  `POST /api/workspaces/:workspace_slug/import?into_dataset=…&into_project=…`
  (task-9a458d67319697b3): the HTTP face of `WorkspaceBundle`'s `:into_dataset`
  option. A dataset bundle exported from workspace A lands as a NEW dataset in
  the workspace the URL names.

  Unlike a restore, the URL's workspace IS the target here, so the caller must
  hold write on it. The refusal test uses a token that passes this route's
  whole pipeline (global admin, no operator allowlist in test) and is refused
  ONLY because it is not a member of the target — the tenant check this path
  adds.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Tenancy.WorkspaceBundle

  @src "src"

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  # Global admin + a membership (admin role) in `ws` when given; with `nil`
  # the token's home is a fresh workspace, so it is a member of nothing else.
  defp admin_token(label, ws) do
    n = System.unique_integer([:positive])
    raw = "#{label}-#{n}"

    home =
      ws ||
        elem(Tenancy.create_workspace(%{slug: "#{label}-home-#{n}", name: "#{label} #{n}"}), 1)

    {:ok, _token} = Auth.create_token(raw, label, "test", ["read", "write", "admin"], home.id)
    raw
  end

  # Workspace A, dataset `src`: `a` references `b` by `_ref`, plus a content
  # edge a -> b. Returns the dataset-scoped bundle and the doc ids.
  defp source_bundle!(opts \\ []) do
    ws_a = TenancyFixtures.create_workspace!(unique("wsa"))
    proj_a = TenancyFixtures.create_project!(ws_a, unique("proja"))
    scope = [workspace_id: ws_a.id, project_id: proj_a.id]

    {:ok, b} = Content.create_document("post", %{"doc_id" => "b", "title" => "B"}, @src, scope)

    {:ok, a} =
      Content.create_document(
        "post",
        %{"doc_id" => "a", "title" => "A", "next" => %{"_ref" => "b"}},
        @src,
        scope
      )

    edge!(a.id, b.id)

    if opts[:dangling] do
      {:ok, o} =
        Content.create_document("post", %{"doc_id" => "o", "title" => "O"}, "other", scope)

      edge!(a.id, o.id)
    end

    {:ok, bundle} = WorkspaceBundle.export(ws_a.id, dataset: @src)
    %{bundle: bundle, ws_a: ws_a, a: a, b: b}
  end

  defp edge!(from, to) do
    Repo.query!(
      "INSERT INTO content_edges (id, from_id, to_id, kind, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2::text::uuid, 'next', now(), now())",
      [from, to]
    )
  end

  defp target! do
    ws_b = TenancyFixtures.create_workspace!(unique("wsb"))
    proj_b = TenancyFixtures.create_project!(ws_b, unique("projb"))
    %{ws_b: ws_b, proj_b: proj_b}
  end

  defp post_import(conn, raw, ws_slug, query, bundle) do
    conn
    |> authed(raw)
    |> put_req_header("content-type", "application/x-tar")
    |> post("/api/workspaces/#{ws_slug}/import?" <> URI.encode_query(query), bundle)
  end

  defp datasets_named(project_id, slug) do
    Repo.all(
      from d in Tenancy.Dataset,
        where: d.project_id == ^project_id and d.slug == ^slug,
        select: d.id
    )
  end

  defp docs_in(dataset_id) do
    Repo.query!(
      "SELECT doc_id, workspace_id::text FROM documents WHERE dataset_id = $1::text::uuid " <>
        "ORDER BY doc_id",
      [dataset_id]
    ).rows
  end

  describe "a member with write on the target imports a dataset as a new dataset" do
    test "200: the new dataset lands in the URL's workspace, re-keyed, references intact",
         %{conn: conn} do
      %{bundle: bundle, ws_a: ws_a} = source_bundle!()
      %{ws_b: ws_b, proj_b: proj_b} = target!()
      raw = admin_token("remap-op", ws_b)

      resp =
        post_import(
          conn,
          raw,
          ws_b.slug,
          %{into_dataset: "copy", into_project: proj_b.slug},
          bundle
        )
        |> json_response(200)

      assert resp["dataset"]["slug"] == "copy"
      assert resp["dataset"]["workspace_id"] == ws_b.id
      assert resp["dataset"]["project_id"] == proj_b.id
      assert resp["source"]["workspace_id"] == ws_a.id
      assert resp["tables"]["documents"] == 2
      assert resp["tables"]["content_edges"] == 1

      [new_id] = datasets_named(proj_b.id, "copy")
      assert resp["dataset"]["id"] == new_id
      assert docs_in(new_id) == [["drafts.a", ws_b.id], ["drafts.b", ws_b.id]]

      # The `_ref` in `a` names a document that exists in the new dataset.
      assert Repo.query!(
               "SELECT count(*) FROM documents r JOIN documents d " <>
                 "ON d.dataset_id = r.dataset_id AND d.doc_id IN (r.content->'next'->>'_ref', " <>
                 "'drafts.' || (r.content->'next'->>'_ref')) " <>
                 "WHERE r.dataset_id = $1::text::uuid AND r.doc_id = 'drafts.a'",
               [new_id]
             ).rows == [[1]]
    end
  end

  describe "authorization on the TARGET workspace" do
    test "403: a global-admin token that is not a member of the target is refused, nothing written",
         %{conn: conn} do
      %{bundle: bundle} = source_bundle!()
      %{ws_b: ws_b, proj_b: proj_b} = target!()
      outsider = admin_token("remap-outsider", nil)

      conn =
        post_import(
          conn,
          outsider,
          ws_b.slug,
          %{into_dataset: "copy", into_project: proj_b.slug},
          bundle
        )

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
      assert datasets_named(proj_b.id, "copy") == []
    end

    test "control: the same bundle and target succeed for a member (the 403 is the membership)",
         %{conn: conn} do
      %{bundle: bundle} = source_bundle!()
      %{ws_b: ws_b, proj_b: proj_b} = target!()
      member = admin_token("remap-member", ws_b)

      conn =
        post_import(
          conn,
          member,
          ws_b.slug,
          %{into_dataset: "copy", into_project: proj_b.slug},
          bundle
        )

      assert conn.status == 200
      assert length(datasets_named(proj_b.id, "copy")) == 1
    end

    test "404: an unknown target workspace or project", %{conn: conn} do
      %{bundle: bundle} = source_bundle!()
      %{ws_b: ws_b} = target!()
      raw = admin_token("remap-404", ws_b)

      assert post_import(
               conn,
               raw,
               "no-such-ws-#{unique("x")}",
               %{
                 into_dataset: "copy",
                 into_project: "default"
               },
               bundle
             ).status == 404

      assert post_import(
               scoped_conn(),
               raw,
               ws_b.slug,
               %{into_dataset: "copy", into_project: "nope"},
               bundle
             ).status ==
               404
    end
  end

  describe "refusals map to existing codes, with the engine's reason named" do
    test "409 conflict / dataset_slug_conflict when the project already has the slug",
         %{conn: conn} do
      %{bundle: bundle} = source_bundle!()
      %{ws_b: ws_b, proj_b: proj_b} = target!()
      raw = admin_token("remap-409", ws_b)
      query = %{into_dataset: "copy", into_project: proj_b.slug}

      assert post_import(conn, raw, ws_b.slug, query, bundle).status == 200

      err = post_import(scoped_conn(), raw, ws_b.slug, query, bundle) |> json_response(409)
      assert err["error"]["code"] == "conflict"
      assert err["error"]["reason"] == "dataset_slug_conflict"
      assert length(datasets_named(proj_b.id, "copy")) == 1
    end

    test "422 validation_failed / dangling_reference for an edge that leaves the dataset",
         %{conn: conn} do
      %{bundle: bundle} = source_bundle!(dangling: true)
      %{ws_b: ws_b, proj_b: proj_b} = target!()
      raw = admin_token("remap-422", ws_b)

      err =
        post_import(
          conn,
          raw,
          ws_b.slug,
          %{into_dataset: "copy", into_project: proj_b.slug},
          bundle
        )
        |> json_response(422)

      assert err["error"]["code"] == "validation_failed"
      assert err["error"]["reason"] == "dangling_reference"
      assert err["error"]["details"]["table"] == "content_edges"
      assert datasets_named(proj_b.id, "copy") == []
    end

    test "422 validation_failed for a malformed request, before the body is read",
         %{conn: conn} do
      %{ws_b: ws_b, proj_b: proj_b} = target!()
      raw = admin_token("remap-bad", ws_b)

      missing =
        post_import(conn, raw, ws_b.slug, %{into_dataset: "copy"}, "") |> json_response(422)

      assert missing["error"]["code"] == "validation_failed"
      assert missing["error"]["message"] =~ "into_project"

      merge =
        post_import(
          scoped_conn(),
          raw,
          ws_b.slug,
          %{into_dataset: "copy", into_project: proj_b.slug, mode: "merge"},
          ""
        )
        |> json_response(422)

      assert merge["error"]["code"] == "validation_failed"
      assert merge["error"]["message"] =~ "mode=clean"
    end
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
