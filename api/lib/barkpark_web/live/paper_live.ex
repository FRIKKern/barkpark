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
  alias Barkpark.PortableDoc.Render

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    paper = Content.get_paper(slug)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(slug))
    end

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
      |> assign_block_mode(paper)

    {:ok, socket, layout: false}
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
    </main>
    """
  end
end
