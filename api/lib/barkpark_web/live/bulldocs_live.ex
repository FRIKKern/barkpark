defmodule BarkparkWeb.BulldocsLive do
  @moduledoc """
  Live render of a paper inside Barkpark (convergence masterplan
  Figure 6; block-streaming in Wave 4).

  ## Two render paths

    * **Block-backed (Wave 4):** the paper has a block list. Each top-level
      block is rendered to a fragment and pushed into a `Phoenix.LiveView`
      stream keyed by block id. A `{:paper_block, frame}` delta appends /
      inserts / patches / deletes the **single** affected stream item — no
      whole re-assign, so scroll and focus on untouched blocks are preserved.
    * **HTML-only (Wave 3, legacy):** the paper carries opaque `body_html` and
      no block list. We render `raw(@html)` and re-assign it on a
      `{:paper_updated, …}` broadcast — the original no-reload path, kept as a
      fallback.

  ## Rev-gap recovery

  Every broadcast carries a monotonic integer `rev`. The LiveView tracks the
  last rev it applied. On a delta whose rev is not exactly `last_rev + 1`, a
  frame was missed — we refetch the full doc, re-stream every block, and resume
  from the fetched rev. (Whole-HTML frames simply adopt the new rev.)

  ## No-reload proof

  `#paper-sentinel` is rendered once at mount OUTSIDE the streamed container.
  It survives a `handle_info` DOM diff but would be torn down by a
  remount / navigate — the surviving-sentinel proof, now extended across a
  multi-block append sequence (see `bulldocs_live_test.exs`).

  Layout: the full-document `paper.html.heex` is the ROOT layout (set in the
  router's `:papers` live_session); `mount/3` returns `layout: false`.

  Note on `raw/1`: legacy HTML reaches this public/scoped reader only after the
  paper write pipeline sanitizes it. The reader preserves those stored bytes;
  it does not treat arbitrary caller-supplied HTML as trusted.
  """
  use BarkparkWeb, :live_view

  require Logger

  # `raw/1` lives in Phoenix.HTML; the :live_view macro imports
  # Phoenix.HTML.Form but not the parent module, so import it here.
  import Phoenix.HTML, only: [raw: 1]

  alias Barkpark.Content
  alias Barkpark.Content.Labels
  alias Barkpark.Plugins.Bulldocs.Events
  alias Barkpark.Papers.TextDiff
  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.PaperViewer

  defmodule NotFound do
    @moduledoc "Raised when a canonical Paper identity is missing or unpublished."
    defexception [:message, plug_status: 404]
  end

  defmodule InvalidSource do
    @moduledoc "Raised when a Paper exists but has no unambiguous semantic reader source."
    defexception [:message, plug_status: 422]
  end

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    # Optional dataset path param (present only on /d/:dataset/papers/:slug).
    # Absent on the flat /papers/:slug + scoped /w/:ws/p/:proj/papers/:slug
    # surfaces → default dataset (back-compat: identical behaviour as today).
    dataset = Map.get(params, "dataset") || Content.paper_default_dataset()
    # Two front doors, one LiveView (P4 of Scoped-by-URL):
    #   * flat /papers/:slug — PUBLIC surface, resolves ONLY within the seeded
    #     Default workspace (barkpark-w9dg; the locked paper-ingest contract).
    #   * scoped /w/:ws/p/:proj/papers/:slug — the dead-render-resolved scope
    #     arrives via PluginScopeSession (member, section share, or ?share=
    #     item token — RequireShareScope/ResolveWorkspace already gated);
    #     fetch within THAT tenant, live updates ride the same ws-keyed topic.
    reader_scope = reader_scope(socket)
    # Persist the resolved dataset so the rev-gap refetch + goal/scope helpers
    # re-resolve the paper in the SAME dataset they mounted (default for the
    # flat + scoped surfaces).
    socket =
      socket
      |> assign(:reader_scope, reader_scope)
      |> assign(:dataset, dataset)

    # Mount-only twin of `fetch_paper/3` that keeps the Default workspace row
    # the public resolve already loaded (am-w1-s3) — `reader_theme/3` below
    # reuses it instead of re-reading the same workspace by id.
    {paper, paper_workspace} = fetch_paper_with_workspace(slug, reader_scope, dataset)

    paper ||
      raise NotFound, message: "no published paper #{inspect(slug)}"

    # Edit-on-the-link slice 1 (task-0c242c8dc61f6b13): the viewer was
    # resolved by `BarkparkWeb.PaperViewer.on_mount/4`; the EDIT verdict needs
    # the paper's OWN workspace, known only now. Fail-closed: a mount without
    # the hook (no `:viewer` assign) is anonymous and can never edit.
    socket =
      socket
      |> assign(:viewer, socket.assigns[:viewer] || PaperViewer.anonymous())
      |> assign(:can_edit?, PaperViewer.can_edit?(socket.assigns, paper.workspace_id))

    reader_source =
      case Content.Papers.reader_source(paper, dataset, reader_scope) do
        {:error, reason} ->
          raise InvalidSource,
            message: "paper #{inspect(slug)} has invalid reader source: #{reason}"

        source ->
          source
      end

    paper_link_refs = reader_source |> source_blocks() |> paper_link_refs()

    # Preview manifest (preview-contract pc-w2) — the outward social-share card.
    # Computed BEFORE the `connected?` branch so the DEAD render (crawlers +
    # unfurlers run no JS) already carries the og/twitter/JSON-LD head. Resolves
    # to the write-time `content["preview"]`, else the pc-w1 read-time
    # projection, else a degraded core manifest (ShareMeta.manifest/4). The
    # layout reads `:preview` + `:page_title`.
    preview = paper_preview(paper, slug)

    socket =
      socket
      |> assign(:preview, preview)
      |> assign(:page_title, preview["title"])

    task_ws = (paper && paper.workspace_id) || reader_scope[:workspace_id]

    subscribe_document_changes? =
      task_ws && (has_live_task_blocks?(paper) || paper_link_refs != [])

    if connected?(socket) do
      # Workspace-scope the subscription (barkpark-n56v, P0). The topic now
      # carries the owning workspace, so we MUST subscribe with the SAME
      # workspace the broadcaster stamps — else a write in another tenant's
      # same-slug paper would (pre-fix) have leaked its rendered body here.
      #
      # `get_public_paper/2` resolves the slug ONLY within the seeded Default
      # (public) workspace, so a found paper's `workspace_id` IS the Default ws
      # — exactly what `broadcast_paper_*` stamps for a Default-scoped paper.
      # When the paper isn't found yet (or is a legacy NULL-workspace row),
      # `paper_topic/3` normalizes nil to the same Default ws, so a later
      # publish into the Default workspace still reaches this viewer.
      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Content.paper_topic(
          slug,
          (paper && paper.workspace_id) || reader_scope[:workspace_id],
          dataset
        )
      )

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Content.paper_relations_topic(
          (paper && paper.workspace_id) || reader_scope[:workspace_id],
          dataset
        )
      )

      # Live plans: a paper embedding a task query ALSO listens on its tenant's
      # document stream, so an embedded board/list/roadmap re-resolves and
      # re-renders the moment a task moves (the "always feel progress" criterion
      # on a real plan). Gated on `has_live_task_blocks?` so a plain paper adds
      # no subscription. Task docs (`type:"task"`) broadcast `:document_changed`
      # on this workspace-scoped topic (content/broadcast.ex).
      if subscribe_document_changes? do
        Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{task_ws}:#{dataset}")
      end

      # DELETION needs NO extra subscription (pd-ee-reader-stale-cache).
      # `Content.paper_topic(slug, ws, ds)` above and
      # `Content.doc_topic(pubid, "paper", ws, ds)` build the SAME string —
      # `doc:ws:<ws>:<ds>:paper:<slug>` — because a paper's doc_id IS its slug
      # and `paper_topic/3` is the doc topic with the type pinned to "paper"
      # (content/broadcast.ex). So the delete frame
      # `{:doc_updated, %{mutation: "delete"}}` that
      # `Broadcast.tap_broadcast/7` publishes ALREADY arrives here. What was
      # missing was a `handle_info/2` clause for it: the reader only ever
      # matched `{:paper_updated, …}`, which delete never emits, and its
      # `{:document_changed, %{type: "paper"}}` clause reacts only to LINKED
      # papers. The frame landed in the catch-all and was dropped, so a reader
      # already on the URL kept rendering a paper that was gone from storage.
      # The topic identity is pinned in
      # `bulldocs_reader_deleted_paper_test.exs` so a future rename that splits
      # the two topics apart reds instead of silently reopening the leak.
    end

    rail_events = load_rail_events(paper)

    socket =
      socket
      |> assign(:slug, slug)
      |> assign(:found, not is_nil(paper))
      |> assign(:source_error, nil)
      |> assign(:rev, paper_rev(paper))
      # `:article?` is the per-doc style marker (`content["style"] == "article"`).
      # The root `:paper` layout reads it to switch on article page chrome; the
      # block render path reads it to render each block in `:article` palette.
      # Non-article papers leave it false → email default, chrome unchanged.
      |> assign(:article?, paper_article?(paper))
      |> assign(:wide?, paper_wide?(paper))
      |> assign(:html, source_html(reader_source))
      # P6.U2 goal-path rail: events for this paper's goal (empty when no
      # goal_id / no events → the rail is not rendered, article unchanged).
      |> assign(:rail_events, rail_events)
      |> assign(:rail_gitgraph, build_gitgraph(rail_events))
      |> assign(:selected_event_id, nil)
      # P6.U3 diff modal: shift-clicking two rail nodes opens a line-diff of
      # their event payloads. Closed at mount; the modal renders only when
      # `:diff_open` flips true (via the "open-diff" event below).
      |> assign(:diff_open, false)
      |> assign(:diff_html, nil)
      |> assign(:diff_from, nil)
      |> assign(:diff_to, nil)
      # P6.U5 action buttons: the per-type action set derived from the paper's
      # originating doc path (`content["source_doc"]`), mirroring
      # doc.js. Empty when there's no/unknown source_doc → the bar renders not
      # at all. `:last_action` acknowledges the most recent click inline.
      |> assign(:paper_actions, paper_actions(paper))
      |> assign(:last_action, nil)
      # P6.U4 Simplify control. `:simplify?` gates the button (true only when the
      # paper carries a goal_id — Simplify applies to any goal-bearing paper).
      # `:pending_simplify` holds the in-flight `simplified-<n>` branch name once a
      # simplify-request is recorded this session — it gates Accept/Reject and
      # carries the branch into those decision events. `:last_simplify` is the
      # inline ack of the most recent simplify decision.
      |> assign(:simplify?, paper_goal_id(paper) != nil)
      |> assign(:pending_simplify, nil)
      |> assign(:last_simplify, nil)
      # Outbound `paper-links` refs are stored separately from rendered HTML so
      # workspace document broadcasts can refresh only readers whose related
      # Paper metadata may actually have changed.
      |> assign(:paper_link_refs, paper_link_refs)
      |> assign(:document_changes_subscribed?, connected?(socket) && subscribe_document_changes?)
      # Related Papers + "Driven tasks" — both sections read the SAME
      # inbound-edge walk, so they are assigned together off ONE
      # `reverse_referencers/2` call (am-w1-s3). See `assign_linked_sections/3`
      # for the scope + engine posture; each assign is `""` when its section
      # has nothing to show → the template omits it.
      |> assign_linked_sections(paper, dataset)
      # Theme identity (ts-w4e): resolve the paper's workspace theme so
      # bulldocs.html.heex stamps `data-bp-theme` server-side (no flash). The
      # reader ALWAYS mode-swaps via prefers-color-scheme — this attribute only
      # selects WHICH theme, never light/dark. No setting → default → the layout
      # omits the attribute → byte-identical to before.
      |> assign(:bp_theme, reader_theme(paper, reader_scope, paper_workspace))
      |> assign_block_mode(paper, reader_source)

    {:ok, socket, layout: false}
  end

  # Resolve the theme identity for the reader: the paper's OWN workspace, falling
  # back to the mounted reader scope's workspace (the seeded Default for the flat
  # /papers surface). A nil/unresolvable workspace → the default theme.
  #
  # `prefetched` is the workspace row the public paper resolve already loaded
  # (am-w1-s3): when it IS the paper's workspace — always true on the flat
  # public surface — the tenancy re-read is skipped; any mismatch (scoped
  # surface, legacy NULL-workspace paper) falls back to the plain by-id read.
  defp reader_theme(paper, reader_scope, prefetched) do
    ws_id = (paper && Map.get(paper, :workspace_id)) || reader_scope[:workspace_id]

    workspace =
      case prefetched do
        %{id: id} when id == ws_id -> prefetched
        _ -> Barkpark.Tenancy.get_workspace_by_id(ws_id)
      end

    Barkpark.Tenancy.workspace_theme(workspace)
  end

  # Assign the related-Paper AND "Driven tasks" sections for a paper off
  # ONE inbound-edge walk. Empty strings (no markup) when the paper is absent
  # or nothing links to it.
  #
  # Powered by the INDEXED engine `Content.Graph.reverse_referencers/2` (the same
  # one the Studio editor's backlinks pane uses) over the materialised
  # `content_edges` table — NOT a full-corpus block scan. We mirror the Studio's
  # `load_backlinks` call shape (shared/paper.ex): resolve the paper's published
  # id, pass `dataset` + the tenant scope.
  #
  # The lookup MUST be scoped exactly like the paper read (else it could surface
  # a backlink from a paper the reader can't see, or — on the public surface —
  # leak a cross-workspace link). So we reuse the paper's OWN resolved
  # `workspace_id` / `project_id` as the scope: for the tenant-scoped reader that
  # equals `reader_scope`; for the public reader it equals the seeded Default
  # workspace `get_public_paper/2` resolved into. A legacy NULL-workspace paper
  # resolves unscoped (back-compat, mirrors its own read).
  #
  # The walk is SHARED (am-w1-s3 reader dedupe): backlinks render the
  # referencer list directly; "Driven tasks" (lvw-t8) narrows the SAME list to
  # citing tasks via `Expectations.driven_tasks_from_referencers/2` — the same
  # fail-closed posture as before (a source the scope can't see was already
  # dropped inside the walk), one `reverse_referencers/2` instead of two.
  defp assign_linked_sections(socket, %{doc_id: doc_id} = paper, dataset)
       when is_binary(doc_id) do
    opts =
      [dataset: dataset]
      |> maybe_scope(:workspace_id, Map.get(paper, :workspace_id))
      |> maybe_scope(:project_id, Map.get(paper, :project_id))

    referencers =
      doc_id
      |> Content.published_id()
      |> Content.Graph.reverse_referencers(opts)

    socket
    |> assign(:backlinks_html, BarkparkWeb.PaperBacklinks.section_html(referencers))
    |> assign(
      :driven_tasks_html,
      referencers
      |> Barkpark.Tasks.Expectations.driven_tasks_from_referencers(opts)
      |> BarkparkWeb.PaperTasks.section_html()
    )
  end

  defp assign_linked_sections(socket, _paper, _dataset) do
    socket
    |> assign(:backlinks_html, "")
    |> assign(:driven_tasks_html, "")
  end

  defp maybe_scope(opts, _key, nil), do: opts
  defp maybe_scope(opts, key, value), do: Keyword.put(opts, key, value)

  # ── P6.U5 action buttons ──────────────────────────────────────────────────

  # Derive the action set from the paper's originating doc path,
  # mirroring doc.js's per-type button mapping. The path lives at
  # `content["source_doc"]`. A `/specs/` doc gets create-plan + grill; a
  # `/plans/` doc gets build + grill; a `/grills/` doc gets submit. Anything
  # else (or a missing source_doc) yields [] → no bar is rendered (graceful).
  defp paper_actions(%{content: content}) when is_map(content) do
    case Map.get(content, "source_doc") do
      path when is_binary(path) -> actions_for_path(path)
      _ -> []
    end
  end

  defp paper_actions(_), do: []

  defp actions_for_path(path) do
    cond do
      String.contains?(path, "/specs/") ->
        [
          %{key: "create-plan", label: "Create plan from this spec"},
          %{key: "grill", label: "Grill the spec"}
        ]

      String.contains?(path, "/plans/") ->
        [
          %{key: "build", label: "Build this plan"},
          %{key: "grill", label: "Grill the plan"}
        ]

      String.contains?(path, "/grills/") ->
        [%{key: "submit", label: "Submit"}]

      true ->
        []
    end
  end

  # ── P6.U2 goal-path rail ──────────────────────────────────────────────────

  # Load the lifecycle events for the paper's goal. U1 stores the goal id at
  # `content["goal_id"]`; absent it (or with zero events) we return [] and the
  # template renders no rail at all — the article reading column is unchanged.
  #
  # W1.5-C: SCOPE the rail to the paper's OWN workspace/project so the rail
  # never surfaces another workspace's events for a same-named goal. An
  # unscoped paper (NULL workspace_id, pre-tenancy) reads unscoped — back-compat.
  defp load_rail_events(%{content: content} = paper) when is_map(content) do
    case Map.get(content, "goal_id") do
      goal_id when is_binary(goal_id) and goal_id != "" ->
        Events.list_for_goal(goal_id, paper_scope_opts(paper))

      _ ->
        []
    end
  end

  defp load_rail_events(_), do: []

  # W1.5-C: the paper's OWN tenancy scope as Events query opts. NULL
  # workspace_id (a pre-tenancy paper) yields [] → an unscoped read (the
  # back-compat path). A scoped paper yields [workspace_id: …] (+ project_id
  # when set) so reads and writes both stay inside the paper's workspace.
  defp paper_scope_opts(%{workspace_id: ws_id, project_id: project_id})
       when is_binary(ws_id) do
    case project_id do
      proj when is_binary(proj) -> [workspace_id: ws_id, project_id: proj]
      _ -> [workspace_id: ws_id]
    end
  end

  defp paper_scope_opts(_), do: []

  @doc false
  # Build a VALID linear Mermaid gitGraph from the rail's events. One `commit`
  # per event in inserted_at order (the context already sorts asc). Each commit
  # id is `<sanitized-event_type>-<1-based-index>` so ids are unique and clean.
  #
  # v1 is deliberately LINEAR — every event is a commit on the default branch.
  # The `branch` field is carried through to the assign (for a later unit) but
  # we emit NO branch/checkout directives: they make gitGraph fragile.
  # TODO U2.1: branch lanes — emit `branch`/`checkout` from each event's
  #            `branch` field (alt-<n> / simplified-<n>) once a stable lane
  #            layout is designed.
  def build_gitgraph([]), do: nil

  def build_gitgraph(events) when is_list(events) do
    commits =
      events
      |> Enum.with_index(1)
      |> Enum.map(fn {event, idx} ->
        id = "#{sanitize_event_type(event.event_type)}-#{idx}"
        "   commit id: \"#{id}\""
      end)

    Enum.join(["gitGraph" | commits], "\n")
  end

  # Mermaid commit ids are quoted, but keep them clean: lowercase, then collapse
  # anything outside [a-z0-9-] to a single hyphen, trim stray edge hyphens.
  defp sanitize_event_type(nil), do: "event"

  defp sanitize_event_type(type) when is_binary(type) do
    cleaned =
      type
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")

    if cleaned == "", do: "event", else: cleaned
  end

  @impl true
  def handle_event("rail-select", %{"event-id" => id}, socket) do
    # v1: selection highlight only. Article-swap / diff land in U3.
    {:noreply, assign(socket, :selected_event_id, id)}
  end

  # ── P6.U3 diff modal ──────────────────────────────────────────────────────

  # Shift-clicking two rail nodes pushes "open-diff" with the two event ids.
  # Load both events; if both exist, line-diff their `payload_html` and open
  # the modal. A missing event is a no-op (no crash) with a gentle flash — the
  # rail row could have been for an event that has since been pruned.
  #
  # SECURITY (cross-tenant IDOR, fail-closed): `from_id`/`to_id` are client-
  # supplied and reach here over ANY authenticated-or-anonymous socket, so a
  # malicious client can push arbitrary UUIDs. `Events.get_event/1` is UNSCOPED
  # (bare `Repo.get`), so an unconstrained lookup would leak another workspace's
  # event `payload_html` into this paper's diff modal. The socket's
  # `:rail_events` was built by `load_rail_events/1` via the already-workspace-
  # scoped `Events.list_for_goal(goal_id, paper_scope_opts(paper))`, so it holds
  # ONLY this paper's own rail (or, for a NULL-workspace pre-tenancy paper, its
  # own unscoped rail — back-compat). We therefore require BOTH ids to be
  # members of that rail before touching `Events.get_event/1`; a foreign id is
  # not on the rail and falls through to the existing "no longer exists" flash.
  # `reader_scope(socket)` is nil on this flat public surface, so rail
  # membership — not scope threading — is the correct fence.
  def handle_event("open-diff", %{"from" => from_id, "to" => to_id}, socket) do
    rail_ids = MapSet.new(socket.assigns.rail_events, & &1.id)

    from =
      if MapSet.member?(rail_ids, from_id), do: Events.get_event(from_id), else: nil

    to =
      if MapSet.member?(rail_ids, to_id), do: Events.get_event(to_id), else: nil

    if from && to do
      chunks = TextDiff.diff_lines(from.payload_html, to.payload_html)

      socket =
        socket
        |> assign(:diff_open, true)
        |> assign(:diff_html, TextDiff.format_diff_html(chunks))
        |> assign(:diff_from, from.event_type)
        |> assign(:diff_to, to.event_type)

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "One of the selected events no longer exists.")}
    end
  end

  def handle_event("close-diff", _params, socket) do
    {:noreply, assign(socket, :diff_open, false)}
  end

  # ── P6.U5 action buttons ──────────────────────────────────────────────────

  # Clicking an action button records the user's intent as a `paper_events`
  # row (routing Option B: store-in-Barkpark; the orchestrator reads these rows
  # separately, out of scope here — there is no daemon, no CLAUDE_TARGET nonce).
  # The intent row also surfaces in the U2 rail's gitGraph (as an
  # `action-<key>-N` commit) — the intended, queryable Option-B demonstration.
  #
  # goal_id is pulled from `content["goal_id"]`; a missing goal_id still records
  # the row (Event.changeset only requires event_type + one of goal_id/slug, and
  # we always pass paper_slug) so the action is never lost and never crashes.
  def handle_event("paper-action", %{"action" => key}, socket) do
    slug = socket.assigns.slug
    label = action_label(socket.assigns.paper_actions, key)

    {goal_id, scope} =
      paper_goal_and_scope(slug, socket.assigns[:reader_scope], socket.assigns[:dataset])

    # W1.5-C: stamp the intent row with the paper's OWN workspace/project so the
    # event follows the paper/goal scope (Default fallback when unscoped).
    _ =
      Events.create_event(
        %{
          "event_type" => "action:" <> key,
          "goal_id" => goal_id,
          "paper_slug" => slug,
          "payload_html" => "<p>Action '#{key}' requested from /papers/#{slug}</p>",
          "branch" => "main"
        }
        |> stamp_scope(scope)
      )

    {:noreply, assign(socket, :last_action, label || key)}
  end

  # ── P6.U4 Simplify control ────────────────────────────────────────────────

  # Clicking Simplify records the user's intent to run a leaning pass as a
  # `paper_events` row on a fresh `simplified-<n>` branch (routing Option B:
  # store-in-Barkpark; the orchestrator reads these rows separately). The
  # actual leaning-pass subagent run AND the merge-to-source / branch-close are
  # ORCHESTRATOR-SIDE and OUT OF SCOPE here — a later reader follow-on. U4 only
  # records the request + the user's Accept/Reject decision.
  #
  # The branch index `n` = (count of this paper's events whose branch starts
  # "simplified-") + 1, so repeated requests land on simplified-1, simplified-2,
  # … The row also surfaces in the U2 rail's gitGraph (as a `simplify-request-N`
  # commit) — the intended Option-B demonstration.
  def handle_event("simplify-request", _params, socket) do
    slug = socket.assigns.slug

    {goal_id, scope} =
      paper_goal_and_scope(slug, socket.assigns[:reader_scope], socket.assigns[:dataset])

    # No goal_id → nothing to simplify against; skip gracefully (never crash).
    if is_nil(goal_id) do
      {:noreply, socket}
    else
      branch = "simplified-#{next_simplify_index(slug, scope)}"

      _ =
        Events.create_event(
          %{
            "event_type" => "simplify-request",
            "goal_id" => goal_id,
            "paper_slug" => slug,
            "payload_html" => "<p>Simplify requested (#{branch}) for /papers/#{slug}</p>",
            "branch" => branch
          }
          |> stamp_scope(scope)
        )

      {:noreply,
       socket
       |> assign(:pending_simplify, branch)
       |> assign(:last_simplify, "Simplify requested — #{branch}")}
    end
  end

  # Accept the pending simplify candidate. Records the user's decision as a
  # `simplify-accept` event on the pending branch. NOTE: this only records the
  # decision — the actual merge-to-source HTML write / branch-close is the
  # ORCHESTRATOR's job (out of scope here; a reader follow-on consumes this row).
  def handle_event("simplify-accept", _params, socket) do
    {:noreply, record_simplify_decision(socket, "simplify-accept", "Accepted")}
  end

  # Reject the pending simplify candidate. Records a `simplify-reject` decision
  # on the pending branch. As with accept, the branch-close itself is the
  # orchestrator's job (out of scope) — we only persist the user's intent.
  def handle_event("simplify-reject", _params, socket) do
    {:noreply, record_simplify_decision(socket, "simplify-reject", "Rejected")}
  end

  # Fall-through: a stale/unknown phx event must not FunctionClauseError-crash
  # the session. Keep LAST among handle_event/3 clauses.
  def handle_event(event, _params, socket) do
    Logger.warning("bulldocs: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # Shared body for accept/reject: record the decision event on the pending
  # branch (skip gracefully if there is no pending branch or no goal_id), ack
  # inline, then clear `:pending_simplify` so the controls retract.
  defp record_simplify_decision(socket, event_type, verb) do
    slug = socket.assigns.slug
    branch = socket.assigns.pending_simplify

    {goal_id, scope} =
      paper_goal_and_scope(slug, socket.assigns[:reader_scope], socket.assigns[:dataset])

    if is_nil(branch) or is_nil(goal_id) do
      socket
    else
      _ =
        Events.create_event(
          %{
            "event_type" => event_type,
            "goal_id" => goal_id,
            "paper_slug" => slug,
            "payload_html" => "<p>#{verb} #{branch} for /papers/#{slug}</p>",
            "branch" => branch
          }
          |> stamp_scope(scope)
        )

      socket
      |> assign(:pending_simplify, nil)
      |> assign(:last_simplify, "#{verb} #{branch}")
    end
  end

  # The next `simplified-<n>` index for this paper: 1 + how many of its events
  # already sit on a `simplified-` branch. Counts the persisted rows (via
  # list_for_paper) so the index is stable across reconnects, not just the
  # session — repeated requests increment 1, 2, 3, …
  defp next_simplify_index(slug, scope) do
    count =
      slug
      |> Events.list_for_paper(scope)
      |> Enum.count(fn event ->
        is_binary(event.branch) and String.starts_with?(event.branch, "simplified-")
      end)

    count + 1
  end

  # ── P6.U5 action-button helpers ───────────────────────────────────────────

  # The human label for a clicked key, looked up in the derived action set so
  # the inline confirmation reads "Requested: Build this plan". Falls back to
  # the raw key if the set somehow lacks it.
  defp action_label(actions, key) when is_list(actions) do
    case Enum.find(actions, &(&1.key == key)) do
      %{label: label} -> label
      _ -> nil
    end
  end

  # The goal id AND the paper's tenancy scope, re-read from the live paper. We
  # re-fetch rather than carry assigns so this stays a purely additive change to
  # mount; a nil goal_id is recorded as-is (paper_slug keeps the row valid).
  # Shared by the U5 action + U4 Simplify handlers — both need the live goal_id
  # AND (W1.5-C) the paper's workspace/project so the recorded event follows the
  # paper/goal scope. Returns `{goal_id | nil, scope_opts}`.
  defp paper_goal_and_scope(slug, reader_scope, dataset) do
    # Resolve the live paper within the SAME tenant + dataset the reader mounted
    # (Default for the flat surface, the URL scope for /w/... — P4). The
    # resolved paper's OWN workspace/project still stamps the recorded
    # event via paper_scope_opts/1.
    case fetch_paper(slug, reader_scope, dataset) do
      %{content: content} = paper when is_map(content) ->
        {Map.get(content, "goal_id"), paper_scope_opts(paper)}

      _ ->
        {nil, []}
    end
  end

  # Fold the paper's scope opts into a create_event attrs map as string keys.
  # An unscoped paper (scope == []) leaves attrs untouched → upsert_paper's
  # Events.create_event Default-stamping is NOT involved here (BulldocsLive writes
  # events directly), so a nil scope means the row is unscoped (back-compat).
  defp stamp_scope(attrs, scope) do
    attrs
    |> maybe_put_scope("workspace_id", Keyword.get(scope, :workspace_id))
    |> maybe_put_scope("project_id", Keyword.get(scope, :project_id))
  end

  defp maybe_put_scope(attrs, _key, nil), do: attrs
  defp maybe_put_scope(attrs, key, value), do: Map.put(attrs, key, value)

  # Pull the streaming rev / cached HTML / blocks out of the paper document's
  # `content` map (papers are type-"paper" documents now).
  defp paper_rev(nil), do: 0
  defp paper_rev(%{content: content}), do: Map.get(content || %{}, "rev") || 0

  defp source_html({:html, html}), do: html
  defp source_html(_), do: ""

  # Preview manifest for the social-share head (preview-contract pc-w2). The
  # canonical url is the RELATIVE `/papers/:slug` (ShareMeta absolutizes it at
  # emission, D3). A missing paper still yields a valid degraded manifest, so
  # the not-found reader unfurls as a branded default card rather than blank.
  defp paper_preview(%{content: content} = paper, slug) when is_map(content),
    do:
      BarkparkWeb.ShareMeta.manifest(content, "/papers/#{slug}", "paper", Map.get(paper, :title))

  defp paper_preview(_paper, slug),
    do: BarkparkWeb.ShareMeta.manifest(%{}, "/papers/#{slug}", "paper", slug)

  defp source_blocks({:blocks, blocks}), do: blocks
  defp source_blocks(_), do: nil

  # The paper's goal id, if any — used at mount to gate the P6.U4 Simplify
  # button. A blank string counts as absent (no goal to simplify against).
  defp paper_goal_id(%{content: content}) when is_map(content) do
    case Map.get(content, "goal_id") do
      goal_id when is_binary(goal_id) and goal_id != "" -> goal_id
      _ -> nil
    end
  end

  defp paper_goal_id(_), do: nil

  # `article-wide` documents share the article palette AND open the shell to
  # the evidence band (`.bp-paper-shell--wide`, bulldocs.html.heex): a
  # scorecard, matrix or dashboard paper improves with width the way a table
  # does, and the 660px reading measure was shrinking its tables into
  # thumbnails. Prose inside a wide paper still keeps its measure (the shell
  # rule caps p/h/list at 72ch); only the evidence blocks fill the width.
  defp paper_article?(%{content: content}),
    do: Map.get(content || %{}, "style") in ["article", "article-wide"]

  defp paper_article?(_), do: false

  defp paper_wide?(%{content: content}),
    do: Map.get(content || %{}, "style") == "article-wide"

  defp paper_wide?(_), do: false

  # Render opts threaded into every block render. Article papers carry
  # `style: :article`; the empty map keeps the email default byte-unchanged.
  defp render_opts(true), do: %{style: :article}
  defp render_opts(false), do: %{}

  # A paper with a non-nil block list streams its blocks; HTML-only papers
  # (and the empty state) keep the raw-HTML container.
  defp assign_block_mode(socket, paper, reader_source) do
    case source_blocks(reader_source) do
      blocks when is_list(blocks) ->
        resolved = with_live_tasks(blocks, paper, socket.assigns.dataset)

        socket
        |> assign(:block_mode, true)
        |> stream(
          :blocks,
          to_stream_items(
            resolved,
            paper_article?(paper),
            reader_resolvers(resolved, socket.assigns[:dataset], paper)
          )
        )

      _ ->
        socket
        |> assign(:block_mode, false)
        # Initialise an empty stream so the template can reference @streams.blocks
        # uniformly even on the HTML-only path (it just stays empty).
        |> stream(:blocks, [])
    end
  end

  # D2 (ratified, wire §10): the reader's mount/refetch render resolves
  # wikilinks/task chips, inline valuerefs, `field-reference` titles AND
  # `codelist` labels FRESH per page load, as the ANONYMOUS principal over
  # PUBLISHED rows only — per-page-load freshness with no live push, and
  # nothing here can outrank what an unauthenticated caller may see
  # (`resolve_values_in_blocks` defaults `:caller_context` to the anonymous
  # `%CallerContext{}`; `published_only: true` is the D5 gate).
  # Resolution is tenant-scoped to the paper's own workspace/project; a legacy
  # NULL-workspace row normalizes to the seeded Default workspace (the same
  # rule the PubSub topic applies) — and with NO seeded Default there is no
  # public tenant, so nothing resolves (fail closed, never a global read).
  #
  # `Labels.render_opts/2` supplies the `:ref_resolver`/`:codelist_resolver`
  # closures the pure renderer reads (Render.resolve_ref_title/resolve_code_label)
  # so a `field-reference` block shows the referenced doc's TITLE and a
  # `codelist` block its human LABEL — matching Studio and the body_html cache
  # instead of leaking the raw slug/code. The SAME tenant scope + published_only
  # gate flows through: `reference_title` drops the `drafts.` twin under
  # published_only (a draft-only target degrades to the raw id, never leaking a
  # draft title), and `codelist_label` is a global (plugin, list_id) registry
  # lookup carrying no per-tenant user data, so it is safe to resolve here.
  defp reader_resolvers(blocks, dataset, paper) do
    workspace_id =
      (paper && paper.workspace_id) ||
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: id} -> id
          _ -> nil
        end

    if is_nil(workspace_id) do
      %{}
    else
      scope = [
        workspace_id: workspace_id,
        project_id: paper && paper.project_id,
        published_only: true
      ]

      %{
        wikilinks: Content.resolve_wikilinks_in_blocks(blocks, dataset, scope),
        values: Content.resolve_values_in_blocks(blocks, dataset, scope),
        paper_links: resolve_paper_link_details(blocks, dataset, scope)
      }
      |> Map.merge(Labels.render_opts(dataset, scope))
    end
  end

  # Live plans (resolve-at-read): a task block carrying a `query` resolves
  # against the task substrate FRESH on every mount/refetch, so an embedded
  # board/list/roadmap reflects the real `bp` tasks — not a snapshot frozen at
  # save. Tenant-scoped (the paper's own workspace/project, fail-closed); a
  # blank scope resolves nothing. An author-pinned `snapshot` (no `query`) is
  # left untouched, so offline/plugin-off papers still render.
  #
  # Visibility note: this surfaces the paper's-tenant task data (titles /
  # statuses) to whoever can read the paper — the author opts in by embedding a
  # query. Cross-tenant leakage is impossible (workspace fail-closed).
  defp with_live_tasks(blocks, paper, dataset) when is_list(blocks) do
    Barkpark.Content.Papers.resolve_tasks_in_blocks(blocks, reader_task_scope(paper), dataset)
  end

  defp with_live_tasks(blocks, _paper, _dataset), do: blocks

  defp reader_task_scope(paper) do
    ws_id =
      (paper && paper.workspace_id) ||
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: id} -> id
          _ -> nil
        end

    [workspace_id: ws_id, project_id: paper && paper.project_id]
  end

  @task_block_types ~w(tasks task-list task-board roadmap task-detail)

  # True only when the paper has at least one task block with a live `query`
  # (recursing into container children) — the gate for the task-mutation
  # subscription, so a plain paper subscribes to nothing extra.
  defp has_live_task_blocks?(%{content: %{"blocks" => blocks}}) when is_list(blocks),
    do: any_live_task?(blocks)

  defp has_live_task_blocks?(_), do: false

  defp any_live_task?(blocks) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{"type" => t, "query" => q} when is_map(q) -> t in @task_block_types
      %{"children" => ch} when is_list(ch) -> any_live_task?(ch)
      _ -> false
    end)
  end

  defp any_live_task?(_), do: false

  defp paper_link_refs(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "paper-links", "refs" => refs} -> Enum.map(List.wrap(refs), &paper_ref_slug/1)
      %{"children" => children} when is_list(children) -> paper_link_refs(children)
      %{"blocks" => children} when is_list(children) -> paper_link_refs(children)
      _ -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp paper_link_refs(_), do: []

  defp paper_ref_slug(slug) when is_binary(slug) do
    case String.trim(slug) do
      "" -> nil
      value -> value
    end
  end

  defp paper_ref_slug(%{"slug" => slug}), do: paper_ref_slug(slug)
  defp paper_ref_slug(%{slug: slug}), do: paper_ref_slug(slug)
  defp paper_ref_slug(_), do: nil

  # One tenant-scoped batch read per render, never one query per card. Only
  # published type:"paper" rows survive; unresolved refs remain authored links.
  defp resolve_paper_link_details(blocks, dataset, scope) do
    blocks
    |> paper_link_refs()
    |> Content.resolve_docs_by_ids(dataset, scope)
    |> Enum.filter(&(&1.type == "paper"))
    |> Map.new(fn paper ->
      content = paper.content || %{}

      {paper.doc_id,
       %{
         title: paper.title,
         description: Map.get(content, "description"),
         event_type: Map.get(content, "event_type"),
         rev: Map.get(content, "rev") || paper.rev,
         updated_at: paper_timestamp(paper.updated_at)
       }}
    end)
  end

  defp paper_timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp paper_timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp paper_timestamp(_), do: nil

  # Each stream item needs a stable `:id` (the block id) and its rendered
  # fragment. Only top-level blocks are streamed individually; a `section`
  # block renders as one fragment (its children live inside it). An article
  # paper renders each block in the `:article` palette so the live per-block
  # output matches the article body_html cache. `resolvers` is the D2
  # per-page-load palette (wikilinks + values) merged onto the style opts.
  defp to_stream_items(blocks, article?, resolvers) do
    opts = Map.merge(render_opts(article?), resolvers)

    # R2 fix: id-less blocks must each get a UNIQUE stream/DOM id, else
    # Phoenix's stream dedupes them on the constant `blocks-` id and only the
    # last block survives in the live <article>. Fall back to a positional id
    # when a block carries none. (Option A assigns ids at ingest so this path
    # only catches legacy id-less papers already on disk.)
    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, index} ->
      %{id: stream_block_id(block, index), html: Render.render_block(block, opts)}
    end)
  end

  # A stable per-block stream id: the block's own id when present, else a
  # positional fallback so every block streams under a distinct DOM id.
  defp stream_block_id(block, index) do
    case Map.get(block, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> "block-#{index}"
    end
  end

  # ── delta frame (Wave 4) ──────────────────────────────────────────────────

  @impl true
  def handle_info({:paper_block, frame}, socket) do
    cond do
      # A cached delta fragment cannot carry fresh metadata for `paper-links`.
      # Re-resolve the complete block list whenever this reader has one.
      socket.assigns[:paper_link_refs] != [] ->
        {:noreply, refetch(socket)}

      # First block delta to a view still in HTML-only mode: we have no stream
      # to append onto, so adopt the block list wholesale via a refetch rather
      # than blindly inserting one item over the opaque HTML body.
      not socket.assigns.block_mode ->
        {:noreply, refetch(socket)}

      # Missed a frame — refetch the whole doc and re-stream from scratch.
      gap?(socket.assigns.rev, frame.rev) ->
        {:noreply, refetch(socket)}

      true ->
        {:noreply, apply_delta(socket, frame)}
    end
  end

  # ── whole-HTML frame (Wave 3 fallback) ────────────────────────────────────

  def handle_info({:paper_updated, _msg}, socket), do: {:noreply, refetch(socket)}

  # THE DELETE FRAME (pd-ee-reader-stale-cache). Deletion is the ONE mutation
  # that reaches this reader as `{:doc_updated, …}` and never as
  # `{:paper_updated, …}` — the paper-write pipeline emits the latter, the
  # generic `Content.delete_document/4` path only the former (on the same
  # topic; see the mount comment). Without this clause the frame fell into the
  # catch-all and a connected reader served the deleted body indefinitely.
  #
  # `refetch/1` re-reads the slug and, on nil, clears the stream, the html and
  # `:found` — so this one line IS the not-found transition. Every OTHER
  # `{:doc_updated, …}` on the topic still falls through: an ordinary edit
  # already arrives as `{:paper_updated, …}`, and refetching twice per edit
  # would be pure duplicate work on a public reader.
  def handle_info({:doc_updated, %{mutation: "delete"}}, socket),
    do: {:noreply, refetch(socket)}

  # Emitted only after the edge projector has reconciled the materialised
  # graph. Re-read the compact related-Paper projection without replacing the
  # article body, so cards update in place when links or source details change.
  def handle_info({:paper_relations_changed, _msg}, socket) do
    paper =
      fetch_paper(socket.assigns.slug, socket.assigns[:reader_scope], socket.assigns[:dataset])

    {:noreply, assign_linked_sections(socket, paper, socket.assigns[:dataset])}
  end

  # Live-plan push: a task moved in this paper's tenant → re-resolve the
  # embedded task blocks (resolve-at-read) and re-stream. Only reacts to
  # `type:"task"` docs and only while in block mode; the paper's own edits ride
  # the paper topic above. A non-task doc_changed (same tenant stream) is a
  # no-op — the plan only redraws when work actually moves.
  def handle_info({:document_changed, %{type: "task"}}, socket) do
    if socket.assigns[:block_mode], do: {:noreply, refetch(socket)}, else: {:noreply, socket}
  end

  def handle_info({:document_changed, %{type: "paper", doc_id: doc_id}}, socket) do
    if Content.published_id(doc_id) in socket.assigns[:paper_link_refs] do
      {:noreply, refetch(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:document_changed, _msg}, socket), do: {:noreply, socket}

  def handle_info(_other, socket), do: {:noreply, socket}

  # A gap is any received rev that is not exactly the next one we expect. The
  # very first delta on a paper we mounted at rev 0 (never-streamed) also takes
  # the refetch path, which is correct: we have nothing to append onto.
  defp gap?(last_rev, incoming_rev) when is_integer(last_rev) and is_integer(incoming_rev) do
    incoming_rev != last_rev + 1
  end

  defp gap?(_last, _incoming), do: true

  defp apply_delta(socket, %{op_kind: "remove-block", block_id: id} = frame) do
    socket
    |> stream_delete_by_dom_id(:blocks, dom_id(id))
    |> assign(:rev, frame.rev)
    |> assign(:block_mode, true)
    |> assign(:found, true)
  end

  defp apply_delta(
         socket,
         %{op_kind: kind, block_id: id, fragment_html: html, position: pos} = frame
       )
       when kind in ["append-block", "insert-after"] and is_integer(pos) do
    # A NEW block enters the stream at its known top-level index, so a
    # mid-document insert-after lands in order — not appended to the end.
    socket
    |> stream_insert(:blocks, %{id: id, html: html}, at: pos)
    |> assign(:rev, frame.rev)
    |> assign(:block_mode, true)
    |> assign(:found, true)
  end

  defp apply_delta(socket, %{block_id: id, fragment_html: html} = frame) do
    # patch-block / replace-block (and any new block whose top-level position is
    # unknown, e.g. one nested in a section): upsert by id. A seen id is patched
    # in place; an unseen id is appended. Patch/replace MUST be in-place (no
    # `at:`) so editing a block never reorders it. The rev-gap path repairs
    # any residual ordering on the next full refetch.
    socket
    |> stream_insert(:blocks, %{id: id, html: html})
    |> assign(:rev, frame.rev)
    |> assign(:block_mode, true)
    |> assign(:found, true)
  end

  defp refetch(socket) do
    # Same tenant scoping as mount (Default flat / URL scope on /w/..., P4).
    case fetch_paper(socket.assigns.slug, socket.assigns[:reader_scope], socket.assigns[:dataset]) do
      nil ->
        socket
        |> stream(:blocks, [], reset: true)
        |> assign(:html, "")
        |> assign(:block_mode, false)
        |> assign(:found, false)
        |> assign(:source_error, nil)
        |> assign(:article?, false)
        |> assign(:wide?, false)
        |> assign(:paper_link_refs, [])
        |> assign_linked_sections(nil, socket.assigns[:dataset])

      paper ->
        article? = paper_article?(paper)

        reader_source =
          Content.Papers.reader_source(
            paper,
            socket.assigns[:dataset],
            socket.assigns[:reader_scope]
          )

        case reader_source do
          {:blocks, blocks} ->
            resolved = with_live_tasks(blocks, paper, socket.assigns.dataset)
            refs = paper_link_refs(resolved)

            socket
            |> ensure_document_changes_subscription(paper, refs)
            |> stream(
              :blocks,
              to_stream_items(
                resolved,
                article?,
                reader_resolvers(resolved, socket.assigns[:dataset], paper)
              ),
              reset: true
            )
            |> assign(:rev, paper_rev(paper))
            |> assign(:article?, article?)
            |> assign(:wide?, paper_wide?(paper))
            |> assign(:block_mode, true)
            |> assign(:found, true)
            |> assign(:source_error, nil)
            |> assign(:paper_link_refs, refs)
            |> assign_linked_sections(paper, socket.assigns[:dataset])

          {:html, html} ->
            # Refetched a paper that has reverted to HTML-only — fall back.
            socket
            |> assign(:html, html)
            |> assign(:rev, paper_rev(paper))
            |> assign(:article?, article?)
            |> assign(:wide?, paper_wide?(paper))
            |> assign(:block_mode, false)
            |> assign(:found, true)
            |> assign(:source_error, nil)
            |> assign(:paper_link_refs, [])
            |> assign_linked_sections(paper, socket.assigns[:dataset])

          {:error, reason} ->
            socket
            |> stream(:blocks, [], reset: true)
            |> assign(:html, "")
            |> assign(:rev, paper_rev(paper))
            |> assign(:article?, article?)
            |> assign(:wide?, paper_wide?(paper))
            |> assign(:block_mode, false)
            |> assign(:found, false)
            |> assign(:source_error, reason)
            |> assign(:paper_link_refs, [])
            |> assign_linked_sections(paper, socket.assigns[:dataset])
        end
    end
  end

  # Stream dom ids are namespaced by the stream name; mirror that so deletes by
  # id line up with what the template renders.
  defp dom_id(id), do: "blocks-#{id}"

  defp ensure_document_changes_subscription(socket, paper, refs) do
    if connected?(socket) && refs != [] && !socket.assigns[:document_changes_subscribed?] do
      ws_id = (paper && paper.workspace_id) || socket.assigns[:reader_scope][:workspace_id]

      if ws_id do
        Phoenix.PubSub.subscribe(
          Barkpark.PubSub,
          "documents:ws:#{ws_id}:#{socket.assigns.dataset}"
        )

        assign(socket, :document_changes_subscribed?, true)
      else
        socket
      end
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `bp-paper-surface` makes the reader main a SINK of the canonical
          paper-surface source (bulldocs.html.heex embeds it) so View↔Edit
          parity is by construction. It is gated on `@article?` on purpose: the
          shared `.bp-paper-surface` element rules must NOT reach legacy
          non-article papers (which keep the dark chrome above) — those emit
          bare `<h1>/<p>/…` the surface rules would restyle. The parchment
          reader skin re-skins the `--paper-*` tokens on this same element. --%>
    <main class={[
      "bp-paper-shell",
      @article? && "bp-paper-surface",
      @article? && "bp-paper-article",
      @wide? && "bp-paper-shell--wide"
    ]}>
      <%!-- Sentinel: rendered once at mount, OUTSIDE the streamed/re-assigned
            container. It survives a handle_info DOM diff but would be torn
            down by a remount/navigate — the surviving-sentinel proof of
            no-reload. --%>
      <div id="paper-sentinel" data-slug={@slug} hidden></div>

      <%!-- P6.U5 action bar. These are the paper doc action buttons
            (Create plan / Grill / Build / Submit) rendered NATIVELY on the
            paper. The set is derived from content["source_doc"] in mount; an
            empty set (no/unknown source_doc) renders no bar at all. Each click
            fires "paper-action" which records the intent as a paper_events
            row (routing Option B — orchestrator reads them; no daemon, no
            nonce). `:last_action` shows a small inline confirmation. --%>
      <div :if={@paper_actions != []} id="paper-action-bar" class="bp-paper-actions">
        <button
          :for={action <- @paper_actions}
          type="button"
          class="bp-paper-action"
          phx-click="paper-action"
          phx-value-action={action.key}
        >
          {action.label}
        </button>
        <span :if={@last_action} class="bp-paper-action-ack" id="paper-action-ack">
          Requested: {@last_action}
        </span>
      </div>

      <%!-- P6.U4 Simplify control. Rendered ONLY for goal-bearing papers
            (`content["goal_id"]` present → `@simplify?`); independent of the
            U5 doc-type action set. Clicking Simplify fires "simplify-request",
            which records a `simplify-request` paper_events row on a fresh
            `simplified-<n>` branch (routing Option B — orchestrator reads it;
            the leaning-pass run + merge-to-source are orchestrator-side, OUT
            of scope here). Once a request is pending (`@pending_simplify`),
            Accept/Reject render and record the user's decision on that branch.
            `:last_simplify` shows a small inline confirmation. --%>
      <div :if={@simplify?} id="paper-simplify" class="bp-paper-simplify">
        <button
          type="button"
          class="bp-paper-action"
          phx-click="simplify-request"
        >
          Simplify
        </button>
        <%!-- Accept/Reject appear once a simplify-request is pending this
              session. They record the decision only; the actual branch-close /
              merge-to-source is the orchestrator's job (out of scope). --%>
        <span :if={@pending_simplify} class="bp-paper-simplify-decide">
          <button
            type="button"
            class="bp-paper-action bp-paper-action-accept"
            phx-click="simplify-accept"
          >
            Accept
          </button>
          <button
            type="button"
            class="bp-paper-action bp-paper-action-reject"
            phx-click="simplify-reject"
          >
            Reject
          </button>
        </span>
        <span :if={@last_simplify} class="bp-paper-action-ack" id="paper-simplify-ack">
          {@last_simplify}
        </span>
      </div>

      <%= cond do %>
        <% @source_error -> %>
          <article id="paper-body" data-rev={@rev} data-source-error={@source_error}>
            <p id="paper-invalid">This paper has no safe, unambiguous reader source.</p>
          </article>
        <% not @found -> %>
          <article id="paper-body" data-rev={@rev}>
            <p id="paper-empty">No paper saved yet for <code>{@slug}</code>.</p>
          </article>
        <% @block_mode -> %>
          <%!-- Block-backed: each top-level block is its own keyed stream item.
                A delta patches/appends/deletes ONE of these, never the lot.
                `phx-hook="PaperMermaid"` runs the Mermaid engine over any fresh
                `pre.mermaid` on mount AND on every stream delta — so a `diagram`
                block streamed in after the initial parse still renders. The
                hook re-renders harmlessly when no diagram blocks are present. --%>
          <article id="paper-body" data-rev={@rev} phx-update="stream" phx-hook="PaperMermaid">
            <div :for={{dom_id, block} <- @streams.blocks} id={dom_id} data-block-id={block.id}>
              {raw(block.html)}
            </div>
          </article>
        <% true -> %>
          <%!-- HTML-only (legacy): whole opaque body, re-assigned on update. --%>
          <article id="paper-body" data-rev={@rev}>{raw(@html)}</article>
      <% end %>

      <%!-- Related Papers. Real graph-backed document cards rendered AFTER the
            body and refreshed in place when projection completes.
            `@backlinks_html` is the full <section> or "" — empty string means
            no markup, so the section disappears when nothing links here. --%>
      {raw(@backlinks_html)}

      <%!-- "Driven tasks" (lvw-t8 expectation reverse view). Tasks that cite
            this paper (design_doc/papers edges) with their acceptance-criteria
            state — a claim satisfied by a close(met+evidence) shows ✓ here on
            the next read. `@driven_tasks_html` is the full <section> or "". --%>
      {raw(@driven_tasks_html)}

      <%!-- P6.U2 goal-path rail. Rendered ONLY when there are events for the
            paper's goal (empty list → no rail, article column unchanged).
            The gitGraph <pre class="mermaid"> sits inside its OWN element
            carrying phx-hook="PaperMermaid", so the engine runs over it on
            mount exactly as it does for diagram blocks in the article. --%>
      <aside :if={@rail_events != []} id="goal-path-rail" class="bp-goal-rail">
        <h2 class="bp-goal-rail-title">Goal path</h2>
        <div id="goal-path-graph" phx-hook="PaperMermaid">
          <pre class="mermaid">{@rail_gitgraph}</pre>
        </div>
        <%!-- Clickable event list — doubles as the no-Mermaid fallback. A
              PLAIN click selects (highlight only, via "rail-select"). A
              SHIFT+click is intercepted by the RailDiffSelect hook to pick two
              rows and push "open-diff" — the U3 diff modal below renders the
              line-diff of the two events' payloads. --%>
        <ol class="bp-goal-rail-events" id="goal-path-events" phx-hook="RailDiffSelect">
          <li
            :for={{event, idx} <- Enum.with_index(@rail_events, 1)}
            class={["bp-goal-rail-event", event.id == @selected_event_id && "is-selected"]}
            phx-click="rail-select"
            phx-value-event-id={event.id}
          >
            <span class="bp-goal-rail-event-idx">{idx}</span>
            <span class="bp-goal-rail-event-type">{event.event_type}</span>
          </li>
        </ol>
      </aside>

      <%!-- P6.U3 diff modal. Rendered ONLY when two rail nodes were shift-
            clicked (open-diff). The overlay + close button both fire
            "close-diff"; clicks inside the panel are stopped so the panel
            stays open. `{raw(@diff_html)}` is the TextDiff output — every line
            is HTML-escaped at format time, so the untrusted payload_html is
            shown as text, never executed. --%>
      <div :if={@diff_open} id="bp-diff-modal" class="bp-diff-overlay">
        <%!-- Backdrop is its own element behind the panel; clicking it closes
              the modal. The panel sits above it and does NOT carry the close
              click, so clicks inside the panel never bubble to a close. --%>
        <div class="bp-diff-backdrop" phx-click="close-diff" aria-hidden="true"></div>
        <div class="bp-diff-panel" role="dialog" aria-modal="true">
          <div class="bp-diff-head">
            <h2 class="bp-diff-title">
              <span class="bp-diff-from">{@diff_from}</span>
              <span class="bp-diff-arrow">→</span>
              <span class="bp-diff-to">{@diff_to}</span>
            </h2>
            <button type="button" class="bp-diff-close" phx-click="close-diff" aria-label="Close diff">
              ×
            </button>
          </div>
          {raw(@diff_html)}
        </div>
      </div>
    </main>
    """
  end

  # ── P4 scoped-reader helpers ────────────────────────────────────────────

  # The PluginScopeSession on_mount put %{id, slug} maps into these assigns
  # on the scoped mount; the flat mount has neither → nil → public fetch.
  defp reader_scope(socket) do
    with %{id: ws_id} when is_binary(ws_id) <- socket.assigns[:current_workspace],
         %{id: proj_id} when is_binary(proj_id) <- socket.assigns[:current_project] do
      [workspace_id: ws_id, project_id: proj_id]
    else
      _ -> nil
    end
  end

  # Public (unscoped) reader — flat /papers/:slug and dataset-scoped
  # /d/:dataset/papers/:slug both arrive here (reader_scope == nil). The
  # dataset comes from the path param, defaulting to the production dataset.
  defp fetch_paper(slug, nil, dataset), do: Content.get_public_paper(slug, dataset)
  # Tenant-scoped reader (/w/:ws/p/:proj/papers/:slug) — dataset stays
  # "production" exactly as before (no dataset segment on that route).
  defp fetch_paper(slug, scope, _dataset), do: Content.get_paper(slug, "production", scope)

  # Mount-only sibling of `fetch_paper/3`: `{paper, workspace_row_or_nil}`. On
  # the public surface the resolve pins the Default workspace anyway (am-w1-s3)
  # — keep that row for `reader_theme/3`. The scoped surface resolves no
  # workspace row here, so it threads nil and reader_theme reads by id as
  # before. Refetch paths (rev-gap, action reload) keep calling `fetch_paper/3`.
  defp fetch_paper_with_workspace(slug, nil, dataset) do
    Content.Papers.get_public_paper_with_workspace(slug, dataset) || {nil, nil}
  end

  defp fetch_paper_with_workspace(slug, scope, dataset),
    do: {fetch_paper(slug, scope, dataset), nil}
end
