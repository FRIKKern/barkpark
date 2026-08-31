defmodule BarkparkWeb.OptionalTokenSilentDowngradeTest do
  @moduledoc """
  RED-before demonstration (security hunt, OptionalToken fail-soft): a
  REVOKED or EXPIRED workspace-B bearer on the flat `/v1/data/query` read is
  silently downgraded to anonymous by `BarkparkWeb.Plugs.OptionalToken`
  (`Auth.verify_token/1` folds revoked/expired into `{:error, :unauthorized}`,
  the plug swallows the error), so `DeriveWorkspaceFromToken` never fires and
  `AssignDefaultScope` stamps the seeded DEFAULT workspace. The SAME request
  that answered workspace B's rows yesterday answers ANOTHER TENANT's
  (Default's) rows today, 200, with no signal — a tenant swap by credential
  decay, not a refusal.

  Not a confidentiality leak (Default's published/public data is
  anonymous-readable by design) — an INTEGRITY/mislead defect: an automated
  consumer (bp CLI, SDK, site build) holding a decayed token ingests the wrong
  tenant's content with no error to react to.

  The GREEN controls pin the two behaviors any fix must preserve:
    * a VALID workspace-B bearer keeps answering B's rows (flat-alias
      derivation, task-28c3f7f0987d6e85);
    * a request with NO bearer keeps serving the anonymous Default public
      read (the legitimate browser/public case a blanket 401 would break).

  A fix that turns ONLY presented-but-unverifiable bearers into a refusal on
  this surface leaves both controls green and does not touch
  `OptionalTokenTest` ("invalid Bearer token → passes through") — that test
  pins the PLUG's default contract, not this route's.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, TenancyFixtures}

  @dataset "production"
  @type_name "otsd-post"
  @raw_b "otsd-token-b-#{System.unique_integer([:positive])}"

  setup do
    {default_ws, default_project} = TenancyFixtures.ensure_default_scope!()
    default_scope = [workspace_id: default_ws.id, project_id: default_project.id]

    ws_b = TenancyFixtures.create_workspace!()
    project_b = TenancyFixtures.create_project!(ws_b)
    scope_b = [workspace_id: ws_b.id, project_id: project_b.id]

    seed_schema!(default_scope)
    seed_schema!(scope_b)

    seed_doc!("otsd-default-1", default_scope)
    seed_doc!("otsd-b-1", scope_b)

    {:ok, token_b} = Auth.create_token(@raw_b, "otsd-b", @dataset, ["read"], ws_b.id)

    %{token_b: token_b}
  end

  defp seed_schema!(scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => @type_name,
          "fields" => [%{"name" => "title", "type" => "string"}],
          # public so the anonymous tier can read it — the downgrade question
          # is about WHICH tenant answers, not visibility.
          "visibility" => "public"
        },
        @dataset,
        scope
      )
  end

  defp seed_doc!(doc_id, scope) do
    {:ok, doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => doc_id, "title" => doc_id, "content" => %{}},
        @dataset,
        scope
      )

    {:ok, published} = Content.publish_document(doc.doc_id, @type_name, @dataset, scope)
    published
  end

  defp authed(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp doc_ids(resp) do
    resp.resp_body
    |> Jason.decode!()
    |> get_in(["result", "documents"])
    |> List.wrap()
    |> Enum.map(& &1["_id"])
  end

  defp query_path, do: "/v1/data/query/#{@dataset}/#{@type_name}"

  # ── GREEN controls — what any fix must NOT break ──────────────────────────

  test "CONTROL — a VALID workspace-B bearer answers B's rows on the flat read",
       %{conn: conn} do
    resp = conn |> authed(@raw_b) |> get(query_path())

    assert resp.status == 200
    ids = doc_ids(resp)

    assert "otsd-b-1" in ids and "otsd-default-1" not in ids,
           "fixture/positive control broken: a valid B token must answer B's rows " <>
             "(got #{inspect(ids)}) — without this, the downgrade assertions below " <>
             "prove nothing"
  end

  test "CONTROL — NO bearer at all keeps the anonymous Default public read",
       %{conn: conn} do
    resp = get(conn, query_path())

    assert resp.status == 200

    assert "otsd-default-1" in doc_ids(resp),
           "the legitimate anonymous/browser public read must keep working — a fix " <>
             "that breaks THIS is the blanket-401 overreach the hunt brief forbids"
  end

  # ── RED-before — the silent tenant swap ───────────────────────────────────

  test "a REVOKED workspace-B bearer must not silently answer with the Default " <>
         "workspace's rows",
       %{conn: conn, token_b: token_b} do
    {:ok, _} = Auth.revoke_token(token_b)

    resp = conn |> authed(@raw_b) |> get(query_path())

    refute resp.status == 200 and "otsd-default-1" in doc_ids(resp),
           "OptionalToken swallowed the revoked bearer: the request was served as " <>
             "ANONYMOUS, AssignDefaultScope stamped the seeded Default workspace, and " <>
             "a caller that read workspace B yesterday now ingests ANOTHER TENANT's " <>
             "documents with a 200 and no signal (status=#{resp.status}, " <>
             "ids=#{inspect(doc_ids(resp))}). A presented-but-unverifiable bearer on " <>
             "this route should be refused (401), not tenant-swapped."
  end

  test "an EXPIRED workspace-B bearer must not silently answer with the Default " <>
         "workspace's rows",
       %{conn: conn, token_b: token_b} do
    past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
    {:ok, _} = token_b |> Ecto.Changeset.change(expires_at: past) |> Repo.update()

    resp = conn |> authed(@raw_b) |> get(query_path())

    refute resp.status == 200 and "otsd-default-1" in doc_ids(resp),
           "OptionalToken swallowed the expired bearer: same silent tenant swap as " <>
             "the revoked case (status=#{resp.status}, ids=#{inspect(doc_ids(resp))})."
  end
end
