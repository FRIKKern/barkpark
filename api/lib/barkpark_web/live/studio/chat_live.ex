defmodule BarkparkWeb.Studio.ChatLive do
  @moduledoc """
  Studio agent chat at `/studio/chat` (or its workspace-scoped route) — an
  admin-only control plane backed by the selected Claude Code or Codex runtime.
  Sessions are a PLACE: every conversation is
  persisted (`Barkpark.StudioChat`), listed in the sidebar, addressable at
  `/studio/chat/:session_id`, and resumable via the CLI's `--resume`.

  The chat subprocess is owned by the selected provider Runtime adapter,
  started lazily on the first send — never on mount, never on reopen
  (reopen replays OUR persisted history instantly). Every decoded
  stream-json event arrives here as `{:claude_chat_event, map}`:

    * `system/init`   → model + session id for the header
    * `stream_event`  → `text_delta`s accumulate into the in-progress bubble
    * `assistant`     → the completed message replaces the streaming buffer
                        (t3code's accumulate-and-reconcile pattern); tool_use
                        blocks render as dim activity lines
    * `result`        → the turn is over — back to ready, usage in the footer

  Gating lives behind `Barkpark.StudioChat.Runtime` — this mount redirects out
  unless the selected provider is enabled (which hard-refuses public-demo hosts and
  honors the per-host opt-out), and the `:admin_studio` live_session carrying
  the route applies the admin `on_mount` gate.

  Zero JS: the transcript scroll container is `column-reverse`, so the newest
  content sticks to the bottom without a hook; the composer input remounts
  (id bump) to clear after each send.
  """

  use BarkparkWeb, :live_view

  require Logger

  alias Barkpark.ChatHosts
  alias Barkpark.Content.DraftId
  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.PortableDoc.Render
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Attachments
  alias Barkpark.StudioChat.ContextIdentity
  alias Barkpark.StudioChat.PlanPapers
  alias Barkpark.StudioChat.QuestionAnswer
  alias Barkpark.Tasks
  alias Barkpark.Tenancy
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime
  alias Barkpark.StudioChat.StreamTail
  alias Barkpark.StudioChat.TaskTransition
  alias BarkparkWeb.Studio.ChatToolRenderer
  alias BarkparkWeb.Studio.ReturnTo
  alias BarkparkWeb.Studio.StudioLive.Paths

  # Spawn-row heuristics + labels for the nested agent trace (charter D40) — pure
  # helpers shared by the live render and the store-replay path.
  import BarkparkWeb.Studio.ChatToolRenderer, only: [spawn?: 2, spawn_label: 2]

  # How long a Stop may sit in `:interrupting` before we force-close a wedged
  # CLI (charter D18). Config-overridable so tests can drive the timeout fast.
  @default_interrupt_timeout_ms 8_000

  # The park's spinner vocabulary — this chat's own answer to Claude Code's
  # "Pondering…". Barkpark is a happy place, so the busy rows speak dog-park:
  # the thinking pulse rolls one word per bout (blank_pulse/0), the
  # between-tools busy row one per turn (roll_spinner_word/1). Only
  # ":interrupting → stopping…" stays literal — a Stop must always read as a
  # Stop.
  @spinner_words [
    "Joymaxxing",
    "Waggeling",
    "Sniffing around",
    "Aurafarming",
    "Barkstorming",
    "Pawndering",
    "Doing zoomies",
    "Chasing squirrels",
    "Fetchmaxxing",
    "Gnawing on it",
    "Digging up bones",
    "Borking softly",
    "Treatseeking",
    "Goodboying",
    "Herding pixels",
    "Vibesniffing",
    "Snoot-booping",
    "Frolicmaxxing",
    "Squirrel-checking",
    "Basking in sunbeams",
    "Howling at the moon",
    "Bellyrub pending",
    "Rolling in the grass",
    "Wagmaxxing"
  ]

  # Public so the tests (and any future surface that wants the same voice) can
  # assert against the one canonical list instead of pinning a word.
  @doc false
  def spinner_words, do: @spinner_words

  # How long a spinner word wears before it is swapped for a fresh one. Long
  # enough to read, short enough that no turn ever feels stuck on one word.
  # The rotation is the BROWSER's (bp-chat-turn-clock.js, Hooks.ChatSpinWord):
  # the server stamps the vocabulary and this dwell on the word span as static
  # markup, and the hook picks the next word. Nothing about a running turn
  # costs a LiveView diff on a timer any more.
  @spinner_rotate_ms 7_000

  # The vocabulary exactly as the hook reads it (data-words). Encoded once at
  # compile time and rendered as STATIC markup, so it never enters a diff.
  @spinner_words_json Jason.encode!(@spinner_words)

  defp spinner_words_json, do: @spinner_words_json
  defp spinner_rotate_ms, do: @spinner_rotate_ms

  # Per-socket transcript window (efficiency; task-9e21c3f285b3d7d0). A long
  # multi-hundred-turn agent session appends user/assistant/tool rows for its
  # whole life; without a bound `@messages` grows the socket heap O(n) and the
  # grouped-rows recompute over the FULL list makes each turn O(n) = O(n²) total.
  # We keep only the last `@transcript_window` rows in the socket (and load only
  # that many on reopen — `StudioChat.list_messages/2`), so heap and per-turn CPU
  # are bounded by the window, not the session length. The store keeps the full
  # durable history (replay law, D7); this trims only the in-memory display view.
  @transcript_window 500

  # How long a SETTLED rail entry lingers on screen after IT reaches a terminal
  # status before it auto-dismisses (fades out) — INDEPENDENTLY of its siblings.
  # Long enough to read that one agent's outcome, short enough that a done agent
  # stops squatting under the composer while others still run. Each entry arms
  # its own prune when it settles (charter D47); running siblings are untouched,
  # the rail header count decrements as rows drop, and the rail vanishes only
  # when its LAST entry is pruned. This replaced the old wholesale 5-min sweep,
  # which could only clear the rail once EVERY entry was terminal — so a single
  # still-running agent pinned every completed sibling on screen indefinitely.
  # The rail STATE survives in the store (replay law, charter D47) — this only
  # ends an entry's SCREEN residency, never its stored `rail_snapshot`.
  @rail_entry_linger_ms 90_000

  # The exact deny message a "Keep planning" click sends back to the model
  # (charter D34, proven on the real binary: the model re-plans and the next
  # system/init stays in plan mode).
  @keep_planning_message "The user wants to keep planning — continue in plan mode."

  # The "needs you" message roles (charter D31) — the socket-side twin of
  # `StudioChat`'s `@needs_you_roles`. A permission ask renders as one of three
  # cards (a generic approval, an AskUserQuestion form, an ExitPlanMode plan)
  # but all three carry `:approval_status` and all three are gated / canceled /
  # resolved identically. Widening only one seam would leave the pill or the
  # cancel-on-crash lying for the others.
  @needs_you_roles [:approval, :question, :plan]

  # Mount no longer spawns (the eager-spawn contract is inverted, charter D8/D14):
  # mount lays out the chrome + loads the sidebar session list; `handle_params/3`
  # is the single source of truth for WHICH session is on screen. A subprocess is
  # started lazily only on the first user send, never on mount and never on
  # reopen — reopening replays OUR persisted history instantly and resumes the
  # CLI's memory on the next send via `--resume`.
  @impl true
  def mount(params, _session, socket) do
    enabled_provider = Enum.find(StudioChat.Session.providers(), &Runtime.enabled?/1)

    if enabled_provider do
      {:ok,
       socket
       |> assign(
         page_title: "chat",
         nav_section: :chat,
         dataset: default_dataset(),
         # The dataset the URL SCOPE names, as distinct from the one above.
         # No chat route carries a `:dataset` segment today, so this is nil and
         # `dataset:` is a substitution nobody chose — the context band reports
         # exactly that difference rather than printing the substitution as if
         # it were a choice. Read from params (not hardcoded nil) so a future
         # dataset-scoped chat route tells the truth without touching the band.
         scope_dataset: params["dataset"],
         # The transcript header's context identity (chat-local-cloud-context-w3).
         # Rebuilt on session load, on the new-chat reset, and on a host report —
         # never per render.
         context_identity: nil,
         # current_path is owned by StudioChrome's :handle_params hook, which
         # also keeps it fresh across the /studio/chat/:session_id patches
         # (this static string used to freeze the active tab on reopen).
         # Truthful return path (charter D5): a scoped surface links here with
         # `?return_to=<its canonical path>`; we sanitize it (open-redirect
         # guard) and thread it through every self-`push_patch` so a back/exit
         # affordance can land the admin back in the SAME scope instead of the
         # `/studio` session funnel. nil when arrived at flat/directly.
         return_to: ReturnTo.sanitize(params["return_to"]),
         chat_base_path: chat_base_path(params),
         # WHICH of the two mounts this socket is (see `read_workspace_id/1`).
         # The workspace-scoped route carries `:workspace_slug` in its path; the
         # flat `/studio/chat` route has no such segment. Captured at mount
         # because the two mounts are authorized by DIFFERENT gates and the read
         # scope below turns on exactly that.
         scoped_mount?: is_binary(params["workspace_slug"]),
         session: nil,
         store_session_id: nil,
         session_id: nil,
         # `sessions` + `pending_ask_roles` are loaded together by
         # refresh_sessions/1 (chained below) — the roles map is the store-truth
         # half of the needs-you strip (wave 12), so the two must never drift.
         sessions: [],
         pending_ask_roles: %{},
         show_archived: false,
         renaming_session: nil,
         open_menu_session: nil,
         # The Cmd/Ctrl+K session palette (T3 keybindings parity). Socket-local
         # per-tab UI state, like open_menu_session: it holds NO list of its own
         # — the palette renders `@sessions`, the very list the sidebar shows —
         # so it can never disagree with the sidebar or outlive a tenant clamp.
         palette_open: false,
         # Per-tab expand state for proposed-plan cards (charter D34): the set of
         # plan message ids the viewer has expanded. Socket-local, never
         # broadcast, reset on every session load — clones the open_menu_session
         # kebab pattern.
         plan_expanded: MapSet.new(),
         # Per-tab expand override for agent drill-down blocks (charter D46):
         # `%{spawn tool_use_id => bool}`. Default is open while the sub-agent
         # runs and collapsed once terminal; a manual toggle always wins. Never
         # broadcast (a co-viewer's expand is their own), reset on session load.
         agent_expanded: %{},
         # Per-tab expand override for TURN FOLDS (task-8f904a88b9bc3d59): the
         # set of `turn_settled_at` keys the reader clicked open. Default is
         # COLLAPSED (a settled turn is history — its header says how long it
         # took), never broadcast (a co-viewer's expand is their own), reset on
         # session load. A MapSet, not a map: a fold has one bit, and the absent
         # key IS the default, so no stale `false` entries accumulate.
         turn_folds_expanded: MapSet.new(),
         # SHOW-ACTIVE-ONLY, per-tab (task-b66928b2958c8cfa): has the reader
         # opened the RUNNING turn's "+N previous" control? One BOOLEAN, not a
         # set — at most one turn runs at a time, so there is at most one such
         # fold on screen and nothing to key it by. Default COLLAPSED (the whole
         # point is that the live row stays visible), reset when a turn settles
         # and on session load, never broadcast.
         running_fold_expanded: false,
         # The agents rail (charter D47): the task_id-keyed mission-control
         # snapshot rendered below the composer, Claude-Code-TUI style. `rail` is
         # the live map (hydrated from `rail_snapshot` on reopen, folded by the
         # background_tasks_changed / task_progress / task_* frames); `rail_sig`
         # caches its structural signature so a token-only tick is a no-op render
         # (D46 value-equality). `rail_expanded` is the per-tab expand override
         # (task_id => bool) for a workflow row's phase→agent tree — never
         # broadcast, reset on session load (agent_expanded precedent).
         rail: %{},
         rail_sig: [],
         rail_expanded: %{},
         # Per-tab agent drill-down override (wsc-ad): agentId => bool, default
         # CLOSED, a manual toggle wins. Never broadcast, reset on session load
         # (rail_expanded precedent).
         agent_detail_expanded: %{},
         mode: List.first(Runtime.capabilities(enabled_provider).modes) || "default",
         provider: enabled_provider,
         execution_target: "managed",
         execution_host_id: nil,
         execution_hosts: execution_hosts(socket),
         model_choice: "default",
         # Reasoning-effort intent (charter D48), the exact mirror of model_choice.
         effort_choice: "default",
         # Bypass arm ceremony (charter D48): `arming_bypass` opens the loud
         # type-to-confirm panel; `bypass_confirm` tracks the typed word so the
         # Arm button only enables on an exact "bypass". Both socket-local, reset
         # on every session load — a bypass is never armed by a select alone.
         arming_bypass: false,
         bypass_confirm: "",
         # Bypass arming is a LIVE act (charter D55). `bypass_live_armed` is the
         # socket-local twin of the persisted mode: arming happens ONLY through
         # the type-"bypass" ceremony this lifetime, never inherited from the
         # stored row. Spawn's dangerous-flag gate is this token AND the persisted
         # bypassPermissions mode — a reopened bypass session fail-closes to plan
         # until the ceremony re-runs. `bypass_disarmed` drives the honest
         # auto-opened panel line on reopening such a session.
         bypass_live_armed: false,
         bypass_disarmed: false,
         status: :new,
         init: nil,
         messages: [],
         # Memoized grouped transcript rows (task-9e21c3f285b3d7d0): the HEEx
         # renders `@grouped_rows`, recomputed ONCE per append (via
         # `assign_messages/2`), never per render over the full `@messages`.
         grouped_rows: [],
         # The incremental-regroup memo (task-07f27c32c84a5005): the already
         # grouped PREFIX of `@messages`, spliced in front of a freshly grouped
         # tail on every write. See `regroup/2`.
         grouping_cache: empty_grouping_cache(),
         next_id: 0,
         # The in-memory id of THIS turn's TodoWrite living-checklist card
         # (charter D39). The turn's first TodoWrite appends a :todo card and
         # records its id here; every later TodoWrite supersedes that card in
         # place. Reset to nil on the broadcast `system/init` (the per-turn
         # boundary) and on every session load.
         todo_card_id: nil,
         streaming: nil,
         # The live extended-thinking pulse (charter D41): nil, or
         # %{tokens: N, text: "", word: w}. Driven by `system/thinking_tokens`
         # frames — the wire never carries thinking text, so the row shows a
         # "✻ <spinner word>… ~N tokens" counter that settles into a durable
         # `:thinking` message the instant real output (text/tool/result) begins.
         thinking_pulse: nil,
         # The turn's spinner word (the park voice): rolled fresh on every send,
         # worn by the between-tools busy row. The pulse rolls its own per bout.
         spinner_word: Enum.random(@spinner_words),
         # Advertised slash commands (charter D36a) — the CLI's initialize list,
         # held by the Recorder and delivered on subscribe + broadcast. The
         # composer's slash menu merges these with the builtin floor.
         commands: [],
         # Server-bound composer (charter D24): the input renders `value=` from
         # this draft, so a send can clear it and a failed dispatch can restore
         # the words verbatim — an uncontrolled DOM input is invisible to render/1.
         composer_draft: "",
         # The id of the optimistic user echo awaiting a dispatch verdict. A hard
         # failure withdraws exactly this row; a dispatched frame clears the marker.
         pending_echo_id: nil,
         interrupt_requested: false,
         pending_mode: nil,
         # The turn's start as EPOCH MILLISECONDS, stamped once at the user
         # message boundary and read by the ChatElapsed hook. nil = no turn we
         # can date (a fresh mount, a reconnect mid-turn), and the label simply
         # does not render — the same silence the old counter kept at 0.
         turn_started_at_ms: nil,
         subscribed_topic: nil,
         # Per-tab AskUserQuestion answer state (charter D31/D35): request_id →
         # %{selections: %{qidx => [labels]}, custom: %{qidx => text}}. Chip picks
         # and custom text stay SOCKET-LOCAL — never broadcast — until the ONE
         # submit resolves the ask; the resolution itself broadcasts.
         question_forms: %{},
         # Live sidebar overlay (wave 5): session_id → %{state, line}, fed by
         # every Recorder's activity broadcasts. Renders over the stored row.
         activity: %{},
         # Wave-session-card (wsc charter D8-D11): `workflow` is the LIVE
         # compact-summary overlay (session_id → D3 summary, fed by
         # {:chat_workflow} pings, D4); `workflow_summaries` is the COLD half
         # folded from the stored rail_snapshot at refresh_sessions (D7);
         # `epic_goals` carries the epic-goal line per workflow row (D9).
         # A sidebar of plain chats keeps all three empty — zero cost.
         workflow: %{},
         workflow_summaries: %{},
         epic_goals: %{},
         # The hand-task surface (chat ⇄ ledger): every bp-task claim THIS
         # session's provider-scoped worker id currently holds, keyed by
         # published doc id — fed live off the dataset's task-document
         # broadcasts and hydrated from the ledger on session open. Renders as
         # the Doing strip above the composer.
         hand_tasks: %{},
         # Live task transitions (tlv-bl-chat-live-transition-stream). The
         # STICKY set of published task ids this session has touched — grown
         # from the session worker's claims (see StudioChat.TaskTransition's
         # scoping rule) and seeded from its held claims on open — plus the
         # idempotency set of already-rendered mutation_event ids, so a
         # duplicate or Last-Event-ID-replayed lifecycle event renders once.
         touched_tasks: MapSet.new(),
         seen_task_events: MapSet.new(),
         # The ready-task picker: nil (closed) or the ready head as lean rows.
         # Loaded fresh on every open — never a cached queue.
         task_picker: nil,
         last_result: nil,
         ring: blank_ring(),
         title_source: "default",
         title_kicked: false
       )
       # Chat-never-vanishes readiness (chat-task-hands, charter decision 4):
       # the probe costs ~1–2s (claude auth status), so mount only seeds
       # :checking and kicks it ASYNC — never inline. The composer chrome keys
       # its onboarding card off this assign; :checking keeps the composer
       # live (optimistic — the common case is :ready) with a quiet probe
       # strip, a definitive claude-lane verdict swaps the card in.
       |> kick_readiness_probe()
       |> refresh_sessions()
       |> subscribe_activity()
       |> subscribe_hand_tasks()
       |> assign_context_identity()
       |> allow_upload(:attachments,
         # Charter D25: paste/drop images ride the SAME user turn as base64
         # content blocks. Cap at 4 × 3MB — base64 inflates ×4/3, so the wire
         # payload stays under the Anthropic ~5MB-per-image cap. The composer
         # phx-hook feeds files into this upload; consume happens on send.
         accept: ~w(.png .jpg .jpeg .gif .webp),
         max_entries: 4,
         max_file_size: 3_000_000
       )}
    else
      # Disabled here — bounce back to where the admin came from when we have a
      # validated return path (charter D5), else the `/studio` funnel. Prefers
      # the truthful scope over the session-resolving redirect.
      {:ok,
       socket
       |> put_flash(:error, "No Studio Chat provider is enabled on this instance.")
       |> redirect(to: ReturnTo.sanitize(params["return_to"]) || "/studio")}
    end
  end

  # Single source of truth for the on-screen session. Fires on the initial mount
  # AND on every `push_patch` (sidebar click, new-chat, first-send self-patch).
  @impl true
  def handle_params(%{"session_id" => sid} = params, _uri, socket) do
    socket = put_return_to(socket, params)

    cond do
      # A `push_patch` to the session we already own (e.g. right after a fresh
      # send minted + patched to its own uuid) — keep the live state untouched.
      socket.assigns.store_session_id == sid ->
        {:noreply, assign(socket, session_id: sid)}

      true ->
        # Switch-away moment (charter D36c): persist the draft of the session we
        # are LEAVING before anything else, so its unsent words survive the swap
        # and reload when it is reopened.
        socket = capture_draft(socket)

        case get_session_in_tenancy(socket, sid) do
          nil ->
            # Unknown/deleted session — fall back to the new-chat state with an
            # honest notice. (A mount-time push_patch would fight the initial
            # navigation; resetting in place is simpler and just as clear.)
            {:noreply,
             socket
             |> reset_to_new_chat()
             |> put_flash(:error, "That chat is no longer available.")}

          session ->
            {:noreply, load_stored_session(socket, session)}
        end
    end
  end

  def handle_params(params, _uri, socket) do
    # Leaving to the new-chat state persists the departed session's draft and
    # re-reads the list.
    {:noreply,
     socket
     |> put_return_to(params)
     |> capture_draft()
     |> reset_to_new_chat()
     |> refresh_sessions()}
  end

  # Ingest a `return_to` param from the wire (charter D5). Only OVERWRITE the
  # standing value when the incoming param sanitizes to a valid canonical Studio
  # path — a self-`push_patch` that carries it forward keeps it, and a patch that
  # somehow drops it never clobbers the one captured on mount.
  defp put_return_to(socket, params) do
    case ReturnTo.sanitize(params["return_to"]) do
      nil -> socket
      rt -> assign(socket, return_to: rt)
    end
  end

  defp execution_hosts(socket) do
    case socket.assigns[:current_workspace] do
      %{id: workspace_id} -> ChatHosts.list_hosts(workspace_id)
      _ -> []
    end
  end

  defp chat_base_path(params) do
    params["workspace_slug"]
    |> Paths.scope_prefix(params["project_slug"])
    |> Paths.chat_root()
  end

  # Persist the leaving session's composer draft (charter D36c). No-op on the
  # new-chat state (no store row yet) — a fresh chat's draft is discarded, never
  # persisted to a row that doesn't exist. Blank drafts clear the column.
  defp capture_draft(socket) do
    if sid = socket.assigns[:store_session_id] do
      StudioChat.set_draft(sid, socket.assigns[:composer_draft])
    end

    socket
  end

  # Keep the server-bound composer draft in step with what the user types
  # (charter D24). Without this, `value={@composer_draft}` would fight the DOM:
  # a restore-on-failure could never be SEEN and a clear-on-send could never
  # stick. Enter still submits via the form's `phx-submit="send"`.
  def handle_event("composer-change", %{"message" => text}, socket) do
    {:noreply, assign(socket, composer_draft: text)}
  end

  # Two-phase send (charter D24). PHASE 1 is instant and pure UI: echo the user
  # bubble, clear the composer, flip to `:thinking`, and return — the first diff
  # carries the words before any spawn/write/persist runs. The slow, failure-prone
  # work (ensure_session → wire write → persist) is handed to `{:dispatch_send}`
  # so the tab never blocks on a subprocess. A hard failure there withdraws the
  # echo and hands the words back verbatim; nothing is ever silently lost.
  @impl true
  def handle_event("send", %{"message" => text}, socket) do
    text = String.trim(text)
    has_attachments? = socket.assigns.uploads.attachments.entries != []

    # A leading-slash BUILTIN (charter D36b) never reaches the model: /plan
    # steers the permission mode, /model switches the brain. Routing them
    # here (server-side, on submit) keeps the JS slash menu a pure insert widget
    # and makes the routing testable. Advertised (non-builtin) slash commands
    # fall through as plain user text — the CLI executes them itself.
    case builtin_command(text) do
      {:set_mode, mode} ->
        {:noreply, socket |> clear_persisted_draft() |> change_mode(mode) |> clear_composer()}

      {:set_model, choice} ->
        {:noreply, socket |> clear_persisted_draft() |> change_model(choice) |> clear_composer()}

      :arm_bypass ->
        # Open the arm ceremony — the SAME assigns as the set-mode bypass road;
        # nothing is armed until the exact typed confirm word (charter D48).
        {:noreply,
         socket
         |> clear_persisted_draft()
         |> assign(arming_bypass: true, bypass_confirm: "", bypass_disarmed: false)
         |> clear_composer()}

      :model_usage ->
        {:noreply,
         socket
         |> clear_persisted_draft()
         |> append_message(:system, "Usage: /model default · haiku · sonnet · opus · fable")
         |> clear_composer()}

      :task_usage ->
        {:noreply,
         socket
         |> clear_persisted_draft()
         |> append_message(
           :system,
           "Usage: /task <task-id> — hand a task to Claude (claim → work → stamp → close) · /task new <wish> — author + publish a task"
         )
         |> clear_composer()}

      {:agent_prompt, prompt} ->
        # The builtin expands into a full doctrine prompt and rides the NORMAL
        # send path — the expansion IS the message (visible, persisted, queued
        # like any other turn; no hidden steering).
        handle_event("send", %{"message" => prompt}, socket)

      :none ->
        cond do
          text == "" and not has_attachments? ->
            {:noreply, socket}

          true ->
            # Queue-honest send (charter D43): a mid-turn send is NO LONGER
            # dropped. The real binary buffers a mid-turn stdin user frame and
            # runs it as the NEXT turn (probe-proven — never steers, never
            # errors), so a mid-turn send runs the SAME two-phase path; its echo
            # just wears a '⧗ queued' badge and the row persists metadata.queued.
            # Words are never lost to a silent drop.
            queued? = turn_active?(socket.assigns.status)

            # PHASE 1 (charter D24): echo instantly, clear the composer, and defer
            # every failure-prone step to {:dispatch_send}. An image-only turn gets
            # its bubble in phase 2 when the staged files are consumed (D25) — the
            # attachment strip keeps showing the thumbnails until that next diff,
            # so nothing visually vanishes in between.
            echo_id = socket.assigns.next_id
            send(self(), {:dispatch_send, text, queued?})

            socket =
              if text == "" do
                assign(socket, pending_echo_id: nil)
              else
                socket
                |> append_message(:user, text, queued: queued?)
                |> assign(pending_echo_id: echo_id)
              end

            # The stuck draft is history the instant a turn dispatches (charter
            # D36c): clear the persisted column so a reopen shows a clean composer,
            # not the words that just went to the model.
            socket = clear_persisted_draft(socket)

            # A FRESH send starts the turn clock and flips to :thinking; a QUEUED
            # send rides the already-running turn, so leave its clock and status
            # untouched — the live spinner keeps its own elapsed time.
            socket =
              if queued? do
                assign(socket, composer_draft: "")
              else
                socket
                |> start_turn_clock()
                |> roll_spinner_word()
                |> assign(status: :thinking, interrupt_requested: false, composer_draft: "")
              end

            {:noreply, socket}
        end
    end
  end

  # Cancel a staged attachment before send (the × on its chip).
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  # Toggle the ready-task picker (hand-task surface). Open loads the ready
  # head FRESH from the queue — the panel is a window, never a cache.
  def handle_event("toggle-task-picker", _params, socket) do
    case socket.assigns.task_picker do
      nil ->
        rows = Tasks.ready([limit: 8] ++ hand_task_scope()) |> Enum.map(&hand_ready_row/1)
        {:noreply, assign(socket, task_picker: rows)}

      _open ->
        {:noreply, assign(socket, task_picker: nil)}
    end
  end

  # Hand a ready task to the agent: close the picker and ride the NORMAL send
  # path with the claim-first work prompt — the echo, queueing, persistence,
  # and status flip all behave exactly like a typed message.
  def handle_event("hand_task", %{"id" => id}, socket) do
    handle_event("send", %{"message" => task_work_prompt(id)}, assign(socket, task_picker: nil))
  end

  # Re-check on the onboarding card (chat-task-hands, charter decision 4):
  # re-run the SAME async probe and unlock the composer in place — no reload,
  # no dead end. The card flips to :checking for honest feedback while the
  # probe (~1–2s on a real host) runs off the LiveView process.
  def handle_event("readiness-recheck", _params, socket) do
    session = socket.assigns[:session]
    provider = socket.assigns.provider

    {:noreply,
     socket
     |> assign(readiness: :checking)
     |> start_async(:readiness_probe, fn -> compute_readiness(provider, session) end)}
  end

  # Stop a running turn. The interrupt is a control-request frame on stdin
  # (proven on the raw wire): the CLI aborts the turn and emits a terminal
  # `result` with subtype `error_during_execution` /
  # `terminal_reason: "aborted_streaming"` — but the session SURVIVES. We flag
  # `interrupt_requested` so the result classifies as "interrupted", never an
  # error, and flip to a transient `:interrupting` status for honest feedback.
  # A late ack (or a duplicate Stop) is harmless — the cast is idempotent.
  #
  # Stopping cannot wedge (charter D18): we arm an {:interrupt_timeout, sid}
  # timer. If a terminal `result` arrives first, status leaves `:interrupting`
  # and the timer no-ops; if the CLI wedges (no result), the timer force-closes
  # the subprocess and runs the shared honest teardown so the composer never
  # sticks at "Stopping…" forever.
  def handle_event("stop_turn", _params, socket) do
    # Esc now fires stop_turn from ANYWHERE (charter D42), so this must be a
    # strict no-op unless a turn is actually running: a stray Escape at an idle
    # composer must never interrupt a live-but-quiescent session (nor a dead one).
    cond do
      is_nil(socket.assigns.session) ->
        {:noreply, socket}

      not turn_active?(socket.assigns.status) ->
        {:noreply, socket}

      true ->
        Runtime.interrupt(socket.assigns.provider, socket.assigns.session)

        # The Recorder — not this tab — owns the turn's outcome
        # (task-8f904a88b9bc3d59). Telling it here is what lets a turn stopped
        # from THIS tab read "You stopped after 42s" in every other tab and on
        # every later reopen, including the D18 road where the wedge timer
        # force-closes and no terminal `result` ever arrives.
        Recorder.note_interrupt_requested(socket.assigns[:store_session_id])

        Process.send_after(
          self(),
          {:interrupt_timeout, socket.assigns[:store_session_id]},
          interrupt_timeout_ms()
        )

        {:noreply, assign(socket, interrupt_requested: true, status: :interrupting)}
    end
  end

  # Switching permission mode steers the LIVE session via a `set_permission_mode`
  # control frame (key `mode`, charter D12) — the model's context is preserved,
  # no respawn. With no live subprocess (the common case now that spawn is lazy)
  # it is a silent selector update; the next spawn carries the mode via
  # build_args.
  #
  # Persistence is ACK-driven for a live session (charter D23): the store's mode
  # is the last value the CLI actually confirmed, never the optimistic guess.
  # We record the minted request_id in `pending_mode` (with the mode to revert to
  # if it fails) so ONLY the ack matching the LATEST outstanding switch may commit
  # or revert — a stale ack from a superseded rapid switch is ignored, never a
  # mis-revert. With no live session there is no ack to wait on, so we persist
  # immediately and the next lazy `--resume` spawn carries the mode.
  # Picking bypassPermissions in the footer NEVER steers on the select alone
  # (charter D48 fail-closed law): it opens the loud type-to-confirm arm panel.
  # The mode is unchanged until the ceremony completes — a plain select can't
  # arm dangerous bypass.
  def handle_event("set-mode", %{"mode" => "bypassPermissions"}, socket) do
    {:noreply, assign(socket, arming_bypass: true, bypass_confirm: "", bypass_disarmed: false)}
  end

  def handle_event("set-provider", %{"provider" => provider}, socket) do
    if is_nil(socket.assigns[:store_session_id]) and provider in StudioChat.Session.providers() do
      capabilities = Runtime.capabilities(provider)

      {:noreply,
       socket
       |> assign(
         provider: provider,
         mode: List.first(capabilities.modes) || "default",
         model_choice: "default",
         effort_choice: "default",
         readiness: :checking
       )
       |> start_async(:readiness_probe, fn -> compute_readiness(provider, nil) end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set-execution-target", %{"execution_target" => target}, socket) do
    if is_nil(socket.assigns[:store_session_id]) and
         target in StudioChat.Session.execution_targets() do
      {:noreply, assign(socket, execution_target: target, execution_host_id: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set-execution-host", %{"execution_host_id" => host_id}, socket) do
    if is_nil(socket.assigns[:store_session_id]) and Ecto.UUID.cast(host_id) != :error do
      {:noreply, assign(socket, execution_host_id: host_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set-mode", %{"mode" => mode}, socket) do
    normalized = Runtime.normalize_mode(socket.assigns.provider, mode)

    # The toggle's active segment stays clickable — a same-mode click (with no
    # switch in flight) is a no-op, never a redundant steer + transcript line.
    if normalized == socket.assigns.mode and is_nil(socket.assigns[:pending_mode]) do
      {:noreply, socket}
    else
      # Steering to any non-bypass mode drops the live arming token (charter D55):
      # the next resume of what was a bypass session can never fail open.
      {:noreply,
       socket
       |> assign(
         arming_bypass: false,
         bypass_confirm: "",
         bypass_disarmed: false,
         bypass_live_armed: false
       )
       |> change_mode(normalized)}
    end
  end

  # Track the confirm word as it's typed so the Arm button only enables on an
  # exact "bypass" (net-new UX — a data-confirm dialog is NOT enough, charter D48).
  def handle_event("bypass-confirm", %{"confirm" => text}, socket) do
    {:noreply, assign(socket, bypass_confirm: text)}
  end

  # Arm bypass — the ONLY road that persists mode == bypassPermissions. Guarded
  # server-side on the exact typed word (never trust the client's button-enabled
  # state). Persists the mode (so the next spawn's build_args, gated on the
  # PERSISTED row, emits --allow-dangerously-skip-permissions) and posts an
  # honest line: bypass takes effect on the NEXT spawn, never the running turn —
  # the live process was started without the arming flag, so we send NO
  # set_permission_mode steer for it (unlike the other five modes).
  def handle_event("arm-bypass", _params, socket) do
    if String.trim(socket.assigns[:bypass_confirm] || "") == "bypass" do
      if sid = socket.assigns[:store_session_id],
        do: StudioChat.set_mode(sid, "bypassPermissions")

      line =
        if socket.assigns[:session],
          do:
            "⚠ Bypass permissions ARMED — it takes effect on the next resume, not the running turn.",
          else: "⚠ Bypass permissions ARMED — it takes effect when this chat next runs."

      # The ceremony is the ONLY thing that flips the live token (charter D55) —
      # a reopened bypass session lands here disarmed and re-arms only through
      # this branch, so the next spawn's build_args gate (live token AND
      # persisted mode) can emit --allow-dangerously-skip-permissions.
      socket =
        socket
        |> assign(
          mode: "bypassPermissions",
          arming_bypass: false,
          bypass_confirm: "",
          bypass_live_armed: true,
          bypass_disarmed: false
        )
        |> append_message(:system, line)

      {:noreply, socket}
    else
      # Word mismatch — never arm; keep the panel open for another try.
      {:noreply, socket}
    end
  end

  def handle_event("cancel-arm-bypass", _params, socket) do
    {:noreply, assign(socket, arming_bypass: false, bypass_confirm: "", bypass_disarmed: false)}
  end

  # Pick the brain (wave 5). The choice persists on the session row (intent)
  # and steers a LIVE session in place via the set_model control frame — the
  # CLI's ack for set_model can be an empty success (charter D12 vacuous-green
  # trap), so we do not pend/revert on it: the next init/result frame reports
  # the answering model as fact, rendered beside the picker.
  def handle_event("set-model", %{"model" => raw}, socket) do
    {:noreply, change_model(socket, Runtime.normalize_model(socket.assigns.provider, raw))}
  end

  # Pick the reasoning-effort tier (charter D48). Intent-only: it persists on the
  # row and rides the NEXT spawn as --effort. There is NO set_effort control verb
  # (the four control subtypes are closed), so a mid-session change never steers
  # the running turn — we post an honest "applies from the next resume" line.
  def handle_event("set-effort", %{"effort" => raw}, socket) do
    {:noreply, change_effort(socket, Runtime.normalize_effort(socket.assigns.provider, raw))}
  end

  def handle_event("approve", %{"rid" => request_id}, socket) do
    {:noreply, resolve_permission(socket, request_id, :allow)}
  end

  def handle_event("deny", %{"rid" => request_id}, socket) do
    {:noreply, resolve_permission(socket, request_id, {:deny, "The user declined this action."})}
  end

  # ── proposed-plan card (charter D34) ─────────────────────────────────────

  # Approve the plan: answer the ExitPlanMode ask with `{:allow, echoed input}`.
  # The echoed input is REQUIRED — a bare `{"behavior":"allow"}` fails
  # ExitPlanMode on the real binary (ZodError, mode stays plan). We send NO
  # mode follow-up; the CLI flips its own mode and we OBSERVE it on the next
  # init (see observe_permission_mode/2). Routed through the ONE needs-you
  # resolve seam (resolve_permission) so the outcome persists AND broadcasts to
  # co-viewing tabs (charter D35) exactly like questions and approvals.
  def handle_event("plan-approve", %{"rid" => request_id}, socket) do
    case find_message_by_rid(socket, request_id) do
      %{role: :plan} = m ->
        {:noreply, resolve_permission(socket, request_id, {:allow, m.plan_input || %{}})}

      _ ->
        {:noreply, socket}
    end
  end

  # Keep planning: deny with the exact re-plan instruction (charter D34).
  def handle_event("plan-keep", %{"rid" => request_id}, socket) do
    {:noreply, resolve_permission(socket, request_id, {:deny, @keep_planning_message})}
  end

  # Expand/collapse the clamped plan preview — per-tab socket state, never
  # broadcast (a co-viewer's expand is their own). Toggles the plan message id
  # in the `plan_expanded` set.
  def handle_event("plan-toggle", %{"id" => id}, socket) do
    id = String.to_integer(id)
    set = socket.assigns.plan_expanded

    next =
      if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)

    {:noreply, assign(socket, plan_expanded: next)}
  end

  # Expand/collapse an agent drill-down block (charter D46). Per-tab override map
  # keyed by the spawn's tool_use_id, never broadcast (a co-viewer's expand is
  # their own). The toggle flips the EFFECTIVE current state (override if set,
  # else the running/terminal default) so a manual choice always wins.
  def handle_event("agent-toggle", %{"id" => id}, socket) do
    agent = Enum.find(socket.assigns.messages, &(&1[:spawn?] == true and &1[:tool_use_id] == id))

    # A stale toggle (the session switched under an in-flight click) finds no
    # spawn row — drop it instead of crashing the LiveView on `not nil`.
    if agent do
      current = agent_open?(socket.assigns.agent_expanded, agent)
      next = Map.put(socket.assigns.agent_expanded, id, not current)
      {:noreply, assign(socket, agent_expanded: next)}
    else
      {:noreply, socket}
    end
  end

  # Expand/collapse ONE settled turn's fold (task-8f904a88b9bc3d59). Per-tab and
  # ASSIGNS-ONLY: a fold is a reading preference, not a fact about the turn, so
  # nothing is written to the store and nothing is broadcast to co-viewers. A
  # `handle_event` deliberately — the pds-w42 census pins ChatLive's handle_info
  # head count, and a reader's click has no business becoming a message.
  #
  # The key is the turn's `turn_settled_at`, so a stale click (the session
  # switched under an in-flight click) simply toggles a key nothing renders and
  # the next `assign_messages` drops it from view — no crash, no lookup needed.
  def handle_event("toggle_turn_fold", %{"key" => key}, socket) do
    expanded = socket.assigns.turn_folds_expanded

    next =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, assign(socket, turn_folds_expanded: next)}
  end

  # Expand/collapse the RUNNING turn's "+N previous" control
  # (task-b66928b2958c8cfa). Per-tab and ASSIGNS-ONLY, exactly like
  # `toggle_turn_fold` above: what a reader chooses to look at is not a fact
  # about the turn, so nothing is stored and nothing is broadcast. No key is
  # carried because there is only ever one running turn to open.
  def handle_event("toggle_running_fold", _params, socket) do
    {:noreply, assign(socket, running_fold_expanded: !socket.assigns.running_fold_expanded)}
  end

  # Expand/collapse a rail workflow row's phase→agent tree (charter D47). The
  # per-tab `rail_expanded` map is keyed by task_id; default EXPANDED (user
  # mandate 2026-07-09: "we want to be able to see what is happening in the
  # workflow"), a manual toggle is the per-tab override that wins. Never
  # broadcast — a co-viewer's collapse is their own.
  def handle_event("rail-toggle", %{"id" => id}, socket) do
    entry = Map.put(Map.get(socket.assigns.rail, id) || %{}, "task_id", id)
    current = rail_open?(socket.assigns.rail_expanded, entry)

    {:noreply,
     assign(socket, rail_expanded: Map.put(socket.assigns.rail_expanded, id, not current))}
  end

  # Expand/collapse ONE rail agent's per-agent detail (wsc-ad) — keyed by the
  # node's agentId, default CLOSED, a manual toggle is the per-tab override that
  # wins. Never broadcast (a co-viewer's collapse is their own). A stale id (the
  # session switched under an in-flight click) is a harmless no-op flip.
  def handle_event("rail-agent-toggle", %{"id" => id}, socket) do
    current = agent_detail_open?(socket.assigns.agent_detail_expanded, id)

    {:noreply,
     assign(socket,
       agent_detail_expanded: Map.put(socket.assigns.agent_detail_expanded, id, not current)
     )}
  end

  # ── AskUserQuestion answer form (charter D31/D32) ────────────────────────

  # Pick (or un-pick) an option chip. Single-select REPLACES; multiSelect TOGGLES
  # (a chip can be added/removed). Purely socket-local scratch state — never
  # broadcast — until the ONE submit resolves the ask.
  def handle_event(
        "question-toggle",
        %{"rid" => rid, "qi" => qi, "label" => label} = params,
        socket
      ) do
    qi = to_int(qi)
    multi = params["multi"] == "true"
    form = get_question_form(socket, rid)
    current = Map.get(form.selections, qi, [])

    next =
      cond do
        multi and label in current -> List.delete(current, label)
        multi -> current ++ [label]
        label in current -> []
        true -> [label]
      end

    form = %{form | selections: Map.put(form.selections, qi, next)}
    {:noreply, put_question_form(socket, rid, form)}
  end

  # Free-text custom answer for one question (phx-change on the input). A
  # non-empty custom value wins over chip selections at submit time.
  def handle_event("question-custom", %{"rid" => rid, "qi" => qi, "value" => value}, socket) do
    qi = to_int(qi)
    form = get_question_form(socket, rid)
    form = %{form | custom: Map.put(form.custom, qi, value)}
    {:noreply, put_question_form(socket, rid, form)}
  end

  # Submit ALL answers as ONE allow (charter D32). Answers are keyed by the
  # QUESTION STRING (proven — the CLI keys internally by K.question); a
  # multiSelect value is comma-joined labels; a non-empty custom field overrides
  # the chips. Empty questions are omitted (the CLI narrates "did not answer").
  def handle_event("question-submit", %{"rid" => rid}, socket) do
    case find_message_by_rid(socket, rid) do
      %{questions: questions, raw_input: raw_input} ->
        form = get_question_form(socket, rid)
        answers = build_answers(questions, form)
        updated = Map.put(raw_input || %{}, "answers", answers)
        {:noreply, resolve_permission(socket, rid, {:allow, updated})}

      _ ->
        {:noreply, socket}
    end
  end

  # Dismiss the questions — a deny carrying an honest message the model sees.
  def handle_event("question-dismiss", %{"rid" => rid}, socket) do
    {:noreply,
     resolve_permission(
       socket,
       rid,
       {:deny, "The user dismissed the questions without answering."}
     )}
  end

  # ── sidebar as a managed resource list (wave 2) ──────────────────────────

  # Toggle the per-row kebab menu (idempotent open/close). `phx-click-away` on
  # the open menu closes it; opening a different row's menu replaces the target.
  def handle_event("session-menu-toggle", %{"id" => id}, socket) do
    next = if socket.assigns.open_menu_session == id, do: nil, else: id
    {:noreply, assign(socket, open_menu_session: next)}
  end

  def handle_event("session-menu-close", _params, socket) do
    {:noreply, assign(socket, open_menu_session: nil)}
  end

  # Inline rename triad (cloned from the sheet-tab rename, sheet_grid.ex) with
  # ONE divergence: blur COMMITS (a click-away while editing keeps your edit).
  def handle_event("session-rename-start", %{"id" => id}, socket) do
    {:noreply, assign(socket, renaming_session: id, open_menu_session: nil)}
  end

  # Commit path shared by Enter (form submit → `title`) and blur (→ `value`).
  # A blank/whitespace title cancels rather than erroring through the required
  # validation — an empty rename is a no-op, never a wipe.
  def handle_event("session-rename", %{"id" => id} = params, socket) do
    title = (params["title"] || params["value"] || "") |> String.trim()
    socket = assign(socket, renaming_session: nil)

    socket =
      if title == "" do
        socket
      else
        # rename/2 pins title_source: "human" — a human name is never
        # overwritten by the AI titler (charter D13). rename/2 takes no scope
        # argument (it reads :global), so the tenancy check is made here.
        if tenancy_permits?(socket, id), do: StudioChat.rename(id, title)
        refresh_sessions(socket)
      end

    {:noreply, socket}
  end

  def handle_event("session-rename-cancel", _params, socket) do
    {:noreply, assign(socket, renaming_session: nil)}
  end

  def handle_event("session-archive", %{"id" => id}, socket) do
    # `archive_session/2` is called at `:global` because the STORE call takes no
    # narrower scope that keeps NULL-owned legacy rows reachable (see
    # `session_in_tenancy?/2`); `tenancy_permits?/2` is what refuses a
    # CROSS-TENANT reach.
    #
    # WHAT THIS COMMENT USED TO SAY, and why it no longer does: "the sidebar sees
    # every workspace's sessions, unchanged from today", stated flatly, of every
    # mount. That was written when this LiveView was mounted ONLY at flat
    # `/studio/chat` under the instance-wide `{LiveAuth, :admin}`, and it is
    # still true THERE (charter D17/D18 — `chat_live_test.exs`'s "tenant seam"
    # case pins it). It became false the day the router also mounted this module
    # inside `live_session :scoped_admin_studio` at `/w/:ws/p/:proj/studio/chat`
    # behind `{LiveAuth, :scoped_admin}` — a gate that proves owner/admin in the
    # URL WORKSPACE and nothing more, so a global sidebar THERE discloses every
    # other tenant's session titles to a principal who proved authority in one.
    # The read scope is now per-mount: see `read_workspace_id/1`, which clamps
    # the scoped mount and leaves the flat superuser path alone.
    if tenancy_permits?(socket, id), do: StudioChat.archive_session(id, :global)
    {:noreply, after_lifecycle_mutation(socket, id)}
  end

  # Unarchive keeps an on-screen session on screen (store_session_id unchanged);
  # it only leaves the archived shelf, so a refresh is enough — no push_patch.
  def handle_event("session-unarchive", %{"id" => id}, socket) do
    if tenancy_permits?(socket, id), do: StudioChat.unarchive_session(id, :global)
    {:noreply, socket |> assign(open_menu_session: nil) |> refresh_sessions()}
  end

  def handle_event("session-delete", %{"id" => id}, socket) do
    # A managed-codex session that recorded a runtime attempt / usage receipt is
    # protected by RESTRICT FKs (StudioChat.delete_session maps them to a
    # changeset error). Surface that as a flash — never let the FK abort crash
    # the admin LiveView. Its ledgers are permanent; archive is the way out.
    case delete_within_tenancy(socket, id) do
      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That chat has a recorded runtime ledger and can't be deleted — archive it instead."
         )}

      _ok_or_noop ->
        {:noreply, after_lifecycle_mutation(socket, id)}
    end
  end

  # Flip the active ⇄ archived shelf. refresh_sessions reads the new flag.
  def handle_event("toggle-archived", _params, socket) do
    show = not (socket.assigns.show_archived == true)

    {:noreply,
     socket |> assign(show_archived: show, open_menu_session: nil) |> refresh_sessions()}
  end

  # ── keyboard thread jump + session palette (T3 keybindings parity) ───────
  #
  # Three events, ONE navigation: every one of them ends at
  # `activate_session/2`, which is the same `session_link_path/2` the sidebar
  # <.link patch={…}> is built from. There is no second way to reach a session.
  # The client half (bp-chat-palette.js) only classifies keys and pushes; it
  # never touches history or location.

  # Cmd/Ctrl+N → the Nth VISIBLE sidebar session. Past the end is a no-op: a
  # number the sidebar does not show must not navigate anywhere, and must never
  # crash the chat.
  def handle_event("chat-jump", %{"n" => n}, socket) do
    {:noreply, activate_nth_session(socket, n)}
  end

  def handle_event("chat-palette-open", _params, socket) do
    {:noreply, assign(socket, palette_open: true, open_menu_session: nil)}
  end

  # Escape (claimed by the palette input, so it never reaches the global
  # interrupt listener) and a backdrop click both land here. Closing is UI-only:
  # it never touches the session, the runtime, or a running turn.
  def handle_event("chat-palette-close", _params, socket) do
    {:noreply, assign(socket, palette_open: false)}
  end

  # Enter on the highlighted palette row. The id is client-supplied, so it is
  # matched against the VISIBLE list rather than trusted — an id that is not on
  # screen closes the palette and navigates nowhere.
  def handle_event("chat-palette-activate", %{"id" => id}, socket) do
    socket = assign(socket, palette_open: false)

    case Enum.find(socket.assigns.sessions, &(&1.id == id)) do
      nil -> {:noreply, socket}
      session -> {:noreply, activate_session(socket, session.id)}
    end
  end

  # Stale/unknown client events must never crash the chat — mirror the other
  # admin LVs' tolerant catch-all.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── composer command routing (charter D36b) — shared by the selectors and
  #    the slash builtins, kept OUT of the handle_event group ─────────────────

  # Switch permission mode — shared by the header selector and the /plan slash
  # builtin. See the `set_mode` ack handler for the ack-driven
  # persistence contract (D23): a live switch persists only the confirmed value.
  defp change_mode(socket, mode) do
    cond do
      mode == socket.assigns.mode ->
        socket

      session = socket.assigns.session ->
        # Optimistic: move the selector now for instant feedback, but DON'T
        # persist yet — the persisted mode is the last ACKED value (D23). Remember
        # the request_id (latest-outstanding correlation) and the revert target:
        # the last known-good mode, which a chain of unconfirmed rapid switches
        # must preserve rather than fold into an intermediate optimistic value.
        {:ok, request_id} = Runtime.steer(socket.assigns.provider, session, %{mode: mode})
        revert_to = revert_target(socket)

        socket
        |> assign(mode: mode, pending_mode: %{req: request_id, revert_to: revert_to})
        |> append_message(:system, "Permission mode → #{mode_label(mode)}.")

      true ->
        persist_mode(socket, mode)
        assign(socket, mode: mode, pending_mode: nil)
    end
  end

  # Switch the brain — shared by the header picker and the /model slash builtin.
  # `choice` is an already-normalized alias or nil (= CLI default).
  defp change_model(socket, choice) do
    label = if choice, do: model_label(choice), else: "the CLI default"

    if sid = socket.assigns[:store_session_id], do: StudioChat.set_model_choice(sid, choice)

    if session = socket.assigns[:session],
      do: Runtime.steer(socket.assigns.provider, session, %{model: choice || "default"})

    socket
    |> assign(model_choice: choice || "default")
    |> append_message(:system, "Model → #{label}.")
  end

  # Pick the reasoning-effort tier (charter D48) — shared by the footer selector.
  # Intent-only: persist on the row (rides the next spawn as --effort) and post an
  # honest line. There is NO live steer (no set_effort control verb exists), so a
  # mid-session change applies from the next resume, never the running turn.
  defp change_effort(socket, choice) do
    if sid = socket.assigns[:store_session_id], do: StudioChat.set_effort_choice(sid, choice)

    socket
    |> assign(effort_choice: choice || "default")
    |> append_message(:system, effort_line(choice, socket.assigns[:session]))
  end

  defp effort_line(choice, nil), do: "Effort → #{choice || "the CLI default"}."

  defp effort_line(choice, _live),
    do: "Effort → #{choice || "the CLI default"} (applies from the next resume)."

  # Classify a submitted composer line as a BUILTIN slash command (charter D36b)
  # or `:none` (send it to the model as-is). Only EXACT builtins route — a
  # `/plan` with trailing prose is ambiguous, so it falls through as user text.
  # The floor is /plan · /autopilot · /bypass · /model (the retired /default
  # builtin is gone, charter D48 — `default` is no longer an offered mode);
  # session-mutating CLI commands (/compact, /clear) are NOT builtins — they
  # ride through as plain user text so the CLI handles them itself, and our
  # store identity is pinned by `--session-id`/`--resume` regardless of what a
  # slash-turn result echoes (D8; spot-check assumption per D36b — we never
  # scrape ids off frames).
  defp builtin_command("/plan"), do: {:set_mode, "plan"}
  defp builtin_command("/autopilot"), do: {:set_mode, "auto"}
  # The toggle never offers bypass (charter D48) — this builtin is the arm
  # ceremony's entry point now that the raw six-mode select is gone.
  defp builtin_command("/bypass"), do: :arm_bypass
  defp builtin_command("/model"), do: :model_usage

  # /task builtins (hand-task surface): both expand to a doctrine prompt the
  # model works with its own bp hands — the builtin is sugar, never a second
  # write path (chat-task-hands D1). `/task new <wish>` authors + publishes;
  # `/task <id>` claims and works. Bare/malformed forms teach usage.
  defp builtin_command("/task new " <> wish) do
    case String.trim(wish) do
      "" -> :task_usage
      w -> {:agent_prompt, task_create_prompt(w)}
    end
  end

  defp builtin_command("/task " <> rest) do
    case String.trim(rest) do
      "" -> :task_usage
      "new" -> :task_usage
      id -> {:agent_prompt, task_work_prompt(id)}
    end
  end

  defp builtin_command("/task"), do: :task_usage

  defp builtin_command(text) when is_binary(text) do
    case String.split(text, ~r/\s+/, trim: true) do
      ["/model", "default"] ->
        {:set_model, nil}

      ["/model", arg] ->
        # normalize_model fails closed to nil — but for a TYPED command that
        # would silently reset a sticky choice to the CLI default on any typo
        # ("/model opsu"). An unrecognized alias shows usage instead; only an
        # explicit "/model default" resets.
        case Runtime.normalize_model("claude", arg) do
          nil -> :model_usage
          choice -> {:set_model, choice}
        end

      _ ->
        :none
    end
  end

  defp builtin_command(_), do: :none

  # Clear the server-bound composer input (charter D24 — an uncontrolled input's
  # DOM text is invisible to render/1, so the clear must go through the assign).
  defp clear_composer(socket), do: assign(socket, composer_draft: "")

  # Clear the persisted sticky draft for the on-screen session (charter D36c) —
  # a no-op when there is no store row yet (a fresh chat before its first send).
  defp clear_persisted_draft(socket) do
    if sid = socket.assigns[:store_session_id], do: StudioChat.set_draft(sid, nil)
    socket
  end

  # PHASE 2 of send (charter D24): the deferred, failure-prone work. Bring the
  # session up (creating the store row + resuming the CLI as needed), write the
  # user turn, and — only once the frame is DISPATCHED — persist it. Every hard
  # failure withdraws the optimistic echo and restores the words verbatim so a
  # send never disappears into a lie:
  #
  #   * create/spawn error → `ensure_session` already posted an honest system
  #     line and went `:offline`; we just undo the echo + hand the words back.
  #   * port-write error   → the model never got the turn; system line + go
  #     offline (the next send lazy-resumes) + hand the words back.
  #   * DISPATCHED + persist-exhaustion → the model DID get the turn, so the echo
  #     STAYS and the composer stays CLEARED (restoring would double-send);
  #     `persist_user_message` warns that this row may not survive a reopen.
  @impl true
  def handle_info({:dispatch_send, text, queued?}, socket) do
    socket = ensure_session(socket)

    case socket.assigns.session do
      nil ->
        # Nothing consumed yet — staged attachments survive in the strip, the
        # words go back to the composer. A send never disappears into a lie.
        {:noreply, restore_failed_send(socket, text)}

      session ->
        # Consume the pasted/dropped images only once a session exists (D25):
        # store each under the chat-owned dir and build the content blocks.
        {attachments, socket} = consume_attachments(socket)

        case build_user_content(text, attachments) do
          [] ->
            # Every image failed to store AND there was no text — never write
            # an empty user frame; say so honestly and keep the composer live.
            {:noreply,
             socket
             |> append_message(:system, "⚠ Nothing to send — the attachment could not be read.")
             |> restore_failed_send(text)
             |> assign(status: :ready)}

          blocks ->
            case Runtime.send_turn(socket.assigns.provider, session, blocks) do
              :ok ->
                # With images, upgrade the phase-1 text echo to the full bubble
                # (text + thumbnails) now that the stored data-URIs exist.
                socket =
                  if attachments != [] do
                    socket
                    |> withdraw_pending_echo()
                    |> append_user_message(text, attachments)
                  else
                    socket
                  end

                # Co-viewing (wave 4): other tabs on this session get the user
                # turn as a broadcast — the CLI never echoes it back as a frame,
                # so without this their transcripts would diverge until reopen.
                if topic = socket.assigns[:subscribed_topic] do
                  images =
                    Enum.map(attachments, fn a ->
                      %{data_uri: data_uri(a.media_type, a.bytes)}
                    end)

                  Phoenix.PubSub.broadcast_from(
                    Barkpark.PubSub,
                    self(),
                    topic,
                    {:chat_user_message, text, images}
                  )
                end

                {:noreply,
                 socket
                 |> persist_user_message(text, attachments, queued?)
                 |> assign(status: :thinking, pending_echo_id: nil)}

              {:error, reason} ->
                note =
                  if attachments != [],
                    do: " Your attached images were not sent — re-attach them.",
                    else: ""

                {:noreply,
                 socket
                 |> append_message(:system, send_error_text(reason) <> note)
                 |> assign(session: nil, status: :offline)
                 |> restore_failed_send(text)}
            end
        end
    end
  end

  def handle_info({:claude_chat_event, %{"type" => "system", "subtype" => "init"} = ev}, socket) do
    observed = ev["permissionMode"] || ev["permission_mode"]

    init = %{
      model: ev["model"],
      session_id: ev["session_id"],
      permission_mode: observed
    }

    status = if socket.assigns.status == :starting, do: :ready, else: socket.assigns.status

    # system/init fires once per TURN (charter): the queued turn is now starting,
    # so drop the live-only '⧗ queued' badge on any echoed row (charter D43). The
    # metadata.queued fact stays in the store; only the chrome clears.
    {:noreply,
     socket
     # A new turn is starting: forget the previous turn's checklist card so this
     # turn's first TodoWrite starts a fresh living card (charter D39), and drop
     # the live-only '⧗ queued' badge on any echoed row (charter D43).
     |> assign(
       init: init,
       status: status,
       todo_card_id: nil
     )
     |> assign_messages(clear_queued_badges(socket.assigns.messages))
     |> observe_permission_mode(observed)}
  end

  def handle_info(
        {:studio_chat_runtime_event, %Runtime.Event{kind: :text_delta} = event},
        socket
      ) do
    text = get_in(event.native, ["params", "delta"]) || ""
    {:noreply, assign(socket, streaming: advance_streaming(socket.assigns.streaming, text))}
  end

  def handle_info(
        {:studio_chat_runtime_event, %Runtime.Event{kind: :turn_completed} = event},
        socket
      ) do
    socket =
      case socket.assigns.streaming do
        %{text: text} when is_binary(text) and text != "" ->
          append_message(socket, :assistant, text)

        _ ->
          socket
      end

    line =
      case event.terminal_state do
        :interrupted -> "⊘ Interrupted — the session is still live."
        :failed -> "The turn ended with an error."
        _ -> nil
      end

    socket = if line, do: append_message(socket, :system, line), else: socket

    {:noreply,
     socket
     |> assign(status: :ready, streaming: nil, interrupt_requested: false)
     |> refresh_sessions()}
  end

  def handle_info(
        {:studio_chat_runtime_event, %Runtime.Event{kind: kind, native: native}},
        socket
      )
      when kind in [:item_started, :item_completed] do
    lifecycle = if kind == :item_started, do: :started, else: :completed
    item = get_in(native, ["params", "item"]) || %{}

    {:noreply,
     fold_rail(
       socket,
       StudioChat.rail_apply_codex_item(socket.assigns.rail, item, lifecycle)
     )}
  end

  # Codex runtime FAILURE events (codex/protocol.ex): `:protocol_error` (framing
  # buffer overflow at :139, malformed JSONL at :157), a bare `:error` frame, and
  # `:process_failed` (the codex process exiting non-zero). Each carries an `error`
  # map with the reason. Without a clause they fell to the bare %Runtime.Event{}
  # catch-all below and rendered NOTHING — a hard failure left the transcript
  # silent (recorder.ex records these kinds; only this LiveView surface was dark).
  # Surface the reason as an honest :system line. Purely additive: the turn
  # lifecycle (status/streaming) is left to the terminal turn_completed / DOWN
  # paths, so a mid-stream malformed line does not falsely settle the turn.
  def handle_info(
        {:studio_chat_runtime_event, %Runtime.Event{kind: kind, error: error}},
        socket
      )
      when kind in [:protocol_error, :error, :process_failed] do
    {:noreply, append_message(socket, :system, codex_failure_line(kind, error))}
  end

  def handle_info({:studio_chat_runtime_event, %Runtime.Event{}}, socket),
    do: {:noreply, socket}

  def handle_info(
        {:claude_chat_event,
         %{
           "type" => "stream_event",
           "event" => %{
             "type" => "content_block_delta",
             "delta" => %{"type" => "text_delta", "text" => text}
           }
         }},
        socket
      ) do
    # The first text delta is the moment thinking gives way to prose — settle any
    # live pulse into its durable row (charter D41) before the bubble streams.
    socket = settle_thinking(socket)
    {:noreply, assign(socket, streaming: advance_streaming(socket.assigns.streaming, text))}
  end

  # The thinking block opens (charter D41): show the ✻ row immediately, even
  # before the first `thinking_tokens` count lands, so a bout that thinks briefly
  # still pulses. Idempotent — a live pulse already open keeps its count.
  def handle_info(
        {:claude_chat_event,
         %{
           "type" => "stream_event",
           "event" => %{
             "type" => "content_block_start",
             "content_block" => %{"type" => "thinking"}
           }
         }},
        socket
      ) do
    {:noreply, assign(socket, thinking_pulse: socket.assigns[:thinking_pulse] || blank_pulse())}
  end

  # A thinking delta (charter D41). The count comes from `thinking_tokens`, NEVER
  # from a delta's per-block count. Forward-compatible: today `delta["thinking"]`
  # is always "" (the wire carries no thinking text), but if a future CLI ever
  # populates it we append it live and fall back to the counter otherwise. The
  # encrypted signature is never read.
  def handle_info(
        {:claude_chat_event,
         %{
           "type" => "stream_event",
           "event" => %{
             "type" => "content_block_delta",
             "delta" => %{"type" => "thinking_delta"} = delta
           }
         }},
        socket
      ) do
    pulse = socket.assigns[:thinking_pulse] || blank_pulse()

    pulse =
      case delta["thinking"] do
        text when is_binary(text) and text != "" -> %{pulse | text: pulse.text <> text}
        _ -> pulse
      end

    {:noreply, assign(socket, thinking_pulse: pulse)}
  end

  # The cumulative thinking-token counter (charter D41). `estimated_tokens` is
  # monotonic across a bout — bump the pulse's high-water mark. This clause and
  # the two above MUST precede the `{:claude_chat_event, _event}` catch-all.
  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "thinking_tokens"} = ev},
        socket
      ) do
    pulse = socket.assigns[:thinking_pulse] || blank_pulse()
    tokens = max(pulse.tokens, thinking_tokens_count(ev))
    {:noreply, assign(socket, thinking_pulse: %{pulse | tokens: tokens})}
  end

  def handle_info(
        {:claude_chat_event, %{"type" => "assistant", "message" => %{"content" => blocks}} = ev},
        socket
      )
      when is_list(blocks) do
    # A thinking bout with no intervening prose (thinking → tool_use) settles here
    # so its ✻ row lands just before the tool row, matching the persisted order.
    socket = settle_thinking(socket)

    # Runtime auth guard (chat-task-hands, charter decision 5): a logged-out
    # CLI's assistant frame carries `error:"authentication_failed"` — flip the
    # onboarding card to :not_logged_in the moment it shows. The frame's text
    # blocks still render below (transcript stays honest).
    socket =
      if Runtime.auth_failure?(socket.assigns.provider, ev),
        do: flag_auth_failure(socket),
        else: socket

    # A sub-agent's frames carry a top-level parent_tool_use_id (charter D40);
    # every row this frame produces inherits it so children indent under the
    # spawn row. Top-level frames leave it nil (no indent).
    parent_id = ev["parent_tool_use_id"]

    socket =
      Enum.reduce(blocks, socket, fn
        %{"type" => "text", "text" => text}, acc when is_binary(text) ->
          if String.trim(text) == "" do
            acc
          else
            append_message(acc, :assistant, text,
              html: render_paper_html(text),
              parent_tool_use_id: parent_id
            )
          end

        %{"type" => "tool_use", "name" => name} = block, acc ->
          input = block["input"]

          if StudioChat.todo_shaped?(input) and is_nil(parent_id) do
            # A TOP-LEVEL TodoWrite-shaped call becomes the turn's ONE living
            # checklist card (D39) instead of a generic tool row. A sub-agent's
            # TodoWrite must never hijack the main turn's card — it stays a
            # plain (indented) tool row below its spawn (D40).
            apply_todo_block(acc, input)
          else
            # Thread the FULL input + tool name so the diff renderer (D38) can
            # dispatch on input SHAPE; the store already persists both verbatim
            # (recorder.ex), so live and replay render the identical diff.
            append_message(acc, :tool, tool_line(name, input),
              tool_use_id: block["id"],
              output: nil,
              # The settle gate's two facts, seeded honest: the row is born
              # UNSETTLED (its turn is running) and error-free. The turn's
              # terminal result frame flips `turn_settled`; a tool_result block
              # carrying `is_error` flips `tool_error`.
              turn_settled: false,
              tool_error: false,
              # The fold facts (task-8f904a88b9bc3d59) are stamped by the SERVER
              # at the terminal frame — a live row carries none, which is exactly
              # what keeps a running turn unfoldable.
              turn_settled_at: nil,
              turn_duration_ms: nil,
              turn_outcome: nil,
              tool: name,
              input: input,
              parent_tool_use_id: parent_id,
              spawn?: spawn?(name, input),
              spawn_label: spawn_label(name, input)
            )
          end

        _block, acc ->
          acc
      end)

    # Persist on COMPLETION (D7) — the whole assistant message is here, so this
    # is the message boundary, never a per-delta write. Streaming deltas only
    # touch the `:streaming` assign; nothing hits the store mid-turn.

    # The complete message supersedes the accumulated preview, and the sidebar
    # picks up the fresh summary/message_count.
    {:noreply, socket |> assign(streaming: nil) |> refresh_sessions()}
  end

  def handle_info({:claude_chat_event, %{"type" => "result"} = ev}, socket) do
    # A turn that thought then produced no prose/tool still settles its pulse
    # here so the ✻ row is never lost (charter D41).
    socket = settle_thinking(socket)

    # An interrupted turn arrives as `error_during_execution` too — the ONLY
    # way to tell it from a genuine error is that WE asked to stop
    # (`interrupt_requested`) or the CLI tagged the terminus
    # `aborted_streaming`. Classify honestly: an interrupt is a normal outcome,
    # not a failure, and the session stays live for a follow-up.
    #
    # This now runs BEFORE the settle: the same verdict that picks the system
    # line also picks the fold label, so the two can never disagree.
    interrupted? =
      socket.assigns[:interrupt_requested] == true or
        ev["terminal_reason"] == "aborted_streaming"

    # The TURN boundary is the settle gate: every tool row of this turn may now
    # show its outcome glyph. A row whose tool_result never arrived stays
    # neutral (the provenance gate lives in ChatToolRenderer.settle_state/1).
    #
    # The fold stamp rides along, built by the SAME server-owned builder the
    # Recorder hands its durable write (task-8f904a88b9bc3d59) — the live mirror
    # of one truth, never a second derivation. `duration_ms` is the runtime's own
    # off this very frame (the `last_result` badge below reads the same field).
    socket =
      settle_tool_rows(
        socket,
        StudioChat.turn_settle_stamp(%{
          duration_ms: ev["duration_ms"],
          interrupted?: interrupted?
        })
      )

    socket =
      cond do
        # Runtime auth guard (chat-task-hands, charter decision 5): an unauthed
        # turn's terminal result says `subtype:"success"` BUT `is_error:true` /
        # `terminal_reason:"api_error"` (captured wire truth —
        # fixtures/claude_chat/unauthed_stream.ndjson). This clause runs FIRST:
        # subtype alone is never trusted.
        Runtime.auth_failure?(socket.assigns.provider, ev) ->
          flag_auth_failure(socket)

        Runtime.result_success?(socket.assigns.provider, ev) ->
          maybe_kick_title(socket)

        interrupted? ->
          append_message(socket, :system, "⊘ Interrupted — the session is still live.")

        true ->
          append_message(socket, :system, "The turn ended with an error (#{ev["subtype"]}).")
      end

    socket = record_result(socket, ev)
    last_result = %{duration_ms: ev["duration_ms"], cost_usd: ev["total_cost_usd"]}

    {:noreply,
     socket
     |> assign(
       status: :ready,
       streaming: nil,
       thinking_pulse: nil,
       last_result: last_result,
       interrupt_requested: false
     )
     |> refresh_sessions()}
  end

  # The async AI title landed (the store's clobber guard already refused any
  # write that would stomp a human rename) — refresh the sidebar so the row
  # shows it, whichever session it belongs to.
  #
  # ONE accepted write reaches this tab TWICE: `Recorder.broadcast_title/2`
  # publishes on the activity topic (subscribed at mount) AND on the on-screen
  # session's topic (subscribed by `subscribe_session/2`) so the SSE forwarder
  # gets it too (ct-bl-recorder-titles). The second delivery is DROPPED here —
  # not merely tolerated: `refresh_sessions/1` is a store read, and firing it
  # again for a row we already render would re-query on every title and let a
  # concurrent edit land as a flicker the user never asked for. The drop is
  # keyed on what is RENDERED, so a genuinely new title always refreshes.
  def handle_info({:chat_title, session_id, title}, socket) do
    if title_rendered?(socket, session_id, title) do
      {:noreply, socket}
    else
      {:noreply, refresh_sessions(socket)}
    end
  end

  # The CLI's advertised slash commands landed (charter D36a), broadcast by the
  # Recorder after its initialize ack. We subscribe to exactly ONE session topic
  # at a time, so any list on the wire belongs to the on-screen session — stamp
  # it so the composer's slash menu offers the real command vocabulary.
  def handle_info({:chat_commands, _session_id, commands}, socket) do
    {:noreply, assign(socket, commands: commands)}
  end

  # The CLI acked a permission-mode switch (charter D17/D23). Two guards, in
  # order:
  #
  #   1. CORRELATE by request_id — only the ack matching the LATEST outstanding
  #      switch may act. A stale ack (a rapid re-switch superseded this one) is
  #      dropped: acting on it would mis-revert a switch the user has already
  #      moved past. This is the fix for the wave-2 seam (acks were value-matched).
  #   2. Never trust the bare subtype:success — assert the ECHOED mode (D12
  #      vacuous-green: the alt wire key no-ops silently, returning an empty echo).
  #
  # A confirmed echo COMMITS: it persists the acked mode (the store's mode is the
  # last confirmed value, D23) and clears the pending marker. An empty/mismatched
  # echo REVERTS the optimistic selector to the pending switch's known-good mode,
  # persists that, and says so honestly — the UI never claims a switch that didn't
  # land.
  def handle_info({:claude_chat_control, :set_mode, request_id, response}, socket) do
    case socket.assigns[:pending_mode] do
      %{req: ^request_id} = pending ->
        echoed = if is_map(response), do: response["mode"], else: nil

        if echoed == socket.assigns.mode do
          persist_mode(socket, echoed)
          {:noreply, assign(socket, pending_mode: nil)}
        else
          revert_to = pending.revert_to
          persist_mode(socket, revert_to)

          {:noreply,
           socket
           |> assign(mode: revert_to, pending_mode: nil)
           |> append_message(
             :system,
             "Couldn't switch permission mode — still #{mode_label(revert_to)}."
           )}
        end

      _ ->
        # Stale ack (superseded switch) or no pending switch at all — ignore it.
        {:noreply, socket}
    end
  end

  # Interrupt / set_model acks need no UI action: the interrupt's real outcome
  # arrives as the terminal `result` frame, and set_model has no surface. Swallow
  # them so they never fall to the noisy catch-all.
  def handle_info({:claude_chat_control, _kind, _request_id, _response}, socket),
    do: {:noreply, socket}

  # The Recorder engaged Autopilot (an approved plan — steer + persist already
  # done server-side, surface-agnostic). Render only: flip the toggle, drop any
  # in-flight user switch (the adoption supersedes it), tell the transcript.
  def handle_info({:studio_chat_mode_adopted, mode, :plan_approved}, socket) do
    {:noreply,
     socket
     |> assign(mode: mode, pending_mode: nil)
     |> append_message(:system, "Plan approved — #{mode_label(mode)} engaged.")}
  end

  # A permission ask (charter D31). The SAME wire message routes to one of three
  # cards by its tool_name: AskUserQuestion → an answer FORM, ExitPlanMode → the
  # proposed-plan card (title from the first heading, clamped paper-engine
  # preview, Approve / Keep planning — charter D34), anything else → the generic
  # Allow/Deny approval card. The Recorder already persisted the pending row
  # under the matching role (D31); here we only render, and `refresh_sessions`
  # re-reads the bumped pending count so the "needs you" sidebar pill raises.
  # Every co-viewing tab receives this via the session PubSub topic and renders
  # its own card independently.
  def handle_info({:claude_chat_permission, ask}, socket) do
    id = socket.assigns.next_id
    message = permission_message(id, ask)

    socket =
      socket
      |> put_message(message)
      |> seed_question_form(message)
      |> refresh_sessions()

    {:noreply, socket}
  end

  # The CLI compacted the conversation to reclaim context window (charter D27).
  # Today this system subtype is eaten by the catch-all below — but compaction is
  # exactly the moment the headroom ring resets, so an unexplained shrink would
  # read as a bug. Surface an honest, EPHEMERAL system line naming the trigger and
  # the pre-compaction size. Deliberately NOT persisted (D7 store is display
  # history; a compaction is a live event, and the next result's snapshot already
  # tells the durable story via the ring).
  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "compact_boundary"} = ev},
        socket
      ) do
    meta = ev["compact_metadata"] || %{}
    pre = meta["pre_tokens"]

    line =
      case meta["trigger"] do
        "manual" -> "Conversation compacted manually#{compact_size(pre)}."
        _ -> "Conversation compacted automatically#{compact_size(pre)}."
      end

    {:noreply, append_message(socket, :system, line)}
  end

  # The CLI reports a tool's RESULT as a user-frame tool_result block (wire-
  # proven). Attach the output to its tool row by tool_use_id — the transcript
  # then reads like the terminal: `● Bash(…)` with `⎿ output` beneath. The
  # Recorder persists the same output into the row's metadata for replay.
  def handle_info({:claude_chat_event, %{"type" => "user"} = ev}, socket) do
    results = tool_results(ev)

    if results == [] do
      {:noreply, socket}
    else
      messages =
        Enum.map(socket.assigns.messages, fn m ->
          case Enum.find(results, fn {id, _out, _error?} -> id == m[:tool_use_id] end) do
            {_id, out, error?} -> m |> Map.put(:output, out) |> Map.put(:tool_error, error?)
            nil -> m
          end
        end)

      {:noreply, assign_messages(socket, messages)}
    end
  end

  # ── Task lifecycle → agent drill-down merge (charter D45/D46) ────────────────
  #
  # The four `system/task_*` frames drive an agent block's live state. Each
  # merges into the in-memory spawn row it belongs to (by tool_use_id — only
  # task_updated is task_id-only, and the row carries task_id from a prior
  # task_started or replay hydration). A VALUE-EQUALITY guard makes an unchanged
  # status+progress a no-op: `@messages` is a flat comprehension, so every
  # reassign is an O(n) server render per tab — the guard turns hot progress into
  # render-on-change. Co-viewers converge off the Recorder's verbatim
  # rebroadcast. These clauses MUST precede the `{:claude_chat_event, _event}`
  # catch-all below.

  # A sub-agent started: light the block as running and stamp its task_id so a
  # later task_updated (task_id-only) can still find the row.
  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "task_started"} = ev},
        socket
      ) do
    merge_task_row(
      socket,
      by_tool_use_id(ev["tool_use_id"]),
      drop_nil(%{task_id: ev["task_id"], task_status: "running"})
    )
  end

  # A progress heartbeat: the latest "Running: …" line AND the rail's phase→agent
  # tree (charter D46/D47). The wire field is `description` (never `line`). Keeps
  # the block running so the breathing line shows even if task_started was missed.
  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "task_progress"} = ev},
        socket
      ) do
    socket = fold_rail(socket, StudioChat.rail_capture_progress(socket.assigns.rail, ev))

    merge_task_row(
      socket,
      by_tool_use_id(ev["tool_use_id"]),
      drop_nil(%{task_progress: ev["description"], task_status: "running"})
    )
  end

  # Completion notification (tool_use_id aboard): flip to the terminal status so
  # the block collapses to its ⎿ report and the spinner stops; the rail entry
  # settles to the same status (charter D47).
  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "task_notification"} = ev},
        socket
      ) do
    socket =
      fold_rail(
        socket,
        StudioChat.rail_stamp_status(socket.assigns.rail, ev["task_id"], ev["status"])
      )

    merge_task_row(
      socket,
      by_tool_use_id(ev["tool_use_id"]),
      %{task_status: ev["status"] || "completed"}
    )
  end

  # task_updated is task_id-only, carrying a status patch. Resolve by task_id
  # (the row learned it from task_started/replay); drop harmlessly with no patch.
  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "task_updated"} = ev},
        socket
      ) do
    case get_in(ev, ["patch", "status"]) do
      status when is_binary(status) ->
        socket =
          fold_rail(
            socket,
            StudioChat.rail_stamp_status(socket.assigns.rail, ev["task_id"], status)
          )

        merge_task_row(socket, by_task_id(ev["task_id"]), %{task_status: status})

      _ ->
        {:noreply, socket}
    end
  end

  # The agents rail's row set (charter D47): a task_id-keyed snapshot that adds
  # rows on launch and empties on completion. Folded into the mission-control
  # rail below the composer — this is the frame the user's Workflow emitted that
  # the catch-all below silently dropped. Value-equality guarded (fold_rail).
  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "background_tasks_changed"} = ev},
        socket
      ) do
    {:noreply, fold_rail(socket, StudioChat.rail_apply_background(socket.assigns.rail, ev))}
  end

  def handle_info({:claude_chat_event, _event}, socket), do: {:noreply, socket}

  # A per-entry linger timer fired (charter D47): auto-dismiss THAT ONE entry
  # iff it is still present, still terminal, and its per-entry signature is
  # UNCHANGED since scheduling. The signature guard is the re-run defense — if
  # the same task_id went non-terminal again (or settled to a different tree)
  # its signature moved, so this stale prune is a no-op and the re-settle armed
  # a fresh one. Running siblings are never touched; dropping the last entry
  # makes `map_size` hit 0 so the rail region vanishes on its own. Only the
  # on-screen assign is trimmed — the stored `rail_snapshot` keeps the replay
  # law intact (the D47 store is never rewritten here).
  def handle_info({:rail_prune_entry, key, sig}, socket) do
    rail = socket.assigns.rail
    entry = Map.get(rail, key)

    if is_map(entry) and StudioChat.rail_terminal?(entry) and
         StudioChat.rail_entry_signature(entry) == sig do
      new_rail = Map.delete(rail, key)
      {:noreply, assign(socket, rail: new_rail, rail_sig: StudioChat.rail_signature(new_rail))}
    else
      {:noreply, socket}
    end
  end

  # A real port exit (exit_status frame). Run the shared honest teardown, and
  # tell the truth about a DOOMED spawn (charter D54): a nonzero exit BEFORE any
  # system/init frame means the argv was rejected — zero frames emitted, the
  # reason on stderr — so a resume would re-run the same command and re-die.
  # Surface the captured stderr reason and DO NOT invite a resume. A death AFTER
  # init resumes cleanly (lazy `--resume` rehydrates), so keep the invite and
  # append the reason when the CLI wrote one. `init` is nil until the first init
  # frame arrives, so it is the "did this session initialize?" signal.
  def handle_info({:claude_chat_exit, status, stderr_tail}, socket) do
    reason = stderr_reason(stderr_tail)
    init_seen? = not is_nil(socket.assigns[:init])

    message =
      if not init_seen? and failed_start?(status) do
        "Claude failed to start (exit #{status})" <>
          if reason != "", do: ": #{reason}", else: "."
      else
        base = "Claude session ended (exit #{status}). Send a message to resume it."
        if reason != "", do: base <> "\n" <> reason, else: base
      end

    {:noreply, teardown_session(socket, message)}
  end

  # The interrupt timed out (charter D18). CRITICAL: runtime `close/1` does
  # NOT emit {:claude_chat_exit} (only a real port exit_status does), so this
  # path must force-close AND run teardown itself. Guarded: a `result` arriving
  # first left `:interrupting`, and a session switch changed `store_session_id`
  # — both make a stale timer a no-op.
  def handle_info({:interrupt_timeout, sid}, socket) do
    if socket.assigns.status == :interrupting and socket.assigns[:store_session_id] == sid do
      if pid = socket.assigns[:session],
        do: Runtime.close(socket.assigns.provider, pid)

      {:noreply,
       teardown_session(
         socket,
         "Stopping timed out — the session was force-closed. Send a message to resume it."
       )}
    else
      {:noreply, socket}
    end
  end

  # A user message another tab on this session just dispatched (wave 4
  # co-viewing): render it here too, so every viewer's transcript converges
  # without a reopen. The sender excludes itself via broadcast_from.
  def handle_info({:chat_user_message, text, images}, socket) do
    id = socket.assigns.next_id
    message = %{id: id, role: :user, text: text, html: nil, images: images}

    {:noreply,
     socket
     |> start_turn_clock()
     |> roll_spinner_word()
     |> put_message(message)
     |> assign(status: :thinking)}
  end

  # Another tab resolved a needs-you card on this session (charter D35). Converge
  # our copy: flip the matching card to the same terminal state, drop any open
  # answer form, and re-read the sidebar so the "needs you" pill clears. The
  # resolving tab already responded to the CLI and persisted — we only mirror
  # the visible state (idempotent: an already-terminal card is left as-is).
  def handle_info({:chat_permission_resolved, request_id, status}, socket) do
    messages = flip_card(socket.assigns.messages, request_id, status)

    {:noreply,
     socket
     |> assign_messages(messages)
     |> clear_question_form(request_id)
     |> refresh_sessions()}
  end

  # D49: an approved plan's Paper landed — stamp the in-memory plan row so its
  # "→ published as Paper" link appears in EVERY co-viewing tab at once (the
  # approver's own tab is subscribed too, so it converges here, not inline). The
  # metadata was already persisted by the publishing Task, so replay is durable.
  def handle_info({:plan_paper, request_id, %{paper_id: paper_id, paper_url: paper_url}}, socket) do
    messages = stamp_plan_paper(socket.assigns.messages, request_id, paper_id, paper_url)
    {:noreply, assign_messages(socket, messages)}
  end

  # D49 failure honesty: the approve already succeeded on the wire; only the Paper
  # projection failed. Render a live-only honest system line — never a lie, never a
  # crash, and the plan stays approved.
  def handle_info({:plan_paper_failed, _request_id}, socket) do
    {:noreply,
     append_message(
       socket,
       :system,
       "Couldn't publish the approved plan as a Paper — the plan is still approved."
     )}
  end

  # The Session hit its stdout buffer cap (claude_chat.ex D126): the CLI streamed
  # bytes without a newline past the reassembly cap, so the Session force-closed
  # the port and stopped itself. It sends this NAMED reason before the DOWN
  # follows; without a clause it fell through to the catch-all no-op and the user
  # saw only the generic "ended unexpectedly" DOWN banner. Surface the captured
  # reason honestly, mirroring the :claude_chat_exit path (the stderr tail is
  # appended when the CLI wrote one). Ordered before the DOWN handler so the
  # named message wins the race against the bare process-down that follows.
  def handle_info({:claude_chat_error, :buffer_overflow, stderr_tail}, socket) do
    reason = stderr_reason(stderr_tail)

    base =
      "Claude sent more data than this session can buffer, so it was stopped. " <>
        "Send a message to resume it."

    message = if reason != "", do: base <> "\n" <> reason, else: base

    {:noreply, teardown_session(socket, message)}
  end

  # A bare process DOWN with no prior exit frame (an unexpected Session crash, or
  # the DOWN that follows our own force-close). Only act while WE still own that
  # pid — after a teardown set `session: nil`, the double-fire DOWN finds no
  # match and no-ops; teardown itself is idempotent besides.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if socket.assigns.session == pid do
      {:noreply,
       teardown_session(socket, "Claude session ended unexpectedly. Send a message to resume it.")}
    else
      {:noreply, socket}
    end
  end

  # A task-document mutation on the dataset stream (hand-task surface): fold it
  # into the Doing strip. Only PUBLISHED ledger rows count (claims live on the
  # published twin; a draft-twin echo must not flap the strip). A row is OURS
  # while this session's worker holds its claim and it is in_progress — any
  # other shape (closed, released, reaped, re-claimed elsewhere) drops it.
  def handle_info({:document_changed, %{type: "task"} = msg}, socket) do
    id = msg.doc_id

    if String.starts_with?(id, "drafts.") do
      {:noreply, socket}
    else
      # SIBLING step (wsc charter D9): a mutation of a held hand-task's PARENT
      # is the epic heartbeat (a wave_status patch, a slice closing under it) —
      # re-read the epic-goal lines. Purely additive: the claim.worker fold
      # below is untouched, and no new PubSub topic exists (this is the same
      # dataset document stream the Doing strip already rides).
      socket =
        if Enum.any?(socket.assigns.hand_tasks, fn {_tid, row} -> row.parent_id == id end),
          do: refresh_epic_goals(socket),
          else: socket

      worker = Runtime.worker_id(socket.assigns.provider, socket.assigns.store_session_id)
      content = (msg.doc && msg.doc.content) || %{}
      claim = content["claim"] || %{}

      mine? =
        claim["worker"] == worker and content["lifecycle_status"] == "in_progress"

      hand_tasks =
        if mine?,
          do: Map.put(socket.assigns.hand_tasks, id, hand_task_row(msg.doc.title, content)),
          else: Map.delete(socket.assigns.hand_tasks, id)

      {:noreply,
       socket
       |> assign(hand_tasks: hand_tasks)
       |> fold_task_transition(msg, worker)}
    end
  end

  # Every other document type on the dataset stream is not ours to render.
  def handle_info({:document_changed, _msg}, socket), do: {:noreply, socket}

  # A Recorder's live-activity ping (wave 5): overlay the sidebar card. On a
  # terminal transition (idle/offline) also re-read the list once — the stored
  # summary/status/pending-count is fresh again and the overlay yields to it.
  def handle_info({:chat_activity, sid, activity}, socket) do
    overlay =
      if activity.state in [:idle, :offline],
        do: Map.delete(socket.assigns.activity, sid),
        else: Map.put(socket.assigns.activity, sid, activity)

    # Always re-read the list: a session that just became active may not be in
    # the sidebar yet (created by another tab), and a terminal transition needs
    # the fresh stored summary/status. Activity events are change-only, so this
    # stays cheap.
    {:noreply, socket |> assign(activity: overlay) |> refresh_sessions()}
  end

  # A Recorder's workflow-summary ping (wsc charter D4): the compact D3 summary,
  # broadcast change-only on rail-signature flips. Overlay ONLY — the
  # {:chat_activity} clause above is untouched (D45's law stands) and the stored
  # rail_snapshot keeps the durable truth for cold mounts (D7). A summary for a
  # row without an epic-goal line yet also fetches it once — nil is cached, so
  # an epic-less workflow never re-queries the ledger per frame.
  def handle_info({:chat_workflow, sid, summary}, socket) when is_map(summary) do
    socket = assign(socket, workflow: Map.put(socket.assigns.workflow, sid, summary))

    socket =
      if Map.has_key?(socket.assigns.epic_goals, sid) do
        socket
      else
        case Enum.find(socket.assigns.sessions, &(&1.id == sid)) do
          nil ->
            socket

          s ->
            assign(socket,
              epic_goals:
                Map.put(socket.assigns.epic_goals, sid, StudioChat.epic_goal(s.provider, s.id))
            )
        end
      end

    {:noreply, socket}
  end

  # Herd-layer liveness ticks (charter D41h) ride the same activity topic so
  # the fleet wire can badge stalls; the Studio sidebar keys off flips only —
  # explicitly ignored here so the tick is documented, not merely swallowed by
  # the catch-all below.
  def handle_info({:chat_heartbeat, _sid, _ts}, socket), do: {:noreply, socket}

  # The session's task-credential verdict changed under us
  # (task-cth-bl-token-renewal). A long conversation must never discover its
  # lost hands as an unexplained 401: the Session renews on its own clock and
  # pushes the outcome through the Recorder, so the onboarding card flips in
  # place — no browser reload, no Re-check click, no reconnect. The frame
  # carries a VERDICT ATOM only; the credential itself never reaches the
  # LiveView, the assigns, or the DOM.
  def handle_info({:claude_chat_task_hands, verdict}, socket) do
    {:noreply, assign(socket, readiness: readiness_for_hands(verdict))}
  end

  # A registered host's authoritative state report (herd-s6) rides the activity
  # topic this LiveView already joined, and it is also the only moment the
  # server learns execution MOVED: a lease transfer becomes visible when the new
  # host first speaks under its own fence. Rebuild the context band for the OPEN
  # session so the header names who is running it now — in place, no reconnect,
  # no browser reload. Reads only: the report's own write already happened
  # server-side (ChatHosts.report_state/4), and this head touches no store.
  def handle_info({:chat_reported_state, sid, _frame}, socket) do
    if socket.assigns[:store_session_id] == sid do
      {:noreply, assign_context_identity(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The async readiness probe landed (chat-task-hands, charter decision 4).
  # A probe that CRASHES fails OPEN to :ready — the chat must never vanish
  # because the checking machinery broke; a real not-ready state will still
  # speak at spawn time (spawn_error_text) and through the runtime auth guard.
  @impl true
  def handle_async(:readiness_probe, {:ok, state}, socket) do
    {:noreply, assign(socket, readiness: state)}
  end

  def handle_async(:readiness_probe, {:exit, reason}, socket) do
    Logger.warning("claude chat: readiness probe crashed (#{inspect(reason)}) — failing open")
    {:noreply, assign(socket, readiness: :ready)}
  end

  # ── transcript row + agent drill-down (charter D46) ─────────────────────────

  # One transcript row's body — the per-role case, shared by top-level rows and
  # the nested children of an agent block. Extracted so a child renders
  # byte-identically to a top-level row; the wrapping <div> (data-role/
  # data-parent/trace gutter) stays at the call site.
  attr :message, :map, required: true
  attr :plan_expanded, :any, required: true
  attr :question_forms, :map, required: true

  defp message_body(assigns) do
    ~H"""
    <%= case @message.role do %>
      <% :user -> %>
        <%!-- Terminal anatomy: the user's prompt wears the ❯ gutter,
              left-aligned like the CLI — no chat bubble. --%>
        <div style="display: flex; flex-direction: column; gap: 6px; margin-top: 6px;">
          <div
            :if={user_images(@message) != []}
            style="display: flex; flex-wrap: wrap; gap: 6px; padding-left: 22px;"
          >
            <%= for img <- user_images(@message) do %>
              <div :if={img[:missing]} class="text-xs text-dim" style="border: 1px dashed var(--border-muted); border-radius: 10px; padding: 14px 18px;">
                attachment missing
              </div>
              <img
                :if={img[:data_uri]}
                src={img.data_uri}
                alt="attachment"
                style="max-width: 220px; max-height: 220px; border-radius: 10px; border: 1px solid var(--border-muted);"
              />
            <% end %>
          </div>
          <div :if={@message.text not in [nil, ""]} style="display: flex; gap: 8px;">
            <span
              style="color: var(--primary); font-family: var(--font-mono); font-weight: 700; flex: none;"
              aria-hidden="true"
            >
              ❯
            </span>
            <div
              class="text-sm"
              style="white-space: pre-wrap; overflow-wrap: anywhere; font-weight: 550; padding-top: 1px;"
              data-gutter-text
            >{@message.text}</div>
          </div>
          <%!-- Queue-honest badge (charter D43): a mid-turn send lands
                immediately and is dispatched right away — the binary runs
                it as the next turn. The badge is LIVE-ONLY; it clears when
                that turn's system/init fires, and replay never shows it. --%>
          <div
            :if={@message[:queued]}
            class="text-xs text-dim"
            style="font-family: var(--font-mono); padding-left: 22px;"
          >
            ⧗ queued
          </div>
        </div>
      <% :assistant -> %>
        <%!-- Terminal anatomy: assistant prose wears the ● gutter. --%>
        <div style="display: flex; gap: 8px;">
          <span
            style="color: var(--primary); font-family: var(--font-mono); flex: none; line-height: 1.6;"
            aria-hidden="true"
          >
            ●
          </span>
          <div style="flex: 1; min-width: 0;">
            <div
              :if={@message.html}
              class="bp-paper-surface bp-chat-md"
              style="overflow-wrap: anywhere; padding: 2px 0; font-size: 0.925rem;"
            >
              {Phoenix.HTML.raw(@message.html)}
            </div>
            <div
              :if={@message.html == nil}
              class="text-sm"
              style="white-space: pre-wrap; overflow-wrap: anywhere; padding: 2px 0;"
              data-gutter-text
            >{@message.text}</div>
          </div>
        </div>
      <% :tool -> %>
        <%!-- D64: an mcp__barkpark__* result (task/paper/search) classifies
              to a first-class chip. The SAME pure ChatToolRenderer.chip/2 is
              consumed here for BOTH live-append and replay rows (they thread
              identical `tool` + `output`), so the chip HTML is parity-stable
              by construction — the diff?/spawn? precedent. A host tool, an
              error string, or a truncated/oversized payload returns nil and
              keeps the generic ⎿ row below. --%>
        <% mcp_chip = ChatToolRenderer.chip(@message[:tool], @message[:output]) %>
        <%!-- A Task/agent spawn (charter D40) gets a headline row: the
              gutter glyph plus the sub-agent's description; the frames it
              emits interleave below, indented under it. A plain tool row
              keeps the terse mono line. --%>
        <%!-- Hanging indent: glyph and text are flex columns, so a
              wrapped line continues under the TEXT, never under the glyph. --%>
        <%!-- The gutter is SETTLE-GATED (ChatToolRenderer.settle_state/1): ●
              neutral while the row's turn is live, ✓ once the turn settled with
              a result, ✗ once it settled with an error — and ● forever if the
              result never arrived. Live and replay thread the identical three
              facts, so a reopened session draws the same glyph. --%>
        <div :if={@message[:spawn?]} class="text-xs" style="font-family: var(--font-mono); display: flex; gap: 6px;">
          <span
            style={"color: #{ChatToolRenderer.settle_color(@message)}; flex: none;"}
            data-tool-state={ChatToolRenderer.settle_state(@message)}
          >{ChatToolRenderer.settle_glyph(@message)}</span>
          <span style="min-width: 0; overflow-wrap: anywhere;">
            <span style="font-weight: 650;" data-gutter-text>{@message[:spawn_label] || @message.text}</span>
            <span class="text-dim" style="margin-left: 6px; opacity: 0.7;">agent</span>
          </span>
        </div>
        <div :if={!@message[:spawn?]} class="text-xs" style="font-family: var(--font-mono); display: flex; gap: 6px;">
          <span
            style={"color: #{ChatToolRenderer.settle_color(@message)}; flex: none;"}
            data-tool-state={ChatToolRenderer.settle_state(@message)}
          >{ChatToolRenderer.settle_glyph(@message)}</span>
          <span style="min-width: 0; overflow-wrap: anywhere;" data-gutter-text>{@message.text}</span>
        </div>
        <%!-- D38 + D25: a file-mutating tool call renders as a real colored
              diff (dispatch on input SHAPE, not tool name) beneath the
              ● header. Routed through the `chat-tool-diff` PortableDoc block
              (compose_block :article → Components.chat_tool_diff_html) — the
              SAME block path the assistant reply body uses (D8) and the Go TUI
              decodes — so this is ONE dual-surface renderer, not a GUI-only
              widget (Law 1). A non-diff shape yields "" and keeps the ⎿ row. --%>
        {Phoenix.HTML.raw(chat_tool_diff_html(@message[:input]))}
        <%!-- A classified MCP result renders as a chip INSTEAD of dumping the
              raw JSON blob — the store keeps the full output either way. --%>
        <ChatToolRenderer.tool_chip :if={mcp_chip} chip={mcp_chip} />
        <%!-- The terminal's ⎿ result line: first line inline; multi-
              line outputs expand on click (details/summary). Suppressed when a
              chip already stands in for the result. --%>
        <div
          :if={is_nil(mcp_chip) and @message[:output] not in [nil, ""]}
          class="text-xs text-dim"
          style="font-family: var(--font-mono); padding-left: 16px; overflow-wrap: anywhere;"
        >
          <%= if tool_output_lines(@message.output) > 1 do %>
            <details>
              <summary style="cursor: pointer; list-style: none;">
                ⎿ <%= tool_output_head(@message.output) %>
                <span style="opacity: 0.7;">… +<%= tool_output_lines(@message.output) - 1 %> lines</span>
              </summary>
              <pre style="margin: 4px 0 0; padding: 6px 8px; background: var(--muted-surface); border-radius: 6px; overflow-x: auto; font-size: 11px; line-height: 1.5; white-space: pre-wrap;" data-gutter-text><%= @message.output %></pre>
            </details>
          <% else %>
            ⎿ <%= tool_output_head(@message.output) %>
          <% end %>
        </div>
      <% :todo -> %>
        <%!-- The living checklist card (charter D39 + D25): one ☐/◐/☒ card the
              Recorder collapsed + the reducer superseded, so it renders
              the turn's LATEST todo state whether live or replayed. Routed
              through the `chat-todo` PortableDoc block (compose_block :article →
              Components.chat_todo_html) — ONE dual-surface renderer the Go TUI
              decodes too (Law 1), not a bespoke inline HEEx card. --%>
        {Phoenix.HTML.raw(chat_todo_html(@message.todos))}
      <% :approval -> %>
        <div
          :if={@message.approval_status == :pending}
          data-approval={@message.request_id}
          style="border: 1px solid var(--border-muted); border-left: 3px solid var(--primary); border-radius: 8px; padding: 10px 12px; display: flex; align-items: center; gap: 12px;"
        >
          <div style="flex: 1; min-width: 0;">
            <div class="text-sm" style="font-weight: 600;">
              Allow <%= @message.tool_name %>?
            </div>
            <div class="text-xs text-dim" style="font-family: var(--font-mono); overflow-wrap: anywhere;">
              <%= @message.text %>
            </div>
          </div>
          <button
            type="button"
            class="btn btn-primary"
            phx-click="approve"
            phx-value-rid={@message.request_id}
          >
            Allow
          </button>
          <button
            type="button"
            class="btn"
            phx-click="deny"
            phx-value-rid={@message.request_id}
          >
            Deny
          </button>
        </div>
        <div
          :if={@message.approval_status != :pending}
          class="text-xs text-dim"
          style="font-family: var(--font-mono); overflow-wrap: anywhere;"
        >
          <%= approval_outcome_label(@message.approval_status) %> — <%= @message.tool_name %>
        </div>
      <% :question -> %>
        <.question_card
          message={@message}
          form={question_form_for(@question_forms, @message.request_id)}
        />
      <% :plan -> %>
        <div
          :if={@message.approval_status == :pending}
          class="bp-chat-plan"
          data-plan={@message.request_id}
        >
          <div style="display: flex; align-items: baseline; gap: 8px; margin-bottom: 6px;">
            <span
              class="text-xs text-dim"
              style="text-transform: uppercase; letter-spacing: 0.06em; font-weight: 600;"
            >
              proposed plan
            </span>
            <span class="text-xs text-dim" style="margin-left: auto;">plan ready</span>
          </div>
          <div
            class="text-sm"
            style="font-weight: 600; margin-bottom: 8px; overflow-wrap: anywhere;"
          >
            <%= @message.title %>
          </div>
          <div class={[
            "bp-chat-plan-body",
            !MapSet.member?(@plan_expanded, @message.id) && "is-collapsed"
          ]}>
            <div
              :if={String.trim(to_string(@message.plan_markdown)) != ""}
              class="bp-paper-surface bp-chat-md"
              style="overflow-wrap: anywhere; padding: 2px 0; font-size: 0.925rem;"
            >
              {Phoenix.HTML.raw(@message.html || "")}
            </div>
            <div
              :if={String.trim(to_string(@message.plan_markdown)) == ""}
              class="text-xs text-dim"
              style="font-style: italic;"
            >
              (the plan has no text)
            </div>
          </div>
          <button
            type="button"
            class="btn text-xs"
            phx-click="plan-toggle"
            phx-value-id={@message.id}
            aria-expanded={to_string(MapSet.member?(@plan_expanded, @message.id))}
            style="margin-top: 6px; padding: 2px 9px;"
          >
            <%= if MapSet.member?(@plan_expanded, @message.id),
              do: "Show less",
              else: "Show full plan" %>
          </button>
          <div style="display: flex; gap: 8px; margin-top: 10px;">
            <button
              type="button"
              class="btn btn-primary"
              phx-click="plan-approve"
              phx-value-rid={@message.request_id}
            >
              Approve plan
            </button>
            <button
              type="button"
              class="btn"
              phx-click="plan-keep"
              phx-value-rid={@message.request_id}
            >
              Keep planning
            </button>
          </div>
        </div>
        <div
          :if={@message.approval_status != :pending}
          class="text-xs text-dim"
          style="overflow-wrap: anywhere;"
        >
          <%= plan_outcome_label(@message.approval_status) %> — <%= @message.title %>
          <a
            :if={@message[:paper_url]}
            href={@message.paper_url}
            target="_blank"
            rel="noopener"
            style="margin-left: 6px; text-decoration: none; color: var(--accent);"
          >
            → published as Paper
          </a>
        </div>
      <% :thinking -> %>
        <%!-- Settled thinking bout (charter D41 + D25): dim mono ✻, no text
              ever — only "thought for ~N tokens". A token-bearing bout routes
              through the `chat-thinking` PortableDoc block (compose_block
              :article → Components.chat_thinking_html) — ONE dual-surface
              renderer the Go TUI decodes too (Law 1). A legacy row with no
              persisted count degrades to its plain ✻ text. --%>
        <%= if is_integer(@message[:tokens]) do %>
          {Phoenix.HTML.raw(chat_thinking_html(@message[:tokens]))}
        <% else %>
          <div class="text-xs text-dim" style="font-family: var(--font-mono);">
            <span aria-hidden="true">✻</span> <%= @message.text %>
          </div>
        <% end %>
      <% :task_transition -> %>
        <%!-- A live ledger transition (tlv): one quiet mono row, tinted with the
              row's `--life-*` lifecycle token so a chip and a transition agree on
              what "done" or "blocked" looks like. Live-only chrome — never
              persisted, so a replay of this conversation carries the settled
              task_prime snapshot instead, unchanged. --%>
        <div
          class="text-xs text-dim"
          style="font-family: var(--font-mono); display: flex; gap: 6px; align-items: baseline;"
          data-task-transition={@message[:task_id]}
          data-task-status={@message[:task_status]}
          data-event-key={@message[:event_key]}
        >
          <span style={"color: #{@message[:task_color]}; flex: none;"} aria-hidden="true">◆</span>
          <span style="min-width: 0; overflow-wrap: anywhere;"><%= @message.text %></span>
        </div>
      <% _ -> %>
        <div class="text-xs text-dim" style="font-family: var(--font-mono);">
          <span aria-hidden="true">✻</span> <%= @message.text %>
        </div>
    <% end %>
    """
  end

  # SHOW-ACTIVE-ONLY, the RUNNING turn's control (task-b66928b2958c8cfa): one
  # "+N previous" row standing in for the tool rows that ran BEFORE the active
  # one, so the row the reader is actually watching stays on screen no matter
  # how long the turn gets. Clicking expands every row of the turn; clicking
  # again re-collapses. The count and the label come from the ONE counter and
  # the ONE formatter (`ChatToolRenderer.running_hidden_count/1` +
  # `running_fold_label/1`), the same strings `bp chat` prints.
  #
  # A SETTLED turn never reaches here — `fold_running_turn/1`'s gate hands it to
  # U1's `turn_fold` instead.
  attr :label, :string, required: true
  attr :hidden_rows, :list, required: true
  attr :rows, :list, required: true
  attr :expanded, :boolean, required: true
  attr :plan_expanded, :any, required: true
  attr :question_forms, :map, required: true

  defp running_fold(assigns) do
    ~H"""
    <div data-role="running-fold" style="font-family: var(--font-mono);">
      <button
        type="button"
        class="text-xs text-dim"
        phx-click="toggle_running_fold"
        data-running-fold-toggle
        aria-expanded={to_string(@expanded)}
        style="display: flex; align-items: baseline; gap: 6px; width: 100%; text-align: left; background: none; border: none; padding: 0; cursor: pointer; color: inherit; font: inherit;"
      >
        <span aria-hidden="true" style="flex: none; color: var(--life-in_progress);">
          <%= if @expanded, do: "▾", else: "▸" %>
        </span>
        <span data-running-fold-label style="font-weight: 650;"><%= @label %></span>
      </button>

      <%!-- The earlier rows, shown only when the reader asks for them. They are
            rendered by the SAME body every flat row uses — folding is a
            wrapper, never a second rendering of a row. --%>
      <div :if={@expanded}>
        <div
          :for={message <- @hidden_rows}
          data-role={message.role}
          data-parent={message[:parent_tool_use_id]}
          style={message[:parent_tool_use_id] && trace_child_style()}
        >
          <.message_body
            message={message}
            plan_expanded={@plan_expanded}
            question_forms={@question_forms}
          />
        </div>
      </div>

      <%!-- The ACTIVE row (and any pending siblings after it) always paints —
            that is the whole point of the fold. --%>
      <div
        :for={message <- @rows}
        data-role={message.role}
        data-parent={message[:parent_tool_use_id]}
        style={message[:parent_tool_use_id] && trace_child_style()}
      >
        <.message_body
          message={message}
          plan_expanded={@plan_expanded}
          question_forms={@question_forms}
        />
      </div>
    </div>
    """
  end

  # ONE settled turn, folded (task-8f904a88b9bc3d59): a single header row reading
  # "Worked for 3m 12s" — or "You stopped after 42s" when a Stop ended the turn —
  # standing in for the turn's tool rows, which expand on click. The label is
  # SERVER-stamped and formatted by the one shared formatter
  # (`ChatToolRenderer.fold_label/1`), the same string `bp chat` prints.
  #
  # The whole header is the button: a fold is one affordance, and a reader
  # reaching for "Worked for 3m 12s" should not have to find a separate chevron.
  attr :fold_key, :string, required: true
  attr :label, :string, required: true
  attr :rows, :list, required: true
  attr :expanded, :boolean, required: true
  attr :plan_expanded, :any, required: true
  attr :question_forms, :map, required: true

  defp turn_fold(assigns) do
    ~H"""
    <div data-role="turn-fold" data-turn-fold={@fold_key} style="font-family: var(--font-mono);">
      <button
        type="button"
        class="text-xs text-dim"
        phx-click="toggle_turn_fold"
        phx-value-key={@fold_key}
        data-turn-fold-toggle={@fold_key}
        aria-expanded={to_string(@expanded)}
        style="display: flex; align-items: baseline; gap: 6px; width: 100%; text-align: left; background: none; border: none; padding: 0; cursor: pointer; color: inherit; font: inherit;"
      >
        <span aria-hidden="true" style="flex: none; color: var(--life-done);">
          <%= if @expanded, do: "▾", else: "▸" %>
        </span>
        <span data-turn-fold-label style="font-weight: 650;"><%= @label %></span>
        <span style="opacity: 0.7;">
          · <%= length(@rows) %> <%= if length(@rows) == 1, do: "step", else: "steps" %>
        </span>
      </button>

      <%!-- The turn's rows, byte-identical to the flat transcript they came
            from — folding is a wrapper, never a second rendering of a row. --%>
      <div :if={@expanded}>
        <div
          :for={message <- @rows}
          data-role={message.role}
          data-parent={message[:parent_tool_use_id]}
          style={message[:parent_tool_use_id] && trace_child_style()}
        >
          <.message_body
            message={message}
            plan_expanded={@plan_expanded}
            question_forms={@question_forms}
          />
        </div>
      </div>
    </div>
    """
  end

  # An agent drill-down block (charter D46): the ● Agent(type — description)
  # header, a breathing "Running: …" line + step count while the sub-agent runs,
  # the child tool trace nested inside when expanded, and the agent's ⎿ report
  # (the parent tool_result) once it finishes. Expand state is per-tab.
  attr :agent, :map, required: true
  attr :kids, :list, required: true
  attr :expanded, :boolean, required: true
  attr :plan_expanded, :any, required: true
  attr :question_forms, :map, required: true

  defp agent_block(assigns) do
    ~H"""
    <div data-role="agent" data-agent={@agent[:tool_use_id]} style="font-family: var(--font-mono);">
      <div class="text-xs" style="display: flex; gap: 6px; align-items: baseline;">
        <span style="color: var(--primary); flex: none;">●</span>
        <span style="min-width: 0; overflow-wrap: anywhere; flex: 1;">
          <span style="font-weight: 650;">Agent(<%= agent_headline(@agent) %>)</span>
          <span :if={@kids != []} class="text-dim" style="margin-left: 6px; opacity: 0.7;">
            · <%= length(@kids) %> <%= if length(@kids) == 1, do: "step", else: "steps" %>
          </span>
        </span>
        <button
          :if={@kids != []}
          type="button"
          class="btn text-xs"
          phx-click="agent-toggle"
          phx-value-id={@agent[:tool_use_id]}
          aria-expanded={to_string(@expanded)}
          style="flex: none; padding: 1px 8px; opacity: 0.8;"
        >
          <%= if @expanded, do: "collapse", else: "expand" %>
        </button>
      </div>

      <%!-- Live progress while the sub-agent runs (charter D46): the latest
            "Running: …" line breathes in the primary tone. It only shows while
            task_status is "running"; a terminal agent shows no spinner. --%>
      <div
        :if={agent_running?(@agent)}
        class="text-xs bp-chat-agent-run"
        data-agent-running={@agent[:tool_use_id]}
        style="font-family: var(--font-mono); color: var(--primary); padding-left: 16px; overflow-wrap: anywhere;"
      >
        Running: <%= @agent[:task_progress] || "…" %>
      </div>

      <%!-- The nested child trace, one level (charter D46): each child renders
            byte-identically to a top-level row, indented under the spawn with
            the connecting evergreen gutter. --%>
      <div :if={@expanded and @kids != []}>
        <div
          :for={kid <- @kids}
          data-role={kid.role}
          data-parent={kid[:parent_tool_use_id]}
          style={trace_child_style()}
        >
          <.message_body message={kid} plan_expanded={@plan_expanded} question_forms={@question_forms} />
        </div>
      </div>

      <%!-- The agent's ⎿ report — the parent tool_result (subagent summary +
            usage) attached to the spawn row by the existing machinery. This is
            what a completed block collapses TO. --%>
      <div
        :if={@agent[:output] not in [nil, ""]}
        class="text-xs text-dim"
        style="font-family: var(--font-mono); padding-left: 16px; overflow-wrap: anywhere;"
      >
        <%= if tool_output_lines(@agent.output) > 1 do %>
          <details>
            <summary style="cursor: pointer; list-style: none;">
              ⎿ <%= tool_output_head(@agent.output) %>
              <span style="opacity: 0.7;">… +<%= tool_output_lines(@agent.output) - 1 %> lines</span>
            </summary>
            <pre style="margin: 4px 0 0; padding: 6px 8px; background: var(--muted-surface); border-radius: 6px; overflow-x: auto; font-size: 11px; line-height: 1.5; white-space: pre-wrap;" data-gutter-text><%= @agent.output %></pre>
          </details>
        <% else %>
          ⎿ <%= tool_output_head(@agent.output) %>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="flex: 1; display: flex; flex-direction: row; min-height: 0; background: var(--bg);">
      <style>
        @keyframes bp-skel-pulse { 0%, 100% { opacity: 0.22; } 50% { opacity: 0.55; } }
        /* The sidebar's live pulse (wave 5): a busy session breathes — same
           keyframes, stronger floor so the dot stays legible at 6px. */
        .bp-chat-live-dot { animation: bp-skel-pulse 1.2s ease-in-out infinite; opacity: 0.9; }
        /* Terminal-style turn spinner: a small evergreen arc. */
        @keyframes bp-chat-spin { to { transform: rotate(360deg); } }
        .bp-chat-spinner {
          display: inline-block; width: 11px; height: 11px; border-radius: 50%;
          border: 2px solid hsl(var(--primary-hsl) / 0.25);
          border-top-color: var(--primary);
          animation: bp-chat-spin 0.8s linear infinite;
        }
        /* Claude-TUI-style shimmer: an evergreen highlight sweeps through the
           spinner word. Gradient-clipped text needs explicit colors, so the
           base tone is the primary dimmed — it reads in both themes. Browsers
           without background-clip:text paint the base gradient behind the
           (transparent) text, so keep this on the SHORT word span only. */
        @keyframes bp-chat-shimmer {
          0% { background-position: 200% 0; }
          100% { background-position: -200% 0; }
        }
        .bp-chat-spin-word {
          background: linear-gradient(90deg,
            hsl(var(--primary-hsl) / 0.45) 35%,
            hsl(var(--primary-hsl) / 1) 50%,
            hsl(var(--primary-hsl) / 0.45) 65%) 0 0 / 200% 100%;
          -webkit-background-clip: text;
          background-clip: text;
          color: transparent;
          animation: bp-chat-shimmer 2.4s linear infinite;
        }
        /* Chat bubbles borrow the paper TYPOGRAPHY from .bp-paper-surface —
           NOT the page. The reader class also carries page-scale layout:
           min-height:100% (inside the transcript this stretched the streaming
           block viewport-tall, shoving the forming-component skeleton to the
           bottom of the screen), a 720px centered measure, and 56px page
           padding. Neutralize the page, keep the type. */
        .bp-paper-surface.bp-chat-md {
          min-height: 0;
          max-width: none;
          margin: 0;
          padding: 2px 0;
          background: transparent;
        }
        /* The paper engine gives paragraphs/headings a top margin — inside a
           gutter row that pushes the FIRST line a full line below the ● glyph.
           The bubble's first block starts flush so glyph and text align. */
        .bp-paper-surface.bp-chat-md > :first-child {
          margin-top: 0;
        }
        /* Primary (evergreen) fill, NOT --border-muted: the dark theme's border
           tone is an 11%-lightness gray on a dark bg — the shapes rendered
           invisible. Primary reads in both schemes; the pulse keeps it a ghost. */
        .bp-chat-skel .bp-skel-shape {
          background: var(--primary);
          border-radius: 4px;
          animation: bp-skel-pulse 1.2s ease-in-out infinite;
        }
        .bp-chat-skel .bp-skel-dot {
          width: 7px; height: 7px; border-radius: 50%;
          background: var(--primary);
          animation: bp-skel-pulse 1.2s ease-in-out infinite;
        }
        /* Needs-you strip rows (wave 12): compact inbox lines above the session
           list — badge + title + age, quiet until hovered. */
        .bp-chat-strip-row {
          display: flex; align-items: center; gap: 6px;
          padding: 3px 6px; border-radius: 6px; text-decoration: none;
          min-width: 0;
        }
        .bp-chat-strip-row:hover { background: hsl(var(--primary-hsl) / 0.08); }
        .bp-chat-session-row { position: relative; border-radius: 8px; }
        /* !important beats the inline `background` the active/inactive row style
           sets, so an inactive row still lights on hover. */
        .bp-chat-session-row:hover { background: hsl(var(--primary-hsl) / 0.08) !important; }
        .bp-chat-session-link { display: block; text-decoration: none; }
        /* Kebab: a quiet affordance — revealed on row hover, keyboard focus, or
           while its own menu is open, so a resting sidebar stays calm. */
        .bp-chat-kebab {
          position: absolute; top: 6px; right: 6px;
          width: 22px; height: 22px; line-height: 1; font-size: 15px;
          display: inline-flex; align-items: center; justify-content: center;
          background: transparent; border: none; border-radius: 6px; cursor: pointer;
          opacity: 0; transition: opacity 0.12s ease;
        }
        .bp-chat-session-row:hover .bp-chat-kebab,
        .bp-chat-kebab:focus,
        .bp-chat-kebab[aria-expanded="true"] { opacity: 1; }
        .bp-chat-kebab:hover { background: hsl(var(--primary-hsl) / 0.14); }
        .bp-chat-menu {
          position: absolute; top: 30px; right: 6px; z-index: 20;
          min-width: 132px; padding: 4px;
          display: flex; flex-direction: column; gap: 1px;
          background: var(--bg); border: 1px solid var(--border-muted);
          border-radius: 8px; box-shadow: 0 6px 20px rgba(0, 0, 0, 0.18);
        }
        .bp-chat-menuitem {
          text-align: left; padding: 6px 9px; font-size: 0.8125rem;
          background: transparent; color: var(--text); border: none;
          border-radius: 5px; cursor: pointer;
        }
        .bp-chat-menuitem:hover { background: hsl(var(--primary-hsl) / 0.12); }
        .bp-chat-menuitem-danger { color: var(--danger); }
        .bp-chat-menuitem-danger:hover { background: hsl(var(--danger-hsl) / 0.12); }
        .bp-chat-rename-input {
          width: 100%; box-sizing: border-box; font: inherit;
          background: var(--bg); color: var(--text);
          border: 1px solid var(--primary); border-radius: 6px; padding: 6px 8px;
        }
        /* Proposed-plan card (charter D34): evergreen-accented, the full plan
           rendered through the paper engine, clamped to ~8 lines until expanded.
           The collapsed body fades into the page background via a token gradient
           — NEVER pre-truncate the markdown (an unbalanced fence would degrade
           the whole doc), only the RENDERED height. */
        .bp-chat-plan {
          border: 1px solid var(--border-muted);
          border-left: 3px solid var(--primary);
          border-radius: 8px; padding: 12px 14px;
        }
        .bp-chat-plan-body { position: relative; overflow: hidden; }
        .bp-chat-plan-body.is-collapsed { max-height: 12.5em; }
        .bp-chat-plan-body.is-collapsed::after {
          content: ""; position: absolute; left: 0; right: 0; bottom: 0;
          height: 3.5em; pointer-events: none;
          background: linear-gradient(to bottom, transparent, var(--bg));
        }
        /* Agent drill-down (charter D46): a running sub-agent's live line breathes
           in the primary tone, reusing the skeleton pulse keyframes — a live
           signal that collapses to a still report on completion. */
        .bp-chat-agent-run { animation: bp-skel-pulse 1.4s ease-in-out infinite; }
        /* Rail per-entry auto-dismiss (charter D47): when a settled entry ages
           out ~90s after it terminates, its row fades opacity and collapses its
           height before the server diff drops it (phx-remove drives these three
           classes). Best-effort chrome — no color literal, so studio-literal
           stays green; if the transition is skipped the node still removes. */
        .bp-chat-rail-leave {
          transition: opacity 0.32s ease, max-height 0.32s ease, margin 0.32s ease;
          overflow: hidden;
        }
        .bp-chat-rail-leave-start { opacity: 1; max-height: 200px; }
        .bp-chat-rail-leave-end { opacity: 0; max-height: 0; margin: 0; }
        /* The session palette's highlighted row. The ChatPalette hook stamps
           data-palette-active as the arrows move; the token keeps the gate
           green (no color literal). */
        #chat-palette-list li[data-palette-active] { background: var(--primary-soft); }
      </style>
      <%!-- The keyboard surface (T3 keybindings parity). An empty, hidden
            element whose only job is to host the ChatKeys hook
            (bp-chat-palette.js): it arms ONE document-level keydown listener
            that turns Cmd/Ctrl+1..9 into `chat-jump` and Cmd/Ctrl+K into
            `chat-palette-open`, and ignores every key typed inside an input,
            textarea or contenteditable so the composer, the slash combobox and
            the inline rename field keep their own keys. Escape is untouched —
            it still belongs to the global interrupt (charter D42). --%>
      <div id="chat-keys" phx-hook="ChatKeys" hidden></div>

      <%!-- The Cmd/Ctrl+K session palette. The LIST is server-rendered from
            `@sessions` — the same tenant-clamped, archived-shelf-aware list the
            sidebar shows, so the palette can never offer a session the sidebar
            hides. The FILTERING is client-side (subsequence fuzzy over the
            stamped titles): a palette that round-trips per keystroke is not a
            palette, and a server-side filter would need a second copy of the
            visible-set rule. Enter pushes `chat-palette-activate`, which lands
            on `session_link_path/2` — the sidebar click's own path. --%>
      <div
        :if={@palette_open}
        id="chat-palette"
        phx-hook="ChatPalette"
        data-test-id="chat-palette"
        role="dialog"
        aria-modal="true"
        aria-label="Jump to a chat"
        style="position: fixed; inset: 0; z-index: 60; display: flex; align-items: flex-start; justify-content: center; padding: 12vh 16px 16px; background: rgba(0, 0, 0, 0.38);"
      >
        <%!-- click-away sits on the CARD, never the full-screen overlay:
              nothing is ever outside a full-screen element, so a backdrop click
              would never fire there. --%>
        <div
          id="chat-palette-card"
          phx-click-away="chat-palette-close"
          style="width: min(560px, 94vw); max-height: 64vh; display: flex; flex-direction: column; background: var(--bg-popover); border: 1px solid var(--border); border-radius: 10px; box-shadow: var(--shadow-lg); overflow: hidden;"
        >
          <input
            id="chat-palette-input"
            type="text"
            autocomplete="off"
            role="combobox"
            aria-expanded="true"
            aria-controls="chat-palette-list"
            aria-label="Filter chats by title"
            placeholder="Jump to a chat…"
            data-test-id="chat-palette-input"
            style="flex: none; width: 100%; box-sizing: border-box; padding: 12px 14px; border: none; border-bottom: 1px solid var(--border-muted); background: transparent; color: var(--text); font-size: 14px; outline: none;"
          />

          <ul
            id="chat-palette-list"
            role="listbox"
            aria-label="Chats"
            style="flex: 1; min-height: 0; overflow-y: auto; list-style: none; margin: 0; padding: 6px;"
          >
            <li
              :for={{s, i} <- Enum.with_index(@sessions)}
              id={"chat-palette-opt-#{i}"}
              role="option"
              aria-selected={to_string(i == 0)}
              data-palette-row
              data-palette-id={s.id}
              data-palette-title={s.title}
              data-test-id={"chat-palette-row-#{s.id}"}
              style="display: flex; align-items: baseline; gap: 8px; padding: 7px 9px; border-radius: 6px;"
            >
              <span
                :if={i < 9}
                class="text-xs text-dim"
                style="flex: none; font-family: var(--font-mono);"
              >
                <%= i + 1 %>
              </span>
              <span
                class="text-sm"
                style="color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0;"
              >
                <%= s.title %>
              </span>
              <span class="text-xs text-dim" style="margin-left: auto; flex: none;">
                <%= session_stamp(s) %>
              </span>
            </li>
          </ul>

          <div
            class="text-xs text-dim"
            style="flex: none; padding: 7px 12px; border-top: 1px solid var(--border-muted);"
          >
            ↑↓ move · Enter open · Esc close · ⌘/Ctrl+1–9 jump
          </div>
        </div>
      </div>

      <aside style="width: 280px; flex: none; border-right: 1px solid var(--border-muted); display: flex; flex-direction: column; min-height: 0;">
        <div style="display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--border-muted); flex: none;">
          <span class="h3" style="display: flex; align-items: center; gap: 8px; flex: 1;">
            <.icon name="message-circle" size={15} /> chats
          </span>
          <.link
            patch={ReturnTo.with_return_to(@chat_base_path, @return_to)}
            class="btn btn-primary text-xs"
            style="display: inline-flex; align-items: center; gap: 4px; padding: 3px 9px;"
          >
            <.icon name="plus" size={13} /> New
          </.link>
        </div>

        <%!-- The needs-you strip (wave 12): a cross-session inbox — pending asks,
              running turns, and finished-while-away sessions, priority-ordered
              (approve > answer > plan ready > running > done). Derived from
              persisted rows (cold-mount correct) + the live activity overlay;
              the ON-SCREEN session is never "away". Visiting a session clears
              it. Hidden on the archived shelf — the strip is about live work. --%>
        <% strip = strip_entries(assigns) %>
        <div
          :if={not @show_archived and @sessions != []}
          style="flex: none; border-bottom: 1px solid var(--border-muted); padding: 6px;"
          data-test-id="chat-strip"
        >
          <div
            class="text-dim"
            style="padding: 2px 4px 4px; font-size: 10px; text-transform: uppercase; letter-spacing: 0.06em;"
          >
            Inbox
          </div>
          <div
            :if={strip == []}
            class="text-xs text-dim"
            style="padding: 0 4px 4px;"
            data-test-id="chat-strip-empty"
          >
            All quiet — nothing waiting on you.
          </div>
          <.link
            :for={e <- strip}
            patch={ReturnTo.with_return_to("#{@chat_base_path}/#{e.session.id}", @return_to)}
            class="bp-chat-strip-row"
            data-test-id={"chat-strip-#{e.session.id}"}
          >
            <span
              class={"badge #{strip_badge(e.kind)}"}
              style="height: 16px; padding: 0 6px; font-size: 9px; flex: none; display: inline-flex; align-items: center;"
            >
              <%= strip_label(e.kind) %>
            </span>
            <span
              class="text-xs"
              style="color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0;"
            >
              <%= e.session.title %>
            </span>
            <span class="text-xs text-dim" style="margin-left: auto; flex: none;">
              <%= session_stamp(e.session) %>
            </span>
          </.link>
        </div>

        <div style="flex: 1; min-height: 0; overflow-y: auto; padding: 6px;">
          <div
            :if={@sessions == [] and @show_archived}
            class="text-xs text-dim"
            style="padding: 14px 10px; line-height: 1.55;"
            data-test-id="chat-archived-empty"
          >
            <div class="text-sm" style="font-weight: 600; color: var(--text); margin-bottom: 6px;">
              No archived chats
            </div>
            <p style="margin: 0;">
              Archived chats rest here. Archive one from its <span aria-hidden="true">⋯</span>
              menu to tuck it away without deleting it — it stays fully resumable.
            </p>
          </div>

          <div
            :if={@sessions == [] and not @show_archived}
            class="text-xs text-dim"
            style="padding: 14px 10px; line-height: 1.55;"
            data-test-id="chat-empty"
          >
            <div class="text-sm" style="font-weight: 600; color: var(--text); margin-bottom: 6px;">
              No chats yet
            </div>
            <p style="margin: 0 0 8px;">
              This is your remembered agent workspace. Provider and execution location
              are stored with every conversation — reopen one to pick up exactly where
              you left off. Admins only.
            </p>
            <p style="margin: 0;">
              Try: <em>“Walk the studio LiveViews and sketch how a request flows.”</em>
            </p>
          </div>

          <nav :if={@sessions != []} style="display: flex; flex-direction: column; gap: 2px;">
            <% active_id = @session_id %>
            <div
              :for={s <- @sessions}
              class="bp-chat-session-row"
              style={session_row_style(s.id == active_id)}
              data-test-id="chat-session-row"
            >
              <%= if @renaming_session == s.id do %>
                <%!-- Inline rename (sheet-tab triad) — blur COMMITS (divergence);
                      Enter submits, Escape cancels. The commit path accepts both
                      the form's `title` and blur's `value`. --%>
                <form phx-submit="session-rename" phx-value-id={s.id} style="display: block;">
                  <input
                    name="title"
                    type="text"
                    value={s.title}
                    class="bp-chat-rename-input"
                    autocomplete="off"
                    autofocus
                    aria-label={"Rename #{s.title}"}
                    phx-blur="session-rename"
                    phx-value-id={s.id}
                    phx-keydown="session-rename-cancel"
                    phx-key="Escape"
                    data-chat-rename
                    data-test-id={"chat-session-rename-input-#{s.id}"}
                  />
                </form>
              <% else %>
                <.link patch={session_link_path(assigns, s.id)} class="bp-chat-session-link">
                  <% act = @activity[s.id] %>
                  <% {pill_class, pill_text} = session_pill(s, act) %>
                  <div style="display: flex; align-items: center; gap: 6px; padding-right: 22px;">
                    <span class={"badge #{pill_class}"} style="height: 18px; padding: 0 7px; font-size: 10px; display: inline-flex; align-items: center; gap: 4px;">
                      <span
                        :if={act && act.state == :working}
                        class="bp-chat-live-dot"
                        style="width: 6px; height: 6px; border-radius: 50%; background: currentColor;"
                      >
                      </span>
                      <%= pill_text %>
                    </span>
                    <span class="text-xs text-dim" style="margin-left: auto;">
                      <%= session_stamp(s) %>
                    </span>
                  </div>
                  <div
                    class="text-sm"
                    style="font-weight: 600; color: var(--text); margin-top: 3px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
                  >
                    <%= s.title %>
                  </div>
                  <%!-- While the agent works, the card shows WHAT it is doing
                        right now (the live tool line from the Recorder) in the
                        evergreen; at rest it shows the stored summary. --%>
                  <div
                    :if={act && act.line}
                    class="text-xs"
                    style="margin-top: 1px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--primary); font-family: var(--font-mono);"
                    data-test-id={"chat-activity-#{s.id}"}
                  >
                    ▸ <%= act.line %>
                  </div>
                  <div
                    :if={s.summary && !(act && act.line)}
                    class="text-xs text-dim"
                    style="margin-top: 1px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
                  >
                    <%= s.summary %>
                  </div>
                  <%!-- Wave-session-card (wsc charter D8-D11): two lines that
                        exist ONLY while the session's rail carries a workflow —
                        a plain chat's row renders byte-identically to before.
                        Live truth is the {:chat_workflow} overlay (D4); cold
                        truth is the compact summary folded from rail_snapshot
                        at refresh_sessions (D7). --%>
                  <% ws = @workflow[s.id] || @workflow_summaries[s.id] %>
                  <div
                    :if={ws}
                    class="text-xs"
                    style="margin-top: 3px; display: flex; align-items: center; gap: 6px; min-width: 0;"
                    data-test-id={"chat-workflow-#{s.id}"}
                  >
                    <span
                      :if={ws.ticks != []}
                      aria-hidden="true"
                      style="display: inline-flex; gap: 3px; flex: none;"
                    >
                      <span
                        :for={tick <- ws.ticks}
                        class={workflow_tick_class(tick)}
                        style={workflow_tick_style(tick)}
                      >
                      </span>
                    </span>
                    <span
                      style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text);"
                      data-test-id={"chat-workflow-line-#{s.id}"}
                    >
                      <%= workflow_card_line(ws) %>
                    </span>
                  </div>
                  <% eg = ws && @epic_goals[s.id] %>
                  <div
                    :if={eg}
                    class="text-xs text-dim"
                    style="margin-top: 1px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
                    data-test-id={"chat-epic-#{s.id}"}
                  >
                    ↳ <%= eg.title %> · <%= eg.slices_done %>/<%= eg.slices_total %> slices<%= if eg.wave_status, do: " · #{eg.wave_status}" %>
                  </div>
                </.link>

                <button
                  type="button"
                  class="bp-chat-kebab text-dim"
                  phx-click="session-menu-toggle"
                  phx-value-id={s.id}
                  aria-haspopup="menu"
                  aria-expanded={to_string(@open_menu_session == s.id)}
                  aria-label={"Actions for #{s.title}"}
                  data-test-id={"chat-session-menu-#{s.id}"}
                >
                  ⋯
                </button>

                <div
                  :if={@open_menu_session == s.id}
                  class="bp-chat-menu"
                  role="menu"
                  aria-label={"Actions for #{s.title}"}
                  phx-click-away="session-menu-close"
                  data-test-id={"chat-session-menu-list-#{s.id}"}
                >
                  <button
                    type="button"
                    role="menuitem"
                    class="bp-chat-menuitem"
                    phx-click="session-rename-start"
                    phx-value-id={s.id}
                    data-test-id={"chat-session-rename-#{s.id}"}
                  >
                    Rename
                  </button>
                  <button
                    :if={@show_archived}
                    type="button"
                    role="menuitem"
                    class="bp-chat-menuitem"
                    phx-click="session-unarchive"
                    phx-value-id={s.id}
                    data-test-id={"chat-session-unarchive-#{s.id}"}
                  >
                    Unarchive
                  </button>
                  <button
                    :if={not @show_archived}
                    type="button"
                    role="menuitem"
                    class="bp-chat-menuitem"
                    phx-click="session-archive"
                    phx-value-id={s.id}
                    data-test-id={"chat-session-archive-#{s.id}"}
                  >
                    Archive
                  </button>
                  <button
                    type="button"
                    role="menuitem"
                    class="bp-chat-menuitem bp-chat-menuitem-danger"
                    phx-click="session-delete"
                    phx-value-id={s.id}
                    data-test-id={"chat-session-delete-#{s.id}"}
                  >
                    Delete
                  </button>
                </div>
              <% end %>
            </div>
          </nav>
        </div>

        <div style="flex: none; border-top: 1px solid var(--border-muted); padding: 6px 10px;">
          <button
            type="button"
            class="text-xs text-dim"
            phx-click="toggle-archived"
            aria-pressed={to_string(@show_archived)}
            data-test-id="chat-archived-toggle"
            style="display: inline-flex; align-items: center; gap: 5px; background: transparent; border: none; cursor: pointer; padding: 4px 6px;"
          >
            <.icon name={if @show_archived, do: "arrow-left", else: "archive"} size={12} />
            <%= if @show_archived, do: "Back to active chats", else: "Show archived" %>
          </button>
        </div>
      </aside>

      <div style="flex: 1; display: flex; flex-direction: column; min-height: 0;">
      <%!-- Slim header (charter D44): title only. The mode select, model picker +
            observed-model fact, context ring, and Send/Stop all moved into the
            composer footer cockpit below — where you type. The header's visible
            status label is gone (leftover clutter next to the cockpit's own
            affordances), but the machine-readable truth survives as
            data-chat-status: the session's status atom, stamped on the header so
            tests (and tooling) can assert lifecycle transitions — new/ready/
            working/interrupting/offline — without coupling to visible copy. --%>
      <div
        data-chat-status={@status}
        style="display: flex; align-items: center; gap: 10px; padding: 8px 16px; border-bottom: 1px solid var(--border-muted); flex: none;"
      >
        <span class="h3" style="display: flex; align-items: center; gap: 8px;">
          <.icon name="message-circle" size={16} /> chat
        </span>
      </div>

      <%!-- The context identity band (chat-local-cloud-context-w3, criterion 2;
            the CLI half is internal/chat/context.go). WHICH execution host runs
            this session, on WHICH Barkpark server, in WHICH workspace / project
            / dataset, out of WHICH repository root. Every segment is a
            PROJECTION of server truth — the session row, its live execution
            lease and the host that last reported on it — never a config string.
            A field whose two truths disagree leads with ⚠ and carries both
            values; absence is typed ((not set) / (unknown) / (not a git repo) /
            (server-local)) and never renders blank or as a plausible default. --%>
      <div
        :if={@context_identity}
        data-test-id="chat-context-band"
        class="text-xs text-dim"
        style="display: flex; flex-wrap: wrap; gap: 2px 12px; padding: 5px 16px; border-bottom: 1px solid var(--border-muted); flex: none;"
      >
        <span
          :for={f <- @context_identity.fields}
          data-test-id={"chat-context-#{f.name}"}
          data-mismatch={to_string(f.mismatch?)}
          style={f.mismatch? && "color: var(--warn);"}
        >
          <%= if f.mismatch?, do: "⚠ " %><%= f.name %> <%= ContextIdentity.Field.display(f) %>
        </span>
      </div>

      <div
        id="chat-transcript"
        style="flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column-reverse; padding: 16px;"
      >
        <div style="display: flex; flex-direction: column; gap: 10px; max-width: 860px; width: 100%; margin: 0 auto;">
          <p :if={@messages == [] and @streaming == nil} class="text-sm text-dim">
            An agent chat backed by <code><%= @provider %></code> on the selected execution
            location. Plan mode can read approved files, but cannot edit or execute anything.
          </p>

          <div
            id="chat-messages"
            phx-hook="PaperMermaid"
            style="display: flex; flex-direction: column; gap: 10px;"
          >
            <%!-- Charter D46: bucket child rows under their top-level spawn as an
                  expandable agent block; every other row (and orphan children)
                  stays a flat top-level row in seq order. A nested :for over the
                  grouped list diffs cleanly and leaves #chat-messages + the
                  PaperMermaid hook untouched. --%>
            <%= for item <- @grouped_rows do %>
              <%= case item do %>
                <% {:row, message} -> %>
                  <div
                    data-role={message.role}
                    data-parent={message[:parent_tool_use_id]}
                    style={message[:parent_tool_use_id] && trace_child_style()}
                  >
                    <.message_body
                      message={message}
                      plan_expanded={@plan_expanded}
                      question_forms={@question_forms}
                    />
                  </div>
                <% {:running_fold, _n, label, hidden_rows, rows} -> %>
                  <.running_fold
                    label={label}
                    hidden_rows={hidden_rows}
                    rows={rows}
                    expanded={@running_fold_expanded}
                    plan_expanded={@plan_expanded}
                    question_forms={@question_forms}
                  />
                <% {:turn_fold, fold_key, label, rows} -> %>
                  <.turn_fold
                    fold_key={fold_key}
                    label={label}
                    rows={rows}
                    expanded={turn_fold_open?(@turn_folds_expanded, fold_key)}
                    plan_expanded={@plan_expanded}
                    question_forms={@question_forms}
                  />
                <% {:agent, agent, kids} -> %>
                  <.agent_block
                    agent={agent}
                    kids={kids}
                    expanded={agent_open?(@agent_expanded, agent)}
                    plan_expanded={@plan_expanded}
                    question_forms={@question_forms}
                  />
              <% end %>
            <% end %>
          </div>

          <%!-- The LIVE thinking pulse (charter D41): a ✻ counter that breathes
                while the model thinks, before any prose streams. It settles into a
                durable :thinking message (above) the moment real output begins. --%>
          <div
            :if={@thinking_pulse}
            class="text-xs text-dim"
            style="font-family: var(--font-mono); display: flex; align-items: center; gap: 8px;"
          >
            <span class="bp-chat-spinner" aria-hidden="true"></span>
            <span :if={@thinking_pulse.text in [nil, ""]}>
              <span
                id="chat-pulse-word"
                class="bp-chat-spin-word"
                phx-hook="ChatSpinWord"
                phx-update="ignore"
                data-words={spinner_words_json()}
                data-rotate-ms={spinner_rotate_ms()}
              ><%= @thinking_pulse.word %>…</span> ~<%= @thinking_pulse.tokens %> tokens
            </span>
            <span :if={@thinking_pulse.text not in [nil, ""]} style="white-space: pre-wrap;" data-gutter-text>{@thinking_pulse.text}</span>
          </div>

          <div :if={@streaming} style="opacity: 0.92;">
            <div
              :if={@streaming.stable_html}
              class="bp-paper-surface bp-chat-md"
              style="overflow-wrap: anywhere; padding: 2px 0; font-size: 0.925rem;"
            >
              {Phoenix.HTML.raw(@streaming.stable_html)}
            </div>
            <%!-- Display cap breached (charter D131): the live preview froze at the
                  last stable block; the still-forming tail is dropped and an honest
                  marker stands in. The full response arrives untruncated on completion. --%>
            <div
              :if={@streaming[:capped]}
              class="text-xs text-dim"
              style="padding: 4px 0; font-style: italic;"
              data-streaming-capped
            >
              live preview truncated — the full response arrives on completion
            </div>
            <%= if !@streaming[:capped] do %>
              <%= case StreamTail.classify(@streaming) do %>
                <% {:text, tail} -> %>
                  <div class="text-sm" style="white-space: pre-wrap; overflow-wrap: anywhere; padding: 2px 0;" data-gutter-text>{tail}<span class="text-dim">▌</span></div>
                <% {:component, kind, prose} -> %>
                  <div
                    :if={String.trim(prose) != ""}
                    class="text-sm"
                    style="white-space: pre-wrap; overflow-wrap: anywhere; padding: 2px 0;"
                    data-gutter-text
                  >{prose}</div>
                  <.skeleton kind={kind} />
              <% end %>
            <% end %>
          </div>

          <div
            :if={@streaming == nil and @thinking_pulse == nil and turn_active?(@status)}
            class="text-xs text-dim"
            style="font-family: var(--font-mono); display: flex; align-items: center; gap: 8px;"
          >
            <span class="bp-chat-spinner" aria-hidden="true"></span>
            <span>
              <span :if={@status == :interrupting}>stopping…</span>
              <span
                :if={@status != :interrupting}
                id="chat-turn-word"
                class="bp-chat-spin-word"
                phx-hook="ChatSpinWord"
                phx-update="ignore"
                data-words={spinner_words_json()}
                data-rotate-ms={spinner_rotate_ms()}
              >{@spinner_word}…</span>
              <%!-- The elapsed clock is the BROWSER's (bp-chat-turn-clock.js):
                    the server stamps this turn's start ONCE and the hook mutates
                    textContent on its own 1 s interval, so no viewer costs a
                    per-second LiveView patch. `phx-update="ignore"` keeps the
                    constant transcript patching from reverting the hook's text;
                    every remount (this row hides behind each streaming frame)
                    and every reconnect re-seeds from THIS server value. --%>
              <span
                :if={@turn_started_at_ms}
                id="chat-turn-elapsed"
                style="opacity: 0.8;"
                phx-hook="ChatElapsed"
                phx-update="ignore"
                data-started-at={@turn_started_at_ms}
              ></span>
              · Stop to interrupt
            </span>
          </div>
        </div>
      </div>

      <%!-- The Doing strip (hand-task surface): every ledger claim this
            session's worker holds, live off the dataset's task broadcasts —
            title · met/total criteria · pulse now-line · id. Proof the agent
            is ON a task, not just talking about one. --%>
      <div :if={@hand_tasks != %{}} style="flex: none; padding: 0 16px;">
        <div
          :for={{task_id, t} <- Enum.take(Enum.sort(@hand_tasks), 3)}
          class="text-xs text-dim"
          data-role="chat-hand-task"
          data-task-id={task_id}
          style="font-family: var(--font-mono); display: flex; align-items: center; gap: 8px; padding: 2px 0; min-width: 0;"
        >
          <span aria-hidden="true" style="color: var(--primary);">⚒</span>
          <span style="color: var(--fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
            {t.title}
          </span>
          <span :if={t.total > 0} title="acceptance criteria met">{t.met}/{t.total} ✓</span>
          <span
            :if={t.now not in [nil, ""]}
            style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap; opacity: 0.85;"
            title="the claim's pulse now-line"
          >
            · {t.now}
          </span>
          <span style="opacity: 0.7; flex: none;">{task_id}</span>
        </div>
        <div
          :if={map_size(@hand_tasks) > 3}
          class="text-xs text-dim"
          style="font-family: var(--font-mono); padding: 2px 0;"
        >
          +{map_size(@hand_tasks) - 3} more claims
        </div>
      </div>

      <%!-- Ready-task picker (hand-task surface): the queue head, loaded fresh
            on every open. Hand to Claude rides the normal send path with the
            claim-first prompt — the ledger writes stay in the agent's hands. --%>
      <div :if={@task_picker != nil} data-role="chat-task-picker" style="flex: none; padding: 6px 16px 0;">
        <div style="border: 1px solid var(--border); border-radius: 10px; padding: 8px 12px; display: flex; flex-direction: column; gap: 4px;">
          <div class="text-xs text-dim" style="font-family: var(--font-mono);">ready tasks</div>
          <div :if={@task_picker == []} class="text-xs text-dim">
            Nothing ready — file new work with /task new &lt;wish&gt;.
          </div>
          <div
            :for={t <- @task_picker}
            class="text-xs"
            style="display: flex; align-items: center; gap: 8px; min-width: 0;"
          >
            <span :if={t.priority} class="text-dim" style="font-family: var(--font-mono); flex: none;">
              p{t.priority}
            </span>
            <span style="flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
              {t.title}
            </span>
            <span class="text-dim" style="font-family: var(--font-mono); flex: none;">{t.id}</span>
            <button
              type="button"
              class="bp-iconbtn"
              style="width: auto; padding: 0 8px; font-size: 0.72rem; font-family: var(--font-mono);"
              phx-click="hand_task"
              phx-value-id={t.id}
              title="Claim-first: Claude claims it, reads the brief, stamps evidence, closes"
            >
              Hand to Claude
            </button>
          </div>
        </div>
      </div>

      <div style="flex: none; padding: 8px 16px 12px;">
        <%!-- One-card composer: input on top, controls row below, ONE rounded
              border around both. The form and the cockpit stay SIBLINGS inside
              the card (nested <form>s are invalid HTML — the parser would drop
              them and break the phx-change selectors); the card div is pure
              chrome. --%>
        <div class="bp-composer">
        <%!-- Chat-never-vanishes onboarding card (chat-task-hands, charter
              D2/decision 4): a claude-lane not-ready verdict (:no_binary /
              :not_logged_in) REPLACES the composer inside this same chrome —
              one calm card, the exact next step, and a Re-check that
              re-probes and unlocks the composer in place. The bp-lane states
              render as a banner BELOW the live composer instead (the chat
              itself still works; only its task hands are offline). --%>
        <.chat_readiness_card
          :if={composer_locked?(@readiness)}
          readiness={@readiness}
          provider={@provider}
        />
        <div :if={not composer_locked?(@readiness)} style="display: contents;">
        <form
          id="chat-composer-form"
          phx-hook="ChatComposer"
          phx-submit="send"
          phx-change="composer-change"
          data-commands={Jason.encode!(slash_vocab(@commands))}
          style="display: flex; flex-direction: column; gap: 8px; padding: 12px 14px 2px;"
        >
          <%!-- The upload the paste/drop hook feeds (charter D25). Kept in the
                DOM (allow_upload needs it) but visually hidden — files are added
                programmatically via `this.upload("attachments", …)`. The form's
                phx-change (composer-change, which also owns the server-bound
                draft per D24) is what lets allow_upload validate staged entries. --%>
          <.live_file_input upload={@uploads.attachments} style="display: none;" />

          <%!-- Attachment strip: a thumbnail chip per staged image with a remove
                button; per-entry + form-level upload errors render honestly. --%>
          <div
            :if={@uploads.attachments.entries != []}
            style="display: flex; flex-wrap: wrap; gap: 8px;"
          >
            <div
              :for={entry <- @uploads.attachments.entries}
              style="display: flex; align-items: center; gap: 6px; border: 1px solid var(--border-muted); border-radius: 8px; padding: 4px 6px; background: var(--bg);"
            >
              <.live_img_preview
                entry={entry}
                style="width: 40px; height: 40px; object-fit: cover; border-radius: 6px;"
              />
              <span
                class="text-xs text-dim"
                style="max-width: 130px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
              >
                <%= entry.client_name %>
              </span>
              <button
                type="button"
                class="btn"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                aria-label="Remove attachment"
                style="padding: 0 6px; line-height: 1;"
              >
                ×
              </button>
              <span
                :for={err <- upload_errors(@uploads.attachments, entry)}
                class="text-xs"
                role="alert"
                style="color: var(--danger);"
              >
                <%= upload_error_label(err) %>
              </span>
            </div>
          </div>
          <p
            :for={err <- upload_errors(@uploads.attachments)}
            class="text-xs"
            role="alert"
            style="color: var(--danger); margin: 0;"
          >
            <%= upload_error_label(err) %>
          </p>

          <div style="display: flex; gap: 8px;">
            <%!-- Slash-command combobox (charter D36b): typing a leading "/"
                  opens the listbox below; the ChatComposer hook filters the
                  server-stamped vocab (data-commands on the form), handles
                  ArrowUp/Down/Enter/Escape + aria-activedescendant, and on
                  select writes the input value AND dispatches a native input
                  event so the server-bound draft stays in sync (D24). --%>
            <div style="position: relative; flex: 1;">
              <input
                id="chat-composer"
                type="text"
                name="message"
                value={@composer_draft}
                autocomplete="off"
                role="combobox"
                aria-expanded="false"
                aria-autocomplete="list"
                aria-controls="chat-slash-menu"
                aria-activedescendant=""
                placeholder={composer_placeholder(@status)}
                class="bp-composer-input"
              />
              <%!-- phx-update="ignore": the combobox hook OWNS this element —
                    every keystroke round-trips (server-bound composer, D24) and
                    without the ignore, the returning patch re-applies `hidden`
                    and wipes the options the instant the menu opens. --%>
              <ul
                id="chat-slash-menu"
                class="bp-composer-menu"
                phx-update="ignore"
                role="listbox"
                aria-label="Slash commands"
                hidden
              >
              </ul>
            </div>
          </div>

        </form>

        <%!-- Composer cockpit footer (charter D44): the mode + model controls
              live borderless on the left (KEEP the phx-change form wrappers —
              the test selectors target them), the mini context ring + image
              attach + Send/Stop cluster on the right. It reads as one composer
              block but is a SIBLING of the form, never a child — nested <form>s
              are invalid HTML (the parser drops them, breaking the selectors).
              Send re-associates to the composer via `form="chat-composer-form"`;
              the attach <label>'s `for` reaches the hidden input by id. --%>
        <div style="display: flex; align-items: center; gap: 10px; padding: 4px 12px 10px;">
            <div style="display: flex; align-items: center; gap: 8px; min-width: 0;">
              <form
              :if={is_nil(@store_session_id)}
                phx-change="set-provider"
                style="display: inline-flex; align-items: center;"
              >
                <span class="bp-select bp-select-strong">
                  <select name="provider" aria-label="Provider">
                    <option :for={p <- StudioChat.Session.providers()} value={p} selected={p == @provider}>
                      <%= String.capitalize(p) %>
                    </option>
                  </select>
                </span>
              </form>
              <form
                :if={is_nil(@store_session_id) and @execution_target == "registered_host"}
                phx-change="set-execution-host"
                style="display: inline-flex; align-items: center;"
              >
                <span class="bp-select">
                  <select name="execution_host_id" aria-label="Registered host">
                    <option value="">Choose local hardware…</option>
                    <option
                      :for={host <- @execution_hosts}
                      value={host.id}
                      selected={host.id == @execution_host_id}
                    >
                      <%= host.name %><%= if host.online, do: " · online", else: " · offline" %>
                    </option>
                  </select>
                </span>
              </form>
              <form
                :if={is_nil(@store_session_id)}
                phx-change="set-execution-target"
                style="display: inline-flex; align-items: center;"
              >
                <span class="bp-select">
                  <select name="execution_target" aria-label="Execution target">
                    <option value="managed" selected={@execution_target == "managed"}>Managed</option>
                    <option value="registered_host" selected={@execution_target == "registered_host"}>
                      Registered host
                    </option>
                  </select>
                </span>
              </form>
              <%!-- Session mode: a two-state projection over the raw permission
                    modes — ◇ Plan (plan + discuss, read-only) ⇄ ▶ Autopilot
                    ("auto"). An odd raw mode (a resumed acceptEdits/manual/…
                    row, or an armed bypass) surfaces honestly as a transient
                    third segment until the user picks a side; the bypass arm
                    ceremony itself is reachable via /bypass (charter D48 — the
                    toggle never offers it). --%>
              <%!-- Map.get, not strict access: test/fake provider capability
                    maps may omit :mode_switch — an absent key means no toggle,
                    never a render crash. --%>
              <div
                :if={Map.get(Runtime.capabilities(@provider), :mode_switch, false)}
                class="mode-toggle"
                role="tablist"
                aria-label="Session mode"
              >
                <button
                  type="button"
                  role="tab"
                  aria-selected={to_string(mode_segment(@mode) == :plan)}
                  class={["mode-tab mode-tab-plan", mode_segment(@mode) == :plan && "active"]}
                  phx-click="set-mode"
                  phx-value-mode="plan"
                >
                  ◇ Plan
                </button>
                <button
                  type="button"
                  role="tab"
                  aria-selected={to_string(mode_segment(@mode) == :autopilot)}
                  class={["mode-tab mode-tab-autopilot", mode_segment(@mode) == :autopilot && "active"]}
                  phx-click="set-mode"
                  phx-value-mode="auto"
                >
                  ▶ Autopilot
                </button>
                <button
                  :if={mode_segment(@mode) in [:other, :bypass]}
                  type="button"
                  role="tab"
                  aria-selected="true"
                  disabled
                  class={[
                    "mode-tab active",
                    (mode_segment(@mode) == :bypass && "mode-tab-bypass") || "mode-tab-other"
                  ]}
                >
                  <%= mode_label(@mode) %>
                </button>
              </div>
              <%!-- Model picker (wave 5): the choice is intent — it rides the next
                    spawn as `--model` and steers a live session via the set_model
                    control frame; the dim mono suffix is FACT (the answering model
                    observed off the last init/result), sitting beside its intent. --%>
              <form phx-change="set-model" style="display: inline-flex; align-items: center; gap: 6px;">
                <span class="bp-select bp-select-strong">
                <select
                  name="model"
                  aria-label="Model"
                >
                  <option value="default" selected={@model_choice == "default"}>
                    Model
                  </option>
                  <option :for={m <- Runtime.capabilities(@provider).models} value={m} selected={m == @model_choice}>
                    <%= model_label(m) %>
                  </option>
                </select>
                </span>
                <span
                  :if={@init && @init.model}
                  class="text-xs text-dim"
                  style="font-family: var(--font-mono);"
                  title="The answering model, as reported by the CLI"
                >
                  <%= @init.model %>
                </span>
              </form>
              <%!-- Effort picker (wave 9, charter D48): composed with the model as
                    one "Fable high" group — dark model beside dim effort reads as a
                    pair. It is intent-only (rides the next spawn as `--effort`); a
                    mid-session change never steers the running turn (no set_effort
                    control verb). --%>
              <form phx-change="set-effort" style="display: inline-flex; align-items: center;">
                <span class="bp-select">
                <select
                  name="effort"
                  aria-label="Reasoning effort"
                >
                  <option value="default" selected={@effort_choice == "default"}>
                    Effort
                  </option>
                  <option :for={e <- Runtime.capabilities(@provider).efforts} value={e} selected={e == @effort_choice}>
                    <%= effort_label(e) %>
                  </option>
                </select>
                </span>
              </form>
            </div>
            <div style="display: flex; align-items: center; gap: 8px; margin-left: auto;">
              <%!-- The one-word session status (new chat / ready / working /
                    stopping… / offline) — the honest state affordance the old
                    header line carried, now a quiet cockpit fact beside the
                    ring. Tests assert these words render; keep them visible. --%>
              <span class="text-xs text-dim" style="font-family: var(--font-mono); opacity: 0.8;">
                <%= status_label(@status) %>
              </span>
              <.context_ring ring={@ring} size={:sm} show_cost={false} />
              <%!-- Ready-task picker toggle (hand-task surface): opens the
                    ready-queue head above the composer; each row hands its
                    task to the agent as a claim-first work prompt. --%>
              <button
                type="button"
                class="bp-iconbtn"
                phx-click="toggle-task-picker"
                aria-label="Barkpark tasks — hand ready work to Claude"
                aria-expanded={to_string(@task_picker != nil)}
                title="Barkpark tasks"
              >
                <.icon name="check-square" size={16} />
              </button>
              <%!-- Attach an image (charter D44/D25): a <label> for the hidden
                    live_file_input (whose id is the upload ref) opens the native
                    picker with ZERO hook change. The strip / paste-drop are below. --%>
              <label
                for={@uploads.attachments.ref}
                class="bp-iconbtn"
                aria-label="Attach an image"
                title="Attach an image"
              >
                <.icon name="image" size={16} />
              </label>
              <%!-- While a turn runs the primary button becomes Stop (interrupt),
                    but pressing ↵ still submits: a mid-turn send is queued honestly
                    (charter D43) — dispatched immediately, run as the next turn. --%>
              <%!-- Icon-only Stop: the "Stopping…" word lives in the composer
                    placeholder (composer_placeholder(:interrupting)), so the
                    button stays a quiet square-in-circle like the reference. --%>
              <button
                :if={turn_active?(@status)}
                type="button"
                class="bp-iconbtn"
                phx-click="stop_turn"
                disabled={@status == :interrupting}
                aria-label="Stop the current turn"
                title={if @status == :interrupting, do: "Stopping…", else: "Stop (esc)"}
                style="color: var(--danger);"
              >
                <span style="display: inline-block; width: 9px; height: 9px; background: currentColor; border-radius: 2px;"></span>
              </button>
              <button
                :if={not turn_active?(@status)}
                type="submit"
                form="chat-composer-form"
                class="bp-iconbtn bp-iconbtn-primary"
                aria-label="Send message"
              >
                <.icon name="send" size={14} />
              </button>
            </div>
        </div>
        <%!-- Probe-in-flight strip (:checking): the readiness check costs
              ~1–2s — say so quietly WITHOUT hiding the composer (the common
              verdict is :ready; hiding it on every mount would be its own
              vanish). A not-ready verdict swaps the card in above. --%>
        <div
          :if={@readiness == :checking}
          data-role="chat-readiness"
          data-readiness="checking"
          class="text-xs text-dim"
          style="display: flex; align-items: center; gap: 8px; padding: 0 14px 10px; font-family: var(--font-mono); opacity: 0.75;"
        >
          <span class="bp-chat-spinner" aria-hidden="true"></span>
          <span>checking <%= String.capitalize(@provider) %> readiness…</span>
        </div>
        <%!-- bp-lane banner: task hands offline, chat still live (charter D2 —
              named state + next step, never a silent Logger line). --%>
        <.chat_readiness_card
          :if={@readiness in [:no_task_hands, :task_token_expired, :task_token_rearmed]}
          readiness={@readiness}
          provider={@provider}
        />
        </div>
        </div>
        <%!-- Bypass ARM panel (charter D48): opened only when the user picks
              bypassPermissions. Loud via --danger tokens, type-the-word-"bypass"
              + an explicit Arm button — a select alone can NEVER arm dangerous
              bypass. Arming persists the mode (the next spawn's build_args, gated
              on the persisted row, emits --allow-dangerously-skip-permissions);
              it does NOT steer the running turn. --%>
        <div
          :if={@arming_bypass}
          role="alertdialog"
          aria-label="Arm bypass permissions"
          style="max-width: 860px; margin: 10px auto 0; padding: 12px 14px; border: 1px solid var(--danger); border-radius: 8px; background: hsl(var(--danger-hsl) / 0.08);"
        >
          <%!-- Honest reopen affordance (charter D55): a remembered bypass
                session lands here disarmed — the mode persisted but the live
                arming did not, so the next resume fail-closes to plan until the
                ceremony re-runs. --%>
          <p
            :if={@bypass_disarmed}
            class="text-xs"
            style="color: var(--danger); font-weight: 600; margin: 0 0 4px;"
          >
            ⚠ Bypass disarmed — re-arm to enable. This session remembers bypassPermissions, but arming never survives a reopen.
          </p>
          <p class="text-xs" style="color: var(--danger); font-weight: 600; margin: 0 0 4px;">
            ⚠ Bypass permissions runs tools WITHOUT asking — full shell reach, no approval cards.
          </p>
          <p class="text-xs text-dim" style="margin: 0 0 8px;">
            Type <strong>bypass</strong> to confirm, then Arm. It takes effect on the next spawn, not the running turn.
          </p>
          <%!-- phx-submit rides along so Enter in the confirm input ARMS (server-guarded
                on the exact word) instead of falling through to a native form submit
                that would navigate the whole LiveView away. --%>
          <form
            phx-change="bypass-confirm"
            phx-submit="arm-bypass"
            style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;"
          >
            <input
              type="text"
              name="confirm"
              value={@bypass_confirm}
              autocomplete="off"
              placeholder="bypass"
              aria-label="Type bypass to confirm"
              class="text-xs"
              style="flex: 0 1 160px; padding: 4px 8px; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); color: var(--text); font-family: var(--font-mono);"
            />
            <button
              type="button"
              phx-click="arm-bypass"
              disabled={String.trim(@bypass_confirm || "") != "bypass"}
              class="btn"
              aria-label="Arm bypass permissions"
              style={"padding: 4px 12px; font-weight: 600; color: var(--danger); border-color: var(--danger);" <> if(String.trim(@bypass_confirm || "") != "bypass", do: " opacity: 0.5; cursor: not-allowed;", else: "")}
            >
              Arm bypass
            </button>
            <button
              type="button"
              phx-click="cancel-arm-bypass"
              class="btn text-xs text-dim"
              aria-label="Cancel"
              style="padding: 4px 10px;"
            >
              Cancel
            </button>
          </form>
        </div>
        <%!-- Cost strip: facts only, and only once a turn has a cost. The
              keyboard affordances (charter D42) moved into the idle composer
              PLACEHOLDER — no standing footer row. --%>
        <div
          :if={@last_result && @last_result.cost_usd}
          class="text-xs text-dim"
          style="max-width: 860px; margin: 5px auto 0; padding: 0 6px; font-family: var(--font-mono); font-size: 11px; opacity: 0.6;"
        >
          <%= @mode %> ⏵ <%= (@init && @init.model) || @model_choice %> · <%= format_duration(
            @last_result.duration_ms
          ) %> · $<%= :erlang.float_to_binary(@last_result.cost_usd / 1, decimals: 4) %>
        </div>

        <%!-- Agents rail (charter D47): the Claude-Code-TUI mission-control view,
              directly below the composer. One row per background task; a workflow
              row expands (per-tab) into its phase→agent tree with breathing state
              glyphs, models, and token counts. Hydrated from `rail_snapshot` on
              reopen; a dead "running" entry reads "interrupted", never a spinner. --%>
        <.agents_rail
          :if={map_size(@rail) > 0}
          rail={@rail}
          rail_expanded={@rail_expanded}
          agent_detail_expanded={@agent_detail_expanded}
        />
      </div>
      </div>
    </div>
    """
  end

  # The onboarding card (chat-task-hands, charter D2/decision 4) — ONE calm
  # card per named not-ready state, rendered inside the bp-composer chrome.
  # Every state carries its exact next step and a Re-check button that
  # re-probes and unlocks the composer in place — the chat never dead-ends.
  attr :readiness, :atom, required: true
  attr :provider, :string, required: true

  defp chat_readiness_card(assigns) do
    ~H"""
    <div
      data-role="chat-readiness"
      data-readiness={@readiness}
      role="status"
      style="display: flex; flex-direction: column; gap: 8px; padding: 14px 16px;"
    >
      <span class="text-sm" style="font-weight: 600; display: flex; align-items: center; gap: 8px;">
        <.icon name="alert-triangle" size={15} />
        <%= readiness_title(@readiness, @provider) %>
      </span>
      <p class="text-sm text-dim" style="margin: 0; max-width: 60ch;">
        <%= readiness_body(@readiness, @provider) %>
      </p>
      <code
        :if={readiness_step(@readiness, @provider)}
        class="text-xs"
        style="font-family: var(--font-mono); background: var(--bg); border: 1px solid var(--border-muted); border-radius: 6px; padding: 4px 8px; align-self: flex-start;"
      >
        <%= readiness_step(@readiness, @provider) %>
      </code>
      <div>
        <button
          type="button"
          class="btn text-xs"
          phx-click="readiness-recheck"
          aria-label="Re-check readiness"
          style="padding: 4px 12px;"
        >
          Re-check
        </button>
      </div>
    </div>
    """
  end

  defp readiness_title(:no_binary, "claude"), do: "Claude Code isn't installed on this host"
  defp readiness_title(:no_binary, provider), do: "#{provider_name(provider)} isn't installed"

  defp readiness_title(:not_logged_in, "claude"),
    do: "Claude Code isn't logged in on this host"

  defp readiness_title(:not_logged_in, provider),
    do: "#{provider_name(provider)} isn't logged in on this execution host"

  defp readiness_title(:no_task_hands, _provider), do: "Task hands are offline"

  defp readiness_title(:task_token_expired, _provider),
    do: "The chat's task credential expired"

  defp readiness_title(:task_token_rearmed, _provider),
    do: "Task hands re-armed — restart to hand them over"

  defp readiness_title(_, _provider), do: "Checking readiness"

  # :no_binary reuses the spawn-error copy VERBATIM (the card is that copy's
  # first live surface — it was dead code until this slice).
  defp readiness_body(:no_binary, "claude"), do: spawn_error_text(:binary_not_found)

  defp readiness_body(:no_binary, provider),
    do: "The #{provider_name(provider)} runtime is not available on the selected execution host."

  defp readiness_body(:not_logged_in, "claude"),
    do:
      "The `claude` binary is installed, but it has no credentials. " <>
        "Log in on this host, then Re-check — the composer unlocks in place, no reload."

  defp readiness_body(:not_logged_in, provider),
    do:
      "#{provider_name(provider)} is installed but has no usable local credentials. " <>
        "Authenticate on the execution host, then Re-check."

  defp readiness_body(:no_task_hands, _provider),
    do:
      "Barkpark refused to mint this session's task credential — the agent can chat, " <>
        "but its bp task tools are offline. Check that your admin token has write " <>
        "access to this workspace, then Re-check."

  defp readiness_body(:task_token_expired, _provider),
    do:
      "This session's minted Barkpark task token has expired and Barkpark could not " <>
        "mint a replacement, so its bp task tools are offline. The chat itself still " <>
        "works. Start a new session to mint fresh task hands."

  defp readiness_body(:task_token_rearmed, _provider),
    do:
      "This session's task credential was about to expire, so Barkpark minted a fresh " <>
        "one and revoked the old. The new credential is already wired into this " <>
        "session's MCP config; the running agent's shell still holds the retired one " <>
        "until the session restarts — a live process's environment cannot be rewritten."

  defp readiness_body(_, provider), do: "Checking #{provider_name(provider)} readiness…"

  defp readiness_step(:not_logged_in, "claude"), do: "claude auth login"
  defp readiness_step(:not_logged_in, "codex"), do: "codex login"

  # The named next step for a re-armed session: the MCP lane already has the
  # fresh credential; the Bash lane is re-armed by the next spawn.
  defp readiness_step(:task_token_rearmed, _provider), do: "Restart this session"
  defp readiness_step(_, _provider), do: nil

  defp provider_name("claude"), do: "Claude Code"
  defp provider_name("codex"), do: "Codex"
  defp provider_name(provider), do: String.capitalize(provider)

  # The agents rail (charter D47) — mission control below the composer. Distinct
  # from the D45/D46 transcript spawn rows BY DESIGN (this is live state, that is
  # history); no dedup. All chrome via emitted tokens.
  attr :rail, :map, required: true
  attr :rail_expanded, :map, required: true
  attr :agent_detail_expanded, :map, required: true

  defp agents_rail(assigns) do
    ~H"""
    <div
      data-role="agents-rail"
      style="max-width: 860px; margin: 10px auto 0; border-top: 1px solid var(--border-muted); padding-top: 8px; font-family: var(--font-mono);"
    >
      <div class="text-xs text-dim" style="display: flex; align-items: center; gap: 6px; margin-bottom: 6px; opacity: 0.75;">
        <span aria-hidden="true">▚</span>
        <span>agents · <%= map_size(@rail) %></span>
      </div>

      <.rail_entry
        :for={entry <- rail_rows(@rail)}
        entry={entry}
        open={rail_open?(@rail_expanded, entry)}
        agent_detail_expanded={@agent_detail_expanded}
      />
    </div>
    """
  end

  # One rail entry rendered as a phase JOURNEY (charter D57/D58/wave-11): the
  # header line settles by status, and — when expanded — completed phases collapse
  # to one quiet line, the active phase breathes with its live agents, and future
  # phases render dim by name. The whole projection is `StudioChat.workflow_journey/1`
  # — no numbers invented in the view. A non-workflow row (no phases) keeps the
  # simple one-line render.
  attr :entry, :map, required: true
  attr :open, :boolean, required: true
  attr :agent_detail_expanded, :map, required: true

  defp rail_entry(assigns) do
    journey = StudioChat.workflow_journey(assigns.entry)
    assigns = assign(assigns, journey: journey, workflow?: journey.phases != [])

    ~H"""
    <div
      id={"rail-entry-#{@entry["task_id"]}"}
      data-rail-task={@entry["task_id"]}
      data-rail-status={@entry["status"]}
      phx-remove={
        Phoenix.LiveView.JS.hide(
          transition:
            {"bp-chat-rail-leave", "bp-chat-rail-leave-start", "bp-chat-rail-leave-end"},
          time: 320
        )
      }
      style="padding: 3px 0;"
    >
      <div class="text-xs" style="display: flex; align-items: baseline; gap: 6px;">
        <span
          aria-hidden="true"
          class={rail_running?(@entry) && "bp-chat-agent-run"}
          style={"flex: none; color: #{rail_status_color(@entry["status"])};"}
        >
          <%= rail_entry_glyph(@entry) %>
        </span>
        <span style="min-width: 0; overflow-wrap: anywhere; flex: 1;">
          <span style="font-weight: 600;"><%= rail_label(@entry) %></span>
          <span
            class="text-dim"
            style={"margin-left: 6px; opacity: 0.85; color: #{rail_status_color(@entry["status"])};"}
          >
            · <%= rail_header_summary(@entry, @journey) %>
          </span>
        </span>
        <button
          :if={@workflow?}
          type="button"
          class="btn text-xs"
          phx-click="rail-toggle"
          phx-value-id={@entry["task_id"]}
          aria-expanded={to_string(@open)}
          style="flex: none; padding: 1px 8px; opacity: 0.8;"
        >
          <%= if @open, do: "collapse", else: "expand" %>
        </button>
      </div>

      <%!-- The phase journey. Expanded by default while a cycle lives (a completed
            cycle defaults collapsed to the one summary line above; the per-tab
            toggle overrides both ways, charter D61). --%>
      <div :if={@open and @workflow?} style="padding-left: 16px; margin-top: 2px;">
        <.rail_phase
          :for={phase <- @journey.phases}
          phase={phase}
          entry={@entry}
          agent_detail_expanded={@agent_detail_expanded}
        />
      </div>
    </div>
    """
  end

  # A single phase in the journey — settled phases are one quiet line; the active
  # (or interrupted-frontier) phase heads its nested agent rows.
  attr :phase, :map, required: true
  attr :entry, :map, required: true
  attr :agent_detail_expanded, :map, required: true

  defp rail_phase(assigns) do
    ~H"""
    <div data-rail-phase={@phase.status} style="padding: 1px 0;">
      <div
        class="text-xs"
        style="display: flex; align-items: baseline; gap: 6px; overflow-wrap: anywhere;"
      >
        <span aria-hidden="true" style={"flex: none; color: #{rail_phase_color(@phase.status)};"}>
          <%= rail_phase_glyph(@phase.status) %>
        </span>
        <span style={"min-width: 0; flex: 1; color: #{rail_phase_color(@phase.status)};"}>
          <span style="font-weight: 600;"><%= @phase.title %></span>
          <span :if={@phase.status == :done} class="text-dim" style="margin-left: 6px; opacity: 0.7;">
            · <%= @phase.total %> <%= pluralize(@phase.total, "agent") %> · <%= StudioChat.format_tokens(@phase.tokens) %> tok
          </span>
          <span
            :if={@phase.status == :done and @phase.failed > 0}
            style="margin-left: 6px; color: var(--danger);"
          >
            · <%= @phase.failed %> failed
          </span>
          <span :if={@phase.status == :skipped} class="text-dim" style="margin-left: 6px; opacity: 0.7;">
            · skipped
          </span>
        </span>
      </div>

      <div
        :if={@phase.status in [:active, :interrupted]}
        style="padding-left: 16px; margin-top: 1px;"
      >
        <.rail_agent
          :for={node <- @phase.agents}
          node={node}
          entry={@entry}
          agent_detail_expanded={@agent_detail_expanded}
        />
      </div>
    </div>
    """
  end

  # A single agent row: state glyph · two-part label · model family · tokens. It
  # breathes ONLY while its entry is live and its state is non-terminal — a dead
  # (interrupted) entry's non-terminal agents never spin (no fake spinners law).
  attr :node, :map, required: true
  attr :entry, :map, required: true
  attr :agent_detail_expanded, :map, required: true

  defp rail_agent(assigns) do
    detail = StudioChat.workflow_agent_node_detail(assigns.node)
    agent_id = assigns.node["agentId"]
    # The affordance is gated on DETAIL, never origin (wsc-ad D27): a node with no
    # brief/tool/result/attempt (or no id to key the toggle) simply carries no
    # drill-down — a background/codex row stays one quiet line.
    has_detail? = detail != %{} and is_binary(agent_id)

    assigns =
      assign(assigns,
        detail: detail,
        agent_id: agent_id,
        has_detail?: has_detail?,
        detail_open?: has_detail? and agent_detail_open?(assigns.agent_detail_expanded, agent_id)
      )

    ~H"""
    <div data-rail-node="workflow_agent">
      <div
        class="text-xs"
        style="display: flex; align-items: baseline; gap: 6px; padding: 1px 0; overflow-wrap: anywhere;"
      >
        <span
          aria-hidden="true"
          class={rail_node_running?(@entry, @node) && "bp-chat-agent-run"}
          title={@node["error"]}
          style={"flex: none; color: #{rail_agent_color(@entry, @node)};"}
        >
          <%= rail_agent_glyph(@node) %>
        </span>
        <span style="min-width: 0; flex: 1;">
          <%= case StudioChat.workflow_label_parts(@node["label"]) do %>
            <% {:pair, kind, rest} -> %>
              <span class="text-dim" style="opacity: 0.7;"><%= kind %>:</span><span style="font-weight: 600;"><%= rest %></span>
            <% {:bare, label} -> %>
              <span><%= label || "agent" %></span>
          <% end %>
          <span :if={@node["model"]} class="text-dim" style="margin-left: 6px; opacity: 0.7;">
            <%= StudioChat.model_family(@node["model"]) %>
          </span>
          <span :if={rail_node_tokens(@node)} class="text-dim" style="margin-left: 6px; opacity: 0.7;">
            · <%= StudioChat.format_tokens(rail_node_tokens(@node)) %> tok
          </span>
        </span>
        <button
          :if={@has_detail?}
          type="button"
          class="btn text-xs"
          phx-click="rail-agent-toggle"
          phx-value-id={@agent_id}
          aria-expanded={to_string(@detail_open?)}
          style="flex: none; padding: 0 6px; opacity: 0.7;"
        >
          <%= if @detail_open?, do: "hide", else: "detail" %>
        </button>
      </div>

      <.rail_agent_detail :if={@detail_open?} detail={@detail} />
    </div>
    """
  end

  # The expanded per-agent detail (wsc-ad): ABOUT — the brief; NOW — the live tool
  # line + progress age while the agent is non-terminal; DONE — the settled result
  # (capped) once terminal; and an attempt>1 retry chip. Every field is read
  # VERBATIM off the normalized detail map — absent fields simply do not render.
  # HONESTY: thinking text never rides the wire (encrypted signature only), so
  # NOTHING here is labeled "thinking" — the brief + tool line + result ARE the
  # honest window into what the agent is about.
  attr :detail, :map, required: true

  defp rail_agent_detail(assigns) do
    ~H"""
    <div
      class="text-xs"
      style="padding: 1px 0 4px 20px; display: flex; flex-direction: column; gap: 3px;"
    >
      <div :if={@detail["attempt"] && @detail["attempt"] > 1}>
        <span
          class="text-xs"
          style="display: inline-block; padding: 0 6px; border-radius: 8px; background: var(--warn-soft); color: var(--warn);"
        >
          attempt <%= @detail["attempt"] %>
        </span>
      </div>

      <div
        :if={@detail["promptPreview"]}
        class="text-dim"
        style="opacity: 0.85; white-space: pre-wrap; overflow-wrap: anywhere;"
      >
        <span style="font-weight: 600; opacity: 0.7;">about</span>
        <%= @detail["promptPreview"] %>
      </div>

      <div
        :if={not @detail["terminal"] and (@detail["lastToolName"] || @detail["lastToolSummary"])}
        style="overflow-wrap: anywhere;"
      >
        <span aria-hidden="true">▸</span>
        <span :if={@detail["lastToolName"]} style="font-weight: 600;"><%= @detail["lastToolName"] %></span>
        <span :if={@detail["lastToolSummary"]} class="text-dim" style="opacity: 0.85;">
          · <%= @detail["lastToolSummary"] %>
        </span>
        <span
          :if={agent_progress_age(@detail["lastProgressAt"])}
          class="text-dim"
          style="opacity: 0.6;"
        >
          · <%= agent_progress_age(@detail["lastProgressAt"]) %>
        </span>
      </div>

      <div
        :if={@detail["terminal"] and @detail["resultPreview"]}
        class="text-dim"
        style="opacity: 0.85; white-space: pre-wrap; overflow-wrap: anywhere;"
      >
        <span style="font-weight: 600; opacity: 0.7;">done</span>
        <%= agent_result_preview(@detail["resultPreview"]) %>
      </div>
    </div>
    """
  end

  # Cap the settled result at 300 opaque chars (wsc-ad) — it is NOT re-parsed and
  # NOT run through `summary_preview` (that is for a different, JSON-aware path);
  # it is verbatim text with an ellipsis when clipped.
  defp agent_result_preview(text) when is_binary(text) do
    if String.length(text) > 300, do: String.slice(text, 0, 300) <> "…", else: text
  end

  defp agent_result_preview(_), do: nil

  # Coarse age of the last progress tick (epoch-ms), for the live NOW line only.
  # A wall-clock read — deliberately confined to non-terminal agent rows, which
  # never appear in any byte-locked/determinism-guarded region (the golden folds a
  # COMPLETED run, whose phases collapse their agents). Reuses `age_words/1`.
  defp agent_progress_age(ms) when is_integer(ms) do
    diff = System.system_time(:millisecond) - ms
    if diff >= 0, do: age_words(div(diff, 1000)), else: nil
  end

  defp agent_progress_age(_), do: nil

  # A dedicated shimmering placeholder per forming component — the reader sees
  # WHAT is coming (a chart, a diagram, a table…) instead of raw source noise.
  # Pure CSS (the pulse keyframes ride the transcript <style> in render/1).
  defp skeleton(assigns) do
    ~H"""
    <div
      class="bp-chat-skel"
      data-skel={@kind}
      style="border: 1px dashed hsl(var(--primary-hsl) / 0.45); border-radius: 8px; padding: 10px 12px; margin: 6px 0;"
    >
      <div
        class="text-xs text-dim"
        style="font-family: var(--font-mono); margin-bottom: 8px; display: flex; align-items: center; gap: 6px;"
      >
        <span class="bp-skel-dot"></span> rendering <%= StreamTail.skeleton_label(@kind) %>…
      </div>
      <%= case @kind do %>
        <% "chart" -> %>
          <div style="display: flex; align-items: flex-end; gap: 6px; height: 64px;">
            <div :for={h <- [40, 62, 30, 52, 44, 58]} class="bp-skel-shape" style={"width: 22px; height: #{h}px;"}></div>
          </div>
        <% "stats" -> %>
          <div style="display: flex; gap: 8px;">
            <div :for={_i <- 1..3} class="bp-skel-shape" style="flex: 1; height: 52px;"></div>
          </div>
        <% "table" -> %>
          <div style="display: flex; flex-direction: column; gap: 5px;">
            <div :for={_r <- 1..3} style="display: flex; gap: 5px;">
              <div :for={_c <- 1..3} class="bp-skel-shape" style="flex: 1; height: 14px;"></div>
            </div>
          </div>
        <% "diagram" -> %>
          <div style="display: flex; align-items: center; gap: 10px; height: 56px;">
            <div class="bp-skel-shape" style="width: 88px; height: 34px;"></div>
            <div class="bp-skel-shape" style="flex: 1; height: 2px;"></div>
            <div class="bp-skel-shape" style="width: 88px; height: 34px;"></div>
          </div>
        <% "callout" -> %>
          <div style="display: flex; gap: 8px;">
            <div class="bp-skel-shape" style="width: 3px; align-self: stretch;"></div>
            <div style="flex: 1; display: flex; flex-direction: column; gap: 6px;">
              <div class="bp-skel-shape" style="height: 12px; width: 40%;"></div>
              <div class="bp-skel-shape" style="height: 12px; width: 85%;"></div>
            </div>
          </div>
        <% _ -> %>
          <div style="display: flex; flex-direction: column; gap: 6px;">
            <div :for={w <- [70, 90, 55]} class="bp-skel-shape" style={"height: 12px; width: #{w}%;"}></div>
          </div>
      <% end %>
    </div>
    """
  end

  # ── session lifecycle (mount-lazy, handle_params-driven) ────────────────

  # Fire the AI title generation once per session, on the first successful turn,
  # while the title is still the default (the store makes a human rename
  # authoritative regardless). Fire-and-forget under Barkpark.TaskSupervisor —
  # a failure keeps the default title silently and never touches this LV.
  defp maybe_kick_title(socket) do
    cond do
      socket.assigns[:title_kicked] ->
        socket

      Map.get(socket.assigns, :title_source, "default") != "default" ->
        socket

      true ->
        with sid when is_binary(sid) <- socket.assigns[:store_session_id],
             first when is_binary(first) <- first_user_message(socket) do
          Barkpark.StudioChat.Titles.kick_title(sid, first, self())
          assign(socket, title_kicked: true)
        else
          _ -> socket
        end
    end
  end

  defp first_user_message(socket) do
    case Enum.find(socket.assigns.messages, &(&1.role == :user)) do
      %{text: text} -> text
      _ -> nil
    end
  end

  # Called on the first send with no live subprocess. Fresh chat: mint the
  # session uuid (D2), create the store row, spawn with `--session-id`, and
  # `push_patch` to the session's own URL so it becomes a place. Reopened chat:
  # a store row already exists (store_session_id set by replay) — spawn with
  # `--resume` to rehydrate the CLI's memory. Never eager-respawn; never scrape
  # ids off hook_* frames (D8).
  defp ensure_session(%{assigns: %{session: session}} = socket) when not is_nil(session),
    do: socket

  defp ensure_session(socket) do
    case socket.assigns.store_session_id do
      nil ->
        id = Ecto.UUID.generate()

        # Every session BELONGS to the workspace it is created in — managed and
        # registered-host alike (herd charter D43h: `BlockedSweeper` is
        # fail-closed on NULL owners, so a `nil`-owned session can never fire
        # `chat_blocked`). Stamp the resolved scope workspace, falling back to
        # the seeded Default Workspace; `:global` (a `nil`-owned session) is
        # reserved for a pre-tenancy instance with no Default Workspace.
        scope =
          case socket.assigns[:current_workspace] do
            %{id: ws_id} when is_binary(ws_id) ->
              {:workspace, ws_id}

            _ ->
              case Barkpark.Tenancy.get_default_workspace() do
                %{id: ws_id} -> {:workspace, ws_id}
                nil -> :global
              end
          end

        # De-fanged strict match (charter D24): a create failure must NOT crash
        # the LiveView (a crashed tab restores nothing). Post an honest line and
        # go offline; the caller withdraws the echo and hands the words back.
        case StudioChat.create_session(
               %{
                 id: id,
                 provider: socket.assigns.provider,
                 execution_target: socket.assigns.execution_target,
                 execution_host_id: socket.assigns.execution_host_id,
                 cwd: Runtime.cwd(socket.assigns.provider),
                 mode: socket.assigns.mode
               },
               scope
             ) do
          {:ok, _} ->
            socket
            |> assign(store_session_id: id, session_id: id, status: :working)
            |> push_patch(to: chat_patch_to("#{socket.assigns.chat_base_path}/#{id}", socket))
            |> spawn_session(id, false)

          {:error, reason} ->
            Logger.warning("studio chat: failed to create session row: #{inspect(reason)}")

            socket
            |> append_message(
              :system,
              "⚠ Couldn't start a new chat — the session store is unavailable. Your message was kept; try again."
            )
            |> assign(session: nil, status: :offline)
        end

      id ->
        spawn_session(socket, id, true)
    end
  end

  # Bring the runtime up for `store_id` (fresh: `--session-id`; reopen:
  # `--resume`) — via the RECORDER, never a tab-owned process (wave 4, charter
  # D28). The Recorder is the Session's permanent sink: it persists frames and
  # rebroadcasts them on PubSub, so this tab (and any other on the same
  # session) just subscribes and renders. Closing the tab leaves the runtime
  # running; a spawn error stays honest — the composer never lies about a
  # session that isn't there.
  defp spawn_session(socket, store_id, resume?) do
    # The turn's workspace identity is the SESSION's persisted
    # owner_workspace_id (connectors D206 — mirror chat_controller.ex's
    # `session.owner_workspace_id`), NEVER the ambient current_workspace
    # assign: on the flat /studio/chat route StudioChrome pins that assign to
    # the seeded Default workspace, so a genuinely-:global session would
    # silently inherit the Default workspace's execution profile (D205).
    store_session = get_session_in_tenancy(socket, store_id)

    with {:ok, recorder} <-
           Recorder.ensure(%{
             session_id: store_id,
             provider: socket.assigns.provider,
             provider_session_id: socket.assigns[:provider_session_id],
             execution_target: socket.assigns.execution_target,
             execution_host_id: socket.assigns.execution_host_id,
             workspace_id: store_session && store_session.owner_workspace_id,
             cwd: Runtime.cwd(socket.assigns.provider),
             mode: socket.assigns.mode,
             resume: resume?,
             model:
               Runtime.normalize_choice(
                 socket.assigns.provider,
                 :models,
                 socket.assigns[:model_choice]
               ),
             effort:
               Runtime.normalize_choice(
                 socket.assigns.provider,
                 :efforts,
                 socket.assigns[:effort_choice]
               ),
             # The chat admin's principal (charter D63): the Session mints its
             # loopback bp-mcp credential from this — never exceeding the
             # human's own rights; absent ⇒ no hands, chat unchanged.
             minter: socket.assigns[:api_token] || socket.assigns[:current_user],
             # Bypass arming is a LIVE act (charter D55): the dangerous flag
             # rides ONLY when the type-"bypass" ceremony ran THIS lifetime
             # (`bypass_live_armed`) AND the persisted row is bypassPermissions.
             # A reopened bypass session has the mode but not the live token, so
             # it fail-closes to plan (build_args' normalize path, D48b) until
             # the user re-runs the ceremony — the persisted mode alone can never
             # silently re-arm.
             bypass_armed:
               socket.assigns[:bypass_live_armed] == true and
                 StudioChat.bypass_armed?(store_id)
           }),
         {:ok, session} <- Recorder.session_pid(recorder) do
      StudioChat.update_status(store_id, "working")
      # Ready as soon as the subprocess is up. The CLI emits its init event
      # only when the FIRST turn starts — gating the composer on init would
      # deadlock the tab (nothing sent → no init → composer never enables).
      socket
      |> subscribe_session(store_id)
      |> assign(session: session, status: :ready)
      # Late-join the slash vocabulary (charter D36a): the initialize ack may
      # have already landed on the Recorder before we subscribed, so read the
      # held list now; the broadcast covers the ack that arrives after.
      |> assign(commands: Recorder.advertised_commands(recorder))
      # bp-lane readiness (chat-task-hands, charter D2): the task-hands mint
      # happens AT spawn, so this is the moment its outcome is queryable — a
      # refused/expired mint surfaces the onboarding card as a banner beside
      # the (still live) composer, never a silent Logger.warning.
      |> observe_hands_state(session)
      |> refresh_sessions()
    else
      {:error, reason} ->
        socket
        |> append_message(:system, spawn_error_text(reason))
        # Keep the onboarding card in step with the spawn truth: a spawn that
        # died on a missing binary flips the card to :no_binary, so the next
        # step renders beside the honest system line (charter D2).
        |> maybe_flip_readiness(reason)
        |> assign(session: nil, status: :offline)
    end
  end

  # Spawn-failure → readiness-card mapping. Only reasons the card has a named
  # state for; anything else leaves the current readiness (the system line
  # from spawn_error_text/1 already spoke).
  defp maybe_flip_readiness(socket, :binary_not_found), do: assign(socket, readiness: :no_binary)
  defp maybe_flip_readiness(socket, _reason), do: socket

  # Follow exactly one session's frame topic at a time (PubSub). Idempotent for
  # the same session; switching sessions swaps the subscription — never two
  # topics at once (a stray frame from a previous chat must not render here).
  defp subscribe_session(socket, store_id) do
    current = socket.assigns[:subscribed_topic]
    topic = Recorder.topic(store_id)

    cond do
      current == topic ->
        socket

      true ->
        if current, do: Phoenix.PubSub.unsubscribe(Barkpark.PubSub, current)
        if connected?(socket), do: Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
        assign(socket, subscribed_topic: topic)
    end
  end

  # The global activity feed (wave 5) — one subscription per tab, at mount.
  defp subscribe_activity(socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

    socket
  end

  defp unsubscribe_session(socket) do
    if t = socket.assigns[:subscribed_topic],
      do: Phoenix.PubSub.unsubscribe(Barkpark.PubSub, t)

    assign(socket, subscribed_topic: nil)
  end

  # Undo the optimistic echo (charter D24): drop exactly the pending echo row and
  # hand the words back to the composer verbatim so nothing is lost. Status/system
  # lines are the caller's to set (they differ per failure). A no-op when there is
  # no pending echo (idempotent).
  defp restore_failed_send(socket, text) do
    echo_id = socket.assigns[:pending_echo_id]

    socket
    |> assign(composer_draft: text, pending_echo_id: nil)
    |> assign_messages(Enum.reject(socket.assigns.messages, &(&1.id == echo_id)))
  end

  # ── chat-never-vanishes readiness (chat-task-hands, charter D2/decision 4) ──
  #
  # The onboarding card's state machine. `@readiness` is one of:
  #
  #   :checking           probe in flight — quiet strip, composer stays live
  #   :no_binary          claude lane: the CLI is not on PATH   (locks composer)
  #   :not_logged_in      claude lane: CLI present, not authed  (locks composer)
  #   :no_task_hands      bp lane: the task-credential mint was refused
  #   :task_token_expired bp lane: the minted task credential expired
  #   :task_token_rearmed bp lane: renewed — restart to re-arm the shell lane
  #   :ready              live composer
  #
  # The two claude-lane states REPLACE the composer (there is nothing to send
  # to); the two bp-lane states render as a banner BESIDE the live composer —
  # the chat itself still works, only its task hands are offline, and locking
  # the whole chat for a bp-side problem would be its own vanish (the wish).

  defp kick_readiness_probe(socket) do
    socket = assign(socket, readiness: :checking)
    provider = socket.assigns.provider

    if connected?(socket) do
      start_async(socket, :readiness_probe, fn -> compute_readiness(provider, nil) end)
    else
      socket
    end
  end

  # Probe seam (config-injectable for deterministic tests — the same idiom as
  # the fake-binary `:command` override). `:studio_chat_readiness_probe` may be
  # `{:static, state}` or a 0-arity fun; absent ⇒ the real provider-neutral
  # probe. Runs INSIDE the start_async task, never on the LiveView process
  # (the claude auth shell-out costs ~1–2s, charter Verified ground).
  defp compute_readiness(provider, session) do
    case Application.get_env(:barkpark, :studio_chat_readiness_probe) do
      {:static, state} when is_atom(state) -> state
      fun when is_function(fun, 0) -> fun.()
      _ -> with(:ready <- provider_readiness(provider), do: hands_readiness(provider, session))
    end
  end

  defp provider_readiness(provider) do
    probe = Runtime.readiness(provider)
    probe = if match?({:ok, _}, probe), do: elem(probe, 1), else: probe

    cond do
      not is_map(probe) -> :no_binary
      Map.get(probe, :binary) != true -> :no_binary
      Map.get(probe, :authed?) != true -> :not_logged_in
      true -> :ready
    end
  end

  # bp-lane readiness from the spawn-time mint outcome. Pre-spawn (no session)
  # there is nothing to ask — the mint happens AT spawn (charter decision 2) —
  # so a nil session reads :ready and observe_hands_state/2 covers the spawn
  # moment. The default reads the spawn-env slice's queryable mint state
  # (provider `task_hands/1`: :minted | :mint_refused | :not_attempted |
  # :unknown); the config seam injects a verdict for deterministic tests.
  # `:expired` and `:rearmed` are now REAL provider verdicts, not seam-only
  # placeholders (task-cth-bl-token-renewal): the session reads its own
  # credential's clock, renews through the same mint before expiry, and reports
  # `:rearmed` afterwards because a live child's environment still carries the
  # retired value.
  defp hands_readiness(provider, session) do
    readiness_for_hands(hands_state(provider, session))
  end

  # One verdict->card mapping, shared by the probe path and the pushed
  # `{:claude_chat_task_hands, verdict}` frame, so a renewal that lands
  # mid-conversation and a Re-check can never disagree.
  defp readiness_for_hands(state) when state in [:refused, :mint_refused], do: :no_task_hands
  defp readiness_for_hands(:expired), do: :task_token_expired
  defp readiness_for_hands(:rearmed), do: :task_token_rearmed
  defp readiness_for_hands(_), do: :ready

  defp hands_state(_provider, nil), do: :ok

  defp hands_state(provider, session) do
    case Application.get_env(:barkpark, :studio_chat_hands_state) do
      fun when is_function(fun, 1) -> fun.(session)
      _ -> Runtime.task_hands(provider, session)
    end
  catch
    # A session that died between spawn and query is not a hands verdict.
    :exit, _ -> :ok
  end

  defp observe_hands_state(socket, session) do
    case hands_readiness(socket.assigns.provider, session) do
      :ready -> socket
      state -> assign(socket, readiness: state)
    end
  end

  # Flip the card to :not_logged_in off a live-stream auth failure (charter
  # decision 5). Idempotent: the frames arrive as a pair (assistant + result),
  # and the honest system line must land once, not twice.
  defp flag_auth_failure(socket) do
    if socket.assigns[:readiness] == :not_logged_in do
      socket
    else
      socket
      |> assign(readiness: :not_logged_in)
      |> append_message(
        :system,
        "⚠ Claude isn't logged in on this host — the turn ended unauthenticated. " <>
          "Run `claude auth login` on this host, then Re-check below."
      )
    end
  end

  # The claude-lane states lock the composer (no CLI to talk to); everything
  # else keeps it live — :checking optimistically (the common case is :ready),
  # the bp-lane states because the chat itself still works.
  defp composer_locked?(readiness), do: readiness in [:no_binary, :not_logged_in]

  # Drop the phase-1 text-only echo WITHOUT restoring the composer — used when a
  # dispatched turn carries images (D25) and the echo upgrades to the full
  # text+thumbnails bubble. A no-op when there is no pending echo.
  defp withdraw_pending_echo(socket) do
    echo_id = socket.assigns[:pending_echo_id]

    socket
    |> assign(pending_echo_id: nil)
    |> assign_messages(Enum.reject(socket.assigns.messages, &(&1.id == echo_id)))
  end

  # Replay a remembered session from our own store. Runtime-aware (charter
  # D22/D28): if this session's Recorder is still running, the tab co-views it
  # live (PubSub) and the replayed pending approval cards stay answerable
  # through the running session pid. Only a session with NO live runtime is
  # truly dead; there (and only there) we cancel-persist its dangling approvals
  # and go display-only until the next send lazy-resumes.
  defp load_stored_session(socket, session) do
    # Navigating away NEVER tears the previous session down (wave 4, charter
    # D28): its Recorder owns the runtime; we only stop listening to it.
    socket = socket |> unsubscribe_session() |> subscribe_session(session.id)

    {session_pid, status, live?} =
      case live_runtime(session) do
        nil ->
          # No live runtime: a still-"pending" approval can never be answered,
          # so persist its cancellation BEFORE replay — the store then agrees
          # with the canceled cards on screen and the sidebar "needs you" pill
          # drops (D11). Replay is display-only (status :resumable).
          StudioChat.cancel_pending_approvals(session.id)
          {nil, :resumable, false}

        session_pid ->
          # Live: the Recorder keeps driving; this tab co-views via PubSub
          # (already subscribed above) and the replayed pending approval cards
          # stay answerable through the running session pid. A mid-turn reopen
          # shows a brief gap until the next frame (accepted gap: the Session
          # never snapshots streaming/turn state).
          {session_pid, :ready, true}
      end

    messages = replay_messages(session.id, live?)

    assign(socket,
      session: session_pid,
      store_session_id: session.id,
      session_id: session.id,
      provider: session.provider || "claude",
      execution_target: session.execution_target || "managed",
      execution_host_id: session.execution_host_id,
      provider_session_id: session.provider_session_id,
      mode: session.mode || "plan",
      model_choice: session.model_choice || "default",
      effort_choice: session.effort_choice || "default",
      # A reopen resets any in-flight arm ceremony — arming is never carried
      # across a session load (charter D48). Bypass arming is a LIVE act
      # (charter D55): the live token drops to false on every reopen, so a
      # remembered bypassPermissions session is DISARMED until the ceremony
      # re-runs. When the reopened row is bypass, auto-open the arm panel with an
      # honest "disarmed" line — the selector keeps showing bypassPermissions but
      # the next resume fail-closes to plan until the user re-arms.
      # HONESTY GATE: only when there is NO live runtime. A live adopted process
      # (D22) is running under ITS spawn-time arming — telling the user it is
      # "disarmed — re-arm to enable" while an armed process is mid-turn would
      # be false, and re-arming applies only at the next spawn anyway. The live
      # token above still drops, so once that runtime dies the next respawn
      # fail-closes exactly the same.
      arming_bypass: reopened_bypass?(session) and not live?,
      bypass_confirm: "",
      bypass_live_armed: false,
      bypass_disarmed: reopened_bypass?(session) and not live?,
      status: status,
      init: replay_init(session),
      messages: messages,
      # Grouped rows memoized at load time (task-9e21c3f285b3d7d0) — the template
      # reads `@grouped_rows`, so reopen does the grouping ONCE, not per render.
      grouped_rows: grouped_rows(messages),
      # A reopen groups from scratch; the memo starts empty and the first live
      # append rebuilds it, after which every append is tail-bounded.
      grouping_cache: empty_grouping_cache(),
      # Sticky draft (charter D36c): restore the unsent words left behind when
      # this session was last switched away from (nil column → clean composer).
      # From the FULL struct — list_sessions omits `draft`.
      composer_draft: session.draft || "",
      # A live runtime may already hold the CLI's advertised slash commands
      # (charter D36a) — read the held list on reopen; a dead session floors to
      # builtins (empty advertised list).
      commands: runtime_commands(session.id),
      # Strictly past every replayed id (seqs are 1-based), so a live append
      # never collides with a replayed message's id.
      next_id: Enum.reduce(messages, 0, &max(&1.id, &2)) + 1,
      # A reopen starts no turn — the next live TodoWrite opens a fresh card
      # (charter D39). A replayed todo row is already the final collapsed state.
      todo_card_id: nil,
      streaming: nil,
      thinking_pulse: nil,
      interrupt_requested: false,
      pending_mode: nil,
      last_result: nil,
      # Reopen must show the last-known headroom (charter D19) — read the snapshot
      # off the stored row; nil window renders hollow, never a fake arc.
      ring: ring_from_session(session),
      # Title state follows the STORED session: a titled (ai/human) session
      # never re-kicks; a still-default one may kick on its next good turn.
      title_source: session.title_source || "default",
      title_kicked: false,
      # Any half-open sidebar affordance is stale after a navigation.
      renaming_session: nil,
      open_menu_session: nil,
      # Plan-card expand state is per-tab and per-session (charter D34) — a reopen
      # starts every replayed plan collapsed.
      plan_expanded: MapSet.new(),
      # Agent drill-down overrides reset on reopen (charter D46): a replayed
      # terminal agent starts collapsed to its report, a mid-run one open.
      agent_expanded: %{},
      # Turn folds reset on reopen (task-8f904a88b9bc3d59): a replayed settled
      # turn starts collapsed under its "Worked for …" header.
      turn_folds_expanded: MapSet.new(),
      # And a reopened transcript's running fold starts collapsed too
      # (task-b66928b2958c8cfa) — a reopen has no running turn at all.
      running_fold_expanded: false,
      # Rail replay parity (charter D47): hydrate the mission-control rail from
      # the stored `rail_snapshot` so a reopened session shows its last-known
      # agents. `interrupt_running_tasks/1` already flipped any dead "running"
      # entry to "interrupted" on teardown, so this never shows a fake spinner.
      rail: session.rail_snapshot || %{},
      rail_sig: StudioChat.rail_signature(session.rail_snapshot || %{}),
      rail_expanded: %{},
      # Per-agent drill-down overrides reset on reopen (wsc-ad, rail_expanded
      # precedent): a replayed rail starts every agent detail collapsed.
      agent_detail_expanded: %{},
      # The reopened session's own sticky draft is restored above (charter D36c);
      # only the in-flight echo of the session we LEFT is stale here.
      pending_echo_id: nil,
      # Fresh question-answer scratch state — any half-filled form belonged to the
      # session we navigated away from. Replayed pending question cards under a
      # live owner (D22) re-seed their form lazily as the user interacts.
      question_forms: %{}
    )
    # Both branches mutate the stored row (cancel-persist, or mark "working" on
    # adopt), so re-read the sidebar list once — the pending pill and the working
    # pill both stay honest on reopen.
    |> refresh_sessions()
    # A reopened session's rehydrated terminal entries each get the same
    # per-entry auto-dismiss a live one earns (charter D47) — replay shows the
    # last-known rail, then each settled entry ages out ~90s later instead of
    # re-squatting. `old_rail = %{}` treats every rehydrated entry as a fresh
    # settle; running entries (never flipped by `interrupt_running_tasks/1`) are
    # left alone. The stored `rail_snapshot` is untouched.
    |> then(fn s -> schedule_entry_prunes(s, %{}, s.assigns.rail) end)
    # The Doing strip follows the SESSION's worker — re-read its held claims
    # off the ledger so a reopen shows in-flight task work immediately.
    |> assign(task_picker: nil)
    |> hydrate_hand_tasks()
    |> assign_context_identity()
  end

  # A reopened session whose persisted mode is bypassPermissions (charter D55).
  # Drives the auto-opened, honest "bypass disarmed — re-arm to enable" panel:
  # the mode survives in the store (the selector keeps showing it) but arming
  # never survives a reopen, so the panel tells the user to re-run the ceremony.
  defp reopened_bypass?(%{mode: "bypassPermissions"}), do: true
  defp reopened_bypass?(_), do: false

  # The live SESSION pid for a store id, reached through its Recorder — or nil.
  # Charter D22/D28: consulted BEFORE any store write so a reopen of a session
  # whose runtime is still running keeps its pending approvals answerable
  # instead of cancelling them. A recorder that dies between lookup and the
  # session_pid call is treated as no runtime.
  defp live_runtime(session) do
    with recorder when is_pid(recorder) <- Recorder.whereis(session.id),
         {:ok, runtime_ref} <- Recorder.session_pid(recorder),
         true <- Runtime.alive?(runtime_ref) do
      runtime_ref
    else
      _ -> nil
    end
  end

  # The advertised slash commands a session's live Recorder is holding (charter
  # D36a) — the vocabulary a reopened LIVE session already knows. `[]` for a dead
  # or absent runtime (the composer floors to builtins).
  defp runtime_commands(session_id) do
    case Recorder.whereis(session_id) do
      recorder when is_pid(recorder) -> Recorder.advertised_commands(recorder)
      _ -> []
    end
  end

  # The new-chat empty state: no store row, nothing subscribed. A previously-
  # viewed session's runtime keeps running under its Recorder (wave 4) — we
  # only stop listening to it.
  defp reset_to_new_chat(socket) do
    socket = unsubscribe_session(socket)

    assign(socket,
      session: nil,
      store_session_id: nil,
      session_id: nil,
      # No session → no worker → no held claims; the picker is per-view UI.
      hand_tasks: %{},
      # A new chat is a new conversation: it has touched no task and rendered
      # no transition, so BOTH the scope set and the idempotency set reset.
      touched_tasks: MapSet.new(),
      seen_task_events: MapSet.new(),
      task_picker: nil,
      mode: "plan",
      provider: "claude",
      execution_target: "managed",
      execution_host_id: nil,
      provider_session_id: nil,
      # Sticky model default (charter D36d): a new chat inherits the last
      # non-default model you picked, via a DEDICATED query (list_sessions omits
      # model_choice — seeding off it reads nil forever). nil → "default".
      model_choice: StudioChat.recent_model_choice() || "default",
      # Sticky effort default (charter D48), the exact mirror — a dedicated query,
      # never list_sessions (which omits effort_choice). nil → "default".
      effort_choice: StudioChat.recent_effort_choice() || "default",
      arming_bypass: false,
      bypass_confirm: "",
      # A new chat is never armed (charter D55) — the live token starts false.
      bypass_live_armed: false,
      bypass_disarmed: false,
      status: :new,
      init: nil,
      messages: [],
      grouped_rows: [],
      grouping_cache: empty_grouping_cache(),
      next_id: 0,
      todo_card_id: nil,
      streaming: nil,
      thinking_pulse: nil,
      # A new chat has no runtime yet, so no advertised commands — the slash menu
      # floors to builtins until the first send spawns + initializes (D36a).
      commands: [],
      interrupt_requested: false,
      pending_mode: nil,
      last_result: nil,
      ring: blank_ring(),
      title_source: "default",
      title_kicked: false,
      renaming_session: nil,
      open_menu_session: nil,
      plan_expanded: MapSet.new(),
      agent_expanded: %{},
      # A new chat has no settled turns yet (task-8f904a88b9bc3d59).
      turn_folds_expanded: MapSet.new(),
      # A new chat has no running turn to fold yet (task-b66928b2958c8cfa).
      running_fold_expanded: false,
      # A new chat has no background agents yet (charter D47).
      rail: %{},
      rail_sig: [],
      rail_expanded: %{},
      agent_detail_expanded: %{},
      composer_draft: "",
      pending_echo_id: nil,
      question_forms: %{}
    )
    |> assign_context_identity()
  end

  # Is `title` for `session_id` ALREADY what the sidebar shows? The duplicate-
  # delivery guard for `{:chat_title, …}`: the Recorder publishes one accepted
  # write on two topics this LiveView subscribes to, and the repeat must not
  # re-read the store. A session absent from the list (a row this tenant cannot
  # see, or a list not yet loaded) is NOT "rendered", so it falls through to the
  # refresh — the guard only ever suppresses a no-op.
  defp title_rendered?(socket, session_id, title) do
    Enum.any?(
      socket.assigns[:sessions] || [],
      &(&1.id == session_id and &1.title == title)
    )
  end

  defp refresh_sessions(socket) do
    # The sidebar LIST. The store call stays `:global` and the tenant clamp is
    # applied HERE — `StudioChat`'s own workspace scope is a strict
    # `owner_workspace_id == ^ws` equality that would ALSO delete every
    # NULL-owned legacy row from the sidebar (see `owner_in_tenancy?/2` for the
    # full argument), and on the flat superuser mount there is no clamp at all.
    # Clamping BEFORE the folds below is deliberate: `workflow_summaries`,
    # `epic_goals` (which queries the task ledger per row) and
    # `pending_ask_roles` all derive from this list, so a row filtered here can
    # never reach a per-tenant count rendered into the page.
    sessions =
      [archived: socket.assigns[:show_archived] == true]
      |> StudioChat.list_sessions(:global)
      |> clamp_list_to_tenancy(socket)

    # Cold workflow truth (wsc charter D7): the select-widened rail_snapshot
    # folds to the compact D3 summary HERE, and the snapshot itself never
    # rides an assign (stripped below). Plain sessions (nil summary) pay zero.
    workflow_summaries =
      for s <- sessions, summary = StudioChat.workflow_summary(s.rail_snapshot), into: %{} do
        {s.id, summary}
      end

    # The epic-goal line (wsc charter D9): computed ONLY for workflow rows —
    # a sidebar of plain chats never queries the ledger.
    epic_goals =
      for s <- sessions, Map.has_key?(workflow_summaries, s.id), into: %{} do
        {s.id, StudioChat.epic_goal(s.provider, s.id)}
      end

    sessions = Enum.map(sessions, &%{&1 | rail_snapshot: nil})

    # The needs-you strip's store-truth half (wave 12): the pending ask ROLES of
    # every listed session whose denormalised counter says the agent needs the
    # human — one grouped query, only for the rows that can carry a needs-you
    # kind. Loaded together with `sessions` so the two assigns never drift.
    pending_ids =
      for s <- sessions, is_integer(s.pending_approvals) and s.pending_approvals > 0, do: s.id

    assign(socket,
      sessions: sessions,
      workflow_summaries: workflow_summaries,
      epic_goals: epic_goals,
      pending_ask_roles: StudioChat.pending_ask_roles(pending_ids)
    )
  end

  # Re-read the epic-goal lines for every workflow row (cold ∪ live overlay) —
  # the sibling document_changed step (wsc charter D9) lands here when the epic
  # parent's heartbeat moves.
  defp refresh_epic_goals(socket) do
    ids =
      MapSet.union(
        MapSet.new(Map.keys(socket.assigns.workflow_summaries)),
        MapSet.new(Map.keys(socket.assigns.workflow))
      )

    goals =
      for s <- socket.assigns.sessions, MapSet.member?(ids, s.id), into: %{} do
        {s.id, StudioChat.epic_goal(s.provider, s.id)}
      end

    assign(socket, epic_goals: goals)
  end

  # A row-level archive/delete. Always refresh the sidebar; when the mutated row
  # is the ON-SCREEN session, push_patch to /studio/chat so `handle_params/3`
  # (the single source of truth) re-resets to the clean new-chat state — a
  # background row leaves the open session untouched. The refreshed session list
  # survives the patch (reset_to_new_chat never re-lists), so the deleted row is
  # gone from the sidebar too.
  # ── Tenancy confinement for the id-addressed lifecycle clauses ─────────────
  #
  # These four clauses take a session id straight off the wire. The flat
  # `/studio/chat` route rides `LiveAuth.:admin`, a GLOBAL-permission gate that
  # never reads the acting token's workspace binding, so "this socket mounted"
  # says nothing about which tenant's rows it may touch. Before this guard a
  # workspace-bound admin token could rename, archive and DELETE another
  # workspace's chat sessions by id.
  #
  # The predicate refuses ONE thing: a row owned by a workspace that is not the
  # principal's. It deliberately does NOT narrow to the principal's workspace
  # wholesale — a NULL `owner_workspace_id` is a legacy / pre-tenancy row and
  # stays reachable, which is the admin superuser path charter D17/D18 asks for
  # and what the sidebar has always shown. Note that `Auth.create_token/5`
  # defaults an omitted workspace to the Default workspace, so almost every
  # token IS bound; narrowing on the binding alone would have made every legacy
  # row unmanageable.
  defp tenancy_permits?(socket, id) do
    case principal_workspace_id(socket) do
      # No binding at all (no Default workspace) — the genuine :global superuser.
      nil ->
        true

      ws_id ->
        case StudioChat.get_session(id, :global) do
          %{owner_workspace_id: owner} when is_binary(owner) -> owner == ws_id
          # Missing row, or a legacy NULL-owned one: not a cross-tenant reach.
          _ -> true
        end
    end
  end

  # ── The acting tenant for a READ, and the permitted set it may see ────────
  #
  # ChatLive is DUAL-MOUNTED and the two mounts prove DIFFERENT things:
  #
  #   * flat `/studio/chat` (`live_session :admin_studio`) — `{LiveAuth, :admin}`,
  #     an INSTANCE-wide permission gate. This is the `:global` superuser path
  #     charter D17/D18 reserves, and `chat_live_test.exs`'s "tenant seam" case
  #     pins it: the flat sidebar surfaces sessions of EVERY owner. Nothing here
  #     narrows it — `nil` means no clamp. The cross-tenant WRITE reach on that
  #     route is a separate question, already answered by `tenancy_permits?/2`.
  #
  #   * scoped `/w/:ws/p/:proj/studio/chat` (`live_session :scoped_admin_studio`)
  #     — `{LiveAuth, :scoped_admin}`, which proves owner/admin membership in the
  #     URL WORKSPACE and NOTHING MORE. A workspace-B admin is not an instance
  #     admin. THIS is the mount the carve-out comment was never written for, and
  #     the reason it went stale: it predates the scoped mount entirely.
  #
  # On that scoped mount the acting tenant is `:current_workspace`, which
  # `LiveScope.:resolve` pins to the authorized URL workspace before this
  # LiveView's `mount/3` runs (it short-circuits both of StudioChrome's flat
  # fallbacks). It is also the very assign `ensure_session/1` reads to stamp
  # `owner_workspace_id` on a session it CREATES — so the reads stop disagreeing
  # with the write beside them. `principal_workspace_id/1` is the fallback for a
  # scoped socket with no resolved workspace, which narrows rather than opens.
  defp read_workspace_id(socket) do
    if socket.assigns[:scoped_mount?] do
      case socket.assigns[:current_workspace] do
        %{id: ws_id} when is_binary(ws_id) -> ws_id
        _ -> principal_workspace_id(socket)
      end
    end
  end

  # The PERMITTED SET for a read: the acting workspace's own rows PLUS
  # `NULL`-owned legacy / pre-tenancy rows — the same permitted set
  # `tenancy_permits?/2` grants a WRITE, for the same reason it gives there.
  #
  # Note what this deliberately is NOT: `StudioChat.list_sessions/2` and
  # `get_session/2` handed a bare workspace binary. That store gate is a strict
  # `owner_workspace_id == ^ws` equality (documented in `studio_chat.ex`, with
  # `StudioChat.scope_match?/2` as its term twin), so a NULL owner never matches
  # and every pre-tenancy session would VANISH the moment these loaders stopped
  # saying `:global`. `Auth.create_token/5` defaults an omitted workspace to the
  # seeded Default, so nearly every token IS bound and that vanishing would be
  # the common case, not the edge. The store has no "mine-or-unowned" scope to
  # ask for, so the clamp is made HERE.
  defp owner_in_tenancy?(socket, owner) do
    case read_workspace_id(socket) do
      nil -> true
      ws_id -> is_nil(owner) or owner == ws_id
    end
  end

  defp session_in_tenancy?(socket, %{owner_workspace_id: owner}),
    do: owner_in_tenancy?(socket, owner)

  defp session_in_tenancy?(_socket, _other), do: false

  # `StudioChat.get_session/2` clamped to that permitted set: a row outside this
  # socket's tenancy reads back as `nil`, indistinguishable from a row that does
  # not exist — so `handle_params/3` takes its existing "no longer available"
  # branch rather than growing a second refusal path.
  defp get_session_in_tenancy(socket, id) do
    case StudioChat.get_session(id, :global) do
      %{} = session -> if session_in_tenancy?(socket, session), do: session
      _ -> nil
    end
  end

  # The SIDEBAR arm of the same rule — and it cannot reuse `session_in_tenancy?/2`
  # directly, for a reason that is invisible in the source and was caught only by
  # running it:
  #
  #   `StudioChat.list_sessions/2` carries a narrowing `select` of the sidebar
  #   columns, and `owner_workspace_id` is NOT one of them. Every row it returns
  #   therefore carries `owner_workspace_id: nil` — the struct default for a
  #   field that was never selected, indistinguishable from a genuine NULL owner.
  #   Filtering that projection on the owner field reads EVERY row as a
  #   NULL-owned legacy row and removes nothing. The same trap swallows
  #   `StudioChat.scope_match?/2`, the documented term twin, if it is handed a
  #   `list_sessions/2` row.
  #
  # So ownership is RE-READ for the listed ids instead of trusted from the
  # projection: ONE bounded query (`list_sessions/2` caps at 50 rows), never a
  # per-row `get_session/2`. The one-line alternative — adding
  # `owner_workspace_id: s.owner_workspace_id` to that select — lives inside
  # `Barkpark.StudioChat` and is deliberately not taken from here.
  #
  # A `nil` read scope (the flat superuser mount) short-circuits before the extra
  # query, so that path pays nothing.
  defp clamp_list_to_tenancy(sessions, socket) do
    if is_nil(read_workspace_id(socket)) do
      sessions
    else
      owners = session_owners(Enum.map(sessions, & &1.id))
      Enum.filter(sessions, &owner_in_tenancy?(socket, Map.get(owners, &1.id)))
    end
  end

  defp session_owners([]), do: %{}

  defp session_owners(ids) do
    import Ecto.Query, only: [from: 2]

    from(s in StudioChat.Session,
      where: s.id in ^ids,
      select: {s.id, s.owner_workspace_id}
    )
    |> Barkpark.Repo.all()
    |> Map.new()
  end

  defp principal_workspace_id(socket) do
    case socket.assigns[:api_token] do
      %{workspace_id: ws_id} when is_binary(ws_id) -> ws_id
      _ -> nil
    end
  end

  # `:noop` is `delete_session/2`'s own "nothing to delete" return, so a refused
  # cross-tenant delete takes the existing success-or-noop branch and the flash
  # stays reserved for the real FK-protected case.
  defp delete_within_tenancy(socket, id) do
    if tenancy_permits?(socket, id) do
      StudioChat.delete_session(id, :global)
    else
      :noop
    end
  end

  defp after_lifecycle_mutation(socket, id) do
    socket = socket |> assign(open_menu_session: nil) |> refresh_sessions()

    if socket.assigns.store_session_id == id do
      push_patch(socket, to: chat_patch_to(socket.assigns.chat_base_path, socket))
    else
      socket
    end
  end

  # ── ONE navigation path to a session (T3 keybindings parity) ─────────────
  #
  # The sidebar <.link patch={…}>, the palette's Enter, and Cmd/Ctrl+1..9 ALL
  # build their destination here. A second copy of this URL shape is how the
  # keyboard and the mouse drift apart (one keeps `return_to`, the other drops
  # it); the test suite asserts the sidebar link's href and the keyboard patch
  # are byte-identical for the same session.
  #
  # Takes `assigns` (not a socket) so the HEEx template and the event handlers
  # call the SAME function.
  defp session_link_path(assigns, session_id) do
    ReturnTo.with_return_to("#{assigns.chat_base_path}/#{session_id}", assigns[:return_to])
  end

  defp activate_session(socket, session_id) do
    push_patch(socket, to: session_link_path(socket.assigns, session_id))
  end

  # The Nth VISIBLE sidebar row, 1-indexed. `@sessions` IS the visible list
  # (refresh_sessions/1 already applied the archived shelf and the tenant
  # clamp), so "visible" needs no second definition here.
  defp activate_nth_session(socket, n) do
    case nth_index(n) do
      nil ->
        socket

      i ->
        case Enum.at(socket.assigns.sessions, i) do
          nil -> socket
          session -> activate_session(socket, session.id)
        end
    end
  end

  # 1..9 only, from either a JSON number or a string — anything else is not a
  # jump. Returns the 0-based index.
  defp nth_index(n) when is_integer(n) and n >= 1 and n <= 9, do: n - 1

  defp nth_index(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> nth_index(i)
      _ -> nil
    end
  end

  defp nth_index(_), do: nil

  # Carry the validated `return_to` across a self-`push_patch` (charter D5), so
  # the flat chat surface never loses the scope it should return to as the user
  # opens/closes sessions inside it.
  defp chat_patch_to(path, socket) do
    ReturnTo.with_return_to(path, socket.assigns[:return_to])
  end

  # ONE idempotent honest teardown for a dead/wedged subprocess (charter D18),
  # shared by the port-exit handler, the interrupt-timeout guard, and the DOWN
  # handler. Fail the in-flight turn (drop the streaming buffer), force-cancel
  # EVERY pending approval — their control-response can never be delivered, so a
  # hanging Allow/Deny would be a dead button — mark the persisted session exited
  # (nil-safe), and go offline. The CLI keeps the memory: the next send
  # lazy-resumes. Idempotent: already `:offline` ⇒ no-op, so a close-then-DOWN
  # double-fire never duplicates the system line or re-cancels approvals.
  # UI-only since wave 4 (charter D28): the STORE side of a session's death —
  # cancel-persisting pending approvals, marking the row exited — is the
  # Recorder's job (it owns the runtime and outlives every tab). This flips the
  # visible cards, posts the honest line, and re-reads the sidebar.
  # A nonzero OS exit status (integer). The crash/idle-reap paths carry an atom
  # (`:crashed`/`:idle_reaped`) and never count as a rejected-argv start.
  defp failed_start?(status), do: is_integer(status) and status != 0

  # The captured stderr tail, trimmed for display; nil-safe for the paths that
  # carry no stderr (already bounded to a few lines at the Session, charter D54).
  defp stderr_reason(tail) when is_binary(tail), do: String.trim(tail)
  defp stderr_reason(_), do: ""

  defp teardown_session(socket, message) do
    if socket.assigns.status == :offline do
      socket
    else
      messages =
        Enum.map(socket.assigns.messages, fn
          %{role: role, approval_status: :pending} = m when role in @needs_you_roles ->
            %{m | approval_status: :canceled}

          m ->
            m
        end)

      socket
      |> assign_messages(messages)
      |> append_message(:system, message)
      |> assign(
        session: nil,
        status: :offline,
        streaming: nil,
        thinking_pulse: nil,
        interrupt_requested: false
      )
      |> refresh_sessions()
    end
  end

  # The mode to fall back to if the pending switch fails: the last known-good
  # mode. When a switch is already in flight, keep ITS revert target (the mode
  # confirmed before the chain started) rather than the current optimistic value
  # — otherwise a failed second switch would revert to an unconfirmed first.
  defp revert_target(socket) do
    case socket.assigns[:pending_mode] do
      %{revert_to: rt} -> rt
      _ -> socket.assigns.mode
    end
  end

  # Adopt the mode the CLI reports on `system/init` (charter D34). Approving a
  # plan makes the CLI flip its OWN permission mode (plan → default) inside the
  # ExitPlanMode tool — we send NO `set_permission_mode` follow-up, and the flip
  # is invisible on the terminal `result` frame (its `permission_mode` is null;
  # asserting there is vacuous-green). The ONLY honest signal is the NEXT turn's
  # init `permissionMode`. When it differs from the mode we hold, adopt it and
  # persist via `set_mode/2` so a reopen and the next lazy `--resume` spawn both
  # carry the post-plan mode. Skipped while a user-initiated switch is in flight
  # (its ack owns the mode, charter D17/D23) and for any unknown/echoed-same
  # value, so a routine init never churns the selector.
  # Adopt the mode the CLI actually reports off an init frame. `default` is NOT
  # handled here anymore: the post-plan flip (plan → default, charter D34/D52)
  # is now the Recorder's seam — it observes the same init frame, engages
  # Autopilot (steer + persist), and broadcasts `{:studio_chat_mode_adopted, …}`
  # which this LiveView renders. Only bypassPermissions stays excluded — the
  # fail-closed law (D48): an echoed frame is an untrusted string and must
  # never arm dangerous bypass.
  defp observe_permission_mode(socket, mode)
       when is_binary(mode) and mode in ~w(plan acceptEdits auto dontAsk manual) do
    cond do
      mode == socket.assigns.mode or not is_nil(socket.assigns[:pending_mode]) ->
        socket

      # A DISARMED bypassPermissions session deliberately spawns fail-closed
      # (charter D48b/D55): build_args normalizes the mode, so the init frame
      # echoing that normalized mode is OUR OWN fail-close, not a CLI-side flip.
      # Stay quiet and — critically — do NOT adopt/persist it: the stored
      # bypassPermissions row is what keeps the re-arm affordance alive on the
      # next reopen (D55's honest disarmed panel).
      mode == Runtime.normalize_mode(socket.assigns.provider, socket.assigns.mode) ->
        socket

      true ->
        if store_id = socket.assigns[:store_session_id], do: StudioChat.set_mode(store_id, mode)

        # No silent escalation (charter D52, wave-10 real-binary verdict): the CLI
        # flips its OWN permission mode plan → default inside ExitPlanMode (PROVEN
        # v2.1.205 — the post-plan init reports `"default"`), a mode the user never
        # picked. A user-initiated switch surfaces its own "Permission mode → …"
        # line (via set-mode); this CLI-initiated adoption was previously SILENT.
        # Surface it too, so the transcript never quietly changes what the agent is
        # allowed to do. `pending_mode` guards this off during a user switch (its
        # ack owns the mode, D17/D23), so this line only ever narrates a genuine
        # CLI-side flip.
        socket
        |> assign(mode: mode)
        |> append_message(:system, observed_mode_line(socket.assigns.mode, mode))
    end
  end

  # The CLI's own post-plan flip: inert HERE — the Recorder owns this seam
  # (engage Autopilot + `{:studio_chat_mode_adopted, …}` broadcast); adopting it
  # locally too would double-persist and race the steer.
  defp observe_permission_mode(socket, "default"), do: socket

  # A permissionMode OUTSIDE the six-value guard (a future/unknown CLI mode) is
  # NOT silently adopted (charter D52): the stored mode is left ALONE (never
  # widen the guard to admit an untrusted string), but the divergence is surfaced
  # honestly so the transcript does not hide it. Falls through for a nil observed
  # value (an init frame with no permissionMode — a routine turn boundary).
  defp observe_permission_mode(socket, mode) when is_binary(mode) and mode != "" do
    if mode != socket.assigns.mode and is_nil(socket.assigns[:pending_mode]) do
      append_message(
        socket,
        :system,
        "The agent reports an unrecognized permission mode (#{mode}); keeping #{mode_label(socket.assigns.mode)}."
      )
    else
      socket
    end
  end

  defp observe_permission_mode(socket, _mode), do: socket

  # A CLI-side divergence is narrated without inventing a cause. (The proven
  # ExitPlanMode signature — plan → default, charter D52 — no longer lands
  # here: the Recorder adopts it into Autopilot and its broadcast carries the
  # story.)
  defp observed_mode_line(_from, mode),
    do: "Permission mode is now #{mode_label(mode)} (reported by the agent)."

  # Persist a mode switch onto the store row (charter D17) — no-op with no store
  # session yet (a brand-new chat before its first send has no row to write).
  defp persist_mode(socket, mode) do
    if store_id = socket.assigns[:store_session_id], do: StudioChat.set_mode(store_id, mode)
    :ok
  end

  defp interrupt_timeout_ms do
    Application.get_env(
      :barkpark,
      :studio_chat_interrupt_timeout_ms,
      @default_interrupt_timeout_ms
    )
  end

  # ── persistence (D7 — source markdown, on completion only) ──────────────

  # Persist the user's turn (D7). A store write can fail (e.g. a same-session
  # append race that outlived its retries) — we never discard that error: log it
  # and tell the user honestly that THIS message may not survive a reopen, so
  # the transcript never lies about what was remembered (charter D20b).
  defp persist_user_message(socket, text, attachments, queued?) do
    # Only the lightweight pointer rides the jsonb — NEVER the base64/bytes
    # (charter D25/D7). An attachment-free send keeps the empty-metadata shape.
    metadata =
      case attachments do
        [] -> %{}
        list -> %{"attachments" => Enum.map(list, &attachment_pointer_json/1)}
      end

    # A mid-turn send is stamped queued=true (charter D43) as HISTORICAL FACT:
    # replay keeps the row a plain ❯ (the '⧗ queued' badge is live-only chrome),
    # but the metadata records that this word landed while a turn was running.
    metadata = if queued?, do: Map.put(metadata, "queued", true), else: metadata

    socket =
      case persist_store(socket, %{role: "user", source_markdown: text, metadata: metadata}) do
        {:error, reason} ->
          Logger.warning("studio chat: failed to persist user message: #{inspect(reason)}")

          append_message(
            socket,
            :system,
            "⚠ This message could not be saved — it may not appear if you reopen this chat."
          )

        _ ->
          socket
      end

    refresh_sessions(socket)
  end

  # ── image attachments (charter D25) ─────────────────────────────────────────

  # Consume the staged uploads: read each into memory, store the bytes under the
  # chat-owned dir keyed by the session id, and carry the bytes forward (for the
  # base64 wire block + the live bubble data-URI). A store/read failure drops that
  # one image honestly (logged) rather than failing the whole turn.
  #
  # Sobelow Traversal.FileModule (File.read/1) is a false-positive: `tmp_path`
  # is the temp file LiveView's upload machinery created and hands to the
  # `consume_uploaded_entries/3` callback — never a client-supplied name. The
  # client controls the file BYTES and `entry.client_type`, not this path.
  # (Was baseline-skipped in .sobelow-skips; the fingerprint is line-anchored,
  # so edits above this function broke it — the inline skip is durable.)
  # sobelow_skip ["Traversal.FileModule"]
  defp consume_attachments(socket) do
    store_id = socket.assigns.store_session_id

    attachments =
      consume_uploaded_entries(socket, :attachments, fn %{path: tmp_path}, _entry ->
        # (entry ignored: the media type comes from the BYTES, not client_type)
        # `Attachments.put/2` is the ONE store seam both surfaces write through
        # (ct-bl-chat-attachments): the Studio composer and the
        # `POST /v1/chat/sessions/:id/attachments` transport route land in the
        # SAME content-addressed store, so a Studio-pasted image is readable by
        # `bp chat` through the chat-owned read route with no second store and no
        # per-surface fork. It also sniffs the media type from the bytes instead
        # of trusting `entry.client_type` — a client-declared type is caller
        # input, and the type the store records is what is served back.
        with {:ok, bytes} <- File.read(tmp_path),
             {:ok, pointer} <- Attachments.put(store_id, bytes) do
          {:ok, Map.put(pointer, :bytes, bytes)}
        else
          {:error, reason} ->
            Logger.warning("studio chat: failed to attach image: #{inspect(reason)}")
            {:ok, :error}
        end
      end)

    {Enum.reject(attachments, &(&1 == :error)), socket}
  end

  # Assemble the user frame's content-block list: the text block (omitted when
  # blank — an image-only turn) followed by one base64 image block per attachment
  # (charter D25 wire shape, proven on the real binary).
  defp build_user_content(text, attachments) do
    text_blocks = if text == "", do: [], else: [%{"type" => "text", "text" => text}]

    image_blocks =
      Enum.map(attachments, fn a ->
        %{
          "type" => "image",
          "source" => %{
            "type" => "base64",
            "media_type" => a.media_type,
            "data" => Base.encode64(a.bytes)
          }
        }
      end)

    text_blocks ++ image_blocks
  end

  # Live user bubble carrying the just-sent images as data-URIs (bytes in hand —
  # no disk re-read). Replay rebuilds the same shape from the store.
  defp append_user_message(socket, text, attachments) do
    images = Enum.map(attachments, fn a -> %{data_uri: data_uri(a.media_type, a.bytes)} end)
    id = socket.assigns.next_id
    message = %{id: id, role: :user, text: text, html: nil, images: images}
    put_message(socket, message)
  end

  # The jsonb pointer for a stored attachment — path/media_type/sha256/byte_size
  # ONLY, never the bytes. Delegated to `Attachments.pointer_json/1` so the
  # Studio composer and the transport persist the IDENTICAL pointer shape; the
  # wire projection (`Attachments.reference/2`, which drops `path`) then reads
  # one shape rather than guessing between two writers.
  defp attachment_pointer_json(a), do: Attachments.pointer_json(a)

  defp data_uri(media_type, bytes),
    do: "data:#{media_type};base64,#{Base.encode64(bytes)}"

  # Images on a message map (live or replayed); older/other user rows have none.
  defp user_images(message), do: Map.get(message, :images, []) || []

  defp upload_error_label(:too_large), do: "Image is larger than 3 MB."
  defp upload_error_label(:not_accepted), do: "Only PNG, JPEG, GIF, or WebP images."
  defp upload_error_label(:too_many_files), do: "Up to 4 images per message."
  defp upload_error_label(_), do: "That file could not be attached."

  # Append to the store when a session row exists; `:no_store` when this chat is
  # still unsaved (a pre-first-send draft), otherwise the append result verbatim
  # so callers can react to `{:error, _}` (never silently drop it).
  defp persist_store(socket, attrs) do
    case socket.assigns.store_session_id do
      nil -> :no_store
      store_id -> StudioChat.append_message(store_id, attrs)
    end
  end

  # Record the turn's usage AND capture the per-turn context snapshot for the
  # header ring (charter D19). The lifetime totals stay summed; last_context_tokens
  # / context_window are SET from THIS frame (input + both cache reads + output,
  # and the answering model's contextWindow — never a hardcoded window map). The
  # returned session drives the ring assign so the header updates on every result.
  # READ-ONLY since wave 4 (charter D28): the Recorder records the metrics the
  # moment the result frame lands (it outlives every tab); each viewing tab
  # only re-reads the row so its header ring reflects the fresh snapshot.
  # Recording here too would double-sum the lifetime token totals.
  defp record_result(socket, _ev) do
    with store_id when is_binary(store_id) <- socket.assigns.store_session_id,
         %{} = session <- get_session_in_tenancy(socket, store_id) do
      assign(socket, ring: ring_from_session(session))
    else
      _ -> socket
    end
  end

  # Rebuild the transcript message list from the persisted store. Assistant
  # markdown re-renders through the SAME paper engine used live, so the improving
  # renderer wins on every reopen (D7).
  # Load only the last `@transcript_window` rows (task-9e21c3f285b3d7d0): a huge
  # session no longer pulls its ENTIRE history into the socket on reopen. The DB
  # LIMIT caps both the query result and the initial socket heap; the store keeps
  # the full durable history, so nothing is lost — only the on-screen window is
  # bounded. `assign_messages/2` keeps it bounded across subsequent live appends.
  # The store call stays `:global` because `chat_messages` carries no
  # `owner_workspace_id` of its own — `StudioChat`'s scoped arm reaches the
  # tenant through the parent SESSION, on the same strict equality that would
  # blank a NULL-owned legacy transcript. The tenant gate for a transcript is
  # therefore its session, and `replay_messages/2` is reachable from exactly one
  # place: `load_stored_session/2`, whose only caller is the `handle_params/3`
  # clause above — which now loads through `get_session_in_tenancy/2`. A foreign
  # session never becomes an on-screen session, so its messages are never read.
  defp replay_messages(session_id, live?) do
    StudioChat.list_messages(session_id, @transcript_window, :global)
    |> Enum.map(&replay_message(&1, live?))
  end

  # An approval row rebuilds its card from metadata (request_id + tool_name +
  # lifecycle). `live?` decides the fate of a still-"pending" row: on a display-
  # only reopen (no live owner) it can NEVER be resolved, so it renders as the
  # honest terminal state, canceled (the persisted flip already ran in
  # load_stored_session so the store agrees with the screen). On a reopen that
  # ADOPTED a live owner (charter D22) the ask stays answerable — the card keeps
  # its :pending status and resolve_permission holds the adopted pid.
  defp replay_message(%{role: "approval", seq: seq, source_markdown: md, metadata: meta}, live?) do
    meta = meta || %{}

    %{
      id: seq,
      role: :approval,
      text: md,
      html: nil,
      request_id: Map.get(meta, "request_id"),
      tool_name: Map.get(meta, "tool_name"),
      approval_status: replay_approval_status(Map.get(meta, "approval_status"), live?)
    }
  end

  # A question row (AskUserQuestion) rebuilds its answer FORM from the persisted
  # ask input (charter D31). Same live?/pending fate as an approval — under a
  # live owner it stays answerable; on a dead reopen it renders the terminal
  # state. The parsed questions + raw input let the form re-render and, if still
  # answerable, submit a fresh answer.
  defp replay_message(%{role: "question", seq: seq, source_markdown: md, metadata: meta}, live?) do
    meta = meta || %{}
    input = Map.get(meta, "input") || %{}

    %{
      id: seq,
      role: :question,
      text: md,
      html: nil,
      request_id: Map.get(meta, "request_id"),
      tool_name: Map.get(meta, "tool_name") || "AskUserQuestion",
      questions: parse_questions(input),
      raw_input: input,
      approval_status: replay_approval_status(Map.get(meta, "approval_status"), live?)
    }
  end

  # A proposed-plan row (charter D34) re-renders the card from metadata — the
  # plan markdown is `input.plan` (already persisted in the ask metadata; the
  # source_markdown is the fallback). `live?` decides a still-"pending" plan's
  # fate exactly like an approval: answerable under a live owner (D22), else the
  # honest terminal state, canceled (never a dead Approve button, never a bare
  # :system line).
  defp replay_message(%{role: "plan", seq: seq, source_markdown: md, metadata: meta}, live?) do
    meta = meta || %{}
    input = Map.get(meta, "input") || %{}

    # input.plan is the source of truth; fall back to the stored source_markdown
    # so an older/thinner row still renders something honest.
    input =
      if is_binary(input["plan"]),
        do: input,
        else: Map.put(input, "plan", md || "")

    build_plan_message(
      seq,
      Map.get(meta, "request_id"),
      input,
      replay_approval_status(Map.get(meta, "approval_status"), live?),
      meta
    )
  end

  # A user row rebuilds its image attachments (charter D25) from the metadata
  # pointers, read SERVER-SIDE from the chat-owned store and inlined as data-URIs
  # — no HTTP route ever (D6). A file missing on disk degrades to an honest
  # placeholder so replay never crashes.
  defp replay_message(%{role: "user", seq: seq, source_markdown: md, metadata: meta}, _live?) do
    %{id: seq, role: :user, text: md, html: nil, images: replay_images(meta)}
  end

  # A todo row replays as ONE final-state living checklist (charter D39): the
  # Recorder collapsed every TodoWrite of the turn into this single row's
  # metadata.input, so parsing it here reconstructs exactly the last state.
  defp replay_message(%{role: "todo", seq: seq, metadata: meta}, _live?) do
    input = Map.get(meta || %{}, "input") || %{}

    %{
      id: seq,
      role: :todo,
      text: "Update todos",
      html: nil,
      todos: ChatToolRenderer.parse_todos(input)
    }
  end

  # A tool row replays with its captured output so the ⎿ line survives reopen,
  # its input + tool name so the diff renderer (D38) reproduces the identical
  # colored diff, and the spawn heuristics + nested-trace parentage (D40) so a
  # reopened transcript shows the same ● spawn row and indented children the
  # live tab drew — replay parity is first-class.
  defp replay_message(%{role: "tool", seq: seq, source_markdown: md, metadata: meta}, _live?) do
    meta = meta || %{}
    name = Map.get(meta, "tool")
    input = Map.get(meta, "input")

    %{
      id: seq,
      role: :tool,
      text: md,
      html: nil,
      output: Map.get(meta, "output"),
      # Settle-gated gutter, REPLAY half: the Recorder stamped `turn_settled` on
      # this row when its turn's result frame landed, and `tool_error` when the
      # tool_result said `is_error` — so a reopened session draws the SAME ✓/✗/●
      # the live tab drew, off the persisted envelope, with no re-derivation.
      turn_settled: Map.get(meta, "turn_settled") == true,
      tool_error: Map.get(meta, "tool_error") == true,
      # The turn fold's facts (task-8f904a88b9bc3d59), read back VERBATIM off the
      # same stamp `StudioChat.settle_tool_rows/2` wrote — the reopened
      # transcript folds under the identical "Worked for …" header the live tab
      # drew, with no clock and no classification on this side.
      turn_settled_at: Map.get(meta, "turn_settled_at"),
      turn_duration_ms: Map.get(meta, "turn_duration_ms"),
      turn_outcome: Map.get(meta, "turn_outcome"),
      tool: name,
      input: input,
      tool_use_id: Map.get(meta, "tool_use_id"),
      parent_tool_use_id: Map.get(meta, "parent_tool_use_id"),
      spawn?: spawn?(name, input),
      spawn_label: spawn_label(name, input),
      # Agent drill-down hydration (charter D46): a reopened spawn row carries its
      # last-persisted task state — a mid-run agent shows the honest last line, an
      # interrupted one shows "interrupted" (D45 teardown), never a fake spinner.
      task_id: Map.get(meta, "task_id"),
      task_status: Map.get(meta, "task_status"),
      task_progress: Map.get(meta, "task_progress")
    }
  end

  # A thinking row (charter D41) rebuilds the ✻ pulse from its persisted count —
  # the signature was never stored, only `metadata.tokens`. `source_markdown` is
  # the human-readable fallback for an older/thinner row with no count.
  defp replay_message(%{role: "thinking", seq: seq, source_markdown: md, metadata: meta}, _live?) do
    tokens = Map.get(meta || %{}, "tokens")
    text = if is_integer(tokens), do: thinking_label(tokens), else: md || "thought"
    # `tokens` (when present) routes the render through the `chat-thinking` block
    # (D25); a legacy row with no count keeps `tokens: nil` and its plain ✻ text.
    %{id: seq, role: :thinking, text: text, html: nil, tokens: tokens}
  end

  defp replay_message(m, _live?) do
    role = replay_role(m.role)

    html =
      if role == :assistant and is_binary(m.source_markdown) and
           String.trim(m.source_markdown) != "",
         do: render_paper_html(m.source_markdown)

    %{
      id: m.seq,
      role: role,
      text: m.source_markdown,
      html: html,
      parent_tool_use_id: Map.get(m.metadata || %{}, "parent_tool_use_id")
    }
  end

  # Rebuild the inline image list from a user row's metadata attachment pointers.
  defp replay_images(meta) do
    case Map.get(meta || %{}, "attachments") do
      list when is_list(list) -> Enum.map(list, &replay_image/1)
      _ -> []
    end
  end

  defp replay_image(%{"path" => path, "media_type" => media_type}) when is_binary(path) do
    case StudioChat.read_attachment(path) do
      {:ok, bytes} -> %{data_uri: data_uri(media_type, bytes)}
      {:error, :missing} -> %{missing: true}
    end
  end

  defp replay_image(_), do: %{missing: true}

  defp replay_approval_status("allowed", _live?), do: :allowed
  defp replay_approval_status("denied", _live?), do: :denied
  # pending under a live owner stays answerable (D22); pending with no owner, or
  # any unknown value, degrades to canceled — never a dead card no one can click.
  defp replay_approval_status("pending", true), do: :pending
  defp replay_approval_status(_, _live?), do: :canceled

  # A stored role must never make a session unopenable: map the known roles and
  # degrade anything else (a future wave's vocabulary) to a system line.
  defp replay_role("user"), do: :user
  defp replay_role("assistant"), do: :assistant
  defp replay_role("tool"), do: :tool
  defp replay_role(_), do: :system

  defp replay_init(%{model: model}) when is_binary(model),
    do: %{model: model, session_id: nil, permission_mode: nil}

  defp replay_init(_), do: nil

  # Honest failure copy for a codex runtime failure event (protocol_error /
  # error / process_failed). Names the failure class, then the scrubbed reason
  # from protocol.ex's `error` map (message/detail, with the machine code in
  # parens) when one is present.
  defp codex_failure_line(kind, error) do
    label =
      case kind do
        :process_failed -> "The codex process exited unexpectedly"
        :protocol_error -> "The codex stream hit a protocol error"
        _ -> "The codex turn ended with an error"
      end

    case codex_error_detail(error) do
      "" -> label <> "."
      detail -> label <> " — " <> detail <> "."
    end
  end

  defp codex_error_detail(error) when is_map(error) do
    reason =
      [error["message"], error["detail"]]
      |> Enum.map(&codex_error_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.join(" — ")

    code = codex_error_text(error["code"])

    cond do
      reason != "" and code != "" -> reason <> " (" <> code <> ")"
      reason != "" -> reason
      code != "" -> code
      true -> ""
    end
  end

  defp codex_error_detail(_), do: ""

  defp codex_error_text(value) when is_binary(value), do: String.trim(value)
  defp codex_error_text(value) when is_integer(value), do: Integer.to_string(value)
  defp codex_error_text(_), do: ""

  defp append_message(socket, role, text, opts \\ []) do
    id = socket.assigns.next_id
    message = Map.merge(%{id: id, role: role, text: text, html: nil}, Map.new(opts))
    put_message(socket, message)
  end

  # Drop the live-only '⧗ queued' badge (charter D43) when the queued turn starts
  # (the next system/init). Historical fact lives in the store's metadata.queued;
  # this only clears the in-memory chrome so the row settles to a plain ❯ prompt.
  defp clear_queued_badges(messages) do
    Enum.map(messages, fn m ->
      if Map.get(m, :queued), do: Map.put(m, :queued, false), else: m
    end)
  end

  # Settle the live thinking pulse into a durable `:thinking` message (charter
  # D41). Called at the first real output of a bout (text delta / assistant
  # blocks / result) so live order matches the persisted replay order. A bout
  # with a positive count leaves a "thought for ~N tokens" row; one that never
  # counted (no thinking frames) leaves nothing. Always clears the pulse, so
  # repeated calls within a turn are idempotent.
  defp settle_thinking(socket) do
    case socket.assigns[:thinking_pulse] do
      %{tokens: n} when is_integer(n) and n > 0 ->
        socket
        |> append_message(:thinking, thinking_label(n), tokens: n)
        |> assign(thinking_pulse: nil)

      _ ->
        assign(socket, thinking_pulse: nil)
    end
  end

  # ── hand-task surface (chat ⇄ ledger) ────────────────────────────────────
  # The chat-task-hands substrate already gives every session's CLI a worker id
  # + scoped bp credentials; this surface makes that work VISIBLE and DRIVABLE:
  # the Doing strip mirrors the worker's held claims live, the picker hands a
  # ready task to the agent, and the /task builtins expand to doctrine prompts.
  # One-substrate law (chat-task-hands D1): the surface only PROMPTS — every
  # ledger write still goes through the agent's own bp/MCP hands.

  # The whole dataset's document stream — the Doing strip folds task mutations
  # out of it. Same global topic the SSE listener serves; cheap to filter.
  defp subscribe_hand_tasks(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{socket.assigns.dataset}")
    end

    socket
  end

  # The scope the agent's own task hands work in: the flat /v1/tasks routes
  # resolve to the seeded defaults via AssignDefaultScope, so the surface reads
  # the SAME board the agent writes. (Tasks.ready is fail-closed on a nil
  # workspace — passing no scope would render the picker permanently empty.)
  defp hand_task_scope do
    ws = Barkpark.Tenancy.get_default_workspace()
    proj = Barkpark.Tenancy.get_default_project()
    [workspace_id: ws && ws.id, project_id: proj && proj.id]
  end

  # ── live task transitions in the transcript (tlv) ─────────────────────────
  #
  # The Doing strip above shows WHAT this session holds; this shows WHEN it
  # changed. A lifecycle mutation of a task this session has touched appends one
  # tinted mono row to the transcript, so a claim, a stage, a close, a release,
  # or a lead's kill lands in the conversation within PubSub latency instead of
  # waiting for the agent's next MCP re-fetch.
  #
  # No new bus and no new subscription: this rides the SAME
  # `documents:<dataset>` stream `subscribe_hand_tasks/1` already joined, and
  # the SAME `{:document_changed, …}` message the Doing strip folds. The scope
  # rule, the idempotency key, and the label all live in
  # `StudioChat.TaskTransition` — the ONE derivation `Recorder` re-broadcasts to
  # `bp chat` from, so the two surfaces cannot drift.
  #
  # Idempotency (criterion 3): the mutation_events row id is the key. A
  # duplicate broadcast, or a Last-Event-ID replay of the same event, is
  # dropped BEFORE the append — so it renders exactly once and the rows that
  # came after it keep their positions. The transition row is live-only chrome:
  # it is never persisted, so the separate `task_prime` snapshot contract (the
  # MCP chip renderer) is untouched.
  defp fold_task_transition(socket, msg, worker) do
    case TaskTransition.project(msg, worker, socket.assigns.touched_tasks) do
      {:ok, transition, touched} ->
        socket = assign(socket, touched_tasks: touched)

        if MapSet.member?(socket.assigns.seen_task_events, transition.key) do
          socket
        else
          socket
          |> update(:seen_task_events, &MapSet.put(&1, transition.key))
          |> append_message(:task_transition, transition.label,
            task_id: transition.task_id,
            task_status: transition.status,
            task_color: transition.color,
            event_key: transition.key
          )
        end

      {:skip, touched} ->
        assign(socket, touched_tasks: touched)
    end
  end

  # Re-read the session worker's held claims off the ledger (reopen/mount).
  # No session → no worker → empty strip, no query.
  defp hydrate_hand_tasks(%{assigns: %{store_session_id: nil}} = socket),
    do: assign(socket, hand_tasks: %{})

  defp hydrate_hand_tasks(socket) do
    worker = Runtime.worker_id(socket.assigns.provider, socket.assigns.store_session_id)

    rows =
      Tasks.prime([worker: worker, limit: 10] ++ hand_task_scope())
      |> Map.get(:in_progress, [])
      |> Map.new(fn d ->
        {DraftId.published_id(d.doc_id), hand_task_row(d.title, d.content)}
      end)

    # SEED the transition scope off the SAME read (tlv, no second query): every
    # claim this worker already holds is a task this session has touched, so a
    # release/reap/kill arriving AFTER the reopen — which carries no
    # claim.worker to match on — still renders as a transition.
    socket
    |> assign(hand_tasks: rows)
    |> update(:touched_tasks, fn set ->
      Enum.reduce(Map.keys(rows), set, &MapSet.put(&2, &1))
    end)
  end

  defp hand_task_row(title, content) when is_map(content) do
    criteria = List.wrap(content["acceptance_criteria"])

    %{
      title: title || content["title"] || "untitled task",
      now: get_in(content, ["claim", "now"]),
      met: Enum.count(criteria, fn c -> is_map(c) and c["met"] == true end),
      total: length(criteria),
      # The one-hop epic pointer (wsc charter D9): both feeding paths (ledger
      # hydrate + document broadcast) already hold the full content, so this
      # is a pure projection — it keys the sibling document_changed step.
      parent_id: content["parent_id"]
    }
  end

  defp hand_task_row(title, _content),
    do: %{title: title || "untitled task", now: nil, met: 0, total: 0, parent_id: nil}

  # A ready-queue Document as a lean picker row.
  defp hand_ready_row(doc) do
    %{
      id: DraftId.published_id(doc.doc_id),
      title: doc.title || doc.content["title"] || "untitled task",
      priority: doc.content["priority"]
    }
  end

  # The claim-first work prompt (spinner-claim-first doctrine): the agent
  # claims to GET the brief, stamps evidence as it goes, pulses (epoch bumps —
  # re-read it), and closes with the final epoch.
  defp task_work_prompt(task_id) do
    """
    Work Barkpark task #{task_id}.
    Claim it first as your $BARKPARK_WORKER_ID worker (`bp task claim #{task_id} "$BARKPARK_WORKER_ID"`) and read the brief + acceptance criteria off the claim response. Then do the work. Discipline: stamp each criterion with concrete evidence the moment it is met (`bp task stamp`); pulse a now-line at phase boundaries (`bp task pulse` — pulse BUMPS the claim epoch, re-read it from the response); close with the final epoch only when every criterion is stamped. If you get blocked, stamp `--miss` with an honest note and tell me what you need.
    """
  end

  # The authoring prompt: the agent writes a rubric-grade task and satisfies
  # the publish wall (weighted registered tags) itself.
  defp task_create_prompt(wish) do
    """
    Author and publish a Barkpark task for this wish: #{wish}
    Meet the authoring rubric: a crisp title; a description carrying the WHY and the shape of done; acceptance_criteria as {criterion, met: false, evidence: ""} entries; a priority (0 = highest); and 1-12 weighted tags picked from the REGISTERED tag registry ({tag, strength, rationale} — list the registered tags first). Create it with `bp task create … --publish`; if the publish wall rejects it, fix exactly what it names and republish. Report the task id once it is live.
    """
  end

  defp blank_pulse, do: %{tokens: 0, text: "", word: Enum.random(@spinner_words)}

  # Roll the turn-level word (worn by the between-tools busy row). Called at
  # every turn start; from there the ChatSpinWord hook rotates it in the
  # browser (the park never stands still — the liveness floor is unchanged,
  # only its clock moved off the server).
  defp roll_spinner_word(socket), do: assign(socket, spinner_word: Enum.random(@spinner_words))

  defp thinking_label(n), do: "thought for ~#{n} tokens"

  # The cumulative estimated-token count off a `system/thinking_tokens` frame.
  defp thinking_tokens_count(ev) do
    case ev["estimated_tokens"] do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

  # A TodoWrite-shaped tool_use is ONE living checklist card per turn (charter
  # D39). The turn's first TodoWrite appends a :todo card and records its id;
  # every later one supersedes that card's list IN PLACE (never appends). The
  # tracked id resets on the broadcast `system/init` (per-turn boundary), so a
  # mid-turn joiner — whose id is nil — appends one latest-state card (accepted;
  # reopen converges to the single persisted row). The existence guard keeps a
  # stale id (from a session we just left) from silently dropping the card.
  defp apply_todo_block(socket, input) do
    todos = ChatToolRenderer.parse_todos(input)
    tracked = socket.assigns[:todo_card_id]

    if is_integer(tracked) and
         Enum.any?(socket.assigns.messages, &(&1.id == tracked and &1.role == :todo)) do
      messages =
        Enum.map(socket.assigns.messages, fn
          %{id: ^tracked} = m -> %{m | todos: todos}
          m -> m
        end)

      assign_messages(socket, messages)
    else
      id = socket.assigns.next_id

      socket
      |> append_message(:todo, "Update todos", todos: todos)
      |> assign(todo_card_id: id)
    end
  end

  # Resolve a pending needs-you card (approval | question | plan) with a
  # `:allow | {:allow, updated_input} | {:deny, message}` decision (charter
  # D32). `:allow`/`{:allow, _}` land as the terminal `:allowed`; a deny lands
  # `:denied`. After persisting, the resolution BROADCASTS on the session topic
  # (charter D35) so every co-viewing tab converges its card — a question form
  # left open on another tab flips to answered instead of lingering. The
  # broadcast excludes self (this tab already flipped its own card).
  defp resolve_permission(socket, request_id, decision) do
    socket =
      case socket.assigns[:store_session_id] do
        nil -> socket
        sid -> assign(socket, activity: Map.delete(socket.assigns.activity, sid))
      end

    pending? =
      Enum.any?(
        socket.assigns.messages,
        &(&1.role in @needs_you_roles and &1[:request_id] == request_id and
            &1.approval_status == :pending)
      )

    if pending? and socket.assigns.session do
      Runtime.answer_approval(
        socket.assigns.provider,
        socket.assigns.session,
        request_id,
        decision
      )

      status =
        case decision do
          {:deny, _} -> :denied
          _ -> :allowed
        end

      messages = flip_card(socket.assigns.messages, request_id, status)

      # Persist the decision (D11) and drop the pending count so the sidebar
      # "needs you" pill clears on the next sidebar refresh.
      if store_id = socket.assigns[:store_session_id],
        do: StudioChat.update_approval_status(store_id, request_id, Atom.to_string(status))

      broadcast_resolution(socket, request_id, status)

      # D49: an APPROVED ExitPlanMode plan grows up into a real published Paper.
      # Fire-and-forget so the approve (already on the wire above) never blocks or
      # fails on a publish error; the result converges every co-viewing tab via
      # the session topic. Deny/keep-planning and ordinary approvals never touch
      # Papers — the gate is role :plan AND an allow decision.
      maybe_publish_plan(socket, request_id, decision)

      socket
      |> assign_messages(messages)
      |> clear_question_form(request_id)
      |> refresh_sessions()
    else
      socket
    end
  end

  # Project an approved plan into a Paper (charter D49) by DELEGATING to the one
  # owner of that side effect, `PlanPapers.publish_approved_plan/3` — the same
  # seam `POST /v1/chat/sessions/:id/approval` calls, so a plan approved from the
  # TUI and one approved from this tab produce the identical Paper, stamp and
  # broadcast (ct-bl-plan-paper-parity). The gates (allow-only, :plan-role-only,
  # non-blank server-held markdown), the fire-and-forget task and the honest
  # failure broadcast all live THERE, keyed on the row the Recorder persisted —
  # never on this socket's in-memory copy. A tab with no store session (a
  # brand-new chat) has nothing to project.
  defp maybe_publish_plan(socket, request_id, decision) do
    with sid when is_binary(sid) <- socket.assigns[:store_session_id] do
      PlanPapers.publish_approved_plan(sid, request_id, decision)
    end

    :ok
  end

  # Flip every card matching a request_id to a terminal status (idempotent over
  # already-terminal rows — the guard only rewrites the matched request_id).
  defp flip_card(messages, request_id, status) do
    Enum.map(messages, fn
      %{role: role, request_id: ^request_id} = m when role in @needs_you_roles ->
        %{m | approval_status: status}

      m ->
        m
    end)
  end

  # Stamp a plan row's Paper id/url in memory (charter D49) so its "→ published
  # as Paper" link renders. Idempotent and request_id-scoped; leaves every other
  # row untouched.
  defp stamp_plan_paper(messages, request_id, paper_id, paper_url) do
    Enum.map(messages, fn
      %{role: :plan, request_id: ^request_id} = m ->
        %{m | paper_id: paper_id, paper_url: paper_url}

      m ->
        m
    end)
  end

  # Broadcast a resolution to co-viewing tabs (charter D35). Excludes self via
  # `broadcast_from` — this tab already flipped its own card. A tab with no
  # store session (a brand-new chat before its first send) has nothing to
  # converge, so we skip.
  defp broadcast_resolution(socket, request_id, status) do
    if topic = socket.assigns[:subscribed_topic] do
      Phoenix.PubSub.broadcast_from(
        Barkpark.PubSub,
        self(),
        topic,
        {:chat_permission_resolved, request_id, status}
      )
    end

    :ok
  end

  # ── permission-card construction + question-form scratch state ────────────

  # Build the live card for an incoming ask, routed by tool_name (charter D31).
  defp permission_message(id, %{tool_name: "AskUserQuestion", input: input} = ask) do
    %{
      id: id,
      role: :question,
      text: ask.title || tool_line(ask.tool_name, input),
      html: nil,
      request_id: ask.request_id,
      tool_name: ask.tool_name,
      questions: parse_questions(input),
      raw_input: input,
      approval_status: :pending
    }
  end

  # ExitPlanMode builds the rich proposed-plan card (charter D34): title off the
  # first heading, the FULL plan through the paper engine, the whole input kept
  # so Approve can echo it back verbatim as updatedInput.
  defp permission_message(id, %{tool_name: "ExitPlanMode", input: input} = ask) do
    build_plan_message(id, ask.request_id, input || %{}, :pending)
  end

  defp permission_message(id, ask) do
    %{
      id: id,
      role: :approval,
      text: ask.title || tool_line(ask.tool_name, ask.input),
      html: nil,
      request_id: ask.request_id,
      tool_name: ask.tool_name,
      approval_status: :pending
    }
  end

  # Normalize the AskUserQuestion input into a render-ready question list.
  # Delegated to StudioChat.QuestionAnswer, which is the SAME parse the `/answer`
  # transport validates against (ct-bl-question-updatedinput): what the human sees
  # on this card and what the server will accept from the terminal cannot drift,
  # because there is one parse.
  defp parse_questions(input), do: QuestionAnswer.parse_questions(input)

  # Seed an empty answer form when a question card first arrives, so the render
  # never reads a missing map. Idempotent (put_new): a co-viewing replay never
  # clobbers an in-progress form.
  defp seed_question_form(socket, %{role: :question, request_id: rid}) when is_binary(rid) do
    forms = Map.put_new(socket.assigns.question_forms, rid, blank_question_form())
    assign(socket, question_forms: forms)
  end

  defp seed_question_form(socket, _), do: socket

  defp blank_question_form, do: %{selections: %{}, custom: %{}}

  defp get_question_form(socket, rid),
    do: Map.get(socket.assigns.question_forms, rid, blank_question_form())

  defp put_question_form(socket, rid, form),
    do: assign(socket, question_forms: Map.put(socket.assigns.question_forms, rid, form))

  defp clear_question_form(socket, rid),
    do: assign(socket, question_forms: Map.delete(socket.assigns.question_forms, rid))

  defp find_message_by_rid(socket, rid),
    do: Enum.find(socket.assigns.messages, &(&1[:request_id] == rid))

  # Collapse the form scratch state into the wire answer map (charter D32):
  # keyed by the QUESTION STRING; a non-empty custom field wins; multiSelect =
  # comma-joined labels; unanswered questions are omitted. Owned by
  # StudioChat.QuestionAnswer so Studio and the `/answer` transport speak ONE
  # answer dialect to the CLI (ct-bl-question-updatedinput).
  defp build_answers(questions, form), do: QuestionAnswer.build_answers(questions, form)

  # Render helpers for the question form: is a chip selected, is a question
  # answered at all, and how many of N are answered (the N/M progress).
  defp chip_selected?(form, qidx, label), do: label in Map.get(form.selections, qidx, [])

  defp question_answered?(form, qidx) do
    selections = Map.get(form.selections, qidx, [])
    custom = Map.get(form.custom, qidx) || ""
    selections != [] or String.trim(custom) != ""
  end

  defp answered_count(questions, form) do
    questions
    |> Enum.with_index()
    |> Enum.count(fn {_q, qidx} -> question_answered?(form, qidx) end)
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  defp question_form_for(forms, rid), do: Map.get(forms || %{}, rid, blank_question_form())

  # ── permission-card components (charter D31/D34) ──────────────────────────

  # The AskUserQuestion answer form. Each question shows its header + prompt,
  # option chips (single- or multi-select), and a custom free-text field; ONE
  # submit sends all answers, and a dismiss denies honestly. Chip/custom state is
  # socket-local per tab (@form). A resolved card collapses to a terminal line.
  defp question_card(assigns) do
    ~H"""
    <div
      :if={@message.approval_status == :pending}
      data-approval={@message.request_id}
      data-question={@message.request_id}
      style="border: 1px solid var(--border-muted); border-left: 3px solid var(--primary); border-radius: 8px; padding: 12px 14px; display: flex; flex-direction: column; gap: 14px;"
    >
      <div style="display: flex; align-items: baseline; justify-content: space-between; gap: 8px;">
        <div class="text-sm" style="font-weight: 600;">The agent is asking you</div>
        <div :if={length(@message.questions) > 1} class="text-xs text-dim" style="white-space: nowrap;">
          <%= answered_count(@message.questions, @form) %>/<%= length(@message.questions) %> answered
        </div>
      </div>

      <div
        :for={{q, qidx} <- Enum.with_index(@message.questions)}
        style="display: flex; flex-direction: column; gap: 8px;"
      >
        <div
          :if={q.header}
          class="text-xs text-dim"
          style="text-transform: uppercase; letter-spacing: 0.04em; font-weight: 600;"
        >
          <%= q.header %>
        </div>
        <div class="text-sm" style="font-weight: 600; overflow-wrap: anywhere;">
          <%= q.question %>
        </div>

        <div :if={q.options != []} style="display: flex; flex-wrap: wrap; gap: 6px;">
          <button
            :for={opt <- q.options}
            type="button"
            phx-click="question-toggle"
            phx-value-rid={@message.request_id}
            phx-value-qi={qidx}
            phx-value-label={opt.label}
            phx-value-multi={to_string(q.multi)}
            aria-pressed={to_string(chip_selected?(@form, qidx, opt.label))}
            title={opt.description}
            style={chip_style(chip_selected?(@form, qidx, opt.label))}
          >
            <span style="font-weight: 600;"><%= opt.label %></span>
            <span :if={opt.description} class="text-xs text-dim" style="display: block; font-weight: 400;">
              <%= opt.description %>
            </span>
          </button>
        </div>

        <input
          type="text"
          placeholder={if q.multi, do: "Custom answer (comma-separated)…", else: "Custom answer…"}
          value={Map.get(@form.custom, qidx, "")}
          phx-keyup="question-custom"
          phx-debounce="300"
          phx-value-rid={@message.request_id}
          phx-value-qi={qidx}
          class="text-sm"
          style="width: 100%; padding: 6px 10px; border: 1px solid var(--border-muted); border-radius: 6px; background: var(--bg-raised, transparent);"
        />
      </div>

      <div style="display: flex; gap: 8px; justify-content: flex-end;">
        <button type="button" class="btn" phx-click="question-dismiss" phx-value-rid={@message.request_id}>
          Dismiss
        </button>
        <button
          type="button"
          class="btn btn-primary"
          phx-click="question-submit"
          phx-value-rid={@message.request_id}
        >
          Answer
        </button>
      </div>
    </div>

    <div
      :if={@message.approval_status != :pending}
      class="text-xs text-dim"
      style="font-family: var(--font-mono); overflow-wrap: anywhere;"
    >
      <%= question_outcome_label(@message.approval_status) %> — the agent's questions
    </div>
    """
  end

  # Chip styling: a selected option reads as filled (soft primary + primary
  # border); unselected is a plain outlined chip. All var(--…) tokens.
  defp chip_style(true),
    do:
      "text-align: left; padding: 6px 10px; border-radius: 8px; cursor: pointer; border: 1px solid var(--primary); background: var(--primary-soft);"

  defp chip_style(false),
    do:
      "text-align: left; padding: 6px 10px; border-radius: 8px; cursor: pointer; border: 1px solid var(--border-muted); background: transparent;"

  defp question_outcome_label(:allowed), do: "✓ answered"
  defp question_outcome_label(:canceled), do: "✗ canceled"
  defp question_outcome_label(_), do: "✗ dismissed"

  # ── proposed-plan card construction (charter D34) ──────────────────────────

  # Build the transcript message for a proposed plan. `input` is the raw
  # ExitPlanMode input (`%{"plan" => markdown, …}`); it is kept whole in
  # `plan_input` so Approve can echo it back verbatim (a bare allow fails the
  # tool). The body is the FULL plan through the paper engine — never truncated;
  # only its RENDERED height is clamped in CSS.
  # `paper` carries a prior projection (charter D49) — the persisted metadata on
  # replay, `%{}` for a fresh live ask. Its keys stay nil until an approve lands a
  # Paper, so the "→ published as Paper" link only ever shows once one exists.
  defp build_plan_message(id, request_id, input, status, paper \\ %{}) do
    plan = plan_markdown(input)

    %{
      id: id,
      role: :plan,
      request_id: request_id,
      tool_name: "ExitPlanMode",
      plan_input: input,
      plan_markdown: plan,
      title: plan_title(plan),
      html: render_paper_html(plan),
      approval_status: status,
      paper_id: paper["paper_id"],
      paper_url: paper["paper_url"]
    }
  end

  defp plan_markdown(%{"plan" => plan}) when is_binary(plan), do: plan
  defp plan_markdown(_), do: ""

  # The card title: the first heading's text (charter D34), off the same
  # FromMarkdown blocks the body renders through. Fallback "Proposed plan" when
  # the plan opens with prose, an empty heading, or no markdown at all.
  defp plan_title(markdown) when is_binary(markdown) do
    markdown
    |> FromMarkdown.blocks()
    |> Enum.find_value("Proposed plan", fn
      %{"type" => "heading", "text" => t} when is_binary(t) ->
        case String.trim(t) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end)
  end

  defp plan_title(_), do: "Proposed plan"

  defp plan_outcome_label(:allowed), do: "✓ plan approved"
  defp plan_outcome_label(:canceled), do: "✗ canceled"
  defp plan_outcome_label(_), do: "✗ kept planning"

  # ── progressive streaming render ────────────────────────────────────────
  # Blocks render the moment they complete, not when the whole message ends.
  # The boundary law, the fold that computes it, the display cap and the
  # forming-component classification all live in `Barkpark.StudioChat.StreamTail`
  # (charter D58/D62/D68) so an SSE producer can compute the SAME prefix. The
  # renderer is injected — `render_paper_html/1` stays HERE because HTML is
  # web-only and it has three non-streaming callers.
  defp advance_streaming(state, delta),
    do: StreamTail.advance(state, delta, &render_paper_html/1)

  # Assistant markdown -> PortableDoc blocks -> the SAME article renderer the
  # paper reader uses. The renderer escapes all text at walk time, so the
  # fragment is safe to embed with raw/1. Fail-soft: any crash means the
  # message falls back to its plain-text form (html: nil).
  defp render_paper_html(markdown) do
    markdown
    |> FromMarkdown.blocks()
    |> Render.render_blocks(%{style: :article})
  rescue
    _ -> nil
  end

  # ── chat tool/todo/thinking rows → the SAME PortableDoc block path (D25) ─────
  #
  # A tool diff / todo card / thinking bout is a first-class PortableDoc BLOCK
  # (`chat-tool-diff` | `chat-todo` | `chat-thinking`), rendered through the exact
  # compose_block :article → Components emitter path the assistant reply body uses
  # (D8) and the Go TUI decodes — closing the Law-1 parallel-render fork. The
  # block is built by `Render.Components.chat_*_block/1` (which REUSES the pure
  # `TextDiff` / `parse_todos` / token derivations), so live-append and replay
  # reach an identical row. Fail-soft: a crash degrades to "" (never a 500).

  defp chat_tool_diff_html(input) do
    case Render.Components.chat_tool_diff_block(input) do
      nil -> ""
      block -> render_chat_block(block)
    end
  end

  defp chat_todo_html(todos), do: render_chat_block(Render.Components.chat_todo_block(todos))

  defp chat_thinking_html(tokens) when is_integer(tokens),
    do: render_chat_block(Render.Components.chat_thinking_block(tokens))

  defp chat_thinking_html(_), do: ""

  defp render_chat_block(block) do
    Render.render_blocks([block], %{style: :article})
  rescue
    _ -> ""
  end

  # Extract {tool_use_id, output_string, is_error?} triples from a wire
  # user-frame. The result content may be a plain string or a block list;
  # anything else (our own echoed sends through the cat test fake) yields [] and
  # is ignored. `is_error` rides along because it is the ONLY wire fact that can
  # turn a settled row's glyph ✗ — and an ERROR result with empty text is kept
  # (a failing tool often has nothing to print, and dropping it would leave the
  # row falsely neutral); a plain empty result is still ignored as before.
  defp tool_results(%{"message" => %{"content" => content}}) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_result" and is_binary(&1["tool_use_id"])))
    |> Enum.map(fn block ->
      {block["tool_use_id"], tool_result_text(block["content"]), block["is_error"] == true}
    end)
    |> Enum.reject(fn {_id, out, error?} -> out in [nil, ""] and not error? end)
  end

  defp tool_results(_), do: []

  # Settle EVERY tool row on the turn's terminal result frame (the SETTLE gate's
  # live half; the Recorder writes the same truth durably via
  # `StudioChat.settle_tool_rows/1`, which replay reads back). Rows of earlier
  # turns are already settled, so this is idempotent — and the any?/guard keeps
  # a settled transcript from paying an O(n) reassign + regroup per result.
  defp settle_tool_rows(socket, stamp) do
    messages = socket.assigns.messages

    # The turn is over, so its "+N previous" control is over with it
    # (task-b66928b2958c8cfa): the NEXT running turn starts collapsed no matter
    # what the reader opened during this one.
    socket = assign(socket, running_fold_expanded: false)

    if Enum.any?(messages, &(&1.role == :tool and Map.get(&1, :turn_settled) != true)) do
      row_stamp = %{
        turn_settled: true,
        turn_started_at: Map.get(stamp, "turn_started_at"),
        turn_settled_at: Map.get(stamp, "turn_settled_at"),
        turn_duration_ms: Map.get(stamp, "turn_duration_ms"),
        turn_outcome: Map.get(stamp, "turn_outcome")
      }

      assign_messages(
        socket,
        Enum.map(messages, fn
          # An already-settled row belongs to an EARLIER turn and keeps its own
          # facts — restamping it here would relabel last turn's fold with this
          # turn's duration. The durable half fences the same rows in its WHERE.
          %{role: :tool, turn_settled: true} = m -> m
          %{role: :tool} = m -> Map.merge(m, row_stamp)
          m -> m
        end)
      )
    else
      socket
    end
  end

  defp tool_result_text(content) when is_binary(content), do: content

  defp tool_result_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp tool_result_text(_), do: nil

  # The ⎿ line: first non-empty line of the output, hard-capped.
  defp tool_output_head(out) when is_binary(out) do
    out
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.find("", &(String.trim(&1) != ""))
    |> String.slice(0, 140)
  end

  defp tool_output_lines(out) when is_binary(out),
    do: out |> String.split("\n") |> Enum.count(&(String.trim(&1) != ""))

  # A diff-shaped call (Edit/Write/MultiEdit by SHAPE) renders its content as a
  # colored diff right below the header (D38) — the header shows only the path,
  # terminal style (`● Update(path)`), never a duplicate old/new-string preview.
  defp tool_line(name, input) when is_map(input) do
    if ChatToolRenderer.diff?(input) do
      "#{name} — #{input["file_path"]}"
    else
      preview =
        input
        |> Enum.filter(fn {_k, v} -> is_binary(v) end)
        |> Enum.map(fn {k, v} -> "#{k}: #{String.slice(v, 0, 80)}" end)
        |> Enum.take(2)
        |> Enum.join(" · ")

      if preview == "", do: name, else: "#{name} — #{preview}"
    end
  end

  defp tool_line(name, _input), do: name

  # A sub-agent's rows (charter D40) indent under their spawn row with a
  # connecting evergreen gutter — the nested-trace feel of the terminal. Tokens
  # only (no color literals): the gate stays green.
  defp trace_child_style,
    do: "margin-left: 12px; padding-left: 12px; border-left: 2px solid var(--primary);"

  # ── agent drill-down grouping + state (charter D46) ─────────────────────────

  # Bucket the flat message list into render items: a top-level spawn row plus
  # every row whose parent_tool_use_id matches its tool_use_id becomes one
  # `{:agent, spawn, [children]}`; everything else (including ORPHAN children
  # whose parent isn't a top-level spawn in this transcript) stays a top-level
  # `{:row, message}`, never vanishing. Grouping is by ID MATCH in seq order —
  # children of parallel spawns interleave, so this is never consecutive
  # chunking. One nesting level: a child that is itself a spawn renders as a
  # plain spawn row inside its parent's bucket (message_body's :tool branch).
  # ── transcript window + memoized grouping (task-9e21c3f285b3d7d0) ────────────
  #
  # The ONE choke point for writing `@messages`: trim to the last
  # `@transcript_window` rows and recompute `@grouped_rows` from that bounded
  # list. Every message write (append, tool-result merge, task-status merge,
  # card flip) routes through here, so per-socket heap AND the grouping cost are
  # bounded by the window — not the (unbounded) session length. Because the HEEx
  # renders `@grouped_rows`, the grouping runs ONCE per write, never per render
  # over the full transcript.
  defp assign_messages(socket, messages) do
    trimmed = trim_transcript(messages)

    {rows, cache} =
      regroup(trimmed, socket.assigns[:grouping_cache] || empty_grouping_cache())

    assign(socket, messages: trimmed, grouped_rows: rows, grouping_cache: cache)
  end

  # Keep only the last `@transcript_window` rows. The drop count is floored at 0
  # (`Enum.drop/2` with a NEGATIVE count drops from the END — that would delete
  # the most recent rows of a short session), so a session at or under the window
  # pays nothing and a long one stays pinned at the window. Public + @doc false
  # only so the window guard (chat_transcript_window_test.exs) can assert the cap.
  @doc false
  def trim_transcript(messages, window \\ @transcript_window)

  def trim_transcript(messages, window) when is_integer(window) and window > 0 do
    Enum.drop(messages, max(length(messages) - window, 0))
  end

  def trim_transcript(messages, _window), do: messages

  # Append one new row and advance the id counter, through the window choke
  # point. Callers set `message.id = socket.assigns.next_id` before calling.
  defp put_message(socket, message) do
    socket
    |> assign(next_id: socket.assigns.next_id + 1)
    |> assign_messages(socket.assigns.messages ++ [message])
  end

  # Bucket child tool-rows under their top-level spawn (charter D46). Public and
  # @doc false ONLY so the efficiency guard (chat_transcript_window_test.exs) can
  # benchmark it directly — it is not part of the module's API.
  #
  # task-9e21c3f285b3d7d0: the child accumulator prepends (`[m | acc]`, O(1)) and
  # reverses each brood ONCE at the end, instead of the old `acc ++ [m]` which is
  # O(k) per child = O(k²) to build a brood of k rows. Same ascending order out,
  # now linear in the brood size. Called ONCE per append (via `assign_messages/2`)
  # over a bounded window — never per render over the full transcript.
  @doc false
  def group_agent_rows(messages) do
    spawns =
      for m <- messages,
          m.role == :tool,
          m[:spawn?],
          is_nil(m[:parent_tool_use_id]),
          is_binary(m[:tool_use_id]),
          into: %{},
          do: {m[:tool_use_id], true}

    children =
      messages
      |> Enum.reduce(%{}, fn m, acc ->
        pid = m[:parent_tool_use_id]

        if is_binary(pid) and Map.has_key?(spawns, pid) do
          Map.update(acc, pid, [m], &[m | &1])
        else
          acc
        end
      end)
      |> Map.new(fn {pid, rows} -> {pid, Enum.reverse(rows)} end)

    consumed =
      children |> Map.values() |> List.flatten() |> MapSet.new(& &1.id)

    Enum.flat_map(messages, fn m ->
      cond do
        m.role == :tool and m[:spawn?] and is_nil(m[:parent_tool_use_id]) and
            is_binary(m[:tool_use_id]) ->
          [{:agent, m, Map.get(children, m[:tool_use_id], [])}]

        MapSet.member?(consumed, m.id) ->
          []

        true ->
          [{:row, m}]
      end
    end)
  end

  # Collapse each SETTLED turn's consecutive tool rows into ONE fold item
  # (task-8f904a88b9bc3d59). Runs as a SECOND pass over `group_agent_rows/1`'s
  # output rather than inside it: the D46 agent bucket is its own block with its
  # own expand state, so an agent block ENDS a fold run instead of being swallowed
  # by one — two folds either side of it, which is what the transcript reads like.
  #
  # The run key is `ChatToolRenderer.turn_fold_key/1` (the row's server-stamped
  # `turn_settled_at`): rows of one turn share it, a live row has none and can
  # never fold, and a row from a server too old to stamp it degrades to the flat
  # transcript it has always been. Linear, called ONCE per write over the bounded
  # window — the same budget `group_agent_rows/1` is held to.
  # The transcript's ONE grouping pipeline: D46 agent blocks, then the RUNNING
  # turn's show-active-only fold (task-b66928b2958c8cfa), then U1's settled
  # folds (task-8f904a88b9bc3d59). The running pass runs FIRST and on
  # `{:row, _}` items, so its gate — "this row's turn has not settled" — is the
  # only thing standing between a SETTLED turn and the active-only collapse.
  defp grouped_rows(messages) do
    messages
    |> group_agent_rows()
    |> fold_running_turn()
    |> fold_settled_turns()
  end

  # ── incremental regrouping (task-07f27c32c84a5005) ──────────────────────
  #
  # `grouped_rows/1` is a fold over the transcript, and the old write path ran it
  # over the WHOLE list on every append: O(N) grouping per write, O(N²) across a
  # session. Nothing about the items it emits changes here — only how much of the
  # list the pass has to look at.
  #
  # THE BOUNDARY. The memo carries an already-grouped PREFIX plus the two facts a
  # later message could use to reach back into it. A write splices `cache.items`
  # in front of the freshly grouped TAIL, so the pass visits the tail only. The
  # prefix is extended ONLY up to a NON-tool message, and that is what makes the
  # cut safe for all three passes:
  #
  #   * `fold_running_turn/1` and `fold_settled_turns/1` are `chunk_by` over
  #     CONSECUTIVE items, and both hand a non-`{:row, tool}` item a nil key. A
  #     nil-keyed chunk is returned unchanged by both, so cutting the list right
  #     after a non-tool row can never split a chunk either fold would collapse.
  #   * `group_agent_rows/1` DOES look both ways — a child is bucketed by ID
  #     match, not adjacency — so the cut carries two explicit guards: no tail row
  #     may name a prefix spawn as its parent, and no prefix ORPHAN reference may
  #     be satisfied by a tail spawn. Either guard failing falls back to a full
  #     regroup: correct, just not cheap.
  #
  # The RUNNING turn is always the trailing run of tool rows, so it always lands
  # in the tail — the bound is "the last turn", never N. Front-trimming (the
  # `@transcript_window` cap) rewrites the prefix, so it MISSES and regroups the
  # window once; the cap itself is what keeps that bounded.
  @doc false
  def empty_grouping_cache do
    %{msgs: [], len: 0, items: [], spawn_ids: MapSet.new(), orphan_refs: MapSet.new(), visited: 0}
  end

  # Returns `{grouped_rows, cache}` — the SAME items `grouped_rows/1` would have
  # returned for the whole list. `cache.visited` is how many transcript rows this
  # call handed to the grouping pass: the per-append bound, read directly by
  # chat_regroup_incremental_test.exs.
  @doc false
  def regroup(messages, cache) do
    case reusable_tail(messages, cache) do
      {:ok, tail} -> extend_grouping(cache, tail)
      :miss -> extend_grouping(empty_grouping_cache(), messages)
    end
  end

  # The memo is reusable only when its prefix is still literally the head of the
  # list (a merge or a card flip that rewrote a prefix row MISSES, as it must)
  # and the tail cannot reach back into it.
  defp reusable_tail(_messages, %{len: 0}), do: :miss

  defp reusable_tail(messages, cache) do
    with true <- List.starts_with?(messages, cache.msgs),
         tail = Enum.drop(messages, cache.len),
         true <- split_safe?(cache, tail) do
      {:ok, tail}
    else
      _ -> :miss
    end
  end

  defp split_safe?(cache, tail) do
    MapSet.disjoint?(cache.spawn_ids, parent_refs(tail)) and
      MapSet.disjoint?(cache.orphan_refs, top_spawn_ids(tail))
  end

  defp extend_grouping(cache, tail) do
    items = cache.items ++ grouped_rows(tail)

    cache =
      if advanceable?(tail) do
        spawns = top_spawn_ids(tail)

        %{
          msgs: cache.msgs ++ tail,
          len: cache.len + length(tail),
          items: items,
          spawn_ids: MapSet.union(cache.spawn_ids, spawns),
          orphan_refs:
            MapSet.union(cache.orphan_refs, MapSet.difference(parent_refs(tail), spawns)),
          visited: length(tail)
        }
      else
        %{cache | visited: length(tail)}
      end

    {items, cache}
  end

  # Only a tail that ENDS on a non-tool row may join the prefix — that is the one
  # cut both folds are blind to. A tail still inside a turn stays live, so the
  # next append regroups that turn and nothing before it.
  defp advanceable?([]), do: false
  defp advanceable?(tail), do: List.last(tail)[:role] != :tool

  defp top_spawn_ids(messages) do
    for m <- messages,
        m.role == :tool,
        m[:spawn?],
        is_nil(m[:parent_tool_use_id]),
        is_binary(m[:tool_use_id]),
        into: MapSet.new(),
        do: m[:tool_use_id]
  end

  defp parent_refs(messages) do
    for m <- messages,
        is_binary(m[:parent_tool_use_id]),
        into: MapSet.new(),
        do: m[:parent_tool_use_id]
  end


  # SHOW-ACTIVE-ONLY (task-b66928b2958c8cfa). While a turn RUNS, its consecutive
  # tool rows collapse to the ACTIVE row plus one "+N previous" control, so a
  # long turn can no longer push the live row off the screen. A SETTLED turn is
  # NOT ours — it belongs to U1's fold-on-settle — and the gate that says so is
  # `turn_fold_key/1`: a settled row HAS a key and is chunked away from the
  # running run, a live row has none.
  #
  # Emits `{:running_fold, n, label, hidden_rows, visible_rows}` and only when
  # `n > 0`: a turn whose active row is its first row hides nothing, so it keeps
  # the flat rows it always had and no control is drawn.
  @doc false
  def fold_running_turn(items) do
    items
    |> Enum.chunk_by(&running_run_key/1)
    |> Enum.flat_map(fn chunk ->
      if running_run_key(hd(chunk)) == :running, do: collapse_running_run(chunk), else: chunk
    end)
  end

  # THE RUNNING GATE. `:running` only for a tool row whose turn has NOT settled.
  # A settled row chunks under its fold key instead — including the key-less
  # "server too old to stamp the fold facts" row, which U1 deliberately leaves
  # FLAT: `turn_settled` is the gate, never the fold key, so a row that cannot
  # fold does not fall through to the running collapse either.
  defp running_run_key({:row, %{role: :tool} = message}) do
    if Map.get(message, :turn_settled) == true,
      do: {:settled, ChatToolRenderer.turn_fold_key(message)},
      else: :running
  end

  defp running_run_key(_item), do: nil

  defp collapse_running_run(chunk) do
    rows = Enum.map(chunk, fn {:row, message} -> message end)

    case ChatToolRenderer.running_hidden_count(rows) do
      0 ->
        chunk

      n ->
        {hidden, visible} = Enum.split(rows, n)
        [{:running_fold, n, ChatToolRenderer.running_fold_label(n), hidden, visible}]
    end
  end

  @doc false
  def fold_settled_turns(items) do
    items
    |> Enum.chunk_by(fn
      {:row, m} -> ChatToolRenderer.turn_fold_key(m)
      _ -> nil
    end)
    |> Enum.flat_map(fn
      [{:row, first} | _] = chunk ->
        case ChatToolRenderer.turn_fold_key(first) do
          nil ->
            chunk

          key ->
            rows = Enum.map(chunk, fn {:row, m} -> m end)
            [{:turn_fold, key, ChatToolRenderer.fold_label(first), rows}]
        end

      chunk ->
        chunk
    end)
  end

  # Is this turn's fold open in THIS tab? Default collapsed — a settled turn is
  # history, and its header already says how long it took.
  defp turn_fold_open?(expanded, key), do: MapSet.member?(expanded, key)

  # The effective expand state of an agent block: a manual per-tab override wins;
  # otherwise the default is open while running (or status-unknown) and collapsed
  # once terminal (charter D46).
  defp agent_open?(overrides, agent) do
    case Map.fetch(overrides, agent[:tool_use_id]) do
      {:ok, v} -> v
      :error -> default_agent_open?(agent)
    end
  end

  defp default_agent_open?(agent), do: agent[:task_status] in [nil, "running"]

  # Terminal collapse is a status-aware DEFAULT (charter D61): a completed cycle
  # defaults COLLAPSED to its one settled summary line; a running or interrupted
  # entry defaults EXPANDED (the interrupted frontier must be visible). The
  # explicit per-tab toggle is the override that wins BOTH ways — including across
  # a running→completed flip (the `default_agent_open?` idiom, keyed by task_id).
  defp rail_open?(overrides, entry) when is_map(entry) do
    case Map.fetch(overrides, entry["task_id"]) do
      {:ok, v} -> v
      :error -> entry["status"] != "completed"
    end
  end

  # The effective expand state of ONE rail agent's detail (wsc-ad): default
  # CLOSED, the per-tab override (keyed by agentId) wins. Unlike rail rows there
  # is no status-aware default — the drill-down is always opt-in, so a busy rail
  # never buries the fleet under exploded detail.
  defp agent_detail_open?(overrides, agent_id), do: Map.get(overrides, agent_id, false)

  # A sub-agent is running only while its task_status says so — a terminal (or
  # interrupted, D45) block shows its report, never a spinner.
  defp agent_running?(agent), do: agent[:task_status] == "running"

  # The agent block headline: "type — description" (charter D46 shape), falling
  # back to whichever of description/type/spawn_label is present so a thinner
  # spawn frame still reads honestly.
  defp agent_headline(agent) do
    input = agent[:input] || %{}
    type = input["subagent_type"]
    desc = input["description"]

    cond do
      is_binary(type) and type != "" and is_binary(desc) and desc != "" -> "#{type} — #{desc}"
      is_binary(desc) and desc != "" -> desc
      is_binary(type) and type != "" -> type
      true -> agent[:spawn_label] || agent[:text] || "agent"
    end
  end

  # Merge task-lifecycle keys into the ONE in-memory row the matcher selects,
  # with a value-equality guard: if status+progress are unchanged, return the
  # socket untouched so a no-op frame costs no server render (charter D46).
  defp merge_task_row(socket, matcher, updates) do
    {messages, changed?} =
      Enum.map_reduce(socket.assigns.messages, false, fn m, changed ->
        if matcher.(m) do
          merged = Map.merge(m, updates)

          if task_signature(merged) == task_signature(m),
            do: {m, changed},
            else: {merged, true}
        else
          {m, changed}
        end
      end)

    if changed?, do: {:noreply, assign_messages(socket, messages)}, else: {:noreply, socket}
  end

  defp task_signature(m), do: {m[:task_status], m[:task_progress]}

  defp by_tool_use_id(id), do: fn m -> is_binary(id) and m[:tool_use_id] == id end
  defp by_task_id(id), do: fn m -> is_binary(id) and m[:task_id] == id end

  defp drop_nil(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)

  # ── agents rail (charter D47) ──────────────────────────────────────────────

  # Apply a folded rail with the SAME structural change-only guard the Recorder
  # persists on: a token-only progress tick (same rows/tree/states, only tokens
  # advanced) yields an equal signature and is a no-op — `@messages`/the rail are
  # a flat comprehension, so every reassign is an O(n) render per tab, and the
  # guard turns the hot workflow_progress heartbeat into render-on-change.
  defp fold_rail(socket, new_rail) do
    sig = StudioChat.rail_signature(new_rail)

    if sig == socket.assigns.rail_sig do
      socket
    else
      old_rail = socket.assigns.rail

      socket
      |> assign(rail: new_rail, rail_sig: sig)
      |> schedule_entry_prunes(old_rail, new_rail)
    end
  end

  # Arm a per-entry auto-dismiss (charter D47) for each entry that JUST reached a
  # terminal status in this fold — present-and-terminal in `new_rail`, and NOT
  # already terminal in `old_rail`. Scheduling on the transition (not on every
  # terminal entry every fold) means an entry's ~90s clock starts when IT
  # settles and a later sibling flip never resets it. The prune carries the
  # entry's per-entry signature so a re-run leaves the stale timer a guarded
  # no-op (see the {:rail_prune_entry, …} handler). A reopened session passes
  # `old_rail = %{}` so every already-terminal rehydrated entry ages out too
  # instead of re-squatting. This never deletes the stored `rail_snapshot`.
  defp schedule_entry_prunes(socket, old_rail, new_rail) do
    Enum.each(new_rail, fn {key, entry} ->
      if StudioChat.rail_terminal?(entry) and not rail_entry_terminal?(old_rail, key) do
        Process.send_after(
          self(),
          {:rail_prune_entry, key, StudioChat.rail_entry_signature(entry)},
          @rail_entry_linger_ms
        )
      end
    end)

    socket
  end

  defp rail_entry_terminal?(rail, key) do
    case Map.get(rail, key) do
      entry when is_map(entry) -> StudioChat.rail_terminal?(entry)
      _ -> false
    end
  end

  # Rail entries in stable insertion order (seq), for a deterministic render.
  defp rail_rows(rail) do
    rail
    |> Enum.sort_by(fn {_tid, entry} -> StudioChat.rail_seq(entry) end)
    |> Enum.map(fn {tid, entry} -> Map.put(entry, "task_id", tid) end)
  end

  defp rail_running?(entry), do: entry["status"] == "running"

  # The row's one-line label: the background task's description, else its type.
  defp rail_label(entry) do
    row = entry["row"] || %{}
    row["description"] || row["task_type"] || "agent"
  end

  # The leading glyph by entry lifecycle: a running cycle shows its kind glyph
  # (⚙ workflow / ◆ other) and breathes; a completed cycle settles to ✓; an
  # interrupted (dead) one reads ✕ — never a spinner.
  defp rail_entry_glyph(%{"status" => "completed"}), do: "✓"
  defp rail_entry_glyph(%{"status" => "interrupted"}), do: "✕"

  defp rail_entry_glyph(entry) do
    case (entry["row"] || %{})["task_type"] do
      "local_workflow" -> "⚙"
      _ -> "◆"
    end
  end

  # The entry header summary AFTER the row label — the aggregate truth, all of it
  # from `workflow_journey/1`'s summary, none invented (charter wave-11). A
  # non-workflow row (no phases) keeps the plain status word + token total.
  defp rail_header_summary(entry, %{phases: []}) do
    base = rail_status_label(entry["status"])

    case rail_tokens(entry) do
      n when is_integer(n) -> "#{base} · #{StudioChat.format_tokens(n)} tok"
      _ -> base
    end
  end

  defp rail_header_summary(%{"status" => "completed"}, %{summary: s}) do
    "#{s.phases_run} of #{s.phase_total} phases" <>
      skipped_part(s.skipped) <>
      " · #{s.agents_total} #{pluralize(s.agents_total, "agent")}" <>
      failed_part(s.failed) <> " · #{StudioChat.format_tokens(s.tokens)} tok"
  end

  defp rail_header_summary(%{"status" => "interrupted"}, %{summary: s}) do
    where =
      case s.active do
        %{index: i, title: t} -> "interrupted in #{t} (#{i}/#{s.phase_total})"
        _ -> "interrupted"
      end

    "#{where} · #{s.running} running · #{s.done} done · #{StudioChat.format_tokens(s.tokens)} tok"
  end

  defp rail_header_summary(_entry, %{summary: s}) do
    head =
      case s.active do
        %{index: i, title: t} -> "#{t} #{i}/#{s.phase_total}"
        _ -> "starting"
      end

    "#{head} · #{s.running} running · #{s.done} done" <>
      failed_part(s.failed) <> " · #{StudioChat.format_tokens(s.tokens)} tok"
  end

  defp skipped_part(0), do: ""
  defp skipped_part(n), do: " · #{n} skipped"
  defp failed_part(0), do: ""
  defp failed_part(n), do: " · #{n} failed"

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  defp rail_status_label("completed"), do: "done"
  defp rail_status_label("interrupted"), do: "interrupted"
  defp rail_status_label(_), do: "running"

  # The rail speaks the lifecycle palette (charter D60): a settled cycle is
  # --life-done, a live one --life-in_progress, an interrupted one --life-blocked.
  #
  # NOTE this rail colours the AGENT-WORKFLOW vocabulary (running / completed /
  # interrupted), NOT the task lifecycle — the three cases below are exact and
  # stay exact. What changed (TLV charter D14) is the DEFAULT: it used to be
  # `--life-in_progress`, so ANY status this build has not heard of rendered as a
  # bright live run — the worst possible direction for a wrong guess, since it
  # reports work in flight that may not be. `running` is now its own explicit
  # clause and the fall-through is neutral.
  defp rail_status_color("running"), do: "var(--life-in_progress)"
  defp rail_status_color("completed"), do: "var(--life-done)"
  defp rail_status_color("interrupted"), do: "var(--life-blocked)"
  defp rail_status_color(_), do: "var(--fg-dim)"

  # Phase-row glyph + color by journey status (charter D58/D60).
  defp rail_phase_glyph(:done), do: "✓"
  defp rail_phase_glyph(:active), do: "◆"
  defp rail_phase_glyph(:interrupted), do: "◆"
  defp rail_phase_glyph(_), do: "○"

  defp rail_phase_color(:done), do: "var(--life-done)"
  defp rail_phase_color(:active), do: "var(--life-in_progress)"
  defp rail_phase_color(:interrupted), do: "var(--life-blocked)"
  defp rail_phase_color(_), do: "var(--life-open)"

  # Agent-row glyph + color: a failed agent is ✕ in --danger (its error string in
  # the title=), a settled one ✓, a live one ●. A non-terminal agent on a DEAD
  # (interrupted) entry reads --life-open (stalled) and never breathes.
  # PUBLIC (and only) so the cross-surface glyph lock can call it directly:
  # api/test/support/fixtures/chat_rail_agent_glyphs.json pins this truth table
  # and is read by BOTH chat_rail_agent_glyph_test.exs and the TUI's
  # internal/chat/rail_glyph_lock_test.go, so a glyph — or an ARM ORDER — edit
  # on either surface reds the other surface's test.
  @doc false
  def rail_agent_glyph(node) do
    cond do
      StudioChat.workflow_node_failed?(node) -> "✕"
      StudioChat.workflow_node_terminal?(node) -> "✓"
      true -> "●"
    end
  end

  defp rail_agent_color(entry, node) do
    cond do
      StudioChat.workflow_node_failed?(node) -> "var(--danger)"
      StudioChat.workflow_node_terminal?(node) -> "var(--life-done)"
      rail_running?(entry) -> "var(--life-in_progress)"
      true -> "var(--life-open)"
    end
  end

  # A node breathes only while its ENTRY is live AND its state is non-terminal — a
  # replayed interrupted workflow's tree (visible on reopen) must never breathe.
  defp rail_node_running?(entry, node),
    do: rail_running?(entry) and not StudioChat.workflow_node_terminal?(node)

  # The rail entry's last-known token total (charter D47), or nil.
  defp rail_tokens(entry) do
    case entry["usage"] do
      %{"total_tokens" => n} when is_integer(n) -> n
      _ -> nil
    end
  end

  defp rail_node_tokens(node) do
    case node["tokens"] do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  # Short names on purpose: a native <select> sizes itself to its LONGEST
  # option, so a verbose label ("Sonnet — balanced") would push the cockpit
  # chevron away from the closed text. One word keeps the row tight.
  defp model_label("haiku"), do: "Haiku"
  defp model_label("sonnet"), do: "Sonnet"
  defp model_label("opus"), do: "Opus"
  defp model_label("fable"), do: "Fable"
  defp model_label(m), do: m

  # The two toggle states carry their product names; the rest keep their raw
  # stories (they still label odd resumed sessions and transcript lines).
  defp mode_label("plan"), do: "Plan"
  defp mode_label("acceptEdits"), do: "accept edits"
  defp mode_label("auto"), do: "Autopilot"
  defp mode_label("dontAsk"), do: "don't ask"
  defp mode_label("manual"), do: "manual approve"
  defp mode_label("bypassPermissions"), do: "bypass · dangerous"
  # The retired middle mode: shown ONLY while a legacy session still carries it.
  defp mode_label("default"), do: "ask (legacy)"
  defp mode_label(other), do: other

  # Which toggle segment a raw permission mode lights up (the presentation
  # projection — the raw vocabulary/wire/DB stay untouched): plan ⇒ Plan,
  # auto ⇒ Autopilot, armed bypass ⇒ the danger segment, anything else (a
  # resumed acceptEdits/manual/dontAsk/legacy-default row) ⇒ the transient
  # third segment until the user picks a side.
  defp mode_segment("plan"), do: :plan
  defp mode_segment("auto"), do: :autopilot
  defp mode_segment("bypassPermissions"), do: :bypass
  defp mode_segment(_), do: :other

  # Effort tiers render verbatim in the picker (charter D48 — "Fable · high").
  defp effort_label(nil), do: "default"
  defp effort_label("default"), do: "default"
  defp effort_label(e), do: e

  # The "(was ~N tokens)" tail on a compaction line — only when the CLI reports a
  # pre-compaction size, so we never invent a number we don't have.
  defp compact_size(pre) when is_integer(pre) and pre > 0, do: " (was ~#{pre} tokens)"
  defp compact_size(_), do: ""

  # The one-word status rendered in the cockpit (beside the context ring) —
  # the honest session-state affordance; tests assert these exact words.
  defp status_label(:new), do: "new chat"
  defp status_label(:resumable), do: "resumable"
  defp status_label(:starting), do: "starting"
  defp status_label(:ready), do: "ready"
  defp status_label(:working), do: "working"
  defp status_label(:thinking), do: "working"
  defp status_label(:interrupting), do: "stopping…"
  defp status_label(:offline), do: "offline"

  # A turn is in flight while the model works or while we're aborting it — both
  # states show Stop, never Send (there is no queue; the only in-turn control
  # is to cancel).
  defp turn_active?(status), do: status in [:thinking, :interrupting]

  # The terminal's elapsed counter, T3 re-render hygiene #10: the server stamps
  # the turn's start ONCE — epoch milliseconds at the user message boundary,
  # the same boundary the transcript folds on — and the BROWSER ticks the label
  # (bp-chat-turn-clock.js, Hooks.ChatElapsed). There is no `:turn_tick` any
  # more: a running turn costs zero LiveView diffs per second per viewer, and an
  # idle tab costs nothing because nothing is scheduled at all.
  defp start_turn_clock(socket),
    do: assign(socket, turn_started_at_ms: System.system_time(:millisecond))

  defp approval_outcome_label(:allowed), do: "✓ allowed"
  defp approval_outcome_label(:canceled), do: "✗ canceled"
  defp approval_outcome_label(_), do: "✗ denied"

  # The idle/ready clause teaches the composer's verbs (charter D44) — never a
  # mic, never @-mentions. The keyboard affordances (D42) live HERE in the
  # placeholder, not in a footer row: visible from the very first mount, gone
  # the moment you type. Degraded states keep their honest, specific copy.
  @idle_placeholder "Plan, build… · / for commands · ↵ to send · esc to interrupt"
  defp composer_placeholder(:new), do: @idle_placeholder
  defp composer_placeholder(:resumable), do: "Message Claude to resume this chat…"
  defp composer_placeholder(:offline), do: "Send a message to resume this session…"
  defp composer_placeholder(:thinking), do: "Claude is working — esc or Stop to interrupt…"
  defp composer_placeholder(:interrupting), do: "Stopping…"
  defp composer_placeholder(_), do: @idle_placeholder

  # ── slash-command menu (charter D36a/D36b) ──────────────────────────────

  # The builtin floor — always offered, even with no live runtime. `builtin:
  # true` marks the ones that route to a control path on submit (the JS just
  # inserts their text; `handle_event("send")` does the routing).
  @slash_builtins [
    %{
      "name" => "/plan",
      "description" => "Plan mode — read-only; discuss and propose before acting",
      "argumentHint" => nil,
      "builtin" => true
    },
    %{
      "name" => "/autopilot",
      "description" => "Autopilot — the agent runs without asking (auto-run)",
      "argumentHint" => nil,
      "builtin" => true
    },
    # The /default builtin is RETIRED (charter D48) — `default` is no longer an
    # offered mode. The toggle surfaces Plan ⇄ Autopilot; /bypass is the armed
    # ceremony's only entry point now that the raw six-mode select is gone.
    %{
      "name" => "/bypass",
      "description" => "Open the bypass arm ceremony (dangerous — skips permissions)",
      "argumentHint" => nil,
      "builtin" => true
    },
    %{
      "name" => "/model",
      "description" => "Switch the model for this session",
      "argumentHint" => "default | haiku | sonnet | opus | fable",
      "builtin" => true
    },
    %{
      "name" => "/task",
      "description" => "Hand a Barkpark task to Claude — or author a new one",
      "argumentHint" => "<task-id> | new <wish>",
      "builtin" => true
    }
  ]

  # The composer's slash vocabulary, JSON-stamped on the form for the client
  # combobox (charter D36b — server-stamped vocab, client listbox). The CLI's
  # advertised commands are AUTHORITATIVE (commands[] wins); the builtin floor
  # fills in only the names the CLI did not advertise, so the three control
  # builtins are always present. Deduped by normalized `/name`.
  defp slash_vocab(commands) do
    advertised =
      commands
      |> List.wrap()
      |> Enum.map(&normalize_slash_command/1)
      |> Enum.reject(&is_nil/1)

    seen = MapSet.new(advertised, & &1["name"])
    floor = Enum.reject(@slash_builtins, &MapSet.member?(seen, &1["name"]))

    advertised ++ floor
  end

  # Normalize one advertised command map into the client menu shape, ensuring a
  # leading slash on the name (the CLI advertises bare names). Drops anything
  # without a usable name.
  defp normalize_slash_command(cmd) when is_map(cmd) do
    case cmd["name"] || cmd[:name] do
      name when is_binary(name) and name != "" ->
        %{
          "name" => ensure_slash(name),
          "description" => cmd["description"] || cmd[:description],
          "argumentHint" => cmd["argumentHint"] || cmd[:argumentHint] || cmd[:argument_hint],
          "builtin" => false
        }

      _ ->
        nil
    end
  end

  defp normalize_slash_command(_), do: nil

  defp ensure_slash("/" <> _ = name), do: name
  defp ensure_slash(name), do: "/" <> name

  # ── sidebar helpers ─────────────────────────────────────────────────────

  # The needs-you strip (wave 12): pure derivation over the ALREADY-loaded
  # sidebar assigns — `sessions` + `pending_ask_roles` (store truth, cold-mount
  # correct) + the live `activity` overlay (arrive/leave freshness). The
  # on-screen session is never "away". All the truth logic lives in
  # `StudioChat.needs_you_strip/2`; this only threads assigns.
  defp strip_entries(assigns) do
    StudioChat.needs_you_strip(assigns.sessions,
      current_session_id: assigns.store_session_id,
      pending_roles: assigns.pending_ask_roles,
      activity: assigns.activity
    )
  end

  # Strip kind → badge class (existing tokenized chat badges — warn for every
  # needs-you kind, working tone for a running turn) and → imperative label.
  # Copy is deliberately DISTINCT from the session-row pill texts ("needs
  # you"/"working"/…) so the two surfaces never read as duplicates.
  defp strip_badge(:working), do: "badge-chat-working"
  defp strip_badge(_needs_you_kind), do: "badge-chat-approval"

  defp strip_label(:pending_approval), do: "approve"
  defp strip_label(:awaiting_input), do: "answer"
  defp strip_label(:plan_ready), do: "plan ready"
  defp strip_label(:working), do: "running"

  # Session → tokenized pill. The live overlay wins over the stored row (wave
  # 5): a Recorder that says "working" right now beats a row the sidebar has
  # not re-read yet. The cold half reads `session.agent_state` (herd wave 1) —
  # see session_pill/1 below.
  # ── wave-session-card lines (wsc charter D8/D11) ──────────────────────────
  # One tick per D3 `ticks` status, straight off the journey truth table (D1 —
  # never re-derived positionally): done settles evergreen (--life-done), the
  # active phase breathes on the EXISTING bp-skel-pulse keyframes
  # (bp-chat-live-dot), an interrupted frontier reads --life-blocked and never
  # breathes (no fake spinners law), and future/skipped/unreached are a dim
  # border-token outline — a skipped Perfect phase stays honestly un-filled
  # instead of faking 7/7. All colors are emitted tokens (charter D60).

  defp workflow_tick_class(:active), do: "bp-chat-live-dot"
  defp workflow_tick_class(_tick), do: nil

  defp workflow_tick_style(tick) do
    base = "width: 5px; height: 5px; border-radius: 50%; flex: none;"

    case tick do
      :done ->
        base <> " background: var(--life-done);"

      :active ->
        base <> " background: var(--life-in_progress);"

      :interrupted ->
        base <> " background: var(--life-blocked);"

      _future_skipped_unreached ->
        base <>
          " background: transparent; border: 1px solid var(--border-muted); box-sizing: border-box;"
    end
  end

  # The phase word + settled/total agent counter (D2: settled = done + failed,
  # the Claude-Code 13/17). A terminal wave settles to "complete · n/n"; an
  # interrupted one names its dead frontier honestly; a live one wears the
  # active phase word. Nothing here is invented — every number is the D3
  # summary's (`outcome` is the journey's entry lifecycle).
  defp workflow_card_line(%{outcome: :completed} = ws),
    do: "complete · #{ws.agents_done}/#{ws.agents_total}"

  defp workflow_card_line(%{outcome: :interrupted} = ws) do
    where = if ws.phase, do: "interrupted in #{ws.phase}", else: "interrupted"
    "#{where} · #{ws.agents_done}/#{ws.agents_total}"
  end

  defp workflow_card_line(ws) do
    "#{ws.phase || "starting"} · #{ws.agents_done}/#{ws.agents_total} agents"
  end

  defp session_pill(_s, %{state: :working}), do: {"badge-chat-working", "working"}
  defp session_pill(_s, %{state: :needs_you}), do: {"badge-chat-approval", "needs you"}
  defp session_pill(_s, %{state: :offline}), do: {"badge-chat-offline", "offline"}
  defp session_pill(s, _act), do: session_pill(s)

  # The COLD half reads the persisted herd column (herd wave 1, charter
  # D38/D40): `agent_state` is the four-state truth the Recorder writes at
  # every flip, so the pill, the needs-you strip, and the fleet wire agree by
  # construction — the old parallel derivation (pending_approvals + status) is
  # gone. `blocked` wears the warn-toned "needs you"; a mid-turn death reads
  # `unknown` and wears "offline"; everything else is honestly idle.
  defp session_pill(%{agent_state: agent_state}), do: session_pill_by_state(agent_state)

  defp session_pill_by_state("working"), do: {"badge-chat-working", "working"}
  defp session_pill_by_state("blocked"), do: {"badge-chat-approval", "needs you"}
  defp session_pill_by_state("unknown"), do: {"badge-chat-offline", "offline"}
  defp session_pill_by_state(_idle), do: {"badge-chat-idle", "idle"}

  # The active row wears the evergreen accent; the rest are transparent (hover
  # tint lives in the render <style>). All colours are emitted tokens.
  defp session_row_style(true),
    do:
      "padding: 8px 9px; border-radius: 8px; text-decoration: none; border: 1px solid hsl(var(--primary-hsl) / 0.35); background: var(--primary-soft);"

  defp session_row_style(false),
    do:
      "padding: 8px 9px; border-radius: 8px; text-decoration: none; border: 1px solid transparent; background: transparent;"

  # Coarse relative age off `last_active_at` (fallback `inserted_at`). Copied
  # from board_live.ex age_label/age_words — no shared module exists.
  defp age_label(%DateTime{} = dt), do: age_words(DateTime.diff(DateTime.utc_now(), dt))

  defp age_label(%NaiveDateTime{} = dt),
    do: age_words(NaiveDateTime.diff(NaiveDateTime.utc_now(), dt))

  defp age_label(_), do: nil

  defp age_words(s) when s < 60, do: "now"
  defp age_words(s) when s < 3_600, do: "#{div(s, 60)}m"
  defp age_words(s) when s < 86_400, do: "#{div(s, 3_600)}h"
  defp age_words(s) when s < 604_800, do: "#{div(s, 86_400)}d"
  defp age_words(s), do: "#{div(s, 604_800)}w"

  defp session_stamp(%{last_active_at: t}) when not is_nil(t), do: age_label(t)
  defp session_stamp(%{inserted_at: t}), do: age_label(t)
  defp session_stamp(_), do: nil

  # ── header context-headroom ring (charter D19) ──────────────────────────
  #
  # A from-scratch inline-SVG arc (no ring prior art in Studio). The arc length
  # IS last_context_tokens / context_window — geometry encodes the datum, colour
  # only reinforces it. Honest unknown: a nil window (pre-migration session, no
  # result yet) draws the track alone + an em-dash, NEVER a fake full/empty arc.

  # Circumference of the r=15.5 arc, evaluated at compile time. The progress
  # circle's stroke-dasharray is "<arc> <circ>" — arc = fraction × circ.
  @ring_circ 2 * :math.pi() * 15.5

  # A ring datum carried in assigns: the CURRENT-turn snapshot, not the summed
  # totals (which cannot express window occupancy). `cost` is the lifetime total.
  defp blank_ring, do: %{context_tokens: nil, context_window: nil, cost: 0.0}

  defp ring_from_session(session) do
    %{
      context_tokens: session.last_context_tokens,
      context_window: session.context_window,
      cost: session.total_cost_usd || 0.0
    }
  end

  # Known only when BOTH the used-tokens and a positive window are present.
  defp ring_geometry(%{context_tokens: used, context_window: window})
       when is_integer(used) and used >= 0 and is_integer(window) and window > 0 do
    frac = min(used / window, 1.0)
    %{known: true, frac: frac, pct: round(frac * 100)}
  end

  defp ring_geometry(_), do: %{known: false, frac: 0.0, pct: nil}

  # Token ramp (charter D19): ok < 70% · warn 70–90% · danger ≥ 90%. All tokens.
  defp ring_color(frac) when frac >= 0.9, do: "var(--danger)"
  defp ring_color(frac) when frac >= 0.7, do: "var(--warn)"
  defp ring_color(_), do: "var(--ok)"

  defp ring_dash(frac) do
    arc = frac * @ring_circ
    "#{Float.round(arc, 2)} #{Float.round(@ring_circ, 2)}"
  end

  defp ring_title(%{context_tokens: used, context_window: window})
       when is_integer(used) and is_integer(window) and window > 0 do
    "Context: #{used} / #{window} tokens"
  end

  defp ring_title(_), do: "Context window unknown until the first result"

  defp format_cost(cost) when is_number(cost) and cost > 0 do
    "$" <> :erlang.float_to_binary(cost / 1, decimals: 4)
  end

  defp format_cost(_), do: "$0.0000"

  attr :ring, :map, required: true
  attr :size, :atom, default: :md
  attr :show_cost, :boolean, default: true

  defp context_ring(assigns) do
    # Geometry is viewBox-relative (0 0 36 36) so the arc math is size-agnostic —
    # only the pixel width/height and the 9px % label change between :md and :sm
    # (charter D44: the miniature footer ring drops the label, keeping just the arc).
    assigns =
      assigns
      |> assign(:geo, ring_geometry(assigns.ring))
      |> assign(:px, if(assigns.size == :sm, do: 16, else: 30))
      |> assign(:show_pct, assigns.size != :sm)

    ~H"""
    <div style="display: inline-flex; align-items: center; gap: 8px;" title={ring_title(@ring)}>
      <div style="position: relative; display: inline-flex; align-items: center; justify-content: center;">
        <svg width={@px} height={@px} viewBox="0 0 36 36" style="display: block;" aria-hidden="true">
          <circle cx="18" cy="18" r="15.5" fill="none" stroke="var(--primary-soft)" stroke-width="3.5" />
          <circle
            :if={@geo.known}
            cx="18"
            cy="18"
            r="15.5"
            fill="none"
            stroke={ring_color(@geo.frac)}
            stroke-width="3.5"
            stroke-linecap="round"
            stroke-dasharray={ring_dash(@geo.frac)}
            transform="rotate(-90 18 18)"
          />
        </svg>
        <span
          :if={@show_pct}
          class="text-dim"
          style="position: absolute; font-size: 9px; font-weight: 600; font-variant-numeric: tabular-nums;"
        >
          <%= if @geo.known, do: "#{@geo.pct}%", else: "—" %>
        </span>
      </div>
      <span
        :if={@show_cost}
        class="text-xs text-dim"
        style="font-family: var(--font-mono); font-variant-numeric: tabular-nums;"
      >
        <%= format_cost(@ring.cost) %>
      </span>
    </div>
    """
  end

  defp format_duration(ms) when is_integer(ms) and ms >= 1000,
    do: "#{Float.round(ms / 1000, 1)}s"

  defp format_duration(ms) when is_integer(ms), do: "#{ms}ms"
  defp format_duration(_), do: "–"

  defp spawn_error_text(:disabled),
    do: "Claude chat is not enabled on this host."

  defp spawn_error_text(:binary_not_found),
    do:
      "The `claude` binary is not installed on this host. Install Claude Code and run `claude auth login`."

  defp spawn_error_text(_),
    do: "Failed to start the Claude session."

  # Honest line for a user turn that never reached the model (charter D24): the
  # port write failed or the session had already gone. The words are restored to
  # the composer, so this is a "try again", not a "your message is lost".
  defp send_error_text(_reason),
    do:
      "That message didn't reach Claude — the session dropped. Your words were kept; send again."

  # ── the transcript header's context identity (chat-local-cloud-context-w3) ──
  #
  # The GATHERING half only: which host runs this session, on which server, in
  # which workspace / project / dataset, out of which repository root.
  # `Barkpark.StudioChat.ContextIdentity` owns the two laws (a displayed value
  # comes from the actual binding; absence is visible and typed) and every
  # rendering decision — this reads the facts and hands them over.
  #
  # Called on mount, on session load, on the new-chat reset and on a host state
  # report. NEVER per render: the band lives in an assign precisely so a
  # streaming turn does not re-query the lease table sixty times a second.
  defp assign_context_identity(socket) do
    assign(socket, context_identity: build_context_identity(socket))
  end

  defp build_context_identity(socket) do
    session = stored_session(socket)

    hosts =
      case session do
        %{id: id} -> ChatHosts.session_execution_identity(id)
        _ -> %{lease_host: nil, reporting_host: nil}
      end

    ContextIdentity.resolve(%{
      lease_host: hosts.lease_host,
      reporting_host: hosts.reporting_host,
      endpoint: server_endpoint(),
      viewer_workspace: viewer_workspace_slug(socket),
      session_workspace: session_workspace_slug(session),
      project: project_slug(socket),
      scope_dataset: socket.assigns[:scope_dataset],
      mount_dataset: socket.assigns[:dataset],
      execution_target: session && session.execution_target,
      cwd: session && session.cwd,
      repo_probe: ContextIdentity.repo_probe()
    })
  end

  # The STORED row (not the `@session` runtime pid): the band needs
  # `owner_workspace_id`, `execution_target` and `cwd`, none of which live in
  # assigns. `:global` because the tenancy clamp already ran at load time —
  # `store_session_id` is only ever set by `load_stored_session/2`, which is
  # reached through `get_session_in_tenancy/2`.
  defp stored_session(socket) do
    case socket.assigns[:store_session_id] do
      id when is_binary(id) -> StudioChat.get_session(id, :global)
      _ -> nil
    end
  end

  # The server the browser is actually talking to, read at RUNTIME off the
  # endpoint config. Never a compile-time literal — a baked-in URL that silently
  # disagrees with the running endpoint is exactly the class of string this band
  # exists to stop trusting.
  defp server_endpoint do
    BarkparkWeb.Endpoint.url()
  rescue
    _ -> nil
  end

  # The workspace the VIEWER is acting in: the URL scope on the scoped mount,
  # the acting token's own workspace on the flat one (which carries no
  # `current_workspace` — its live_session has no LiveScope hook). This is the
  # CLAIM half of the workspace comparison; the session's own owner is the other.
  defp viewer_workspace_slug(socket) do
    case socket.assigns[:current_workspace] do
      %{slug: slug} when is_binary(slug) ->
        slug

      _ ->
        workspace_slug(principal_workspace_id(socket))
    end
  end

  defp session_workspace_slug(%{owner_workspace_id: ws_id}), do: workspace_slug(ws_id)
  defp session_workspace_slug(_), do: nil

  defp workspace_slug(ws_id) do
    case Tenancy.get_workspace_by_id(ws_id) do
      %{slug: slug} when is_binary(slug) -> slug
      _ -> nil
    end
  end

  defp project_slug(socket) do
    case socket.assigns[:current_project] do
      %{slug: slug} when is_binary(slug) -> slug
      _ -> nil
    end
  end

  defp default_dataset do
    case Barkpark.Content.list_datasets() do
      [ds | _] when is_binary(ds) -> ds
      _ -> "production"
    end
  rescue
    _ -> "production"
  end
end
