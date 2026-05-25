defmodule BarkparkWeb.PaperLive do
  @moduledoc """
  Live render of a paperflow paper inside Barkpark (convergence masterplan
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
  multi-block append sequence (see `paper_live_test.exs`).

  Layout: the full-document `paper.html.heex` is the ROOT layout (set in the
  router's `:papers` live_session); `mount/3` returns `layout: false`.

  Note on `raw/1`: papers are our own HTML, produced by paperflow's doc
  pipeline, so injecting it unescaped is acceptable for personal-local use.
  """
  use BarkparkWeb, :live_view

  # `raw/1` lives in Phoenix.HTML; the :live_view macro imports
  # Phoenix.HTML.Form but not the parent module, so import it here.
  import Phoenix.HTML, only: [raw: 1]

  alias Barkpark.Content
  alias Barkpark.Papers.Events
  alias Barkpark.Papers.TextDiff
  alias Barkpark.PortableDoc.Render

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    paper = Content.get_paper(slug)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(slug))
    end

    rail_events = load_rail_events(paper)

    socket =
      socket
      |> assign(:slug, slug)
      |> assign(:found, not is_nil(paper))
      |> assign(:rev, paper_rev(paper))
      # `:article?` is the per-doc style marker (`content["style"] == "article"`).
      # The root `:paper` layout reads it to switch on article page chrome; the
      # block render path reads it to render each block in `:article` palette.
      # Non-article papers leave it false → email default, chrome unchanged.
      |> assign(:article?, paper_article?(paper))
      |> assign(:html, paper_html(paper))
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
      |> assign_block_mode(paper)

    {:ok, socket, layout: false}
  end

  # ── P6.U2 goal-path rail ──────────────────────────────────────────────────

  # Load the lifecycle events for the paper's goal. U1 stores the goal id at
  # `content["goal_id"]`; absent it (or with zero events) we return [] and the
  # template renders no rail at all — the article reading column is unchanged.
  defp load_rail_events(%{content: content}) when is_map(content) do
    case Map.get(content, "goal_id") do
      goal_id when is_binary(goal_id) and goal_id != "" -> Events.list_for_goal(goal_id)
      _ -> []
    end
  end

  defp load_rail_events(_), do: []

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
  def handle_event("open-diff", %{"from" => from_id, "to" => to_id}, socket) do
    from = Events.get_event(from_id)
    to = Events.get_event(to_id)

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

  # Pull the streaming rev / cached HTML / blocks out of the paper document's
  # `content` map (papers are type-"paper" documents now).
  defp paper_rev(nil), do: 0
  defp paper_rev(%{content: content}), do: Map.get(content || %{}, "rev") || 0

  defp paper_html(nil), do: ""
  defp paper_html(%{content: content}), do: Map.get(content || %{}, "body_html") || ""

  defp paper_blocks(%{content: content}), do: Map.get(content || %{}, "blocks")
  defp paper_blocks(_), do: nil

  # The per-doc style marker. An article paper sets `content["style"] ==
  # "article"`; everything else (and the empty state) is the email default.
  defp paper_article?(%{content: content}), do: Map.get(content || %{}, "style") == "article"
  defp paper_article?(_), do: false

  # Render opts threaded into every block render. Article papers carry
  # `style: :article`; the empty map keeps the email default byte-unchanged.
  defp render_opts(true), do: %{style: :article}
  defp render_opts(false), do: %{}

  # A paper with a non-nil block list streams its blocks; HTML-only papers
  # (and the empty state) keep the raw-HTML container.
  defp assign_block_mode(socket, %{content: %{"blocks" => blocks}} = paper) when is_list(blocks) do
    socket
    |> assign(:block_mode, true)
    |> stream(:blocks, to_stream_items(blocks, paper_article?(paper)))
  end

  defp assign_block_mode(socket, _paper) do
    socket
    |> assign(:block_mode, false)
    # Initialise an empty stream so the template can reference @streams.blocks
    # uniformly even on the HTML-only path (it just stays empty).
    |> stream(:blocks, [])
  end

  # Each stream item needs a stable `:id` (the block id) and its rendered
  # fragment. Only top-level blocks are streamed individually; a `section`
  # block renders as one fragment (its children live inside it). An article
  # paper renders each block in the `:article` palette so the live per-block
  # output matches the article body_html cache.
  defp to_stream_items(blocks, article?) do
    opts = render_opts(article?)

    Enum.map(blocks, fn block ->
      %{id: Map.get(block, "id"), html: Render.render_block(block, opts)}
    end)
  end

  # ── delta frame (Wave 4) ──────────────────────────────────────────────────

  @impl true
  def handle_info({:paper_block, frame}, socket) do
    cond do
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

  def handle_info({:paper_updated, %{html: html} = msg}, socket) do
    # Re-assign only. No remount, no navigate — LiveView diffs the DOM.
    {:noreply,
     socket
     |> assign(:html, html)
     |> assign(:found, true)
     |> assign(:block_mode, false)
     |> assign(:rev, msg[:rev] || socket.assigns.rev)}
  end

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

  defp apply_delta(socket, %{op_kind: kind, block_id: id, fragment_html: html, position: pos} = frame)
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
    case Content.get_paper(socket.assigns.slug) do
      nil ->
        socket

      paper ->
        article? = paper_article?(paper)

        case paper_blocks(paper) do
          blocks when is_list(blocks) ->
            socket
            |> stream(:blocks, to_stream_items(blocks, article?), reset: true)
            |> assign(:rev, paper_rev(paper))
            |> assign(:article?, article?)
            |> assign(:block_mode, true)
            |> assign(:found, true)

          _ ->
            # Refetched a paper that has reverted to HTML-only — fall back.
            socket
            |> assign(:html, paper_html(paper))
            |> assign(:rev, paper_rev(paper))
            |> assign(:article?, article?)
            |> assign(:block_mode, false)
            |> assign(:found, true)
        end
    end
  end

  # Stream dom ids are namespaced by the stream name; mirror that so deletes by
  # id line up with what the template renders.
  defp dom_id(id), do: "blocks-#{id}"

  @impl true
  def render(assigns) do
    ~H"""
    <main class={["bp-paper-shell", @article? && "bp-paper-article"]}>
      <%!-- Sentinel: rendered once at mount, OUTSIDE the streamed/re-assigned
            container. It survives a handle_info DOM diff but would be torn
            down by a remount/navigate — the surviving-sentinel proof of
            no-reload. --%>
      <div id="paper-sentinel" data-slug={@slug} hidden></div>

      <%= cond do %>
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
end
