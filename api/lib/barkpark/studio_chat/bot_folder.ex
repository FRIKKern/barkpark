defmodule Barkpark.StudioChat.BotFolder do
  @moduledoc """
  The bot folder of a registered-host chat session (task-ed93b8c0ab2b44b8,
  Paper barkbot-many-bots-plan): several bots share one computer, and each new
  bot works in its own folder under the host's approved root.

  The folder is a NAME, never a path. It is one segment matching
  `^[a-z0-9][a-z0-9-]{0,39}$`: 1 to 40 characters of lower-case ASCII letters,
  digits and dashes, not starting with a dash. No dot, slash, backslash,
  upper case, unicode, space or control character can match, so `..`, `a/b`,
  `.barkpark` and an absolute path are refused by construction. The server never
  joins it onto a path. A send_turn lease carries it as `payload.bot_folder`,
  next to `payload.cwd` (the host's first approved root, exactly as for a
  session with no folder), and the host checks it again and works in
  `{root}/{bot_folder}`.

  A session with no folder sends no `bot_folder` key at all, so its turns are
  byte-for-byte what they were: claude keeps a session's history under a folder
  named for its cwd, and a moved cwd would lose `--resume`.

  Every host enrolled before this change ignores a payload key it does not know
  and would run the turn in the shared root. So a turn carrying a folder is
  leased only to a host whose stored capabilities say
  `providers.<provider>.bot_folders == true` (`admit/3`); any other host gets
  `{:error, {:host_cannot_use_bot_folder, provider}}` and nothing is leased.
  """

  # \A and \z, not ^ and $: in PCRE `$` also matches before a final newline,
  # so `"bot\n"` would pass a `$` anchor.
  @pattern ~r/\A[a-z0-9][a-z0-9-]{0,39}\z/

  @doc "The rule as a Postgres/Go-compatible regex source (the migration's CHECK uses it)."
  def pattern_source, do: "^[a-z0-9][a-z0-9-]{0,39}$"

  @doc "True when `value` is a bot folder name."
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value), do: Regex.match?(@pattern, value)
  def valid?(_), do: false

  @doc """
  The stored bot folder of session `id`, or nil. The Recorder reads it when it
  opens a runtime, so no caller of `Recorder.ensure/1` has to carry it.
  """
  @spec of_session(String.t()) :: String.t() | nil
  def of_session(id) do
    case Barkpark.StudioChat.get_session(id) do
      %{bot_folder: folder} when is_binary(folder) -> folder
      _ -> nil
    end
  end

  @doc """
  Whether `host` may be leased `command`. Only a send_turn whose payload names a
  `bot_folder` is checked; everything else is admitted unchanged.
  """
  @spec admit(map(), String.t() | atom(), map()) ::
          :ok | {:error, {:host_cannot_use_bot_folder, String.t()}}
  def admit(host, provider, %{operation: :send_turn, payload: %{bot_folder: folder}}) do
    provider = to_string(provider)

    if valid?(folder) and advertised?(host, provider),
      do: :ok,
      else: {:error, {:host_cannot_use_bot_folder, provider}}
  end

  def admit(_host, _provider, _command), do: :ok

  # Fails closed: a missing or malformed capability reads as "no folders".
  # Stored capabilities are string-keyed JSON; in-memory test hosts use atoms.
  defp advertised?(host, provider) do
    with caps when is_map(caps) <- field(host, "capabilities", :capabilities),
         providers when is_map(providers) <- field(caps, "providers", :providers),
         meta when is_map(meta) <-
           Enum.find_value(providers, fn {name, m} -> if to_string(name) == provider, do: m end) do
      field(meta, "bot_folders", :bot_folders) == true
    else
      _ -> false
    end
  end

  defp field(map, string_key, atom_key), do: Map.get(map, string_key, Map.get(map, atom_key))
end
