defmodule Barkpark.Codelists.EDItEUR do
  @moduledoc """
  EDItEUR ONIX codelist parser + seeder.

  Barkpark ships the parser; publishers bring their own EDItEUR codelist XML
  snapshot ("BYO model", per Phase 4 D21). Path resolution priority:

    1. explicit `--source PATH` arg / `path` opt
    2. `BARKPARK_ONIX_CODELIST_PATH` environment variable
    3. plugin settings entry (`Barkpark.Plugins.Settings.get/1` → `"codelist_path"`)

  ## Pipeline

      path
      |> EDItEUR.parse_xml()       # → {:ok, [%{list_id, issue, name, values}]}
      |> EDItEUR.seed(opts)        # → :ok, calls Codelists.register/3 per list

  Streaming uses `SweetXml.stream_tags/3` so the file is parsed one
  `<CodeList>` element at a time — fine for 50+ MB EDItEUR snapshots.

  ## Hierarchy

  Codes carrying a `<ParentCode>X</ParentCode>` element are linked into
  Thema-style trees (codelist 93, ~3000 nodes). The EDItEUR tree is built
  in-memory once per list and then handed to `Codelists.register/3`, which
  walks the `:children` keys and writes `parent_id` self-references on
  insert (effectively a two-pass: collect-then-link).

  Codes with no `<ParentCode>` are treated as roots. Forward references
  (a code naming a parent that has not yet been seen) are still placed
  under the named parent — list assembly is a post-pass over the full
  flat set.

  ## Multi-language

  Per-language labels come from `<Description language="…">` elements.
  When only a `<CodeDescription>` element is present (no language attr)
  it is recorded as `eng` (the EDItEUR default).

  ## Plugin discriminator

  Every row is tagged `plugin_name: "onixedit"` (D20). The `list_id` is
  derived as `"onixedit:list_<NUMBER>"` so Phase 0's
  `(plugin_name, list_id, issue)` uniqueness key is preserved across
  publishers and across issues.
  """

  alias Barkpark.Content.Codelists

  import SweetXml

  @plugin_default "onixedit"

  @typedoc "One parsed codelist, as returned by `parse_xml/1`."
  @type parsed_list :: %{
          list_id: String.t(),
          list_number: String.t(),
          issue: String.t() | nil,
          name: String.t() | nil,
          values: [Codelists.value_input()]
        }

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Stream-parse an EDItEUR ONIX codelist XML file.

  Returns `{:ok, [parsed_list]}` on success, `{:error, reason}` if the file
  is missing or malformed. Memory footprint stays bounded: one `<CodeList>`
  in flight at a time. Empty or attribute-only `<CodeList>` elements are
  skipped silently — a real EDItEUR export is allowed to contain header
  metadata that is not itself a list.
  """
  @spec parse_xml(Path.t(), keyword()) :: {:ok, [parsed_list()]} | {:error, term()}
  def parse_xml(path, opts \\ []) do
    plugin = Keyword.get(opts, :plugin, @plugin_default)

    cond do
      not File.exists?(path) ->
        {:error, {:file_not_found, path}}

      not File.regular?(path) ->
        {:error, {:not_a_file, path}}

      true ->
        try do
          lists =
            path
            |> File.stream!([], 64 * 1024)
            |> SweetXml.stream_tags(:CodeList, discard: [:CodeList])
            |> Enum.flat_map(fn {:CodeList, element} -> parse_list(element, plugin) end)

          {:ok, lists}
        rescue
          e -> {:error, {:parse_failed, Exception.message(e)}}
        catch
          :exit, reason -> {:error, {:parse_exit, reason}}
        end
    end
  end

  @doc """
  Persist parsed codelists into the Phase 0 registry.

  Each list is written via `Barkpark.Content.Codelists.register/3`, which
  is idempotent on `(plugin_name, list_id, issue)`: re-running the seeder
  with the same XML and the same issue is a no-op as far as row counts
  go (existing values + translations are replaced, the codelist row is
  upserted).

  ## Options

    * `:plugin` — plugin discriminator. Defaults to `"onixedit"`.
    * `:issue` — overrides the per-list `issue` field. When the parser
      could not extract `issue` from the XML (older EDItEUR exports omit
      a Version attribute), the caller must pass this.
  """
  @spec seed([parsed_list()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def seed(parsed, opts \\ []) when is_list(parsed) do
    plugin = Keyword.get(opts, :plugin, @plugin_default)
    fallback_issue = Keyword.get(opts, :issue)

    Enum.reduce_while(parsed, {:ok, []}, fn list, {:ok, acc} ->
      issue = list.issue || fallback_issue

      cond do
        is_nil(issue) ->
          {:halt, {:error, {:missing_issue, list.list_id}}}

        true ->
          attrs = %{
            issue: to_string(issue),
            name: list.name,
            values: list.values
          }

          case Codelists.register(plugin, list.list_id, attrs) do
            {:ok, _} -> {:cont, {:ok, [list.list_id | acc]}}
            {:error, reason} -> {:halt, {:error, {:register_failed, list.list_id, reason}}}
          end
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      other -> other
    end
  end

  @doc """
  Resolve the on-disk EDItEUR XML path using the BYO precedence chain.

  Returns `{:ok, path}` if any source produces a string, `{:error, :not_found}`
  otherwise. Callers (the Mix task) print the friendly first-boot message
  on `:not_found`.
  """
  @spec resolve_source(keyword()) :: {:ok, String.t()} | {:error, :not_found}
  def resolve_source(opts \\ []) do
    explicit = Keyword.get(opts, :source)
    plugin = Keyword.get(opts, :plugin, @plugin_default)

    cond do
      is_binary(explicit) and explicit != "" ->
        {:ok, explicit}

      env = System.get_env("BARKPARK_ONIX_CODELIST_PATH") ->
        if env != "", do: {:ok, env}, else: lookup_settings_path(plugin)

      true ->
        lookup_settings_path(plugin)
    end
  end

  # ── Internals — tree assembly ───────────────────────────────────────────

  defp parse_list(element, _plugin) do
    list_number =
      element
      |> xpath(~x"./CodeListNumber/text()"s)
      |> trim_or_nil()

    if is_nil(list_number) do
      []
    else
      list_name = element |> xpath(~x"./CodeListDescription/text()"s) |> trim_or_nil()
      issue = element |> xpath(~x"./@IssueNumber"s) |> trim_or_nil()

      flat =
        element
        |> xpath(~x"./Code"l)
        |> Enum.with_index()
        |> Enum.map(fn {code_el, position} -> parse_code(code_el, position) end)
        |> Enum.reject(&is_nil/1)

      [
        %{
          list_id: "onixedit:list_#{list_number}",
          list_number: list_number,
          issue: issue,
          name: list_name,
          values: build_tree(flat)
        }
      ]
    end
  end

  defp parse_code(code_el, position) do
    value = code_el |> xpath(~x"./CodeValue/text()"s) |> trim_or_nil()

    if is_nil(value) do
      nil
    else
      parent_code = code_el |> xpath(~x"./ParentCode/text()"s) |> trim_or_nil()
      translations = extract_translations(code_el)

      %{
        code: value,
        parent_code: parent_code,
        position: position,
        translations: translations
      }
    end
  end

  # `<Description language="…">` wins over `<CodeDescription>` (the latter
  # is the EDItEUR default-language fallback). Keep both shapes — a real
  # snapshot mixes them depending on language coverage.
  defp extract_translations(code_el) do
    multi =
      code_el
      |> xpath(~x"./Description"l, language: ~x"./@language"s, label: ~x"./text()"s)
      |> Enum.map(fn %{language: lang, label: label} ->
        %{language: normalize_lang(lang), label: trim_or_nil(label)}
      end)
      |> Enum.reject(&(is_nil(&1.label) or &1.language in [nil, ""]))

    cond do
      multi != [] ->
        multi

      label = code_el |> xpath(~x"./CodeDescription/text()"s) |> trim_or_nil() ->
        notes = code_el |> xpath(~x"./CodeNotes/text()"s) |> trim_or_nil()
        [%{language: "eng", label: label, description: notes}]

      true ->
        []
    end
  end

  defp build_tree(flat) do
    by_code = Map.new(flat, fn entry -> {entry.code, entry} end)
    children_by_parent = Enum.group_by(flat, & &1.parent_code)

    flat
    |> Enum.filter(fn entry ->
      is_nil(entry.parent_code) or not Map.has_key?(by_code, entry.parent_code)
    end)
    |> Enum.sort_by(& &1.position)
    |> Enum.map(&assemble(&1, children_by_parent))
  end

  defp assemble(entry, children_by_parent) do
    children =
      children_by_parent
      |> Map.get(entry.code, [])
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&assemble(&1, children_by_parent))

    %{
      code: entry.code,
      position: entry.position,
      translations: entry.translations,
      children: children
    }
  end

  # ── Internals — misc ────────────────────────────────────────────────────

  defp trim_or_nil(nil), do: nil

  defp trim_or_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_lang(nil), do: nil

  defp normalize_lang(lang) when is_binary(lang) do
    case String.trim(lang) do
      "" -> nil
      v -> String.downcase(v)
    end
  end

  defp lookup_settings_path(plugin) do
    case Barkpark.Plugins.Settings.get(plugin) do
      {:ok, %{"codelist_path" => path}} when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        {:error, :not_found}
    end
  rescue
    # Plugin settings may not be available in every test environment; treat
    # any error as "no path configured" rather than crashing the resolver.
    _ -> {:error, :not_found}
  end
end
