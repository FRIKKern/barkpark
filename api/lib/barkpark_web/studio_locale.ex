defmodule BarkparkWeb.StudioLocale do
  @moduledoc """
  The one seam between a workspace's `settings["locale"]` and the gettext
  locale the Studio chrome renders in (Gyldendal parity E7).

  Sanity's agency Studio runs `@sanity/locale-nb-no`; the twin's Barkpark
  Studio spoke English on every button, card and fallback. The workspace
  carries its locale as BCP-47 (`nb-NO`, the spelling Sanity's packages use);
  gettext wants the directory spelling (`nb_NO`). Nothing else in the tree
  should know both spellings.

  `put/1` is process-local (Gettext keeps the locale in the process
  dictionary), so the Studio calls it on every `handle_params` — the same
  place the workspace is resolved, and the place a mid-session scope switch
  re-runs — and the login page calls it from the request process. Schema
  titles/descriptions are never translated here: they are already the
  content owner's words.
  """

  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Tenancy

  @doc "BCP-47 (`nb-NO`) → gettext directory (`nb_NO`)."
  @spec gettext_locale(String.t()) :: String.t()
  def gettext_locale(locale) when is_binary(locale), do: String.replace(locale, "-", "_")
  def gettext_locale(_), do: gettext_locale(Tenancy.default_locale())

  @doc "The workspace's Studio locale in gettext spelling; `en` for nil/unknown."
  @spec resolve(Tenancy.Workspace.t() | nil) :: String.t()
  def resolve(workspace), do: gettext_locale(Tenancy.workspace_locale(workspace))

  @doc """
  The page language for `<html lang>`: the locale this process renders in, in
  BCP-47 spelling (`nb-NO`, `en`). The Studio puts the workspace locale before
  the layout renders, so a Norwegian Studio is no longer declared English to
  screen readers (task-c227351a938bcf9c); a surface that puts none stays `en`.
  """
  @spec html_lang() :: String.t()
  def html_lang do
    BarkparkWeb.Gettext |> Gettext.get_locale() |> String.replace("_", "-")
  end

  @doc """
  PortableDoc render opts in the locale this process renders in, so the
  renderer's own words (form Yes/No, task status, empty states) match the
  Studio or reader around them (task-8e96278fc4ee7097). A process that put no
  locale renders `en`, byte-identical to a render without `:locale`.
  """
  @spec pd_opts(map()) :: map()
  def pd_opts(opts \\ %{}) when is_map(opts),
    do: Map.put(opts, :locale, Gettext.get_locale(BarkparkWeb.Gettext))

  @doc "Put the workspace's locale on the current process for the render that follows."
  @spec put(Tenancy.Workspace.t() | nil) :: String.t()
  def put(workspace) do
    locale = resolve(workspace)
    Gettext.put_locale(BarkparkWeb.Gettext, locale)

    # The renderer's words follow this workspace too; hand it the locale we
    # already loaded so its render opts cost no second workspace query.
    with %Tenancy.Workspace{id: id} <- workspace,
         do:
           Barkpark.Content.Labels.remember_workspace_locale(
             id,
             Tenancy.workspace_locale(workspace)
           )

    locale
  end

  @doc """
  Put the locale of the workspace that OWNS a public document (the paper
  reader, the public sheet): its language is the page's language, so a screen
  reader speaks the text in the voice it was written in. Takes the workspace
  when the caller already loaded it, else looks it up by id; an unknown or
  missing workspace reads as the default locale.
  """
  @spec put_owner(Tenancy.Workspace.t() | term(), String.t() | nil) :: String.t()
  def put_owner(%Tenancy.Workspace{} = workspace, _workspace_id), do: put(workspace)
  def put_owner(_workspace, workspace_id), do: put(Tenancy.get_workspace_by_id(workspace_id))

  @doc "Put a locale by its BCP-47 name (used by the login page's return_to resolution)."
  @spec put_named(String.t() | nil) :: String.t()
  def put_named(locale) do
    locale = if locale in Tenancy.known_locales(), do: locale, else: Tenancy.default_locale()
    Gettext.put_locale(BarkparkWeb.Gettext, gettext_locale(locale))
    gettext_locale(locale)
  end

  @doc """
  The strings a web component renders itself (bp-media-picker, bp-reference-
  picker), in the CURRENT process locale, as the JSON the server stamps on the
  element as `data-strings`. The component keeps its English literal for every
  key that is absent, so an element without the attribute is byte-identical to
  today.
  """
  @spec component_strings(:media | :reference) :: String.t()
  def component_strings(:media) do
    Jason.encode!(%{
      "upload" => gettext("Upload file"),
      "browse" => gettext("Browse library"),
      "upload_button" => gettext("Upload"),
      "alt" => gettext("Alt text"),
      "alt_placeholder" => gettext("Describe the image for people who cannot see it"),
      "remove" => gettext("Remove image"),
      "empty" => gettext("No image selected — drop a file, or click to upload"),
      "replace" => gettext("Replace image"),
      "add" => gettext("Add image"),
      "add_short" => gettext("+ Add image"),
      "add_an_image" => gettext("Add an image"),
      "add_featured" => gettext("Add a featured image"),
      "drop_hint" => gettext("Drop a file, click to upload, or browse the library"),
      "focal" => gettext("Click the image to set its focal point"),
      "asset" => gettext("Asset"),
      "broken" => gettext("Image unavailable — drop a file, or click to replace"),
      "uploading" => gettext("Uploading…"),
      "options" => gettext("Right-click for image options"),
      "library" => gettext("Media library"),
      "search" => gettext("Search assets…"),
      "close" => gettext("Close"),
      "image_options" => gettext("Image options"),
      "search_assets" => gettext("Search assets"),
      "search_assets_placeholder" => gettext("Search assets…"),
      "no_matching_assets" => gettext("No matching assets"),
      "loading" => gettext("Loading…"),
      "library_error" => gettext("Could not load media library.")
    })
  end

  # The media library's words (bp-asset-explorer), keyed by their English: the
  # component looks each text up and falls back to the key. %{name} slots are
  # handed through verbatim and filled client-side, like :reference's
  # %{types}. Lowercase keys are the codes it shows as words: asset kinds,
  # processing states and visibility.
  def component_strings(:asset_explorer) do
    Jason.encode!(%{
      # The status facet's values (task-9b39b33f9b4e63c2); the processing and
      # visibility values below were already here, keyed by the raw value.
      "draft" => gettext("draft"),
      "published" => gettext("published"),
      "%{count} assets" => gettext("%{count} assets", count: "%{count}"),
      "%{count} assets match" => gettext("%{count} assets match", count: "%{count}"),
      "%{count} searches" => gettext("%{count} searches", count: "%{count}"),
      "%{loaded} in %{name}" =>
        gettext("%{loaded} in %{name}", loaded: "%{loaded}", name: "%{name}"),
      "%{what} copied" => gettext("%{what} copied", what: "%{what}"),
      "1 asset" => gettext("1 asset"),
      "1 asset matches" => gettext("1 asset matches"),
      "Add selected to folder" => gettext("Add selected to folder"),
      "Add to collection" => gettext("Add to collection"),
      "Add to collection…" => gettext("Add to collection…"),
      "Added to collection" => gettext("Added to collection"),
      "All" => gettext("All"),
      "All assets" => gettext("All assets"),
      "Asset checked out" => gettext("Asset checked out"),
      "Audio" => gettext("Audio"),
      "audio" => gettext("audio"),
      "Best match" => gettext("Best match"),
      "Cancel" => gettext("Cancel"),
      "Check out" => gettext("Check out"),
      "Checked out" => gettext("Checked out"),
      "Checked out by %{who}" => gettext("Checked out by %{who}", who: "%{who}"),
      # The fixed holder words Media.Storage.Actor.display/2 sends.
      "you" => gettext("you"),
      "another editor" => gettext("another editor"),
      "Checkout failed" => gettext("Checkout failed"),
      "Checkout released" => gettext("Checkout released"),
      "Clear all" => gettext("Clear all"),
      "Collection created" => gettext("Collection created"),
      "Collection name" => gettext("Collection name"),
      "Collection: %{value}" => gettext("Collection: %{value}", value: "%{value}"),
      "Collections" => gettext("Collections"),
      "Copy" => gettext("Copy"),
      "Copy link" => gettext("Copy link"),
      "Could not add to collection" => gettext("Could not add to collection"),
      "Could not create collection" => gettext("Could not create collection"),
      "Couldn't load your media library — the request failed." =>
        gettext("Couldn't load your media library — the request failed."),
      "Create folder" => gettext("Create folder"),
      "document" => gettext("document"),
      "Document" => gettext("Document"),
      "Documents" => gettext("Documents"),
      "Edit metadata" => gettext("Edit metadata"),
      "Enter a collection name" => gettext("Enter a collection name"),
      "failed" => gettext("failed"),
      "Filtered search" => gettext("Filtered search"),
      "Find assets…  (/ to focus)" => gettext("Find assets…  (/ to focus)"),
      "Folder" => gettext("Folder"),
      "Folder collections hold curated sets of assets." =>
        gettext("Folder collections hold curated sets of assets."),
      "Format" => gettext("Format"),
      "Generate link" => gettext("Generate link"),
      "Grid" => gettext("Grid"),
      "Grid view" => gettext("Grid view"),
      "image" => gettext("image"),
      "Images" => gettext("Images"),
      "Kind" => gettext("Kind"),
      "Kind: %{value}" => gettext("Kind: %{value}", value: "%{value}"),
      "Library" => gettext("Library"),
      "Link" => gettext("Link"),
      "List" => gettext("List"),
      "List view" => gettext("List view"),
      "Load more" => gettext("Load more"),
      "Load more · %{count} remaining" =>
        gettext("Load more · %{count} remaining", count: "%{count}"),
      "Loading assets…" => gettext("Loading assets…"),
      "Locked" => gettext("Locked"),
      "Name" => gettext("Name"),
      "New folder" => gettext("New folder"),
      "Newest first" => gettext("Newest first"),
      "No assets match" => gettext("No assets match"),
      "No assets match these filters — try removing one or search for something broader." =>
        gettext(
          "No assets match these filters — try removing one or search for something broader."
        ),
      "No assets yet — upload a file to get started." =>
        gettext("No assets yet — upload a file to get started."),
      "No folders yet — click + to create one." =>
        gettext("No folders yet — click + to create one."),
      "No matches before" => gettext("No matches before"),
      "Oldest first" => gettext("Oldest first"),
      "Open file" => gettext("Open file"),
      "Original" => gettext("Original"),
      "Other" => gettext("Other"),
      "other" => gettext("other"),
      "Popular" => gettext("Popular"),
      "Preview" => gettext("Preview"),
      "private" => gettext("private"),
      "Processing" => gettext("Processing"),
      "processing" => gettext("processing"),
      "public" => gettext("public"),
      "Public share link" => gettext("Public share link"),
      "ready" => gettext("ready"),
      "Recent" => gettext("Recent"),
      "Recently updated" => gettext("Recently updated"),
      "Refine" => gettext("Refine"),
      "Relations" => gettext("Relations"),
      "Release" => gettext("Release"),
      "Release failed" => gettext("Release failed"),
      "Remove failed" => gettext("Remove failed"),
      "Remove from collection" => gettext("Remove from collection"),
      "Removed from collection" => gettext("Removed from collection"),
      "Result view" => gettext("Result view"),
      "Retry" => gettext("Retry"),
      "Revoke" => gettext("Revoke"),
      "Revoke failed" => gettext("Revoke failed"),
      "Rotate link" => gettext("Rotate link"),
      "Search assets" => gettext("Search assets"),
      "Search: %{value}" => gettext("Search: %{value}", value: "%{value}"),
      "Select an asset or collection" => gettext("Select an asset or collection"),
      "Share link" => gettext("Share link"),
      "Share link created" => gettext("Share link created"),
      "Share link failed" => gettext("Share link failed"),
      "Share link revoked" => gettext("Share link revoked"),
      "Showing %{loaded} of %{total} assets" =>
        gettext("Showing %{loaded} of %{total} assets", loaded: "%{loaded}", total: "%{total}"),
      "Showing %{loaded} of %{total} in %{name}" =>
        gettext("Showing %{loaded} of %{total} in %{name}",
          loaded: "%{loaded}",
          name: "%{name}",
          total: "%{total}"
        ),
      "Size" => gettext("Size"),
      "Smart collection" => gettext("Smart collection"),
      "Sort results" => gettext("Sort results"),
      "Status" => gettext("Status"),
      "Tags" => gettext("Tags"),
      "This folder is empty — upload files or add assets from All assets." =>
        gettext("This folder is empty — upload files or add assets from All assets."),
      "Thumb" => gettext("Thumb"),
      "Thumbnail" => gettext("Thumbnail"),
      "Updated" => gettext("Updated"),
      "Upload" => gettext("Upload"),
      "Upload blocked — your session has ended. Sign in again." =>
        gettext("Upload blocked — your session has ended. Sign in again."),
      "Upload complete" => gettext("Upload complete"),
      "Upload failed (%{status})" => gettext("Upload failed (%{status})", status: "%{status}"),
      "Upload failed — check that the API is running" =>
        gettext("Upload failed — check that the API is running"),
      "Use Refine or clear filters to broaden" =>
        gettext("Use Refine or clear filters to broaden"),
      "Video" => gettext("Video"),
      "video" => gettext("video"),
      "Video preview" => gettext("Video preview"),
      "Visibility" => gettext("Visibility")
    })
  end

  # The paper editor hooks' words (bp-paper-editor-hooks.js, task-e8a5c972b7720591):
  # the save status, the save-conflict and related-Paper banners, history and
  # field-validity messages and the block menu. Keyed by the English text the
  # hooks fall back to; %{slots} are left for the hooks to fill.
  def component_strings(:paper_hooks) do
    Jason.encode!(%{
      "Auto-saved" => gettext("Auto-saved"),
      "Block actions" => gettext("Block actions"),
      "Copy or download this exact old-reference draft, then use Discard old draft. It will not be applied to the replacement." =>
        gettext(
          "Copy or download this exact old-reference draft, then use Discard old draft. It will not be applied to the replacement."
        ),
      "Could not save this block as a master." =>
        gettext("Could not save this block as a master."),
      "Delete block" => gettext("Delete block"),
      "description" => gettext("description"),
      "Discard old draft" => gettext("Discard old draft"),
      "Download old field draft" => gettext("Download old field draft"),
      "Download or copy this exact draft before explicitly discarding it." =>
        gettext("Download or copy this exact draft before explicitly discarding it."),
      "Enter a number greater than zero, or leave blank for automatic." =>
        gettext("Enter a number greater than zero, or leave blank for automatic."),
      "Enter a number." => gettext("Enter a number."),
      "Enter a positive whole number." => gettext("Enter a positive whole number."),
      "Enter a whole number." => gettext("Enter a whole number."),
      "Keep mine" => gettext("Keep mine"),
      "master" => gettext("master"),
      "Maximum must be at least the minimum." => gettext("Maximum must be at least the minimum."),
      "Move down" => gettext("Move down"),
      "Move up" => gettext("Move up"),
      "Nothing to show yet." => gettext("Nothing to show yet."),
      "Part of the document template" => gettext("Part of the document template"),
      "Redo was not confirmed. Try again." => gettext("Redo was not confirmed. Try again."),
      "Redoing…" => gettext("Redoing…"),
      "Related Paper changed" => gettext("Related Paper changed"),
      "Retained %{field} draft" => gettext("Retained %{field} draft", field: "%{field}"),
      "Review" => gettext("Review"),
      "Review retained draft" => gettext("Review retained draft"),
      "Save paused" => gettext("Save paused"),
      "Save paused after one hour of retries. Unsaved work remains here; copy it before reloading." =>
        gettext(
          "Save paused after one hour of retries. Unsaved work remains here; copy it before reloading."
        ),
      "Save paused — retry required." => gettext("Save paused — retry required."),
      "Save paused — review required." => gettext("Save paused — review required."),
      "Save paused: this browser cannot create a safe retry ID. Your edits are still here." =>
        gettext(
          "Save paused: this browser cannot create a safe retry ID. Your edits are still here."
        ),
      "Save paused: this nested editor lost its document position. Your edits are still here; copy them before reloading." =>
        gettext(
          "Save paused: this nested editor lost its document position. Your edits are still here; copy them before reloading."
        ),
      "Saved as master: %{title}" => gettext("Saved as master: %{title}", title: "%{title}"),
      "Saving…" => gettext("Saving…"),
      "Server revision %{revision}. Keep mine retries your edits on that revision; Use latest discards them." =>
        gettext(
          "Server revision %{revision}. Keep mine retries your edits on that revision; Use latest discards them.",
          revision: "%{revision}"
        ),
      "Server revision %{revision}. No exact retry payload is available. Use latest explicitly discards this retained draft." =>
        gettext(
          "Server revision %{revision}. No exact retry payload is available. Use latest explicitly discards this retained draft.",
          revision: "%{revision}"
        ),
      "Server revision %{revision}. Row positions may have changed. Keep mine is unavailable for positional collections; Use latest explicitly discards this draft." =>
        gettext(
          "Server revision %{revision}. Row positions may have changed. Keep mine is unavailable for positional collections; Use latest explicitly discards this draft.",
          revision: "%{revision}"
        ),
      "Step must be greater than zero." => gettext("Step must be greater than zero."),
      "Technical details" => gettext("Technical details"),
      "Text" => gettext("Text"),
      "This change is more than one hour old and can no longer be restored." =>
        gettext("This change is more than one hour old and can no longer be restored."),
      "This change no longer matches the current document." =>
        gettext("This change no longer matches the current document."),
      "This document changed elsewhere. Your edits are still here." =>
        gettext("This document changed elsewhere. Your edits are still here."),
      "This draft has a pending or attempted save for the old reference. Copy or download it; retry and discard are unavailable here." =>
        gettext(
          "This draft has a pending or attempted save for the old reference. Copy or download it; retry and discard are unavailable here."
        ),
      "This history step could not be validated." =>
        gettext("This history step could not be validated."),
      "This history step is no longer available for this document." =>
        gettext("This history step is no longer available for this document."),
      "This history step is unavailable." => gettext("This history step is unavailable."),
      "This history step was already used. Make a new edit to continue." =>
        gettext("This history step was already used. Make a new edit to continue."),
      "This related Paper was replaced before your %{field} draft was sent." =>
        gettext("This related Paper was replaced before your %{field} draft was sent.",
          field: "%{field}"
        ),
      "This related Paper was replaced before your %{field} draft was sent. The draft was not applied to the replacement." =>
        gettext(
          "This related Paper was replaced before your %{field} draft was sent. The draft was not applied to the replacement.",
          field: "%{field}"
        ),
      "This related Paper was replaced while your %{field} save was unresolved." =>
        gettext("This related Paper was replaced while your %{field} save was unresolved.",
          field: "%{field}"
        ),
      "This related Paper was replaced while your %{field} save was unresolved. Download the retained draft while its result is confirmed." =>
        gettext(
          "This related Paper was replaced while your %{field} save was unresolved. Download the retained draft while its result is confirmed.",
          field: "%{field}"
        ),
      "This retained draft has no safe exact rebase path." =>
        gettext("This retained draft has no safe exact rebase path."),
      "This save has an unresolved server outcome and cannot be discarded here." =>
        gettext("This save has an unresolved server outcome and cannot be discarded here."),
      "This save may already have reached the server. It cannot be discarded safely here." =>
        gettext(
          "This save may already have reached the server. It cannot be discarded safely here."
        ),
      "title" => gettext("title"),
      "Undo was not confirmed. Try again." => gettext("Undo was not confirmed. Try again."),
      "Undoing…" => gettext("Undoing…"),
      "unknown" => gettext("unknown"),
      "Unsaved changes — fix invalid fields." => gettext("Unsaved changes — fix invalid fields."),
      "Unsaved draft payload" => gettext("Unsaved draft payload"),
      "Use latest" => gettext("Use latest"),
      "Value must be at least %{min}." =>
        gettext("Value must be at least %{min}.", min: "%{min}"),
      "Value must be at most %{max}." => gettext("Value must be at most %{max}.", max: "%{max}"),
      "✓ Auto-saved" => gettext("✓ Auto-saved")
    })
  end

  # The paper canvas (api/assets/paper-editor) reads this map, keyed by the
  # ENGLISH text, through its one `t()` helper (src/i18n.js), stamped on each
  # canvas run's host (task-addade22d350314a). `%{name}` slots are filled
  # client-side, so they pass through verbatim here.
  def component_strings(:paper_canvas) do
    Jason.encode!(%{
      "+ footer" => gettext("+ footer"),
      "2-track grid · 2 cards" => gettext("2-track grid · 2 cards"),
      "7 blocks · kicker → TOC" => gettext("7 blocks · kicker → TOC"),
      "a quoted passage" => gettext("a quoted passage"),
      "Action" => gettext("Action"),
      "Edit empty ingress" => gettext("Edit empty ingress"),
      "Edit empty paragraph" => gettext("Edit empty paragraph"),
      "Select hidden divider" => gettext("Select hidden divider"),
      "action href" => gettext("action href"),
      "action label" => gettext("action label"),
      "Action label" => gettext("Action label"),
      "%{label} (first of %{count} hidden blocks)" =>
        gettext("%{label} (first of %{count} hidden blocks)",
          label: "%{label}",
          count: "%{count}"
        ),
      "Add a block below" => gettext("Add a block below"),
      "Add a block below (click)" => gettext("Add a block below (click)"),
      "Add a kicker…" => gettext("Add a kicker…"),
      "Add an image" => gettext("Add an image"),
      "Add names, separated by · …" => gettext("Add names, separated by · …"),
      "Add option" => gettext("Add option"),
      "Align centre" => gettext("Align centre"),
      "Align left" => gettext("Align left"),
      "Align right" => gettext("Align right"),
      "Annotated figure" => gettext("Annotated figure"),
      "Array of" => gettext("Array of"),
      "Article chrome" => gettext("Article chrome"),
      "author / credit line" => gettext("author / credit line"),
      "Basic fields" => gettext("Basic fields"),
      "Block" => gettext("Block"),
      "Block options" => gettext("Block options"),
      "Bold" => gettext("Bold"),
      "Boolean" => gettext("Boolean"),
      "Bullet list" => gettext("Bullet list"),
      "Bulleted list" => gettext("Bulleted list"),
      "bulleted or ordered" => gettext("bulleted or ordered"),
      "Button" => gettext("Button"),
      "Button label" => gettext("Button label"),
      "Byline" => gettext("Byline"),
      "call-to-action button" => gettext("call-to-action button"),
      "Callout" => gettext("Callout"),
      "Callout title" => gettext("Callout title"),
      "caption" => gettext("caption"),
      "Caption" => gettext("Caption"),
      "captioned block" => gettext("captioned block"),
      "Card" => gettext("Card"),
      "Card action label" => gettext("Card action label"),
      "Card title" => gettext("Card title"),
      "Change image" => gettext("Change image"),
      "chart · regions, refline, callout" => gettext("chart · regions, refline, callout"),
      "Checklist" => gettext("Checklist"),
      "Clear formatting" => gettext("Clear formatting"),
      "Click, or press Enter, to choose from the media library" =>
        gettext("Click, or press Enter, to choose from the media library"),
      "Code" => gettext("Code"),
      "code language" => gettext("code language"),
      "Code list" => gettext("Code list"),
      "collapsible details" => gettext("collapsible details"),
      "Color" => gettext("Color"),
      "Columns" => gettext("Columns"),
      "Command palette filter" => gettext("Command palette filter"),
      "Composite" => gettext("Composite"),
      "Configure table" => gettext("Configure table"),
      "console frame" => gettext("console frame"),
      "Contents" => gettext("Contents"),
      "contents — no entries yet" => gettext("contents — no entries yet"),
      "Date & time" => gettext("Date & time"),
      "Delete" => gettext("Delete"),
      "Diagram" => gettext("Diagram"),
      "diagram caption" => gettext("diagram caption"),
      "Diagram caption" => gettext("Diagram caption"),
      "dismiss" => gettext("dismiss"),
      "Display (own line)" => gettext("Display (own line)"),
      "Divider" => gettext("Divider"),
      "Drag to move · click for options" => gettext("Drag to move · click for options"),
      "Drag to resize the column" => gettext("Drag to resize the column"),
      "Duplicate" => gettext("Duplicate"),
      "Edit" => gettext("Edit"),
      "Edit action label" => gettext("Edit action label"),
      "Edit diagram" => gettext("Edit diagram"),
      "Edit number" => gettext("Edit number"),
      "Edit options" => gettext("Edit options"),
      "embed a spreadsheet" => gettext("embed a spreadsheet"),
      "Emoji" => gettext("Emoji"),
      "Entries (indent two spaces per level; `text | anchor`)" =>
        gettext("Entries (indent two spaces per level; `text | anchor`)"),
      "Equation" => gettext("Equation"),
      "equation — no tex source" => gettext("equation — no tex source"),
      "EXPECTED" => gettext("EXPECTED"),
      "expected" => gettext("expected"),
      "Eyebrow" => gettext("Eyebrow"),
      "Field label" => gettext("Field label"),
      "Figure" => gettext("Figure"),
      "figure caption" => gettext("figure caption"),
      "File" => gettext("File"),
      "filter (e.g. proj:x)" => gettext("filter (e.g. proj:x)"),
      "footer" => gettext("footer"),
      "Footnotes" => gettext("Footnotes"),
      "footnotes — none yet" => gettext("footnotes — none yet"),
      "Format" => gettext("Format"),
      "Format %{mark}" => gettext("Format %{mark}", mark: "%{mark}"),
      "grid" => gettext("grid"),
      "Grid of cards" => gettext("Grid of cards"),
      "h1 — section title" => gettext("h1 — section title"),
      "Heading" => gettext("Heading"),
      "Heading %{level}" => gettext("Heading %{level}", level: "%{level}"),
      "Heading 1" => gettext("Heading 1"),
      "Heading 2" => gettext("Heading 2"),
      "Heading 3" => gettext("Heading 3"),
      "Heading 4" => gettext("Heading 4"),
      "Heading 5" => gettext("Heading 5"),
      "Heading 6" => gettext("Heading 6"),
      "hex swatch value" => gettext("hex swatch value"),
      "Highlight" => gettext("Highlight"),
      "highlighted quote" => gettext("highlighted quote"),
      "horizontal rule" => gettext("horizontal rule"),
      "Image" => gettext("Image"),
      "Image field" => gettext("Image field"),
      "Ingress" => gettext("Ingress"),
      "Inline code" => gettext("Inline code"),
      "insert" => gettext("insert"),
      "Insert" => gettext("Insert"),
      "Insert %{block}" => gettext("Insert %{block}", block: "%{block}"),
      "Insert block" => gettext("Insert block"),
      "insert link" => gettext("insert link"),
      "Italic" => gettext("Italic"),
      "kicker over the title" => gettext("kicker over the title"),
      "label" => gettext("label"),
      "labelled annotation" => gettext("labelled annotation"),
      "labelled panels" => gettext("labelled panels"),
      "lang" => gettext("lang"),
      "Language" => gettext("Language"),
      "language" => gettext("language"),
      "lead paragraph" => gettext("lead paragraph"),
      "Legend" => gettext("Legend"),
      "legend" => gettext("legend"),
      "level 2 heading" => gettext("level 2 heading"),
      "level 3 heading" => gettext("level 3 heading"),
      "level 4 heading" => gettext("level 4 heading"),
      "level 5 heading" => gettext("level 5 heading"),
      "level 6 heading" => gettext("level 6 heading"),
      "Link" => gettext("Link"),
      "link another document" => gettext("link another document"),
      "Link preview" => gettext("Link preview"),
      "Link to page" => gettext("Link to page"),
      "Link URL" => gettext("Link URL"),
      "List" => gettext("List"),
      "live" => gettext("live"),
      "Live dashboard section" => gettext("Live dashboard section"),
      "Localized text" => gettext("Localized text"),
      "Long text" => gettext("Long text"),
      "Loop" => gettext("Loop"),
      "Markdown source" => gettext("Markdown source"),
      "Markdown source is unavailable inside a Figure because it could create extra blocks." =>
        gettext(
          "Markdown source is unavailable inside a Figure because it could create extra blocks."
        ),
      "Masters" => gettext("Masters"),
      "Masthead" => gettext("Masthead"),
      "Maximum" => gettext("Maximum"),
      "Media & reference" => gettext("Media & reference"),
      "Mermaid diagram" => gettext("Mermaid diagram"),
      "Mermaid source" => gettext("Mermaid source"),
      "Minimum" => gettext("Minimum"),
      "monospace block" => gettext("monospace block"),
      "Move down" => gettext("Move down"),
      "Move up" => gettext("Move up"),
      "multi-column layout" => gettext("multi-column layout"),
      "multi-language string" => gettext("multi-language string"),
      "multi-line value" => gettext("multi-line value"),
      "navigate" => gettext("navigate"),
      "No blocks match" => gettext("No blocks match"),
      "No commands match" => gettext("No commands match"),
      "No image yet — paste or drop a picture, or enter a URL below" =>
        gettext("No image yet — paste or drop a picture, or enter a URL below"),
      "No matching pages" => gettext("No matching pages"),
      "No video yet — paste a video url below" =>
        gettext("No video yet — paste a video url below"),
      "Note" => gettext("Note"),
      "Notes, one per line" => gettext("Notes, one per line"),
      "Numbered" => gettext("Numbered"),
      "Numbered list" => gettext("Numbered list"),
      "numbered notes" => gettext("numbered notes"),
      "numbered steps with bodies" => gettext("numbered steps with bodies"),
      "object of subfields" => gettext("object of subfields"),
      "One footnote per line" => gettext("One footnote per line"),
      "Open" => gettext("Open"),
      "Option %{n} label" => gettext("Option %{n} label"),
      "Option %{n} value" => gettext("Option %{n} value"),
      "Ordered list" => gettext("Ordered list"),
      "outline of entries" => gettext("outline of entries"),
      "page title size" => gettext("page title size"),
      "Paragraph" => gettext("Paragraph"),
      "Number" => gettext("Number"),
      "numeric value" => gettext("numeric value"),
      "Paper text" => gettext("Paper text"),
      "Part of the document template" => gettext("Part of the document template"),
      "Paste link, ↵ to apply" => gettext("Paste link, ↵ to apply"),
      "pick one option" => gettext("pick one option"),
      "picture from a url" => gettext("picture from a url"),
      "pipeline stage node" => gettext("pipeline stage node"),
      "plain body text" => gettext("plain body text"),
      "Poster url" => gettext("Poster url"),
      "poster url (optional)" => gettext("poster url (optional)"),
      "Presets" => gettext("Presets"),
      "Primary" => gettext("Primary"),
      "Pullquote" => gettext("Pullquote"),
      "Quote" => gettext("Quote"),
      "Reference" => gettext("Reference"),
      "registry-backed enum" => gettext("registry-backed enum"),
      "Remove" => gettext("Remove"),
      "Remove option %{n}" => gettext("Remove option %{n}"),
      "repeating list" => gettext("repeating list"),
      "rows and columns" => gettext("rows and columns"),
      "ruled group" => gettext("ruled group"),
      "run" => gettext("run"),
      "Run command" => gettext("Run command"),
      "Runbook step" => gettext("Runbook step"),
      "Save as master" => gettext("Save as master"),
      "Searching…" => gettext("Searching…"),
      "Secondary" => gettext("Secondary"),
      "Section" => gettext("Section"),
      "Select" => gettext("Select"),
      "Sheet" => gettext("Sheet"),
      "single-line value" => gettext("single-line value"),
      "Slug" => gettext("Slug"),
      "source" => gettext("source"),
      "stack" => gettext("stack"),
      "Stage" => gettext("Stage"),
      "Start typing, or press / for blocks…" => gettext("Start typing, or press / for blocks…"),
      "Starters" => gettext("Starters"),
      "stat queries · chart · task board" => gettext("stat queries · chart · task board"),
      "Step" => gettext("Step"),
      "Steps" => gettext("Steps"),
      "steps · terminal · rollback callout" => gettext("steps · terminal · rollback callout"),
      "Strikethrough" => gettext("Strikethrough"),
      "String" => gettext("String"),
      "Structured" => gettext("Structured"),
      "Subscript (Ctrl+,)" => gettext("Subscript (Ctrl+,)"),
      "Summary" => gettext("Summary"),
      "Superscript (Ctrl+.)" => gettext("Superscript (Ctrl+.)"),
      "Table" => gettext("Table"),
      "Table columns" => gettext("Table columns"),
      "Table rows" => gettext("Table rows"),
      "Tabs" => gettext("Tabs"),
      "Task list" => gettext("Task list"),
      "task list query filter" => gettext("task list query filter"),
      "Task list title" => gettext("Task list title"),
      "task list title" => gettext("task list title"),
      "Terminal" => gettext("Terminal"),
      "TeX" => gettext("TeX"),
      "TeX math" => gettext("TeX math"),
      "Text" => gettext("Text"),
      "timestamp value" => gettext("timestamp value"),
      "title" => gettext("title"),
      "Title" => gettext("Title"),
      "titled content tile" => gettext("titled content tile"),
      "to-do items" => gettext("to-do items"),
      "Toggle" => gettext("Toggle"),
      "Toggle Markdown source" => gettext("Toggle Markdown source"),
      "toggle summary" => gettext("toggle summary"),
      "true / false toggle" => gettext("true / false toggle"),
      "Turn into" => gettext("Turn into"),
      "Turn into %{block}" => gettext("Turn into %{block}", block: "%{block}"),
      "Type a command…" => gettext("Type a command…"),
      "Underline" => gettext("Underline"),
      "Unit" => gettext("Unit"),
      "upload or url" => gettext("upload or url"),
      "Uploading…" => gettext("Uploading…"),
      "url-safe key" => gettext("url-safe key"),
      "value" => gettext("value"),
      "Video" => gettext("Video"),
      "video from a url" => gettext("video from a url"),
      "Video url" => gettext("Video url"),
      "video url" => gettext("video url"),
      "View" => gettext("View"),
      "Visual" => gettext("Visual"),
      "warn or info card" => gettext("warn or info card"),
      "Wikilink" => gettext("Wikilink"),
      "Write the highlighted quote…" => gettext("Write the highlighted quote…"),
      "Write the introduction…" => gettext("Write the introduction…"),
      "Write the quote…" => gettext("Write the quote…")
    })
  end

  # The Studio graph pane (bp-graph.js), keyed by the English it falls back to.
  def component_strings(:graph) do
    Jason.encode!(%{
      "Document blast-radius graph. Press Tab to enter, arrow keys to traverse." =>
        gettext("Document blast-radius graph. Press Tab to enter, arrow keys to traverse."),
      "Document graph" => gettext("Document graph"),
      "Couldn't load graph data" => gettext("Couldn't load graph data"),
      "No connections yet" => gettext("No connections yet"),
      "Zoom in" => gettext("Zoom in"),
      "Zoom out" => gettext("Zoom out"),
      "Fit to view" => gettext("Fit to view"),
      "Reset view" => gettext("Reset view"),
      "Types" => gettext("Types"),
      "Legend" => gettext("Legend"),
      "Full color" => gettext("Full color"),
      "Flow" => gettext("Flow"),
      "Search…" => gettext("Search…"),
      "Search the graph" => gettext("Search the graph"),
      "1 connection" => pgettext("graph", "1 connection"),
      "%{count} connections" => pgettext("graph", "%{count} connections", count: "%{count}"),
      "Broken reference: %{id} via %{via}" =>
        gettext("Broken reference: %{id} via %{via}", id: "%{id}", via: "%{via}"),
      "Broken reference: %{id}" => gettext("Broken reference: %{id}", id: "%{id}"),
      "Status: %{status}" => gettext("Status: %{status}", status: "%{status}"),
      "document" => gettext("document"),
      "active" => gettext("active"),
      "broken ref" => gettext("broken ref"),
      "broken reference" => gettext("broken reference"),
      "via %{via}" => gettext("via %{via}", via: "%{via}"),
      "Focused: %{title}. Connected to: %{names}." =>
        gettext("Focused: %{title}. Connected to: %{names}.",
          title: "%{title}",
          names: "%{names}"
        )
    })
  end

  # bp-rich-text-editor's toolbar, keyed by the English.
  def component_strings(:rich_text) do
    Jason.encode!(%{
      "Bold (mod+B)" => gettext("Bold (mod+B)"),
      "Italic (mod+I)" => gettext("Italic (mod+I)"),
      "Link" => gettext("Link"),
      "Set" => gettext("Set"),
      "Remove" => gettext("Remove")
    })
  end

  # bp-document-preview, keyed by the English.
  def component_strings(:document_preview) do
    Jason.encode!(%{
      "No document selected" => gettext("No document selected"),
      "Could not parse document JSON" => gettext("Could not parse document JSON"),
      "Untitled" => gettext("Untitled"),
      "Title" => gettext("Title"),
      "Type" => gettext("Type"),
      "Document ID" => gettext("Document ID"),
      "Contributors" => gettext("Contributors"),
      "Identifiers" => gettext("Identifiers"),
      "Blurb" => gettext("Blurb"),
      "Full content (JSON)" => gettext("Full content (JSON)")
    })
  end

  def component_strings(:reference) do
    Jason.encode!(%{
      "change" => gettext("Change"),
      "cancel" => gettext("Cancel"),
      "remove" => gettext("Remove"),
      "no_matches" => gettext("No matches"),
      "draft" => gettext("draft"),
      # The picker fills %{types} client-side (the joined ref-type set), so the
      # placeholder is handed through verbatim instead of bound here.
      "search" => gettext("Search %{types}…", types: "%{types}"),
      "documents" => gettext("documents"),
      # A context of its own: "1 result" is also a plural msgid elsewhere,
      # and the picker needs both forms with the slot left in.
      "one_result" => pgettext("reference picker", "1 result"),
      "n_results" => pgettext("reference picker", "%{count} results", count: "%{count}"),
      "recent" => gettext("Recent"),
      "popular" => gettext("Popular"),
      "no_matches_before" => gettext("No matches before"),
      "one_search" => pgettext("reference picker", "1 search"),
      "n_searches" => gettext("%{count} searches", count: "%{count}"),
      "one_doc" => pgettext("reference picker", "1 doc"),
      "n_docs" => gettext("%{count} docs", count: "%{count}")
    })
  end

  @doc """
  A validation finding in the CURRENT process locale (Gyldendal parity E7
  follow-up, friction #87). `Barkpark.Content.Validation` is kernel code with
  no Gettext, so its messages are stable English keys; the Studio translates
  them at the assign, once, before any render site sees them. A schema's own
  `"message"` (already the editor's language) and anything unrecognised pass
  through verbatim. The flat envelope's `"/path: msg"` form keeps its pointer.
  """
  @spec validation_message(String.t()) :: String.t()
  def validation_message("Required"), do: gettext("Required")

  def validation_message("Does not match required format"),
    do: gettext("Does not match required format")

  def validation_message(msg) when is_binary(msg) do
    cond do
      m = Regex.run(~r/^Must be at least (\d+) characters$/, msg) ->
        gettext("Must be at least %{min} characters", min: Enum.at(m, 1))

      m = Regex.run(~r/^Must be at most (\d+) characters$/, msg) ->
        gettext("Must be at most %{max} characters", max: Enum.at(m, 1))

      m = Regex.run(~r/^Must be at least (-?[\d.]+)$/, msg) ->
        gettext("Must be at least %{min}", min: Enum.at(m, 1))

      m = Regex.run(~r/^Must be at most (-?[\d.]+)$/, msg) ->
        gettext("Must be at most %{max}", max: Enum.at(m, 1))

      m = Regex.run(~r/^(\/[^:]*): (.+)$/s, msg) ->
        Enum.at(m, 1) <> ": " <> validation_message(Enum.at(m, 2))

      true ->
        msg
    end
  end

  def validation_message(other), do: other

  @doc """
  `validation_message/1` over a whole findings tree as `Validation.check_tree/3`
  returns it: field → list, or field → `%{__self__: list, "sub" => …, 1 => …}`.
  Shape-preserving; an empty map stays an empty map.
  """
  @spec localize_findings(map() | list()) :: map() | list()
  def localize_findings(list) when is_list(list), do: Enum.map(list, &validation_message/1)

  def localize_findings(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, localize_findings(v)} end)

  def localize_findings(other), do: other
end
