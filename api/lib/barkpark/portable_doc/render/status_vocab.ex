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
  """

  # render/ -> ../../../../../design/status-manifest.json  (repo root)
  @manifest_path Path.expand("../../../../../design/status-manifest.json", __DIR__)
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> Jason.decode!()

  @statuses @manifest["statuses"]
  @default_role @manifest["default_role"]
  @roles @manifest["roles"]
  @tones @manifest["tones"]

  # role -> glyph char / spinner? / label / meaning, precomputed at compile time.
  @glyph_by_role Map.new(@roles, fn r -> {r["role"], r["glyph"]} end)
  @spinner_by_role Map.new(@roles, fn r -> {r["role"], r["spinner"] == true} end)
  @label_by_role Map.new(@roles, fn r -> {r["role"], r["label"]} end)
  @meaning_by_role Map.new(@roles, fn r -> {r["role"], r["meaning"]} end)
  @role_names Enum.map(@roles, & &1["role"])

  # @canonical capability:status-vocabulary aka:glyph,white-ladder,status-role,task-status doc:design/status-manifest.json
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

  @doc "The canonical lowercase display label for a role (e.g. \"in progress\")."
  @spec label_for_role(String.t()) :: String.t()
  def label_for_role(role),
    do: Map.get(@label_by_role, role, Map.fetch!(@label_by_role, @default_role))

  @doc "The one-line meaning (the legend gloss) for a role."
  @spec meaning_for_role(String.t()) :: String.t()
  def meaning_for_role(role),
    do: Map.get(@meaning_by_role, role, Map.fetch!(@meaning_by_role, @default_role))

  @doc "The ordered list of role names (the ladder rungs)."
  @spec roles() :: [String.t()]
  def roles, do: @role_names

  # The terminal, non-claimable rung. Named once so the board derivation below
  # reads as a RULE ("move the terminal rung last") and not as a second list.
  @cancel_role "cancel"

  # The board's lane roles: EVERY manifest rung, in manifest order, with `cancel`
  # moved to the END. Derived from @role_names — the manifest's roles[] — so a new
  # rung added to design/status-manifest.json becomes a lane automatically and can
  # never be silently DROPPED from a board again (task-881952f8d8417f4b's ruling).
  @board_roles Enum.reject(@role_names, &(&1 == @cancel_role)) ++
                 Enum.filter(@role_names, &(&1 == @cancel_role))

  @doc """
  The board lane roles: the manifest ladder with the terminal `cancel` rung LAST.

  This is the ONE place the board's lane order is computed. Every board surface
  that renders in Elixir (`Components.task_board_html/1`,
  `FleetEmail.task_board_email_html/2`, and the golden-parity projection)
  resolves its columns through here, so no surface holds a retyped copy and no
  surface can drop a rung.

  `cancel` is a lane, not a drop and not a fold into `open`: dropping it makes an
  abandoned row vanish with no symptom, and homing it in `open` — the CLAIMABLE
  lane that `bp task ready` serves — manufactures phantom ready work. It renders
  last and de-emphasised (`.bp-board__col--cancel`) carrying the manifest's ✕.
  """
  @spec board_roles() :: [String.t()]
  def board_roles, do: @board_roles

  @doc "The status→role map (raw manifest section)."
  @spec statuses() :: %{optional(String.t()) => String.t()}
  def statuses, do: @statuses

  @doc "The semantic tone → %{\"light\" => hex, \"dark\" => hex} map (raw manifest section)."
  @spec tones() :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}
  def tones, do: @tones
end
