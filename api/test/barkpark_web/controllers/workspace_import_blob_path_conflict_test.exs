defmodule BarkparkWeb.WorkspaceImportBlobPathConflictTest do
  @moduledoc """
  The HTTP edge of the cross-tenant blob-path refusal (task-918106d49c62563e).

  The engine rolls a colliding import back with
  `{:error, {:blob_path_conflict, info}}`. Without a clause naming it, that term
  falls to `import_failed` — a 500 that tells an operator nothing actionable
  about WHICH paths collided.

  EMITTER PARITY is the point of this file. This repo's import error emitters are
  DUPLICATED per arm — `clean_import/3` and `merge_import/3` each pattern-match
  their own error terms — so a clause added to one arm and not the other is a
  half fix that reads as done. Both arms are driven here, over the REAL HTTP
  route, through the `:import_fault` seam (the same seam
  `workspace_controller_test.exs` uses to pin the `import_failed` 500).
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Tenancy}
  alias Barkpark.Tenancy.WorkspaceBundle

  @conflict {:error,
             {:blob_path_conflict,
              %{
                workspace_id: "11111111-1111-1111-1111-111111111111",
                count: 2,
                sample: [
                  %{
                    path: "2026/08/collide.png",
                    owner_workspace_id: "22222222-2222-2222-2222-222222222222"
                  }
                ]
              }}}

  setup do
    Application.put_env(:barkpark, :allow_bundle_import, true)
    Application.put_env(:barkpark, :import_fault, @conflict)

    on_exit(fn ->
      Application.delete_env(:barkpark, :allow_bundle_import)
      Application.delete_env(:barkpark, :import_fault)
    end)

    raw = "ws-blobconflict-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "ws admin", "test", ["read", "write", "admin"])

    {:ok, target} =
      Tenancy.create_workspace_with_owner(%{name: "Blob Conflict WS"}, token)

    {:ok, bundle} = WorkspaceBundle.export(target.id)

    %{raw: raw, target: target, bundle: bundle}
  end

  defp post_import(conn, raw, target, bundle, query) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/x-tar")
    |> post("/api/workspaces/#{target.slug}/import#{query}", bundle)
  end

  for {arm, query} <- [{"clean", ""}, {"merge", "?mode=merge"}] do
    test "the #{arm} arm answers 409 blob_path_conflict naming the colliding paths", %{
      conn: conn,
      raw: raw,
      target: target,
      bundle: bundle
    } do
      resp = post_import(conn, raw, target, bundle, unquote(query))

      assert resp.status == 409
      err = Jason.decode!(resp.resp_body)["error"]

      assert err["code"] == "blob_path_conflict",
             "the #{unquote(arm)} arm mislabelled the refusal as #{inspect(err["code"])} — " <>
               "the import emitters are duplicated per arm, so a one-arm clause is a half fix"

      assert err["details"]["count"] == 2

      assert Enum.map(err["details"]["sample"], & &1["path"]) == ["2026/08/collide.png"],
             "the operator cannot act on a refusal that does not name the colliding path"
    end
  end
end
