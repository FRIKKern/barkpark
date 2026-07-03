defmodule Barkpark.Plugins.Tickets do
  @moduledoc """
  Tickets — a NAMED api key IS identity.

  An operator mints a named, low-trust key (`bptk_…`) and hands it to an
  outsider. The key-holder files **tickets** — requests/questions that can
  carry media — which live as `type:ticket` documents with an embedded,
  append-only message thread. The operator answers from Studio / the `bp`
  CLI; the key-holder retrieves the answer with the SAME key. We know it is
  them because they sent it.

  ## The one-noun model (charter Decisions 2, 3, 5)

  One ticket = one conversation = one document = one fetch for the polling
  key-holder. **Status IS the turn indicator**, derived and never client-set:

    * `open`     — the operator's move (a submitter just created or replied)
    * `answered` — the submitter's move (the operator answered)
    * `closed`   — done (the operator closed it)

  A submitter reply on an `answered`/`closed` ticket AUTO-REOPENS it (back to
  `open`, `waiting_since` reset). Triage is then trivial: `status=open`, oldest
  `waiting_since` first — the operator sees only what is waiting on them.

  ## What this module contributes (thin plugin wiring, tasks.ex precedent)

    * `register_schemas/1` — the `ticket` document type (Decision 2 field
      contract), visibility `"private"` so it never reaches the anonymous
      query API. Auto-registers on every boot via
      `Barkpark.Plugins.Bootstrap.register_all_schemas/0`, idempotent on
      `(name, dataset)`.
    * `register_routes/1` — the COMPLETE charter route table across three
      auth buckets (`:ticket_key` submitter surface, `:token_root` operator
      surface, `:api` admin key-mint surface) plus the Studio `:admin`
      LiveView. Several referenced modules (`TicketKeysController`,
      `TicketsAttachmentsController`, `InboxLive`) and the `:ticket_key`
      auth value are built/mounted by SIBLING slices — module atoms in
      route-spec DATA are safe even when the module doesn't exist in this
      worktree, and unknown `auth:` values are silently dropped by the
      host router's `route_in_scope?`, so the whole table is declared here
      and merges cleanly across worktrees.
    * `cli_commands/0` — merge-safe delegate to `Tickets.CLI` (built by the
      CLI slice). Guarded with `Code.ensure_loaded?/1` so it returns `[]`
      until that module merges.

  The heavy lifting — the embedded thread, the pure lifecycle state machine,
  triage ordering, and the submitter/operator HTTP surface — lives in
  `Barkpark.Plugins.Tickets.{Thread,Triage}` and
  `BarkparkWeb.TicketsController`.

  Plugin off (`config :barkpark, :plugins, []`) = zero routes, zero schemas —
  Barkpark doesn't know tickets exist.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/tickets/plugin.json"

  alias Barkpark.Content.SchemaDefinition

  @dataset_default "production"

  @doc """
  Declares the `ticket` document type (charter Decision 2).

  Fields — `subject`, `status`, `key_id`, `key_name`, `messages` (the
  append-only thread), `submitter_seen_at`, `waiting_since` — all live under
  the document `content` map, the same substrate `task` rides. Visibility is
  `"private"`: tickets are only ever read through the server-side
  ticket-scoped endpoints (a ticket key can't reach `/v1/data` at all), never
  the anonymous public query API.

  `dataset` comes from `opts[:dataset]` when supplied (Bootstrap calls this
  with `[]`), defaulting to `"production"` — matching every other seed schema.
  """
  @impl Barkpark.Plugin
  def register_schemas(opts) do
    dataset = Keyword.get(opts, :dataset, @dataset_default)
    [ticket_schema(dataset)]
  end

  @doc "Just the `ticket` schema struct (callers that only need one)."
  @spec ticket_schema(String.t()) :: SchemaDefinition.t()
  def ticket_schema(dataset \\ @dataset_default) do
    %SchemaDefinition{
      name: "ticket",
      title: "Ticket",
      icon: "🎫",
      # PRIVATE: never served by the anonymous query API. Tickets are read
      # ONLY through the ticket-scoped endpoints (submitter key or operator
      # token) — a leaked key is spam, never data.
      visibility: "private",
      dataset: dataset,

      # Generic list-row preview (host affordance): status badge + the key
      # name as meta, so the Studio doc-list reads "who is waiting" at a glance.
      list_preview: %{
        "badge" => "status",
        "meta" => %{"field" => "key_name"}
      },
      groups: [
        %{"name" => "thread", "title" => "Thread", "icon" => "messages-square"},
        %{"name" => "system", "title" => "System", "icon" => "settings"}
      ],

      # Bookmarkable ?desk= filter chips over the ticket list pane — the
      # turn-encoding statuses (open = your move) as one-tap filters.
      desk_groups: [
        %{
          "name" => "open",
          "title" => "Needs answer",
          "filter" => %{"content.status" => %{"eq" => "open"}}
        },
        %{
          "name" => "answered",
          "title" => "Waiting on them",
          "filter" => %{"content.status" => %{"eq" => "answered"}}
        },
        %{
          "name" => "closed",
          "title" => "Closed",
          "filter" => %{"content.status" => %{"eq" => "closed"}}
        },
        %{"name" => "all", "title" => "All", "filter" => %{}}
      ],
      fields: [
        %{
          "name" => "subject",
          "type" => "string",
          "title" => "Subject",
          "group" => "thread"
        },
        %{
          "name" => "status",
          "type" => "string",
          "title" => "Status",
          "group" => "thread",
          # Derived, never client-set — the turn indicator (Decision 3).
          "options" => %{"list" => ["open", "answered", "closed"]},
          "readOnly" => true
        },
        %{
          "name" => "messages",
          "type" => "array",
          "title" => "Thread",
          "group" => "thread",
          "of" => [%{"type" => "object"}],
          "readOnly" => true
        },
        %{
          "name" => "key_name",
          "type" => "string",
          "title" => "From (key name)",
          "group" => "system",
          "readOnly" => true
        },
        %{
          "name" => "key_id",
          "type" => "string",
          "title" => "Key id",
          "group" => "system",
          "readOnly" => true
        },
        %{
          "name" => "waiting_since",
          "type" => "datetime",
          "title" => "Waiting since",
          "group" => "system",
          "readOnly" => true
        },
        %{
          "name" => "submitter_seen_at",
          "type" => "datetime",
          "title" => "Submitter last saw answer",
          "group" => "system",
          "readOnly" => true
        }
      ]
    }
  end

  @doc """
  Contributes a Tickets desk group to the Studio Structure pane, gated on the
  `ticket` schema existing in the requested dataset (mirrors tasks.ex).
  """
  @impl Barkpark.Plugin
  def desk_items(dataset) do
    if ticket_schema_present?(dataset) do
      [%{type: :document_list, label: "Tickets", doc_type: "ticket", icon: "🎫"}]
    else
      []
    end
  end

  # Failure-safe schema probe (tasks.ex precedent): a context with no DB
  # sandbox / no Repo (registration-time fingerprint, boot) must never crash
  # here — no schema reachable → no desk entry.
  defp ticket_schema_present?(dataset) do
    match?({:ok, _}, Barkpark.Content.get_schema("ticket", dataset))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  The COMPLETE charter route table (Pinned contracts).

  Three HTTP buckets + one Studio LiveView. Referenced modules that this
  worktree does NOT build — `BarkparkWeb.TicketKeysController` (mint, `:api`
  bucket), `BarkparkWeb.TicketsAttachmentsController` (`:ticket_key` bucket),
  `Barkpark.Plugins.Tickets.InboxLive` (`:admin` bucket) — are safe as atoms
  in route DATA; they mount when the sibling slice merges. Likewise the
  `:ticket_key` auth value: until the auth slice adds that bucket to the host
  router, `route_in_scope?` silently drops those specs, so declaring them here
  is harmless and lets the table merge in one place.

  STATIC-BEFORE-CATCHALL (tasks.ex:141 idiom): within each bucket the static
  paths (`/tickets/inbox`, `/tickets/keys`) are declared BEFORE the
  `/tickets/:id` dynamic segment so an operator/admin static route can never
  resolve as `:id = "inbox"`. The `:ticket_key` submitter block only has
  `/tickets` + `/tickets/:id/...`, so its ordering is self-consistent.
  """
  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      # ── Submitter surface (:ticket_key bucket — added by the auth slice) ──
      {:post, "/tickets", BarkparkWeb.TicketsController, :create, auth: :ticket_key},
      {:get, "/tickets", BarkparkWeb.TicketsController, :index_own, auth: :ticket_key},
      {:get, "/tickets/:id", BarkparkWeb.TicketsController, :show_own, auth: :ticket_key},
      {:post, "/tickets/:id/messages", BarkparkWeb.TicketsController, :reply, auth: :ticket_key},
      {:post, "/tickets/:id/attachments", BarkparkWeb.TicketsAttachmentsController, :create,
       auth: :ticket_key},
      {:get, "/tickets/:id/attachments/:asset_id", BarkparkWeb.TicketsAttachmentsController,
       :show, auth: :ticket_key},

      # ── Operator surface (:token_root bucket — mounted at /v1) ────────────
      # Static /tickets/inbox* BEFORE the submitter /tickets/:id catchall's
      # cousins; kept here in one block for readability.
      {:get, "/tickets/inbox", BarkparkWeb.TicketsController, :inbox, auth: :token_root},
      {:get, "/tickets/inbox/:id", BarkparkWeb.TicketsController, :show_operator,
       auth: :token_root},
      {:get, "/tickets/inbox/:id/attachments/:asset_id", BarkparkWeb.TicketsAttachmentsController,
       :show_operator, auth: :token_root},
      {:post, "/tickets/:id/answer", BarkparkWeb.TicketsController, :answer, auth: :token_root},
      {:post, "/tickets/:id/close", BarkparkWeb.TicketsController, :close, auth: :token_root},

      # ── Key-mint surface (:api bucket — admin, under /v1/plugins) ─────────
      # Static /tickets/keys BEFORE /tickets/keys/:id catchalls.
      {:post, "/tickets/keys", BarkparkWeb.TicketKeysController, :create, auth: :api},
      {:get, "/tickets/keys", BarkparkWeb.TicketKeysController, :index, auth: :api},
      {:post, "/tickets/keys/:id/rotate", BarkparkWeb.TicketKeysController, :rotate, auth: :api},
      {:post, "/tickets/keys/:id/pause", BarkparkWeb.TicketKeysController, :pause, auth: :api},
      {:post, "/tickets/keys/:id/unpause", BarkparkWeb.TicketKeysController, :unpause,
       auth: :api},
      {:delete, "/tickets/keys/:id", BarkparkWeb.TicketKeysController, :delete, auth: :api},

      # ── Studio operator inbox (:admin LiveView — under /studio) ───────────
      {:live, "/tickets", Barkpark.Plugins.Tickets.InboxLive, :index, auth: :admin}
    ]
  end

  @doc """
  Merge-safe CLI delegate (charter-pinned EXACTLY): contributes the `ticket`
  and `ticket-key` verbs the `/v1/capabilities` manifest exposes, but only
  once the sibling CLI slice's `Barkpark.Plugins.Tickets.CLI` module exists.
  Until then this returns `[]`, so the plugin compiles and boots standalone in
  every worktree.
  """
  @impl Barkpark.Plugin
  def cli_commands do
    if Code.ensure_loaded?(Barkpark.Plugins.Tickets.CLI),
      do: Barkpark.Plugins.Tickets.CLI.commands(),
      else: []
  end
end
