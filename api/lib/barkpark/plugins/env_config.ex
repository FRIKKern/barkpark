defmodule Barkpark.Plugins.EnvConfig do
  @moduledoc """
  Translates the `BARKPARK_PLUGINS` OS environment variable into the value
  `runtime.exs` feeds to `config :barkpark, :plugins`.

  This is the runtime counterpart to `bp setup`'s plugin selection: whatever
  the operator picked lands in `.env` as `BARKPARK_PLUGINS=...`, and this
  helper maps that string onto the `:barkpark, :plugins` kill-switch the
  `Barkpark.Plugins.Registry` already understands.

  The kill-switch semantics are PRESERVED EXACTLY (see
  `Barkpark.Plugins.Registry.discover_and_register/0`):

    * env UNSET (`nil`)        -> `:unset`. Caller must NOT set `:plugins`,
      so the registry discovers every plugin from disk. This is the
      fresh-install / production default — do not collapse it to `[]`.
    * env empty string (`""`)  -> `[]`. The kill switch: register no plugins.
    * env `"bulldocs,onixedit"` -> `["bulldocs", "onixedit", "media"]`.
      Whitelist mode; each name is trimmed and blank entries are dropped.

  Whitelist mode implicitly unions `"media"`: media is a real registry plugin
  (priv/plugins/media) but the `bp setup` picker hides it as core, so an
  emitted whitelist never names it — and any whitelist that omits `media`
  would silently kill the media schemas. The kill switch stays truly empty.
  """

  @doc """
  Parse a raw `BARKPARK_PLUGINS` value.

  Returns `:unset` when the env var is absent (`nil`) — the signal for the
  caller to leave `:barkpark, :plugins` unconfigured. Otherwise returns the
  list `config :barkpark, :plugins` should receive (`[]` for the kill switch,
  or the trimmed, blank-stripped name list — with `"media"` unioned in — for
  whitelist mode).
  """
  @spec parse(String.t() | nil) :: :unset | [String.t()]
  def parse(nil), do: :unset

  def parse(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> union_media()
  end

  # Media is core-in-disguise: union it into every non-empty whitelist so an
  # operator (or bp) listing plugins never silently disables the media
  # schemas. `[]` passes through untouched — the kill switch must stay empty.
  defp union_media([]), do: []
  defp union_media(names), do: if("media" in names, do: names, else: names ++ ["media"])
end
