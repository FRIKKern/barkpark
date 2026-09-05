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
  session that could not start at all answers 422 `session_start_failed`. A
  request carrying a `request_id` answers 503 `replay_unavailable` (+
  `retry-after`) when the exactly-once ring cannot be read at all — the batch
  was NOT applied; retry.

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

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @default_dataset "production"

  def apply_ops(conn, %{"slug" => slug, "ops" => ops} = params) when is_list(ops) do
    dataset =
      case params["dataset"] do
        d when is_binary(d) and d != "" -> d
        _ -> @default_dataset
      end

    with {:ok, request_id} <- fetch_request_id(params),
         :ok <- check_batch_size(ops),
         {:ok, doc} <- authorize_sheet(conn, slug, dataset),
         {:ok, result} <-
           Session.apply_ops(slug, dataset, ops, request_id, doc.workspace_id) do
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

  # The whole-request SHAPE rejections (`malformed_ops` via the second
  # `apply_ops/2` clause, `invalid_request_id`, `batch_too_large`) stay AHEAD of
  # the tenant gate below, so their contract is byte-identical to before it
  # existed — an oversized batch is still 422, never a 404 that hides why.
  # The cap constant is NOT forked: it is read from `Session.max_ops_per_call/0`,
  # the one owner, which re-checks it anyway inside `apply_ops/4`.
  defp check_batch_size(ops) do
    max = Session.max_ops_per_call()

    case length(ops) do
      n when n > max -> {:error, :batch_too_large, n}
      _ -> :ok
    end
  end

  # The sheet must exist IN THE CALLER'S TENANT before the session is touched
  # (task-ef3eb91bf7f87d4c). `Session.apply_ops/4` addresses a sheet by
  # `{dataset, published-id}` alone and loads it with an UNSCOPED
  # `Content.get_document/3`, so without this gate an ingest token bound to
  # workspace B could drive structural ops against workspace A's sheet purely
  # by naming its slug. The check is the same scoped draft-first/published
  # -fallback lookup the export door does, and reuses the existing
  # `{:error, :not_found}` → 404 arm, so an in-scope caller's behaviour is
  # byte-identical and a cross-tenant caller gets the same 404 an unknown slug
  # has always produced.
  #
  # THE RESIDUAL THIS GATE DECLARED IS NOW CLOSED (task-f0c064a406e8d363). The
  # session registry key was `{dataset, published-id}` with no workspace in it,
  # so two tenants holding the SAME slug in the same dataset shared one session
  # process. It is now `{dataset, workspace_id, published-id}`, and the door
  # feeds it the workspace of the row IT authorized — so a cross-tenant caller
  # cannot attach to another tenant's live session even by naming its slug, and
  # the session's own load is scoped to the same tenant this gate admitted.
  #
  # The gate therefore RETURNS the resolved doc instead of a bare `:ok`; the
  # `{:error, :not_found}` → 404 arm is unchanged, so an out-of-scope caller
  # still gets the 404 an unknown slug has always produced.
  defp authorize_sheet(conn, slug, dataset) do
    scope = scope_opts(conn)

    with {:error, :not_found} <-
           Content.get_document(Content.draft_id(slug), "sheet", dataset, scope),
         {:error, :not_found} <-
           Content.get_document(Content.published_id(slug), "sheet", dataset, scope) do
      {:error, :not_found}
    end
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

      # The exactly-once ring has no table to read, so the session refuses the
      # batch rather than risk re-applying a non-idempotent op it can no longer
      # recognise (Session.ReplayRing's fail-CLOSED backstop). NOTHING was
      # applied and the SAME request succeeds once the ring is back — a
      # server-side transient, exactly the class `:session_unavailable` is in,
      # so it takes the same 503 + `retry-after` envelope. Rendering it through
      # the catch-all made it a 422, which tells a client its request was wrong
      # and stops the retry that would have fixed it.
      {:error, :replay_unavailable} ->
        conn
        |> put_resp_header("retry-after", "2")
        |> put_status(:service_unavailable)
        |> json(%{
          error: %{
            code: "replay_unavailable",
            message:
              "the exactly-once replay ring is unavailable — the batch was NOT " <>
                "applied; retry shortly"
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
