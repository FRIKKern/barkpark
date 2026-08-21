defmodule BarkparkWeb.Integration.PublicReadClampIndependentDerivationTest do
  @moduledoc """
  INDEPENDENT re-derivation of the `dr-w2-s7` public-read visibility clamp
  (charter D17/D35, site-spawner D106) — written by an agent that did NOT build
  the slice, from `origin/main` bytes AFTER the merge commit.

  It is deliberately NOT a copy of `public_read_private_type_clamp_test.exs`:

    * the private type it seeds is `mediaAsset` — the type the LIVE census
      names as private and that the media surface also resolves — instead of
      the builder's synthetic `ledger`;
    * it drives the `{read}` and `{admin}` tiers as first-class cases rather
      than as controls on one door;
    * it pins the COUNT at zero, not only the row list, because a surviving
      count is an existence leak on its own.

  A green file here means the clamp holds against a fixture the builder never
  wrote. The MUTATION proof lives in the ledger entry
  `tooling/grip/ledger/dr-w2-independent-review-scoped-search-leak-2026-08-21.md`.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo}
  alias Barkpark.Media.Storage.MediaFile

  import Barkpark.TenancyFixtures

  @dataset "production"
  @probe "quixotrondev"

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp mint!(label, perms, ws_id) do
    raw = "#{label}-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, label, @dataset, perms, ws_id)
    raw
  end

  defp scoped(ws, proj, suffix), do: "/w/#{ws.slug}/p/#{proj.slug}#{suffix}"

  defp search(conn, token, ctx) do
    conn
    |> bearer(token)
    |> get(scoped(ctx.ws, ctx.proj, "/v1/data/search/#{@dataset}?q=#{@probe}"))
    |> json_response(200)
  end

  setup do
    ws = create_workspace!("idp-ws")
    proj = create_project!(ws, "idp-proj")
    scope = [workspace_id: ws.id, project_id: proj.id]

    # PRIVATE — `mediaAsset` is one of the 34 private schemas in the live census.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "mediaAsset",
          "title" => "Media Asset",
          "visibility" => "private",
          "fields" => []
        },
        @dataset,
        scope
      )

    file =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: "#{@probe}.png",
        original_name: "#{@probe}-original.png",
        path: "test/idp/#{@probe}.png",
        mime_type: "image/png",
        size: 42,
        dataset: @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      })
      |> Repo.insert!()

    {:ok, _} =
      Content.create_document(
        "mediaAsset",
        %{
          "_id" => "idp-asset",
          "title" => "Quixotrondev Secret Asset",
          "mediaFileId" => file.id,
          "rightsNote" => "CONFIDENTIAL-QUIXOTRONDEV"
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("idp-asset", "mediaAsset", @dataset, scope)

    %{
      ws: ws,
      proj: proj,
      mfile: file,
      public_read: mint!("idp-pr", ["public-read", "read"], ws.id),
      singleton: mint!("idp-pr1", ["public-read"], ws.id),
      read: mint!("idp-read", ["read"], ws.id),
      admin: mint!("idp-admin", ["read", "write", "admin"], ws.id)
    }
  end

  describe "scoped search door — independent re-derivation" do
    test "CONTROL: admin reads the private mediaAsset row (the seed is leak-observable)", ctx do
      ids = search(ctx.conn, ctx.admin, ctx) |> Map.fetch!("documents") |> Enum.map(& &1["_id"])

      assert "idp-asset" in ids,
             "seed is NOT leak-observable — a green clamp case below would prove nothing"
    end

    test "NON-REGRESSION: a {read}-only token is unaffected by the clamp", ctx do
      ids = search(ctx.conn, ctx.read, ctx) |> Map.fetch!("documents") |> Enum.map(& &1["_id"])

      assert "idp-asset" in ids,
             "the clamp moved more than one tier: a plain {read} token lost the private type"
    end

    test "a mixed [public-read, read] token is clamped — 200 with an empty result, never 403",
         ctx do
      body = search(ctx.conn, ctx.public_read, ctx)

      assert Enum.map(body["documents"], & &1["_id"]) == []
      assert body["count"] == 0, "the count survives the clamp — an existence leak on its own"
    end

    test "a singleton [public-read] token is clamped identically", ctx do
      body = search(ctx.conn, ctx.singleton, ctx)

      assert Enum.map(body["documents"], & &1["_id"]) == []
      assert body["count"] == 0
    end

    test "?type= narrowing onto the private type yields an empty 200, never its rows", ctx do
      body =
        ctx.conn
        |> bearer(ctx.public_read)
        |> get(
          scoped(ctx.ws, ctx.proj, "/v1/data/search/#{@dataset}?q=#{@probe}&types=mediaAsset")
        )
        |> json_response(200)

      assert Enum.map(body["documents"], & &1["_id"]) == []
      assert body["count"] == 0
    end
  end

  describe "scoped federated door — the second transport over the same retriever" do
    test "CONTROL: admin reads the private row on the documents surface", ctx do
      hits =
        ctx.conn
        |> bearer(ctx.admin)
        |> get(scoped(ctx.ws, ctx.proj, "/v1/search/#{@dataset}?q=#{@probe}"))
        |> json_response(200)
        |> get_in(["results", "documents", "hits"])

      assert "idp-asset" in Enum.map(hits || [], & &1["_id"])
    end

    test "a public-read token is clamped on the federated documents surface too", ctx do
      body =
        ctx.conn
        |> bearer(ctx.public_read)
        |> get(scoped(ctx.ws, ctx.proj, "/v1/search/#{@dataset}?q=#{@probe}"))
        |> json_response(200)

      assert get_in(body, ["results", "documents", "hits"]) == []
      assert get_in(body, ["results", "documents", "total"]) == 0
    end
  end
end
