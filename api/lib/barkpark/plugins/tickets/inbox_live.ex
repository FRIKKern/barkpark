defmodule Barkpark.Plugins.Tickets.InboxLive do
  @moduledoc """
  Studio operator inbox for the Tickets epic — a **plugin-owned** LiveView
  (BulldocsLive precedent: a plugin can own a whole Studio page). The route

      {:live, "/tickets", #{inspect(__MODULE__)}, :index, auth: :admin}

  is declared in the sibling-owned `Barkpark.Plugins.Tickets` plugin module;
  the `:admin` live_session supplies auth, so this module writes NONE.

  ## What the operator sees (charter Decision 3 + 5)

  Three partitions, computed entirely by the pure
  `Barkpark.Plugins.Tickets.InboxPresenter`:

    * **Needs answer** — `open` tickets, oldest-waiting first. THE list. Amber.
    * **Waiting on them** — `answered` tickets with a delivery/seen signal.
    * **Recently closed** — `closed` tickets, collapsed.

  Opening a row shows the thread as a full-width timeline (NOT chat bubbles):
  author chip left (key-name pill for the submitter, tinted operator pill),
  timestamp right, body below, attachment links. The composer offers a split
  action — **Answer** (stay `answered`) and **Answer & close** — plus a
  confirmed **Close**. A key-management sub-view mints (one-time secret +
  handoff card), rotates and pauses ticket keys.

  ## Data seam (worktree isolation)

  Every database touch is funnelled through the private `fetch_*` / `apply_*`
  seams, which call the charter-pinned sibling contexts
  (`Barkpark.Plugins.Tickets.{Thread,Triage,Keys}`). Those siblings may be
  ABSENT in a given worktree, so each seam guards with `Code.ensure_loaded?/1`
  and degrades to an honest "backend unavailable" state instead of crashing.
  The view is driven entirely by `InboxPresenter` output, so the render tests
  run without the siblings and without the route.
  """

  use BarkparkWeb, :live_view

  require Logger

  alias Barkpark.Plugins.Tickets.InboxPresenter

  # Charter-pinned sibling contexts. Held as atoms and dispatched dynamically
  # (never a static call) so an absent module is a runtime-guarded no-op, not a
  # compile-time hard dependency.
  @thread Barkpark.Plugins.Tickets.Thread
  @keys Barkpark.Plugins.Tickets.Keys

  @impl true
  def mount(params, _session, socket) do
    dataset = Map.get(params, "dataset")

    socket =
      socket
      |> assign(
        page_title: "Tickets",
        nav_section: :tickets,
        dataset: dataset,
        view: :inbox,
        thread: nil,
        keys: [],
        mint_result: nil,
        data_error: nil,
        now: DateTime.utc_now()
      )
      |> load_inbox()

    {:ok, socket}
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_thread", %{"id" => id}, socket) do
    case fetch_thread(socket, id) do
      {:ok, ticket} ->
        {:noreply, assign(socket, view: :thread, thread: ticket, data_error: nil)}

      {:error, reason} ->
        {:noreply, socket |> assign(view: :thread, thread: nil) |> put_error(reason)}
    end
  end

  def handle_event("back_to_inbox", _params, socket) do
    {:noreply, socket |> assign(view: :inbox, thread: nil, mint_result: nil) |> load_inbox()}
  end

  def handle_event("open_keys", _params, socket) do
    {:noreply, socket |> assign(view: :keys, mint_result: nil) |> load_keys()}
  end

  def handle_event("answer", %{"ticket_id" => id} = params, socket) do
    # The clicked submit button contributes `action` ("answer" | "close");
    # a keyboard-Enter submit omits it → default to a plain answer.
    answer(socket, id, params["body"], close: params["action"] == "close")
  end

  def handle_event("close_ticket", %{"id" => id}, socket) do
    case apply_close(socket, id) do
      {:ok, ticket} ->
        {:noreply,
         socket
         |> assign(thread: ticket)
         |> put_flash(:info, "Ticket closed.")}

      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  def handle_event("mint_key", %{"name" => name}, socket) do
    case apply_mint(socket, name) do
      {:ok, %{raw: raw, key: key}} ->
        {:noreply,
         socket
         |> assign(mint_result: %{raw: raw, key_name: mint_key_name(key, name)})
         |> load_keys()
         |> put_flash(:info, "Key minted — copy the secret now, it is shown once.")}

      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  def handle_event("dismiss_mint", _params, socket) do
    {:noreply, assign(socket, mint_result: nil)}
  end

  def handle_event("rotate_key", %{"id" => id}, socket) do
    case apply_key_action(socket, :rotate, id) do
      {:ok, %{raw: raw, key: key}} ->
        {:noreply,
         socket
         |> assign(mint_result: %{raw: raw, key_name: mint_key_name(key, nil)})
         |> load_keys()
         |> put_flash(:info, "Key rotated — new secret shown once; history is kept.")}

      {:ok, _other} ->
        {:noreply, socket |> load_keys() |> put_flash(:info, "Key rotated.")}

      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  def handle_event("pause_key", %{"id" => id}, socket) do
    key_toggle(socket, :pause, id, "Key paused.")
  end

  def handle_event("unpause_key", %{"id" => id}, socket) do
    key_toggle(socket, :unpause, id, "Key resumed.")
  end

  # Fall-through: a stale/forged phx event must not FunctionClauseError-crash
  # the session. Keep LAST among handle_event/3 clauses.
  def handle_event(event, _params, socket) do
    Logger.warning("studio/tickets: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # Fall-through: an unexpected message must not crash the LiveView.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("studio/tickets: unhandled info #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Event helpers ─────────────────────────────────────────────────────────

  defp answer(socket, id, body, close: close?) do
    body = String.trim(body || "")

    if body == "" do
      {:noreply, put_flash(socket, :error, "Write an answer first.")}
    else
      case apply_answer(socket, id, body, close?) do
        {:ok, ticket} ->
          msg = if close?, do: "Answered and closed.", else: "Answer sent."
          {:noreply, socket |> assign(thread: ticket) |> put_flash(:info, msg)}

        {:error, reason} ->
          {:noreply, put_error(socket, reason)}
      end
    end
  end

  defp key_toggle(socket, action, id, ok_msg) do
    case apply_key_action(socket, action, id) do
      {:ok, _} -> {:noreply, socket |> load_keys() |> put_flash(:info, ok_msg)}
      {:error, reason} -> {:noreply, put_error(socket, reason)}
    end
  end

  defp put_error(socket, :unavailable),
    do: put_flash(socket, :error, "Tickets backend is not available in this build.")

  defp put_error(socket, reason),
    do: put_flash(socket, :error, "Action failed: #{inspect(reason)}")

  defp mint_key_name(key, fallback) when is_map(key) do
    Map.get(key, :name) || Map.get(key, "name") || fallback || "new key"
  end

  defp mint_key_name(_key, fallback), do: fallback || "new key"

  # ── Data seams (guarded sibling dispatch) ─────────────────────────────────

  defp load_inbox(socket) do
    case fetch_tickets(socket) do
      {:ok, tickets} ->
        assign(socket, presenter: InboxPresenter.build(tickets, socket.assigns.now), data_error: nil)

      {:error, reason} ->
        assign(socket, presenter: empty_model(), data_error: reason)
    end
  end

  defp load_keys(socket) do
    case fetch_keys(socket) do
      {:ok, keys} -> assign(socket, keys: keys, data_error: nil)
      {:error, reason} -> assign(socket, keys: [], data_error: reason)
    end
  end

  defp empty_model,
    do: %{needs_answer: [], waiting_on_them: [], recently_closed: [], badge_count: 0}

  # The single load seam. A sibling worktree wires `Thread.list_for_operator/1`
  # (workspace-scoped operator listing); absent here → honest unavailable.
  defp fetch_tickets(socket) do
    call(@thread, :list_for_operator, [scope(socket)])
  end

  defp fetch_thread(socket, id) do
    call(@thread, :get_for_operator, [scope(socket), id])
  end

  defp apply_answer(socket, id, body, close?) do
    call(@thread, :operator_answer, [scope(socket), id, body, [close: close?]])
  end

  defp apply_close(socket, id) do
    call(@thread, :operator_close, [scope(socket), id])
  end

  defp fetch_keys(socket) do
    call(@keys, :list, [scope(socket)])
  end

  defp apply_mint(socket, name) do
    call(@keys, :mint, [%{name: name, scope: scope(socket)}])
  end

  defp apply_key_action(_socket, :rotate, id), do: call(@keys, :rotate, [id])
  defp apply_key_action(_socket, :pause, id), do: call(@keys, :pause, [id])
  defp apply_key_action(_socket, :unpause, id), do: call(@keys, :unpause, [id])

  # Dynamic, absence-tolerant dispatch. Returns {:ok, term} | {:error, term}.
  # A sibling function may already return an {:ok, _}/{:error, _} tuple — we
  # pass those through; a bare value is wrapped in {:ok, _}.
  defp call(mod, fun, args) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      case apply(mod, fun, args) do
        {:ok, _} = ok -> ok
        {:error, _} = err -> err
        other -> {:ok, other}
      end
    else
      {:error, :unavailable}
    end
  rescue
    e ->
      Logger.error("studio/tickets: #{inspect(mod)}.#{fun} raised: #{Exception.message(e)}")
      {:error, :unavailable}
  end

  defp scope(socket) do
    %{
      workspace_id: socket.assigns[:workspace_id],
      project_id: socket.assigns[:project_id],
      dataset: socket.assigns[:dataset]
    }
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bp-tickets">
      <style>
        .bp-tickets { display:flex; flex-direction:column; min-height:0; flex:1; font-family:var(--font,ui-sans-serif,system-ui); }
        .bp-tk-topbar { display:flex; align-items:center; justify-content:space-between; padding:16px 24px; border-bottom:1px solid var(--border-muted,#2a2a2a); }
        .bp-tk-topbar-left { display:flex; align-items:center; gap:12px; }
        .bp-tk-topbar-right { display:flex; align-items:center; gap:8px; }
        .bp-tk-badge { display:inline-flex; align-items:center; height:22px; padding:0 10px; border-radius:999px; font-size:11px; font-weight:600; background:hsl(38 92% 50% / 0.14); color:var(--warning,#e0a11a); }
        .bp-tk-body { flex:1; overflow-y:auto; padding:20px 24px; }
        .bp-tk-banner { padding:10px 24px; font-size:13px; }
        .bp-tk-banner-ok { background:var(--success-bg,#10311d); color:var(--success,#2fbf5e); }
        .bp-tk-banner-error { background:var(--destructive-bg,#3a1414); color:var(--destructive,#e5484d); }

        .bp-tk-partition { margin-bottom:22px; }
        .bp-tk-partition-title { display:flex; align-items:center; gap:8px; font-size:12px; font-weight:700; text-transform:uppercase; letter-spacing:0.05em; color:var(--fg-muted,#9a9a9a); margin-bottom:8px; }
        .bp-tk-count { display:inline-flex; align-items:center; justify-content:center; min-width:18px; height:18px; padding:0 5px; border-radius:999px; font-size:11px; font-weight:600; background:var(--bg-accent,#222); color:var(--fg-muted,#9a9a9a); }
        .bp-tk-partition-empty { font-size:13px; padding:6px 2px; }
        .bp-tk-rows { display:flex; flex-direction:column; gap:6px; }

        .bp-tk-row { display:flex; align-items:center; gap:12px; width:100%; text-align:left; padding:10px 14px; border-radius:var(--radius-sm,7px); border:1px solid var(--border-muted,#2a2a2a); background:var(--bg-card,#161616); color:var(--fg,#eee); transition:background .12s,border-color .12s; }
        .bp-tk-row:hover { background:var(--bg-accent,#222); }
        /* Needs-answer rows are visually primary — amber/warn tint + left accent. */
        .bp-tk-tone-warn.bp-tk-row { border-left:3px solid var(--warning,#e0a11a); background:hsl(38 92% 50% / 0.05); }
        .bp-tk-tone-warn.bp-tk-row:hover { background:hsl(38 92% 50% / 0.1); }
        .bp-tk-tone-info.bp-tk-row { border-left:3px solid var(--primary,#3b82f6); }
        .bp-tk-tone-dim.bp-tk-row { opacity:0.72; }

        .bp-tk-keypill { display:inline-flex; align-items:center; height:20px; padding:0 8px; border-radius:999px; font-size:11px; font-weight:600; background:var(--bg-accent,#222); color:var(--fg,#eee); white-space:nowrap; max-width:180px; overflow:hidden; text-overflow:ellipsis; }
        .bp-tk-oppill { background:hsl(217 91% 60% / 0.16); color:var(--primary,#3b82f6); }
        .bp-tk-subject { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:14px; font-weight:500; }
        .bp-tk-clip { font-size:13px; opacity:0.8; }
        .bp-tk-msgs { font-size:12px; color:var(--fg-muted,#9a9a9a); white-space:nowrap; }
        .bp-tk-age { font-size:12px; font-weight:600; color:var(--fg-muted,#9a9a9a); font-variant-numeric:tabular-nums; min-width:34px; text-align:right; }
        .bp-tk-seen { font-size:11px; font-weight:500; white-space:nowrap; }
        .bp-tk-seen-yes { color:var(--success,#2fbf5e); }
        .bp-tk-seen-no { color:var(--fg-dim,#6b6b6b); }

        .bp-tk-closed { margin-top:8px; }
        .bp-tk-closed-summary { display:flex; align-items:center; gap:8px; cursor:pointer; font-size:12px; font-weight:600; color:var(--fg-muted,#9a9a9a); padding:6px 2px; }

        .bp-tk-empty { text-align:center; padding:64px 24px; color:var(--fg-muted,#9a9a9a); }
        .bp-tk-empty-mark { font-size:40px; color:var(--success,#2fbf5e); margin-bottom:8px; }

        /* Thread detail — full-width timeline rows, NOT chat bubbles. */
        .bp-tk-thread { max-width:820px; }
        .bp-tk-thread-head { display:flex; align-items:flex-start; justify-content:space-between; gap:16px; padding-bottom:14px; margin-bottom:14px; border-bottom:1px solid var(--border-muted,#2a2a2a); }
        .bp-tk-thread-subject { margin-top:6px; }
        .bp-tk-timeline { display:flex; flex-direction:column; }
        .bp-tk-event { padding:14px 0; border-bottom:1px solid var(--border-muted,#2a2a2a); }
        .bp-tk-event-operator { padding-left:0; }
        .bp-tk-event-meta { display:flex; align-items:center; justify-content:space-between; gap:12px; margin-bottom:6px; }
        .bp-tk-event-time { font-size:11px; color:var(--fg-dim,#6b6b6b); font-variant-numeric:tabular-nums; }
        .bp-tk-event-body { font-size:14px; line-height:1.55; white-space:pre-wrap; word-break:break-word; }
        .bp-tk-attachments { display:flex; flex-wrap:wrap; gap:8px; margin-top:8px; }
        .bp-tk-attachment { display:inline-flex; align-items:center; gap:4px; font-size:12px; padding:3px 8px; border-radius:var(--radius-sm,7px); border:1px solid var(--border,#333); color:var(--fg-muted,#9a9a9a); }
        .bp-tk-attachment:hover { color:var(--fg,#eee); border-color:var(--primary,#3b82f6); }

        .bp-tk-composer { margin-top:18px; }
        .bp-tk-textarea, .bp-tk-input { width:100%; font-family:inherit; font-size:14px; padding:10px 12px; border-radius:var(--radius-sm,7px); border:1px solid var(--border,#333); background:var(--bg,#0d0d0d); color:var(--fg,#eee); resize:vertical; }
        .bp-tk-textarea:focus, .bp-tk-input:focus { outline:none; border-color:var(--primary,#3b82f6); }
        .bp-tk-composer-actions { display:flex; align-items:center; gap:8px; margin-top:10px; }
        .bp-tk-spacer { flex:1; }

        /* Key management */
        .bp-tk-keys { max-width:760px; }
        .bp-tk-handoff { border:1px solid var(--primary,#3b82f6); border-radius:var(--radius-lg,10px); padding:14px 16px; margin-bottom:18px; background:hsl(217 91% 60% / 0.06); }
        .bp-tk-handoff-head { display:flex; align-items:center; justify-content:space-between; margin-bottom:6px; }
        .bp-tk-secret { font-family:ui-monospace,SFMono-Regular,monospace; font-size:13px; padding:10px 12px; border-radius:var(--radius-sm,7px); background:var(--bg,#0d0d0d); border:1px solid var(--border,#333); color:var(--fg,#eee); overflow-x:auto; user-select:all; margin:8px 0; }
        .bp-tk-mint { display:flex; gap:8px; margin-bottom:18px; }
        .bp-tk-mint .bp-tk-input { flex:1; }
        .bp-tk-keytable { width:100%; border-collapse:collapse; font-size:13px; }
        .bp-tk-keytable th { text-align:left; font-size:11px; text-transform:uppercase; letter-spacing:0.05em; color:var(--fg-dim,#6b6b6b); padding:6px 10px; border-bottom:1px solid var(--border-muted,#2a2a2a); }
        .bp-tk-keytable td { padding:10px; border-bottom:1px solid var(--border-muted,#2a2a2a); vertical-align:middle; }
        .bp-tk-keyname { font-weight:600; }
        .bp-tk-keyactions-h { text-align:right; }
        .bp-tk-keyactions { display:flex; gap:6px; justify-content:flex-end; }
      </style>

      <header class="bp-tk-topbar">
        <div class="bp-tk-topbar-left">
          <h1 class="h1">Tickets</h1>
          <span :if={@view == :inbox and @presenter.badge_count > 0} class="bp-tk-badge" data-test-id="inbox-badge">
            {@presenter.badge_count} waiting
          </span>
        </div>
        <nav class="bp-tk-topbar-right">
          <button
            :if={@view != :inbox}
            type="button"
            class="btn btn-sm"
            phx-click="back_to_inbox"
            data-test-id="back-to-inbox"
          >
            ← Inbox
          </button>
          <button
            type="button"
            class={["btn btn-sm", @view == :keys && "btn-primary"]}
            phx-click="open_keys"
            data-test-id="open-keys"
          >
            Keys
          </button>
        </nav>
      </header>

      <div :if={@data_error} class="bp-tk-banner bp-tk-banner-error" role="alert" data-test-id="data-error">
        Tickets backend is not available in this build. Showing an empty inbox.
      </div>
      <div :if={msg = Phoenix.Flash.get(@flash, :info)} class="bp-tk-banner bp-tk-banner-ok" role="status">
        {msg}
      </div>
      <div :if={msg = Phoenix.Flash.get(@flash, :error)} class="bp-tk-banner bp-tk-banner-error" role="alert">
        {msg}
      </div>

      <main class="bp-tk-body">
        <%= case @view do %>
          <% :thread -> %>
            {thread_detail(assigns)}
          <% :keys -> %>
            {key_management(assigns)}
          <% _ -> %>
            {inbox_list(assigns)}
        <% end %>
      </main>
    </div>
    """
  end

  @doc """
  The three-partition operator inbox. Presentational — render_component-safe.
  Assigns: `:presenter` (InboxPresenter model), `:data_error` (nil | reason).
  """
  def inbox_list(assigns) do
    ~H"""
    <div class="bp-tk-inbox" data-test-id="inbox-list">
      <%= if inbox_empty?(@presenter) and is_nil(@data_error) do %>
        <div class="bp-tk-empty" data-test-id="inbox-zero">
          <div class="bp-tk-empty-mark">✓</div>
          <p class="h2">Inbox zero</p>
          <p class="text-muted">Nothing is waiting on you. New tickets appear here the moment a key-holder files one.</p>
        </div>
      <% else %>
        <.partition
          title="Needs answer"
          tone="warn"
          rows={@presenter.needs_answer}
          show_seen={false}
          empty="Nothing open — you're caught up."
          test_id="needs-answer"
        />
        <.partition
          title="Waiting on them"
          tone="info"
          rows={@presenter.waiting_on_them}
          show_seen={true}
          empty="No answered tickets awaiting a reply."
          test_id="waiting-on-them"
        />
        <details class="bp-tk-closed" data-test-id="recently-closed">
          <summary class="bp-tk-closed-summary">
            Recently closed
            <span class="bp-tk-count">{length(@presenter.recently_closed)}</span>
          </summary>
          <.partition
            title={nil}
            tone="dim"
            rows={@presenter.recently_closed}
            show_seen={false}
            empty="Nothing closed yet."
            test_id="recently-closed-rows"
          />
        </details>
      <% end %>
    </div>
    """
  end

  @doc "One inbox partition (a titled group of dense ticket rows)."
  def partition(assigns) do
    ~H"""
    <section class={["bp-tk-partition", "bp-tk-tone-#{@tone}"]} data-test-id={@test_id}>
      <h2 :if={@title} class="bp-tk-partition-title">
        {@title}
        <span class="bp-tk-count">{length(@rows)}</span>
      </h2>
      <p :if={@rows == []} class="bp-tk-partition-empty text-muted">{@empty}</p>
      <ul :if={@rows != []} class="bp-tk-rows">
        <li :for={row <- @rows}>
          <.ticket_row row={row} tone={@tone} show_seen={@show_seen} />
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  A single dense inbox row. Presentational — render_component-safe.
  Assigns: `:row` (InboxPresenter row), `:tone`, `:show_seen`.
  """
  def ticket_row(assigns) do
    ~H"""
    <button
      type="button"
      class={["bp-tk-row", "bp-tk-tone-#{@tone}"]}
      phx-click="open_thread"
      phx-value-id={@row.id}
      data-test-id="ticket-row"
      data-ticket-id={@row.id}
    >
      <span class="bp-tk-keypill" title={"Key: #{@row.key_name}"}>{@row.key_name}</span>
      <span class="bp-tk-subject">{@row.subject}</span>
      <span :if={@row.has_attachments?} class="bp-tk-clip" title="Has attachments" aria-label="has attachments">📎</span>
      <span class="bp-tk-msgs" title="Messages">💬 {@row.message_count}</span>
      <span
        :if={@show_seen and @row.seen}
        class={["bp-tk-seen", seen_class(@row.seen)]}
        data-test-id="seen-signal"
      >
        {@row.seen}
      </span>
      <span class="bp-tk-age" title="Waiting">{@row.waiting_age}</span>
    </button>
    """
  end

  @doc """
  Full-width thread timeline + composer. Presentational — render_component-safe.
  Assigns: `:thread` (a ticket map, or nil for the not-found/unavailable state).
  """
  def thread_detail(assigns) do
    ~H"""
    <div class="bp-tk-thread" data-test-id="thread-detail">
      <%= if is_nil(@thread) do %>
        <div class="bp-tk-empty" data-test-id="thread-missing">
          <p class="h2">Ticket unavailable</p>
          <p class="text-muted">
            This ticket could not be loaded. It may have been closed, or the tickets backend is not available in this build.
          </p>
        </div>
      <% else %>
        <div class="bp-tk-thread-head">
          <div>
            <span class="bp-tk-keypill">{tval(@thread, :key_name, "—")}</span>
            <h2 class="h2 bp-tk-thread-subject">{tval(@thread, :subject, "(no subject)")}</h2>
          </div>
          <span class={["badge", thread_status_badge(tval(@thread, :status, "open"))]} data-test-id="thread-status">
            {tval(@thread, :status, "open")}
          </span>
        </div>

        <ol class="bp-tk-timeline" data-test-id="thread-timeline">
          <li :for={msg <- thread_messages(@thread)} class={["bp-tk-event", "bp-tk-event-#{author_kind(msg)}"]}>
            <div class="bp-tk-event-meta">
              <span class={["bp-tk-keypill", author_kind(msg) == "operator" && "bp-tk-oppill"]}>
                {author_label(msg, @thread)}
              </span>
              <time class="bp-tk-event-time">{tval(msg, :at, "")}</time>
            </div>
            <div class="bp-tk-event-body">{tval(msg, :body, "")}</div>
            <div :if={msg_attachments(msg) != []} class="bp-tk-attachments">
              <a
                :for={aid <- msg_attachments(msg)}
                class="bp-tk-attachment"
                href={attachment_href(@thread, aid)}
                target="_blank"
                rel="noopener"
              >
                📎 {aid}
              </a>
            </div>
          </li>
        </ol>

        <form
          class="bp-tk-composer"
          phx-submit="answer"
          data-test-id="composer"
        >
          <input type="hidden" name="ticket_id" value={tval(@thread, :id, "")} />
          <textarea
            name="body"
            rows="4"
            class="bp-tk-textarea"
            placeholder="Write your answer…"
            data-test-id="composer-body"
          ></textarea>
          <div class="bp-tk-composer-actions">
            <%!-- Split submit: the clicked button's name/value rides the form
                  payload, so ONE phx-submit branches on :action (no double-fire
                  from a phx-click + submit on the same button). Enter → answer. --%>
            <button type="submit" name="action" value="answer" class="btn btn-primary" data-test-id="answer-btn">
              Answer
            </button>
            <button type="submit" name="action" value="close" class="btn" data-test-id="answer-close-btn">
              Answer &amp; close
            </button>
            <span class="bp-tk-spacer"></span>
            <button
              type="button"
              class="btn btn-destructive"
              phx-click="close_ticket"
              phx-value-id={tval(@thread, :id, "")}
              data-confirm="Close this ticket without answering?"
              data-test-id="close-btn"
            >
              Close
            </button>
          </div>
        </form>
      <% end %>
    </div>
    """
  end

  @doc """
  Key-management sub-view: mint (one-time secret + handoff card), rotate, pause.
  Presentational — render_component-safe. Assigns: `:keys`, `:mint_result`.
  """
  def key_management(assigns) do
    assigns = assign_new(assigns, :mint_result, fn -> nil end)

    ~H"""
    <div class="bp-tk-keys" data-test-id="key-management">
      <div :if={@mint_result} class="bp-tk-handoff" data-test-id="mint-result">
        <div class="bp-tk-handoff-head">
          <strong>Handoff card — {@mint_result.key_name}</strong>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="dismiss_mint">Done</button>
        </div>
        <p class="text-muted text-sm">
          Copy this now. The secret is shown <strong>once</strong>. Hand it to the key-holder along with the etiquette line.
        </p>
        <pre class="bp-tk-secret" data-test-id="mint-secret">{@mint_result.raw}</pre>
        <p class="text-xs text-dim">Replies reopen the ticket — a paused key can still read, but cannot file.</p>
      </div>

      <form class="bp-tk-mint" phx-submit="mint_key" data-test-id="mint-form">
        <input
          type="text"
          name="name"
          class="bp-tk-input"
          placeholder='Name this key, e.g. "Gyldendal — Kari"'
          autocomplete="off"
          required
        />
        <button type="submit" class="btn btn-primary">Mint key</button>
      </form>

      <table class="bp-tk-keytable" data-test-id="key-table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Status</th>
            <th>Tickets</th>
            <th class="bp-tk-keyactions-h">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@keys == []} data-test-id="keys-empty">
            <td colspan="4" class="text-muted">No keys yet. Mint one above and hand it to an outsider — that key is their identity.</td>
          </tr>
          <tr :for={key <- @keys} data-test-id="key-row">
            <td class="bp-tk-keyname">{kval(key, :name, "—")}</td>
            <td>
              <span class={["badge", key_paused?(key) && "badge-draft" || "badge-active"]}>
                {if key_paused?(key), do: "paused", else: "active"}
              </span>
            </td>
            <td>{kval(key, :ticket_count, 0)}</td>
            <td class="bp-tk-keyactions">
              <button type="button" class="btn btn-sm" phx-click="rotate_key" phx-value-id={kval(key, :id, "")}>
                Rotate
              </button>
              <button
                :if={not key_paused?(key)}
                type="button"
                class="btn btn-sm"
                phx-click="pause_key"
                phx-value-id={kval(key, :id, "")}
              >
                Pause
              </button>
              <button
                :if={key_paused?(key)}
                type="button"
                class="btn btn-sm btn-primary"
                phx-click="unpause_key"
                phx-value-id={kval(key, :id, "")}
              >
                Resume
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ── View helpers (pure) ───────────────────────────────────────────────────

  defp inbox_empty?(p),
    do: p.needs_answer == [] and p.waiting_on_them == [] and p.recently_closed == []

  defp seen_class("not seen yet"), do: "bp-tk-seen-no"
  defp seen_class(_), do: "bp-tk-seen-yes"

  defp thread_status_badge("open"), do: "badge-draft"
  defp thread_status_badge("answered"), do: "badge-active"
  defp thread_status_badge("closed"), do: "badge-published"
  defp thread_status_badge(_), do: "badge-draft"

  defp author_kind(msg) do
    case tget(msg, :author_kind) do
      "operator" -> "operator"
      :operator -> "operator"
      _ -> "submitter"
    end
  end

  defp author_label(msg, thread) do
    case tget(msg, :author_name) do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        if author_kind(msg) == "operator", do: "Operator", else: tval(thread, :key_name, "Submitter")
    end
  end

  defp thread_messages(thread) do
    case tget(thread, :messages) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp msg_attachments(msg) do
    case tget(msg, :attachments) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp attachment_href(thread, asset_id),
    do: "/v1/tickets/inbox/#{tval(thread, :id, "")}/attachments/#{asset_id}"

  defp key_paused?(key), do: not is_nil(kget(key, :paused_at))

  # Dual-key getters (string OR atom) shared by the components.
  defp tget(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp tget(_map, _key), do: nil

  defp tval(map, key, default) do
    case tget(map, key) do
      nil -> default
      "" -> default
      v -> v
    end
  end

  defp kget(map, key), do: tget(map, key)
  defp kval(map, key, default), do: tval(map, key, default)

end
