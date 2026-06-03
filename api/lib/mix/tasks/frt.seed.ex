defmodule Mix.Tasks.Frt.Seed do
  @moduledoc """
  Seed the `frt` (Frickin Real Time) dataset with its schema catalogue and a
  set of published documents carrying the REAL game values from the Godot port.

  This is the demo / content-population sibling of `priv/repo/seeds.exs`: it
  materialises the `frt` dataset, registers the 25 frt schemas INTO that
  dataset (the plugin bootstrap only registers them into `"production"`), then
  inserts ~45 published documents whose `content` maps mirror the live game
  tables (`godot/swarm/enemy_types.gd`, `godot/boss/boss_types.gd`,
  `godot/autoload/game_clock.gd`, `godot/combat/bonus_manager.gd`,
  `godot/autoload/player_stats.gd`, etc.).

  ## Identity convention

    * Singletons (one canonical document — `coordinatorLoop`, `gameClock`,
      `player`, `weapon`, `runRuleset`, `arena`, `theme`) use `doc_id ==
      typeName`.
    * Collections use `doc_id == "<type>_<slug>"` (e.g. `enemyType_grunt`).

  ## Idempotency

  Every insert is `on_conflict: :nothing`, keyed on the `(name, dataset_id)`
  unique for schemas and `(doc_id, type, dataset_id)` unique for documents, so
  a re-run is a no-op. The dataset is get-or-created, never duplicated.

  ## Usage

      mix frt.seed

  Prints the schema + document counts on completion.
  """
  @shortdoc "Seed the frt dataset with schemas + published game-value documents"

  use Mix.Task

  alias Barkpark.Repo
  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Plugins.Frt
  alias Barkpark.Tenancy

  @dataset "frt"

  @impl Mix.Task
  def run(_args) do
    # Boot the app so the Repo, the plugin registry, and the tenancy tables are
    # all live — same precondition `mix run priv/repo/seeds.exs` relies on.
    Mix.Task.run("app.start")

    # ── 1. Resolve the tenancy scope + materialise the "frt" dataset ──────────
    #
    # Datasets are NOT implicit string-only here: the read path filters
    # `WHERE dataset_id = <id>` (Content.scope_to_dataset), so a seeded row left
    # with dataset_id = NULL is invisible to every scoped read. Mirror
    # seeds.exs: resolve the Default workspace/project, then get-or-create the
    # `frt` dataset ROW under that project to obtain the authoritative
    # dataset_id, and stamp workspace_id/project_id/dataset_id onto every row.
    {ws_id, project_id, dataset_id} = resolve_scope!()

    IO.puts(
      "frt scope: workspace=#{inspect(ws_id)} project=#{inspect(project_id)} dataset_id=#{inspect(dataset_id)}"
    )

    # ── 2. Register the 25 frt schemas INTO the "frt" dataset ─────────────────
    #
    # Frt.register_schemas/1 emits %SchemaDefinition{} structs hardcoded to
    # dataset: "production" (the plugin bootstrap target). Override the dataset
    # to "frt" + stamp the tenancy scope, then insert via the SAME changeset +
    # on_conflict: :nothing path seeds.exs uses for its schema rows.
    schema_count = seed_schemas(ws_id, project_id, dataset_id)
    IO.puts("Seeded #{schema_count} frt schema definition(s) into dataset=#{@dataset}")

    # ── 3. Insert the published documents with real game values ───────────────
    doc_count = seed_documents(ws_id, project_id, dataset_id)
    IO.puts("Seeded #{doc_count} published frt document(s) into dataset=#{@dataset}")
  end

  # ── Scope resolution ────────────────────────────────────────────────────────

  # Resolve {workspace_id, project_id, dataset_id} for the "frt" dataset.
  # Reuses the seeded Default workspace/project (created by the w1-s4 backfill /
  # priv/repo/seeds.exs), get-or-creating each only if missing so this task can
  # run standalone against a fresh DB. The dataset ROW is get-or-created under
  # the project to obtain the authoritative dataset_id.
  defp resolve_scope! do
    workspace =
      case Tenancy.get_default_workspace() do
        nil ->
          {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default Workspace"})
          ws

        ws ->
          ws
      end

    project =
      case Tenancy.get_default_project() do
        nil ->
          {:ok, project} =
            Tenancy.create_project(workspace, %{slug: "default", name: "Default Project"})

          project

        project ->
          project
      end

    {:ok, %Tenancy.Dataset{id: dataset_id}} =
      Tenancy.get_or_create_dataset(project.id, @dataset)

    {workspace.id, project.id, dataset_id}
  end

  # ── Schema registration ──────────────────────────────────────────────────────

  defp seed_schemas(ws_id, project_id, dataset_id) do
    schemas = Frt.register_schemas([])

    Enum.each(schemas, fn %SchemaDefinition{} = schema ->
      attrs =
        schema
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        # Override the plugin's hardcoded dataset: "production" with the frt
        # dataset, and clear any pre-set FK so the changeset cast below is the
        # single source of the scope (matches seeds.exs's stamp-on-insert).
        |> Map.put(:dataset, @dataset)
        |> Map.drop([
          :workspace_id,
          :project_id,
          :dataset_id,
          :dataset_entity,
          :workspace,
          :project
        ])

      %SchemaDefinition{}
      |> SchemaDefinition.changeset(attrs)
      |> Ecto.Changeset.put_change(:workspace_id, ws_id)
      |> Ecto.Changeset.put_change(:project_id, project_id)
      |> Ecto.Changeset.put_change(:dataset_id, dataset_id)
      |> Repo.insert!(on_conflict: :nothing)
    end)

    length(schemas)
  end

  # ── Documents ──────────────────────────────────────────────────────────────

  defp seed_documents(ws_id, project_id, dataset_id) do
    documents = documents()

    Enum.each(documents, fn doc ->
      attrs =
        doc
        |> Map.put(:dataset, @dataset)
        |> Map.put(:status, "published")
        |> Map.put(:rev, random_rev())
        |> Map.put(:workspace_id, ws_id)
        |> Map.put(:project_id, project_id)
        |> Map.put(:dataset_id, dataset_id)

      %Document{}
      |> Document.changeset(attrs)
      |> Repo.insert!(on_conflict: :nothing)
    end)

    length(documents)
  end

  defp random_rev, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  # A singleton document: doc_id == typeName.
  defp singleton(type, title, content) do
    %{doc_id: type, type: type, title: title, content: content}
  end

  # A collection member: doc_id == "<type>_<slug>".
  defp item(type, slug, title, content) do
    %{
      doc_id: "#{type}_#{slug}",
      type: type,
      title: title,
      content: Map.put(content, "slug", slug)
    }
  end

  # The full corpus. All values are taken from the Godot port source files named
  # in the schema field descriptions (enemy_types.gd, boss_types.gd,
  # game_clock.gd, bonus_manager.gd, player_stats.gd, combat.gd, camera_rig.gd,
  # nagrand_arena.gd, projectile_types.gd, wave_manager.gd).
  defp documents do
    List.flatten([
      frame_and_time(),
      player_group(),
      combat_group(),
      enemies_group(),
      the_run_group(),
      progression_group(),
      upgrade_cards(),
      world_group(),
      game_feel_group()
    ])
  end

  # ① Frame & Time — coordinatorLoop (singleton), gameClock (singleton),
  # 7 timeStates.
  defp frame_and_time do
    [
      singleton("coordinatorLoop", "Coordinator per-frame loop", %{
        "title" => "Coordinator per-frame loop",
        "steps" => [
          %{"order" => "1", "system" => "GameClock.tick", "tickChannel" => "real_dt"},
          %{"order" => "2", "system" => "world (_update_world)", "tickChannel" => "physics_dt"},
          %{
            "order" => "3",
            "system" => "player + camera + combat",
            "tickChannel" => "physics_dt"
          },
          %{"order" => "4", "system" => "camera post-combat flush", "tickChannel" => "real_dt"},
          %{"order" => "5", "system" => "waves + audio", "tickChannel" => "real_dt"},
          %{
            "order" => "6",
            "system" => "swarm (advance_and_upload)",
            "tickChannel" => "enemy_dt"
          },
          %{"order" => "7", "system" => "missiles", "tickChannel" => "physics_dt"},
          %{"order" => "8", "system" => "bosses", "tickChannel" => "physics_dt"},
          %{"order" => "9", "system" => "crystals", "tickChannel" => "real_dt"},
          %{
            "order" => "10",
            "system" => "effects + explosions flush",
            "tickChannel" => "real_dt"
          },
          %{"order" => "11", "system" => "hud", "tickChannel" => "real_dt"}
        ]
      }),
      singleton("gameClock", "GameClock", %{
        "title" => "GameClock",
        "gameSpeed" => "1.2",
        "slowMoScale" => "0.25",
        "channels" => [
          %{"name" => "real_dt", "scaledBy" => "none — raw clamped wall-clock delta"},
          %{"name" => "player_dt", "scaledBy" => "real_dt * slow_motion_scale * (0.01 if dead)"},
          %{"name" => "physics_dt", "scaledBy" => "player_dt * game_speed (1.2)"},
          %{"name" => "enemy_dt", "scaledBy" => "physics_dt, hard-gated to 0.0 when frozen"}
        ]
      }),
      time_state("normal", "NORMAL", "1.0", "1.2", "1.2", false, "0", "8.0", "8.0"),
      time_state("slow_mo", "SLOW_MO", "0.25", "0.3", "0.3", false, "0", "8.0", "8.0"),
      time_state("frozen", "FROZEN", "1.0", "1.2", "0.0", true, "0", "8.0", "8.0"),
      time_state("hit_stop", "HIT_STOP", "0.0", "0.0", "0.0", false, "0.06", "0.0", "0.0"),
      time_state("death", "DEATH", "0.01", "0.012", "0.012", false, "0", "8.0", "8.0"),
      time_state("focus_dash", "FOCUS_DASH", "0.25", "0.3", "0.3", false, "0.5", "8.0", "8.0"),
      time_state(
        "celebration_slow_mo",
        "CELEBRATION_SLOW_MO",
        "0.25",
        "0.3",
        "0.3",
        false,
        "3.0",
        "8.0",
        "8.0"
      )
    ]
  end

  defp time_state(
         slug,
         title,
         player_scale,
         physics_scale,
         enemy_scale,
         freeze,
         dur,
         ease_in,
         ease_out
       ) do
    item("timeState", slug, title, %{
      "title" => title,
      "playerScale" => player_scale,
      "physicsScale" => physics_scale,
      "enemyScale" => enemy_scale,
      "freezeEnemies" => freeze,
      "duration" => dur,
      "easeIn" => ease_in,
      "easeOut" => ease_out
    })
  end

  # ② Player — player (singleton), 7 abilities, 3 cameraPresets.
  defp player_group do
    [
      singleton("player", "Player", %{
        "title" => "Player",
        "walkSpeed" => "6.5",
        "turboMult" => "2.0",
        "jumpImpulse" => "5.0",
        "stamina" => %{"max" => "4", "costPerDash" => "1.0", "regenPerSec" => "0.05263"}
      }),
      # 7 abilities (player.gd cost/duration consts + camera_rig.gd FOV deltas).
      ability(
        "focus-dash",
        "Focus Dash",
        "dash",
        "movement",
        "1.0",
        "0",
        "0",
        "4.0",
        "0",
        "0.40",
        "0.5",
        "focus_dash"
      ),
      ability(
        "slide",
        "Slide",
        "slide",
        "movement",
        "1.0",
        "0",
        "0",
        "2.0",
        "15",
        "0.25",
        "0",
        nil
      ),
      ability(
        "bullet-time",
        "Bullet Time",
        "aim",
        "timeControl",
        "1.0",
        "0",
        "0",
        "1.0",
        "-10",
        "0",
        "0",
        "slow_mo"
      ),
      ability("kick", "Kick", "kick", "combat", "1.0", "0.6", "0", "1.0", "0", "0", "0", nil),
      ability("jump", "Jump", "jump", "movement", "0", "0", "0", "1.0", "0", "0", "0", nil),
      ability(
        "super-jump",
        "Super Jump",
        "jump",
        "movement",
        "1.0",
        "0",
        "0",
        "1.0",
        "0",
        "0",
        "3.0",
        "slow_mo"
      ),
      ability(
        "grenade",
        "Grenade",
        "grenade",
        "combat",
        "0",
        "0",
        "3",
        "1.0",
        "0",
        "0",
        "0",
        nil
      ),
      # 3 camera presets (camera_rig.gd SHOULDER_OFFSET / DISTANCE / FOV_BASE).
      camera_preset("right-shoulder", "Right shoulder", "0.6", "3.0", "75", "1.0"),
      camera_preset("left-shoulder", "Left shoulder", "-0.6", "3.0", "75", "1.0"),
      camera_preset("wide", "Wide", "0.6", "4.5", "75", "1.0")
    ]
  end

  defp ability(
         slug,
         title,
         input,
         kind,
         stamina,
         cooldown,
         count,
         speed_mult,
         fov_delta,
         dmg_bonus,
         dur,
         time_state
       ) do
    content = %{
      "title" => title,
      "inputAction" => input,
      "kind" => kind,
      "cost" => %{"stamina" => stamina, "cooldown" => cooldown, "count" => count},
      "speedMult" => speed_mult,
      "fovDelta" => fov_delta,
      "damageBonus" => dmg_bonus,
      "duration" => dur
    }

    content =
      if time_state,
        do: Map.put(content, "usesTimeState", "timeState_#{time_state}"),
        else: content

    item("ability", slug, title, content)
  end

  defp camera_preset(slug, title, shoulder, distance, fov, sens) do
    item("cameraPreset", slug, title, %{
      "title" => title,
      "shoulderOffset" => shoulder,
      "distance" => distance,
      "fov" => fov,
      "sensitivityMult" => sens,
      "stances" => [
        %{"stance" => "right", "fovDelta" => "0", "distance" => "3.0"},
        %{"stance" => "left", "fovDelta" => "0", "distance" => "3.0"},
        %{"stance" => "wide", "fovDelta" => "0", "distance" => "4.5"}
      ]
    })
  end

  # ③ Combat — weapon (singleton), 3 projectileTypes.
  defp combat_group do
    [
      singleton("weapon", "Machine Gun", %{
        "title" => "Machine Gun",
        "fireMode" => "hitscan",
        "baseFireRate" => "0.089",
        "baseDamage" => "4.0",
        "maxRange" => "100.0",
        "headshotMult" => "4.0",
        "critMult" => "2.0",
        "critChance" => "0.25",
        "damageChain" => [
          "stat_dmg",
          "floor_dmg",
          "doomblaster",
          "slide",
          "dash",
          "headshot",
          "crit"
        ]
      }),
      # projectile_types.gd MISSILE_* / LASER_* + projectile_manager.gd PLAYER_HIT_RADIUS.
      item("projectileType", "missile", "Missile", %{
        "title" => "Missile",
        "kind" => "homing",
        "speed" => "28.0",
        "turnRate" => "1.4",
        "lifetime" => "7.0",
        "hitRadius" => "1.5",
        "damage" => "80.0",
        "destroyable" => true
      }),
      item("projectileType", "laser", "Laser", %{
        "title" => "Laser",
        "kind" => "straight",
        "speed" => "30.0",
        "turnRate" => "0",
        "lifetime" => "5.0",
        "hitRadius" => "1.5",
        "damage" => "80.0",
        "destroyable" => false
      }),
      item("projectileType", "thrown-grenade", "Thrown Grenade", %{
        "title" => "Thrown Grenade",
        "kind" => "lobbed",
        "speed" => "",
        "turnRate" => "0",
        "lifetime" => "3.0",
        "hitRadius" => "1.5",
        "damage" => "450.0",
        "destroyable" => false
      })
    ]
  end

  # ④ Enemies — 5 enemyTypes, 3 bossTypes, 4 bossAbilities. Values verbatim from
  # enemy_types.gd parallel const arrays + boss_types.gd.
  defp enemies_group do
    [
      # EnemyTypes HP / DMG / SPEED [GRUNT, RUNNER, ELITE, TNT, DIVEBOMBER].
      enemy_type("grunt", "GRUNT", "grunt", "120", "15", "5.5", "swoop"),
      enemy_type("runner", "RUNNER", "grunt", "50", "8", "14.0", "swoop"),
      enemy_type("elite", "ELITE", "elite", "400", "35", "7.0", "swoop"),
      enemy_type("tnt", "TNT", "bomber", "40", "80", "10.0", "contact"),
      enemy_type("divebomber", "DIVEBOMBER", "flyer", "60", "80", "10.0", "air-swoop"),
      # BossTypes HP / DMG + PRESTIGE [PRINCE, QUEEN, KING].
      boss_type("prince", "Prince", "1", "4200", "45", "70", false, [
        "bossAbility_missile-barrage",
        "bossAbility_laser-burst",
        "bossAbility_devour"
      ]),
      boss_type("queen", "Queen", "2", "6000", "60", "80", false, [
        "bossAbility_missile-barrage",
        "bossAbility_laser-burst",
        "bossAbility_summon-reinforcements",
        "bossAbility_devour"
      ]),
      boss_type("king", "King", "3", "15000", "100", "100", true, [
        "bossAbility_laser-burst",
        "bossAbility_missile-barrage",
        "bossAbility_summon-reinforcements",
        "bossAbility_devour"
      ]),
      # boss.gd cooldowns / counts / window durations (prince-tuned baselines).
      boss_ability(
        "missile-barrage",
        "Missile Barrage",
        "missileBarrage",
        "2.7",
        "4",
        "1.5",
        "projectileType_missile"
      ),
      boss_ability(
        "laser-burst",
        "Laser Burst",
        "laserBurst",
        "4.0",
        "1",
        "4.0",
        "projectileType_laser"
      ),
      boss_ability(
        "summon-reinforcements",
        "Summon Reinforcements",
        "summonReinforcements",
        "24.0",
        "30",
        "0",
        nil
      ),
      boss_ability("devour", "Devour", "devour", "60.0", "1", "10.0", nil)
    ]
  end

  defp enemy_type(slug, title, family, hp, dmg, speed, behavior) do
    item("enemyType", slug, title, %{
      "title" => title,
      "family" => family,
      "statBlock" => %{"baseHp" => hp, "baseDamage" => dmg, "moveSpeed" => speed},
      "behavior" => behavior,
      "contactBand" => %{"min" => "0", "max" => "2.5"},
      "scaling" => "scalingCurve_hp-per-floor"
    })
  end

  defp boss_type(slug, title, rank, hp, dmg, prestige, unlocks, abilities) do
    item("bossType", slug, title, %{
      "title" => title,
      "rank" => rank,
      "statBlock" => %{"hp" => hp, "damage" => dmg},
      "prestigeValue" => prestige,
      "spawnsOnWaves" => ["4", "7", "10"],
      "unlocksFloor" => unlocks,
      "telegraph" => %{"duration" => "0.5", "glow" => true, "scaleSwell" => false},
      "abilities" => abilities
    })
  end

  defp boss_ability(slug, title, kind, cooldown, count, cadence, projectile) do
    content = %{
      "title" => title,
      "kind" => kind,
      "cooldown" => cooldown,
      "count" => count,
      "cadence" => cadence
    }

    content = if projectile, do: Map.put(content, "projectile", projectile), else: content
    item("bossAbility", slug, title, content)
  end

  # ⑤ The Run — runRuleset (singleton), 3 waveTemplates, 5 spreeTiers, 3
  # scalingCurves.
  defp the_run_group do
    [
      singleton("runRuleset", "Default Run", %{
        "title" => "Default Run",
        "wavesPerFloor" => "10",
        "autoWaveInterval" => "20",
        "earlyClearDelay" => "2",
        "floorIntroDelay" => "4",
        "bossWaves" => ["4", "7", "10"],
        "bossSequence" => ["bossType_prince", "bossType_queen", "bossType_king"],
        "hpCurve" => "scalingCurve_hp-per-floor",
        "countCurve" => "scalingCurve_count-per-floor",
        "xpCurve" => "scalingCurve_xp-per-level"
      }),
      # WAVE_PERSONALITY_F1 rows (enemy_types.gd) — counts approximate the weight mix.
      wave_template("floor1-scout", "Floor 1 — Scout", "normal", [
        %{"enemyType" => "enemyType_grunt", "count" => "14"},
        %{"enemyType" => "enemyType_runner", "count" => "5"},
        %{"enemyType" => "enemyType_elite", "count" => "1"}
      ]),
      wave_template("floor1-skirmish", "Floor 1 — Skirmish", "normal", [
        %{"enemyType" => "enemyType_grunt", "count" => "9"},
        %{"enemyType" => "enemyType_runner", "count" => "5"},
        %{"enemyType" => "enemyType_elite", "count" => "3"},
        %{"enemyType" => "enemyType_tnt", "count" => "3"}
      ]),
      wave_template("floor1-bomber-gauntlet", "Floor 1 — Bomber Gauntlet", "normal", [
        %{"enemyType" => "enemyType_grunt", "count" => "6"},
        %{"enemyType" => "enemyType_runner", "count" => "3"},
        %{"enemyType" => "enemyType_elite", "count" => "4"},
        %{"enemyType" => "enemyType_tnt", "count" => "7"},
        %{"enemyType" => "enemyType_divebomber", "count" => "1"}
      ]),
      # bonus_manager.gd tier_name_for ladder + SPREE_MULTIPLIERS.
      spree_tier("bloodbath", "BLOODBATH", "5", "BLOODBATH", "1.5", "#ff4400"),
      spree_tier("killing-spree", "KILLING SPREE", "10", "KILLING SPREE", "1.5", "#ff8800"),
      spree_tier("rampage", "RAMPAGE", "15", "RAMPAGE", "2.0", "#ffcc00"),
      spree_tier("carnage", "CARNAGE", "25", "CARNAGE", "3.0", "#ff1100"),
      spree_tier("massacre", "MASSACRE", "50", "MASSACRE", "5.0", "#cc00ff"),
      # getFloorScaling HP 1.3 / count 1.2 (boss_types.gd FLOOR_HP_SCALING 1.3).
      scaling_curve("hp-per-floor", "HP per floor", "geometric", "1.0", "1.3"),
      scaling_curve("count-per-floor", "Count per floor", "geometric", "1.0", "1.2"),
      scaling_curve("xp-per-level", "XP per level", "geometric", "100", "1.15")
    ]
  end

  defp wave_template(slug, title, role, enemy_mix) do
    item("waveTemplate", slug, title, %{
      "title" => title,
      "role" => role,
      "enemyMix" => enemy_mix,
      "spawnRing" => %{"min" => "60", "max" => "110"}
    })
  end

  defp spree_tier(slug, title, threshold, label, xp_mult, color) do
    item("spreeTier", slug, title, %{
      "title" => title,
      "threshold" => threshold,
      "label" => label,
      "xpMult" => xp_mult,
      "color" => color
    })
  end

  defp scaling_curve(slug, title, kind, base, factor) do
    item("scalingCurve", slug, title, %{
      "title" => title,
      "kind" => kind,
      "base" => base,
      "factor" => factor
    })
  end

  # ⑥ Progression — 12 playerStats, 4 runes, 4 pickups. Values from
  # player_stats.gd STAT_RARITY / SPECIAL_CARDS / getters + bonus_manager.gd.
  defp progression_group do
    [
      # The 12 PlayerStats.stats keys + STAT_RARITY tiers.
      player_stat("damage", "Weapon Damage", "rare", "damage_multiplier", "0.20", "", "⚔️"),
      player_stat("crit", "Crit Chance", "common", "crit_chance", "", "0.20", "🎯"),
      player_stat(
        "attack_speed",
        "Attack Speed",
        "common",
        "attack_speed_multiplier",
        "0.15",
        "",
        "⏩"
      ),
      player_stat("lifesteal", "Lifesteal", "common", "lifesteal_fraction", "", "0.02", "🩸"),
      player_stat("explosion", "Explosion", "rare", "explosion_multiplier", "0.25", "", "💥"),
      player_stat("multitarget", "Multi-target", "rare", "extra_targets", "", "1", "🎯"),
      player_stat("slowmo", "Slow-mo", "rare", "slowmo_duration", "", "0.5", "🐌"),
      player_stat("max_hp", "Max HP", "rare", "max_health", "", "400", "❤️"),
      player_stat("speed", "Move Speed", "common", "move_speed_multiplier", "0.10", "", "🏃"),
      player_stat("blast_resist", "Blast Resist", "rare", "blast_resistance", "", "0.15", "🛡️"),
      player_stat("stamina", "Stamina", "common", "max_stamina", "", "1", "⚡"),
      player_stat("magnetic", "Magnetic", "common", "magnet_range_multiplier", "0.30", "", "🧲"),
      # SPECIAL_CARDS (player_stats.gd) — max_stacks + per-stack damage terms.
      rune(
        "doomblaster",
        "Doomblaster",
        "damage",
        true,
        "5",
        "0.005",
        "2.0",
        "slower fire rate trade-off"
      ),
      rune(
        "el_granados",
        "El Granados",
        "grenade",
        true,
        "5",
        "0.005",
        "0.20",
        "+20% damage & 2x pickup magnet range; spends Damage + Magnetic points"
      ),
      rune(
        "slideshow",
        "Slideshow",
        "slide",
        true,
        "3",
        "0.005",
        "0.10",
        "+10% damage while sliding"
      ),
      rune(
        "super_dash",
        "Super Dash",
        "dash",
        true,
        "3",
        "0.005",
        "0.10",
        "+10% damage while dashing"
      ),
      # progression managers — crystal/heart/grenade/rune drop rates + magnet ranges.
      pickup("crystal", "XP Crystal", "xp", "1.0", "12", "10"),
      pickup("heart", "Heart", "heal", "0.05", "20", "50"),
      pickup("grenade", "Grenade", "ammo", "0.05", "20", "1"),
      pickup("runeDrop", "Rune", "rune", "0.005", "0", "0")
    ]
  end

  defp player_stat(slug, title, rarity, target, mult, delta, icon) do
    item("playerStat", slug, title, %{
      "title" => title,
      "rarity" => rarity,
      "maxPoints" => "5",
      "perPointEffect" => %{"target" => target, "mult" => mult, "delta" => delta},
      "icon" => icon
    })
  end

  defp rune(slug, title, family, stackable, max_stacks, drop_rate, mult, note) do
    item("rune", slug, title, %{
      "title" => title,
      "family" => family,
      "stackable" => stackable,
      "maxStacks" => max_stacks,
      "dropRate" => drop_rate,
      "damageProfile" => %{"mult" => mult, "note" => note},
      "modifies" => "weapon"
    })
  end

  defp pickup(slug, title, kind, drop_rate, magnet_range, value) do
    item("pickup", slug, title, %{
      "title" => title,
      "kind" => kind,
      "dropRate" => drop_rate,
      "magnetRange" => magnet_range,
      "value" => value
    })
  end

  # ⑦ Upgrade cards — the 3-card level-up draw pool (player_stats.gd STAT_RARITY /
  # RARITY_WEIGHT + SPECIAL_CARDS). A plain stat card grants one playerStat point; a
  # SPECIAL power card stacks a rune. El Granados is the lone two-grant card — it spends
  # a Damage AND a Magnetic stat point (SPECIAL_CARDS comment: no BonusManager stack).
  #
  # `grants` references MUST point to doc_ids the seed actually creates: a stat grant
  # uses "playerStat_<slug>" and a rune grant uses "rune_<slug>" — the exact slugs the
  # progression group above seeds (player_stat/* + rune/*). The reference VALUE stored
  # is that doc_id string (the schema field is type:reference, refType playerStat/rune).
  defp upgrade_cards do
    [
      # Stat cards — rarity + weight from STAT_RARITY / RARITY_WEIGHT (common 4 / rare 2).
      stat_card("damage", "Weapon Damage", "+20% weapon damage per point.", "rare", "2"),
      stat_card("crit", "Crit Chance", "+20% crit chance per point.", "common", "4"),
      stat_card("attack_speed", "Attack Speed", "+15% fire rate per point.", "common", "4"),
      stat_card("explosion", "Explosion", "+25% explosion radius/damage per point.", "rare", "2"),
      stat_card("max_hp", "Max HP", "+400 max HP per point.", "rare", "2"),
      stat_card("speed", "Move Speed", "+10% move speed per point.", "common", "4"),
      stat_card("blast_resist", "Blast Resist", "+15% blast resistance per point.", "rare", "2"),
      stat_card("magnetic", "Magnetic", "+30% pickup magnet range per point.", "common", "4"),
      # SPECIAL power cards — always EPIC (weight 1), each stacks the matching rune.
      rune_card(
        "doomblaster",
        "Doomblaster",
        "+200% damage & explosive shots (slower fire)",
        "doomblaster"
      ),
      rune_card(
        "slideshow",
        "Slideshow",
        "Slide mastery: +10% damage while sliding",
        "slideshow"
      ),
      rune_card(
        "super_dash",
        "Super Dash",
        "Focus Dash mastery: +10% damage while dashing",
        "super_dash"
      ),
      # El Granados — the two-grant card: a Damage point AND a Magnetic point (no rune stack).
      item("upgradeCard", "el_granados", "El Granados", %{
        "title" => "El Granados",
        "description" => "+20% damage & 2x pickup magnet range",
        "rarity" => "epic",
        "weight" => "1",
        "grants" => [
          %{"kind" => "stat", "stat" => "playerStat_damage"},
          %{"kind" => "stat", "stat" => "playerStat_magnetic"}
        ]
      })
    ]
  end

  # A plain stat card: one grant allocating a point into playerStat_<slug>.
  defp stat_card(slug, title, desc, rarity, weight) do
    item("upgradeCard", slug, title, %{
      "title" => title,
      "description" => desc,
      "rarity" => rarity,
      "weight" => weight,
      "grants" => [%{"kind" => "stat", "stat" => "playerStat_#{slug}"}]
    })
  end

  # A SPECIAL power card: always epic (weight 1), one grant stacking rune_<rune_slug>.
  defp rune_card(slug, title, desc, rune_slug) do
    item("upgradeCard", slug, title, %{
      "title" => title,
      "description" => desc,
      "rarity" => "epic",
      "weight" => "1",
      "grants" => [%{"kind" => "rune", "rune" => "rune_#{rune_slug}"}]
    })
  end

  # ⑧ World — arena (singleton), theme (singleton). Values from nagrand_arena.gd
  # / nagrand_arena.tscn.
  defp world_group do
    [
      singleton("arena", "Nagrand Arena", %{
        "title" => "Nagrand Arena",
        "radius" => "175",
        "spawnRing" => %{"min" => "60", "max" => "110"},
        "rimRings" => [%{"y" => "-1.25"}, %{"y" => "4.75"}, %{"y" => "13.45"}],
        "pillars" => "4",
        "lighting" => %{"sunAngle" => "-51.4", "energy" => "0.5"}
      }),
      singleton("theme", "FRT Neon", %{
        "title" => "FRT Neon",
        "accent" => "#00ffff",
        "palette" => [
          %{"name" => "dusk-sky", "color" => "#101830"},
          %{"name" => "floor-accent", "color" => "#2143a3"},
          %{"name" => "beacon-gold", "color" => "#ffd666"},
          %{"name" => "beacon-red", "color" => "#ff1100"},
          %{"name" => "mote-gold", "color" => "#ffd973"},
          %{"name" => "mote-cyan", "color" => "#4dd9ff"},
          %{"name" => "mote-purple", "color" => "#b366f2"},
          %{"name" => "silhouette", "color" => "#1a1a28"}
        ],
        "fonts" => %{"heading" => "Rajdhani", "body" => "Inter"}
      })
    ]
  end

  # ⑨ Game feel — the audiovisual layer the game ships with: procedural SFX
  # (autoload/sfx.gd), pooled VFX families (effects/effect_manager.gd), HUD widgets
  # (ui/hud.gd facade) and full-screen overlays (ui/*overlay.gd). All four collections
  # registered but seeded EMPTY before this group.
  defp game_feel_group do
    List.flatten([sounds(), vfx_families(), hud_elements(), overlays()])
  end

  # sound — the procedural SFX baked at boot into in-memory AudioStreamWAV buffers
  # (NO assets on disk). Voice lanes per sfx.gd POOL_PROTECTED (2) / POOL_COMBAT (6).
  # synthParams (wave/freq/decay) + triggerSignal read from the per-clip doc comments.
  defp sounds do
    [
      sound("fire", "Machine-gun fire", "noise+tone", "220.0", "0.05", "combat", "combat.fired"),
      sound("impact", "Bullet impact", "noise", "180.0", "0.06", "combat", "combat.enemy_hit"),
      sound(
        "ding",
        "Skill-reward ding",
        "sine",
        "880.0",
        "0.15",
        "combat",
        "combat.enemy_hit (headshot/crit)"
      ),
      sound(
        "kill",
        "Enemy-kill thump",
        "sine+triangle",
        "90.0",
        "0.12",
        "combat",
        "swarm.enemy_killed"
      ),
      sound(
        "boom",
        "Explosion boom",
        "noise+sine",
        "60.0",
        "0.26",
        "combat",
        "TechnoBot.exploded / grenade detonated"
      ),
      sound(
        "kick",
        "Kick slam thump",
        "noise+sine",
        "60.0",
        "0.25",
        "combat",
        "player kick (AoE slam)"
      ),
      sound(
        "chime",
        "XP-crystal chime",
        "sine",
        "1760.0",
        "0.08",
        "combat",
        "CrystalManager.crystal_collected"
      ),
      sound(
        "fanfare",
        "Level-up fanfare",
        "sine+triangle",
        "523.0",
        "0.52",
        "protected",
        "PlayerStats.level_up"
      ),
      sound(
        "hurt",
        "Player-hurt grunt",
        "noise+sine",
        "120.0",
        "0.13",
        "combat",
        "player.damaged"
      ),
      sound("death", "Player-death stinger", "sine", "165.0", "0.62", "protected", "player.died"),
      sound(
        "footstep",
        "Footstep",
        "noise",
        "200.0",
        "0.025",
        "combat",
        "player stride-phase driver"
      ),
      sound(
        "whoosh_dash",
        "Dash whoosh",
        "noise",
        "600.0",
        "0.19",
        "combat",
        "player.moved(\"dash\")"
      ),
      sound(
        "whoosh_slide",
        "Slide scrape",
        "noise",
        "300.0",
        "0.30",
        "combat",
        "player.moved(\"slide\")"
      ),
      sound(
        "boss_approach_king",
        "King-approach sting",
        "sine+brass",
        "65.0",
        "1.2",
        "protected",
        "wave_manager._start_boss_wave (KING)"
      ),
      sound(
        "dead_eye_arm",
        "Dead-Eye arm sting",
        "bell",
        "660.0",
        "0.6",
        "protected",
        "combat.dead_eye_armed"
      ),
      sound(
        "wave_start",
        "Wave-start sting",
        "square",
        "800.0",
        "0.3",
        "combat",
        "WaveManager.wave_in_floor (WARNING tier)"
      )
    ]
  end

  defp sound(slug, title, wave, freq, decay, lane, trigger) do
    item("sound", slug, title, %{
      "title" => title,
      "synthParams" => %{"wave" => wave, "freq" => freq, "decay" => decay},
      "voiceLane" => lane,
      "triggerSignal" => trigger
    })
  end

  # vfx — the pooled visual-effect families (effect_manager.gd). poolSize + lifetime
  # from the per-family tuning consts; family per the schema's render-family vocabulary.
  defp vfx_families do
    [
      vfx(
        "explosion_glow",
        "On-target explosion glow",
        "billboard",
        "16",
        "0.4",
        "spawn_explosion (enemy_killed flush)"
      ),
      vfx(
        "ground_ring",
        "Explosion ground ring",
        "disc",
        "16",
        "0.55",
        "spawn_explosion (floor footprint)"
      ),
      vfx(
        "impact_spark",
        "Bullet-impact spark",
        "gpu_particles",
        "24",
        "0.25",
        "on_player_hit (combat.enemy_hit)"
      ),
      vfx(
        "dust",
        "Footstep / landing dust",
        "gpu_particles",
        "8",
        "0.38",
        "spawn_dust (land / slide)"
      ),
      vfx(
        "smoke",
        "Explosion smoke",
        "gpu_particles",
        "16",
        "1.2",
        "spawn_explosion (aftermath layer)"
      ),
      vfx(
        "flash_light",
        "Explosion flash light",
        "omni_light",
        "8",
        "0.1",
        "spawn_explosion (instant punch)"
      ),
      vfx("tracer", "Bullet tracer", "mesh_arc", "16", "0.08", "on_player_fired (combat.fired)"),
      vfx(
        "muzzle_flash",
        "Muzzle flash",
        "omni_light",
        "8",
        "0.05",
        "on_player_fired (combat.fired)"
      ),
      vfx("shockwave", "Kick shockwave arc", "mesh_arc", "8", "0.8", "spawn_shockwave (kick)"),
      vfx("xp_burst", "XP-pickup sparkle", "gpu_particles", "24", "0.4", "crystal_collected"),
      vfx(
        "boss_telegraph",
        "Boss-spawn telegraph",
        "disc",
        "2",
        "0.9",
        "wave_manager._start_boss_wave"
      ),
      vfx(
        "wave_telegraph",
        "Wave-spawn telegraph",
        "disc",
        "32",
        "0.4",
        "wave_manager per-spawn telegraph"
      )
    ]
  end

  defp vfx(slug, title, family, pool_size, lifetime, trigger) do
    item("vfx", slug, title, %{
      "title" => title,
      "family" => family,
      "poolSize" => pool_size,
      "lifetime" => lifetime,
      "triggerSignal" => trigger
    })
  end

  # hudElement — the typed facade widgets in hud.gd (kind + bindTo data source + style).
  # AAA-minimal styling per the port UI philosophy (one accent, restraint, no neon dump).
  defp hud_elements do
    [
      hud_element(
        "health_bar",
        "Health bar",
        "bar",
        "PlayerStats.health (Coordinator HP poll)",
        "cyan accent fill on near-black plate, band-tints red as HP drops"
      ),
      hud_element(
        "stamina_pips",
        "Stamina pips",
        "pip",
        "player.stamina",
        "one fixed-width bar subdivided into N blue segments, recharge pulse on the filling pip"
      ),
      hud_element(
        "xp_bar",
        "XP bar",
        "bar",
        "PlayerStats.xp / xp_needed",
        "thin screen-edge cyan fill, shimmer tween, level badge readout"
      ),
      hud_element(
        "crosshair",
        "Crosshair",
        "icon",
        "set_crosshair_mode (FPS aim)",
        "hairline reticle, single cyan accent, no glow"
      ),
      hud_element(
        "boss_hp",
        "Boss HP bar",
        "bar",
        "boss hp / max_hp (update_boss)",
        "wide top plate with chrome brackets, orange threat fill, reveal+pulse on spawn"
      ),
      hud_element(
        "combat_feed",
        "Combat feed",
        "counter",
        "append_feed (kill / damage events)",
        "right-aligned scrolling kill log, tier-tinted lines, hairline rule"
      ),
      hud_element(
        "wave_label",
        "Wave / floor strip",
        "counter",
        "wave_manager.current_wave + floor (update_top_strip)",
        "centred top strip, restraint typography, cyan progress bar"
      ),
      hud_element(
        "chain_banner",
        "Chain-tier banner",
        "banner",
        "Coordinator chain tier (show_chain)",
        "transient centre toast, tier-tinted (orange→red→magenta), drop-shadow legibility"
      ),
      hud_element(
        "score_readout",
        "Score readout",
        "counter",
        "score / kills (update_score)",
        "hero count-up numeric, one accent, pulses on gain"
      ),
      hud_element(
        "dead_eye",
        "Dead-Eye indicator",
        "icon",
        "combat.dead_eye_armed / disarmed",
        "armed-state glyph overlay, tense accent, 5s window"
      )
    ]
  end

  defp hud_element(slug, title, kind, bind_to, style) do
    item("hudElement", slug, title, %{
      "title" => title,
      "kind" => kind,
      "bindTo" => bind_to,
      "style" => style
    })
  end

  # overlay — the full-screen CanvasLayer overlays in ui/*overlay.gd. The slowmo cue
  # SELF-DRIVES off GameClock (zero Coordinator coupling); the other four are
  # Coordinator-driven off a signal or a per-frame poll.
  defp overlays do
    [
      overlay("damage", "Damage overlay", "coordinator", "player.damaged + Coordinator HP poll"),
      overlay(
        "motionVignette",
        "Motion vignette",
        "coordinator",
        "Coordinator speed-ratio set_intensity"
      ),
      overlay("chainFlash", "Chain flash", "coordinator", "Coordinator tier-crossing flash"),
      overlay(
        "floorClear",
        "Floor-clear celebration",
        "coordinator",
        "Coordinator.celebrate (King death)"
      ),
      overlay("slowmo", "Slow-mo cue", "self", "GameClock.slow_motion_scale")
    ]
  end

  defp overlay(slug, title, driver, trigger) do
    item("overlay", slug, title, %{
      "title" => title,
      "driver" => driver,
      "triggerSignal" => trigger
    })
  end
end
