defmodule Barkpark.Plugins.Sheets.Web.ImportQuotaTest do
  @moduledoc """
  task-fa352596d025a916: `POST /v1/plugins/sheets/import` creates a sheet, but
  the `:ingest` pipeline's RequireWithinQuota cannot charge it a create (the
  router may not name the plugin's controller), so a FULL workspace still
  imported. The Sheets plugin now checks the room itself: 402 `quota_exceeded`
  and no sheet, while a workspace with room, or a re-import of an existing
  sheet, imports as before.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Quota

  @dataset "sheets_import_quota_ds"

  setup do
    slug = "sheets-quota-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: "Sheets quota"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    raw = "sheets-quota-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "sheets quota", @dataset, ["read", "write", "admin"], ws.id)
    {:ok, ws: ws, raw: raw}
  end

  defp import_sheet(raw, sheet) do
    path = Path.join(System.tmp_dir!(), "#{sheet}-#{System.unique_integer([:positive])}.csv")
    File.write!(path, "a,b\n1,2\n")
    on_exit(fn -> File.rm(path) end)

    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> post("/v1/plugins/sheets/import", %{
      "file" => %Plug.Upload{path: path, filename: "#{sheet}.csv", content_type: "text/csv"},
      "slug" => sheet,
      "dataset" => @dataset
    })
  end

  defp sheet?(ws, sheet),
    do:
      Enum.any?([sheet, "drafts." <> sheet], fn id ->
        match?({:ok, _}, Content.get_document(id, "sheet", @dataset, workspace_id: ws.id))
      end)

  test "a full workspace gets 402 quota_exceeded and no sheet", %{ws: ws, raw: raw} do
    {:ok, _} = Quota.set_quota(ws, Quota.usage(ws.id))

    conn = import_sheet(raw, "full-sheet")
    assert %{"error" => %{"code" => "quota_exceeded"}} = json_response(conn, 402)
    refute sheet?(ws, "full-sheet")
  end

  test "a workspace with room imports, and re-importing it when full still works", %{
    ws: ws,
    raw: raw
  } do
    assert %{"ok" => true} = json_response(import_sheet(raw, "room-sheet"), 200)
    assert sheet?(ws, "room-sheet")

    {:ok, _} = Quota.set_quota(ws, Quota.usage(ws.id))
    assert %{"ok" => true} = json_response(import_sheet(raw, "room-sheet"), 200)
  end
end
