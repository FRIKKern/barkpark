defmodule Barkpark.Plugins.Tickets.Thread do
  @moduledoc """
  The embedded ticket thread + the pure lifecycle state machine (charter
  Decisions 2 & 3).

  One ticket = one `type:ticket` document = one conversation. The thread is an
  append-only `content.messages` array; every message carries its author
  stamped FROM THE CREDENTIAL (the key's name for a submitter, the operator
  token's label for an operator) — never from the request body, so a leaked
  key can spoof neither identity nor status.

  Message shape:

      %{
        "id"          => "m-<hex>",
        "author_kind" => "submitter" | "operator",
        "author_name" => "<from the credential>",
        "body"        => "<text>",
        "attachments" => ["<asset_id>", ...],
        "at"          => "<iso8601>"
      }

  ## Status is derived, never client-set

  `transition/2` is the whole lifecycle, as a pure function:

      submitter create        → "open"
      operator answer         → "answered"
      submitter reply         → "open"     (auto-reopen; waiting_since reset)
      operator close          → "closed"

  ## Persistence

  This module is a PLUGIN module, so it writes ONLY through `Barkpark.Content`
  (never `Repo` — that would bypass the draft-prefix, lifecycle hooks, and
  PubSub broadcast). Appends are serialized with an optimistic
  compare-and-set on the document `rev` (`if_rev`), retried a bounded number
  of times, so two concurrent replies can't clobber each other's message.

  ## Scoping (fail-closed, never leak existence)

  A ticket key sees ONLY its own tickets: `owned_by_key?/2` matches
  `content.key_id`. A lookup for a foreign (or non-existent) id returns
  `{:error, :not_found}` — 404, never 403 — so a key can't probe which ids
  exist. Lookups go through `Content.get_document/4`, which filters on the
  `doc_id` STRING column (not the `:binary_id` primary key), so there is no
  `Ecto.CastError` surface here — a raw, non-UUID id is a plain no-match, not a
  500 (the binary_id CastError gotcha applies only to `Repo.get/2` by PK, which
  this module never calls).
  """

  alias Barkpark.Content
  alias Barkpark.Content.Document

  @type_name "ticket"
  @dataset_default "production"

  # Charter Decision 2: cap the embedded thread so one runaway ticket can't
  # grow an unbounded document. Past the cap, callers get a 422 "open a fresh
  # ticket" rather than an ever-larger row.
  @max_messages 200

  # Per-field bounds on the LOW-TRUST submitter surface (and, for symmetry,
  # operator appends). "Leaked key = spam, never data" also means BOUNDED spam:
  # without these, one hostile key could stuff megabytes into a single message
  # body (× #{@max_messages} messages = an unbounded jsonb row) or thousands of
  # junk strings into `attachments`. Generous for real use, hard for abuse.
  #
  # The subject bound must stay UNDER 255: it doubles as the document `title`,
  # a varchar(255) column — past that, the insert raises at the DB (a raw 500
  # to the key-holder) instead of this clean 422.
  @max_subject_bytes 200
  @max_body_bytes 65_536
  @max_attachments_per_message 10

  # Bounded CAS retries on a concurrent-append rev bump before giving up.
  @cas_retries 3

  # ── Pure lifecycle state machine ─────────────────────────────────────────

  @doc """
  The pure lifecycle transition. `action` is one of `:create`, `:reply`
  (submitter), `:answer`, `:close` (operator). Total by design — status is
  ALWAYS derived from the action, never read from client input.
  """
  @spec transition(String.t() | nil, :create | :reply | :answer | :close) :: String.t()
  def transition(_status, :create), do: "open"
  def transition(_status, :reply), do: "open"
  def transition(_status, :answer), do: "answered"
  def transition(_status, :close), do: "closed"

  @doc "Maps an author kind to the lifecycle action its message drives."
  @spec action_for(String.t()) :: :reply | :answer
  def action_for("submitter"), do: :reply
  def action_for("operator"), do: :answer

  # ── Create ───────────────────────────────────────────────────────────────

  @doc """
  Create a ticket from a key, with its first (submitter) message.

  `attrs` carries `:subject`, `:body`, and optional `:attachments` (asset id
  strings) — atom OR string keys accepted. The author is stamped from the key
  (`key.name`), never from the body. Status starts `open` and `waiting_since`
  is stamped now (the operator's move).

  Returns `{:ok, %Document{}}` or `{:error, :subject_required | :body_required
  | :subject_too_long | :body_too_long | :too_many_attachments}` / a `Content`
  write error.
  """
  @spec create(map(), map()) :: {:ok, Document.t()} | {:error, term()}
  def create(key, attrs) do
    subject = attrs |> afetch(:subject) |> trim()
    body = attrs |> afetch(:body) |> trim()
    attachments = normalize_attachments(afetch(attrs, :attachments))

    cond do
      subject in [nil, ""] ->
        {:error, :subject_required}

      body in [nil, ""] ->
        {:error, :body_required}

      byte_size(subject) > @max_subject_bytes ->
        {:error, :subject_too_long}

      byte_size(body) > @max_body_bytes ->
        {:error, :body_too_long}

      length(attachments) > @max_attachments_per_message ->
        {:error, :too_many_attachments}

      true ->
        name = key_name(key)
        now = now_iso()
        message = build_message("submitter", name, body, attachments)

        content = %{
          "subject" => subject,
          "status" => "open",
          "key_id" => kfetch(key, :id),
          "key_name" => name,
          "messages" => [message],
          "submitter_seen_at" => nil,
          "waiting_since" => now
        }

        Content.create_document(
          @type_name,
          %{"title" => subject, "content" => content},
          dataset_of(key),
          key_scope(key)
        )
    end
  end

  # ── Append (submitter reply / operator answer) ───────────────────────────

  @doc """
  Append a message to a ticket and derive the new status from the author kind.

  `author` is `{"submitter", name}` or `{"operator", name}` — the name comes
  from the CREDENTIAL, so callers pass the key name / operator label, never a
  body field. A submitter append auto-reopens (`open`, `waiting_since` reset);
  an operator append answers (`answered`) and clears `submitter_seen_at` so the
  delivery signal reflects THIS answer.

  Re-reads the latest ticket, CAS-appends on `rev` (bounded retry), and caps
  the thread at #{@max_messages} messages — past which it returns
  `{:error, :thread_full}` (the controller maps that to 422 "open a fresh
  ticket"). A message body over #{@max_body_bytes} bytes or more than
  #{@max_attachments_per_message} attachments is rejected
  (`:body_too_long` / `:too_many_attachments`).
  """
  @spec append(Document.t(), {String.t(), String.t()}, String.t(), [String.t()]) ::
          {:ok, Document.t()} | {:error, term()}
  def append(%Document{} = ticket, {kind, name}, body, attachments)
      when kind in ["submitter", "operator"] do
    body = trim(body)
    attachments = normalize_attachments(attachments)

    cond do
      body in [nil, ""] ->
        {:error, :body_required}

      byte_size(body) > @max_body_bytes ->
        {:error, :body_too_long}

      length(attachments) > @max_attachments_per_message ->
        {:error, :too_many_attachments}

      true ->
        message = build_message(kind, name, body, attachments)

        update(ticket, fn content ->
          messages = messages_of(content)

          if length(messages) >= @max_messages do
            {:error, :thread_full}
          else
            status = transition(Map.get(content, "status", "open"), action_for(kind))

            new_content =
              content
              |> Map.put("messages", messages ++ [message])
              |> Map.put("status", status)
              |> apply_side_effects(kind)

            {:ok, new_content}
          end
        end)
    end
  end

  # Submitter reply → the ball is back on the operator: reset waiting_since.
  # Operator answer → the ball is on the submitter, and they haven't seen THIS
  # answer yet: clear submitter_seen_at so the next poll re-stamps it.
  defp apply_side_effects(content, "submitter"), do: Map.put(content, "waiting_since", now_iso())
  defp apply_side_effects(content, "operator"), do: Map.put(content, "submitter_seen_at", nil)

  # ── Operator close ───────────────────────────────────────────────────────

  @doc """
  Close a ticket (operator action, no message). Derives `status = "closed"`.
  """
  @spec close(Document.t()) :: {:ok, Document.t()} | {:error, term()}
  def close(%Document{} = ticket) do
    update(ticket, fn content ->
      {:ok, Map.put(content, "status", transition(Map.get(content, "status", "open"), :close))}
    end)
  end

  # ── Operator orchestration (shared by HTTP + Studio) ─────────────────────
  #
  # The answer/close ORCHESTRATION (append + optional chained close + semantic
  # mutation-event emission) lives here, not in the controller, so BOTH the
  # HTTP operator surface (`BarkparkWeb.TicketsController`) and the Studio
  # inbox (`InboxLive`) go through ONE code path. That is what guarantees a
  # Studio answer emits the very same `ticket.answered`/`ticket.closed` events
  # a webhook consumer sees from the HTTP path — a fork here would let Studio
  # answers silently skip the semantic event.

  @doc """
  Operator answer orchestration. Appends an operator message (author stamped
  from `operator_name` — the credential's label, NEVER a body field), emits
  `ticket.answered`, and — when `close: true` — chains an operator close that
  emits `ticket.closed`, so "answer & close" is one call.

  Returns `{:ok, %Document{}}` (the answered, or answered-then-closed, ticket)
  or an `{:error, reason}` from `append/4` (`:body_required`, `:thread_full`,
  `:body_too_long`, `:too_many_attachments`, …). If the answer lands but the
  chained close fails, the answered ticket is returned `{:ok, _}` — the close
  is best-effort and the operator's words are already saved.

  `opts`: `:close` (boolean, default `false`), `:attachments` (list, default
  `[]`).
  """
  @spec operator_answer(Document.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def operator_answer(%Document{} = ticket, operator_name, body, opts \\ []) do
    close? = Keyword.get(opts, :close, false)
    attachments = Keyword.get(opts, :attachments, [])

    case append(ticket, {"operator", operator_name}, body, attachments) do
      {:ok, %Document{} = answered} ->
        emit_event(answered, "ticket.answered")
        if close?, do: chain_close(answered), else: {:ok, answered}

      {:error, _} = err ->
        err
    end
  end

  # Chain an operator close after an answer committed. A failed close does NOT
  # fail the whole call — the answer is already saved — so we surface the
  # answered ticket instead (mirrors the controller's prior maybe_chain_close/3).
  defp chain_close(%Document{} = answered) do
    case operator_close(answered) do
      {:ok, %Document{} = closed} -> {:ok, closed}
      _ -> {:ok, answered}
    end
  end

  @doc """
  Operator close orchestration: closes the ticket and emits `ticket.closed`.
  Shared by the HTTP surface and the Studio inbox so a Studio close emits the
  same mutation event a webhook consumer sees from the HTTP path.
  """
  @spec operator_close(Document.t()) :: {:ok, Document.t()} | {:error, term()}
  def operator_close(%Document{} = ticket) do
    case close(ticket) do
      {:ok, %Document{} = closed} ->
        emit_event(closed, "ticket.closed")
        {:ok, closed}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Emit a ticket-lifecycle `mutation_events` row (`ticket.created` /
  `ticket.answered` / `ticket.reopened` / `ticket.closed`) — the semantic event
  webhook consumers subscribe to, following the `Barkpark.Tasks` precedent.

  Best-effort: `Content.{create,upsert}_document` already broadcast the generic
  create/update, so a failure here (or `Tasks.Internal` being unreachable in a
  stripped build) must never fail the caller — it only costs the semantic
  event. Public so BOTH the controller (create / reopen) and this module's
  operator orchestration (answer / close) emit through ONE path — no forked
  emitter drifts out of sync (see MEMORY: error-emitters-duplicated).
  """
  @spec emit_event(Document.t(), String.t()) :: :ok
  def emit_event(%Document{} = doc, kind) do
    Barkpark.Tasks.Internal.insert_mutation_event!(doc, kind, nil)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ── Seen stamp (delivery signal) ─────────────────────────────────────────

  @doc """
  Stamp `submitter_seen_at` when the key reads its ticket while the status is
  `answered`/`closed` — the "did she get it?" delivery signal (Decision 3).

  Only writes when the stamp is currently absent (so a poll loop doesn't write
  on every read, and the stamp records first-sight-since-the-last-answer —
  operator answers reset it). A ticket that is `open`, or already stamped,
  returns unchanged with no DB write.
  """
  @spec stamp_seen(Document.t()) :: {:ok, Document.t()} | {:error, term()}
  def stamp_seen(%Document{content: content} = ticket) do
    content = content || %{}
    status = Map.get(content, "status", "open")

    if status in ["answered", "closed"] and is_nil(Map.get(content, "submitter_seen_at")) do
      update(ticket, fn fresh ->
        if is_nil(Map.get(fresh, "submitter_seen_at")) do
          {:ok, Map.put(fresh, "submitter_seen_at", now_iso())}
        else
          # A concurrent read already stamped it — nothing to change.
          {:ok, fresh}
        end
      end)
    else
      {:ok, ticket}
    end
  end

  # ── Scoping / lookups ────────────────────────────────────────────────────

  @doc """
  True when `ticket` belongs to `key` (matches `content.key_id`). The scoping
  predicate the submitter surface filters on.
  """
  @spec owned_by_key?(Document.t(), map()) :: boolean()
  def owned_by_key?(%Document{content: content}, key) do
    kid = kfetch(key, :id)
    is_binary(kid) and kid != "" and Map.get(content || %{}, "key_id") == kid
  end

  def owned_by_key?(_ticket, _key), do: false

  @doc """
  Fetch a ticket for a KEY: found within the key's scope AND owned by it, or
  `{:error, :not_found}`. A foreign or missing id is indistinguishable (both
  404) so the key can't probe existence.
  """
  @spec get_for_key(map(), String.t()) :: {:ok, Document.t()} | {:error, :not_found}
  def get_for_key(key, id) do
    case find(id, dataset_of(key), key_scope(key)) do
      {:ok, ticket} ->
        if owned_by_key?(ticket, key), do: {:ok, ticket}, else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Fetch a ticket for an OPERATOR: any ticket within the operator's tenancy
  scope (no key filter). `{:error, :not_found}` when absent in scope.
  """
  @spec get_for_operator(String.t(), String.t(), keyword()) ::
          {:ok, Document.t()} | {:error, :not_found}
  def get_for_operator(id, dataset, scope) do
    find(id, dataset, operator_scope(scope))
  end

  @doc """
  List every ticket owned by a key, within its scope. Newest-touched first —
  the operator inbox re-orders via `Triage`; the submitter's own list is fine
  in recency order.
  """
  @spec list_for_key(map(), keyword()) :: [Document.t()]
  def list_for_key(key, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1000)

    @type_name
    |> Content.list_documents(dataset_of(key), key_scope(key) ++ [limit: limit])
    |> Enum.filter(&owned_by_key?(&1, key))
  end

  @doc """
  List every ticket in an operator's WORKSPACE (all keys). The inbox feed.

  The operator tenancy boundary for tickets is the workspace, never the
  project — see `operator_scope/1`.
  """
  @spec list_for_operator(String.t(), keyword()) :: [Document.t()]
  def list_for_operator(dataset, scope) do
    scope = operator_scope(scope)
    limit = Keyword.get(scope, :limit, 1000)
    Content.list_documents(@type_name, dataset, Keyword.put(scope, :limit, limit))
  end

  # The operator tenancy boundary for tickets is the WORKSPACE, not the
  # project. Keys bind at the workspace level (`Keys.mint` sets `workspace_id`,
  # never a project), so every ticket is created with the key's scope —
  # `project_id` nil. `Content.list_documents` / `get_document` run
  # `Content.Scope.scope_to_workspace_or_global/3` (threaded from
  # `Content.Query.base_query/4`), whose binary-workspace arm delegates to
  # `scope_to_workspace/3` and filters `project_id ==
  # ^project_id` with NO null fallback: a project-scoped operator context would
  # therefore see ZERO key-created tickets. Dropping `project_id` here keeps the
  # whole workspace's tickets visible to any operator in that workspace,
  # regardless of the project pane they happen to be viewing. (The submitter
  # surface is unaffected — it scopes through `key_scope/1`, which never carries
  # a project either.)
  #
  # DIRECTION WARNING (do not read the sentence above as fail-closed). The
  # helper named there is `scope_to_workspace_or_global/3`, NOT the fail-closed
  # `scope_to_workspace/3`, and the two have OPPOSITE nil behaviour:
  #
  #   scope_to_workspace_or_global(q, nil, _) -> query UNTOUCHED  = every tenant
  #   scope_to_workspace(q, nil, _)           -> where(q, false)  = zero rows
  #
  # So an operator scope that resolved NO workspace widens this read to every
  # tenant's tickets rather than narrowing it. Reaching that state needs an
  # absent `:workspace_id`, which on the LiveView path means an unset
  # `:current_workspace` (see `BarkparkWeb.ScopeHelpers.scope_opts/1`: the
  # `:shared_only` sentinel is emitted for a `%Plug.Conn{}` and NOT for a
  # socket). Trace the helper before assuming a direction.
  #
  # That warning is now CLOSED rather than merely recorded: this function
  # states its own tenancy intent instead of inheriting whichever default the
  # transport happened to supply. An absent OR explicitly-nil `:workspace_id`
  # becomes the `:shared_only` sentinel, so both transports answer the tenancy
  # question the same way. `BarkparkWeb.TicketsController` already emitted
  # `:shared_only` through the conn arm of `ScopeHelpers.scope_opts/1`, while
  # `Barkpark.Plugins.Tickets.InboxLive` reached this same read through the
  # socket arm, which DROPS the key on a nil `:current_workspace`. Since
  # `get_for_operator/3` shares this helper, the inbox's answer/close handlers
  # were a cross-tenant WRITE on the widened read.
  #
  # `:shared_only` is NOT "zero rows": `Content.Scope.scope_to_workspace/3`
  # resolves it to `where(is_nil(x.workspace_id))` — the shared/global layer —
  # so an unseeded single-tenant install (`Tenancy.get_default_workspace/0`
  # returns nil, and its tickets carry a NULL workspace) keeps seeing exactly
  # its own tickets. Only a multi-tenant install changes behaviour, and there
  # it stops leaking.
  #
  # `Keyword.put_new/3` would NOT be enough: it leaves a key that is PRESENT
  # with a nil value untouched, and nil is precisely the leaking input.
  defp operator_scope(scope) do
    scope
    |> Keyword.delete(:project_id)
    |> Keyword.put(:workspace_id, Keyword.get(scope, :workspace_id) || :shared_only)
  end

  # ── Presenter ────────────────────────────────────────────────────────────

  @doc """
  Flatten a ticket `%Document{}` to a plain map (the shape `Triage` orders and
  the controller renders). The client-facing `:id` is the published (un-draft)
  doc id.
  """
  @spec to_map(Document.t()) :: map()
  def to_map(%Document{} = doc) do
    content = doc.content || %{}
    messages = messages_of(content)

    %{
      id: Content.published_id(doc.doc_id),
      subject: Map.get(content, "subject"),
      status: Map.get(content, "status", "open"),
      key_id: Map.get(content, "key_id"),
      key_name: Map.get(content, "key_name"),
      messages: messages,
      message_count: length(messages),
      has_attachments: Enum.any?(messages, fn m -> attachments_of(m) != [] end),
      submitter_seen_at: Map.get(content, "submitter_seen_at"),
      waiting_since: Map.get(content, "waiting_since"),
      updated_at: doc.updated_at
    }
  end

  # ── Internal: CAS update ─────────────────────────────────────────────────

  # Re-read the latest row, apply `transform` to its content, and write back
  # with an optimistic CAS on `rev`. A concurrent append that bumped the rev
  # loses the fence (`{:rev_mismatch, _}`) and we retry from a fresh read up to
  # @cas_retries times. `transform` may short-circuit with `{:error, reason}`
  # (e.g. `:thread_full`) which is returned verbatim.
  defp update(%Document{} = doc, transform, retries \\ @cas_retries) do
    case refetch(doc) do
      {:ok, %Document{} = fresh} ->
        case transform.(fresh.content || %{}) do
          {:ok, new_content} ->
            case persist(fresh, new_content) do
              {:ok, updated} ->
                {:ok, updated}

              {:error, {:rev_mismatch, _}} when retries > 0 ->
                update(doc, transform, retries - 1)

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp persist(%Document{} = fresh, new_content) do
    attrs = %{
      "doc_id" => fresh.doc_id,
      "type" => @type_name,
      "title" => Map.get(new_content, "subject") || fresh.title,
      "content" => new_content,
      "status" => fresh.status || "draft"
    }

    Content.upsert_document(
      @type_name,
      attrs,
      fresh.dataset,
      doc_scope(fresh) ++ [if_rev: fresh.rev]
    )
  end

  defp refetch(%Document{doc_id: doc_id, dataset: dataset} = doc) do
    Content.get_document(doc_id, @type_name, dataset, doc_scope(doc))
  end

  # Try the id as given, then its draft twin, then its published twin. Tickets
  # are stored as drafts (`drafts.ticket-…`), but a caller may hand us either
  # the bare published id (rendered to them) or the raw stored id.
  defp find(id, dataset, scope) when is_binary(id) and id != "" do
    published = Content.published_id(id)
    draft = Content.draft_id(published)

    [draft, id, published]
    |> Enum.uniq()
    |> Enum.find_value({:error, :not_found}, fn candidate ->
      case Content.get_document(candidate, @type_name, dataset, scope) do
        {:ok, %Document{} = doc} -> {:ok, doc}
        _ -> false
      end
    end)
  end

  defp find(_id, _dataset, _scope), do: {:error, :not_found}

  # ── Internal: builders + accessors ───────────────────────────────────────

  defp build_message(kind, name, body, attachments) do
    %{
      "id" => "m-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)),
      "author_kind" => kind,
      "author_name" => name,
      "body" => body,
      "attachments" => attachments,
      "at" => now_iso()
    }
  end

  defp messages_of(content) do
    case Map.get(content, "messages") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp attachments_of(message) do
    case Map.get(message, "attachments") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp normalize_attachments(list) when is_list(list),
    do: Enum.filter(list, &(is_binary(&1) and &1 != ""))

  defp normalize_attachments(_), do: []

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: nil

  # ── Internal: key/doc scope extraction (tolerant of struct or map) ───────

  defp key_name(key), do: kfetch(key, :name) || "submitter"

  defp dataset_of(key), do: kfetch(key, :dataset) || @dataset_default

  defp key_scope(key) do
    []
    |> put_if(:workspace_id, kfetch(key, :workspace_id))
    |> put_if(:project_id, kfetch(key, :project_id))
  end

  defp doc_scope(%Document{workspace_id: ws, project_id: pr}) do
    []
    |> put_if(:workspace_id, ws)
    |> put_if(:project_id, pr)
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, _key, ""), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  # Read a key attribute spelled as an atom or a string (struct or plain map).
  defp kfetch(key, field) when is_atom(field) do
    case Map.get(key, field) do
      nil -> Map.get(key, Atom.to_string(field))
      value -> value
    end
  end

  defp afetch(attrs, field) when is_atom(field) do
    case Map.get(attrs, field) do
      nil -> Map.get(attrs, Atom.to_string(field))
      value -> value
    end
  end
end
