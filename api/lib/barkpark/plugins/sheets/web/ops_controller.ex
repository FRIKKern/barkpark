defmodule Barkpark.Plugins.Sheets.Web.OpsController do
  @moduledoc """
  POST /v1/plugins/sheets/:slug/ops — cell-granular AND structural wire
  ops (M1 + the grid editor's row/col/tab ops).

  Mounted by `Barkpark.Plugins.Sheets.register_routes/1` on the `:ingest`
  bucket (`RequireIngestToken`), the same bucket as import/export. A THIN
  shim: the body's `{"ops": [ … ]}` list goes straight through
  `Barkpark.Plugins.Sheets.Session.apply_ops/3` — the session (CORE) owns
  validation, serialization, recompute, delta broadcast and debounced
  persistence. The full op vocabulary (set_cell/clear_cell plus
  insert_rows/delete_rows/insert_cols/delete_cols, set_col_width/
  set_row_height, rename_tab/add_tab/delete_tab, and undo/redo) is
  documented in the Session moduledoc. Per-user undo/redo (M4): any op may
  carry a `"user"` string — the caller's identity (the ingest token is a
  shared secret, so identity rides the op itself) — which records that op
  on the user's inverse stack; `{"op":"undo","user":u}` /
  `{"op":"redo","user":u}` pop it.

      POST /v1/plugins/sheets/:slug/ops?dataset=production
      Authorization: Bearer <ingest token>
      {"ops": [{"op":"set_cell","tab":0,"ref":"A1","raw":"=SUM(B1:B3)"},
               {"op":"insert_rows","tab":0,"at":2,"count":3},
               {"op":"clear_cell","tab":0,"ref":"C9"}]}

  Responds `{ok, slug, rev, applied, errors}` — ops are applied
  INDIVIDUALLY (not atomically): invalid ops land in `errors` (with their
  list `index`) while the rest apply; `rev` is the session's monotonic
  applied-op counter. Whole-request errors: 404 for an unknown slug, 422
  when the body carries no `"ops"` list or the list exceeds the per-call
  batch bound (`Session.max_ops_per_call/0` — split and resend), 503 when
  the session died twice in a row (`session_unavailable` — retry shortly).
  """

  use BarkparkWeb, :controller

  alias Barkpark.Plugins.Sheets.Session

  @default_dataset "production"

  def apply_ops(conn, %{"slug" => slug, "ops" => ops} = params) when is_list(ops) do
    dataset =
      case params["dataset"] do
        d when is_binary(d) and d != "" -> d
        _ -> @default_dataset
      end

    case Session.apply_ops(slug, dataset, ops) do
      {:ok, result} ->
        json(conn, %{
          ok: true,
          slug: slug,
          rev: result.rev,
          applied: result.applied,
          errors: result.errors
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: %{code: "not_found", message: "no sheet #{inspect(slug)} in dataset #{inspect(dataset)}"}
        })

      {:error, :batch_too_large, n} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: "batch_too_large",
            message:
              "the ops list carries #{n} ops; the cap is #{Session.max_ops_per_call()} per call — split the batch"
          }
        })

      # The session died twice in a row (crash loop / restart window) —
      # transient by construction, so 503 + retry, not a 422.
      {:error, :session_unavailable} ->
        conn
        |> put_resp_header("retry-after", "2")
        |> put_status(:service_unavailable)
        |> json(%{
          error: %{code: "session_unavailable", message: "the sheet session is restarting — retry shortly"}
        })

      {:error, _other} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "session_unavailable", message: "the sheet session could not start"}})
    end
  end

  def apply_ops(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "malformed_ops", message: "the body must carry an \"ops\" list"}})
  end
end
