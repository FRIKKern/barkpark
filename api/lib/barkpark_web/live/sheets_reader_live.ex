defmodule BarkparkWeb.SheetsReaderLive do
  @moduledoc """
  The live public sheet reader at `/sheets/:slug` (Sheets M4) — the
  Bulldocs-reader precedent applied to sheets: the Sheets plugin mounts
  this CORE LiveView on the `:public_root` route bucket with its own
  full-document `:sheets` root layout (no studio chrome); this module
  stays in core like `BarkparkWeb.BulldocsLive` does (the plugin is the
  wiring, the core keeps the machinery).

  PUBLISHED-ONLY: the slug resolves via `Content.get_public_document/2`
  (the seeded Default workspace, the one deterministic public tenant —
  barkpark-w9dg). A draft-only or unknown slug raises `NotFound`
  (`plug_status: 404`), like the papers contract demands publicly.

  The grid itself is `BarkparkWeb.Studio.SheetGrid` in `read_only` mode —
  every editing affordance stripped (markup AND the component's
  server-side `send_ops` guard), tab switching kept. This LiveView
  subscribes to the sheet session's delta topic (`Session.topic/3`, keyed
  with the doc's owning workspace — what the session broadcasts with) and
  forwards `{:sheets_op, …}` frames into the component via `send_update/3`
  exactly like StudioLive, so viewers watch edits live.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  # The public reader's tenant dataset — same constant the papers reader
  # resolves against (`Content.get_public_paper/2`'s default).
  @dataset "production"

  defmodule NotFound do
    @moduledoc "Raised for an unknown or draft-only (unpublished) sheet slug — renders 404."
    defexception [:message, plug_status: 404]
  end

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Content.get_public_document("sheet", slug, @dataset) do
      nil ->
        raise NotFound, message: "no published sheet #{inspect(slug)}"

      doc ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(
            Barkpark.PubSub,
            Session.topic(slug, @dataset, doc.workspace_id)
          )
        end

        {:ok,
         assign(socket,
           slug: slug,
           doc: doc,
           dataset: @dataset,
           page_title: doc.title || slug
         ), layout: false}
    end
  end

  # A session delta — forward into the grid component (it owns all grid
  # state; same shape as StudioLive's forwarding).
  @impl true
  def handle_info({:sheets_op, payload}, socket) do
    send_update(BarkparkWeb.Studio.SheetGrid,
      id: "sheet-reader-#{socket.assigns.slug}",
      sheets_op: payload
    )

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="bp-sheet-shell">
      <header class="bp-sheet-head" data-test-id="sheet-reader-head">
        <p class="bp-sheet-eyebrow">Sheet</p>
        <h1 class="bp-sheet-title"><%= @doc.title || @slug %></h1>
        <p class="bp-sheet-byline"><code><%= @slug %></code> · live — edits appear as they happen</p>
      </header>
      <.live_component
        module={BarkparkWeb.Studio.SheetGrid}
        id={"sheet-reader-#{@slug}"}
        doc={@doc}
        dataset={@dataset}
        is_draft={false}
        read_only={true}
      />
    </main>
    """
  end
end
