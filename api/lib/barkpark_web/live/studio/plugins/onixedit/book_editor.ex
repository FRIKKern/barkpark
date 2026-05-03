defmodule BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor do
  @moduledoc """
  Phase 5 WI1 — OnixEdit `book` editor LiveView shell + 8-tab framework.

  This module is the **shell only** — it owns layout, document state, the tab
  nav strip, and the `?tab=` URL contract. It does NOT implement any tab body.
  WI3 (Subjects, Contributors) and WI4 (Identity, Title, Publishing, Supply,
  Marketing, Related) drop their components into the seam below.

  ## Module namespace

  Lives at `BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor`, matching the
  `BarkparkWeb.Studio.*` convention used by every other LiveView under
  `api/lib/barkpark_web/live/studio/` (StudioLive, MediaLive, SettingsLive,
  DocumentEditLive, Plugins.Adapter, …). The Phase 4 WI4 commit (726cf76)
  documented this convention and chose it over the brief's nominal
  `BarkparkWeb.Live.Studio.*` for Phoenix endpoint coherence; we follow the
  same precedent.

  ## Route

      live "/onixedit/book/:doc_id", Plugins.OnixEdit.BookEditor

  Mounted under the existing `/studio/:dataset` scope, so `@dataset` is
  available in `params`. Auth follows the same convention as `StudioLive`
  (no extra `on_mount` — Studio is open per existing decision).

  ## Tabs

  Eight tabs, in this order, with URL slugs in parentheses:

      Identity (identity) | Title (title) | Contributors (contributors)
      Subjects (subjects) | Publishing (publishing) | Supply (supply)
      Marketing (marketing) | Related (related)

  `handle_params/3` reads `?tab=<slug>` and assigns `@active_tab` as an atom.
  Default when none given: `:identity`. Unknown slug falls back to default and
  flashes a warning. Tab nav uses `<.link patch={~p"…?tab=…"}>` so URL state
  survives without a full LiveView re-mount.

  ## Seam contract for WI3 / WI4

  The shell renders each tab body via `render_tab/2`, a private dispatch on
  the `@active_tab` atom. Each clause currently emits a placeholder
  paragraph. WI3 and WI4 replace clauses by swapping the placeholder for a
  function-component or `<.live_component>` call. The contract WI3/WI4 must
  honor:

    * **Render shape** — function component (`<.identity_tab assigns={…} />`)
      or LiveComponent (`<.live_component module={…} id={…} … />`). Either
      works; the seam is just "swap the placeholder block".

    * **Assigns available in `render_tab/2`** —
      `:doc` (the `%Document{}` or `nil` for new),
      `:schema` (the `%SchemaDefinition{}` for `book`),
      `:form` (current form-data map, string-keyed),
      `:dataset`,
      `:doc_id`,
      `:active_tab`,
      `:save_status`.

    * **Save / change events** — child components emit a phx-change/phx-submit
      event named `"autosave"` (matching Studio's existing convention) with
      params shaped `%{"doc" => %{<field> => <value>, …}}`. The shell handles
      it via `handle_event/3` and patches `@form`.

    * **No new auth surface** — D7 and D12 hold; no `Code.eval_*`, no TUI
      changes. v1 schemas are untouched (they never reach this module —
      StudioLive routes them through its existing `render_input/2`).

  ## Phase 4 v2 adapter handshake

  The Phase 4 v2 field adapter (`BarkparkWeb.Studio.Plugins.Adapter`) renders
  individual v2 fields inline. WI3/WI4 will call into that adapter (and into
  `BarkparkWeb.Studio.Plugins.FieldComponents`) to draw the actual editor
  primitives for composites, arrayOf, codelist, and localizedText. The shell
  passes `:schema`, `:form`, `:doc` so each tab can run the adapter on the
  subset of `schema.fields` it owns.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Content
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Status, as: BokbasenStatus
  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Plugins.OnixEdit.Export.StatusPill
  alias BarkparkWeb.Studio.Plugins.Adapter, as: PluginAdapter
  alias BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor.ThemaTreePicker

  @type tab ::
          :identity
          | :title
          | :contributors
          | :subjects
          | :publishing
          | :supply
          | :marketing
          | :related

  @tabs [
    {:identity, "Identity"},
    {:title, "Title"},
    {:contributors, "Contributors"},
    {:subjects, "Subjects"},
    {:publishing, "Publishing"},
    {:supply, "Supply"},
    {:marketing, "Marketing"},
    {:related, "Related"}
  ]

  @tab_keys Enum.map(@tabs, &elem(&1, 0))
  @tab_slug_to_atom Map.new(@tabs, fn {atom, _} -> {Atom.to_string(atom), atom} end)
  @default_tab :identity
  @schema_name "book"

  # Tab → top-level field-name membership for the WI4 tabs.
  #
  # The book.json schema does not carry a per-field tab annotation
  # (decision: keep schema clean and let the editor own tab layout — the
  # ONIX 3.0 element-block grouping is an editor concern, not a schema
  # concern). This map encodes the WI4 grouping; WI3 owns the
  # `:contributors` and `:subjects` keys (left absent here).
  @wi4_tab_fields %{
    identity: [
      "notificationType",
      "deletionText",
      "recordSourceType",
      "recordSourceIdentifier",
      "recordSourceName",
      "productIdentifiers",
      "barcode",
      "productForm",
      "productFormDetail",
      "productFormFeatures",
      "productPackaging",
      "productFormDescription",
      "productPartCount",
      "productParts",
      "epubTechnicalProtection",
      "epubUsageConstraints",
      "extents",
      "illustrationsNote",
      "ancillaryContents",
      "productClassifications",
      "bp_internal_note",
      "bp_export_status",
      "bp_last_exported_at"
    ],
    title: [
      "titleDetails",
      "thesis",
      "editionType",
      "editionNumber",
      "editionVersionNumber",
      "editionStatement",
      "noEdition",
      "religiousText",
      "languages"
    ],
    publishing: [
      "publishingDetail"
    ],
    supply: [
      "productSupplies"
    ],
    marketing: [
      "audienceCodes",
      "audienceRanges",
      "audienceDescription",
      "complexity",
      "collateralDetail",
      "contentDetail"
    ],
    related: [
      "relatedMaterial"
    ]
  }

  @doc "Returns the ordered tab list as `[{atom, label}, …]`."
  def tabs, do: @tabs

  @doc "Returns just the tab atoms in display order."
  def tab_keys, do: @tab_keys

  @impl true
  def mount(%{"dataset" => dataset, "doc_id" => doc_id}, _session, socket) do
    pub_id = Content.published_id(doc_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")
      # WI5 — receive lifecycle updates from the Bokbasen PublishWorker so the
      # toolbar status pill updates without a page reload. Subscribe on both
      # draft and published forms of the doc_id so we catch transitions
      # regardless of which form the worker writes to.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "bokbasen:document:#{pub_id}")
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "bokbasen:document:#{Content.draft_id(pub_id)}")
    end

    schema =
      case Content.get_schema(@schema_name, dataset) do
        {:ok, s} -> s
        _ -> nil
      end

    socket =
      socket
      |> assign(
        dataset: dataset,
        doc_id: pub_id,
        type: @schema_name,
        schema: schema,
        active_tab: @default_tab,
        save_status: "",
        subjects_thema: MapSet.new(),
        show_publish_modal: false,
        publish_preview: nil,
        bp_status: %{},
        show_republish_modal: false,
        show_edit_warning_modal: false,
        edit_warning_dismissed: false,
        pending_save_params: nil,
        dirty_since_signoff: false
      )
      |> load_document()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {tab, flash?} = parse_tab(params["tab"])

    socket =
      socket
      |> assign(active_tab: tab)
      |> assign(:page_title, tab_title(tab))

    socket =
      if flash?,
        do: put_flash(socket, :error, "Unknown tab — showing #{tab_title(tab)}"),
        else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_info({:document_changed, %{type: type, doc_id: changed_id}}, socket) do
    if type == socket.assigns.type and Content.published_id(changed_id) == socket.assigns.doc_id do
      {:noreply, load_document(socket)}
    else
      {:noreply, socket}
    end
  end

  # Emission contract from ThemaTreePicker (Phase 5 WI2). The picker emits its
  # current selection as a MapSet whenever the user toggles a code; we mirror it
  # into `@subjects_thema` and the form, then run the standard save path so the
  # sorted list lands in `doc.content["themaSubjectCategory"]` via
  # `build_content/2`. The schema declares the field as `arrayOf` codelist (ONIX
  # 3.0 §P.12 `<Subject>` is repeatable; EDItEUR Thema Best Practice allows a
  # main subject plus qualifiers/secondaries), so the multi-value shape matches.
  def handle_info({:thema_selection_changed, %MapSet{} = codes}, socket) do
    {:noreply, persist_thema(socket, codes)}
  end

  # WI5 — broadcast from `Bokbasen.PublishWorker.persist_status/2`. The
  # payload is the full merged status map (state, submission_id, last_error,
  # …); we mirror it into `@bp_status` so the toolbar pill picks up the new
  # color + tooltip on the next render. We do NOT reload the doc here — the
  # broadcast already contains the authoritative status, and a re-fetch
  # would race against an in-flight DB update from the worker.
  def handle_info({:bokbasen_status_update, %{} = status}, socket) do
    {:noreply, assign(socket, :bp_status, status)}
  end

  @impl true
  def handle_event("autosave", %{"doc" => params}, socket) do
    {:noreply, do_save(%{"doc" => params}, socket)}
  end

  def handle_event("save", %{"doc" => params} = full_params, socket) do
    if signed_off?(socket.assigns.bp_status) and not socket.assigns.edit_warning_dismissed do
      {:noreply,
       socket
       |> assign(:pending_save_params, full_params)
       |> assign(:show_edit_warning_modal, true)}
    else
      socket = do_save(%{"doc" => params}, socket)
      {:noreply, put_flash(socket, :info, "Changes saved")}
    end
  end

  def handle_event("publish", _params, socket) do
    case Content.publish_document(
           socket.assigns.doc_id,
           socket.assigns.type,
           socket.assigns.dataset
         ) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Document published") |> load_document()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to publish")}
    end
  end

  def handle_event("unpublish", _params, socket) do
    case Content.unpublish_document(
           socket.assigns.doc_id,
           socket.assigns.type,
           socket.assigns.dataset
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Document unpublished") |> load_document()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unpublish")}
    end
  end

  # WI6 — Export to ONIX. Pushes a `download` event to the LiveView client
  # which navigates the browser to the controller URL (the controller streams
  # ONIX XML with `Content-Disposition: attachment`). Keeping the heavy work
  # in the controller lets the LiveView stay light and reuses the same
  # admin-gated pipeline.
  def handle_event("export_onix", _params, socket) do
    url = "/v1/plugins/onixedit/export/#{socket.assigns.dataset}/#{socket.assigns.doc_id}.onix"

    {:noreply, push_event(socket, "download", %{url: url})}
  end

  # WI5 — Publish to Bokbasen flow. Opens the confirmation modal; the user
  # picks "Dry run" (preview only) or "Publish" (enqueue Oban worker).
  def handle_event("publish_to_bokbasen", _params, socket) do
    {:noreply, assign(socket, show_publish_modal: true, publish_preview: nil)}
  end

  def handle_event("cancel_publish_modal", _params, socket) do
    {:noreply, assign(socket, show_publish_modal: false, publish_preview: nil)}
  end

  # Dry run: render the ONIX XML in-memory (XSD-validated by `Export.to_iodata/1`)
  # and stash a preview slice in assigns. We do NOT enqueue the worker and do
  # NOT persist `bp_export_status`. The modal stays open showing the preview.
  def handle_event("confirm_publish_dryrun", _params, socket) do
    case build_preview(socket) do
      {:ok, preview} ->
        {:noreply, assign(socket, publish_preview: preview)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(publish_preview: %{kind: :error, message: format_preview_error(reason)})}
    end
  end

  # Real publish: enqueue the PublishWorker and write a `pending` marker into
  # `bp_export_status` so the toolbar pill flips immediately (the worker will
  # transition through staging → staged → polling → accepted on its own).
  def handle_event("confirm_publish_real", _params, socket) do
    case enqueue_publish(socket) do
      {:ok, _job, status} ->
        {:noreply,
         socket
         |> assign(show_publish_modal: false, publish_preview: nil, bp_status: status)
         |> load_document()
         |> put_flash(:info, "Publish enqueued — track status in toolbar pill")}

      {:error, :no_doc} ->
        {:noreply,
         socket
         |> assign(show_publish_modal: false, publish_preview: nil)
         |> put_flash(:error, "No document loaded — save first")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(show_publish_modal: false, publish_preview: nil)
         |> put_flash(:error, "Publish failed to enqueue: #{format_preview_error(reason)}")}
    end
  end

  def handle_event("discard-draft", _params, socket) do
    case Content.discard_draft(socket.assigns.doc_id, socket.assigns.type, socket.assigns.dataset) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Draft discarded") |> load_document()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "No draft to discard")}
    end
  end

  # ── WI3 — Re-publish modal (notificationType=04 UPDATE) ────────────────────

  def handle_event("open-republish-modal", _params, socket) do
    {:noreply, assign(socket, :show_republish_modal, true)}
  end

  def handle_event("dismiss-republish-modal", _params, socket) do
    {:noreply, assign(socket, :show_republish_modal, false)}
  end

  # Persist `notificationType=04` into the doc, then enqueue PublishWorker on
  # the freshly-reloaded doc so the worker reads the updated content. Reset
  # `:dirty_since_signoff` because the user has just initiated a fresh
  # republish — the gate stays closed until the next post-acceptance edit.
  def handle_event("confirm-republish", _params, socket) do
    case do_republish(socket) do
      {:ok, socket} ->
        {:noreply,
         socket
         |> assign(show_republish_modal: false, dirty_since_signoff: false)
         |> put_flash(:info, "Re-publish enqueued — track status in toolbar pill")}

      {:error, :no_doc, socket} ->
        {:noreply,
         socket
         |> assign(show_republish_modal: false)
         |> put_flash(:error, "No document loaded — save first")}

      {:error, reason, socket} ->
        {:noreply,
         socket
         |> assign(show_republish_modal: false)
         |> put_flash(:error, "Re-publish failed: #{format_preview_error(reason)}")}
    end
  end

  # ── WI3 — Edit-warning modal (signed-off save guard) ───────────────────────

  def handle_event("confirm-save-after-warning", _params, socket) do
    params = socket.assigns.pending_save_params || %{"doc" => %{}}
    socket = do_save(params, socket)

    {:noreply,
     socket
     |> assign(
       show_edit_warning_modal: false,
       edit_warning_dismissed: true,
       pending_save_params: nil
     )
     |> put_flash(:info, "Changes saved")}
  end

  def handle_event("dismiss-edit-warning", _params, socket) do
    {:noreply,
     socket
     |> assign(show_edit_warning_modal: false, pending_save_params: nil)}
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp parse_tab(nil), do: {@default_tab, false}

  defp parse_tab(slug) when is_binary(slug) do
    case Map.fetch(@tab_slug_to_atom, slug) do
      {:ok, atom} -> {atom, false}
      :error -> {@default_tab, true}
    end
  end

  defp parse_tab(_), do: {@default_tab, true}

  defp tab_title(atom) do
    Enum.find_value(@tabs, "Identity", fn
      {^atom, label} -> label
      _ -> false
    end)
  end

  defp save(socket, form) do
    doc = socket.assigns[:doc]
    type = socket.assigns.type
    schema = socket.assigns.schema
    dataset = socket.assigns.dataset

    if doc do
      content = build_content(form, schema)
      published_id = Content.published_id(doc.doc_id)

      attrs = %{
        "doc_id" => Content.draft_id(published_id),
        "title" => Map.get(form, "title", doc.title),
        "status" => Map.get(form, "status", doc.status),
        "content" => content
      }

      case Content.upsert_document(type, attrs, dataset) do
        {:ok, saved} ->
          assign(socket,
            doc: saved,
            is_draft: Content.draft?(saved.doc_id),
            form: form,
            save_status: "Saved"
          )

        {:error, _} ->
          assign(socket, save_status: "Save failed")
      end
    else
      assign(socket, form: form)
    end
  end

  defp build_content(form, nil), do: Map.drop(form, ["title", "status"])

  defp build_content(form, schema) do
    schema.fields
    |> Enum.reduce(%{}, fn field, acc ->
      key = field["name"]
      val = Map.get(form, key, "")

      cond do
        key in ["title", "status"] -> acc
        val == "" or is_nil(val) -> acc
        true -> Map.put(acc, key, val)
      end
    end)
  end

  defp load_document(socket) do
    type = socket.assigns.type
    doc_id = socket.assigns.doc_id
    schema = socket.assigns.schema
    dataset = socket.assigns.dataset
    draft_id = Content.draft_id(doc_id)
    pub_id = Content.published_id(doc_id)

    draft_result = Content.get_document(draft_id, type, dataset)
    pub_result = Content.get_document(pub_id, type, dataset)

    {doc, is_draft} =
      case draft_result do
        {:ok, d} ->
          {d, true}

        _ ->
          case pub_result do
            {:ok, d} -> {d, false}
            _ -> {nil, false}
          end
      end

    assign(socket,
      doc: doc,
      is_draft: is_draft,
      has_published: match?({:ok, _}, pub_result),
      form: doc_to_form(doc, schema),
      subjects_thema: extract_thema(doc),
      bp_status: BokbasenStatus.read(doc),
      page_title: (doc && doc.title) || "New Book"
    )
  end

  # Re-hydrate the picker's MapSet from `doc.content["themaSubjectCategory"]`.
  # Tolerates string lists (the canonical shape we persist), nil / missing keys,
  # and accidental scalar values (treated as a single-element selection).
  defp extract_thema(nil), do: MapSet.new()

  defp extract_thema(%{content: content}) when is_map(content) do
    case Map.get(content, "themaSubjectCategory") do
      list when is_list(list) -> MapSet.new(Enum.filter(list, &is_binary/1))
      code when is_binary(code) and code != "" -> MapSet.new([code])
      _ -> MapSet.new()
    end
  end

  defp extract_thema(_), do: MapSet.new()

  # Mirror the picker's selection into the form as a sorted list and run the
  # standard save path. `build_content/2` keeps `themaSubjectCategory` because
  # the schema declares it as `arrayOf` codelist; the list value passes the
  # nil/empty filter unchanged. When no document exists yet we still keep the
  # MapSet (and the form mirror) in assigns so the picker UI stays in sync;
  # persistence resumes on the next save.
  defp persist_thema(socket, codes) do
    list = codes |> MapSet.to_list() |> Enum.sort()
    form = Map.put(socket.assigns.form, "themaSubjectCategory", list)

    socket
    |> assign(subjects_thema: codes)
    |> save(form)
  end

  defp doc_to_form(nil, _), do: %{"title" => "", "status" => "draft"}

  defp doc_to_form(doc, schema) do
    base = %{"title" => doc.title || "", "status" => doc.status || "draft"}

    if schema do
      Enum.reduce(schema.fields, base, fn field, acc ->
        key = field["name"]

        val =
          case key do
            k when k in ["title", "status"] -> Map.get(acc, key, "")
            _ -> get_in(doc.content || %{}, [key]) || ""
          end

        Map.put(acc, key, val)
      end)
    else
      base
    end
  end

  defp tab_path(dataset, doc_id, tab) do
    "/studio/#{dataset}/onixedit/book/#{doc_id}?tab=#{tab}"
  end

  # ── WI5 — Bokbasen publish helpers ─────────────────────────────────────────

  defp build_preview(%{assigns: %{doc: nil}}), do: {:error, :no_doc}

  defp build_preview(%{assigns: %{doc: doc}}) do
    book_doc = book_doc_from(doc)

    case Export.to_iodata(book_doc) do
      {:ok, iodata} ->
        binary = IO.iodata_to_binary(iodata)
        {:ok, %{kind: :xml, xml: binary, summary: summarize(book_doc, binary)}}

      {:error, {:xsd_invalid, reasons}} ->
        {:error, {:xsd_invalid, reasons}}
    end
  end

  # Re-publish: stamp `notificationType=04` (ONIX UPDATE notification) on the
  # current doc, reload it (so `:doc`/`:form`/`:bp_status` are fresh), then
  # enqueue the standard PublishWorker. Returns the updated socket so the
  # caller can fold modal/dirty assigns onto a single result.
  defp do_republish(%{assigns: %{doc: nil}} = socket), do: {:error, :no_doc, socket}

  defp do_republish(%{assigns: %{doc: doc, type: type, dataset: dataset}} = socket) do
    new_content = Map.put(doc.content || %{}, "notificationType", "04")

    attrs = %{
      "doc_id" => doc.doc_id,
      "title" => doc.title,
      "status" => doc.status,
      "content" => new_content
    }

    case Content.upsert_document(type, attrs, dataset) do
      {:ok, _saved} ->
        socket = load_document(socket)

        case enqueue_publish(socket) do
          {:ok, _job, status} ->
            {:ok, assign(socket, :bp_status, status)}

          {:error, :no_doc} ->
            {:error, :no_doc, socket}

          {:error, reason} ->
            {:error, reason, socket}
        end

      {:error, reason} ->
        {:error, reason, socket}
    end
  end

  defp enqueue_publish(%{assigns: %{doc: nil}}), do: {:error, :no_doc}

  defp enqueue_publish(%{assigns: %{doc: doc, type: type, dataset: dataset}}) do
    args = %{"document_id" => doc.doc_id, "type" => type, "dataset" => dataset}

    case Oban.insert(PublishWorker.new(args)) do
      {:ok, job} ->
        # Mark the doc as pending so the pill flips immediately. Reuse the
        # canonical write path (Status.write/2 broadcasts on PubSub) so the
        # write is identical to a worker-driven update.
        updated = BokbasenStatus.write(doc, %{"state" => "pending", "last_error" => nil})
        {:ok, job, BokbasenStatus.read(updated)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp book_doc_from(%{} = doc) do
    pub_id = Content.published_id(doc.doc_id)

    (doc.content || %{})
    |> Map.delete("bp_export_status")
    |> Map.put("_id", doc.doc_id)
    |> Map.put("_publishedId", pub_id)
    |> Map.put("_type", doc.type)
  end

  defp summarize(book_doc, xml) do
    title =
      case book_doc do
        %{"titleDetails" => [%{"titleText" => t} | _]} when is_binary(t) -> t
        %{"title" => t} when is_binary(t) -> t
        _ -> Map.get(book_doc, "_id", "")
      end

    isbn =
      book_doc
      |> Map.get("productIdentifiers", [])
      |> List.wrap()
      |> Enum.find(fn
        %{"productIdType" => t} -> t in ["15", "03"]
        _ -> false
      end)
      |> case do
        %{"idValue" => v} when is_binary(v) -> v
        _ -> nil
      end

    thema_count =
      book_doc
      |> Map.get("themaSubjectCategory", [])
      |> List.wrap()
      |> length()

    contrib_count =
      book_doc
      |> Map.get("contributors", [])
      |> List.wrap()
      |> length()

    %{
      title: title,
      isbn: isbn,
      thema_count: thema_count,
      contributor_count: contrib_count,
      byte_size: byte_size(xml)
    }
  end

  defp format_preview_error({:xsd_invalid, reasons}) when is_list(reasons) do
    "ONIX failed XSD validation: " <> Enum.join(Enum.take(reasons, 3), "; ")
  end

  defp format_preview_error(:no_doc), do: "No document loaded"

  defp format_preview_error(other), do: inspect(other, limit: 100)

  # ── WI3 — sign-off gate helpers ────────────────────────────────────────────

  # Bokbasen sign-off is asserted by `Status.write/2` whenever `accepted_at`
  # lands on the merged composite. The badge / re-publish gate keys off this
  # flag so the editor only nags the user once Bokbasen has actually accepted
  # the submission (`signed_off=true` is derived, never written by hand).
  defp signed_off?(status) when is_map(status), do: Map.get(status, "signed_off") == true
  defp signed_off?(_), do: false

  # Truncated submission id for the badge body. We append a horizontal-ellipsis
  # so it is visually obvious the value is abridged; the full id is exposed via
  # `data-clipboard-text` on the copy link.
  defp submission_id_short(status) do
    status |> Map.get("submission_id", "") |> String.slice(0, 8) |> Kernel.<>("…")
  end

  # Dirty = the editor has accepted at least one autosave/save event since the
  # current `accepted_at` was assigned. We track this via the
  # `:dirty_since_signoff` assign (flipped in `do_save/2` when status is
  # currently signed-off, reset by `confirm-republish` and by mount).
  defp dirty?(%{dirty_since_signoff: true}), do: true
  defp dirty?(_), do: false

  # Extracted body of the original `handle_event("save", …)`. `handle_event/3`
  # now wraps this so the edit-warning modal can intercept saves on signed-off
  # docs without duplicating persistence logic. Autosave routes through here
  # directly (autosaves never trigger the modal — only explicit user saves do).
  defp do_save(%{"doc" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)
    socket = save(socket, form)

    if signed_off?(socket.assigns.bp_status) do
      assign(socket, :dirty_since_signoff, true)
    else
      socket
    end
  end

  # Status pill color/label mapping is centralised in
  # `Barkpark.Plugins.OnixEdit.Export.StatusPill` (Phase 8 WI5) — both this
  # toolbar pill and the admin/bokbasen LV row pill route through the same
  # 5-bucket palette. Phase 7 WI5/WI6 carried inline copies; the helper
  # eliminates the two-place drift risk.

  defp pill_state(%{} = status) do
    case Map.get(status, "state") do
      s when is_binary(s) -> s
      s when is_atom(s) and not is_nil(s) -> Atom.to_string(s)
      _ -> nil
    end
  end

  defp pill_state(_), do: nil

  defp pill_color(state), do: StatusPill.color_class(state)

  defp pill_label(state), do: StatusPill.label(state)

  defp pill_tooltip(%{} = status) do
    case Map.get(status, "last_error") do
      %{"message" => m} when is_binary(m) and m != "" -> m
      %{"summary" => s} when is_binary(s) -> s
      %{"type" => t, "details" => d} when is_binary(t) -> "#{t}: #{inspect(d, limit: 200)}"
      %{"type" => t} when is_binary(t) -> t
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  defp pill_tooltip(_), do: nil

  # ── render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="main-header" style="margin: -24px -24px 24px; padding: 0 24px;">
      <div class="main-header-left">
        <a href={"/studio/#{@dataset}"} class="btn btn-ghost btn-sm">&larr;</a>
        <div>
          <h1 class="h2"><%= (@doc && @doc.title) || "New Book" %></h1>
          <div class="toolbar" style="gap: 6px; margin-top: 2px;">
            <span class="text-xs text-muted">
              <%= if @schema, do: "#{@schema.icon} #{@schema.title}", else: "book" %>
            </span>
            <span class={"badge badge-#{badge_status(@is_draft, @doc)}"}>
              <%= status_label(@is_draft, @doc) %>
            </span>
          </div>
        </div>
      </div>
      <div class="main-header-right">
        <%= render_bokbasen_pill(assigns) %>
        <%= render_signoff_badge(assigns) %>
        <%= if @doc do %>
          <button
            id="onix-export-button"
            class="btn btn-sm"
            phx-click="export_onix"
            phx-hook="OnixDownload"
            data-test-id="onix-export-button"
            aria-label="Export to ONIX"
          >Export to ONIX</button>
          <button
            class="btn btn-sm"
            phx-click="publish_to_bokbasen"
            data-test-id="bokbasen-publish-button"
            aria-label="Publish to Bokbasen"
          >Publish to Bokbasen</button>
          <%= render_republish_button(assigns) %>
        <% end %>
        <%= if @is_draft do %>
          <button class="btn btn-primary btn-sm" phx-click="publish">Publish</button>
          <%= if @has_published do %>
            <button
              class="btn btn-ghost btn-sm"
              phx-click="discard-draft"
              data-confirm="Discard this draft?"
            >Discard draft</button>
          <% end %>
        <% else %>
          <%= if @doc do %>
            <button class="btn btn-sm" phx-click="unpublish">Unpublish</button>
          <% end %>
        <% end %>
      </div>
    </div>

    <nav class="tab-nav" data-test-id="book-editor-tabs"
         style="display: flex; gap: 4px; border-bottom: 1px solid var(--border-muted); margin-bottom: 16px;">
      <%= for {tab_key, label} <- tabs() do %>
        <.link
          patch={tab_path(@dataset, @doc_id, tab_key)}
          class={tab_link_class(tab_key, @active_tab)}
          data-tab={Atom.to_string(tab_key)}
          data-active={if tab_key == @active_tab, do: "true", else: "false"}
        ><%= label %></.link>
      <% end %>
    </nav>

    <div class="card" data-test-id="book-editor-body">
      <div class="card-header">
        <span class="text-sm text-muted">
          <%= tab_title_for(@active_tab) %>
        </span>
        <span class="text-xs text-dim" style="font-family: var(--font-mono);">
          id: <%= @doc_id %>
        </span>
      </div>

      <form phx-submit="save" phx-change="autosave" id="book-editor-form" style="padding: 24px;">
        <%= render_tab(@active_tab, assigns) %>

        <div style="display: flex; gap: 8px; padding-top: 16px; border-top: 1px solid var(--border-muted);">
          <button type="submit" class="btn btn-primary">Save changes</button>
          <a href={"/studio/#{@dataset}"} class="btn">Cancel</a>
          <span class="save-status" style="margin-left: auto; align-self: center;"><%= @save_status %></span>
        </div>
      </form>
    </div>

    <%= render_publish_modal(assigns) %>
    <%= render_republish_modal(assigns) %>
    <%= render_edit_warning_modal(assigns) %>
    """
  end

  # ── WI5 — Bokbasen status pill + publish modal ─────────────────────────────

  defp render_bokbasen_pill(assigns) do
    state = pill_state(assigns.bp_status)
    assigns = assign(assigns, :pill_state, state)

    ~H"""
    <%= if @pill_state do %>
      <span
        class={"badge bp-pill " <> pill_color(@pill_state)}
        data-test-id="bokbasen-status-pill"
        data-bp-state={@pill_state}
        title={pill_tooltip(@bp_status)}
      ><%= pill_label(@pill_state) %></span>
    <% end %>
    """
  end

  defp render_publish_modal(assigns) do
    ~H"""
    <%= if @show_publish_modal do %>
      <div
        class="bp-modal-overlay"
        data-test-id="publish-modal"
        style="position: fixed; inset: 0; background: rgba(0,0,0,0.4); display: flex; align-items: center; justify-content: center; z-index: 1000;"
      >
        <div
          class="bp-modal card"
          style="background: var(--surface, #fff); padding: 24px; min-width: 480px; max-width: 720px; max-height: 80vh; display: flex; flex-direction: column; gap: 12px; overflow: auto;"
        >
          <h2 class="h3" style="margin: 0;">Publish to Bokbasen?</h2>
          <p class="text-sm text-muted" style="margin: 0;">
            <strong>Dry run</strong> renders ONIX XML in-memory and validates against the EDItEUR XSD without contacting Bokbasen.
            <br />
            <strong>Publish</strong> enqueues an async job that stages the submission and polls for acceptance — track progress in the toolbar pill.
          </p>

          <%= render_publish_preview(assigns) %>

          <div style="display: flex; gap: 8px; justify-content: flex-end; padding-top: 8px;">
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="cancel_publish_modal"
              data-test-id="publish-modal-cancel"
            >Cancel</button>
            <button
              type="button"
              class="btn"
              phx-click="confirm_publish_dryrun"
              data-test-id="publish-modal-dryrun"
            >Dry run</button>
            <button
              type="button"
              class="btn btn-primary"
              phx-click="confirm_publish_real"
              data-test-id="publish-modal-confirm"
            >Publish</button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp render_publish_preview(assigns) do
    ~H"""
    <%= if @publish_preview do %>
      <div data-test-id="publish-preview" style="border: 1px solid var(--border-muted); border-radius: 4px; padding: 12px;">
        <%= case @publish_preview do %>
          <% %{kind: :error, message: msg} -> %>
            <p class="text-sm" style="color: var(--error, #b91c1c); margin: 0;" data-test-id="publish-preview-error"><%= msg %></p>
          <% %{kind: :xml, xml: xml, summary: s} -> %>
            <ul class="text-sm" style="margin: 0 0 8px; padding-left: 18px;">
              <li>Title: <strong><%= s.title %></strong></li>
              <li>ISBN: <%= s.isbn || "—" %></li>
              <li>Thema codes: <%= s.thema_count %></li>
              <li>Contributors: <%= s.contributor_count %></li>
              <li>Bytes: <%= s.byte_size %></li>
            </ul>
            <pre
              class="bp-preview-xml"
              data-test-id="publish-preview-xml"
              style="white-space: pre-wrap; word-break: break-all; max-height: 240px; overflow: auto; font-family: var(--font-mono); font-size: 12px; margin: 0; background: var(--surface-muted, #f5f5f5); padding: 8px;"
            ><%= preview_slice(xml) %></pre>
          <% _ -> %>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp preview_slice(xml) when is_binary(xml) do
    xml
    |> String.split("\n")
    |> Enum.take(50)
    |> Enum.join("\n")
  end

  # ── WI3 — sign-off badge + re-publish button + modals ──────────────────────

  defp render_signoff_badge(assigns) do
    status = assigns.bp_status
    submission_id = Map.get(status, "submission_id", "")
    accepted_at = Map.get(status, "accepted_at", "")

    assigns =
      assigns
      |> assign(:signed_off, signed_off?(status))
      |> assign(:submission_short, submission_id_short(status))
      |> assign(:submission_full, submission_id)
      |> assign(
        :badge_title,
        "Signed off · accepted #{accepted_at} · submission #{submission_id}"
      )

    ~H"""
    <%= if @signed_off do %>
      <span
        class="badge bp-pill bp-pill-green"
        data-test-id="bokbasen-signoff-badge"
        title={@badge_title}
      >
        <.icon name="check-circle" size={14} />
        <span>Signed off</span>
        <span class="bp-signoff-id" data-test-id="bokbasen-signoff-submission-id">
          <%= @submission_short %>
        </span>
        <a
          href="#"
          onclick={"navigator.clipboard.writeText('#{@submission_full}'); return false;"}
          data-clipboard-text={@submission_full}
          data-test-id="bokbasen-signoff-copy"
          title="Copy submission id"
        >
          <.icon name="copy" size={12} />
        </a>
      </span>
    <% end %>
    """
  end

  defp render_republish_button(assigns) do
    assigns =
      assigns
      |> assign(:show_republish, signed_off?(assigns.bp_status) and dirty?(assigns))

    ~H"""
    <%= if @show_republish do %>
      <button
        type="button"
        class="btn btn-primary btn-sm"
        phx-click="open-republish-modal"
        data-test-id="bokbasen-republish-button"
      >
        <.icon name="refresh-cw" size={14} /> Re-publish (UPDATE)
      </button>
    <% end %>
    """
  end

  defp render_republish_modal(assigns) do
    ~H"""
    <%= if @show_republish_modal do %>
      <div
        class="bp-modal-overlay"
        data-test-id="republish-modal"
        style="position: fixed; inset: 0; background: rgba(0,0,0,0.4); display: flex; align-items: center; justify-content: center; z-index: 1000;"
      >
        <div
          class="bp-modal card"
          style="background: var(--surface, #fff); padding: 24px; min-width: 480px; max-width: 720px; max-height: 80vh; display: flex; flex-direction: column; gap: 12px; overflow: auto;"
        >
          <h2 class="h3" style="margin: 0;">Re-publish to Bokbasen?</h2>
          <p class="text-sm text-muted" style="margin: 0;">
            This document was already accepted by Bokbasen. Re-publishing stamps the ONIX message as <strong>notificationType <code>04</code> (UPDATE)</strong> and enqueues an async job — track progress in the toolbar pill.
          </p>
          <div style="display: flex; gap: 8px; justify-content: flex-end; padding-top: 8px;">
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="dismiss-republish-modal"
              data-test-id="republish-modal-cancel"
            >Cancel</button>
            <button
              type="button"
              class="btn btn-primary"
              phx-click="confirm-republish"
              data-test-id="republish-modal-confirm"
            >Re-publish (UPDATE)</button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp render_edit_warning_modal(assigns) do
    ~H"""
    <%= if @show_edit_warning_modal do %>
      <div
        class="bp-modal-overlay"
        data-test-id="edit-warning-modal"
        style="position: fixed; inset: 0; background: rgba(0,0,0,0.4); display: flex; align-items: center; justify-content: center; z-index: 1000;"
      >
        <div
          class="bp-modal card"
          style="background: var(--surface, #fff); padding: 24px; min-width: 480px; max-width: 720px; max-height: 80vh; display: flex; flex-direction: column; gap: 12px; overflow: auto;"
        >
          <h2 class="h3" style="margin: 0;">Edit accepted submission?</h2>
          <p class="text-sm text-muted" style="margin: 0;">
            This document has already been accepted by Bokbasen. Saving will diverge the local content from the accepted submission — you will need to <strong>Re-publish (UPDATE)</strong> to bring Bokbasen back in sync.
          </p>
          <div style="display: flex; gap: 8px; justify-content: flex-end; padding-top: 8px;">
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="dismiss-edit-warning"
              data-test-id="edit-warning-modal-cancel"
            >Cancel</button>
            <button
              type="button"
              class="btn btn-primary"
              phx-click="confirm-save-after-warning"
              data-test-id="edit-warning-modal-confirm"
            >Save anyway</button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # ── Tab body dispatch — the WI3 / WI4 seam. ────────────────────────────────
  #
  # Each clause currently renders a placeholder. To wire a real tab, replace
  # the placeholder with a component call:
  #
  #     defp render_tab(:identity, assigns) do
  #       ~H"""
  #       <.live_component
  #         module={BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor.IdentityTab}
  #         id="tab-identity"
  #         doc={@doc}
  #         schema={@schema}
  #         form={@form}
  #       />
  #       """
  #     end
  #
  # Owner: WI4 owns Identity / Title / Publishing / Supply / Marketing /
  # Related. WI3 owns Subjects / Contributors.
  defp render_tab(:identity, assigns), do: render_wi4_tab(:identity, assigns)
  defp render_tab(:title, assigns), do: render_wi4_tab(:title, assigns)
  defp render_tab(:publishing, assigns), do: render_wi4_tab(:publishing, assigns)
  defp render_tab(:supply, assigns), do: render_wi4_tab(:supply, assigns)
  defp render_tab(:marketing, assigns), do: render_wi4_tab(:marketing, assigns)
  defp render_tab(:related, assigns), do: render_wi4_tab(:related, assigns)

  defp render_tab(:contributors, assigns) do
    ~H"""
    <div data-tab-body="contributors">
      <p class="text-sm text-muted">Contributors tab — implemented in WI3</p>
    </div>
    """
  end

  defp render_tab(:subjects, assigns) do
    ~H"""
    <div data-tab-body="subjects">
      <p class="text-sm text-muted" style="margin-bottom: 12px;">
        Thema subject categories. Selections autosave to the draft on every change.
      </p>
      <.live_component
        module={ThemaTreePicker}
        id="thema-picker"
        selected={@subjects_thema}
      />
    </div>
    """
  end

  # ── WI4 generic tab body — picks the relevant subset of @schema.fields,
  # filters by the Simplified/Advanced toggle (`assigns.simplified` —
  # defaults to `false` → show all), and dispatches each field to the v2
  # plugin Adapter (composite / arrayOf / codelist / localizedText) or to a
  # v1 leaf input. ───────────────────────────────────────────────────────
  defp render_wi4_tab(tab, assigns) do
    fields =
      assigns.schema
      |> tab_fields(tab)
      |> Enum.filter(&field_visible?(&1, simplified?(assigns)))

    errors = Map.get(assigns, :validation_errors, %{})

    assigns =
      assigns
      |> assign(:tab_id, Atom.to_string(tab))
      |> assign(:fields, fields)
      |> assign(:errors, errors)

    ~H"""
    <div data-tab-body={@tab_id}>
      <%= if @fields == [] do %>
        <p class="text-sm text-muted" data-empty="true">
          No fields configured for this tab.
        </p>
      <% else %>
        <div class="bp-tab-fields" style="display: flex; flex-direction: column; gap: 16px;">
          <%= for field <- @fields do %>
            <div
              class={field_wrapper_class(@errors, field["name"])}
              data-field-name={field["name"]}
            >
              <%= if !PluginAdapter.v2?(field) do %>
                <label class="bp-field-label" for={leaf_input_id(field["name"])}>
                  <%= field_title(field) %>
                </label>
              <% end %>
              <%= render_field(assigns, field) %>
              <%= for err <- field_errors(@errors, field["name"]) do %>
                <span class="error" data-error-for={field["name"]}><%= err %></span>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Per-field dispatch. v2 → adapter (composite / arrayOf / codelist /
  # localizedText). v1 → leaf input. ─────────────────────────────────────
  defp render_field(assigns, field) do
    if PluginAdapter.v2?(field) do
      PluginAdapter.render(adapter_assigns(assigns), field)
    else
      leaf_input(assigns, field)
    end
  end

  defp adapter_assigns(assigns) do
    assigns
    |> Map.put(:editor_form, assigns.form)
    |> Map.put(:editor_schema, assigns.schema)
    |> Map.put(:validation_errors, Map.get(assigns, :validation_errors, %{}))
  end

  # ── v1 leaf inputs (string, text, boolean, datetime, slug, color, …). ──
  defp leaf_input(assigns, %{"type" => "text", "name" => name} = field) do
    val = Map.get(assigns.form, name, "")
    rows = Map.get(field, "rows") || 3
    assigns = assign(assigns, n: name, v: val, rows: rows)

    ~H"""
    <textarea
      id={leaf_input_id(@n)}
      name={"doc[#{@n}]"}
      class="bp-input form-input"
      rows={@rows}
      phx-debounce="500"
    ><%= @v %></textarea>
    """
  end

  defp leaf_input(assigns, %{"type" => "boolean", "name" => name}) do
    checked = Map.get(assigns.form, name, "") == "true"
    assigns = assign(assigns, n: name, c: checked)

    ~H"""
    <div class="form-checkbox">
      <input type="hidden" name={"doc[#{@n}]"} value="false" />
      <input
        id={leaf_input_id(@n)}
        type="checkbox"
        name={"doc[#{@n}]"}
        value="true"
        checked={@c}
        phx-debounce="100"
      />
    </div>
    """
  end

  defp leaf_input(assigns, %{"type" => "datetime", "name" => name}) do
    val = Map.get(assigns.form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <input
      id={leaf_input_id(@n)}
      type="datetime-local"
      name={"doc[#{@n}]"}
      value={@v}
      class="bp-input form-input"
      phx-debounce="300"
    />
    """
  end

  defp leaf_input(assigns, %{"type" => "color", "name" => name}) do
    val = Map.get(assigns.form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <input
      id={leaf_input_id(@n)}
      type="color"
      name={"doc[#{@n}]"}
      value={@v}
      class="bp-input"
      phx-debounce="300"
    />
    """
  end

  defp leaf_input(assigns, %{"type" => "select", "name" => name, "options" => opts})
       when is_list(opts) do
    val = Map.get(assigns.form, name, "")
    assigns = assign(assigns, n: name, opts: opts, v: val)

    ~H"""
    <select
      id={leaf_input_id(@n)}
      name={"doc[#{@n}]"}
      class="bp-input form-input"
      phx-debounce="300"
    >
      <%= for o <- @opts do %>
        <option value={o} selected={o == @v}><%= o %></option>
      <% end %>
    </select>
    """
  end

  defp leaf_input(assigns, %{"name" => name}) do
    val = Map.get(assigns.form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <input
      id={leaf_input_id(@n)}
      type="text"
      name={"doc[#{@n}]"}
      value={@v}
      class="bp-input form-input"
      phx-debounce="500"
    />
    """
  end

  # ── Field selection / filtering helpers. ───────────────────────────────

  # Resolves the ordered list of raw field maps that belong to `tab`. Honors
  # the schema's actual field order — we walk @schema.fields once and pick
  # the ones whose name appears in the tab's allow-list. Unknown / missing
  # schemas yield an empty list (parent shell renders an empty-state).
  defp tab_fields(nil, _tab), do: []

  defp tab_fields(%{fields: fields}, tab) when is_list(fields) do
    allow = Map.get(@wi4_tab_fields, tab, [])
    allow_set = MapSet.new(allow)

    fields
    |> Enum.filter(fn
      %{"name" => name} -> MapSet.member?(allow_set, name)
      _ -> false
    end)
  end

  defp tab_fields(_, _), do: []

  # `simplified: false` on a field means "Advanced-only — hide in
  # Simplified mode". Default is true (show in both modes). When
  # `assigns.simplified` is `false` (the default Advanced view) we keep
  # everything; when it is `true` we drop fields that opted out.
  defp simplified?(%{simplified: true}), do: true
  defp simplified?(%{simplified: _}), do: false
  defp simplified?(_), do: false

  defp field_visible?(_field, false), do: true

  defp field_visible?(%{"simplified" => false}, true), do: false
  defp field_visible?(_field, true), do: true

  defp field_title(%{"title" => t}) when is_binary(t) and t != "", do: t
  defp field_title(%{"name" => n}) when is_binary(n), do: humanize_name(n)
  defp field_title(_), do: ""

  defp humanize_name(name) do
    name
    |> String.replace(~r/[_\-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp leaf_input_id(name), do: "f-book-#{name}"

  defp field_wrapper_class(errors, name) when is_map(errors) do
    case Map.get(errors, name) do
      nil -> "bp-field-wrapper"
      [] -> "bp-field-wrapper"
      %{} = m when map_size(m) == 0 -> "bp-field-wrapper"
      _ -> "bp-field-wrapper has-error"
    end
  end

  defp field_wrapper_class(_, _), do: "bp-field-wrapper"

  defp field_errors(errors, name) when is_map(errors) do
    case Map.get(errors, name) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp field_errors(_, _), do: []

  # ── Render helpers ─────────────────────────────────────────────────────────

  defp tab_link_class(tab, active) when tab == active, do: "tab tab-active"
  defp tab_link_class(_, _), do: "tab"

  defp tab_title_for(atom), do: tab_title(atom)

  defp badge_status(true, _), do: "draft"
  defp badge_status(false, %{status: status}) when is_binary(status), do: status
  defp badge_status(_, _), do: "draft"

  defp status_label(true, _), do: "draft"
  defp status_label(false, %{status: status}) when is_binary(status), do: status
  defp status_label(_, _), do: "draft"
end
