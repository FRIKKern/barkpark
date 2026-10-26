defmodule BarkparkWeb.MutateSanityAliasTest do
  @moduledoc """
  task-c6cbf346a07ff01e: @sanity/client writes to
  `/v<apiVersion>/data/mutate/<dataset>` with Sanity's semantics — a mutation
  writes exactly the id it names (a bare id is the published document,
  `drafts.<id>` the draft). The route rides the `/v1` mutate pipeline, so
  every write guard is the same; `/v1` keeps its own semantics.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @dataset "production"

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "msa-ws-#{suffix}", name: "Sanity alias"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "note",
          "title" => "Note",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, slug: ws.slug, ws_id: ws.id, scope: scope, writer: token!(ws.id, ["read", "write"])}
  end

  defp token!(ws_id, perms, role \\ nil) do
    raw = "msa-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "msa", @dataset, perms)
    {:ok, _} = TenancyAuth.create_membership(ws_id, token.id)

    if role do
      Membership
      |> Repo.get_by!(principal_id: token.id, principal_type: "api_token", workspace_id: ws_id)
      |> Ecto.Changeset.change(role: role)
      |> Repo.update!()
    end

    raw
  end

  defp post_m(slug, raw, version, mutations, query \\ "") do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/w/#{slug}/p/default/v#{version}/data/mutate/#{@dataset}#{query}",
      Jason.encode!(%{"mutations" => mutations, "transactionId" => "client-tx"})
    )
  end

  defp sanity(slug, raw, mutations, query \\ ""),
    do: post_m(slug, raw, "2025-02-19", mutations, query)

  defp row(id, scope) do
    case Content.get_document(id, "note", @dataset, scope) do
      {:ok, %{doc_id: ^id} = doc} -> doc
      _ -> nil
    end
  end

  defp note(id, title \\ "t"), do: %{"_type" => "note", "_id" => id, "title" => title}

  test "the dated route rides exactly the /v1 mutate pipeline" do
    info = fn v ->
      Phoenix.Router.route_info(
        BarkparkWeb.Router,
        "POST",
        "/w/a/p/b/v#{v}/data/mutate/ds",
        "localhost"
      )
    end

    assert info.("2025-02-19").pipe_through == info.("1").pipe_through
    assert info.("2025-02-19").plug == info.("1").plug
  end

  test "create / createOrReplace on a bare id write the published document, no draft", %{
    slug: slug,
    writer: w,
    scope: scope
  } do
    resp = sanity(slug, w, [%{"create" => note("a1")}, %{"createOrReplace" => note("a2", "two")}])
    assert resp.status == 200, resp.resp_body
    assert row("a1", scope) && row("a2", scope).title == "two"
    refute row("drafts.a1", scope) || row("drafts.a2", scope)

    # /v1 keeps Barkpark's draft-first create.
    assert post_m(slug, w, "1", [%{"create" => note("a3")}]).status == 200
    assert row("drafts.a3", scope)
    refute row("a3", scope)
  end

  test "create of an existing id is a conflict; createIfNotExists is a noop", %{
    slug: slug,
    writer: w,
    scope: scope
  } do
    assert sanity(slug, w, [%{"create" => note("b1", "first")}]).status == 200
    assert sanity(slug, w, [%{"create" => note("b1", "again")}]).status == 409
    assert sanity(slug, w, [%{"createIfNotExists" => note("b1", "again")}]).status == 200
    assert row("b1", scope).title == "first"
  end

  test "a drafts. id writes only the draft, as today", %{slug: slug, writer: w, scope: scope} do
    assert sanity(slug, w, [%{"createOrReplace" => note("drafts.c1")}]).status == 200
    assert row("drafts.c1", scope)
    refute row("c1", scope)
  end

  test "a write past a draft twin is refused 409 naming it, and the draft stays", %{
    slug: slug,
    writer: w,
    scope: scope
  } do
    assert sanity(slug, w, [%{"createOrReplace" => note("drafts.d1", "draft")}]).status == 200

    resp = sanity(slug, w, [%{"createOrReplace" => note("d1", "pub")}])
    assert resp.status == 409
    assert Jason.decode!(resp.resp_body)["error"]["message"] =~ "drafts.d1"
    assert row("drafts.d1", scope).title == "draft"
    refute row("d1", scope)
  end

  test "patch by bare id updates the published document; a missing id 404s", %{
    slug: slug,
    writer: w,
    scope: scope
  } do
    assert sanity(slug, w, [%{"create" => note("e1", "old")}]).status == 200

    assert sanity(slug, w, [%{"patch" => %{"id" => "e1", "set" => %{"title" => "new"}}}]).status ==
             200

    assert row("e1", scope).title == "new"
    refute row("drafts.e1", scope)

    assert sanity(slug, w, [%{"patch" => %{"id" => "nope", "set" => %{"title" => "x"}}}]).status ==
             404
  end

  test "delete by bare id keeps a draft twin, as on Sanity", %{
    slug: slug,
    writer: w,
    scope: scope
  } do
    assert sanity(slug, w, [%{"create" => note("f1")}, %{"create" => note("f2")}]).status == 200
    assert post_m(slug, w, "1", [%{"createOrReplace" => note("f1", "draft")}]).status == 200
    assert row("drafts.f1", scope)

    assert sanity(slug, w, [%{"delete" => %{"id" => "f1"}}, %{"delete" => %{"id" => "f2"}}]).status ==
             200

    refute row("f1", scope) || row("f2", scope)
    assert row("drafts.f1", scope).title == "draft"
  end

  # task-f456b589609f6a84: the client's (and Sanity Studio's) delete is
  # `transaction().delete(id).delete("drafts." <> id)`. A missing id is a noop
  # with no result row, as on Sanity; /v1 keeps its 404.
  test "delete(id) + delete(drafts.id) works when only one exists; a missing id is a noop", %{
    slug: slug,
    writer: w,
    scope: scope
  } do
    both = fn id -> [%{"delete" => %{"id" => id}}, %{"delete" => %{"id" => "drafts." <> id}}] end

    # Only the draft exists.
    assert post_m(slug, w, "1", [%{"createOrReplace" => note("dm1", "draft")}]).status == 200
    refute row("dm1", scope)
    resp = sanity(slug, w, both.("dm1"))

    assert %{"results" => [%{"id" => "drafts.dm1", "operation" => "delete"}]} =
             json_response(resp, 200)

    refute row("drafts.dm1", scope)

    # Only the published exists.
    assert sanity(slug, w, [%{"create" => note("dm2", "pub")}]).status == 200
    refute row("drafts.dm2", scope)
    resp = sanity(slug, w, both.("dm2"))
    assert %{"results" => [%{"id" => "dm2", "operation" => "delete"}]} = json_response(resp, 200)
    refute row("dm2", scope)

    # Neither exists: 200, no result rows.
    assert %{"results" => []} = json_response(sanity(slug, w, both.("dm3")), 200)

    # /v1 is unchanged: a missing id 404s.
    assert post_m(slug, w, "1", [%{"delete" => %{"id" => "dm3", "type" => "note"}}]).status == 404
  end

  # One test per row of the exact-id table that has a draft-twin case.
  test "every create kind and patch refuse 409 past a draft twin, and leave it", %{
    slug: slug,
    writer: w,
    scope: scope
  } do
    for {verb, id} <- [{"create", "t1"}, {"createIfNotExists", "t2"}, {"createOrReplace", "t3"}] do
      assert post_m(slug, w, "1", [%{"createOrReplace" => note(id, "draft")}]).status == 200
      resp = sanity(slug, w, [%{verb => note(id, "pub")}])
      assert resp.status == 409, "#{verb}: #{resp.status}"
      assert row("drafts." <> id, scope).title == "draft"
      refute row(id, scope)
    end

    # patch: a published x with a draft twin.
    assert sanity(slug, w, [%{"create" => note("t4", "pub")}]).status == 200
    assert post_m(slug, w, "1", [%{"createOrReplace" => note("t4", "draft")}]).status == 200

    assert sanity(slug, w, [%{"patch" => %{"id" => "t4", "set" => %{"title" => "x"}}}]).status ==
             409

    assert row("t4", scope).title == "pub" and row("drafts.t4", scope).title == "draft"
  end

  test "/v1 keeps Barkpark's semantics for the same mutations", %{
    slug: slug,
    writer: w,
    scope: scope
  } do
    # A bare-id patch on /v1 writes the draft; a bare-id delete takes both rows.
    assert sanity(slug, w, [%{"create" => note("v1a", "pub")}]).status == 200

    assert post_m(slug, w, "1", [
             %{"patch" => %{"id" => "v1a", "type" => "note", "set" => %{"title" => "d"}}}
           ]).status ==
             200

    assert row("drafts.v1a", scope).title == "d"
    assert row("v1a", scope).title == "pub"

    assert post_m(slug, w, "1", [%{"delete" => %{"id" => "v1a", "type" => "note"}}]).status == 200
    refute row("v1a", scope) || row("drafts.v1a", scope)
  end

  test "dryRun writes nothing", %{slug: slug, writer: w, scope: scope} do
    resp =
      sanity(slug, w, [%{"create" => note("g1")}], "?dryRun=true&returnIds=true&visibility=sync")

    assert resp.status == 200
    assert Jason.decode!(resp.resp_body)["dryRun"] == true
    refute row("g1", scope) || row("drafts.g1", scope)
  end

  test "a read-only and a contributor seat get the refusals a publish on /v1 gets", %{
    slug: slug,
    ws_id: ws_id,
    writer: w
  } do
    assert sanity(slug, w, [%{"create" => note("h1")}]).status == 200
    ro = token!(ws_id, ["read"])
    contributor = token!(ws_id, ["read", "write"], "contributor")

    for {label, raw} <- [read_only: ro, contributor: contributor] do
      v1 = post_m(slug, raw, "1", [%{"publish" => %{"id" => "h1", "type" => "note"}}]).status
      dated = sanity(slug, raw, [%{"createOrReplace" => note("h1", "x")}]).status
      assert v1 in [403, 422] and dated == v1, "#{label}: v1 #{v1}, dated #{dated}"
    end
  end

  test "transactionId in the body draws no unknown-key warning", %{slug: slug, writer: w} do
    body = sanity(slug, w, [%{"create" => note("i1")}]).resp_body |> Jason.decode!()
    refute Enum.any?(body["warnings"] || [], &(&1["code"] == "mutate.unknown_key"))
  end
end
