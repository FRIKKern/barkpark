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

  require Logger

  @plugin_default "onixedit"

  # ── Bundled fixture (Task barkpark-2nw) ─────────────────────────────────
  #
  # `seed_bundled/1` reads the checked-in EDItEUR XML snapshot at
  # `priv/codelists/onix-issue-73.xml` and registers every list. Driven by
  # `Barkpark.Application` at boot and by `priv/repo/seeds.exs` on
  # `mix ecto.reset`. Idempotent — re-running on a populated DB upserts the
  # codelist rows with no duplicate-key churn.

  @bundled_issue "73"
  @bundled_filename "onix-issue-73.xml"

  # ── Bundled Thema fixture (Task barkpark-ufw) ───────────────────────────
  #
  # `seed_thema/1` reads the checked-in EDItEUR Thema JSON snapshot at
  # `priv/codelists/thema-1.6/thema-v1.6-en.json` and registers it as a
  # single codelist `onixedit:thema` issue `"1.6"`. Driven by
  # `Barkpark.Application` at boot and by `priv/repo/seeds.exs` on
  # `mix ecto.reset` — sibling to `seed_bundled/1`. Idempotent on
  # `(plugin_name, list_id, issue)`.
  #
  # Thema is published *separately* from the ONIX codelist bundle (the
  # numeric `list_93` in ONIX is "Supplier role", NOT Thema — see
  # `priv/codelists/thema-1.6/README.md` for the full diagnosis). The
  # friendly key `onixedit:thema` is exempted from the alias resolver's
  # numeric rewrite in `Barkpark.Content.Codelists.@external_scheme_friendlies`.

  @thema_issue "1.6"
  @thema_list_id "onixedit:thema"
  @thema_bundled_path "thema-1.6/thema-v1.6-en.json"
  @thema_default_language "eng"

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
  Seed the codelist registry from the EDItEUR XML snapshot bundled at
  `api/priv/codelists/onix-issue-#{@bundled_issue}.xml`.

  This is the boot-time entry point — `Barkpark.Application` runs it in a
  post-boot `Task`, and `priv/repo/seeds.exs` calls the same helper after
  schema bootstrap. Idempotent on `(plugin_name, list_id, issue)` via
  `Codelists.register/3` — re-running is a no-op.

  Returns:

    * `{:ok, count}` when seeding succeeded (count = number of lists
      registered).
    * `{:ok, :no_snapshot}` when the bundled XML is missing on disk (rare
      — e.g. a stripped-down install). Boots keep moving; the Studio just
      stays in its "(no codelist registered)" state.
    * `{:error, reason}` on parse / register failure.

  Never raises.
  """
  @spec seed_bundled(keyword()) ::
          {:ok, non_neg_integer()} | {:ok, :no_snapshot} | {:error, term()}
  def seed_bundled(opts \\ []) do
    plugin = Keyword.get(opts, :plugin, @plugin_default)
    issue = Keyword.get(opts, :issue, @bundled_issue)

    case bundled_path() do
      {:error, :not_found} ->
        Logger.info(
          "Codelists.EDItEUR: bundled snapshot #{@bundled_filename} not found on disk — skipping seed"
        )

        {:ok, :no_snapshot}

      {:ok, path} ->
        Logger.info(
          "Codelists.EDItEUR: seeding bundled snapshot #{path} (plugin=#{plugin}, issue=#{issue})"
        )

        with {:ok, parsed} <- parse_xml(path, plugin: plugin),
             {:ok, ids} <- seed(parsed, plugin: plugin, issue: issue) do
          Logger.info("Codelists.EDItEUR: seeded #{length(ids)} list(s) from bundled snapshot")
          {:ok, length(ids)}
        else
          {:error, reason} = err ->
            Logger.error("Codelists.EDItEUR: bundled seed failed — #{inspect(reason)}")

            err
        end
    end
  rescue
    e ->
      Logger.error("Codelists.EDItEUR: bundled seed raised — #{Exception.message(e)}")

      {:error, {:raised, Exception.message(e)}}
  end

  @doc """
  Backwards-compat alias for `seed_bundled/1`.

  The task brief (Task barkpark-2nw) named this `seed_from_json/1` on the
  expectation that EDItEUR published codelists as JSON. In practice
  EDItEUR ships the codelist data file only as XML, so the bundled
  snapshot at `priv/codelists/onix-issue-73.xml` is XML. The honest name
  is `seed_bundled/1`; this alias remains so the brief's verification
  commands keep working.
  """
  @spec seed_from_json(keyword() | atom()) ::
          {:ok, non_neg_integer()} | {:ok, :no_snapshot} | {:error, term()}
  def seed_from_json(opts \\ [])
  def seed_from_json(dataset) when is_atom(dataset), do: seed_bundled([])
  def seed_from_json(opts) when is_list(opts), do: seed_bundled(opts)

  @doc """
  Seed the codelist registry from the EDItEUR Thema JSON snapshot bundled
  at `api/priv/codelists/thema-1.6/thema-v1.6-en.json`.

  Sibling to `seed_bundled/1`: same boot-time entry-point contract,
  same idempotent `(plugin_name, list_id, issue)` upsert via
  `Codelists.register/3`, same `{:ok, count} | {:ok, :no_snapshot} | {:error, reason}`
  return shape.

  Thema is NOT in the bundled ONIX codelist XML — EDItEUR publishes it
  separately. The numeric ONIX list 93 is "Supplier role", unrelated to
  Thema; the value 93 next to Thema in book.json is the
  `SubjectSchemeIdentifier` value inside ONIX list 27, not a pointer to
  an ONIX codelist. See `Barkpark.Content.Codelists.@external_scheme_friendlies`
  for the resolver allowlist that prevents `onixedit:thema` from being
  mis-aliased to `onixedit:list_93`.

  ## Options

    * `:plugin` — plugin discriminator. Defaults to `"onixedit"`.
    * `:issue` — overrides the snapshot's pinned issue (`"1.6"`).

  Never raises.
  """
  @spec seed_thema(keyword()) ::
          {:ok, non_neg_integer()} | {:ok, :no_snapshot} | {:error, term()}
  def seed_thema(opts \\ []) do
    plugin = Keyword.get(opts, :plugin, @plugin_default)
    issue = Keyword.get(opts, :issue, @thema_issue)

    case thema_bundled_path() do
      {:error, :not_found} ->
        Logger.info(
          "Codelists.EDItEUR: bundled Thema snapshot #{@thema_bundled_path} not found on disk — skipping seed"
        )

        {:ok, :no_snapshot}

      {:ok, path} ->
        Logger.info(
          "Codelists.EDItEUR: seeding bundled Thema snapshot #{path} (plugin=#{plugin}, issue=#{issue})"
        )

        with {:ok, raw} <- File.read(path),
             {:ok, parsed} <- Jason.decode(raw),
             {:ok, list} <- parse_thema_json(parsed),
             attrs = %{issue: to_string(issue), name: list.name, values: list.values},
             {:ok, _codelist} <- Codelists.register(plugin, @thema_list_id, attrs) do
          Logger.info(
            "Codelists.EDItEUR: seeded Thema codelist (plugin=#{plugin}, list_id=#{@thema_list_id}, issue=#{issue})"
          )

          {:ok, 1}
        else
          {:error, reason} = err ->
            Logger.error("Codelists.EDItEUR: Thema seed failed — #{inspect(reason)}")
            err
        end
    end
  rescue
    e ->
      Logger.error("Codelists.EDItEUR: Thema seed raised — #{Exception.message(e)}")
      {:error, {:raised, Exception.message(e)}}
  end

  @doc """
  The issue `seed_thema/1` pins the bundled Thema snapshot to.

  Exposed so the OnixEdit plugin's declared codelist contract
  (`Barkpark.Plugins.OnixEdit.CodelistSeeders.requirements/0`) can READ the
  issue boot actually writes instead of restating it. The two had drifted:
  the contract declared `"93"`, which is the ONIX list number for
  "Supplier role" — Thema is published separately and carries its own
  version, currently `"1.6"`.
  """
  @spec thema_issue() :: String.t()
  def thema_issue, do: @thema_issue

  @doc """
  Locate the bundled Thema JSON snapshot on disk via `:code.priv_dir/1`.

  Returns `{:ok, abs_path}` when the file exists, `{:error, :not_found}`
  otherwise.
  """
  @spec thema_bundled_path() :: {:ok, Path.t()} | {:error, :not_found}
  def thema_bundled_path do
    case :code.priv_dir(:barkpark) do
      {:error, _} = err ->
        Logger.warning("Codelists.EDItEUR: :code.priv_dir(:barkpark) failed — #{inspect(err)}")
        {:error, :not_found}

      priv when is_list(priv) ->
        path = Path.join([List.to_string(priv), "codelists", @thema_bundled_path])
        if File.exists?(path), do: {:ok, path}, else: {:error, :not_found}
    end
  end

  @doc """
  Locate the bundled XML snapshot on disk via `:code.priv_dir/1`.

  Returns `{:ok, abs_path}` when the file exists, `{:error, :not_found}`
  otherwise. Used by `seed_bundled/1`; also exposed for tests.
  """
  @spec bundled_path() :: {:ok, Path.t()} | {:error, :not_found}
  def bundled_path do
    case :code.priv_dir(:barkpark) do
      {:error, _} = err ->
        Logger.warning("Codelists.EDItEUR: :code.priv_dir(:barkpark) failed — #{inspect(err)}")
        {:error, :not_found}

      priv when is_list(priv) ->
        path = Path.join([List.to_string(priv), "codelists", @bundled_filename])
        if File.exists?(path), do: {:ok, path}, else: {:error, :not_found}
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

  # ── Internals — Thema JSON ──────────────────────────────────────────────

  # Reshape EDItEUR Thema JSON into one `parsed_list` shape so the existing
  # `build_tree/1` can assemble the hierarchy. JSON entries land flat with
  # a `CodeParent` string; the builder turns that into a nested
  # `:children`-tree the registry can recurse into.
  defp parse_thema_json(%{"CodeList" => %{"ThemaCodes" => %{"Code" => entries}} = code_list})
       when is_list(entries) do
    list_name = Map.get(code_list, "CodeListDescription") |> trim_or_nil()

    flat =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, position} -> parse_thema_entry(entry, position) end)
      |> Enum.reject(&is_nil/1)

    {:ok,
     %{
       list_id: @thema_list_id,
       list_number: "214",
       issue: @thema_issue,
       name: list_name || "Thema Subject Codes",
       values: build_tree(flat)
     }}
  end

  defp parse_thema_json(_), do: {:error, :unexpected_thema_shape}

  defp parse_thema_entry(entry, position) when is_map(entry) do
    code = entry |> Map.get("CodeValue") |> to_thema_string() |> trim_or_nil()

    if is_nil(code) do
      nil
    else
      # `CodeParent` is normally a string ("AB", "FV"), but the qualifier
      # subtrees use integer roots ("1", "2", "3", "4", "5", "6") that
      # come over the wire as JSON numbers. Coerce so children of those
      # roots resolve correctly during tree assembly.
      parent_code = entry |> Map.get("CodeParent") |> to_thema_string() |> trim_or_nil()
      label = entry |> Map.get("CodeDescription") |> to_thema_string() |> trim_or_nil()
      notes = entry |> Map.get("CodeNotes") |> to_thema_string() |> trim_or_nil()

      translations =
        case label do
          nil -> []
          _ -> [%{language: @thema_default_language, label: label, description: notes}]
        end

      %{
        code: code,
        parent_code: parent_code,
        position: position,
        translations: translations
      }
    end
  end

  defp parse_thema_entry(_, _), do: nil

  defp to_thema_string(nil), do: nil
  defp to_thema_string(v) when is_binary(v), do: v
  defp to_thema_string(v) when is_integer(v), do: Integer.to_string(v)
  defp to_thema_string(v) when is_float(v), do: Float.to_string(v)
  defp to_thema_string(_), do: nil

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
