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
