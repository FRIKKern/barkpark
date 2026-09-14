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

  @doc "Put the workspace's locale on the current process for the render that follows."
  @spec put(Tenancy.Workspace.t() | nil) :: String.t()
  def put(workspace) do
    locale = resolve(workspace)
    Gettext.put_locale(BarkparkWeb.Gettext, locale)
    locale
  end

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
      "uploading" => gettext("Uploading…"),
      "options" => gettext("Right-click for image options"),
      "library" => gettext("Media library"),
      "search" => gettext("Search assets…"),
      "close" => gettext("Close")
    })
  end

  def component_strings(:reference) do
    Jason.encode!(%{
      "change" => gettext("Change"),
      "remove" => gettext("Remove"),
      "no_matches" => gettext("No matches"),
      "draft" => gettext("draft"),
      # The picker fills %{types} client-side (the joined ref-type set), so the
      # placeholder is handed through verbatim instead of bound here.
      "search" => gettext("Search %{types}…", types: "%{types}"),
      "documents" => gettext("documents")
    })
  end
end
