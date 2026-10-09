defmodule BarkparkWeb.Studio.PluginSchemaCopy do
  @moduledoc """
  The content plugins' schema chrome, in the viewer's Studio language.

  Quiz, Forms and the paper forms register their document types from core
  (`Barkpark.Quiz.Content.schema/0`, `Barkpark.Plugins.Forms`, Bulldocs'
  `form_response.json`), and those
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
  @schemas ~w(quiz form_submission form_endpoint form_response)

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
    gettext_noop("Answers")
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
