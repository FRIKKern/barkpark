defmodule BarkparkWeb.PaperOpsController do
  @moduledoc """
  `POST /w/:workspace_slug/p/:project_slug/v1/papers/:slug/ops` — a
  member-token, `ifRev`-fenced batch of block ops for a Bulldocs paper, over
  HTTP (task-7ee817f37630d669, P1 — blocks barkpark-studio's Freeform papers).

  Before this route, no member-token HTTP path could save a paper's BODY:
  `POST /v1/data/doc/:dataset/:type/:doc_id/ops` (`DocumentOpsController`)
  refuses `type == "paper"` outright — `Content.blocks_type?/1` routes it to
  "paper documents take ops at /v1/plugins/bulldocs/papers/:slug/ops" — and
  that route is `:ingest`-tier only (`BARKPARK_INGEST_TOKEN`, mounted by
  `Barkpark.Plugins.Bulldocs.register_routes/1`), never a member token. So an
  external Studio editing a paper in `bp-paper-canvas` with a member token had
  no save path at all; `PaperMastersController` (task-2dc7b441443f3aaf) only
  ever covered master insert/pin/detach, not the paper's own block list.

  This route closes that gap with the SAME shape `DocumentOpsController` gives
  every other document type: `{"ops": [...], "ifRev": "<the paper's current
  rev>"}` in, the new `rev` out, a stale `ifRev` refused 412 BEFORE any op
  applies. It runs through `Content.apply_paper_block_ops_once/6` — the exact
  request-identified op path `PaperMastersController` already uses and the
  Studio canvas itself uses in-process (`bulldocs_live/edit.ex`) — so every
  Patch constraint, ratchet, normalization and idempotency fingerprint applies
  exactly as it does there. An optional body `"requestId"` (a UUID) makes a
  retried request replay its receipt byte-identical; omit it and a fresh id is
  minted per request. `"principal"` is always the calling token's id — an
  HTTP caller has no socket session to borrow one from.

  Security: this route rides the SAME `:scoped_mutate` pipeline
  `PaperMastersController`'s writes and `DocumentOpsController` already ride —
  `RequireWritePermission` on top of the ordinary tenancy scoping, the same
  `workspace scope + the member's write permission` bar
  `BarkparkWeb.PaperViewer.can_edit?/2` enforces for the Studio canvas's own
  socket (`Tenancy.Auth.authorize/3` with action `:write`, the single
  chokepoint requiring both a membership row and, for a token, the `write`
  permission). A read-only or non-member token never reaches this action at
  all — the pipeline plug refuses it first.

  A stale `ifRev` answers 412 `precondition_failed` with `details: {expected,
  actual}` — the SAME envelope shape `DocumentOpsController`'s rev-mismatch
  answers (`Content.Errors`'s `{:rev_mismatch, %{expected:, actual:}}`
  builder). The paper op path itself (`Papers.BlockOps.check_paper_if_rev/2`)
  only ever refuses with a bare `:precondition_failed` — it has no `actual`
  rev to hand back, because by the time it fails the paper was never loaded
  into the caller's hands. This controller re-reads the paper's CURRENT rev
  on that one error path (never on the happy path) to fill `actual` in,
  rather than widening `check_paper_if_rev/2`'s return shape for every
  existing caller (the ingest route, `bp bulldocs patch`, the BPML sync door)
  that already depends on the bare atom.

  Responses: success answers the paper's native batch-ops receipt (`slug`,
  `opCount`, `rev`, `blockIds`) — the SAME shape `PaperMastersController`'s
  insert/pin/detach and the ingest route's batch leg already answer, so an
  HTTP host that already understands one paper-ops receipt understands this
  one too.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias BarkparkWeb.ErrorResponse

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  @doc """
  Apply an `ifRev`-fenced batch of block ops to paper `slug`. Body:
  `{"ops": [...], "ifRev": "<the paper's current rev>", "requestId":
  "<uuid, optional>"}`.
  """
  def apply_op(conn, %{"slug" => slug} = params) do
    dataset = requested_dataset(params)
    ops = Map.get(params, "ops")
    if_rev = Map.get(params, "ifRev")

    cond do
      not valid_ops?(ops) ->
        ErrorResponse.emit_custom(
          conn,
          :unprocessable_entity,
          "malformed_op",
          "body must carry a non-empty \"ops\" list, each entry naming a DocPatchOp in its \"op\" key"
        )

      not valid_if_rev?(if_rev) ->
        ErrorResponse.emit_custom(
          conn,
          :unprocessable_entity,
          "malformed_op",
          "ifRev is required: read the paper and send its current rev"
        )

      true ->
        with {:ok, request_id} <- request_id(params),
             {:ok, principal} <- principal(conn) do
          scope = scope_opts(conn)

          case Content.apply_paper_block_ops_once(
                 slug,
                 ops,
                 dataset,
                 request_id,
                 principal,
                 scope ++ [if_rev: if_rev]
               ) do
            {:ok, receipt, _replay} ->
              json(conn, receipt_json(receipt))

            {:error, :precondition_failed} ->
              stale_rev_error(conn, slug, dataset, scope, if_rev)

            {:error, reason} ->
              emit_error(conn, reason)
          end
        else
          {:error, reason} -> emit_error(conn, reason)
        end
    end
  end

  def apply_op(conn, _params),
    do: ErrorResponse.emit_custom(conn, 422, "malformed_request", "\"slug\" is required")

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp requested_dataset(params) do
    case Map.get(params, "dataset") do
      ds when is_binary(ds) -> ds
      _ -> Content.paper_default_dataset()
    end
  end

  defp valid_ops?(ops), do: is_list(ops) and ops != [] and Enum.all?(ops, &valid_op?/1)
  defp valid_op?(op), do: is_map(op) and is_binary(op["op"])

  # A paper's rev is a native INTEGER (content["rev"]) — unlike a document's
  # string _rev hash, so ifRev is accepted as either, the same permissiveness
  # Papers.BlockOps.check_paper_if_rev/2's normalize_if_rev/1 already gives
  # it (and the ingest route's apply_op_batch/4, which passes ifRev through
  # with no type check of its own).
  defp valid_if_rev?(v) when is_integer(v), do: true
  defp valid_if_rev?(v) when is_binary(v), do: v != ""
  defp valid_if_rev?(_), do: false

  # A client may send its own UUID for idempotent retries; absent (or not a
  # UUID — refused up front rather than silently swapped for a fresh one, so
  # a typo never looks like a successful retry of something else), mint one.
  defp request_id(%{"requestId" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, :invalid_request_id}
    end
  end

  defp request_id(_params), do: {:ok, Ecto.UUID.generate()}

  # The HTTP caller has no socket session to borrow a principal key from — it
  # IS the bearer token RequireToken already authenticated this request
  # against (mirrors PaperMastersController.principal/1).
  defp principal(%{assigns: %{api_token: %{id: id}}}) when is_binary(id), do: {:ok, id}
  defp principal(_conn), do: {:error, :missing_principal}

  # Re-reads the paper's current rev ON THE ERROR PATH ONLY, so a stale ifRev
  # answers the SAME {status: 412, code: "precondition_failed", details:
  # {expected, actual}} envelope DocumentOpsController's rev-mismatch does
  # (Content.Errors' {:rev_mismatch, %{}} builder) — without widening
  # check_paper_if_rev/2's bare :precondition_failed for every other caller.
  defp stale_rev_error(conn, slug, dataset, scope, if_rev) do
    actual =
      case Content.get_paper(slug, dataset, scope) do
        nil -> nil
        paper -> with {:ok, rev} <- Barkpark.Content.Papers.op_rev(paper), do: rev
      end

    conn
    |> ErrorResponse.emit({:error, {:rev_mismatch, %{expected: if_rev, actual: actual}}})
  end

  defp receipt_json(%{slug: slug, op_count: op_count, rev: rev, block_ids: block_ids}),
    do: %{slug: slug, opCount: op_count, rev: rev, blockIds: block_ids}

  defp emit_error(conn, :not_found),
    do:
      ErrorResponse.emit_custom(
        conn,
        404,
        "not_found",
        "no paper found as #{inspect(conn.params["slug"])}"
      )

  defp emit_error(conn, {:constraint, message, op_kind}),
    do: ErrorResponse.emit_custom(conn, 422, "constraint", message, %{op: op_kind})

  defp emit_error(conn, {:halted, reason}),
    do: ErrorResponse.emit_custom(conn, 409, "halted", reason)

  defp emit_error(conn, {:write_admission, _} = reason),
    do: write_admission_refused(conn, {:error, reason})

  defp emit_error(conn, :invalid_request_id),
    do: ErrorResponse.emit_custom(conn, 422, "malformed_request", "\"requestId\" must be a UUID")

  defp emit_error(conn, :missing_principal),
    do:
      ErrorResponse.emit_custom(
        conn,
        401,
        "unauthorized",
        "no authenticated token on this request"
      )

  defp emit_error(conn, reason),
    do: ErrorResponse.emit(conn, {:error, reason}, "paper ops request failed")

  # C083: a held instance refuses the write at the door. 503 transient, never an op fault.
  defp write_admission_refused(conn, refused) do
    env = Barkpark.Content.Errors.to_envelope(refused, conn)

    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end
end
