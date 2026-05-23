defmodule BarkparkWeb.PaperLive do
  @moduledoc """
  Live render of a paperflow paper inside Barkpark (convergence MVP,
  masterplan Figure 6).

  On mount: load the stored HTML for `:slug`, subscribe to the paper's per-doc
  PubSub topic, and render the body inside a container via `raw(@html)`.

  On `{:paper_updated, …}`: **re-assign** `@html` to the new HTML. We do NOT
  remount, do NOT `push_navigate`, do NOT redirect. LiveView ships a minimal
  DOM diff over the persistent socket and morphdom patches the container in
  place — no reload, by construction. Block-by-block streaming (portable-doc
  + render walker) is a later refinement; this slice re-assigns the full
  opaque HTML each broadcast.

  Note on `raw/1`: papers are our own HTML, produced by paperflow's doc
  pipeline, so injecting it unescaped is acceptable for personal-local use.
  Revisit sanitization only if papers ever carry untrusted content.

  Layout: the full-document `paper.html.heex` is the ROOT layout (set in the
  router's `:papers` live_session); `mount/3` returns `layout: false` so the
  studio app shell does not wrap the paper.
  """
  use BarkparkWeb, :live_view

  # `raw/1` lives in Phoenix.HTML; the :live_view macro imports
  # Phoenix.HTML.Form but not the parent module, so import it here.
  import Phoenix.HTML, only: [raw: 1]

  alias Barkpark.Papers

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    paper = Papers.get_paper(slug)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Papers.topic(slug))
    end

    {
      :ok,
      socket
      |> assign(:slug, slug)
      |> assign(:found, not is_nil(paper))
      |> assign(:rev, paper && paper.rev)
      |> assign(:html, (paper && paper.body_html) || ""),
      # The full-document `paper.html.heex` is the ROOT layout (set in the
      # router's :papers live_session). Disable the inner/app layout so the
      # studio chrome shell does not wrap the paper.
      layout: false
    }
  end

  @impl true
  def handle_info({:paper_updated, %{html: html} = msg}, socket) do
    # Re-assign only. No remount, no navigate — LiveView diffs the DOM.
    {:noreply,
     socket
     |> assign(:html, html)
     |> assign(:found, true)
     |> assign(:rev, msg[:rev])}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="bp-paper-shell">
      <%!-- Sentinel: rendered once at mount, OUTSIDE the re-assigned @html
            container. It survives a handle_info DOM diff but would be torn
            down by a remount/navigate — the surviving-sentinel proof of
            no-reload. --%>
      <div id="paper-sentinel" data-slug={@slug} hidden></div>

      <%= if @found do %>
        <article id="paper-body" data-rev={@rev}>{raw(@html)}</article>
      <% else %>
        <article id="paper-body" data-rev={@rev}>
          <p id="paper-empty">No paper saved yet for <code>{@slug}</code>.</p>
        </article>
      <% end %>
    </main>
    """
  end
end
