defmodule BarkparkWeb.Integration.ReadTierDraftsPreviewTest do
  @moduledoc """
  Gyldendal E2 (task-73cf2bb9162353bf, criterion 0) — the token tier a preview
  pipeline needs, stated as a ROUTED contract: a `["read"]` token minted for a
  workspace reads that workspace's drafts and raw, and is refused every write.

  ## Why this file exists although nothing under `api/lib` had to change for it

  The twin's site credential was a `public-read` token. Asking it for
  `?perspective=drafts` answered `403 perspective not allowed` with the
  code-keyed default hint "use a token with write/admin permission" — which is
  the WRONG remedy: `read` is the tier that reads drafts without writing, it has
  been mintable since `bp token create <label> --permissions read`
  (`BarkparkWeb.TokenReadTierMintTest`), and the hint sent the customer off to
  build a tier that already existed. So this file pins the tier's contract on
  the real routes (the scoped `/w/:ws/p/:project/v1/...` mirror the twin uses)
  and the corrected hint on the clamp — the sentence that turns the 403 into a
  fix.

  ## The three arms

    1. READ TIER READS DRAFTS — `?perspective=drafts` returns the unpublished
       edit and the draft-only document; `raw` returns both twins. Same request
       with the public-read token: 403 + the hint naming the read tier.
    2. READ TIER WRITES NOTHING — mutate, schema apply and token mint all 403.
       Positive control: the same mutate with a write token lands.
    3. WORKSPACE-BOUND — a read token minted for a SIBLING workspace does not
       read this workspace's drafts (403: not a member).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}

  @dataset "production"

  setup do
    ws = create_workspace!("preview-ws")
    project = create_project!(ws, "preview-proj")
    scope = [workspace_id: ws.id, project_id: project.id]

    sibling_ws = create_workspace!("preview-sibling")
    _sibling_project = create_project!(sibling_ws, "preview-sibling-proj")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
        },
        @dataset,
        scope
      )

    # A published document WITH an unpublished edit on top of it …
    {:ok, _} =
      Content.create_document(
        "publication",
        %{"_id" => "pub-1", "title" => "Published title"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("pub-1", "publication", @dataset, scope)

    {:ok, _} =
      Content.create_document(
        "publication",
        %{"_id" => "pub-1", "title" => "Draft edit"},
        @dataset,
        scope
      )

    # … and a document that only exists as a draft.
    {:ok, _} =
      Content.create_document(
        "publication",
        %{"_id" => "pub-draft-only", "title" => "Never published"},
        @dataset,
        scope
      )

    suffix = System.unique_integer([:positive])
    read_raw = "read-tier-#{suffix}"
    public_raw = "public-tier-#{suffix}"
    write_raw = "write-tier-#{suffix}"
    sibling_raw = "sibling-read-#{suffix}"

    {:ok, _} = Auth.create_token(read_raw, "twin-drafts-read", @dataset, ["read"], ws.id)
    {:ok, _} = Auth.create_token(public_raw, "twin-public", @dataset, ["public-read"], ws.id)
    {:ok, _} = Auth.create_token(write_raw, "twin-write", @dataset, ["read", "write"], ws.id)

    {:ok, _} =
      Auth.create_token(sibling_raw, "sibling-read", @dataset, ["read"], sibling_ws.id)

    %{
      ws: ws,
      project: project,
      read: read_raw,
      public: public_raw,
      write: write_raw,
      sibling: sibling_raw
    }
  end

  defp scoped(ws, project, suffix), do: "/w/#{ws.slug}/p/#{project.slug}/v1/#{suffix}"
  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp titles(body) do
    docs = get_in(body, ["result", "documents"]) || body["documents"] || []
    docs |> Enum.map(& &1["title"]) |> Enum.sort()
  end

  describe "arm 1 — the read tier reads drafts and raw" do
    test "perspective=drafts returns the unpublished edit and the draft-only document", %{
      conn: conn,
      ws: ws,
      project: project,
      read: read
    } do
      body =
        conn
        |> authed(read)
        |> get(scoped(ws, project, "data/query/#{@dataset}/publication?perspective=drafts"))
        |> json_response(200)

      assert titles(body) == ["Draft edit", "Never published"]
    end

    test "perspective=raw returns both twins of the edited document", %{
      conn: conn,
      ws: ws,
      project: project,
      read: read
    } do
      body =
        conn
        |> authed(read)
        |> get(scoped(ws, project, "data/query/#{@dataset}/publication?perspective=raw"))
        |> json_response(200)

      assert titles(body) == ["Draft edit", "Never published", "Published title"]
    end

    test "the published perspective is unchanged for the read tier", %{
      conn: conn,
      ws: ws,
      project: project,
      read: read
    } do
      body =
        conn
        |> authed(read)
        |> get(scoped(ws, project, "data/query/#{@dataset}/publication"))
        |> json_response(200)

      assert titles(body) == ["Published title"]
    end

    test "the same drafts request with a public-read token is refused — and the hint names the read tier",
         %{conn: conn, ws: ws, project: project, public: public} do
      body =
        conn
        |> authed(public)
        |> get(scoped(ws, project, "data/query/#{@dataset}/publication?perspective=drafts"))
        |> json_response(403)

      assert body["error"]["code"] == "forbidden"
      assert body["error"]["message"] == "perspective not allowed"

      assert body["error"]["hint"] =~ "READ-tier token",
             "the hint must name the tier that actually reads drafts, got: " <>
               inspect(body["error"]["hint"])

      assert body["error"]["hint"] =~ "--permissions read"
      refute body["error"]["hint"] =~ "write/admin"
    end
  end

  describe "arm 2 — the read tier writes nothing" do
    test "mutate is refused (403), and the same mutate with a write token lands", %{
      conn: conn,
      ws: ws,
      project: project,
      read: read,
      write: write
    } do
      mutations = %{
        "mutations" => [
          %{"patch" => %{"id" => "pub-1", "type" => "publication", "set" => %{"title" => "Nope"}}}
        ]
      }

      refused =
        conn
        |> authed(read)
        |> post(scoped(ws, project, "data/mutate/#{@dataset}"), mutations)

      assert refused.status == 403,
             "read tier mutate answered #{refused.status}: #{refused.resp_body}"

      landed =
        build_conn()
        |> authed(write)
        |> post(scoped(ws, project, "data/mutate/#{@dataset}"), mutations)

      assert landed.status in 200..299,
             "positive control: write tier mutate answered #{landed.status}: #{landed.resp_body}"
    end

    test "schema apply is refused (403)", %{conn: conn, ws: ws, project: project, read: read} do
      refused =
        conn
        |> authed(read)
        |> post(scoped(ws, project, "schemas/#{@dataset}"), %{
          "name" => "probe",
          "title" => "Probe",
          "fields" => []
        })

      assert refused.status == 403, "read tier schema apply answered #{refused.status}"
    end

    test "minting another token is refused (403 — the mint is admin-role gated)", %{
      conn: conn,
      ws: ws,
      project: project,
      read: read
    } do
      refused =
        conn
        |> authed(read)
        |> post(scoped(ws, project, "tokens"), %{"label" => "escalate", "permissions" => ["read"]})

      assert refused.status == 403, "read tier token mint answered #{refused.status}"
    end
  end

  describe "arm 3 — workspace-bound" do
    test "a read token from a sibling workspace does not read this workspace's drafts", %{
      conn: conn,
      ws: ws,
      project: project,
      sibling: sibling
    } do
      resp =
        conn
        |> authed(sibling)
        |> get(scoped(ws, project, "data/query/#{@dataset}/publication?perspective=drafts"))

      assert resp.status in [403, 404],
             "sibling read token answered #{resp.status}: #{String.slice(resp.resp_body, 0, 200)}"

      refute resp.resp_body =~ "Draft edit"
      refute resp.resp_body =~ "Never published"
    end
  end
end
