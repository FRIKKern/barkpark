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

  The grid itself is `BarkparkWeb.Studio.SheetGrid` under
  `{write_capable: false, live_session: false, chrome: :reader}` — the one
  host that says no on all three axes. Every editing affordance stripped
  (markup AND the component's server-side `send_ops` guard), no draft byte
  reachable, no Studio chrome; tab switching kept.

  PUBLISHED-PERSPECTIVE, NOT LIVE-DRAFT: this reader does NOT subscribe to
  the sheet session's delta topic. Session deltas (`{:sheets_op, …}`) carry
  unpublished draft edits — a live session is draft-backed (it persists via
  `DraftId`), so streaming them would leak in-progress edits to anonymous
  visitors and make the live socket disagree with a cold reload. Instead
  this LiveView subscribes to the PUBLISHED-doc topic (`Content.doc_topic/4`)
  and, when a publish lands, re-reads the published perspective and refreshes
  the grid via `send_update/3`. Anonymous readers only ever see published
  content — the same contract every other public read path in Barkpark holds.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Envelope}

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
        # Field-visibility seal (fail-closed): redact the published sheet's
        # content under the ANONYMOUS caller before ANY consumer (the preview
        # manifest AND SheetGrid) reads it.
        doc = seal(doc)

        if connected?(socket) do
          # The PUBLISHED-doc topic — a publish (or any published-row write)
          # broadcasts `{:doc_updated, …}` here. Deliberately NOT the session
          # delta topic: draft edits must never stream to anonymous readers.
          Phoenix.PubSub.subscribe(
            Barkpark.PubSub,
            Content.doc_topic(
              Content.published_id(doc.doc_id),
              "sheet",
              doc.workspace_id,
              @dataset
            )
          )
        end

        # Preview manifest for the social-share head (preview-contract pc-w2) —
        # the SAME shared emitter the papers reader uses. Computed in mount so
        # the DEAD render already carries the og/twitter head (unfurlers run no
        # JS). A sheet's raw type maps to og:type=website (D8).
        preview =
          BarkparkWeb.ShareMeta.manifest(
            doc.content || %{},
            "/sheets/#{slug}",
            "sheet",
            doc.title || slug
          )

        {:ok,
         assign(socket,
           slug: slug,
           doc: doc,
           dataset: @dataset,
           preview: preview,
           page_title: doc.title || slug
         ), layout: false}
    end
  end

  # A publish (or any published-row write) landed on the doc topic. Re-read
  # the PUBLISHED perspective and refresh the grid — never trust the payload
  # (a draft persist broadcasts here too), always fetch published content, so
  # the reader stays published-only by construction (fail closed).
  @impl true
  def handle_info({:doc_updated, _msg}, socket) do
    case Content.get_public_document("sheet", socket.assigns.slug, socket.assigns.dataset) do
      nil ->
        {:noreply, socket}

      doc ->
        # Same fail-closed seal as mount — the refresh must never forward a
        # newly-declared private field to the anonymous grid.
        doc = seal(doc)

        send_update(BarkparkWeb.Studio.SheetGrid,
          id: "sheet-reader-#{socket.assigns.slug}",
          published_content: doc.content || %{}
        )

        {:noreply, assign(socket, doc: doc)}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # Redact a published sheet's `content` through the canonical Envelope
  # field-visibility chokepoint under the ANONYMOUS caller — the public reader
  # is an anonymous principal, so it may see only public fields; a `private` /
  # `owner_only` / `readable_by` (or encrypted) field is DROPPED before it can
  # reach SheetGrid or the social-share preview manifest. Mirrors the public
  # paper reader's seal (`Barkpark.Content.Papers.reader_source/3` →
  # `Envelope.render(paper, schema, CallerContext.anonymous())`).
  #
  # LATENT hardening: with no sheet field declaring visibility today the content
  # is unchanged and every render is byte-identical; it fails closed the instant
  # a sheet schema declares field visibility. `owner_id` is nil (anonymous),
  # so an `owner_only` field conservatively drops. Schema is scoped to the
  # published doc's own workspace (the seeded Default public tenant).
  defp seal(%{content: content} = doc) do
    schema =
      case Content.Schema.get_schema_for_redaction("sheet", @dataset,
             workspace_id: doc.workspace_id
           ) do
        {:ok, s} -> s
        _ -> nil
      end

    %{doc | content: Envelope.redact(content || %{}, schema, CallerContext.anonymous(), nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="bp-sheet-shell">
      <header class="bp-sheet-head" data-test-id="sheet-reader-head">
        <p class="bp-sheet-eyebrow">Sheet</p>
        <h1 class="bp-sheet-title"><%= @doc.title || @slug %></h1>
        <p class="bp-sheet-byline"><code><%= @slug %></code> · updates on publish</p>
      </header>
      <.live_component
        module={BarkparkWeb.Studio.SheetGrid}
        id={"sheet-reader-#{@slug}"}
        doc={@doc}
        dataset={@dataset}
        is_draft={false}
        write_capable={false}
        live_session={false}
        chrome={:reader}
      />
    </main>
    """
  end
end
