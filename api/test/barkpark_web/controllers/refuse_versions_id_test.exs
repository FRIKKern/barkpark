defmodule BarkparkWeb.RefuseVersionsIdTest do
  @moduledoc """
  task-078175e759f71b73 — Sanity's Content Releases id convention,
  `versions.<release>.<id>`, has no analog in Barkpark: there is no
  release/version-set entity to resolve it against. Before this,
  `DraftId.draft_id/1` prepended "drafts." onto the WHOLE string
  unmodified, so a create (or createOrReplace/createIfNotExists/replace —
  the same `admitted_create_document/4` funnel) with `"_id":
  "versions.r1.post-02"` stored a document at `drafts.versions.r1.post-02`
  — an address nobody asked for and nothing resolves back to the release
  or the real document id.

  Refused at the write door instead, under the named code
  `versions_id_not_supported`: nothing is stored, and the error names the
  Sanity convention it rejects.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  setup do
    token = "barkpark-dev-token-versions-id-#{System.unique_integer([:positive])}"

    Auth.create_token(
      token,
      "dev",
      "versions-id-refusal",
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    %{token: token}
  end

  defp create(ctx, type, doc_id) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/test",
      Jason.encode!(%{
        "mutations" => [
          %{
            "create" => %{
              "_id" => doc_id,
              "_type" => type,
              "content" => %{"title" => "x"}
            }
          }
        ]
      })
    )
  end

  defp read_back(type, doc_id) do
    Content.get_document(Barkpark.Content.DraftId.draft_id(doc_id), type, "test")
  end

  test "a bare versions.<release>.<id> create is refused 422, named, and stores nothing", ctx do
    type = "rvid_#{System.unique_integer([:positive])}"
    doc_id = "versions.r1.post-02"

    resp = create(ctx, type, doc_id)

    assert resp.status == 422
    body = json_response(resp, 422)
    assert body["error"]["code"] == "versions_id_not_supported"
    assert body["error"]["details"]["id"] == doc_id
    assert body["error"]["message"] =~ "versions.r1.post-02"
    assert body["error"]["message"] =~ "Content Releases"
    assert Map.has_key?(body["error"], "hint")

    refute match?({:ok, _}, read_back(type, doc_id)),
           "the refused document must not exist under its plain id"

    refute match?({:ok, _}, read_back(type, "drafts." <> doc_id)),
           "the refused document must not exist under drafts.<versions id> either"
  end

  test "a caller-supplied drafts.versions.<release>.<id> is refused identically (same bare id after stripping)",
       ctx do
    type = "rvid_drafts_#{System.unique_integer([:positive])}"
    doc_id = "drafts.versions.r1.post-02"

    resp = create(ctx, type, doc_id)

    assert resp.status == 422
    body = json_response(resp, 422)
    assert body["error"]["code"] == "versions_id_not_supported"
    assert body["error"]["details"]["id"] == doc_id
  end

  test "an ordinary id is unaffected (control)", ctx do
    type = "rvid_ok_#{System.unique_integer([:positive])}"
    doc_id = "post-02"

    resp = create(ctx, type, doc_id)

    assert resp.status == 200
    assert {:ok, doc} = read_back(type, doc_id)
    assert doc.content["title"] == "x"
  end

  test "an id that merely CONTAINS \"versions.\" without starting with it is unaffected",
       ctx do
    type = "rvid_substr_#{System.unique_integer([:positive])}"
    doc_id = "my-versions.doc-1"

    resp = create(ctx, type, doc_id)

    assert resp.status == 200
    assert {:ok, _doc} = read_back(type, doc_id)
  end
end
