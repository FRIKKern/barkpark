defmodule BarkparkWeb.Studio.PluginSchemaCopy do
  @moduledoc """
  The content plugins' schema chrome, in the viewer's Studio language.

  Quiz, Forms, the paper forms and Media register their document types
  (`Barkpark.Quiz.Content.schema/0`, `Barkpark.Plugins.Forms`, Bulldocs'
  `form_response.json`, Media's `media_asset.json` and
  `media_collection.json`), and those
  schemas stay English: they are data, stored per dataset and read by more than
  Studio. Studio owns the translation instead, as `ConnectorsCopy` does for the
  connector catalog (ruling on task-0ded99e28e620ba5, pattern (a)). Each
  English title is marked here for extraction, and `localize/1` translates a
  plugin schema's own titles and descriptions when Studio opens it.

  Only an exact marked string is translated, so a title an operator changed
  stays as they wrote it, and a string with no marker renders in English in
  every language. `markers/0` lets a test catch drift between the plugin
  schemas and this list. Tasks is an operator surface and stays English.
  """
  use Gettext, backend: BarkparkWeb.Gettext

  # The document types whose schemas a content plugin registers.
  @schemas ~w(quiz form_submission form_endpoint form_response mediaAsset mediaCollection)

  @markers [
    # Quiz (Barkpark.Quiz.Content.schema/0)
    gettext_noop("Quiz"),
    gettext_noop("Title"),
    gettext_noop("Question prompt"),
    gettext_noop("Question image"),
    gettext_noop("Time limit (seconds)"),
    gettext_noop("Choices"),
    gettext_noop("Id"),
    gettext_noop("Label"),
    gettext_noop("Correct?"),
    # Forms (Barkpark.Plugins.Forms submission and endpoint schemas)
    gettext_noop("Form submissions"),
    gettext_noop("Site"),
    gettext_noop("State"),
    gettext_noop("Spam"),
    gettext_noop("Received at"),
    gettext_noop("Fields"),
    gettext_noop("Source"),
    gettext_noop("Endpoint"),
    gettext_noop("Form endpoints"),
    gettext_noop("Accepting submissions"),
    gettext_noop("Allowed origins"),
    gettext_noop("Field names"),
    # Bulldocs paper forms (priv/plugins/bulldocs/schemas/form_response.json)
    gettext_noop("Form responses"),
    gettext_noop("Paper"),
    gettext_noop("Submitted at"),
    gettext_noop("Answers"),
    # Media (priv/plugins/media/schemas/media_asset.json): title, group tabs,
    # fields and desk groups
    gettext_noop("Media Asset"),
    gettext_noop("Metadata"),
    gettext_noop("File"),
    gettext_noop("Rights"),
    gettext_noop("Media file ID"),
    gettext_noop("File info"),
    gettext_noop("URL"),
    gettext_noop("Path"),
    gettext_noop("MIME type"),
    gettext_noop("Size (bytes)"),
    gettext_noop("Original filename"),
    gettext_noop("Width"),
    gettext_noop("Height"),
    gettext_noop("Asset kind"),
    gettext_noop("Processing status"),
    gettext_noop("CDN status"),
    gettext_noop("External processing"),
    gettext_noop("Provider"),
    gettext_noop("Job ID"),
    gettext_noop("Last callback"),
    gettext_noop("Delivery visibility"),
    gettext_noop("Checked out by"),
    gettext_noop("Checked out at"),
    gettext_noop("Alt text"),
    gettext_noop("Caption"),
    gettext_noop("Description"),
    gettext_noop("Primary collection"),
    gettext_noop("Collections"),
    gettext_noop("Tags"),
    gettext_noop("Role"),
    gettext_noop("Focal point"),
    gettext_noop("X"),
    gettext_noop("Y"),
    gettext_noop("Related assets"),
    gettext_noop("Relation"),
    gettext_noop("Target asset"),
    gettext_noop("Copyright holder"),
    gettext_noop("License"),
    gettext_noop("Usage notes"),
    gettext_noop("Watermark profile"),
    gettext_noop("Images"),
    gettext_noop("Video"),
    gettext_noop("Audio"),
    gettext_noop("Documents"),
    gettext_noop("All"),
    # Media (priv/plugins/media/schemas/media_collection.json)
    gettext_noop("Media Collection"),
    gettext_noop("Core"),
    gettext_noop("Sharing"),
    gettext_noop("Slug"),
    gettext_noop("Collection kind"),
    gettext_noop("Virtual filter"),
    gettext_noop("Tags (comma-separated)"),
    gettext_noop("Search text"),
    gettext_noop("MIME prefix"),
    gettext_noop("Visibility"),
    gettext_noop("Parent collection"),
    gettext_noop("Cover asset"),
    gettext_noop("Sort order"),
    gettext_noop("Share link"),
    gettext_noop("Enabled"),
    gettext_noop("Token"),
    gettext_noop("Expires at")
  ]

  @doc "The document types whose schema chrome this module translates."
  @spec schemas() :: [String.t()]
  def schemas, do: @schemas

  @doc "Every schema string this module has a translation marker for."
  @spec markers() :: [String.t()]
  def markers, do: @markers

  @doc """
  A content plugin's schema with its title and every field title and
  description in the viewer's Studio language. Any other schema, and nil, is
  returned unchanged.
  """
  def localize(%{name: name, fields: fields} = schema) when name in @schemas do
    %{schema | fields: Enum.map(fields || [], &field/1)}
    |> Map.update(:title, nil, &translate/1)
    |> titled_list(:groups)
    |> titled_list(:desk_groups)
  end

  def localize(schema), do: schema

  defp field(%{} = f) do
    f
    |> update_string("title")
    |> update_string("description")
    |> update_nested("fields")
    |> update_nested("of")
  end

  defp field(other), do: other

  # The group tabs (`groups`) and the desk list's filters (`desk_groups`): each
  # entry's "title" is chrome; its "name" and filter are data and stay.
  defp titled_list(schema, key) do
    case Map.get(schema, key) do
      list when is_list(list) -> Map.put(schema, key, Enum.map(list, &update_string(&1, "title")))
      _ -> schema
    end
  end

  defp update_string(f, key) do
    case Map.get(f, key) do
      text when is_binary(text) -> Map.put(f, key, translate(text))
      _ -> f
    end
  end

  # `fields` is a list of fields; `of` is one member shape (a composite with its
  # own `fields`) or a list of them.
  defp update_nested(f, key) do
    case Map.get(f, key) do
      list when is_list(list) -> Map.put(f, key, Enum.map(list, &field/1))
      %{} = one -> Map.put(f, key, field(one))
      _ -> f
    end
  end

  defp translate(text) when text in @markers, do: Gettext.gettext(BarkparkWeb.Gettext, text)
  defp translate(text), do: text
end
