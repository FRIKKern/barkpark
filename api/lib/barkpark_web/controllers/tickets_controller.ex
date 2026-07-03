defmodule BarkparkWeb.TicketsController do
  @moduledoc """
  HTTP surface for Barkpark Tickets (charter Decisions 2, 3, 5).

  Two disjoint personas over one `/v1/tickets` noun:

    * **Submitter** (key-holder) — authenticated by `conn.assigns[:ticket_key]`,
      the key row the sibling `RequireTicketKey` plug resolves from a `bptk_…`
      bearer. A key sees ONLY its own tickets.

        POST /v1/tickets                 :create     file a ticket (first message)
        GET  /v1/tickets                 :index_own  list mine
        GET  /v1/tickets/:id             :show_own   read the thread (stamps seen)
        POST /v1/tickets/:id/messages    :reply      reply (auto-reopens)

    * **Operator** — normal bearer-token auth (the `:token_root` bucket).

        GET  /v1/tickets/inbox           :inbox          triage feed
        GET  /v1/tickets/inbox/:id       :show_operator  read one thread
        POST /v1/tickets/:id/answer      :answer         answer (+ optional close:true)
        POST /v1/tickets/:id/close       :close          close

  ## Identity comes from the credential, never the body

  The submitter's name is the key's `name`; the operator's name is the token's
  `label`. Neither is ever read from the request body, and `status` is derived
  by `Thread.transition/2` — a client cannot set it. That is what makes a
  leaked key spam and never data.

  ## Worktree note

  The routes above are declared by `Barkpark.Plugins.Tickets.register_routes/1`
  but mount only once the sibling auth slice adds the `:ticket_key` bucket and
  the plugin is enabled. In THIS worktree the controller is unit-tested by
  invoking its actions directly with a hand-assigned `:ticket_key` (submitter)
  or scope assigns (operator).
  """

  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Tickets.{Thread, Triage}

  @default_dataset "production"

  # ── Submitter surface (auth: conn.assigns[:ticket_key]) ──────────────────

  @doc "POST /v1/tickets — file a ticket with its first message."
  def create(conn, params) do
    with_key(conn, fn key ->
      attrs = %{
        subject: params["subject"],
        body: params["body"],
        attachments: params["attachments"]
      }

      case Thread.create(key, attrs) do
        {:ok, %Document{} = ticket} ->
          emit(ticket, "ticket.created")
          render_ticket(conn, ticket, :created)

        {:error, :subject_required} ->
          bad_request(conn, "subject is required")

        {:error, :body_required} ->
          bad_request(conn, "body is required")

        {:error, reason} ->
          unprocessable(conn, "create_failed", inspect(reason))
      end
    end)
  end

  @doc "GET /v1/tickets — the key's own tickets, newest-touched first."
  def index_own(conn, _params) do
    with_key(conn, fn key ->
      rows =
        key
        |> Thread.list_for_key()
        |> Enum.map(&summary(Thread.to_map(&1)))

      json(conn, %{ok: true, tickets: rows})
    end)
  end

  @doc "GET /v1/tickets/:id — read one thread; stamps the delivery signal."
  def show_own(conn, %{"id" => id}) do
    with_key(conn, fn key ->
      case Thread.get_for_key(key, id) do
        {:ok, ticket} ->
          # Stamp submitter_seen_at when the answer is waiting to be read. Best
          # effort: a failed stamp must never fail the read the key came for.
          seen =
            case Thread.stamp_seen(ticket) do
              {:ok, updated} -> updated
              _ -> ticket
            end

          render_ticket(conn, seen)

        {:error, :not_found} ->
          not_found(conn)
      end
    end)
  end

  @doc "POST /v1/tickets/:id/messages — submitter reply (auto-reopens)."
  def reply(conn, %{"id" => id} = params) do
    with_key(conn, fn key ->
      case Thread.get_for_key(key, id) do
        {:ok, ticket} ->
          author = {"submitter", key_name(key)}

          case Thread.append(ticket, author, params["body"], params["attachments"] || []) do
            {:ok, %Document{} = updated} ->
              emit(updated, "ticket.reopened")
              render_ticket(conn, updated)

            {:error, :body_required} ->
              bad_request(conn, "body is required")

            {:error, :thread_full} ->
              thread_full(conn)

            {:error, reason} ->
              unprocessable(conn, "reply_failed", inspect(reason))
          end

        {:error, :not_found} ->
          not_found(conn)
      end
    end)
  end

  # ── Operator surface (normal token auth) ─────────────────────────────────

  @doc "GET /v1/tickets/inbox — triage feed, what-needs-answering first."
  def inbox(conn, _params) do
    now = DateTime.utc_now()

    rows =
      conn
      |> dataset()
      |> Thread.list_for_operator(scope_opts(conn))
      |> Enum.map(&Thread.to_map/1)
      |> Triage.inbox_order()
      |> Enum.map(&inbox_row(&1, now))

    json(conn, %{ok: true, tickets: rows})
  end

  @doc "GET /v1/tickets/inbox/:id — operator reads one thread."
  def show_operator(conn, %{"id" => id}) do
    case Thread.get_for_operator(id, dataset(conn), scope_opts(conn)) do
      {:ok, ticket} -> render_ticket(conn, ticket)
      {:error, :not_found} -> not_found(conn)
    end
  end

  @doc "POST /v1/tickets/:id/answer — operator answers; body `close: true` chains a close."
  def answer(conn, %{"id" => id} = params) do
    case Thread.get_for_operator(id, dataset(conn), scope_opts(conn)) do
      {:ok, ticket} ->
        author = {"operator", operator_label(conn)}

        case Thread.append(ticket, author, params["body"], params["attachments"] || []) do
          {:ok, %Document{} = answered} ->
            emit(answered, "ticket.answered")
            maybe_chain_close(conn, answered, params["close"])

          {:error, :body_required} ->
            bad_request(conn, "body is required")

          {:error, :thread_full} ->
            thread_full(conn)

          {:error, reason} ->
            unprocessable(conn, "answer_failed", inspect(reason))
        end

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  @doc "POST /v1/tickets/:id/close — operator closes."
  def close(conn, %{"id" => id}) do
    case Thread.get_for_operator(id, dataset(conn), scope_opts(conn)) do
      {:ok, ticket} ->
        case Thread.close(ticket) do
          {:ok, %Document{} = closed} ->
            emit(closed, "ticket.closed")
            render_ticket(conn, closed)

          {:error, reason} ->
            unprocessable(conn, "close_failed", inspect(reason))
        end

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  # ── Answer→close chaining ────────────────────────────────────────────────

  # `close: true` on an answer body chains an operator close after the answer
  # append committed, so "answer and close" is one round-trip. Truthy = the
  # JSON boolean `true` or the string "true".
  defp maybe_chain_close(conn, %Document{} = answered, close_flag)
       when close_flag in [true, "true"] do
    case Thread.close(answered) do
      {:ok, %Document{} = closed} ->
        emit(closed, "ticket.closed")
        render_ticket(conn, closed)

      _ ->
        # The answer landed; only the close chain failed — surface the answer.
        render_ticket(conn, answered)
    end
  end

  defp maybe_chain_close(conn, %Document{} = answered, _), do: render_ticket(conn, answered)

  # ── Credential extraction (identity from the credential, never the body) ─

  # Run `fun.(key)` with the resolved ticket key, or short-circuit to a 401 conn
  # when no key is assigned. Keeps every submitter action returning a conn even
  # on the auth-miss path.
  defp with_key(conn, fun) do
    case conn.assigns[:ticket_key] do
      nil -> unauthorized(conn)
      key -> fun.(key)
    end
  end

  defp key_name(key), do: Map.get(key, :name) || Map.get(key, "name") || "submitter"

  # The operator's authored name is the token's label (then name), never a body
  # field. Falls back to a generic "operator" when neither is set.
  defp operator_label(conn) do
    case conn.assigns[:api_token] do
      %{label: label} when is_binary(label) and label != "" -> label
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "operator"
    end
  end

  # ── Rendering ────────────────────────────────────────────────────────────

  defp render_ticket(conn, %Document{} = doc, status \\ :ok) do
    conn
    |> put_status(status)
    |> json(%{ok: true, ticket: Thread.to_map(doc)})
  end

  # Submitter list row: drop the full thread + internal key_id, keep the
  # at-a-glance fields.
  defp summary(map) do
    Map.drop(map, [:messages, :key_id])
  end

  # Operator inbox row: the summary plus the waiting age and an explicit seen
  # signal so "who has waited longest / did they get the answer" is one read.
  defp inbox_row(map, now) do
    map
    |> summary()
    |> Map.put(:waiting_age_seconds, Triage.waiting_age(map, now))
    |> Map.put(:seen, not is_nil(map.submitter_seen_at))
  end

  # ── Scope / dataset ──────────────────────────────────────────────────────

  # Reads an optional `?dataset=` override, defaulting to production. Robust to
  # a conn whose params were never fetched (e.g. a direct action-unit test):
  # an unfetched params struct is treated as "no override".
  defp dataset(conn) do
    case conn.params do
      %Plug.Conn.Unfetched{} -> @default_dataset
      params when is_map(params) -> Map.get(params, "dataset") || @default_dataset
      _ -> @default_dataset
    end
  end

  # ── Error envelopes ──────────────────────────────────────────────────────

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{ok: false, reason: "unauthorized", message: "a ticket key is required"})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{ok: false, reason: "not_found", message: "ticket not found"})
  end

  defp bad_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{ok: false, reason: "bad_request", message: message})
  end

  defp unprocessable(conn, reason, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{ok: false, reason: reason, message: message})
  end

  defp thread_full(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      ok: false,
      reason: "thread_full",
      message: "this ticket's thread is full — open a fresh ticket"
    })
  end

  # ── Semantic mutation events (seam) ──────────────────────────────────────

  # Emit a ticket-lifecycle `mutation_events` row (`ticket.created/answered/
  # reopened/closed`) following the `Barkpark.Tasks` precedent. Best-effort:
  # `Content.{create,upsert}_document` already broadcast the generic
  # create/update, so a failure here (or the helper being unreachable in a
  # stripped build) must never fail the request — it only costs the semantic
  # event. This is the clearly-marked seam a richer event pipeline can grow
  # from; it does NOT gate any behaviour.
  defp emit(%Document{} = doc, kind) do
    Barkpark.Tasks.Internal.insert_mutation_event!(doc, kind, nil)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
