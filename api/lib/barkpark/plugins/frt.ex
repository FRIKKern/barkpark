defmodule Barkpark.Plugins.Frt do
  @moduledoc """
  Frickin Real Time — an author-first content model whose document types
  mirror the Godot game's structure.

  The 25 schemas under `priv/plugins/frt/schemas/` describe the game's
  building blocks (the frame/time loop, the player, combat, enemies, the
  run, progression, game-feel, the world). The desk groups are ordered to
  follow `coordinator.gd`'s tick loop, so browsing the Studio top-to-bottom
  teaches how a frame of the game is assembled.

  Like the OnixEdit plugin, the manifest at
  `priv/plugins/frt/plugin.json` is read and validated at compile time by
  `Barkpark.Plugin.__using__/1` (decision D7 — no runtime eval). Each schema
  JSON is loaded, parsed once for a loud failure on malformed shape, and
  registered via `register_schemas/1`.

  ## Desk structure (mirrors `coordinator.gd`)

  Eight `:nested` groups, in tick order. Each group mixes `:link` rows for
  **singletons** (one canonical document — the link opens it directly at
  `/studio/<dataset>/<typeName>`) with `:document_list` rows for
  **collections** (many documents of a type).

    1. ① Frame & Time   — coordinatorLoop·, gameClock·, timeState
    2. ② Player          — player·, ability, cameraPreset
    3. ③ Combat          — weapon·, projectileType
    4. ④ Enemies         — enemyType, bossType, bossAbility
    5. ⑤ The Run         — runRuleset·, waveTemplate, spreeTier, scalingCurve
    6. ⑥ Progression     — playerStat, upgradeCard, rune, pickup
    7. ⑦ Game Feel       — sound, vfx, hudElement, overlay
    8. ⑧ World           — arena·, theme·

  (· marks a singleton.)

  All 25 schemas are `visibility: "private"`. Because the host's
  `Barkpark.Structure.build_settings_group/2` collects every private schema
  into a "Settings" group, the frt types must be excluded there — otherwise
  they would render twice (once in our 8 groups, once under Settings). The host
  harvests plugin schema ownership generically via `owned_schema_types/0`
  (below), so no per-plugin host edit is needed.
  """

  use Barkpark.Plugin,
    manifest_path: "../../../priv/plugins/frt/plugin.json"

  # Installed but OFF by default — surfaced under the "Plugins" node only when
  # an admin enables it for the workspace.
  @impl Barkpark.Plugin
  def default_enabled?, do: false

  alias Barkpark.Content.SchemaDefinition

  @plugin_name "frt"
  # Resolved at RUNTIME, deliberately not frozen into an attribute.
  # `Application.app_dir/2` finds priv under BOTH deploy models: the source-tree
  # one (Barkpark compiles + runs in place under /opt/barkpark, where Mix
  # symlinks _build/<env>/lib/barkpark/priv at ./priv) and an OTP release, where
  # priv lives at lib/barkpark-<vsn>/priv. The previous
  # `Path.expand("../../../priv/...", __DIR__)` attribute served only the first:
  # it froze the BUILD machine's absolute path, so every released build raised
  # File.Error enoent here and this plugin's schemas never registered.
  # Precedent: the plugin loader already resolves priv this way — see
  # registry/discovery.ex default_paths/0.
  @schemas_subdir "priv/plugins/frt/schemas"
  defp schemas_dir, do: Application.app_dir(:barkpark, @schemas_subdir)

  # Snake-cased file stem → registered schema `name`. Single source of truth
  # for both `register_schemas/1` (which file to load) and the manifest. Kept
  # in the same tick order the desk groups use so the two never drift.
  @schema_files [
    {"coordinator_loop", "coordinatorLoop"},
    {"game_clock", "gameClock"},
    {"time_state", "timeState"},
    {"player", "player"},
    {"ability", "ability"},
    {"camera_preset", "cameraPreset"},
    {"weapon", "weapon"},
    {"projectile_type", "projectileType"},
    {"enemy_type", "enemyType"},
    {"boss_type", "bossType"},
    {"boss_ability", "bossAbility"},
    {"run_ruleset", "runRuleset"},
    {"wave_template", "waveTemplate"},
    {"spree_tier", "spreeTier"},
    {"scaling_curve", "scalingCurve"},
    {"player_stat", "playerStat"},
    {"upgrade_card", "upgradeCard"},
    {"rune", "rune"},
    {"pickup", "pickup"},
    {"sound", "sound"},
    {"vfx", "vfx"},
    {"hud_element", "hudElement"},
    {"overlay", "overlay"},
    {"arena", "arena"},
    {"theme", "theme"}
  ]

  @doc """
  Returns the plugin's discriminator name (D20).
  """
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc """
  The set of schema `name`s this plugin owns. Exposed so the host's Desk
  Structure builder can exclude frt-owned private schemas from the "Settings"
  group (they render via `desk_items/1` instead). Also the source of
  `owned_schema_types/0`'s override — cheap compile-time list, no re-parse.
  """
  @spec schema_names() :: [String.t()]
  def schema_names, do: Enum.map(@schema_files, fn {_file, name} -> name end)

  # Override the harvest default (which would re-parse all 25 schema JSON files
  # per desk build via register_schemas/1) with the compile-time name list.
  @impl Barkpark.Plugin
  def owned_schema_types, do: schema_names()

  @impl Barkpark.Plugin
  def register_schemas(_opts) do
    Enum.map(@schema_files, fn {file, _name} ->
      raw = load_schema!(file)

      # Force a parse round-trip up front (with `plugin: "frt"` so any
      # `plugin:frt:<field>` private fields are allowed). We discard the
      # parsed value — we persist the raw, string-keyed map — but want the
      # SAME loud failure as OnixEdit if a schema JSON is malformed.
      _parsed = parse_schema!(raw, file)

      %SchemaDefinition{
        name: Map.get(raw, "name"),
        title: Map.get(raw, "title"),
        icon: Map.get(raw, "icon"),
        visibility: Map.get(raw, "visibility", "private"),
        fields: Map.get(raw, "fields", []),
        groups: Map.get(raw, "groups", []),
        desk_groups: Map.get(raw, "deskGroups", []),
        initial_values: Map.get(raw, "initial_values", %{}),
        cross_validations: Map.get(raw, "cross_validations", []),
        dataset: "production"
      }
    end)
  end

  # Reads <stem>.json from the schemas dir and decodes it to a string-keyed
  # map. Raises loudly (File.read! / Jason.decode!) if the file is missing or
  # not valid JSON — we want that surfaced at first use, not at request time.
  @spec load_schema!(String.t()) :: map()
  defp load_schema!(file) do
    schemas_dir()
    |> Path.join(file <> ".json")
    |> File.read!()
    |> Jason.decode!()
  end

  @spec parse_schema!(map(), String.t()) :: SchemaDefinition.Parsed.t()
  defp parse_schema!(raw, file) do
    case SchemaDefinition.parse(raw, plugin: @plugin_name) do
      {:ok, parsed} ->
        parsed

      {:error, reason} ->
        raise "frt schema #{file}.json failed to parse: #{inspect(reason)}"
    end
  end

  @doc """
  Plugin-contributed desk items — eight `:nested` groups appended after the
  host's auto-generated schema items in the root Structure pane. The order
  mirrors `coordinator.gd`'s tick loop (see the module doc).

  Singletons render as `:link` rows whose path opens the single canonical
  document directly (`/studio/<dataset>/<typeName>`); collections render as
  `:document_list` rows. The host PaneBuilder dispatches both shapes.
  """
  @impl Barkpark.Plugin
  def desk_items(dataset) do
    [
      nested("① Frame & Time", "history", [
        singleton_link(dataset, "coordinatorLoop", "Coordinator Loop", "refresh-cw"),
        singleton_link(dataset, "gameClock", "Game Clock", "history"),
        doc_list("timeState", "Time States", "moon")
      ]),
      nested("② Player", "user", [
        singleton_link(dataset, "player", "Player", "user"),
        doc_list("ability", "Abilities", "activity"),
        doc_list("cameraPreset", "Camera Presets", "eye")
      ]),
      nested("③ Combat", "send", [
        singleton_link(dataset, "weapon", "Weapon", "send"),
        doc_list("projectileType", "Projectile Types", "send")
      ]),
      nested("④ Enemies", "users", [
        doc_list("enemyType", "Enemy Types", "users"),
        doc_list("bossType", "Boss Types", "user"),
        doc_list("bossAbility", "Boss Abilities", "activity")
      ]),
      nested("⑤ The Run", "compass", [
        singleton_link(dataset, "runRuleset", "Run Ruleset", "compass"),
        doc_list("waveTemplate", "Wave Templates", "layout-list"),
        doc_list("spreeTier", "Spree Tiers", "check-circle"),
        doc_list("scalingCurve", "Scaling Curves", "git-compare")
      ]),
      nested("⑥ Progression", "activity", [
        doc_list("playerStat", "Player Stats", "settings"),
        doc_list("upgradeCard", "Upgrade Cards", "layout-list"),
        doc_list("rune", "Runes", "package"),
        doc_list("pickup", "Pickups", "download")
      ]),
      nested("⑦ Game Feel", "palette", [
        doc_list("sound", "Sounds", "megaphone"),
        doc_list("vfx", "VFX", "image"),
        doc_list("hudElement", "HUD Elements", "panel-right-open"),
        doc_list("overlay", "Overlays", "eye")
      ]),
      nested("⑧ World", "home", [
        singleton_link(dataset, "arena", "Arena", "home"),
        singleton_link(dataset, "theme", "Theme", "palette")
      ])
    ]
  end

  # ── desk_item builders ───────────────────────────────────────────────────

  defp nested(label, icon, items) do
    %{type: :nested, label: label, icon: icon, items: items}
  end

  # A collection: opens the host's regular doc-list pane for the type.
  defp doc_list(type_name, label, icon) do
    %{type: :document_list, label: label, doc_type: type_name, icon: icon}
  end

  # A singleton: a link straight to the single canonical document. The host
  # PaneBuilder opens `/studio/<dataset>/<typeName>` in the editor pane.
  # Deliberately FLAT — desk items carry no scope knowledge. PaneBuilder
  # canonicalises it to the /d/ shape at source (Paths.plugin_link_href/2).
  defp singleton_link(dataset, type_name, label, icon) do
    %{
      type: :link,
      label: label,
      icon: icon,
      path: "/studio/" <> dataset <> "/" <> type_name
    }
  end
end
