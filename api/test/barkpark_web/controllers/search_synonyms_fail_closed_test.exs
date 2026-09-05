defmodule BarkparkWeb.SearchSynonymsFailClosedTest do
  @moduledoc """
  Door 1 (D58/D71) — the flat admin synonym WRITE routes must FAIL-CLOSED on a
  nil-workspace token, on the DOCUMENTS surface (media twin lives in
  `media_synonyms_fail_closed_test.exs`).

  The three write handlers — `create_search_synonym`, `promote_search_synonym`,
  `delete_search_synonym` — resolved their tenant via `workspace_id(conn)` =
  `conn.assigns.current_workspace`, which `AssignDefaultScope` has ALREADY masked
  from nil to the Default Workspace. So a genuinely nil-workspace admin token
  POST/DELETE returned 200 and SILENTLY wrote (or deleted) the Default/global
  synonym row — the same footgun already closed for `update_search_settings`.

  The fix copies that settings wrapper verbatim: read the RAW pre-mask
  `conn.assigns.api_token.workspace_id` (assigned by `RequireToken`, BEFORE the
  mask) and return 422 `code=unprocessable` when nil, BEFORE any
  `Synonyms.{create,promote,delete}`. A workspace-bound admin token is unaffected.

  Reproducing a nil-workspace token: `Auth.create_token` binds an omitted
  `workspace_id` to Default post-backfill, so ONLY a direct `Repo.insert` with an
  explicit `workspace_id: nil` yields the legacy-null token this net catches.

  MUTATION-PROOF (fail-before): reverting the three `token_workspace_id ->
  nil_workspace_write_error` guards in `search_controller.ex` reds the nil-token
  tests below — create/promote return 200 with the leaked row in the body and
  the delete removes the seeded Default/global row. Restoring the guards greens
  them. NOTE: this test deliberately does NOT assert `row.workspace_id ==
  bound_ws.id` on the 200 path — that own-row guarantee only holds once Door 2
  (`bpb-search-intel-record-insights-pipeline-align`) is merged; the lead
  verifies it at merge.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Search.Synonym

  @ds "production"

  setup do
    # A Default Workspace must exist so the pre-fix path (masking nil → Default)
    # would have succeeded — that is exactly the 200-writing-Default footgun the
    # fail-closed guard replaces with a 422.
    {default_ws, _project} = ensure_default_scope!()
    {:ok, default_ws: default_ws}
  end

  # Mint an admin token straight through the schema changeset so `workspace_id`
  # can be forced to `nil` (create_token would bind it to Default).
  defp insert_admin_token!(attrs) do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, _token} =
      %ApiToken{}
      |> ApiToken.changeset(
        Map.merge(
          %{
            token_hash: ApiToken.hash_token(raw),
            label: "synonyms-admin",
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
        surface: "documents",
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

  describe "nil-workspace admin token — flat documents synonym WRITE routes" do
    test "POST synonyms is refused 422 and writes NO row" do
      raw = insert_admin_token!(%{workspace_id: nil})

      conn =
        auth(raw)
        |> post("/v1/data/search/#{@ds}/synonyms", %{"from" => "cat", "to" => "feline"})

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unprocessable"

      refute Repo.get_by(Synonym, surface: "documents", scope: @ds, from_query: "cat")
    end

    test "POST synonyms/promote is refused 422 and writes NO row" do
      raw = insert_admin_token!(%{workspace_id: nil})

      conn =
        auth(raw)
        |> post("/v1/data/search/#{@ds}/synonyms/promote", %{"from" => "dog", "to" => "canine"})

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unprocessable"

      refute Repo.get_by(Synonym, surface: "documents", scope: @ds, from_query: "dog")
    end

    test "DELETE synonyms/:id is refused 422 and the seeded row SURVIVES" do
      # Seed a legacy/global (NULL-workspace) row — exactly the row the pre-fix
      # nil-token DELETE would have silently removed.
      seeded = seed_synonym!(nil)
      raw = insert_admin_token!(%{workspace_id: nil})

      conn =
        auth(raw)
        |> delete("/v1/data/search/#{@ds}/synonyms/#{seeded.id}")

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unprocessable"

      assert Repo.get(Synonym, seeded.id), "seeded synonym must survive a refused delete"
    end
  end

  describe "legit workspace-bound admin token — NOT over-blocked" do
    test "POST synonyms writes a row (200)", %{default_ws: default_ws} do
      # A Default-bound admin token has a non-nil workspace, so the fail-closed
      # guard passes and the write proceeds — the operator path is not refused.
      raw = insert_admin_token!(%{workspace_id: default_ws.id})

      conn =
        auth(raw)
        |> post("/v1/data/search/#{@ds}/synonyms", %{"from" => "car", "to" => "automobile"})

      assert %{"result" => _} = json_response(conn, 200)

      # A row was written. We do NOT assert its workspace_id — that own-row
      # guarantee needs Door 2 merged (verified by the lead at merge).
      assert Repo.get_by(Synonym, surface: "documents", scope: @ds, from_query: "car")
    end
  end
end
