defmodule BarkparkWeb.Contract.FederatedSearchDecayedBearerPerspectiveTest do
  @moduledoc """
  RESIDUE PIN — the half of the `?perspective=drafts` silent pin that the
  `OptionalToken` strict-on-presented fix (PR #14318) does NOT reach.

  THE PIPELINE SPLIT, which is the whole point of this file:

    * `GET /v1/data/query/:ds/:type` rides `[:api, :api_grant_read]` — the flat
      `/v1/data` read pipeline the parent fix mounts `strict_on_presented: true`
      on. A presented-but-unverifiable bearer will 401 there before it ever
      reaches the perspective logic. SUBSUMED.
    * `GET /v1/search/:dataset` (`FederatedSearchController`) rides BARE `:api`
      (api/lib/barkpark_web/router.ex — the "Federated discovery" scope). The
      parent fix does not mount there, and `Plugs.PublicRead` — the plug that
      turns a drafts request into a LOUD 403 — is mounted on `:api_grant_read`,
      `:shared_docs_api` and `:require_token`, never on bare `:api`.

  So on the federated route a decayed bearer is still silently downgraded to
  anonymous and still silently pinned to `:published` by
  `BarkparkWeb.AnonPerspective`.

  THE SIGNAL ASYMMETRY IS THE FINDING, stated precisely rather than maximally.
  `QueryController` echoes the perspective it ACTUALLY used at
  `result.perspective`, so a caller on `/v1/data/query` can detect the
  downgrade from the response envelope alone.
  `FederatedSearchController`'s body is
  `%{query, surfaces, results, searchEventId, ms}` — no perspective key at any
  level. Same downgrade, same instant, one route tells you and the other does
  not.

  HONEST QUALIFIER, pinned below so nobody reads this file as claiming more
  than it proves: the federated hits DO carry a per-row `_draft` boolean, so a
  caller that inspects every row can infer the downgrade — but only while the
  result set is NON-EMPTY. An empty page carries no indicator whatsoever, and
  there is no envelope-level echo to assert on. That is the gap.

  Population coverage note: the VALID `public-read` token half of this defect is
  already pinned in
  `test/barkpark_web/integration/public_read_search_matrix_test.exs`
  ("mixed public-read token + ?perspective=drafts is silently pinned"). This
  file pins the DECAYED-bearer half, which no test covered.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}

  @dataset "production"
  @type_name "fsdpost"
  @probe "wombatsearch"
  @garbage "garbage-not-a-real-token"

  setup do
    {ws, project} = ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @type_name, "title" => "FSDPost", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    # A PUBLISHED row and a DRAFT-ONLY row, both matching the probe query.
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => "fsd-pub", "title" => "#{@probe} Live Row"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("fsd-pub", @type_name, @dataset, scope)

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => "fsd-draft", "title" => "#{@probe} Secret Draft"},
        @dataset,
        scope
      )

    admin_raw = "fsd-admin-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(admin_raw, "fsd-admin", @dataset, ["read", "write", "admin"], ws.id)

    {:ok, admin: admin_raw}
  end

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp federated_body(conn, url) do
    resp = get(conn, url)
    assert resp.status == 200, "expected 200 on the federated route, got #{resp.status}"
    Jason.decode!(resp.resp_body)
  end

  defp hits(body), do: get_in(body, ["results", "documents", "hits"]) || []
  defp ids(body), do: Enum.map(hits(body), & &1["_id"])

  @drafts_url "/v1/search/#{@dataset}?q=#{@probe}&surfaces=documents&perspective=drafts"

  describe "decayed bearer on the federated route (bare :api — outside the parent fix)" do
    test "POSITIVE CONTROL: an admin token DOES read the seeded draft here", %{
      conn: conn,
      admin: admin
    } do
      body = conn |> bearer(admin) |> federated_body(@drafts_url)

      assert "drafts.fsd-draft" in ids(body),
             "seed is not leak-observable on the federated route — every negative " <>
               "assertion in this file would be vacuous. Got ids: #{inspect(ids(body))}"
    end

    test "a garbage bearer gets 200 with published-only rows (fails CLOSED)", %{conn: conn} do
      body = conn |> bearer(@garbage) |> federated_body(@drafts_url)

      # Positive half, so the refute below cannot pass on an empty page: the
      # query DOES return a row for this caller, it is just the wrong one.
      assert ids(body) == ["fsd-pub"],
             "expected exactly the published row; got #{inspect(ids(body))}"

      refute "drafts.fsd-draft" in ids(body)
    end

    test "RED: no envelope-level signal that the drafts request was downgraded", %{conn: conn} do
      body = conn |> bearer(@garbage) |> federated_body(@drafts_url)

      assert Map.has_key?(body, "perspective"),
             "federated search asked for ?perspective=drafts and answered with the " <>
               "PUBLISHED corpus, but the body carries no perspective key to say so. " <>
               "Body keys: #{inspect(Enum.sort(Map.keys(body)))}"

      assert body["perspective"] == "published"
    end

    test "QUALIFIER: a per-row _draft flag is the ONLY indicator, and it needs a non-empty page",
         %{conn: conn} do
      body = conn |> bearer(@garbage) |> federated_body(@drafts_url)

      # This is what a caller CAN see today — recorded so the RED above is not
      # read as "no information of any kind reaches the caller".
      assert Enum.all?(hits(body), &(&1["_draft"] == false))

      # And this is why it is not a substitute for an envelope echo: the
      # indicator lives on rows, so a zero-row answer carries nothing at all.
      empty = conn |> bearer(@garbage) |> federated_body(
                "/v1/search/#{@dataset}?q=zzznomatchzzz&surfaces=documents&perspective=drafts"
              )

      assert hits(empty) == []
      refute Map.has_key?(empty, "perspective")
    end

    test "CONTRAST: the flat /v1/data/query route DOES echo the perspective it used", %{
      conn: conn
    } do
      resp =
        conn
        |> bearer(@garbage)
        |> get("/v1/data/query/#{@dataset}/#{@type_name}?perspective=drafts")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      # This is the route the parent fix (#14318) covers, and it is ALREADY the
      # route that tells the caller the truth. The federated route above is
      # neither covered by that fix nor honest about the downgrade.
      assert body["result"]["perspective"] == "published",
             "expected the flat query route to echo its resolved perspective"

      assert Enum.map(body["result"]["documents"], & &1["_id"]) == ["fsd-pub"]
    end
  end
end
