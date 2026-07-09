defmodule BarkparkWeb.Studio.ChatLive do
  @moduledoc """
  Studio **Claude chat** at `/studio/chat` — admin-only agent chat backed by
  the host's Claude Code CLI. Sessions are a PLACE: every conversation is
  persisted (`Barkpark.StudioChat`), listed in the sidebar, addressable at
  `/studio/chat/:session_id`, and resumable via the CLI's `--resume`.

  The chat subprocess is owned by `BarkparkWeb.Studio.ClaudeChat.Session`,
  started lazily on the first send — never on mount, never on reopen
  (reopen replays OUR persisted history instantly). Every decoded
  stream-json event arrives here as `{:claude_chat_event, map}`:

    * `system/init`   → model + session id for the header
    * `stream_event`  → `text_delta`s accumulate into the in-progress bubble
    * `assistant`     → the completed message replaces the streaming buffer
                        (t3code's accumulate-and-reconcile pattern); tool_use
                        blocks render as dim activity lines
    * `result`        → the turn is over — back to ready, usage in the footer

  Gating lives in `BarkparkWeb.Studio.ClaudeChat` — this mount redirects out
  unless `ClaudeChat.enabled?/0` (which hard-refuses public-demo hosts and
  honors the per-host opt-out), and the `:admin_studio` live_session carrying
  the route applies the admin `on_mount` gate.

  Zero JS: the transcript scroll container is `column-reverse`, so the newest
  content sticks to the bottom without a hook; the composer input remounts
  (id bump) to clear after each send.
  """

  use BarkparkWeb, :live_view

  require Logger

  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.PortableDoc.Render
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.PlanPapers
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.Studio.ChatToolRenderer
  alias BarkparkWeb.Studio.ClaudeChat

  # Spawn-row heuristics + labels for the nested agent trace (charter D40) — pure
  # helpers shared by the live render and the store-replay path.
  import BarkparkWeb.Studio.ChatToolRenderer, only: [spawn?: 2, spawn_label: 2]

  # How long a Stop may sit in `:interrupting` before we force-close a wedged
  # CLI (charter D18). Config-overridable so tests can drive the timeout fast.
  @default_interrupt_timeout_ms 8_000

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
  def mount(_params, _session, socket) do
    if ClaudeChat.enabled?() do
      {:ok,
       socket
       |> assign(
         page_title: "chat",
         nav_section: :chat,
         dataset: default_dataset(),
         # current_path is owned by StudioChrome's :handle_params hook, which
         # also keeps it fresh across the /studio/chat/:session_id patches
         # (this static string used to freeze the active tab on reopen).
         session: nil,
         store_session_id: nil,
         session_id: nil,
         sessions: StudioChat.list_sessions(),
         show_archived: false,
         renaming_session: nil,
         open_menu_session: nil,
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
         mode: "plan",
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
         next_id: 0,
         # The in-memory id of THIS turn's TodoWrite living-checklist card
         # (charter D39). The turn's first TodoWrite appends a :todo card and
         # records its id here; every later TodoWrite supersedes that card in
         # place. Reset to nil on the broadcast `system/init` (the per-turn
         # boundary) and on every session load.
         todo_card_id: nil,
         streaming: nil,
         # The live extended-thinking pulse (charter D41): nil, or
         # %{tokens: N, text: ""}. Driven by `system/thinking_tokens` frames — the
         # wire never carries thinking text, so the row shows a "✻ thinking… ~N
         # tokens" counter that settles into a durable `:thinking` message the
         # instant real output (text/tool/result) begins.
         thinking_pulse: nil,
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
         turn_elapsed_s: 0,
         turn_clock_armed: false,
         subscribed_topic: nil,
         # Per-tab AskUserQuestion answer state (charter D31/D35): request_id →
         # %{selections: %{qidx => [labels]}, custom: %{qidx => text}}. Chip picks
         # and custom text stay SOCKET-LOCAL — never broadcast — until the ONE
         # submit resolves the ask; the resolution itself broadcasts.
         question_forms: %{},
         # Live sidebar overlay (wave 5): session_id → %{state, line}, fed by
         # every Recorder's activity broadcasts. Renders over the stored row.
         activity: %{},
         last_result: nil,
         ring: blank_ring(),
         title_source: "default",
         title_kicked: false
       )
       |> subscribe_activity()
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
      {:ok,
       socket
       |> put_flash(:error, "Claude chat is not enabled on this instance.")
       |> redirect(to: "/studio")}
    end
  end

  # Single source of truth for the on-screen session. Fires on the initial mount
  # AND on every `push_patch` (sidebar click, new-chat, first-send self-patch).
  @impl true
  def handle_params(%{"session_id" => sid}, _uri, socket) do
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

        case StudioChat.get_session(sid) do
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

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> capture_draft() |> reset_to_new_chat()}
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

      :model_usage ->
        {:noreply,
         socket
         |> clear_persisted_draft()
         |> append_message(:system, "Usage: /model default · haiku · sonnet · opus · fable")
         |> clear_composer()}

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
        ClaudeChat.interrupt(socket.assigns.session)

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

  def handle_event("set-mode", %{"mode" => mode}, socket) do
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
     |> change_mode(ClaudeChat.normalize_mode(mode))}
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
      if sid = socket.assigns[:store_session_id], do: StudioChat.set_mode(sid, "bypassPermissions")

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
    {:noreply, change_model(socket, ClaudeChat.normalize_model(raw))}
  end

  # Pick the reasoning-effort tier (charter D48). Intent-only: it persists on the
  # row and rides the NEXT spawn as --effort. There is NO set_effort control verb
  # (the four control subtypes are closed), so a mid-session change never steers
  # the running turn — we post an honest "applies from the next resume" line.
  def handle_event("set-effort", %{"effort" => raw}, socket) do
    {:noreply, change_effort(socket, ClaudeChat.normalize_effort(raw))}
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

  # Expand/collapse a rail workflow row's phase→agent tree (charter D47). The
  # per-tab `rail_expanded` map is keyed by task_id; default collapsed, a manual
  # toggle flips it. Never broadcast — a co-viewer's expand is their own.
  def handle_event("rail-toggle", %{"id" => id}, socket) do
    current = Map.get(socket.assigns.rail_expanded, id, false)
    {:noreply, assign(socket, rail_expanded: Map.put(socket.assigns.rail_expanded, id, not current))}
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
        # overwritten by the AI titler (charter D13).
        StudioChat.rename(id, title)
        refresh_sessions(socket)
      end

    {:noreply, socket}
  end

  def handle_event("session-rename-cancel", _params, socket) do
    {:noreply, assign(socket, renaming_session: nil)}
  end

  def handle_event("session-archive", %{"id" => id}, socket) do
    StudioChat.archive_session(id)
    {:noreply, after_lifecycle_mutation(socket, id)}
  end

  # Unarchive keeps an on-screen session on screen (store_session_id unchanged);
  # it only leaves the archived shelf, so a refresh is enough — no push_patch.
  def handle_event("session-unarchive", %{"id" => id}, socket) do
    StudioChat.unarchive_session(id)
    {:noreply, socket |> assign(open_menu_session: nil) |> refresh_sessions()}
  end

  def handle_event("session-delete", %{"id" => id}, socket) do
    StudioChat.delete_session(id)
    {:noreply, after_lifecycle_mutation(socket, id)}
  end

  # Flip the active ⇄ archived shelf. refresh_sessions reads the new flag.
  def handle_event("toggle-archived", _params, socket) do
    show = not (socket.assigns.show_archived == true)

    {:noreply,
     socket |> assign(show_archived: show, open_menu_session: nil) |> refresh_sessions()}
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
        {:ok, request_id} = ClaudeChat.set_permission_mode(session, mode)
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
    if session = socket.assigns[:session], do: ClaudeChat.set_model(session, choice || "default")

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
  # The floor is /plan · /model (the retired /default builtin is gone, charter
  # D48 — `default` is no longer an offered mode); session-mutating CLI commands
  # (/compact, /clear) are NOT builtins — they ride through as plain user text
  # so the CLI handles them itself, and our store identity is pinned by
  # `--session-id`/`--resume` regardless of what a slash-turn result echoes (D8;
  # spot-check assumption per D36b — we never scrape ids off frames).
  defp builtin_command("/plan"), do: {:set_mode, "plan"}
  defp builtin_command("/model"), do: :model_usage

  defp builtin_command(text) when is_binary(text) do
    case String.split(text, ~r/\s+/, trim: true) do
      ["/model", "default"] ->
        {:set_model, nil}

      ["/model", arg] ->
        # normalize_model fails closed to nil — but for a TYPED command that
        # would silently reset a sticky choice to the CLI default on any typo
        # ("/model opsu"). An unrecognized alias shows usage instead; only an
        # explicit "/model default" resets.
        case ClaudeChat.normalize_model(arg) do
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
            case ClaudeChat.send_message(session, blocks) do
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
       todo_card_id: nil,
       messages: clear_queued_badges(socket.assigns.messages)
     )
     |> observe_permission_mode(observed)}
  end

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
    interrupted? =
      socket.assigns[:interrupt_requested] == true or
        ev["terminal_reason"] == "aborted_streaming"

    socket =
      cond do
        ev["subtype"] == "success" ->
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
  def handle_info({:chat_title, _session_id, _title}, socket) do
    {:noreply, refresh_sessions(socket)}
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
      |> assign(messages: socket.assigns.messages ++ [message], next_id: id + 1)
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
          case Enum.find(results, fn {id, _out} -> id == m[:tool_use_id] end) do
            {_id, out} -> Map.put(m, :output, out)
            nil -> m
          end
        end)

      {:noreply, assign(socket, messages: messages)}
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
    socket = fold_rail(socket, StudioChat.rail_stamp_status(socket.assigns.rail, ev["task_id"], ev["status"]))

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
        socket = fold_rail(socket, StudioChat.rail_stamp_status(socket.assigns.rail, ev["task_id"], status))
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
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "background_tasks_changed"} = ev},
        socket
      ) do
    {:noreply, fold_rail(socket, StudioChat.rail_apply_background(socket.assigns.rail, ev))}
  end

  def handle_info({:claude_chat_event, _event}, socket), do: {:noreply, socket}

  # A real port exit (exit_status frame). Run the shared honest teardown.
  def handle_info({:claude_chat_exit, status}, socket) do
    {:noreply,
     teardown_session(
       socket,
       "Claude session ended (exit #{status}). Send a message to resume it."
     )}
  end

  # The interrupt timed out (charter D18). CRITICAL: `ClaudeChat.close/1` does
  # NOT emit {:claude_chat_exit} (only a real port exit_status does), so this
  # path must force-close AND run teardown itself. Guarded: a `result` arriving
  # first left `:interrupting`, and a session switch changed `store_session_id`
  # — both make a stale timer a no-op.
  def handle_info({:interrupt_timeout, sid}, socket) do
    if socket.assigns.status == :interrupting and socket.assigns[:store_session_id] == sid do
      if pid = socket.assigns[:session], do: ClaudeChat.close(pid)

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
     |> assign(
       messages: socket.assigns.messages ++ [message],
       next_id: id + 1,
       status: :thinking
     )}
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
     |> assign(messages: messages)
     |> clear_question_form(request_id)
     |> refresh_sessions()}
  end

  # D49: an approved plan's Paper landed — stamp the in-memory plan row so its
  # "→ published as Paper" link appears in EVERY co-viewing tab at once (the
  # approver's own tab is subscribed too, so it converges here, not inline). The
  # metadata was already persisted by the publishing Task, so replay is durable.
  def handle_info({:plan_paper, request_id, %{paper_id: paper_id, paper_url: paper_url}}, socket) do
    messages = stamp_plan_paper(socket.assigns.messages, request_id, paper_id, paper_url)
    {:noreply, assign(socket, messages: messages)}
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

  def handle_info(:turn_tick, socket) do
    if turn_active?(socket.assigns.status) do
      Process.send_after(self(), :turn_tick, 1_000)
      {:noreply, assign(socket, turn_elapsed_s: socket.assigns.turn_elapsed_s + 1)}
    else
      {:noreply, assign(socket, turn_clock_armed: false)}
    end
  end

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

  def handle_info(_msg, socket), do: {:noreply, socket}

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
        <%!-- A Task/agent spawn (charter D40) gets a headline row: the
              ● gutter plus the sub-agent's description; the frames it
              emits interleave below, indented under it. A plain tool row
              keeps the terse mono line. --%>
        <%!-- Hanging indent: glyph and text are flex columns, so a
              wrapped line continues under the TEXT, never under the ●. --%>
        <div :if={@message[:spawn?]} class="text-xs" style="font-family: var(--font-mono); display: flex; gap: 6px;">
          <span style="color: var(--primary); flex: none;">●</span>
          <span style="min-width: 0; overflow-wrap: anywhere;">
            <span style="font-weight: 650;" data-gutter-text>{@message[:spawn_label] || @message.text}</span>
            <span class="text-dim" style="margin-left: 6px; opacity: 0.7;">agent</span>
          </span>
        </div>
        <div :if={!@message[:spawn?]} class="text-xs" style="font-family: var(--font-mono); display: flex; gap: 6px;">
          <span style="color: var(--primary); flex: none;">●</span>
          <span style="min-width: 0; overflow-wrap: anywhere;" data-gutter-text>{@message.text}</span>
        </div>
        <%!-- D38: a file-mutating tool call renders as a real colored
              diff (dispatch on input SHAPE, not tool name) beneath the
              ● header; a non-diff shape renders nothing here and keeps
              the generic ⎿ row below. --%>
        <ChatToolRenderer.tool_diff
          :if={ChatToolRenderer.diff?(@message[:input])}
          input={@message.input}
        />
        <%!-- The terminal's ⎿ result line: first line inline; multi-
              line outputs expand on click (details/summary). --%>
        <div
          :if={@message[:output] not in [nil, ""]}
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
        <%!-- The living checklist card (charter D39): one ☐/◐/☒ card the
              Recorder collapsed + the reducer superseded, so it renders
              the turn's LATEST todo state whether live or replayed. --%>
        <ChatToolRenderer.todo_card todos={@message.todos} />
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
        <%!-- Settled thinking bout (charter D41): dim mono ✻, no text
              ever — only "thought for ~N tokens". Same shape live and on
              replay. --%>
        <div class="text-xs text-dim" style="font-family: var(--font-mono);">
          <span aria-hidden="true">✻</span> <%= @message.text %>
        </div>
      <% _ -> %>
        <div class="text-xs text-dim" style="font-family: var(--font-mono);">
          <span aria-hidden="true">✻</span> <%= @message.text %>
        </div>
    <% end %>
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
      </style>
      <aside style="width: 280px; flex: none; border-right: 1px solid var(--border-muted); display: flex; flex-direction: column; min-height: 0;">
        <div style="display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--border-muted); flex: none;">
          <span class="h3" style="display: flex; align-items: center; gap: 8px; flex: 1;">
            <.icon name="message-circle" size={15} /> chats
          </span>
          <.link
            patch="/studio/chat"
            class="btn btn-primary text-xs"
            style="display: inline-flex; align-items: center; gap: 4px; padding: 3px 9px;"
          >
            <.icon name="plus" size={13} /> New
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
              This is your remembered agent workspace. Every conversation with
              <code>claude</code> on this host is saved here — reopen one to pick up
              exactly where you left off. Admins only.
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
                <.link patch={"/studio/chat/#{s.id}"} class="bp-chat-session-link">
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
      <%!-- Slim header (charter D44): title + one honest status label. The mode
            select, model picker + observed-model fact, context ring, and Send/Stop
            all moved into the composer footer cockpit below — where you type. --%>
      <div style="display: flex; align-items: center; gap: 10px; padding: 8px 16px; border-bottom: 1px solid var(--border-muted); flex: none;">
        <span class="h3" style="display: flex; align-items: center; gap: 8px;">
          <.icon name="message-circle" size={16} /> chat
        </span>
        <span class="text-xs text-dim" style="margin-left: auto;">
          <%= status_label(@status) %> — Claude on this host, admins only.
        </span>
      </div>

      <div
        id="chat-transcript"
        style="flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column-reverse; padding: 16px;"
      >
        <div style="display: flex; flex-direction: column; gap: 10px; max-width: 860px; width: 100%; margin: 0 auto;">
          <p :if={@messages == [] and @streaming == nil} class="text-sm text-dim">
            An agent chat backed by this host's <code>claude</code> login. Plan mode: it can
            read this host's files, but cannot edit or execute anything.
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
            <%= for item <- group_agent_rows(@messages) do %>
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
              thinking… ~<%= @thinking_pulse.tokens %> tokens
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
            <%= case classify_tail(streaming_tail(@streaming)) do %>
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
          </div>

          <div
            :if={@streaming == nil and @thinking_pulse == nil and turn_active?(@status)}
            class="text-xs text-dim"
            style="font-family: var(--font-mono); display: flex; align-items: center; gap: 8px;"
          >
            <span class="bp-chat-spinner" aria-hidden="true"></span>
            <span>
              <%= if @status == :interrupting, do: "stopping…", else: "working…" %>
              <%= if @turn_elapsed_s > 0 do %>
                <span style="opacity: 0.8;"><%= @turn_elapsed_s %>s</span>
              <% end %>
              · Stop to interrupt
            </span>
          </div>
        </div>
      </div>

      <div style="flex: none; border-top: 1px solid var(--border-muted); padding: 10px 16px;">
        <form
          id="chat-composer-form"
          phx-hook="ChatComposer"
          phx-submit="send"
          phx-change="composer-change"
          data-commands={Jason.encode!(slash_vocab(@commands))}
          style="display: flex; flex-direction: column; gap: 8px; max-width: 860px; margin: 0 auto;"
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
                style="width: 100%; background: var(--bg); color: inherit; border: 1px solid var(--border-muted); border-radius: 8px; padding: 8px 12px; font: inherit;"
              />
              <%!-- phx-update="ignore": the combobox hook OWNS this element —
                    every keystroke round-trips (server-bound composer, D24) and
                    without the ignore, the returning patch re-applies `hidden`
                    and wipes the options the instant the menu opens. --%>
              <ul
                id="chat-slash-menu"
                phx-update="ignore"
                role="listbox"
                aria-label="Slash commands"
                hidden
                style="position: absolute; bottom: calc(100% + 6px); left: 0; right: 0; margin: 0; padding: 4px; list-style: none; max-height: 240px; overflow-y: auto; background: var(--surface); border: 1px solid var(--border-muted); border-radius: 8px; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.18); z-index: 20;"
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
        <div style="display: flex; align-items: center; gap: 10px; max-width: 860px; margin: 8px auto 0;">
            <div style="display: flex; align-items: center; gap: 8px; min-width: 0;">
              <form phx-change="set-mode" style="display: inline-flex; align-items: center;">
                <select
                  name="mode"
                  class="text-xs text-dim"
                  aria-label="Permission mode"
                  style="background: transparent; color: inherit; border: none; border-radius: 6px; padding: 2px 4px; cursor: pointer;"
                >
                  <%!-- The retired middle mode surfaces ONLY while THIS session still
                        carries it (charter D48) — a legacy row keeps spawning it
                        verbatim, but it is never an offered choice for a fresh pick. --%>
                  <option :if={@mode == "default"} value="default" selected>
                    <%= mode_label("default") %>
                  </option>
                  <option :for={m <- ClaudeChat.modes()} value={m} selected={m == @mode}>
                    <%= mode_label(m) %>
                  </option>
                </select>
              </form>
              <%!-- Model picker (wave 5): the choice is intent — it rides the next
                    spawn as `--model` and steers a live session via the set_model
                    control frame; the dim mono suffix is FACT (the answering model
                    observed off the last init/result), sitting beside its intent. --%>
              <form phx-change="set-model" style="display: inline-flex; align-items: center; gap: 6px;">
                <select
                  name="model"
                  class="text-xs"
                  aria-label="Model"
                  style="background: transparent; color: var(--primary); border: none; border-radius: 6px; padding: 2px 4px; font-weight: 600; cursor: pointer;"
                >
                  <option value="default" selected={@model_choice == "default"}>
                    model: default
                  </option>
                  <option :for={m <- ClaudeChat.models()} value={m} selected={m == @model_choice}>
                    <%= model_label(m) %>
                  </option>
                </select>
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
                    one "Fable · high" group — the dim "·" reads them as a pair. It
                    is intent-only (rides the next spawn as `--effort`); a mid-session
                    change never steers the running turn (no set_effort control verb). --%>
              <span class="text-xs text-dim" aria-hidden="true">·</span>
              <form phx-change="set-effort" style="display: inline-flex; align-items: center;">
                <select
                  name="effort"
                  class="text-xs"
                  aria-label="Reasoning effort"
                  style="background: transparent; color: var(--primary); border: none; border-radius: 6px; padding: 2px 4px; font-weight: 600; cursor: pointer;"
                >
                  <option value="default" selected={@effort_choice == "default"}>
                    effort: default
                  </option>
                  <option :for={e <- ClaudeChat.efforts()} value={e} selected={e == @effort_choice}>
                    <%= effort_label(e) %>
                  </option>
                </select>
              </form>
            </div>
            <div style="display: flex; align-items: center; gap: 8px; margin-left: auto;">
              <.context_ring ring={@ring} size={:sm} show_cost={false} />
              <%!-- Attach an image (charter D44/D25): a <label> for the hidden
                    live_file_input (whose id is the upload ref) opens the native
                    picker with ZERO hook change. The strip / paste-drop are below. --%>
              <label
                for={@uploads.attachments.ref}
                class="btn"
                aria-label="Attach an image"
                title="Attach an image"
                style="display: inline-flex; align-items: center; justify-content: center; padding: 4px 8px; cursor: pointer;"
              >
                <.icon name="image" size={16} />
              </label>
              <%!-- While a turn runs the primary button becomes Stop (interrupt),
                    but pressing ↵ still submits: a mid-turn send is queued honestly
                    (charter D43) — dispatched immediately, run as the next turn. --%>
              <button
                :if={turn_active?(@status)}
                type="button"
                class="btn"
                phx-click="stop_turn"
                disabled={@status == :interrupting}
                aria-label="Stop the current turn"
                style="display: inline-flex; align-items: center; gap: 6px;"
              >
                <span style="display: inline-block; width: 10px; height: 10px; background: currentColor; border-radius: 2px;"></span>
                <%= if @status == :interrupting, do: "Stopping…", else: "Stop" %>
              </button>
              <button
                :if={not turn_active?(@status)}
                type="submit"
                form="chat-composer-form"
                class="btn btn-primary"
                aria-label="Send message"
              >
                <.icon name="send" size={14} />
              </button>
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
        <p :if={@last_result && @last_result.cost_usd} class="text-xs text-dim" style="max-width: 860px; margin: 6px auto 0; font-family: var(--font-mono);">
          <%= @mode %> ⏵ <%= (@init && @init.model) || @model_choice %> · <%= format_duration(@last_result.duration_ms) %> · $<%= :erlang.float_to_binary(@last_result.cost_usd / 1, decimals: 4) %>
        </p>
        <%!-- Keyboard-first footer hint (charter D42): unconditional so the
              affordances are visible from the very first mount, before any turn
              completes — a sibling of the cost strip, never gated on it. --%>
        <p class="text-xs text-dim" style="max-width: 860px; margin: 4px auto 0; font-family: var(--font-mono); opacity: 0.7;">
          esc interrupt · / commands · ↵ send
        </p>

        <%!-- Agents rail (charter D47): the Claude-Code-TUI mission-control view,
              directly below the composer. One row per background task; a workflow
              row expands (per-tab) into its phase→agent tree with breathing state
              glyphs, models, and token counts. Hydrated from `rail_snapshot` on
              reopen; a dead "running" entry reads "interrupted", never a spinner. --%>
        <.agents_rail :if={map_size(@rail) > 0} rail={@rail} rail_expanded={@rail_expanded} />
      </div>
      </div>
    </div>
    """
  end

  # The agents rail (charter D47) — mission control below the composer. Distinct
  # from the D45/D46 transcript spawn rows BY DESIGN (this is live state, that is
  # history); no dedup. All chrome via emitted tokens.
  attr :rail, :map, required: true
  attr :rail_expanded, :map, required: true

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

      <div
        :for={entry <- rail_rows(@rail)}
        data-rail-task={entry["task_id"]}
        data-rail-status={entry["status"]}
        style="padding: 3px 0;"
      >
        <div class="text-xs" style="display: flex; align-items: baseline; gap: 6px;">
          <span
            aria-hidden="true"
            class={rail_running?(entry) && "bp-chat-agent-run"}
            style={"flex: none; color: #{if rail_running?(entry), do: "var(--primary)", else: "var(--text-dim)"};"}
          >
            <%= rail_glyph_type(entry) %>
          </span>
          <span style="min-width: 0; overflow-wrap: anywhere; flex: 1;">
            <span style="font-weight: 600;"><%= rail_label(entry) %></span>
            <span
              class="text-dim"
              style={"margin-left: 6px; opacity: 0.75; color: #{rail_status_color(entry["status"])};"}
            >
              · <%= rail_status_label(entry["status"]) %>
            </span>
            <span :if={rail_tokens(entry)} class="text-dim" style="margin-left: 6px; opacity: 0.7;">
              · <%= rail_tokens(entry) %> tok
            </span>
          </span>
          <button
            :if={rail_workflow_nodes(entry) != []}
            type="button"
            class="btn text-xs"
            phx-click="rail-toggle"
            phx-value-id={entry["task_id"]}
            aria-expanded={to_string(Map.get(@rail_expanded, entry["task_id"], false))}
            style="flex: none; padding: 1px 8px; opacity: 0.8;"
          >
            <%= if Map.get(@rail_expanded, entry["task_id"], false), do: "collapse", else: "expand" %>
          </button>
        </div>

        <%!-- The phase→agent tree, per-tab expandable (charter D47). Phase nodes
              head a group; agent nodes indent beneath with model + breathing
              state glyph + token count. --%>
        <div
          :if={Map.get(@rail_expanded, entry["task_id"], false) and rail_workflow_nodes(entry) != []}
          style="padding-left: 16px; margin-top: 2px;"
        >
          <div
            :for={node <- rail_workflow_nodes(entry)}
            data-rail-node={node["type"]}
            class="text-xs"
            style="display: flex; align-items: baseline; gap: 6px; padding: 1px 0; overflow-wrap: anywhere;"
          >
            <%= case node["type"] do %>
              <% "workflow_phase" -> %>
                <span style="font-weight: 600; color: var(--text);">
                  <%= node["title"] || node["label"] || "phase" %>
                </span>
              <% _ -> %>
                <span
                  aria-hidden="true"
                  class={rail_node_running?(node) && "bp-chat-agent-run"}
                  style={"flex: none; color: #{if rail_node_running?(node), do: "var(--primary)", else: "var(--text-dim)"};"}
                >
                  ●
                </span>
                <span style="min-width: 0; flex: 1;">
                  <%= node["label"] || node["title"] || "agent" %>
                  <span :if={node["model"]} class="text-dim" style="margin-left: 6px; opacity: 0.7;">
                    <%= node["model"] %>
                  </span>
                  <span :if={rail_node_tokens(node)} class="text-dim" style="margin-left: 6px; opacity: 0.7;">
                    · <%= rail_node_tokens(node) %> tok
                  </span>
                </span>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

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
        <span class="bp-skel-dot"></span> rendering <%= skeleton_label(@kind) %>…
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
  defp ensure_session(%{assigns: %{session: session}} = socket) when is_pid(session), do: socket

  defp ensure_session(socket) do
    case socket.assigns.store_session_id do
      nil ->
        id = Ecto.UUID.generate()

        # De-fanged strict match (charter D24): a create failure must NOT crash
        # the LiveView (a crashed tab restores nothing). Post an honest line and
        # go offline; the caller withdraws the echo and hands the words back.
        case StudioChat.create_session(%{
               id: id,
               cwd: ClaudeChat.cwd(),
               mode: socket.assigns.mode
             }) do
          {:ok, _} ->
            socket
            |> assign(store_session_id: id, session_id: id, status: :working)
            |> push_patch(to: "/studio/chat/#{id}")
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
    with {:ok, recorder} <-
           Recorder.ensure(%{
             session_id: store_id,
             mode: socket.assigns.mode,
             resume: resume?,
             model: ClaudeChat.normalize_model(socket.assigns[:model_choice]),
             effort: ClaudeChat.normalize_effort(socket.assigns[:effort_choice]),
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
      |> refresh_sessions()
    else
      {:error, reason} ->
        socket
        |> append_message(:system, spawn_error_text(reason))
        |> assign(session: nil, status: :offline)
    end
  end

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

    assign(socket,
      messages: Enum.reject(socket.assigns.messages, &(&1.id == echo_id)),
      composer_draft: text,
      pending_echo_id: nil
    )
  end

  # Drop the phase-1 text-only echo WITHOUT restoring the composer — used when a
  # dispatched turn carries images (D25) and the echo upgrades to the full
  # text+thumbnails bubble. A no-op when there is no pending echo.
  defp withdraw_pending_echo(socket) do
    echo_id = socket.assigns[:pending_echo_id]

    assign(socket,
      messages: Enum.reject(socket.assigns.messages, &(&1.id == echo_id)),
      pending_echo_id: nil
    )
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
      case live_runtime(session.id) do
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
      arming_bypass: reopened_bypass?(session),
      bypass_confirm: "",
      bypass_live_armed: false,
      bypass_disarmed: reopened_bypass?(session),
      status: status,
      init: replay_init(session),
      messages: messages,
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
      # Rail replay parity (charter D47): hydrate the mission-control rail from
      # the stored `rail_snapshot` so a reopened session shows its last-known
      # agents. `interrupt_running_tasks/1` already flipped any dead "running"
      # entry to "interrupted" on teardown, so this never shows a fake spinner.
      rail: session.rail_snapshot || %{},
      rail_sig: StudioChat.rail_signature(session.rail_snapshot || %{}),
      rail_expanded: %{},
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
  defp live_runtime(session_id) do
    with recorder when is_pid(recorder) <- Recorder.whereis(session_id),
         {:ok, session_pid} <- Recorder.session_pid(recorder),
         true <- Process.alive?(session_pid) do
      session_pid
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
      mode: "plan",
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
      # A new chat has no background agents yet (charter D47).
      rail: %{},
      rail_sig: [],
      rail_expanded: %{},
      composer_draft: "",
      pending_echo_id: nil,
      question_forms: %{}
    )
  end

  defp refresh_sessions(socket) do
    assign(socket,
      sessions: StudioChat.list_sessions(archived: socket.assigns[:show_archived] == true)
    )
  end

  # A row-level archive/delete. Always refresh the sidebar; when the mutated row
  # is the ON-SCREEN session, push_patch to /studio/chat so `handle_params/3`
  # (the single source of truth) re-resets to the clean new-chat state — a
  # background row leaves the open session untouched. The refreshed session list
  # survives the patch (reset_to_new_chat never re-lists), so the deleted row is
  # gone from the sidebar too.
  defp after_lifecycle_mutation(socket, id) do
    socket = socket |> assign(open_menu_session: nil) |> refresh_sessions()

    if socket.assigns.store_session_id == id do
      push_patch(socket, to: "/studio/chat")
    else
      socket
    end
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
      |> assign(messages: messages)
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
  # Adopt the mode the CLI actually reports off an init frame. `default` STAYS
  # adoptable here (charter D34: approving a plan flips the CLI's OWN mode plan →
  # default — observe reflects that REALITY, and a persisted `default` spawns
  # verbatim). Only bypassPermissions is excluded — the fail-closed law (D48):
  # an echoed frame is an untrusted string and must never arm dangerous bypass.
  defp observe_permission_mode(socket, mode)
       when is_binary(mode) and mode in ~w(plan default acceptEdits auto dontAsk manual) do
    if mode != socket.assigns.mode and is_nil(socket.assigns[:pending_mode]) do
      if store_id = socket.assigns[:store_session_id], do: StudioChat.set_mode(store_id, mode)
      assign(socket, mode: mode)
    else
      socket
    end
  end

  defp observe_permission_mode(socket, _mode), do: socket

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
  defp consume_attachments(socket) do
    store_id = socket.assigns.store_session_id

    attachments =
      consume_uploaded_entries(socket, :attachments, fn %{path: tmp_path}, entry ->
        with {:ok, bytes} <- File.read(tmp_path),
             {:ok, pointer} <- StudioChat.store_attachment(store_id, bytes, entry.client_type) do
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
    assign(socket, messages: socket.assigns.messages ++ [message], next_id: id + 1)
  end

  # The jsonb pointer for a stored attachment — path/media_type/sha256/byte_size
  # ONLY, never the bytes.
  defp attachment_pointer_json(a) do
    %{
      "path" => a.path,
      "media_type" => a.media_type,
      "sha256" => a.sha256,
      "byte_size" => a.byte_size
    }
  end

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
         %{} = session <- StudioChat.get_session(store_id) do
      assign(socket, ring: ring_from_session(session))
    else
      _ -> socket
    end
  end

  # Rebuild the transcript message list from the persisted store. Assistant
  # markdown re-renders through the SAME paper engine used live, so the improving
  # renderer wins on every reopen (D7).
  defp replay_messages(session_id, live?) do
    session_id
    |> StudioChat.list_messages()
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
    %{id: seq, role: :thinking, text: text, html: nil}
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

  defp append_message(socket, role, text, opts \\ []) do
    id = socket.assigns.next_id
    message = Map.merge(%{id: id, role: role, text: text, html: nil}, Map.new(opts))

    assign(socket,
      messages: socket.assigns.messages ++ [message],
      next_id: id + 1
    )
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
        |> append_message(:thinking, thinking_label(n))
        |> assign(thinking_pulse: nil)

      _ ->
        assign(socket, thinking_pulse: nil)
    end
  end

  defp blank_pulse, do: %{tokens: 0, text: ""}

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

      assign(socket, messages: messages)
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
      ClaudeChat.respond_permission(socket.assigns.session, request_id, decision)

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
      |> assign(messages: messages)
      |> clear_question_form(request_id)
      |> refresh_sessions()
    else
      socket
    end
  end

  # Project an approved plan into a Paper (charter D49). Gated on the matched
  # row being a :plan card AND an allow decision; only then does a fire-and-forget
  # Task publish + stamp + broadcast. The Task NEVER touches the socket — it talks
  # to the session topic every tab (this one included) is subscribed to. A tab
  # with no store session or no topic (a brand-new chat) has nothing to project.
  defp maybe_publish_plan(socket, request_id, decision) do
    with true <- plan_allow?(decision),
         %{role: :plan} = m <- find_message_by_rid(socket, request_id),
         sid when is_binary(sid) <- socket.assigns[:store_session_id],
         topic when is_binary(topic) <- socket.assigns[:subscribed_topic] do
      markdown = to_string(m[:plan_markdown] || "")

      # Fire-and-forget under Barkpark.TaskSupervisor (same pattern as the AI
      # title, D13) — supervised, `$callers`-scoped so the sandbox connection is
      # inherited under test, and drained on test exit. The Task never touches
      # the socket; it talks to the session topic.
      Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
        publish_plan_paper(sid, request_id, markdown, topic)
      end)
    end

    :ok
  end

  defp plan_allow?(:allow), do: true
  defp plan_allow?({:allow, _}), do: true
  defp plan_allow?(_), do: false

  # The fire-and-forget body: publish the Paper, stamp its id/url onto the plan
  # row's metadata (replay-durable, D49), and broadcast the outcome to the session
  # topic so all tabs converge. A publish failure is honest, not silent, and never
  # re-raises — the approve already succeeded.
  defp publish_plan_paper(session_id, request_id, markdown, topic) do
    # A RAISE inside publish (malformed markdown through FromMarkdown, an upsert
    # invariant) must degrade to the SAME honest failure broadcast as an
    # `{:error, _}` return — a crashed fire-and-forget Task is silent, and the
    # promised "couldn't publish" line would never appear. Scoped to the publish
    # call only: a raise AFTER a successful publish must not lie "couldn't
    # publish" about a Paper that exists.
    result =
      try do
        PlanPapers.publish(session_id, request_id, markdown)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, %{paper_id: paper_id, paper_url: paper_url}} ->
        StudioChat.merge_approval_metadata(session_id, request_id, %{
          "paper_id" => paper_id,
          "paper_url" => paper_url
        })

        Phoenix.PubSub.broadcast(
          Barkpark.PubSub,
          topic,
          {:plan_paper, request_id, %{paper_id: paper_id, paper_url: paper_url}}
        )

      {:error, _reason} ->
        Phoenix.PubSub.broadcast(
          Barkpark.PubSub,
          topic,
          {:plan_paper_failed, request_id}
        )
    end
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

  # Normalize the AskUserQuestion input into a render-ready question list. Each
  # question: prompt string, optional header, multiSelect flag, and option chips
  # (label + optional description). Tolerant of options given as bare strings.
  defp parse_questions(%{"questions" => qs}) when is_list(qs) do
    Enum.map(qs, fn q ->
      %{
        question: to_string(Map.get(q, "question", "")),
        header: nonempty(Map.get(q, "header")),
        multi: Map.get(q, "multiSelect", false) == true,
        options: parse_options(Map.get(q, "options"))
      }
    end)
  end

  defp parse_questions(_), do: []

  defp parse_options(opts) when is_list(opts) do
    opts
    |> Enum.map(fn
      %{"label" => label} = o ->
        %{label: to_string(label), description: nonempty(Map.get(o, "description"))}

      label when is_binary(label) ->
        %{label: label, description: nil}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_options(_), do: []

  defp nonempty(s) when is_binary(s) do
    if String.trim(s) == "", do: nil, else: s
  end

  defp nonempty(_), do: nil

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
  # comma-joined labels; unanswered questions are omitted.
  defp build_answers(questions, form) do
    questions
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {q, qidx}, acc ->
      case answer_value(q, Map.get(form.selections, qidx, []), Map.get(form.custom, qidx)) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, q.question, value)
      end
    end)
  end

  defp answer_value(q, selections, custom) do
    trimmed = if is_binary(custom), do: String.trim(custom), else: ""

    cond do
      trimmed != "" -> trimmed
      q.multi and selections != [] -> Enum.join(selections, ", ")
      selections != [] -> List.first(selections)
      true -> nil
    end
  end

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
  # Blocks render the moment they complete, not when the whole message ends:
  # the accumulated stream is split at the last block boundary ("\n\n") whose
  # prefix has BALANCED code fences (never split inside a streaming ```mermaid
  # or ```portabledoc fence — a half fence would render as a broken block).
  # The stable prefix renders through the paper engine once per boundary
  # advance; only the still-forming tail re-renders as plain text per delta.

  defp advance_streaming(nil, delta),
    do: advance_streaming(%{text: "", stable_html: nil, stable_len: 0}, delta)

  defp advance_streaming(state, delta) do
    text = state.text <> delta
    state = %{state | text: text}
    boundary = stable_boundary(text)

    if boundary > state.stable_len do
      prefix = binary_part(text, 0, boundary)
      %{state | stable_len: boundary, stable_html: render_paper_html(prefix)}
    else
      state
    end
  end

  defp streaming_tail(%{text: text, stable_len: stable_len}) do
    binary_part(text, stable_len, byte_size(text) - stable_len)
  end

  # ── forming-component classification (streaming skeletons) ──────────────
  # The tail after the last balanced-fence boundary is a SINGLE forming block
  # (a "\n\n" with balanced fences would have advanced the boundary), so a
  # cheap look at how it starts tells us what component is being built. The
  # raw source of a forming component reads as noise — render a dedicated
  # skeleton in the component's shape instead; prose keeps streaming as text.
  #
  # Returns `{:text, tail}` or `{:component, kind, prose_before_component}`.
  defp classify_tail(tail) do
    fence_count = length(:binary.matches(tail, "```"))

    cond do
      rem(fence_count, 2) == 1 ->
        {pos, _} = List.last(:binary.matches(tail, "```"))
        prose = binary_part(tail, 0, pos)
        fence = binary_part(tail, pos, byte_size(tail) - pos)
        {:component, fence_kind(fence), prose}

      forming_table?(tail) ->
        {:component, "table", ""}

      String.starts_with?(String.trim_leading(tail), ">") ->
        {:component, "callout", ""}

      true ->
        {:text, tail}
    end
  end

  defp fence_kind("```" <> rest) do
    case rest |> String.split("\n", parts: 2) |> hd() |> String.trim() do
      "mermaid" -> "diagram"
      "portabledoc" -> portabledoc_kind(rest)
      _ -> "code"
    end
  end

  defp fence_kind(_), do: "code"

  # Sniff the first "type" in the (partial) JSON to pick the skeleton shape.
  defp portabledoc_kind(fence_rest) do
    case Regex.run(~r/"type"\s*:\s*"([\w-]+)"/, fence_rest) do
      [_, "chart"] -> "chart"
      [_, "heatmap"] -> "chart"
      [_, t] when t in ["stat", "stats"] -> "stats"
      [_, "table"] -> "table"
      [_, "callout"] -> "callout"
      [_, "divider"] -> "code"
      [_, _other] -> "block"
      _ -> "block"
    end
  end

  defp forming_table?(tail) do
    tail |> String.trim_leading() |> String.starts_with?("|")
  end

  defp skeleton_label("diagram"), do: "diagram"
  defp skeleton_label("chart"), do: "chart"
  defp skeleton_label("stats"), do: "stats"
  defp skeleton_label("table"), do: "table"
  defp skeleton_label("callout"), do: "callout"
  defp skeleton_label("code"), do: "code"
  defp skeleton_label(_), do: "block"

  defp stable_boundary(text) do
    case :binary.matches(text, "\n\n") do
      [] ->
        0

      matches ->
        matches
        |> Enum.reverse()
        |> Enum.find_value(0, fn {pos, len} ->
          boundary = pos + len
          if balanced_fences?(binary_part(text, 0, boundary)), do: boundary, else: nil
        end)
    end
  end

  defp balanced_fences?(prefix) do
    rem(length(:binary.matches(prefix, "```")), 2) == 0
  end

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

  # Extract {tool_use_id, output_string} pairs from a wire user-frame. The
  # result content may be a plain string or a block list; anything else (our
  # own echoed sends through the cat test fake) yields [] and is ignored.
  defp tool_results(%{"message" => %{"content" => content}}) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_result" and is_binary(&1["tool_use_id"])))
    |> Enum.map(fn block -> {block["tool_use_id"], tool_result_text(block["content"])} end)
    |> Enum.reject(fn {_id, out} -> out in [nil, ""] end)
  end

  defp tool_results(_), do: []

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
  defp group_agent_rows(messages) do
    spawns =
      for m <- messages,
          m.role == :tool,
          m[:spawn?],
          is_nil(m[:parent_tool_use_id]),
          is_binary(m[:tool_use_id]),
          into: %{},
          do: {m[:tool_use_id], true}

    children =
      Enum.reduce(messages, %{}, fn m, acc ->
        pid = m[:parent_tool_use_id]

        if is_binary(pid) and Map.has_key?(spawns, pid) do
          Map.update(acc, pid, [m], &(&1 ++ [m]))
        else
          acc
        end
      end)

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

    if changed?, do: {:noreply, assign(socket, messages: messages)}, else: {:noreply, socket}
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

    if sig == socket.assigns.rail_sig,
      do: socket,
      else: assign(socket, rail: new_rail, rail_sig: sig)
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

  defp rail_glyph_type(entry) do
    case (entry["row"] || %{})["task_type"] do
      "local_workflow" -> "⚙"
      t when is_binary(t) -> "◆"
      _ -> "◆"
    end
  end

  # A rail workflow tree normalized to ordered nodes for render: phase headers and
  # the agent rows beneath them. Tolerant of a nil/absent tree.
  defp rail_workflow_nodes(entry) do
    case entry["workflow"] do
      nodes when is_list(nodes) -> Enum.filter(nodes, &is_map/1)
      _ -> []
    end
  end

  defp rail_node_running?(node), do: node["state"] in ["running", "in_progress", "active"]

  defp rail_status_label("completed"), do: "done"
  defp rail_status_label("interrupted"), do: "interrupted"
  defp rail_status_label(_), do: "running"

  defp rail_status_color("completed"), do: "var(--ok)"
  defp rail_status_color("interrupted"), do: "var(--warn)"
  defp rail_status_color(_), do: "var(--primary)"

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

  defp model_label("haiku"), do: "Haiku — fastest"
  defp model_label("sonnet"), do: "Sonnet — balanced"
  defp model_label("opus"), do: "Opus — powerful"
  defp model_label("fable"), do: "Fable — frontier"
  defp model_label(m), do: m

  defp mode_label("plan"), do: "plan (read-only)"
  defp mode_label("acceptEdits"), do: "accept edits"
  defp mode_label("auto"), do: "auto-run"
  defp mode_label("dontAsk"), do: "don't ask"
  defp mode_label("manual"), do: "manual approve"
  defp mode_label("bypassPermissions"), do: "bypass · dangerous"
  # The retired middle mode: shown ONLY while a legacy session still carries it.
  defp mode_label("default"), do: "ask (legacy)"
  defp mode_label(other), do: other

  # Effort tiers render verbatim in the picker (charter D48 — "Fable · high").
  defp effort_label(nil), do: "default"
  defp effort_label("default"), do: "default"
  defp effort_label(e), do: e

  # The "(was ~N tokens)" tail on a compaction line — only when the CLI reports a
  # pre-compaction size, so we never invent a number we don't have.
  defp compact_size(pre) when is_integer(pre) and pre > 0, do: " (was ~#{pre} tokens)"
  defp compact_size(_), do: ""

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

  # The terminal's elapsed counter: one self-tick per second while a turn runs.
  # Re-arms itself; falls silent (and disarms) the first tick after the turn
  # ends, so an idle tab costs nothing.
  defp start_turn_clock(socket) do
    if socket.assigns[:turn_clock_armed] do
      assign(socket, turn_elapsed_s: 0)
    else
      Process.send_after(self(), :turn_tick, 1_000)
      assign(socket, turn_elapsed_s: 0, turn_clock_armed: true)
    end
  end

  defp approval_outcome_label(:allowed), do: "✓ allowed"
  defp approval_outcome_label(:canceled), do: "✗ canceled"
  defp approval_outcome_label(_), do: "✗ denied"

  # The idle/ready clause teaches the composer's verbs (charter D44) — never a
  # mic, never @-mentions. Degraded states keep their honest, specific copy.
  defp composer_placeholder(:new), do: "Plan, build… / for commands"
  defp composer_placeholder(:resumable), do: "Message Claude to resume this chat…"
  defp composer_placeholder(:offline), do: "Send a message to resume this session…"
  defp composer_placeholder(:thinking), do: "Claude is working — press Stop to interrupt…"
  defp composer_placeholder(:interrupting), do: "Stopping…"
  defp composer_placeholder(_), do: "Plan, build… / for commands"

  # ── slash-command menu (charter D36a/D36b) ──────────────────────────────

  # The builtin floor — always offered, even with no live runtime. `builtin:
  # true` marks the three that route to a control path on submit (the JS just
  # inserts their text; `handle_event("send")` does the routing).
  @slash_builtins [
    %{
      "name" => "/plan",
      "description" => "Plan mode — read-only; the agent proposes before acting",
      "argumentHint" => nil,
      "builtin" => true
    },
    # The /default builtin is RETIRED (charter D48) — `default` is no longer an
    # offered mode; the picker's six modes + the armed bypass ceremony are the
    # surface. /plan is the only mode builtin left.
    %{
      "name" => "/model",
      "description" => "Switch the model for this session",
      "argumentHint" => "default | haiku | sonnet | opus | fable",
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

  # Session → tokenized pill. Precedence (charter D14): PendingApproval > Working
  # > Exited > Idle. A session with a persisted pending approval outranks every
  # status — it is the one row that needs the admin RIGHT NOW, so it wears the
  # warn-toned "needs you" pill even mid-turn.
  # The live overlay wins over the stored row (wave 5): a Recorder that says
  # "working" right now beats a store status that flips only on frame writes.
  defp session_pill(_s, %{state: :working}), do: {"badge-chat-working", "working"}
  defp session_pill(_s, %{state: :needs_you}), do: {"badge-chat-approval", "needs you"}
  defp session_pill(_s, %{state: :offline}), do: {"badge-chat-offline", "offline"}
  defp session_pill(s, _act), do: session_pill(s)

  defp session_pill(%{pending_approvals: n}) when is_integer(n) and n > 0,
    do: {"badge-chat-approval", "needs you"}

  defp session_pill(%{status: status}), do: session_pill_by_status(status)

  defp session_pill_by_status("working"), do: {"badge-chat-working", "working"}
  defp session_pill_by_status("exited"), do: {"badge-chat-offline", "offline"}
  defp session_pill_by_status(_), do: {"badge-chat-idle", "idle"}

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

  defp default_dataset do
    case Barkpark.Content.list_datasets() do
      [ds | _] when is_binary(ds) -> ds
      _ -> "production"
    end
  rescue
    _ -> "production"
  end
end
