defmodule BarkparkWeb.MediaSynonymsFailClosedTest do
  @moduledoc """
  Door 1 (D58/D71) — the flat admin synonym WRITE routes must FAIL-CLOSED on a
  nil-workspace token, on the MEDIA surface (documents twin lives in
  `search_synonyms_fail_closed_test.exs`).

  The three write handlers in `V1.MediaController` —
  `create_search_synonym`, `promote_search_synonym`, `delete_search_synonym` —
  resolved their tenant via `workspace_id(conn)` = `conn.assigns.current_workspace`,
  which `AssignDefaultScope` has ALREADY masked from nil to the Default Workspace.
  A genuinely nil-workspace admin token POST/DELETE therefore returned 200 and
  SILENTLY wrote (or deleted) the Default/global media synonym row.

  The fix copies the `update_search_settings` wrapper verbatim: read the RAW
  pre-mask `conn.assigns.api_token.workspace_id` and return 422
  `code=unprocessable` when nil, BEFORE any `Synonyms.{create,promote,delete}`.

  MUTATION-PROOF (fail-before): reverting the three guards in
  `v1/media_controller.ex` reds the nil-token tests below — create/promote return
  200 with the leaked row in the body and the delete removes the seeded
  Default/global row. Restoring the guards greens them. This test deliberately
  does NOT assert `row.workspace_id == bound_ws.id` on the 200 path — that own-row
  guarantee only holds once Door 2 is merged (lead verifies at merge).
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Search.Synonym

  @ds "production"

  setup do
    {default_ws, _project} = ensure_default_scope!()
    {:ok, default_ws: default_ws}
  end

  defp insert_admin_token!(attrs) do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, _token} =
      %ApiToken{}
      |> ApiToken.changeset(
        Map.merge(
          %{
            token_hash: ApiToken.hash_token(raw),
            label: "media-synonyms-admin",
            dataset: @ds,
            permissions: ["read", "write", "admin"]
          },
          attrs
        )
      )
      |> Repo.insert()

    raw
  end

  defp seed_synonym!(workspace_id) do
    {:ok, row} =
      %Synonym{}
      |> Synonym.changeset(%{
        surface: "media",
        scope: @ds,
        from_query: "seeded-from",
        to_query: "seeded-to",
        kind: "one_way",
        source: "manual",
        workspace_id: workspace_id
      })
      |> Repo.insert()

    row
  end

  defp auth(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  describe "nil-workspace admin token — flat media synonym WRITE routes" do
    test "POST synonyms is refused 422 and writes NO row" do
      raw = insert_admin_token!(%{workspace_id: nil})

      conn =
        auth(raw)
        |> post("/v1/media/#{@ds}/search/synonyms", %{"from" => "cat", "to" => "feline"})

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unprocessable"

      refute Repo.get_by(Synonym, surface: "media", scope: @ds, from_query: "cat")
    end

    test "POST synonyms/promote is refused 422 and writes NO row" do
      raw = insert_admin_token!(%{workspace_id: nil})

      conn =
        auth(raw)
        |> post("/v1/media/#{@ds}/search/synonyms/promote", %{"from" => "dog", "to" => "canine"})

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unprocessable"

      refute Repo.get_by(Synonym, surface: "media", scope: @ds, from_query: "dog")
    end

    test "DELETE synonyms/:id is refused 422 and the seeded row SURVIVES" do
      seeded = seed_synonym!(nil)
      raw = insert_admin_token!(%{workspace_id: nil})

      conn =
        auth(raw)
        |> delete("/v1/media/#{@ds}/search/synonyms/#{seeded.id}")

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unprocessable"

      assert Repo.get(Synonym, seeded.id), "seeded synonym must survive a refused delete"
    end
  end

  describe "legit workspace-bound admin token — NOT over-blocked" do
    test "POST synonyms writes a row (200)", %{default_ws: default_ws} do
      raw = insert_admin_token!(%{workspace_id: default_ws.id})

      conn =
        auth(raw)
        |> post("/v1/media/#{@ds}/search/synonyms", %{"from" => "car", "to" => "automobile"})

      assert %{"result" => _} = json_response(conn, 200)

      assert Repo.get_by(Synonym, surface: "media", scope: @ds, from_query: "car")
    end
  end
end
