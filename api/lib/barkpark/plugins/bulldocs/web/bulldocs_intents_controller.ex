defmodule BarkparkWeb.BulldocsIntentsController do
  @moduledoc """
  Pending-intents API over `paper_events` — the Barkpark half of the
  loop-closer (P6.U6a, barkpark-jwai). The paper-side reader loop (U6b)
  polls these token-gated endpoints to drain the actionable intents that
  U4/U5 record into `paper_events`.

  Token-gated via the `:ingest` pipeline (RequireIngestToken plug —
  shared-secret bearer, NOT the api_tokens table), same as the paper-ingest
  endpoint.

      GET /v1/plugins/bulldocs/intents
      Authorization: Bearer <BARKPARK_INGEST_TOKEN>
      → 200 {"intents": [{id, event_type, goal_id, paper_slug, branch,
                          payload_html, inserted_at}, …]}

      POST /v1/plugins/bulldocs/intents/:id/processed
      Authorization: Bearer <BARKPARK_INGEST_TOKEN>
      → 200 {"ok": true, "id": "<id>"}        marked processed
      → 404 {"ok": false, "error": "not_found"} no such event

  Only `action:*` / `simplify-*` events with a NULL `processed_at` are returned
  (see `Events.list_pending_intents/1`); lifecycle events never surface here.

  ## Tenancy (task-18b31997d93e322c)

  The `:ingest` pipeline resolves NO workspace — `RequireIngestToken` authorizes
  on either the instance shared secret or ANY live api_token that satisfies the
  workspace-BLIND `Barkpark.Tenancy.Auth.permits?(token, :admin)`. So there is no
  `conn` scope to bind to, and a token bound to workspace A used to drain (and
  mark processed) every OTHER workspace's intents, `payload_html` included.

  Both actions therefore re-resolve the presented bearer and scope on the
  TOKEN's own `workspace_id`:

    * bearer resolves to an api_token BOUND to a workspace → the read is scoped
      to that workspace, and a mark on a foreign intent is a 404 (indistinguish-
      able from a nonexistent id — the door discloses nothing about other
      tenants' rows, and the foreign row is left untouched);
    * bearer does NOT resolve to a bound api_token → the deliberate, unchanged
      instance-operator drain across all workspaces. That is the shared-secret
      path (the secret is not an `api_tokens` row, so `verify_token/1` rejects
      it) and the un-bound global-admin token. Failing OPEN here is safe only
      because `RequireIngestToken` already rejected every unauthenticated
      caller; this seam narrows an authorized caller, it is not the auth gate.

  ## Dataset binding (task-ad7114cdcb1200b9)

  A token minted with an explicit dataset is held to it here too. An intent
  has no dataset of its own, it follows its paper (`EventDataset`): a
  dataset-bound token lists and marks only intents of papers in its dataset,
  and a mark on any other intent is the same 404. Unbound tokens and the
  shared secret are unchanged.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Plugins.Bulldocs.{EventDataset, Events}

  @doc """
  Return the pending actionable intents, oldest first, as a JSON list — scoped
  to the calling token's workspace (see the module doc).
  """
  def index(conn, _params) do
    intents =
      conn
      |> caller_scope()
      |> Events.list_pending_intents()
      |> within_bound_dataset(conn)
      |> Enum.map(&intent_json/1)

    conn
    |> put_status(:ok)
    |> json(%{intents: intents})
  end

  @doc """
  Mark the intent at `:id` processed so it drops out of the pending list.
  200 `{ok: true, id}` on success; 404 `{ok: false, error: "not_found"}` for
  an unknown id — or for an id that exists in ANOTHER workspace, which this
  caller may not drain and must not be able to probe for.
  """
  def mark_processed(conn, %{"id" => id}) do
    if visible_to_caller?(conn, id) do
      case Events.mark_processed(id) do
        {:ok, event} ->
          conn
          |> put_status(:ok)
          |> json(%{ok: true, id: event.id})

        {:error, :not_found} ->
          not_found(conn, id)
      end
    else
      not_found(conn, id)
    end
  end

  defp not_found(conn, id) do
    conn
    |> put_status(:not_found)
    |> json(%{ok: false, error: "not_found", id: id})
  end

  # The tenancy opts for this request, derived from the BEARER rather than from
  # `conn.assigns` — the `:ingest` pipeline assigns no workspace at all, so
  # `BarkparkWeb.ScopeHelpers.scope_opts/1` would yield the `:shared_only`
  # sentinel for every caller and break the instance-operator drain.
  #
  # `[]` means "explicit global read": `Events.list_pending_intents/1` pipes it
  # through `Content.Scope.scope_to_workspace_or_global/3`, whose nil arm is the
  # named, deliberate cross-tenant path.
  defp caller_scope(conn) do
    with ["Bearer " <> presented] <- get_req_header(conn, "authorization"),
         {:ok, %{workspace_id: workspace_id}} when is_binary(workspace_id) <-
           Barkpark.Auth.verify_token(presented) do
      [workspace_id: workspace_id]
    else
      # The shared ingest secret (never an `api_tokens` row) and the un-bound
      # global-admin token both land here — the instance operator, unchanged.
      _ -> []
    end
  end

  # `Events.mark_processed/1` takes no scope, so the boundary is enforced HERE:
  # read the row first and refuse unless it belongs to the caller's workspace.
  # A globally-scoped caller (`[]`) sees every row, exactly as before.
  defp visible_to_caller?(conn, id) do
    workspace_id = Keyword.get(caller_scope(conn), :workspace_id)

    if is_nil(workspace_id) and is_nil(bound_dataset(conn)) do
      true
    else
      case Events.get_event(id) do
        nil ->
          false

        event ->
          (is_nil(workspace_id) or event.workspace_id == workspace_id) and
            within_bound_dataset([event], conn) != []
      end
    end
  end

  # The dataset a dataset-bound token is held to, else nil. `RequireIngestToken`
  # assigns `:api_token` for a token caller; the shared secret assigns none.
  defp bound_dataset(conn), do: ApiToken.bound_dataset(conn.assigns[:api_token])

  defp within_bound_dataset(events, conn) do
    case bound_dataset(conn) do
      nil -> events
      dataset -> EventDataset.within(events, dataset)
    end
  end

  defp intent_json(event) do
    %{
      id: event.id,
      event_type: event.event_type,
      goal_id: event.goal_id,
      paper_slug: event.paper_slug,
      branch: event.branch,
      payload_html: event.payload_html,
      inserted_at: event.inserted_at
    }
  end
end
