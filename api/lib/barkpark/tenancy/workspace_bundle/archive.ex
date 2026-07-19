defmodule Barkpark.Tenancy.WorkspaceBundle.InvalidBundleError do
  @moduledoc """
  The request body is not a readable bp-export-v1 bundle (PDS-D50).

  Raised — never coerced to a partial import — when the bytes cannot be a
  bundle at all: empty, truncated mid-stream, not a tar, or a tar carrying no
  `manifest.json`. Before this existed `Archive.unpack/1` hard-matched
  `{:ok, entries} = :erl_tar.extract(…)`, so a zero-byte or truncated body
  (exactly what a streamed pull produces on a dropped connection) raised
  `MatchError` and the caller got an opaque 500 with a request_id it could not
  resolve. The HTTP edge turns this into an honest 422 `invalid_bundle`.

  `code` is stable and machine-branchable: `"invalid_bundle"`.
  """
  defexception [:code, :message]

  @type t :: %__MODULE__{code: String.t(), message: String.t()}
end

defmodule Barkpark.Tenancy.WorkspaceBundle.Archive do
  @moduledoc """
  The bp-export-v1 container: a tar carrying a `manifest.json` plus one
  `tables/<name>.copy` member per exported table (charter D1). The `.copy`
  members are the RAW `COPY … TO STDOUT` text bytes — the byte carrier
  (charter D2), never `Envelope.render` output (charter D9).

  `:erl_tar` has no in-memory create, so packing writes a short-lived temp tar
  and reads it back; extraction is fully in-memory from the bundle binary.
  """

  alias Barkpark.Tenancy.WorkspaceBundle.InvalidBundleError

  @format "bp-export-v1"
  @grain "workspace"
  @manifest_name ~c"manifest.json"

  @doc """
  Pack a manifest map + a `%{table => copy_bytes}` map into a bundle binary.
  """
  def pack(manifest, table_dumps) when is_map(manifest) and is_map(table_dumps) do
    manifest_bytes = Jason.encode!(manifest, pretty: true)

    members =
      [{@manifest_name, manifest_bytes}] ++
        Enum.map(table_dumps, fn {table, bytes} ->
          {~c"tables/" ++ String.to_charlist(table) ++ ~c".copy", bytes}
        end)

    path =
      Path.join(
        System.tmp_dir!(),
        "bp-ws-bundle-#{System.unique_integer([:positive])}.tar"
      )

    try do
      :ok = :erl_tar.create(String.to_charlist(path), members, [])
      File.read!(path)
    after
      File.rm(path)
    end
  end

  @doc """
  Extract a bundle binary into `{manifest_map, %{table => copy_bytes}}`.
  """
  def unpack(bundle) when is_binary(bundle) do
    entries = extract!(bundle)

    {manifest_bytes, dumps} =
      Enum.reduce(entries, {nil, %{}}, fn {name, content}, {mf, acc} ->
        name = to_string(name)

        cond do
          name == "manifest.json" ->
            {content, acc}

          String.starts_with?(name, "tables/") and String.ends_with?(name, ".copy") ->
            table =
              name |> String.replace_prefix("tables/", "") |> String.replace_suffix(".copy", "")

            {mf, Map.put(acc, table, content)}

          true ->
            {mf, acc}
        end
      end)

    if is_nil(manifest_bytes) do
      raise InvalidBundleError,
        code: "invalid_bundle",
        message:
          "bundle carries no manifest.json — not a #{@format} bundle " <>
            "(#{byte_size(bundle)} bytes read)"
    end

    {decode_manifest!(manifest_bytes, bundle), dumps}
  end

  def format, do: @format
  def grain, do: @grain

  # PDS-D50: :erl_tar answers {:error, :eof} for BOTH an empty body and a
  # truncated one — the two cases a streamed pull actually produces. Refuse
  # honestly instead of letting a MatchError surface as a 500.
  defp extract!(bundle) do
    case :erl_tar.extract({:binary, bundle}, [:memory]) do
      {:ok, entries} ->
        entries

      {:error, reason} ->
        raise InvalidBundleError,
          code: "invalid_bundle",
          message:
            "request body is not a readable tar (#{byte_size(bundle)} bytes, " <>
              "#{inspect(reason)}) — the bundle is empty or truncated"
    end
  end

  defp decode_manifest!(manifest_bytes, bundle) do
    case Jason.decode(manifest_bytes) do
      {:ok, manifest} when is_map(manifest) ->
        manifest

      _ ->
        raise InvalidBundleError,
          code: "invalid_bundle",
          message:
            "bundle manifest.json is not decodable JSON object " <>
              "(#{byte_size(bundle)} bytes read)"
    end
  end
end
