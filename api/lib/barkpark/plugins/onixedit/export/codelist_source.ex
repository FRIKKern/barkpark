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

  # Resolved at RUNTIME via `:code.lib_dir/1`, the same shape
  # `Export.Validator.default_xsd_path/0` uses — in an OTP release `priv`
  # lives at `lib/barkpark-<vsn>/priv` and the build tree is gone, so a
  # `__DIR__`-baked absolute path would raise File.Error there.
  # `Barkpark.Plugins.ReleasePrivPathTest` enforces this.
  @xsd_subpath "priv/onix/onix-3.0/ONIX_BookProduct_CodeLists.xsd"
  @thema_subpath "priv/codelists/thema-1.6/thema-v1.6-en.json"

  @doc "Absolute path to the vendored EDItEUR ONIX codelist XSD."
  @spec xsd_path() :: Path.t()
  def xsd_path, do: priv_path(@xsd_subpath)

  @doc "Absolute path to the vendored EDItEUR Thema 1.6 JSON snapshot."
  @spec thema_path() :: Path.t()
  def thema_path, do: priv_path(@thema_subpath)

  # `:code.lib_dir/1` answers for a release and for a compiled source tree
  # alike. It can still miss during a COLD first compile of this very app,
  # before its own ebin lands on the code path — these files are read from the
  # module body of `Export.Codelists`, so that window is real. The source-tree
  # fallback covers it; nothing here freezes a build path into a `.beam`.
  defp priv_path(subpath) do
    from_code_path =
      case :code.lib_dir(:barkpark) do
        {:error, _} -> nil
        dir -> Path.join(to_string(dir), subpath)
      end

    if is_binary(from_code_path) and File.exists?(from_code_path) do
      from_code_path
    else
      Path.expand(Path.join("../../../../..", subpath), __DIR__)
    end
  end

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

  # The only paths reaching this are the two module-level `@..._subpath`
  # constants resolved against the app's own priv dir — no request data, no
  # user input, nothing a caller can steer. Same posture as
  # `Export.Validator`'s XSD read, annotated the same way.
  # sobelow_skip ["Traversal.FileModule"]
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
