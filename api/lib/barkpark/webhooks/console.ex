defmodule Barkpark.Webhooks.Console do
  @moduledoc """
  The webhook actions an admin takes by hand: look a hook up inside one scope,
  make a signing secret, replay a stored event, send a test.

  Two doors call these and only these: the HTTP API
  (`BarkparkWeb.WebhookController`) and the Studio Webhooks page
  (`BarkparkWeb.Studio.WebhooksLive`). Keeping the logic here means the two
  cannot drift on who may touch which hook or which event may be replayed.

  `scope_opts` is the caller's resolved tenant scope
  (`BarkparkWeb.ScopeHelpers.scope_opts/1`), passed straight to
  `Barkpark.Webhooks.get_webhook/2`.
  """

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.{Dispatcher, Webhook}

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc """
  Load a webhook by id inside the tenant scope AND under the given dataset. A
  hook fetched under the wrong dataset is refused like an unknown one
  (cross-dataset access guard). Returns `{:ok, webhook}` or `:error`.
  """
  def fetch_scoped(id, dataset, scope_opts) do
    with true <- is_binary(id) and Regex.match?(@uuid_regex, id),
         {:ok, wh} <- Webhooks.get_webhook(id, scope_opts),
         true <- wh.dataset == dataset do
      {:ok, wh}
    else
      _ -> :error
    end
  end

  @doc "A fresh signing secret: `whsec_` and 24 random bytes, URL-safe base64."
  def generate_secret do
    "whsec_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  @doc """
  Give `attrs` a secret when it has none. Returns `{attrs, generated}`, where
  `generated` is the new secret (to show once) or nil when the caller gave one.
  """
  def ensure_secret(attrs) do
    if Dispatcher.blank_secret?(Map.get(attrs, "secret")) do
      secret = generate_secret()
      {Map.put(attrs, "secret", secret), secret}
    else
      {attrs, nil}
    end
  end

  @doc """
  Replay a stored mutation event to THIS webhook as one fresh, synchronous
  attempt on the same delivery row. The payload is rebuilt from the
  `mutation_events` snapshot and signed with the current secret.

  Returns `{:ok, delivery}`, `{:error, :bad_event_id}` or
  `{:error, :event_not_found}` (unknown event, an event this hook could never
  have received, or a row deleted mid-replay).
  """
  def replay(%Webhook{} = wh, event_id) do
    with {:ok, eid} <- parse_event_id(event_id),
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

      case Dispatcher.replay_delivery(wh, body, eid) do
        {:ok, delivery} -> {:ok, delivery}
        # The event or its delivery row was deleted between the guard above and
        # the claim (`:event_gone` / `:delivery_gone`): same verdict as an
        # unknown event id.
        {:error, _gone} -> {:error, :event_not_found}
      end
    else
      {:error, :bad_event_id} -> {:error, :bad_event_id}
      _ -> {:error, :event_not_found}
    end
  end

  @doc """
  Send a one-shot TEST delivery (GR45): a synthetic `webhook.test` event,
  signed with the current secret, in a SINGLE synchronous attempt. The row
  carries a NULL `endpoint_id`, so a test, success or failure, never touches
  the endpoint's auto-disable accounting. Returns `{:ok, delivery}`.
  """
  def send_test(%Webhook{} = wh) do
    body = wh |> test_payload() |> Jason.encode!()
    # `endpoint_id` intentionally omitted (NULL). The snapshot holds the target
    # url + probe body; the secret is NOT snapshotted (a test is never resumed,
    # so there is nothing to re-sign later).
    {:ok, delivery} = Webhooks.create_test_delivery(%{"url" => wh.url, "body" => body})
    Dispatcher.deliver_test(wh, body, delivery)
  end

  # Synthetic probe payload: a self-describing `webhook.test` envelope so the
  # receiver can tell a manual test apart from a real content event.
  defp test_payload(wh) do
    %{
      type: "webhook.test",
      dataset: wh.dataset,
      delivery: "test",
      message:
        "Test delivery from Barkpark — someone clicked \"Send test\" to verify this endpoint.",
      webhook: %{id: wh.id, name: wh.name},
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp parse_event_id(value) when is_integer(value), do: {:ok, value}

  defp parse_event_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_event_id}
    end
  end

  defp parse_event_id(_value), do: {:error, :bad_event_id}

  # Mirror of the dispatch-time selection scope (`Webhooks.active_webhooks_for`
  # through `Scope.scope_to_workspace_or_global`): a webhook may REPLAY an event
  # only if auto-dispatch could have SELECTED it for that event. The dataset
  # must match, and a workspace-scoped event additionally requires the webhook
  # to live in the same workspace (and same project, when the event carries
  # one); an unscoped (legacy) event replays only to a shared-layer webhook,
  # exactly as dispatch selects it. The dataset STRING alone is NOT a
  # tenant boundary — "production" exists in every workspace and event ids are
  # global sequential integers, so without the workspace clause a wsB admin
  # could point a wsB webhook at their own URL and replay wsA's event ids into
  # it (cross-tenant document-snapshot exfiltration).
  # A NULL-project webhook is workspace-wide (see `Webhooks.scope/2`), so it may
  # replay any event of its own workspace.
  # task-ae096a1b6ef7f5a6: listener presence is per-machine heartbeat truth and
  # never fans out to a webhook (PDF-D18). Automatic dispatch, the SSE live leg
  # and the SSE replay leg all drop `type == "listener"`; the replay door must
  # agree, or an admin can hand-deliver what no automatic path would send.
  defp event_in_scope?(%MutationEvent{type: "listener"}, _wh), do: false

  # A workspace-less event replays only to a shared-layer (NULL-workspace)
  # webhook, the same fail-closed rule dispatch applies (owner ruling #51, RQ2).
  defp event_in_scope?(ev, wh) do
    ev.dataset == wh.dataset and
      ((is_nil(ev.workspace_id) and is_nil(wh.workspace_id)) or
         (is_binary(ev.workspace_id) and ev.workspace_id == wh.workspace_id and
            (is_nil(ev.project_id) or is_nil(wh.project_id) or ev.project_id == wh.project_id)))
  end
end
