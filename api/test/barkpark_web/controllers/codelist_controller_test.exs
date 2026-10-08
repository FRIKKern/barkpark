defmodule BarkparkWeb.CodelistControllerTest do
  @moduledoc """
  task-93b24f20348f6df0 — `GET /w/:ws/p/:proj/v1/codelists/:codelist_id`
  reads a registered codelist over HTTP: values with their resolved label
  and parent code, by a plain member token.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content.Codelists}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    ws = create_workspace!("cl-#{System.unique_integer([:positive])}")
    project = create_project!(ws)

    member_raw = "cl-member-#{System.unique_integer([:positive])}"
    {:ok, member} = Auth.create_token(member_raw, "cl-member", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, member.id, "member", "api_token")

    list_id = "onixedit:cl-test-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Codelists.register("onixedit", list_id, %{
        issue: "1",
        name: "Test list",
        description: "a small flat list for the controller test",
        values: [
          %{
            code: "A01",
            translations: [
              %{language: "eng", label: "By (author)"},
              %{language: "nob", label: "Av (forfatter)"}
            ],
            children: [
              %{code: "A02", translations: [%{language: "eng", label: "With"}]}
            ]
          }
        ]
      })

    %{ws: ws, project: project, member_raw: member_raw, list_id: list_id}
  end

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp codelist_path(ws, project, list_id, query \\ nil) do
    base = "/w/#{ws.slug}/p/#{project.slug}/v1/codelists/#{list_id}"
    if query, do: base <> "?" <> query, else: base
  end

  test "a member token reads the codelist with its default (nob/eng) labels and parent codes",
       %{ws: ws, project: project, member_raw: raw, list_id: list_id} do
    conn = get(req(raw), codelist_path(ws, project, list_id))
    body = json_response(conn, 200)

    assert body["codelistId"] == list_id
    assert body["name"] == "Test list"
    assert [root] = body["values"]
    assert root["value"] == "A01"
    assert root["label"] == "Av (forfatter)"
    assert [child] = root["children"]
    assert child["value"] == "A02"
    assert child["label"] == "With"
  end

  test "?lang picks the label language", %{
    ws: ws,
    project: project,
    member_raw: raw,
    list_id: list_id
  } do
    conn = get(req(raw), codelist_path(ws, project, list_id, "lang=eng"))

    assert %{"values" => [%{"value" => "A01", "label" => "By (author)"}]} =
             json_response(conn, 200)
  end

  test "an unknown codelist id is a 404", %{ws: ws, project: project, member_raw: raw} do
    conn = get(req(raw), codelist_path(ws, project, "onixedit:no-such-list"))
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "an id with no plugin prefix is a 404, not a crash", %{
    ws: ws,
    project: project,
    member_raw: raw
  } do
    conn = get(req(raw), codelist_path(ws, project, "no-colon-here"))
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "an anonymous caller is refused", %{ws: ws, project: project, list_id: list_id} do
    conn = get(scoped_conn(), codelist_path(ws, project, list_id))
    assert conn.status in [401, 403]
  end
end
