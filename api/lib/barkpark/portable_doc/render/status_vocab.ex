defmodule Barkpark.PortableDoc.Render.StatusVocab do
  @moduledoc """
  The task status vocabulary — the white ladder — read from the ONE source of
  truth, `design/status-manifest.json` (repo root), at COMPILE time.

  This module is the reason the Elixir paper emitters cannot drift from the
  manifest: `role_for_status/1`, `glyph_for_role/1`, and `spinner?/1` all resolve
  straight out of the inlined manifest, so a status→glyph or status→role edit is
  a one-file change here and there is no second copy to keep in sync.

  Sibling surfaces (the `--st-*` CSS tone tokens, and later Go pdrender + web)
  derive from the SAME file via `scripts/status-manifest-check.sh`, which
  regenerates the CSS tone block and gates every surface against this manifest.

  `@external_resource` on the manifest means editing it recompiles this module.

  @canonical capability:status-vocabulary aka:glyph,white-ladder,status-role,task-status doc:design/status-manifest.json
  """

  # render/ -> ../../../../../design/status-manifest.json  (repo root)
  @manifest_path Path.expand("../../../../../design/status-manifest.json", __DIR__)
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> Jason.decode!()

  @statuses @manifest["statuses"]
  @default_role @manifest["default_role"]
  @roles @manifest["roles"]
  @tones @manifest["tones"]

  # role -> glyph char / spinner?, precomputed from the manifest at compile time.
  @glyph_by_role Map.new(@roles, fn r -> {r["role"], r["glyph"]} end)
  @spinner_by_role Map.new(@roles, fn r -> {r["role"], r["spinner"] == true} end)
  @role_names Enum.map(@roles, & &1["role"])

  @doc "Map a stored (or derived) lifecycle status to its ladder role."
  @spec role_for_status(String.t()) :: String.t()
  def role_for_status(status) when is_binary(status),
    do: Map.get(@statuses, status, @default_role)

  def role_for_status(_), do: @default_role

  @doc "The glyph character for a role (\"\" for a spinner role — the CSS animates it)."
  @spec glyph_for_role(String.t()) :: String.t()
  def glyph_for_role(role),
    do: Map.get(@glyph_by_role, role, Map.fetch!(@glyph_by_role, @default_role))

  @doc "True when the role renders as the animated (Braille) spinner, not a static glyph."
  @spec spinner?(String.t()) :: boolean()
  def spinner?(role), do: Map.get(@spinner_by_role, role, false)

  @doc "The ordered list of role names (the ladder rungs)."
  @spec roles() :: [String.t()]
  def roles, do: @role_names

  @doc "The status→role map (raw manifest section)."
  @spec statuses() :: %{optional(String.t()) => String.t()}
  def statuses, do: @statuses

  @doc "The semantic tone → %{\"light\" => hex, \"dark\" => hex} map (raw manifest section)."
  @spec tones() :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}
  def tones, do: @tones
end
