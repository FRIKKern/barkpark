defmodule Barkpark.Content.Codelists do
  @moduledoc """
  Codelist registry — pluggable, plugin-discriminated codelist storage.

  Backed by three tables:

    * `codelists` — list headers, keyed by `(plugin_name, list_id, issue)`
    * `codelist_values` — entries (with optional `parent_id` for hierarchy)
    * `codelist_value_translations` — multi-language labels per entry

  ## Plugin discriminator (Decision 20)

  `plugin_name` is the discriminator. Two plugins may register a list_id like
  `"language"` without collision. The list_id convention is `<plugin>:<name>`
  for grep-ability (e.g. `"onixedit:contributor_role"`). Both halves of the
  identity are stored explicitly: the column is the discriminator, the string
  is the human-friendly ID.

  ## Idempotent registration

  Calling `register/3` twice with the same `(plugin_name, list_id, issue)` is
  idempotent: the codelist row's metadata is upserted, all of its existing
  values + translations are deleted (cascading) and re-inserted from the
  payload. Re-registration with a different `issue` creates a NEW codelist
  row alongside the previous one (history is preserved).

  ## Default-language fallback

  `lookup/3` resolves labels in this order: the languages passed via
  `:languages`, falling back to `["nob", "eng"]`, then any other available
  translation. The first translation matching a language in the chain wins.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content.Codelists.{Codelist, Translation, Value}

  @default_languages ["nob", "eng"]

  @typedoc """
  Input value tree node accepted by `register/3`.

      %{
        code: "A01",
        position: 0,                       # optional
        metadata: %{...},                  # optional
        translations: [
          %{language: "eng", label: "By (author)", description: "..."}
        ],
        children: [%{code: "A01.1", ...}]   # optional
      }
  """
  @type value_input :: %{
          required(:code) => String.t(),
          optional(:position) => integer() | nil,
          optional(:metadata) => map() | nil,
          optional(:translations) => [translation_input()],
          optional(:children) => [value_input()]
        }

  @type translation_input :: %{
          required(:language) => String.t(),
          required(:label) => String.t(),
          optional(:description) => String.t() | nil
        }

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Register a codelist for a plugin.

  `attrs` accepts:

    * `:issue` (required) — pinned issue/version, e.g. `"73"` or `"2024-q1"`
    * `:name` — display name, e.g. `"ONIX Contributor Role 73"`
    * `:description` — long-form description
    * `:values` — list of `t:value_input/0` (may nest via `:children`)

  Returns `{:ok, codelist}` with the persisted `Codelist` (without preloads).
  Re-registration of the same `(plugin_name, list_id, issue)` is idempotent:
  the header row is upserted in place, and all existing values + translations
  are deleted and replaced.
  """
  @spec register(String.t(), String.t(), map()) :: {:ok, %Codelist{}} | {:error, term()}
  def register(plugin_name, list_id, attrs)
      when is_binary(plugin_name) and is_binary(list_id) and is_map(attrs) do
    issue = fetch_issue!(attrs)
    name = Map.get(attrs, :name)
    description = Map.get(attrs, :description)
    values = Map.get(attrs, :values) || []

    Repo.transaction(fn ->
      codelist = upsert_codelist!(plugin_name, list_id, issue, name, description)
      replace_values!(codelist, values)
      codelist
    end)
  end

  @doc """
  Get the latest-issue codelist for a plugin's list_id.

  Returns the `Codelist` with `values` and their `translations` preloaded, or
  `nil` if no codelist is registered.

  "Latest" is determined by descending `issue` string ordering, which is
  correct for ONIX-style integer issues padded with leading zeros and for
  ISO-style semantic versions like `"2024-q1"`. Callers wanting an exact
  issue should query the schema modules directly.
  """
  @spec get(String.t(), String.t()) :: %Codelist{} | nil
  def get(plugin_name, list_id) do
    Codelist
    |> where([c], c.plugin_name == ^plugin_name and c.list_id == ^list_id)
    |> order_by([c], desc: c.issue)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      codelist -> Repo.preload(codelist, values: :translations)
    end
  end

  @doc """
  Look up a single code in a codelist.

  Returns `%{value: code, label: "...", parent_code: nil | "..."}` for the
  matching code, or `nil` if either the codelist or the code is unknown.

  ## Options

    * `:languages` — preferred language order; defaults to `["nob", "eng"]`.
      The first translation matching a language in the chain wins. If no
      preferred language matches, the first translation by any language is
      used. If the value has no translations at all, `:label` is the code.
  """
  @spec lookup(String.t(), String.t(), String.t(), keyword()) :: map() | nil
  def lookup(plugin_name, list_id, code, opts \\ []) do
    languages = Keyword.get(opts, :languages, @default_languages)

    with %Codelist{id: codelist_id} <-
           latest_codelist_id(plugin_name, list_id),
         %Value{} = value <- fetch_value(codelist_id, code) do
      parent_code =
        case value.parent_id do
          nil ->
            nil

          parent_id ->
            Repo.one(from v in Value, where: v.id == ^parent_id, select: v.code)
        end

      %{
        value: value.code,
        label: resolve_label(value, languages),
        parent_code: parent_code
      }
    else
      _ -> nil
    end
  end

  @doc """
  Build the codelist as a nested tree.

  Returns a list of root maps `[%{value, label, children: [...]}]` walking
  from `parent_id IS NULL` downward. Children are ordered by `position`
  ascending (nulls last) then by `code`.

  Implementation: one query for all values, one query for all translations,
  then assembly in memory. Safe to materialize for ~3000-entry trees like
  Thema (codelist 93).
  """
  @spec tree(String.t(), String.t(), keyword()) :: [map()]
  def tree(plugin_name, list_id, opts \\ []) do
    languages = Keyword.get(opts, :languages, @default_languages)

    case latest_codelist_id(plugin_name, list_id) do
      nil ->
        []

      %Codelist{id: codelist_id} ->
        values =
          Value
          |> where([v], v.codelist_id == ^codelist_id)
          |> Repo.all()

        value_ids = Enum.map(values, & &1.id)

        translations =
          Translation
          |> where([t], t.codelist_value_id in ^value_ids)
          |> Repo.all()
          |> Enum.group_by(& &1.codelist_value_id)

        build_tree(values, translations, languages)
    end
  end

  @doc """
  List all codelists registered under a plugin (latest issue per list_id).
  Useful for debugging.
  """
  @spec list(String.t()) :: [%Codelist{}]
  def list(plugin_name) do
    Codelist
    |> where([c], c.plugin_name == ^plugin_name)
    |> order_by([c], asc: c.list_id, desc: c.issue)
    |> Repo.all()
  end

  # ── Internals ────────────────────────────────────────────────────────────

  defp fetch_issue!(%{issue: issue}) when is_binary(issue) and issue != "", do: issue
  defp fetch_issue!(%{issue: issue}) when is_integer(issue), do: Integer.to_string(issue)

  defp fetch_issue!(_),
    do: raise(ArgumentError, "register/3 requires :issue (string or integer)")

  defp upsert_codelist!(plugin_name, list_id, issue, name, description) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.get_by(Codelist,
           plugin_name: plugin_name,
           list_id: list_id,
           issue: issue
         ) do
      nil ->
        %Codelist{}
        |> Codelist.changeset(%{
          plugin_name: plugin_name,
          list_id: list_id,
          issue: issue,
          name: name,
          description: description
        })
        |> Repo.insert!()

      existing ->
        existing
        |> Codelist.changeset(%{name: name, description: description})
        |> Ecto.Changeset.force_change(:updated_at, now)
        |> Repo.update!()
    end
  end

  defp replace_values!(%Codelist{id: codelist_id}, values) do
    # Cascading FK deletes translations along with values.
    Repo.delete_all(from v in Value, where: v.codelist_id == ^codelist_id)
    Enum.each(values, &insert_value!(&1, codelist_id, nil))
  end

  defp insert_value!(input, codelist_id, parent_id) do
    code = Map.fetch!(input, :code)
    position = Map.get(input, :position)
    metadata = Map.get(input, :metadata)
    translations = Map.get(input, :translations, [])
    children = Map.get(input, :children, [])

    value =
      %Value{}
      |> Value.changeset(%{
        codelist_id: codelist_id,
        parent_id: parent_id,
        code: code,
        position: position,
        metadata: metadata
      })
      |> Repo.insert!()

    Enum.each(translations, fn t ->
      %Translation{}
      |> Translation.changeset(%{
        codelist_value_id: value.id,
        language: Map.fetch!(t, :language),
        label: Map.fetch!(t, :label),
        description: Map.get(t, :description)
      })
      |> Repo.insert!()
    end)

    Enum.each(children, &insert_value!(&1, codelist_id, value.id))
  end

  defp latest_codelist_id(plugin_name, list_id) do
    Codelist
    |> where([c], c.plugin_name == ^plugin_name and c.list_id == ^list_id)
    |> order_by([c], desc: c.issue)
    |> limit(1)
    |> Repo.one()
  end

  defp fetch_value(codelist_id, code) do
    Repo.one(
      from v in Value,
        where: v.codelist_id == ^codelist_id and v.code == ^code,
        preload: [:translations]
    )
  end

  defp resolve_label(%Value{translations: translations} = value, languages)
       when is_list(translations) do
    case pick_translation(translations, languages) do
      nil -> value.code
      %Translation{label: label} -> label
    end
  end

  defp resolve_label(%Value{} = value, _languages), do: value.code

  defp pick_translation([], _languages), do: nil

  defp pick_translation(translations, languages) do
    by_language = Map.new(translations, &{&1.language, &1})

    Enum.find_value(languages, fn lang -> Map.get(by_language, lang) end) ||
      List.first(translations)
  end

  defp build_tree(values, translations_by_value, languages) do
    children_by_parent = Enum.group_by(values, & &1.parent_id)

    children_by_parent
    |> Map.get(nil, [])
    |> sort_values()
    |> Enum.map(&assemble_node(&1, children_by_parent, translations_by_value, languages))
  end

  defp assemble_node(%Value{} = value, children_by_parent, translations_by_value, languages) do
    translations = Map.get(translations_by_value, value.id, [])
    label = resolve_label(%{value | translations: translations}, languages)

    children =
      children_by_parent
      |> Map.get(value.id, [])
      |> sort_values()
      |> Enum.map(&assemble_node(&1, children_by_parent, translations_by_value, languages))

    %{value: value.code, label: label, children: children}
  end

  defp sort_values(values) do
    Enum.sort_by(values, fn v ->
      pos = if v.position == nil, do: :infinity, else: v.position
      {pos, v.code}
    end)
  end
end
