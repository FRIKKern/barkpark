defmodule Barkpark.Plugins.OnixEdit.Export.CodelistSource do
  @moduledoc """
  Compile-time codelist loader for the ONIX 3.0 export pipeline.

  Reads the two EDItEUR snapshots Barkpark already vendors and turns them into
  plain `code => label` maps. `Barkpark.Plugins.OnixEdit.Export.Codelists`
  calls this from its module body, so the maps are baked into the BEAM literal
  pool at compile time and the export path stays pure — no `Repo` call, no
  process state, nothing that can fail at render time.

    * `onix_lists/1` — the numeric ONIX lists, read from
      `priv/onix/onix-3.0/ONIX_BookProduct_CodeLists.xsd`. That is the SAME
      file `Export.Validator` hands to `xmllint`, so the enumeration we emit
      against and the enumeration we are validated against cannot drift.
    * `thema/0` — Thema 1.6 (9,187 codes), read from
      `priv/codelists/thema-1.6/thema-v1.6-en.json`. Thema is published
      separately from the ONIX bundle and is NOT in the XSD (`List93` there is
      Supplier role, 16 codes — see `priv/codelists/thema-1.6/README.md`).
      It is the same file `Barkpark.Codelists.EDItEUR.seed_thema/1` registers
      into the DB registry, so the exporter and the Studio dropdown resolve
      from one source.

  The parser is deliberately regex-based rather than SweetXml: it runs during
  compilation, where pulling a NIF-backed XML parser into the compiler's
  dependency graph buys nothing. The shapes it reads are fixed vendored files,
  not user input.
  """

  @priv_root Path.expand("../../../../../priv", __DIR__)
  @xsd_relpath "onix/onix-3.0/ONIX_BookProduct_CodeLists.xsd"
  @thema_relpath "codelists/thema-1.6/thema-v1.6-en.json"

  @doc "Absolute path to the vendored EDItEUR ONIX codelist XSD."
  @spec xsd_path() :: Path.t()
  def xsd_path, do: Path.join(@priv_root, @xsd_relpath)

  @doc "Absolute path to the vendored EDItEUR Thema 1.6 JSON snapshot."
  @spec thema_path() :: Path.t()
  def thema_path, do: Path.join(@priv_root, @thema_relpath)

  @doc """
  Read the named ONIX lists out of the XSD in one pass.

  Returns `%{list_number => %{code => label}}`. Raises when the file is
  missing or a requested list is not enumerated — a silently-empty list would
  turn every code of that list into "unknown", which is exactly the failure
  this module exists to retire.
  """
  @spec onix_lists([pos_integer()]) :: %{pos_integer() => %{String.t() => String.t()}}
  def onix_lists(numbers) when is_list(numbers) do
    xsd = read_source!(xsd_path())

    Map.new(numbers, fn number ->
      body =
        case Regex.run(~r/<xs:simpleType name="List#{number}">(.*?)<\/xs:simpleType>/s, xsd,
               capture: :all_but_first
             ) do
          [body] ->
            body

          _ ->
            raise "ONIX codelist List#{number} is not enumerated in #{xsd_path()}"
        end

      case parse_enumerations(body) do
        [] -> raise "ONIX codelist List#{number} enumerated zero codes in #{xsd_path()}"
        pairs -> {number, Map.new(pairs)}
      end
    end)
  end

  @doc """
  Read Thema 1.6 out of the bundled JSON snapshot.

  Returns `%{code => label}`. Raises when the file is missing or its shape is
  not the EDItEUR one.
  """
  @spec thema() :: %{String.t() => String.t()}
  def thema do
    entries =
      case thema_path() |> read_source!() |> Jason.decode!() do
        %{"CodeList" => %{"ThemaCodes" => %{"Code" => entries}}} when is_list(entries) ->
          entries

        _ ->
          raise "unexpected Thema snapshot shape in #{thema_path()}"
      end

    map =
      entries
      |> Enum.flat_map(fn
        %{"CodeValue" => code} = entry when is_binary(code) ->
          label = Map.get(entry, "CodeDescription")
          [{code, if(is_binary(label), do: label, else: code)}]

        _ ->
          []
      end)
      |> Map.new()

    if map_size(map) == 0 do
      raise "Thema snapshot at #{thema_path()} yielded zero codes"
    end

    map
  end

  defp read_source!(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents

      {:error, reason} ->
        raise "cannot read vendored codelist source #{path}: #{:file.format_error(reason)}"
    end
  end

  # One `<xs:enumeration value="CODE">` chunk at a time. The chunk is cut at
  # the enumeration's own closing tag BEFORE the label is looked for, so a
  # self-closing `<xs:enumeration value="X"/>` cannot borrow the NEXT code's
  # `<xs:documentation>`.
  defp parse_enumerations(body) do
    body
    |> String.split(~s(<xs:enumeration value="))
    |> Enum.drop(1)
    |> Enum.flat_map(fn chunk ->
      case String.split(chunk, ~s("), parts: 2) do
        [code, rest] when code != "" ->
          [own | _] = String.split(rest, "</xs:enumeration>", parts: 2)
          [{code, label_of(own, code)}]

        _ ->
          []
      end
    end)
  end

  defp label_of(chunk, code) do
    case Regex.run(~r/<xs:documentation>(.*?)<\/xs:documentation>/s, chunk,
           capture: :all_but_first
         ) do
      [label] -> label |> unescape() |> String.trim()
      _ -> code
    end
  end

  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end
end
