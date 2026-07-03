defmodule BarkparkWeb.WebhookController do
  use BarkparkWeb, :controller

  alias Barkpark.Content.Errors
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Dispatcher
  alias BarkparkWeb.ScopeHelpers

  def index(conn, %{"dataset" => dataset}) do
    hooks = Webhooks.list_webhooks(dataset, ScopeHelpers.scope_opts(conn))
    json(conn, %{webhooks: Enum.map(hooks, &render_webhook/1)})
  end

  def show(conn, %{"id" => id}) do
    with :ok <- validate_uuid(id),
         {:ok, wh} <- Webhooks.get_webhook(id, ScopeHelpers.scope_opts(conn)) do
      json(conn, %{webhook: render_webhook(wh)})
    else
      _ -> webhook_not_found(conn)
    end
  end

  def create(conn, %{"dataset" => dataset} = params) do
    attrs = Map.put(params, "dataset", dataset)

    case Webhooks.create_webhook(attrs, ScopeHelpers.scope_opts(conn)) do
      {:ok, wh} ->
        conn |> put_status(201) |> json(%{webhook: render_webhook(wh)})

      {:error, changeset} ->
        validation_failed(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- validate_uuid(id),
         {:ok, wh} <- Webhooks.get_webhook(id, ScopeHelpers.scope_opts(conn)),
         {:ok, updated} <- Webhooks.update_webhook(wh, params) do
      json(conn, %{webhook: render_webhook(updated)})
    else
      {:error, :invalid_uuid} -> webhook_not_found(conn)
      {:error, :not_found} -> webhook_not_found(conn)
      {:error, changeset} -> validation_failed(conn, changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- validate_uuid(id),
         {:ok, wh} <- Webhooks.get_webhook(id, ScopeHelpers.scope_opts(conn)),
         {:ok, _} <- Webhooks.delete_webhook(wh) do
      json(conn, %{deleted: id})
    else
      _ -> webhook_not_found(conn)
    end
  end

  @doc """
  List an endpoint's recent deliveries, newest-first, including per-row latency.
  `?limit=` is clamped to 1..100 (default 25) inside the context.
  """
  def deliveries(conn, %{"dataset" => dataset, "id" => id} = params) do
    case fetch_scoped(conn, dataset, id) do
      {:ok, wh} ->
        deliveries = Webhooks.list_deliveries(wh.id, limit: parse_limit(params["limit"]))
        json(conn, %{deliveries: Enum.map(deliveries, &render_delivery/1)})

      :error ->
        webhook_not_found(conn)
    end
  end

  @doc """
  Replay a stored mutation event to THIS webhook as a fresh, synchronous
  attempt against the same delivery row. Rebuilds the ORIGINAL payload from the
  persisted `mutation_events` snapshot and re-signs with the current secret.
  404 if the webhook (under this dataset) or the event id is unknown.
  """
  def replay(conn, %{"dataset" => dataset, "id" => id, "event_id" => event_id}) do
    with {:ok, wh} <- fetch_scoped(conn, dataset, id),
         {:ok, eid} <- parse_event_id(event_id),
         %MutationEvent{} = ev <- Repo.get(MutationEvent, eid),
         # Tenant isolation: only an event auto-dispatch could have delivered to
         # this webhook may be replayed to it — anything else is refused as
         # not-found, never leaked into another tenant's endpoint.
         true <- event_in_scope?(ev, wh) do
      body =
        Dispatcher.build_payload(
          ev.mutation,
          ev.type,
          ev.doc_id,
          ev.document,
          ev.dataset,
          workspace_id: ev.workspace_id,
          project_id: ev.project_id
        )
        |> Jason.encode!()

      {:ok, delivery} = Dispatcher.replay_delivery(wh, body, eid)
      json(conn, %{delivery: render_delivery(delivery)})
    else
      :error -> webhook_not_found(conn)
      {:error, :bad_event_id} -> event_not_found(conn)
      nil -> event_not_found(conn)
      false -> event_not_found(conn)
    end
  end

  @doc """
  Rotate the endpoint's signing secret. Generates a fresh secret server-side,
  moves the current one to `previous_secret` (valid for its TTL), and returns
  the NEW secret exactly once in the response body — subsequent reads never
  re-expose it (mirrors create's secret-exposure semantics).
  """
  def rotate(conn, %{"dataset" => dataset, "id" => id}) do
    case fetch_scoped(conn, dataset, id) do
      {:ok, wh} ->
        new_secret = generate_secret()

        case Webhooks.rotate_secret(wh, new_secret) do
          {:ok, rotated} ->
            json(conn, %{webhook: render_webhook(rotated), secret: new_secret})

          {:error, changeset} ->
            validation_failed(conn, changeset)
        end

      :error ->
        webhook_not_found(conn)
    end
  end

  # Mirror of the dispatch-time selection scope (`Webhooks.active_webhooks_for`
  # through `Scope.scope_to_workspace_or_global`): a webhook may REPLAY an event
  # only if auto-dispatch could have SELECTED it for that event. The dataset
  # must match, and a workspace-scoped event additionally requires the webhook
  # to live in the same workspace (and same project, when the event carries
  # one); an unscoped (legacy/global) event may replay to any webhook in its
  # dataset, exactly as dispatch fans it out. The dataset STRING alone is NOT a
  # tenant boundary — "production" exists in every workspace and event ids are
  # global sequential integers, so without the workspace clause a wsB admin
  # could point a wsB webhook at their own URL and replay wsA's event ids into
  # it (cross-tenant document-snapshot exfiltration).
  defp event_in_scope?(ev, wh) do
    ev.dataset == wh.dataset and
      (is_nil(ev.workspace_id) or
         (ev.workspace_id == wh.workspace_id and
            (is_nil(ev.project_id) or ev.project_id == wh.project_id)))
  end

  # Load a webhook by id, enforcing BOTH the tenant scope (workspace/project via
  # scope_opts) AND the :dataset path segment — a webhook id fetched under the
  # wrong dataset is refused as not-found (cross-dataset access guard).
  defp fetch_scoped(conn, dataset, id) do
    with :ok <- validate_uuid(id),
         {:ok, wh} <- Webhooks.get_webhook(id, ScopeHelpers.scope_opts(conn)),
         true <- wh.dataset == dataset do
      {:ok, wh}
    else
      _ -> :error
    end
  end

  defp parse_event_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_event_id}
    end
  end

  # A garbage ?limit= is treated as absent so the context applies its default.
  defp parse_limit(nil), do: nil

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp generate_secret do
    "whsec_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  defp render_delivery(d) do
    %{
      id: d.id,
      endpoint_id: d.endpoint_id,
      event_id: d.event_id,
      status: d.status,
      attempts: d.attempts,
      last_status_code: d.last_status_code,
      last_error_text: d.last_error_text,
      last_latency_ms: d.last_latency_ms,
      created_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  # `code: "event_not_found"` (not the generic "not_found") lets the cloud proxy
  # + SPA distinguish a REAL not-found (the endpoint exists, this event id does
  # not) from a route-missing 404 (capability_unavailable) — see charter D46/D51.
  # The 3-tuple reason keeps the code inside Errors' registered vocabulary, so
  # the envelope's hint matches the code (not the document-centric not_found
  # hint) and the OpenAPI Error.code enum stays truthful.
  defp event_not_found(conn) do
    coded_not_found(conn, "event_not_found", "event not found")
  end

  # `code: "webhook_not_found"` — same rationale as event_not_found/1: a coded
  # body means the SPA can tell "no such webhook here" apart from "this route
  # isn't served by the instance" (a missing capability), instead of guessing
  # from a bare 404.
  defp webhook_not_found(conn) do
    coded_not_found(conn, "webhook_not_found", "webhook not found")
  end

  defp coded_not_found(conn, code, message) do
    env = Errors.to_envelope({:error, {:not_found, code, message}}, conn)

    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end

  defp validation_failed(conn, changeset) do
    base = Errors.to_envelope({:error, :malformed}, conn)

    err =
      base
      |> Map.put(:code, "validation_failed")
      |> Map.put(:message, "document failed validation")
      |> Map.put(:details, format_errors(changeset))
      |> Map.delete(:status)

    conn
    |> put_status(422)
    |> json(%{error: err})
  end

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  defp validate_uuid(id) when is_binary(id) do
    if Regex.match?(@uuid_regex, id), do: :ok, else: {:error, :invalid_uuid}
  end

  defp render_webhook(wh) do
    %{
      id: wh.id,
      name: wh.name,
      url: wh.url,
      dataset: wh.dataset,
      events: wh.events,
      types: wh.types,
      active: wh.active,
      # Auto-disable substrate for the console panel: the consecutive terminal
      # give-up count, and when/why the endpoint was auto-disabled (nil until it
      # crosses the threshold). The panel renders these + calls the re-enable path.
      consecutive_failures: wh.consecutive_failures,
      auto_disabled_at: wh.auto_disabled_at,
      disable_reason: wh.disable_reason,
      created_at: wh.inserted_at,
      updated_at: wh.updated_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
