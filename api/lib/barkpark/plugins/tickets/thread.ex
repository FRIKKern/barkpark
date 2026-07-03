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

  Returns `{:ok, %Document{}}` or `{:error, :subject_required | :body_required}`
  / a `Content` write error.
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
  ticket").
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
    find(id, dataset, scope)
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
  List every ticket in an operator's tenancy scope (all keys). The inbox feed.
  """
  @spec list_for_operator(String.t(), keyword()) :: [Document.t()]
  def list_for_operator(dataset, scope) do
    limit = Keyword.get(scope, :limit, 1000)
    Content.list_documents(@type_name, dataset, Keyword.put(scope, :limit, limit))
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
