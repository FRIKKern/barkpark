defmodule BarkparkWeb.PaperMastersController do
  @moduledoc """
  `/w/:workspace_slug/p/:project_slug/v1/papers/:slug/masters` — paper
  masters over HTTP, for an external Studio canvas host (task-2dc7b441443f3aaf).

  The canvas raises events (`bp-save-master`, `bp-master-insert` with
  `master_id`/`after_id`/`mode`, the master-ref block's pin/detach) and
  LiveView answers them in-process through
  `Barkpark.Plugins.Bulldocs.Masters` (`save_master/4`, `list_for_paper/1`,
  `insert_op/4`, `linked_insert_op/4`, `pin_op/3`, `detach_op/3`,
  `studio_live/paper_masters_seam.ex`). No HTTP route exposed any of it, and
  copying a master client-side would skip the server's masterability checks,
  fresh-id seeding and the published-only rule for detach/pin — this
  controller is the same checks LiveView applies, behind the member-token
  write tier (the product-era rule: anything Studio can do, the API can do
  too — see `BarkparkWeb.DocumentOpsController`).

  Insert, pin and detach each run through the matching `Masters.insert_detached/7`,
  `insert_linked/7`, `pin/7` or `detach/6` wrapper — the SAME
  request-identified op path (`Content.apply_paper_block_ops_once/6`) the
  Studio paper socket uses, so every Patch constraint, ratchet, normalization
  and idempotency fingerprint runs exactly as it does there. An optional
  body `"requestId"` (a UUID) makes a retried request replay its receipt
  byte-identical, the same contract the op path already gives the socket;
  omit it and a fresh id is minted per request (no retry safety, every other
  check still applies). `"principal"` is always the calling token's id — an
  HTTP caller has no socket session to borrow one from.

  Responses: list/save answer the master document (`docId`, `rev`, `title`,
  node metadata); insert/pin/detach answer the op receipt (`slug`,
  `opCount`, `rev`, `blockIds`) — an HTTP host echoes `rev` and the new
  block id straight off it.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Bulldocs.Masters
  alias BarkparkWeb.ErrorResponse

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  @doc "List the masters an author may insert into paper `slug`."
  def index(conn, %{"slug" => slug} = params) do
    dataset = requested_dataset(params)

    case Masters.list_for_paper(slug, dataset, scope_opts(conn)) do
      {:ok, masters} -> json(conn, %{masters: Enum.map(masters, &master_json/1)})
      {:error, reason} -> emit_error(conn, reason)
    end
  end

  @doc """
  Save block `blockId` of paper `slug` as a master. Body: `{"blockId": "...",
  "title": "..."}` (`title` optional — defaults to the node's own `title`,
  else its type).
  """
  def create(conn, %{"slug" => slug, "blockId" => block_id} = params) when is_binary(block_id) do
    dataset = requested_dataset(params)
    opts = save_opts(params, scope_opts(conn))

    case Masters.save_master(slug, block_id, dataset, opts) do
      {:ok, %Document{} = master} -> conn |> put_status(:created) |> json(master_json(master))
      {:error, reason} -> emit_error(conn, reason)
    end
  end

  def create(conn, _params),
    do: ErrorResponse.emit_custom(conn, 422, "malformed_request", "\"blockId\" is required")

  @doc """
  Insert master `masterId` into paper `slug`. Body: `{"mode": "detached" |
  "linked", "afterId": "..." | null, "requestId": "<uuid>"}` — `mode`
  defaults to `"detached"`, `afterId` defaults to appending at the top level.
  """
  def insert(conn, %{"slug" => slug, "master_id" => master_id} = params)
      when is_binary(master_id) do
    dataset = requested_dataset(params)
    after_id = Map.get(params, "afterId")

    with {:ok, request_id} <- request_id(params),
         {:ok, principal} <- principal(conn) do
      result =
        case Map.get(params, "mode", "detached") do
          "detached" ->
            Masters.insert_detached(
              slug,
              master_id,
              after_id,
              dataset,
              request_id,
              principal,
              scope_opts(conn)
            )

          "linked" ->
            Masters.insert_linked(
              slug,
              master_id,
              after_id,
              dataset,
              request_id,
              principal,
              scope_opts(conn)
            )

          other ->
            {:error, {:unknown_mode, other}}
        end

      case result do
        {:ok, receipt, _replay} -> json(conn, receipt_json(receipt))
        {:error, reason} -> emit_error(conn, reason)
      end
    else
      {:error, reason} -> emit_error(conn, reason)
    end
  end

  def insert(conn, _params),
    do: ErrorResponse.emit_custom(conn, 422, "malformed_request", "\"masterId\" is required")

  @doc """
  Pin or unpin linked instance `blockId` in paper `slug`. Body: `{"pin":
  true | false, "requestId": "<uuid>"}`.
  """
  def pin(conn, %{"slug" => slug, "block_id" => block_id, "pin" => pin?} = params)
      when is_binary(block_id) and is_boolean(pin?) do
    dataset = requested_dataset(params)

    with {:ok, request_id} <- request_id(params),
         {:ok, principal} <- principal(conn),
         {:ok, receipt, _replay} <-
           Masters.pin(slug, block_id, pin?, dataset, request_id, principal, scope_opts(conn)) do
      json(conn, receipt_json(receipt))
    else
      {:error, reason} -> emit_error(conn, reason)
    end
  end

  def pin(conn, _params),
    do:
      ErrorResponse.emit_custom(
        conn,
        422,
        "malformed_request",
        "\"blockId\" and a boolean \"pin\" are required"
      )

  @doc """
  Detach linked instance `blockId` in paper `slug` to a plain copy. Body:
  `{"requestId": "<uuid>"}`.
  """
  def detach(conn, %{"slug" => slug, "block_id" => block_id} = params) when is_binary(block_id) do
    dataset = requested_dataset(params)

    with {:ok, request_id} <- request_id(params),
         {:ok, principal} <- principal(conn),
         {:ok, receipt, _replay} <-
           Masters.detach(slug, block_id, dataset, request_id, principal, scope_opts(conn)) do
      json(conn, receipt_json(receipt))
    else
      {:error, reason} -> emit_error(conn, reason)
    end
  end

  def detach(conn, _params),
    do: ErrorResponse.emit_custom(conn, 422, "malformed_request", "\"blockId\" is required")

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp requested_dataset(params) do
    case Map.get(params, "dataset") do
      ds when is_binary(ds) -> ds
      _ -> Content.paper_default_dataset()
    end
  end

  defp save_opts(%{"title" => title}, opts) when is_binary(title) and title != "",
    do: Keyword.put(opts, :title, title)

  defp save_opts(_params, opts), do: opts

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

  # The HTTP caller has no socket session to borrow a principal key from
  # (`replay_principal_key/1` in the Studio paper socket) — it IS the bearer
  # token `RequireToken` already authenticated this request against.
  defp principal(%{assigns: %{api_token: %{id: id}}}) when is_binary(id), do: {:ok, id}
  defp principal(_conn), do: {:error, :missing_principal}

  defp master_json(%Document{} = master) do
    %{
      docId: Masters.master_id(master),
      rev: master.rev,
      title: master.title,
      tier: get_in(master.content, ["tier"]),
      blockType: get_in(master.content, ["block_type"]),
      sourcePaper: get_in(master.content, ["source_paper"]),
      sourceBlockId: get_in(master.content, ["source_block_id"])
    }
  end

  defp receipt_json(%{slug: slug, op_count: op_count, rev: rev, block_ids: block_ids}),
    do: %{slug: slug, opCount: op_count, rev: rev, blockIds: block_ids}

  defp emit_error(conn, :paper_not_found),
    do:
      ErrorResponse.emit_custom(
        conn,
        404,
        "not_found",
        "no paper found as #{inspect(conn.params["slug"])}"
      )

  defp emit_error(conn, :master_not_found),
    do: ErrorResponse.emit_custom(conn, 404, "not_found", "no master found in this paper's scope")

  defp emit_error(conn, :block_not_found),
    do: ErrorResponse.emit_custom(conn, 404, "not_found", "no block found with that id")

  defp emit_error(conn, :not_masterable),
    do:
      ErrorResponse.emit_custom(
        conn,
        422,
        "not_masterable",
        "this block's type cannot be saved as a master"
      )

  defp emit_error(conn, :locked_block),
    do:
      ErrorResponse.emit_custom(
        conn,
        422,
        "locked_block",
        "this block is template-locked or a slot role and cannot be saved as a master"
      )

  defp emit_error(conn, :bound_field),
    do:
      ErrorResponse.emit_custom(
        conn,
        422,
        "bound_field",
        "this block is bound to a schema field and cannot be saved as a master"
      )

  defp emit_error(conn, :not_linked),
    do:
      ErrorResponse.emit_custom(
        conn,
        422,
        "not_linked",
        "this block is not a linked master instance"
      )

  defp emit_error(conn, :master_unpublished),
    do:
      ErrorResponse.emit_custom(
        conn,
        422,
        "master_unpublished",
        "the master has no published revision the public reader can show"
      )

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

  defp emit_error(conn, {:unknown_mode, other}),
    do:
      ErrorResponse.emit_custom(
        conn,
        422,
        "malformed_request",
        "\"mode\" must be \"detached\" or \"linked\", got #{inspect(other)}"
      )

  defp emit_error(conn, reason),
    do: ErrorResponse.emit(conn, {:error, reason}, "paper masters request failed")
end
