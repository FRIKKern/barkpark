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
  schemas and this list.

  The Tasks schema (task-228e90e341223f82) translates its title, group titles
  and top-level field titles, and shows its lifecycle and disposition values by
  a word: the stored value stays the English token, only the label changes.
  Its long field descriptions are operator documentation and stay English.
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

  def localize(%{name: "task", fields: fields} = schema) do
    schema
    |> Map.update(:title, nil, &task_word/1)
    |> Map.update(:groups, [], fn groups -> Enum.map(groups || [], &task_group/1) end)
    |> Map.put(:fields, Enum.map(fields || [], &task_field/1))
  end

  def localize(schema), do: schema

  # ── Tasks ──────────────────────────────────────────────────────────────────

  @task_markers [
    pgettext_noop("Task", "task schema"),
    pgettext_noop("Brief", "task schema"),
    pgettext_noop("Work", "task schema"),
    pgettext_noop("Close", "task schema"),
    pgettext_noop("System", "task schema"),
    pgettext_noop("Title", "task schema"),
    pgettext_noop("Portable brief", "task schema"),
    pgettext_noop("Description", "task schema"),
    pgettext_noop("Purpose", "task schema"),
    pgettext_noop("Design notes", "task schema"),
    pgettext_noop("Design paper", "task schema"),
    pgettext_noop("Acceptance criteria", "task schema"),
    pgettext_noop("Estimate", "task schema"),
    pgettext_noop("Execution policy", "task schema"),
    pgettext_noop("Execution gate", "task schema"),
    pgettext_noop("Due", "task schema"),
    pgettext_noop("Priority", "task schema"),
    pgettext_noop("Labels", "task schema"),
    pgettext_noop("Tags", "task schema"),
    pgettext_noop("Parent task", "task schema"),
    pgettext_noop("Lifecycle", "task schema"),
    pgettext_noop("Assignee", "task schema"),
    pgettext_noop("Disposition", "task schema"),
    pgettext_noop("Disposition reason", "task schema"),
    pgettext_noop("Reopen trigger", "task schema"),
    pgettext_noop("Disposition rerun", "task schema"),
    pgettext_noop("Disposition owner", "task schema"),
    pgettext_noop("Worklog", "task schema"),
    pgettext_noop("Blocked on", "task schema"),
    pgettext_noop("Attachments", "task schema"),
    pgettext_noop("Sessions", "task schema"),
    pgettext_noop("Outcome", "task schema"),
    pgettext_noop("Close reason", "task schema"),
    pgettext_noop("Retro", "task schema"),
    pgettext_noop("Kind", "task schema"),
    pgettext_noop("Claim (engine)", "task schema"),
    pgettext_noop("Dependencies", "task schema"),
    pgettext_noop("Linked papers", "task schema"),
    pgettext_noop("History (engine)", "task schema"),
    pgettext_noop("History summary (engine)", "task schema")
  ]

  # The select fields whose stored tokens are shown by a word. The token stays
  # what is stored and sent; only the label is translated.
  @task_option_fields ~w(lifecycle_status disposition)

  @task_option_markers [
    pgettext_noop("open", "task status"),
    pgettext_noop("in_progress", "task status"),
    pgettext_noop("blocked", "task status"),
    pgettext_noop("done", "task status"),
    pgettext_noop("cancelled", "task status"),
    pgettext_noop("considering", "task status"),
    pgettext_noop("researching", "task status"),
    pgettext_noop("parked", "task status"),
    pgettext_noop("closed", "task status")
  ]

  @doc "Every Tasks schema title this module has a translation marker for."
  @spec task_markers() :: [String.t()]
  def task_markers, do: @task_markers

  @doc "Every Tasks lifecycle or disposition token this module shows by a word."
  @spec task_option_markers() :: [String.t()]
  def task_option_markers, do: @task_option_markers

  @doc """
  The word Studio shows for a stored select token: the Tasks lifecycle and
  disposition tokens in the viewer's Studio language, anything else unchanged.
  """
  @spec option_label(String.t() | nil, String.t() | nil, term()) :: term()
  def option_label("task", field, value)
      when field in @task_option_fields and value in @task_option_markers,
      do: Gettext.pgettext(BarkparkWeb.Gettext, "task status", value)

  def option_label(_type, _field, value), do: value

  defp task_word(text) when text in @task_markers,
    do: Gettext.pgettext(BarkparkWeb.Gettext, "task schema", text)

  defp task_word(text), do: text

  defp task_group(%{"title" => title} = g) when is_binary(title),
    do: Map.put(g, "title", task_word(title))

  defp task_group(g), do: g

  defp task_field(%{"name" => name, "options" => opts} = f)
       when name in @task_option_fields and is_list(opts) do
    f
    |> Map.put("options", Enum.map(opts, &task_option(name, &1)))
    |> task_field_title()
  end

  defp task_field(%{} = f), do: task_field_title(f)
  defp task_field(other), do: other

  defp task_field_title(%{"title" => title} = f) when is_binary(title),
    do: Map.put(f, "title", task_word(title))

  defp task_field_title(f), do: f

  defp task_option(field, value) when is_binary(value),
    do: %{"value" => value, "title" => option_label("task", field, value)}

  defp task_option(_field, other), do: other

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
