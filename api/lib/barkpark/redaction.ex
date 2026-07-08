defmodule Barkpark.Redaction do
  @moduledoc """
  The ONE secret-scrubbing engine shared by every plugin error module.

  Recursively walks an arbitrary value (maps, keyword/plain lists, JSON-looking
  binaries) and replaces the VALUES under sensitive keys with `"[REDACTED]"`, so
  bearer tokens and OAuth2 secrets never reach `inspect/1`, `Logger.error/1`, or
  an ExUnit failure dump.

  The allowlists are parameters, NOT constants — each caller passes its own:

    * `header_keys` — keys treated as HTTP header names (checked alongside
      `json_keys` when redacting a `{key, value}` pair inside a map/keyword list).
    * `json_keys` — keys treated as JSON body keys. Used BOTH in the pair check
      AND for the best-effort regex scrub of JSON-looking strings (headers are
      never present as raw strings, so `redact_binary/2` uses `json_keys` only).

  This is the extracted, single-owner successor to the three character-identical
  copies that lived in `Barkpark.Plugins.{Github,Indx,OnixEdit.Bokbasen}.Errors`.
  Each of those modules now delegates here, keeping ONLY its own allowlists.

  NOTE: this is transport/log secret redaction — distinct from
  `Barkpark.Content.Envelope`'s field-visibility redaction (name overlap only).
  """

  @doc """
  Recursively redact the VALUES under `header_keys` / `json_keys` out of `value`.

  Byte-faithful extraction of the former per-plugin engines; behaviour is
  identical given the same allowlists.
  """
  # @canonical capability:secret-redaction aka:scrub,REDACTED,sensitive-keys
  @spec redact(any(), [String.t()], [String.t()]) :: any()
  def redact(value, header_keys, json_keys) do
    do_redact(value, header_keys, json_keys)
  end

  defp do_redact(map, header_keys, json_keys) when is_map(map) and not is_struct(map) do
    Enum.into(map, %{}, fn {k, v} -> {k, redact_pair(k, v, header_keys, json_keys)} end)
  end

  defp do_redact(list, header_keys, json_keys) when is_list(list) do
    Enum.map(list, fn
      {k, v} -> {k, redact_pair(k, v, header_keys, json_keys)}
      other -> do_redact(other, header_keys, json_keys)
    end)
  end

  defp do_redact(bin, _header_keys, json_keys) when is_binary(bin),
    do: redact_binary(bin, json_keys)

  defp do_redact(other, _header_keys, _json_keys), do: other

  defp redact_pair(k, v, header_keys, json_keys) when is_binary(k) do
    cond do
      k in header_keys -> "[REDACTED]"
      k in json_keys -> "[REDACTED]"
      true -> do_redact(v, header_keys, json_keys)
    end
  end

  defp redact_pair(k, v, header_keys, json_keys) when is_atom(k) do
    redact_pair(Atom.to_string(k), v, header_keys, json_keys)
  end

  defp redact_pair(_k, v, header_keys, json_keys), do: do_redact(v, header_keys, json_keys)

  # Best-effort scrub of JSON-looking strings — replace any
  # `"<sensitive_key>":"..."` pair with `"<sensitive_key>":"[REDACTED]"`.
  defp redact_binary(bin, json_keys) do
    Enum.reduce(json_keys, bin, fn key, acc ->
      Regex.replace(
        ~r/("#{Regex.escape(key)}"\s*:\s*)"[^"]*"/,
        acc,
        "\\1\"[REDACTED]\""
      )
    end)
  end
end
