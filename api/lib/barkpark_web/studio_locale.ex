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

  @doc "Put the workspace's locale on the current process for the render that follows."
  @spec put(Tenancy.Workspace.t() | nil) :: String.t()
  def put(workspace) do
    locale = resolve(workspace)
    Gettext.put_locale(BarkparkWeb.Gettext, locale)
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
      "broken" => gettext("Image unavailable — drop a file, or click to replace"),
      "uploading" => gettext("Uploading…"),
      "options" => gettext("Right-click for image options"),
      "library" => gettext("Media library"),
      "search" => gettext("Search assets…"),
      "close" => gettext("Close")
    })
  end

  # The media library's words (bp-asset-explorer), keyed by their English: the
  # component looks each text up and falls back to the key. %{name} slots are
  # handed through verbatim and filled client-side, like :reference's
  # %{types}. Lowercase keys are the codes it shows as words: asset kinds,
  # processing states and visibility.
  def component_strings(:asset_explorer) do
    Jason.encode!(%{
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
      "documents" => gettext("documents")
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
