defmodule Barkpark.Plugins.Quiz do
  @moduledoc """
  Hyperquiz — thin plugin wiring for the live-quiz engine in `Barkpark.Quiz.*`
  (the split-surface game: `/quiz/host/:pin` projector + `/quiz/play/:pin` phone
  input, server-authoritative realtime over per-room GenServers; design epic
  `hyperquiz-epic`, charter `.claude/workflows/bp-hyperquiz-charter.md`).

  The tasks.ex / bulldocs.ex / pulse.ex precedent — core owns the machinery
  (`Barkpark.Quiz.*` engine, `BarkparkWeb.Quiz{Host,Play}Live` surfaces,
  `BarkparkWeb.Quiz{Socket,Channel}`), the plugin owns the MOUNTING. Charter
  Decision D: the branch hardwired its supervision children into
  `application.ex` and its routes into `router.ex` — exactly the
  plugins-off-doctrine violation. This module absorbs both through the plugin
  callbacks so the ONLY core edit is the compile-time `socket "/quiz"` line in
  `endpoint.ex` (Phoenix `socket/3` is a macro with no plugin callback — Pulse
  hand-adds its socket the same way).

  What this module contributes:

    * `register_workers/1` — the three supervision children the game needs: a
      unique Registry over room-PIN keys, the DynamicSupervisor rooms start
      under (lazily on first join; a `max_children` DoS backstop), and the P4
      live-edit `Barkpark.Quiz.Bridge`. Precedent: pulse.ex:75. Started at boot
      for every INSTALLED plugin (disk-discovered) regardless of per-workspace
      surfacing — see `Barkpark.Plugins.Enablement` moduledoc.
    * `register_routes/1` — the two public, anonymous LiveViews on the
      `:public_root` bucket with the quiz root layout (no Studio chrome). The
      host router auto-injects these via `plugin_routes(scope: :public_root)`
      (router.ex ~:883), so ZERO router.ex edits. Precedent: bulldocs.ex:116.
    * `register_schemas/1` — the private `quiz` document type, so
      `Plugins.Bootstrap` upserts it at boot and quizzes are authored in the
      generic Studio editor. This REPLACES the branch's dead
      `Barkpark.Quiz.Content.register_schema/1` (never wired to boot).

  Accepted tradeoff (same as Pulse): the `socket "/quiz"` line compiles
  unconditionally, so a disabled quiz plugin still exposes a dormant `/quiz`
  socket path — harmless, with no reachable channel (the routes/workers are
  plugin-gated).
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/quiz/plugin.json"

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Quiz.Content

  # A live-quiz surface is a demo the workspace WANTS visible — surface it in the
  # main structure by default (unlike the ops/integration plugins that default
  # OFF). Routes/workers/schemas mount regardless of this flag (it only gates
  # per-workspace SURFACING — Enablement moduledoc); this keeps the `quiz` schema
  # node in front of authors without an admin toggle.
  @impl Barkpark.Plugin
  def default_enabled?, do: true

  # The three children the branch hardwired into application.ex, moved here so a
  # disabled/absent quiz plugin supervises nothing. Order matters: the Registry
  # and RoomSupervisor must exist before the Bridge (which drives rooms). NOTE:
  # application.ex splices plugin workers BEFORE the host Phoenix.PubSub child,
  # so the Bridge defers its PubSub subscribe (see bridge.ex init/1).
  @impl Barkpark.Plugin
  def register_workers(_ctx) do
    [
      # Per-room in-memory sessions keyed by room PIN. Rooms register here on
      # first join and self-stop when idle (Barkpark.Quiz.Room @empty_idle_ms).
      {Registry, keys: :unique, name: Barkpark.Quiz.RoomRegistry},
      # Rooms start lazily under this supervisor (restart: :temporary — a crashed
      # room is gone, the next join starts fresh). max_children is a memory-DoS
      # backstop: an anonymous join can start a room for any PIN.
      {DynamicSupervisor,
       name: Barkpark.Quiz.RoomSupervisor, strategy: :one_for_one, max_children: 10_000},
      # P4 live-edit bridge: subscribes to document mutations and re-applies a
      # changed quiz into the rooms bound to it.
      Barkpark.Quiz.Bridge
    ]
  end

  # The public, anonymous split-surface LiveViews. `:public_root` gives each its
  # own quiz root layout at the host top-level scope with no Studio chrome —
  # players join a room by PIN, no auth on_mount. The `:index` action is nominal
  # (the LiveViews read `:pin` in mount, not the action).
  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      {:live, "/quiz/host/:pin", BarkparkWeb.QuizHostLive, :index,
       auth: :public_root, root_layout: {BarkparkWeb.Layouts, :quiz}},
      {:live, "/quiz/play/:pin", BarkparkWeb.QuizPlayLive, :index,
       auth: :public_root, root_layout: {BarkparkWeb.Layouts, :quiz}}
    ]
  end

  # The `quiz` document type. PRIVATE visibility: the doc stores the correct
  # answer inline, so it must NOT be anonymously readable via the public content
  # API (the Room loads it server-side and broadcasts an answer-stripped
  # question). `Plugins.Bootstrap.register_all_schemas/0` upserts this at boot,
  # idempotent on (name, dataset).
  @impl Barkpark.Plugin
  def register_schemas(_opts) do
    s = Content.schema()

    [
      %SchemaDefinition{
        name: s.name,
        title: s.title,
        icon: s.icon,
        visibility: s.visibility,
        fields: s.fields,
        dataset: "production"
      }
    ]
  end
end
