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
  set_row_height, rename_tab/add_tab/delete_tab, merge_cells/unmerge_cells,
  and undo/redo) is documented in the Session moduledoc. Per-user undo/redo (M4): any op may
  carry a `"user"` string — the caller's identity (the ingest token is a
  shared secret, so identity rides the op itself) — which records that op
  on the user's inverse stack; `{"op":"undo","user":u}` /
  `{"op":"redo","user":u}` pop it.

      POST /v1/plugins/sheets/:slug/ops?dataset=production
      Authorization: Bearer <ingest token>
      {"ops": [{"op":"set_cell","tab":0,"ref":"A1","raw":"=SUM(B1:B3)"},
               {"op":"insert_rows","tab":0,"at":2,"count":3},
               {"op":"clear_cell","tab":0,"ref":"C9"}]}

  Responds `{ok, slug, rev, epoch, applied, errors, replayed}` — ops are
  applied INDIVIDUALLY (not atomically): invalid ops land in `errors` (with
  their list `index`) while the rest apply; `rev` is the session's applied-op
  counter, monotonic WITHIN one session incarnation (an idle-stopped or
  restarted session re-counts from 0 — `epoch` disambiguates incarnations;
  treat a changed `epoch` as "refetch, then trust `rev` again").
  Whole-request errors: 404 for an unknown slug, 422
  when the body carries no `"ops"` list or the list exceeds the per-call
  batch bound (`Session.max_ops_per_call/0` — split and resend), 503 when
  the session died twice in a row (`session_restarting` — retry shortly); a
  session that could not start at all answers 422 `session_start_failed`.

  ## Exactly-once retry (`request_id`)

  An OPTIONAL top-level `"request_id"` (a non-empty string ≤ 200 bytes) makes
  the batch idempotent under retry: the FIRST request with a given
  `request_id` applies and caches its reply; a LATER request with the SAME
  `request_id` replays that reply with `replayed: true` and applies NOTHING —
  so a re-sent non-idempotent batch (`insert_rows` after a lost response or a
  503) never double-applies. Absent `request_id` is byte-identical to the
  pre-feature behavior (`replayed: false`, every call applies). A present
  `request_id` of any other shape (empty string, > 200 bytes, non-string) is
  refused 422 `invalid_request_id` — a CONTROLLER-envelope error (the
  `batch_too_large` precedent), NOT a session op code. Idempotency-key
  semantics: the SAME `request_id` with DIFFERENT ops returns the FIRST
  request's reply. The ring is node-local and cleared by a BEAM restart (the
  sessions die with it) — see the `Session` moduledoc for the full contract
  and accepted residuals.
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

    with {:ok, request_id} <- fetch_request_id(params),
         {:ok, result} <- Session.apply_ops(slug, dataset, ops, request_id) do
      json(conn, %{
        ok: true,
        slug: slug,
        rev: result.rev,
        epoch: result.epoch,
        applied: result.applied,
        errors: result.errors,
        replayed: Map.get(result, :replayed, false)
      })
    else
      # A present-but-malformed request_id is a controller-envelope 422
      # (the batch_too_large precedent), NOT a session op code.
      :invalid_request_id ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: "invalid_request_id",
            message: "request_id must be a non-empty string of at most 200 bytes"
          }
        })

      other ->
        apply_ops_error(conn, slug, dataset, other)
    end
  end

  def apply_ops(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "malformed_ops", message: "the body must carry an \"ops\" list"}})
  end

  # Absent (or JSON null) → nil, byte-identical to the pre-feature path. A
  # non-empty string ≤ 200 bytes threads through as the idempotency key.
  # Anything else present → :invalid_request_id (422 at the caller).
  defp fetch_request_id(params) do
    case params["request_id"] do
      nil -> {:ok, nil}
      rid when is_binary(rid) and rid != "" and byte_size(rid) <= 200 -> {:ok, rid}
      _ -> :invalid_request_id
    end
  end

  defp apply_ops_error(conn, slug, dataset, result) do
    case result do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: %{
            code: "not_found",
            message: "no sheet #{inspect(slug)} in dataset #{inspect(dataset)}"
          }
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
          error: %{
            code: "session_restarting",
            message: "the sheet session is restarting — retry shortly"
          }
        })

      {:error, _other} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "session_start_failed", message: "the sheet session could not start"}
        })
    end
  end
end
