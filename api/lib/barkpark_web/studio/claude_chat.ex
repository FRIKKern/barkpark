defmodule BarkparkWeb.Studio.ClaudeChat do
  @moduledoc """
  Gate + subprocess seam for the Studio **Claude chat** (`/studio/chat`).

  A chat panel backed by the host's Claude Code CLI. The `claude` binary is
  spawned in streaming print mode (`--input-format stream-json
  --output-format stream-json`) and inherits the host's `claude auth login`
  OAuth credentials via `$HOME` — Barkpark never sees, stores, or refreshes a
  token. Same trust model as the tmux console, held safe by the same three
  controls:

    1. **Admin-only.** The `/studio/chat` route rides the `:admin_studio`
       live_session, so its `on_mount` requires an admin token / account. The
       nav tab is likewise shown only to admins (`shares_admin?`).
    2. **Public-demo hard refuse.** `enabled?/0` returns false whenever
       `public_demo_studio` is on. Fail-closed, not overridable by the flag.
    3. **Per-host opt-out.** `BARKPARK_CLAUDE_CHAT=0` (runtime.exs) disables
       it on a given host. Binary presence does NOT gate `enabled?/0` (the
       chat-task-hands gate inversion): a host without `claude` still shows
       the chat surface, which renders the onboarding card instead of a
       composer — the tab never silently vanishes.

  Wave 1 runs the agent in **plan mode** (`--permission-mode plan`): the
  model may read the filesystem it runs in but cannot edit or execute —
  no approval UI is needed. The stream-json wire protocol is the same one
  `@anthropic-ai/claude-agent-sdk` speaks, so the t3code-style agent-chat
  features (tool approvals, `--resume` threads, MCP callbacks) layer on
  without changing this seam.

  The subprocess command is read from config (tests inject `{"cat", []}` or
  small `sh -c` scripts), so the whole spawn → NDJSON parse → event path is
  exercised without a real `claude`.
  """

  require Logger

  alias Barkpark.Connectors.CloudPolicy

  @default_binary "claude"
  # The real `--permission-mode` choices the CLI documents (probed v2.1.205,
  # charter D48). Moves TOGETHER with Session's @modes. `default` (our retired
  # middle mode) is deliberately absent — a stored legacy `default` still spawns
  # verbatim (default_args passes the mode through), but it is no longer an
  # offered choice. `bypassPermissions` is offered but GUARDED: it only reaches
  # the argv through the armed ceremony (see build_args/normalize_mode below).
  @modes ~w(plan acceptEdits auto dontAsk manual bypassPermissions)
  # Modes an UNTRUSTED string may normalize INTO. bypassPermissions is excluded
  # by law: it is the one road-blocked mode — a raw event string must never fail
  # OPEN into dangerous bypass (charter D48 fail-closed law).
  @normalizable_modes @modes -- ["bypassPermissions"]
  @default_mode "plan"
  # Reasoning-effort tiers the CLI's `--effort` flag accepts (probed v2.1.205,
  # charter D48). Ascending intensity; defined here so build_args' guard sees it.
  @efforts ~w(low medium high xhigh max)
  # Ceiling on the Port stdout line-reassembly buffer (Session.handle_info →
  # parse_chunk). The CLI emits newline-delimited JSON, so in normal operation
  # the buffer only ever holds the trailing partial line. A malformed or stalled
  # stream that never emits a newline would otherwise grow one binary without
  # bound in the long-lived per-session GenServer (the codex-twin scar-class).
  # Config-overridable per host/test via `config :barkpark, :claude_chat,
  # max_buffer_bytes: N` (validator.ex @default/config/0/Keyword.get technique).
  @default_max_buffer_bytes 8 * 1024 * 1024

  @doc """
  Whether the chat may run on this host. ON by default; requires the flag
  (default on, opt out via env) and is HARD-REFUSED whenever anonymous Studio
  is on (`public_demo_studio`). Both the nav tab (admin-only) and the LiveView
  mount gate on this.

  Binary presence deliberately does NOT gate here (chat-task-hands charter,
  decision 4 — the gate inversion): a missing/logged-out `claude` must never
  make the tab vanish or the mount redirect. The chat surface stays, and the
  onboarding card (`ChatLive`, keyed off the async `Probe` readiness) names
  the exact not-ready state with its next step instead — never fail silent
  (charter D2). Security posture is UNCHANGED: flag-off, public-demo, and the
  admin `on_mount` still refuse outright.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    flag_on?() and not public_demo?()
  end

  # Enable flag defaults ON; only an explicit `enabled: false` (base config or
  # BARKPARK_CLAUDE_CHAT=0 via runtime.exs) turns it off.
  defp flag_on?, do: Keyword.get(config(), :enabled, true) != false

  # Fail-closed: a host that serves Studio to anonymous visitors must never
  # expose an agent with the server's filesystem in reach.
  defp public_demo?, do: Application.get_env(:barkpark, :public_demo_studio, false) == true

  @doc "The configured Claude binary (default `claude`)."
  @spec binary() :: String.t()
  def binary, do: Keyword.get(config(), :binary, @default_binary)

  @doc """
  Byte ceiling on the Port stdout line-reassembly buffer (`@default_max_buffer_bytes`,
  8 MiB). Overridable via `config :barkpark, :claude_chat, max_buffer_bytes: N`
  (tests shrink it to force the overflow path). Read in `Session.handle_info` where
  the raw bytes arrive — a newline-free stream never yields a complete line, so the
  cap must live at the accumulation seam, not the event path (charter D126).
  """
  @spec max_buffer_bytes() :: pos_integer()
  def max_buffer_bytes, do: Keyword.get(config(), :max_buffer_bytes, @default_max_buffer_bytes)

  @doc """
  The subprocess command as `{executable, args}`. Defaults to the Claude CLI
  in streaming print mode, plan permission mode. Overridable via config
  (tests inject a trivial command so they don't require `claude`).

  `session_opts` threads session identity onto the real argv through the pure
  `build_args/2` seam (`%{session_id: uuid}` ⇒ `--session-id`,
  `%{session_id: uuid, resume: true}` ⇒ `--resume`).

  ## Execution profile (connectors D107 — the Cloud crux seam)

  A new app config `:execution_profile` under `:claude_chat` selects WHERE the
  turn runs, WITHOUT touching the `{exe,args,env,cwd} → NDJSON` spawn contract
  (the same `Port.open`, the same parse pipeline). It is an instance/deployment
  property, never a per-session user choice — a cloud session still carries
  `execution_target=managed`:

    * `:self_hosted` (default, greenfield) — the host `claude` CLI subprocess,
      full host access, `bypassPermissions` reachable via the armed ceremony.
      The returned tuple is **byte-identical** to the pre-D107 behavior (no
      config ⇒ this branch is never entered).
    * `:cloud` — `{sandbox_runner(), cloud_build_args(mode, opts)}`: the turn
      runs inside an isolated Vercel Sandbox via the `cloud-sandbox-runner`
      shim, NO host access, connector-scoped tools, gated on a concrete
      workspace principal. The cloud argv (D109) drops the permission-prompt
      bridge and ALL mcp args and **never** emits bypass flags; the shim gets
      the workspace id and hard-fails on a nil/`:global` workspace (D110).

  VACUOUS-GREEN LAW: the `:command` config override returns its tuple
  **verbatim**, bypassing `build_args/2` entirely — never assert session/mode
  flags through a `:command` fake. Assert flags either against `build_args/2`
  directly, or end-to-end through a `:binary` override (which keeps
  `build_args/2`).
  """
  @spec command(String.t(), map()) :: {String.t(), [String.t()]}
  def command(mode \\ @default_mode, session_opts \\ %{}) do
    case Keyword.get(config(), :command) do
      {exe, args} when is_binary(exe) and is_list(args) ->
        {exe, args}

      _ ->
        case execution_profile(session_opts) do
          :cloud -> {sandbox_runner(), cloud_build_args(mode, session_opts)}
          _self_hosted -> {binary(), build_args(mode, session_opts)}
        end
    end
  end

  @default_execution_profile :self_hosted
  @default_sandbox_runner "cloud-sandbox-runner"

  @doc """
  The configured execution profile (`:self_hosted` default | `:cloud`). Greenfield
  config key (connectors D107) — an unset or unrecognized value fails to the
  host CLI, never silently into the sandbox path.
  """
  @spec execution_profile() :: :self_hosted | :cloud
  def execution_profile do
    case Keyword.get(config(), :execution_profile, @default_execution_profile) do
      :cloud -> :cloud
      _ -> :self_hosted
    end
  end

  @doc """
  The turn's EFFECTIVE execution profile (connectors D205): the per-workspace
  choice when the Session resolved one into `session_opts` (see
  `resolve_workspace_execution_profile/1`), else the global config
  (`execution_profile/0`). The Session resolves the workspace ONCE in `init/1`
  and threads `:execution_profile` here, so BOTH consumers — `command/2` and
  the cloud tool-descriptor threading — read the SAME resolution.
  """
  @spec execution_profile(map()) :: :self_hosted | :cloud
  def execution_profile(session_opts) when is_map(session_opts) do
    case Map.get(session_opts, :execution_profile) do
      profile when profile in [:cloud, :self_hosted] -> profile
      _ -> execution_profile()
    end
  end

  @doc """
  Resolve `session_opts[:workspace_id]` into an explicit `:execution_profile`
  (connectors D205 — the per-workspace consumer seam). ONE `Tenancy` lookup per
  Session spawn, from `Session.init/1` — per-session human cadence, never a
  Registry callback. Fail-safe: a nil workspace_id (host-admin/:global sessions
  stamp SQL NULL), a missing row, an absent/malformed/unknown
  `settings["chat"]["execution_profile"]`, or ANY lookup failure leaves
  `session_opts` untouched — `execution_profile/1` then falls through to the
  global config and thus `:self_hosted` (fail-safe, never fail-cloud). When the
  workspace carries an explicit `"cloud"`/`"self_hosted"`, the per-workspace
  value WINS over the global config in BOTH directions; the `:command` config
  tuple stays the outermost verbatim bypass in `command/2`, untouched by this.
  """
  @spec resolve_workspace_execution_profile(map()) :: map()
  def resolve_workspace_execution_profile(session_opts) when is_map(session_opts) do
    case workspace_execution_profile(Map.get(session_opts, :workspace_id)) do
      profile when profile in [:cloud, :self_hosted] ->
        Map.put(session_opts, :execution_profile, profile)

      _ ->
        session_opts
    end
  end

  defp workspace_execution_profile(workspace_id) when is_binary(workspace_id) do
    workspace = Barkpark.Tenancy.get_workspace_by_id(workspace_id)

    case Barkpark.Tenancy.workspace_chat_settings(workspace)["execution_profile"] do
      "cloud" -> :cloud
      "self_hosted" -> :self_hosted
      _ -> nil
    end
  rescue
    e ->
      Logger.warning(
        "claude chat: workspace execution-profile lookup failed (#{inspect(e)}) — global profile"
      )

      nil
  end

  defp workspace_execution_profile(_), do: nil

  @doc """
  The executable that spawns a Cloud turn — the `cloud-sandbox-runner` shim
  (connectors D108/D111). Config-overridable (`:sandbox_runner`) so tests inject
  a chmod+x fake and a real deploy points at the committed
  `scripts/connectors/cloud-sandbox-runner.mjs`. Resolved through the same
  `System.find_executable` path as the host binary.
  """
  @spec sandbox_runner() :: String.t()
  def sandbox_runner, do: Keyword.get(config(), :sandbox_runner, @default_sandbox_runner)

  @doc ~S"""
  The Cloud-profile argv (connectors D109/D127/D137) — the shim's OWN argv.
  Structure:

      ["--workspace", <workspace_id>,
       ("--mcp-config-b64", <b64>)?,
       ("--sandbox-id", <id>)?, "--keep-sandbox",
       ("--egress-host", <host>)*,
       "--" | <claude args>]

  The shim buffers the first user frame from its stdin, creates (or, with
  `--sandbox-id`, reuses the auto-resuming) isolated sandbox tagged with the
  workspace, and runs `claude <claude args> < turn.jsonl` inside it.

  ## Multi-turn session continuity (connectors D135/D137/D139 — W14)

  A Cloud chat is a real multi-turn Barkpark Chat SESSION whose memory lives in
  the sandbox filesystem, not a held subprocess (interactive stdin into a
  sandbox is impossible — D108). Two additive seams carry it:

    * pre-`--` (SHIM-own): `--keep-sandbox` ALWAYS (teardown STOPS, not removes —
      the sandbox + its `/tmp` claude transcript survive to the next turn), plus
      `--sandbox-id <id>` when `session_opts[:cloud_sandbox_id]` is a non-empty
      binary (skip create, exec the bound sandbox).
    * post-`--` (claude-own, at the FRONT of the segment so `--disallowedTools`
      stays the boundary): `--resume <session_id>` when the session is BOUND to a
      sandbox, else a fresh `--session-id <session_id>`.

  D139 LAW: resume-ness derives SOLELY from the sandbox binding, NEVER from
  `session_opts[:resume]`/a message_count — a session whose bound sandbox
  vanished must mint a fresh `--session-id`, never `--resume` into an empty
  filesystem. The claude argv KEEPS `--input-format/--output-format stream-json`,
  `--include-partial-messages`, `--verbose`, `--permission-mode <mode>`; it DROPS
  `--permission-prompt-tool stdio` (no channel answers asks one-shot) and ALL
  HOST mcp args (a host-written `--mcp-config` PATH hard-fails in-sandbox with
  zero output). It **structurally never** emits
  `--allow-dangerously-skip-permissions` — bypass is unreachable from this
  builder (a down-payment on D24 knob 1).

  Knob 3's CONFIG wiring (D126/D127) rides a SHIM-OWN flag: when the workspace
  has ≥1 tool-direction install whose bridge descriptor survives
  `CloudPolicy.cloud_mcp_servers/2`, this builder emits ONE `--mcp-config-b64
  <base64(mcpServers json)>` pair BEFORE the `--` separator (0 installs ⇒ the
  argv is byte-identical to W12). The Elixir argv itself NEVER carries
  `--mcp-config`/`--strict-mcp-config`/a host path — the shim decodes the b64 to
  an in-VM /tmp file and appends those to the claude exec.

  The D24 permission reversal (D116/D117) rides here: the mode is CLAMPED through
  `Barkpark.Connectors.CloudPolicy` (bypass/unknown → `"plan"`) and the argv
  carries `CloudPolicy`'s three tool-removal belts — `--tools ""`,
  `--disallowedTools <deny set>`, and a `--settings` deny JSON STRING (the SAME
  deny list, pinned no-drift). `CloudPolicy` is the single legible owner of the
  cloud posture; this function only emits it.

  Fail-closed principal (D110): a nil/`:global`/blank `workspace_id` RAISES here
  (the `registered_host` `Map.fetch!` shape) rather than spawning an
  unattributed cloud turn.
  """
  @spec cloud_build_args(String.t(), map()) :: [String.t()]
  def cloud_build_args(mode, session_opts \\ %{}) do
    workspace_id = cloud_workspace_id!(session_opts)

    ["--workspace", workspace_id] ++
      cloud_mcp_config_args(session_opts) ++
      cloud_sandbox_args(session_opts) ++
      cloud_egress_args(session_opts) ++
      ["--"] ++
      cloud_claude_args(mode, session_opts)
  end

  # The shim-own per-connector egress allowlist (knob 6's WIRING, D238/D240 — W29)
  # — repeated `--egress-host <host>` pairs emitted AFTER the sandbox-lifecycle
  # flags and BEFORE the `--` separator, so the SHIM (never claude) owns them and
  # can widen the sandbox's deny-all egress to EXACTLY the workspace's installed
  # tool connectors' declared MCP hosts. Derived from the SAME `installs ∩
  # descriptors` truth as `--mcp-config-b64` via `CloudPolicy.cloud_egress_hosts/2`
  # (sorted, unique, D239-sanitized). With 0 surviving hosts this is `[]` and the
  # argv is BYTE-IDENTICAL to W25 (deny-all preserved). Each host rides its OWN
  # `--egress-host` pair — NEVER comma-joined, and `api.anthropic.com` (the shim's
  # env base, never a connector descriptor) never appears.
  defp cloud_egress_args(session_opts) do
    workspace = Map.get(session_opts, :workspace_id)
    descriptors = Map.get(session_opts, :tool_descriptors, [])

    workspace
    |> CloudPolicy.cloud_egress_hosts(descriptors)
    |> Enum.flat_map(fn host -> ["--egress-host", host] end)
  end

  # The shim-own sandbox-lifecycle flags (connectors D137/D138), emitted pre-`--`
  # so the SHIM (never claude) owns them. `--keep-sandbox` ALWAYS rides a Cloud
  # turn: teardown STOPS the sandbox (auto-snapshot) instead of REMOVING it, so
  # the session's sandbox — and the claude transcript under its persisted /tmp
  # HOME — survives to the next turn (the per-turn timeout, not the whole chat,
  # bounds one running turn). When the session is already BOUND to a sandbox
  # (`session_opts[:cloud_sandbox_id]` is a non-empty binary), ALSO emit
  # `--sandbox-id <id>` so the shim skips create and execs straight into the
  # auto-resuming sandbox. Order matches D141's W14-1 line: `--sandbox-id <id>
  # --keep-sandbox`. A nil/blank binding ⇒ just `--keep-sandbox` (fresh sandbox
  # this turn, kept for the next).
  defp cloud_sandbox_args(session_opts) do
    case Map.get(session_opts, :cloud_sandbox_id) do
      id when is_binary(id) and id != "" -> ["--sandbox-id", id, "--keep-sandbox"]
      _ -> ["--keep-sandbox"]
    end
  end

  # Whether this Cloud session is bound to a live sandbox — the SOLE source of
  # resume-ness (D139 LAW). Derived from the binding column, NEVER from
  # `session_opts[:resume]`/a message_count: a session whose bound sandbox
  # vanished (expired/removed) must NOT `--resume` into an empty filesystem, and
  # a bound session resumes even if the transport's `resume?` boolean is inert.
  defp cloud_sandbox_bound?(session_opts) do
    case Map.get(session_opts, :cloud_sandbox_id) do
      id when is_binary(id) and id != "" -> true
      _ -> false
    end
  end

  # The shim-own `--mcp-config-b64 <b64>` flag (knob 3's CONFIG wiring, D127) —
  # emitted BEFORE the `--` separator so the SHIM (never claude) owns it, and ONLY
  # when the workspace has ≥1 tool-direction install whose host-fetched bridge
  # descriptor survives `CloudPolicy.cloud_mcp_servers/2`'s filter. With 0
  # surviving servers the argv is BYTE-IDENTICAL to W12 (no flag at all). The b64
  # payload is the full `%{"mcpServers" => …}` document; the shim decodes it to a
  # /tmp file IN-VM and appends `--mcp-config <path> --strict-mcp-config` to the
  # claude exec — so the Elixir argv NEVER carries `--mcp-config`,
  # `--strict-mcp-config`, or a host path (those are shim-owned). Descriptors are
  # host-fetched into `session_opts[:tool_descriptors]` (fail-soft to []) by the
  # Session; CloudPolicy cross-checks them against the workspace's live installs.
  defp cloud_mcp_config_args(session_opts) do
    workspace = Map.get(session_opts, :workspace_id)
    descriptors = Map.get(session_opts, :tool_descriptors, [])

    case CloudPolicy.cloud_mcp_servers(workspace, descriptors) do
      servers when map_size(servers) > 0 ->
        # W25-E (D214/D217): fold the SAME per-turn tool-session ticket (threaded
        # beside the descriptors, minted ONCE in `tool_descriptors_for/1`) into the
        # payload as a TOP-LEVEL `bpConnectorTicket` — the wire contract the shim
        # (W25-N) reads HOST-side to fetch each entry's FINISHED auth headers from
        # the bridge's loopback tool-headers route, then embeds them into the config
        # it copies into the sandbox (D213: the BRIDGE owns decryption; the shim
        # never sees a credential_ref). D38 held: Elixir threads only the non-secret
        # ticket — never a sealed ref, never plaintext. It rides ONLY when ≥1 server
        # survived (the flag itself does), so a 0-server turn is byte-identical to
        # W12 regardless of the ticket. The key name is the wire contract — NEVER
        # rename.
        json = Jason.encode!(cloud_mcp_payload(servers, session_opts))
        ["--mcp-config-b64", Base.encode64(json)]

      _ ->
        []
    end
  end

  # The b64 mcp document: always `mcpServers`; adds `bpConnectorTicket` when the
  # turn threaded a non-empty tool-session ticket (a :cloud turn with ≥1 install
  # always does — see `maybe_thread_cloud_tool_descriptors/1`). A blank/absent
  # ticket omits the key rather than emit `null`, keeping the payload well-formed.
  defp cloud_mcp_payload(servers, session_opts) do
    base = %{"mcpServers" => servers}

    case Map.get(session_opts, :tool_session_ticket) do
      ticket when is_binary(ticket) and ticket != "" ->
        Map.put(base, "bpConnectorTicket", ticket)

      _ ->
        base
    end
  end

  # The claude argv that runs INSIDE the sandbox (D109/D116/D117). Never derived
  # from any bypass/arming knob, so `--allow-dangerously-skip-permissions` is
  # structurally unreachable. The mode is CLAMPED through CloudPolicy (a bypass or
  # unknown mode → plan — knob 1's validity clamp, NOT a tool-confinement claim).
  # The three tool-removal belts (knob 2) are emitted from the single CloudPolicy
  # owner: `--tools ""` (remove all built-ins), `--disallowedTools <deny set>`
  # (structural per-tool removal), and a `--settings` deny JSON STRING carrying the
  # SAME deny list (pinned argv-deny == settings-deny, no drift). `--disallowedTools`
  # is emitted LAST so its variadic tool list has an unambiguous argv boundary.
  # The session-identity flags (D135/D139) ride at the FRONT of this segment so
  # `--disallowedTools` stays the final boundary — the shim passes the whole
  # segment through to `claude` untouched.
  defp cloud_claude_args(mode, session_opts) do
    cloud_session_args(session_opts) ++
      [
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--include-partial-messages",
        "--verbose",
        "--permission-mode",
        CloudPolicy.cloud_permission_mode(mode),
        "--tools",
        "",
        "--settings",
        CloudPolicy.settings_deny_json()
      ] ++ ["--disallowedTools" | CloudPolicy.cloud_disallowed_tools()]
  end

  # The Cloud-profile session-identity flags (connectors D135/D139) — the front
  # of the post-`--` claude segment. `--session-id <uuid>` (mint fresh) turns 1;
  # `--resume <uuid>` once the session is bound to a sandbox whose /tmp HOME
  # carries the prior transcript. D139 LAW: which one is chosen derives SOLELY
  # from the sandbox binding (`cloud_sandbox_bound?/1`), NEVER from
  # `session_opts[:resume]` or a message_count — the self-hosted `session_args/1`
  # keys off `:resume`, but a Cloud `--resume` into a vanished sandbox would hit
  # an empty filesystem (`No conversation found`, D135), so the binding is the
  # only honest signal. The uuid is the Barkpark session's public UUID
  # (`session_opts[:session_id]`) — the SAME value the self-hosted path emits.
  # Absent/blank session_id ⇒ neither flag (defensive; a real Cloud turn always
  # carries one).
  defp cloud_session_args(session_opts) do
    case Map.get(session_opts, :session_id) do
      id when is_binary(id) and id != "" ->
        if cloud_sandbox_bound?(session_opts), do: ["--resume", id], else: ["--session-id", id]

      _ ->
        []
    end
  end

  # Fail-closed workspace principal for a Cloud turn (D110). A concrete workspace
  # binary passes; nil, the sentinel `:global`/`"global"`, or a blank string
  # RAISE — the cloud profile never spawns an unattributed turn (mirror of the
  # runtime.ex:349 `registered_host` Map.fetch! posture, never the fail-soft
  # mcp empty-list pattern).
  defp cloud_workspace_id!(session_opts) do
    case Map.get(session_opts, :workspace_id) do
      id when is_binary(id) and id != "" and id != "global" ->
        id

      other ->
        raise ArgumentError,
              "cloud execution profile requires a concrete workspace_id; refusing to spawn " <>
                "an unattributed cloud turn (got: #{inspect(other)})"
    end
  end

  @doc """
  Pure assembly of the CLI argv for a given `mode` and `session_opts`. This is
  the single seam where session identity reaches the real process — kept pure
  and public so flag behavior is unit-testable without spawning a Port.

  Session flags (charter D8/D9), appended after the base args:

    * fresh session — `%{session_id: uuid}` ⇒ `["--session-id", uuid]`
      (we mint the uuid, so persistence needs no wire-protocol id scraping)
    * resume — `%{session_id: uuid, resume: true}` ⇒ `["--resume", uuid]`,
      and NEVER `--session-id` (the two are mutually exclusive on the binary)
    * absent — no `session_id` ⇒ neither flag (back-compat with w1–w2c)
  """
  @spec build_args(String.t(), map()) :: [String.t()]
  def build_args(mode, session_opts \\ %{}) do
    effective_mode = permission_mode(mode, session_opts)

    default_args(effective_mode) ++
      disallowed_args(effective_mode) ++
      bypass_args(mode, session_opts) ++
      session_args(session_opts) ++
      model_args(session_opts) ++
      effort_args(session_opts) ++
      mcp_args(session_opts)
  end

  # The permission mode that actually reaches `--permission-mode`. bypassPermissions
  # rides the argv ONLY when the persisted row armed it (`bypass_armed: true`,
  # threaded by ChatLive from the stored mode, never a raw event param); an unarmed
  # bypass falls back to plan (fail-closed). Every other mode — including a legacy
  # stored `default` — passes through verbatim.
  defp permission_mode("bypassPermissions", %{bypass_armed: true}), do: "bypassPermissions"
  defp permission_mode("bypassPermissions", _), do: @default_mode
  defp permission_mode(mode, _), do: mode

  # The dangerous arming flag is emitted ONLY alongside an armed bypass — the
  # second half of the two-key gate (mode == bypassPermissions AND bypass_armed).
  defp bypass_args("bypassPermissions", %{bypass_armed: true}),
    do: ["--allow-dangerously-skip-permissions"]

  defp bypass_args(_mode, _opts), do: []

  # Plan mode is fail-closed for WRITES (charter D65/D68): the Workflow tool
  # can launch a whole epic-cycle — a write-heavy act — and the wave-12 probes
  # found post-plan permissionMode still "default" on 2.1.206. Until S3's
  # scripted-deny verdict PROVES plan mode gates Skill/Workflow under real
  # argv, plan spawns road-block the tool outright. Applied to the EFFECTIVE
  # mode, so an unarmed bypass (which falls back to plan) is covered too.
  defp disallowed_args("plan"), do: ["--disallowedTools", "Workflow"]
  defp disallowed_args(_), do: []

  # The loopback MCP config flags (charter D64). Session.init WRITES the
  # per-session temp config file (impure — its job); build_args stays PURE
  # (D9) and merely references the path. `--strict-mcp-config` makes ours the
  # ONLY server: the CLI must never merge the host's saved MCP config, whose
  # `bp` would inherit the host's ADMIN credentials (proven live, wave-12 V1).
  defp mcp_args(%{mcp_config_path: path}) when is_binary(path),
    do: ["--mcp-config", path, "--strict-mcp-config"]

  defp mcp_args(_), do: []

  # A chosen reasoning-effort tier rides the spawn (`--effort <tier>`); absent =
  # the CLI's own default. Allowlisted tiers only — an unknown value omits the
  # flag (fail-closed), never a raw user string on the argv.
  defp effort_args(%{effort: e}) when e in @efforts, do: ["--effort", e]
  defp effort_args(_), do: []

  # Resume wins over a fresh pin: --resume and --session-id are mutually
  # exclusive, so a resume never also emits --session-id.
  defp session_args(%{session_id: id, resume: true}) when is_binary(id), do: ["--resume", id]
  defp session_args(%{session_id: id}) when is_binary(id), do: ["--session-id", id]
  defp session_args(_), do: []

  # A chosen model rides the spawn (`--model <alias>`); absent/default = the
  # CLI's own setting. Allowlisted aliases only — never a raw user string.
  defp model_args(%{model: m}) when is_binary(m) and m != "", do: ["--model", m]
  defp model_args(_), do: []

  @models ~w(haiku sonnet opus fable)

  @doc "Model aliases the picker may choose (the CLI accepts these)."
  @spec models() :: [String.t()]
  def models, do: @models

  @doc "Reasoning-effort tiers the picker may choose (`--effort`)."
  @spec efforts() :: [String.t()]
  def efforts, do: @efforts

  @doc ~S"""
  Clamp a picker value to an allowlisted effort tier, or nil for the CLI default.
  Fail-closed: an unknown string never reaches the argv (mirror of normalize_model/1).
  """
  @spec normalize_effort(term()) :: String.t() | nil
  def normalize_effort(e) when e in @efforts, do: e
  def normalize_effort(_), do: nil

  @doc ~S"""
  Clamp a picker value to an allowlisted model alias, or nil for the CLI
  default. Fail-closed: an unknown string never reaches the argv.
  """
  @spec normalize_model(term()) :: String.t() | nil
  def normalize_model(m) when m in @models, do: m
  def normalize_model(_), do: nil

  @doc "Permission modes the chat may run in. `plan` is read-only; the others ask."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc """
  Clamp an arbitrary mode string to a supported one (fail-closed to plan).

  bypassPermissions is deliberately NOT normalizable (charter D48): an untrusted
  string — a raw select param, a slash arg, a CLI-echoed init frame — must never
  fail OPEN into dangerous bypass. The only road to bypass is the armed ceremony
  in ChatLive, which persists the mode directly; every other path lands plan.
  """
  @spec normalize_mode(term()) :: String.t()
  def normalize_mode(mode) when mode in @normalizable_modes, do: mode
  def normalize_mode(_), do: @default_mode

  # ── loopback MCP server (charter D63/D64/D65) ─────────────────────────────

  # Our MCP server registers as "barkpark", so every loopback tool arrives on
  # the wire as `mcp__barkpark__<tool>` — dispatching on OUR server's names is
  # a narrow, deliberate D38 exception.
  @mcp_tool_prefix "mcp__barkpark__"

  # The read-only loopback tools that AUTO-APPROVE at the ask seam (charter
  # D65) — in EVERY mode, plan included. A tight full-name allowlist, FAIL
  # CLOSED: anything not listed (task_next CLAIMS, task_create/doc_create
  # WRITE, and the `bp_auth_*` verbs mutate credentials even where the
  # manifest marks them non-writing) surfaces the D31 approval card instead.
  # Curated task reads + the bridged task/doc/search reads (`bp_<noun>_<verb>`
  # per mcp_bridge.go's naming). `chat_read_tail`/`chat_wait_for_state` are the
  # herd read tools (charter D65) — pure observation of the fleet wire, so they
  # auto-approve; `chat_spawn_session`/`chat_send` MUTATE and stay
  # approval-gated.
  @mcp_auto_approve_tools ~w(
    task_ready task_show task_prime
    bp_task_get bp_task_ready bp_task_prime
    bp_doc_get bp_doc_ls bp_doc_query bp_doc_backlinks bp_doc_history bp_doc_revision
    bp_search_query
    chat_read_tail chat_wait_for_state
  )

  @doc "True when `name` is one of OUR loopback server's tools (charter D64)."
  @spec mcp_tool?(term()) :: boolean()
  def mcp_tool?(name) when is_binary(name), do: String.starts_with?(name, @mcp_tool_prefix)
  def mcp_tool?(_), do: false

  @doc "The bare tool behind OUR server prefix (`nil` for any other tool)."
  @spec mcp_tool_name(term()) :: String.t() | nil
  def mcp_tool_name(@mcp_tool_prefix <> tool), do: tool
  def mcp_tool_name(_), do: nil

  @doc """
  D65 permission policy, decided at the single D31 ask-routing seam: a
  READ-ONLY loopback tool auto-approves in every mode; everything else —
  every mutating loopback tool, every non-loopback tool — falls through to
  the honest approval card (that ping IS the workday demo). Fail-closed
  full-name allowlist; plan mode never auto-approves a write.
  """
  @spec mcp_auto_approved?(term()) :: boolean()
  def mcp_auto_approved?(@mcp_tool_prefix <> tool), do: tool in @mcp_auto_approve_tools
  def mcp_auto_approved?(_), do: false

  @doc """
  Whether a `system/init` frame reports OUR loopback server connected — the
  derivation `%Capabilities{}` (scc-w12-capabilities) reads for its
  `mcp_tools` flag. Pure over the frame; false for anything else, including a
  server that is present but failed.
  """
  @spec mcp_connected?(term()) :: boolean()
  def mcp_connected?(%{"mcp_servers" => servers}) when is_list(servers) do
    Enum.any?(servers, fn
      %{"name" => "barkpark", "status" => "connected"} -> true
      _ -> false
    end)
  end

  def mcp_connected?(_), do: false

  # ── runtime auth guard (chat-task-hands, charter decision 5) ──────────────

  @doc ~S"""
  Whether a stream frame is the unauthed-CLI footgun (charter Verified ground
  2026-07-11, captured live on 2.1.207): a logged-out `claude` ends the turn
  with a result frame that says `subtype:"success"` BUT carries
  `is_error:true` / `terminal_reason:"api_error"`, and the assistant frame
  before it carries top-level `error:"authentication_failed"`. Subtype alone
  MISCLASSIFIES — never trust it; this classifier keys on the error facts.

  `test/fixtures/claude_chat/unauthed_stream.ndjson` holds the captured wire
  truth these clauses are written against.
  """
  @spec auth_failure?(term()) :: boolean()
  def auth_failure?(%{"type" => "assistant"} = ev) do
    ev["error"] == "authentication_failed" or
      get_in(ev, ["message", "error"]) == "authentication_failed"
  end

  def auth_failure?(%{"type" => "result"} = ev) do
    ev["is_error"] == true and
      (ev["terminal_reason"] == "api_error" or ev["api_error_status"] == 401)
  end

  def auth_failure?(_), do: false

  @doc ~S"""
  Whether a result frame is a REAL success. `subtype == "success"` alone is a
  proven lie (see `auth_failure?/1`): an unauthed turn ends `subtype:"success"`
  with `is_error:true`. A result only counts as a success when the subtype
  says so AND the error facts agree.
  """
  @spec result_success?(term()) :: boolean()
  def result_success?(%{"type" => "result"} = ev) do
    ev["subtype"] == "success" and ev["is_error"] != true
  end

  def result_success?(_), do: false

  @doc """
  The per-session MCP config map (charter D63/D64; connectors D69/D73) —
  `Session.init` serializes it into a temp file that `--mcp-config` references.

  ALWAYS one server: Barkpark itself, through `bp mcp serve --tools all` (`all`
  because the paper + search legs need the bridged verbs, not just the curated
  task six). The env block is the credential seam: BOTH `BARKPARK_API_URL` and
  `BARKPARK_API_TOKEN` are set so the child `bp` NEVER falls back to the host's
  saved config — the host's credential is typically ADMIN (proven live, wave-12
  V1), and the short-lived minted session token is the whole point.

  PLUS, once per TOOL connector the session's workspace has connected: a SECOND
  (third, …) `mcpServers` key, DERIVED from the bridge's descriptor
  (`%{"provider", "type", "url", "headersHelper"}`) — this is the epic's OTHER
  direction (connectors D69). The agent talks to a human through a channel AND
  ACTS on GitHub, because a tool connector is simply another `mcpServers` entry.

  Two invariants make the fold safe: it is keyed on `descriptor["provider"]` (a
  registry id, never a provider special-case), and it uses `Map.put_new` so a
  rogue descriptor can never SHADOW the loopback `barkpark` server whose env
  carries the minted token. The descriptor is NON-SECRET (D38): the PAT rides
  the `headersHelper` at MCP-connect, never this file. Pure (data in, data out)
  so the shape is unit-testable without a session or a bridge.
  """
  @spec mcp_config(String.t()) :: map()
  def mcp_config(raw_token) when is_binary(raw_token), do: mcp_config(raw_token, [])

  @spec mcp_config(String.t(), [map()]) :: map()
  def mcp_config(raw_token, tool_descriptors)
      when is_binary(raw_token) and is_list(tool_descriptors) do
    barkpark = %{
      "barkpark" => %{
        "command" => Keyword.get(config(), :bp_binary, "bp"),
        "args" => ["mcp", "serve", "--tools", "all"],
        "env" => %{
          "BARKPARK_API_URL" => mcp_api_url(),
          "BARKPARK_API_TOKEN" => raw_token
        }
      }
    }

    servers =
      Enum.reduce(tool_descriptors, barkpark, fn descriptor, acc ->
        case tool_server_entry(descriptor) do
          {name, entry} -> Map.put_new(acc, name, entry)
          :skip -> acc
        end
      end)

    %{"mcpServers" => servers}
  end

  # One tool descriptor -> one `mcpServers` entry, or `:skip`. Fail-closed: a
  # descriptor missing its provider/url, naming a non-http transport, or
  # colliding with the reserved `barkpark` name is DROPPED — a malformed bridge
  # answer degrades the toolset, never poisons the loopback server. `type: "http"`
  # is the only transport a tool connector uses today (D71); `headersHelper` is
  # folded in only when present (the non-secret command that fetches the PAT).
  defp tool_server_entry(%{"provider" => provider, "type" => "http", "url" => url} = descriptor)
       when is_binary(provider) and provider != "" and provider != "barkpark" and
              is_binary(url) and url != "" do
    entry = %{"type" => "http", "url" => url}

    # The credential seam (D38): the subprocess runs `headersHelper` at
    # MCP-connect and prints `{"Authorization":"Bearer <pat>"}` into the
    # transport. Folded in ONLY when present — Elixir writes the command, never
    # the token. A descriptor with no helper is a URL-only server (harmless; an
    # unauthenticated MCP server, which GitHub's is not, but the type allows it).
    entry =
      case descriptor["headersHelper"] do
        helper when is_binary(helper) and helper != "" ->
          Map.put(entry, "headersHelper", helper)

        _ ->
          entry
      end

    {provider, entry}
  end

  defp tool_server_entry(_), do: :skip

  @doc """
  The API URL the loopback `bp mcp serve` child talks to. Config
  `:mcp_api_url` when set; otherwise the LOCAL listener
  (`http://127.0.0.1:<endpoint port>`) — the child runs on this host, so the
  loopback address skips the public proxy and works before any DNS/TLS exists.
  """
  @spec mcp_api_url() :: String.t()
  def mcp_api_url do
    Keyword.get(config(), :mcp_api_url) || default_mcp_api_url()
  end

  defp default_mcp_api_url do
    http = :barkpark |> Application.get_env(BarkparkWeb.Endpoint, []) |> Keyword.get(:http)
    port = if is_list(http), do: Keyword.get(http, :port, 4000), else: 4000
    port = if is_integer(port), do: port, else: 4000
    "http://127.0.0.1:#{port}"
  end

  # ── spawn env: bp credentials in, prod secrets out (charter D1/D3) ────────

  # The poison sentinel injected as BARKPARK_API_TOKEN when the session-token
  # mint was refused (or never attempted). NEVER omit the var instead: bp's
  # credential precedence (flags > env > persisted ~/.config/barkpark > baked
  # dev-token) would silently fall through to a possibly different server or a
  # higher-privileged persisted token. With the sentinel, the URL still points
  # at THIS server, so every call 401s HERE — loud, local, diagnosable.
  @mint_refused_sentinel "bpcs-mint-refused"

  @doc "The poison BARKPARK_API_TOKEN injected when the mint was refused (D2)."
  @spec mint_refused_sentinel() :: String.t()
  def mint_refused_sentinel, do: @mint_refused_sentinel

  # Secret env vars the child must NEVER inherit: everything secret-valued that
  # config/runtime.exs reads, plus RELEASE_COOKIE (BEAM distribution) and
  # BARKPARK_TOKEN (the host's bp credential — typically ADMIN), plus the
  # Hetzner tokens a cloud host's .env exports, plus BARKPARK_ADMIN_TOKEN
  # (ApiTesterLive-reachable, charter D173) and BARKPARK_SEED_ADMIN_TOKEN
  # (deploy-shell-only, scrubbed defensively). Unsetting an absent var is a
  # proven no-op, so the list errs wide. HOME and PATH are deliberately NOT
  # here — the merge keeps them, and claude's OAuth lives under $HOME.
  @scrubbed_env ~w(
    DATABASE_URL SECRET_KEY_BASE RELEASE_COOKIE BARKPARK_TOKEN
    BARKPARK_CLOAK_KEY BARKPARK_KEK BARKPARK_KEK_PREVIOUS
    BOKBASEN_CLIENT_ID BOKBASEN_CLIENT_SECRET
    INDX_USER_EMAIL INDX_USER_PASSWORD INDX_API_TOKEN
    BARKPARK_SYNC_TOKEN
    BARKPARK_RELEASE_CAPTURE_TOKEN BARKPARK_RELEASE_CAPTURE_HMAC_SECRET
    MEDIA_SIGNING_SECRET MEDIA_CDN_INVALIDATION_SECRET
    MEDIA_PROCESSING_CALLBACK_TOKEN MEDIA_WEBHOOK_SECRET
    SMTP_USERNAME SMTP_PASSWORD
    PREVIEW_JWT_SECRET
    BARKPARK_INGEST_TOKEN PAPERFLOW_INGEST_TOKEN
    HETZNER_API_TOKEN HCLOUD_TOKEN
    CONNECTORS_CONNECT_SECRET
    BARKPARK_ADMIN_TOKEN BARKPARK_SEED_ADMIN_TOKEN
  )

  @doc "The secret env var names scrubbed from every chat child (charter D3)."
  @spec scrubbed_env_names() :: [String.t()]
  def scrubbed_env_names, do: @scrubbed_env

  # Secret-shaped env vars that are DELIBERATELY inherited (never scrubbed).
  # This is the rationale-carrying exception to the api/lib-wide self-audit
  # (claude_chat_test.exs — "the denylist covers every secret-shaped env read
  # in api/lib"): a secret read that is neither scrubbed NOR listed here reds
  # the audit, forcing a conscious scrub-or-allowlist decision.
  #
  # ANTHROPIC_API_KEY (charter D23): it IS the cloud path's `claude` auth
  # mechanism. The claude CLI natively authenticates on this var, and whether
  # cloud-sandbox-runner.mjs depends on inheriting it is UNRESOLVED Node-side —
  # a blind scrub could break the human-gated cloud turn. NEVER blind-scrub it;
  # the local in-process reads (studio_chat/titles.ex, tasks/judge.ex) are the
  # server's own Anthropic identity, out of the chat child's scrub scope by
  # design.
  @intentional_env_passthrough ~w(
    ANTHROPIC_API_KEY
  )

  @doc """
  Secret-shaped env var names that are DELIBERATELY inherited by chat children
  rather than scrubbed (charter D23). The self-audit asserts every secret read
  in `api/lib` is either scrubbed (`scrubbed_env_names/0`) OR listed here —
  a flat subset would fail forever on this legitimate exception.
  """
  @spec intentional_env_passthrough_names() :: [String.t()]
  def intentional_env_passthrough_names, do: @intentional_env_passthrough

  @doc """
  The `env:` option for the chat child's `Port.open` (charter D1/D3). Injects
  the bp credential seam — `BARKPARK_API_URL` (this server's loopback),
  `BARKPARK_API_TOKEN` (the minted session token, or the poison sentinel on a
  refused mint), `BARKPARK_WORKER_ID` — and UNSETS every secret in
  `scrubbed_env_names/0`. Without this, the child inherits the FULL BEAM env
  (DATABASE_URL, SECRET_KEY_BASE, every token — a live-proven leak).

  OTP semantics (proven 26–28): `:env` MERGES into the inherited env (HOME and
  PATH survive, so claude's OAuth is unaffected); `{~c"NAME", false}` unsets;
  both key AND value must be charlists — a binary on either side is an
  ArgumentError at `Port.open`. The sibling `args:` list stays binaries.

  Injection propagates to grandchildren (claude's Bash subprocesses AND its
  `--mcp-config` MCP child), so one seam feeds both lanes; scrubbed vars stay
  scrubbed down the tree. Pure (config reads only) and public so the tuple
  shape is unit-testable without spawning a Port.
  """
  @spec spawn_env(String.t(), String.t()) :: [{charlist(), charlist() | false}]
  def spawn_env(raw_token, worker_id) when is_binary(raw_token) and is_binary(worker_id) do
    [
      {~c"BARKPARK_API_URL", String.to_charlist(mcp_api_url())},
      {~c"BARKPARK_API_TOKEN", String.to_charlist(raw_token)},
      {~c"BARKPARK_WORKER_ID", String.to_charlist(worker_id)}
    ] ++ Enum.map(@scrubbed_env, &{String.to_charlist(&1), false})
  end

  @doc """
  The bp worker identity for a chat session — `claude-chat-<sid8>` (cmux
  precedent: ONE worker per chat tab, so the agent's subagents share the same
  fencing lease). `sid8` is the first 8 chars of the pinned session uuid;
  an anonymous session (no pinned id) gets the shared `claude-chat-anon`.
  """
  @spec worker_id(String.t() | nil) :: String.t()
  def worker_id(session_id) when is_binary(session_id) and session_id != "",
    do: "claude-chat-" <> String.slice(session_id, 0, 8)

  def worker_id(_), do: "claude-chat-anon"

  @doc """
  Whether a live session got real bp task-hands (charter D2 — the onboarding
  card's `no_task_hands` truth). `:minted` — the env carries a real session
  token; `:mint_refused` — the mint failed and the env carries the poison
  sentinel (`mint_refused_sentinel/0`); `:not_attempted` — the session carried
  no minter principal (no socket identity to mint from); `:unknown` — the
  session is gone.
  """
  @spec task_hands(pid()) :: :minted | :mint_refused | :not_attempted | :unknown
  def task_hands(session) when is_pid(session) do
    GenServer.call(session, :task_hands)
  catch
    :exit, _reason -> :unknown
  end

  defp default_args(mode) do
    [
      "--print",
      "--verbose",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--include-partial-messages",
      "--permission-mode",
      mode,
      # `--permission-prompt-tool stdio` ships in ALL modes, plan included
      # (charter D33). It makes the CLI route permission asks to us as
      # `control_request` (subtype `can_use_tool`) NDJSON events instead of
      # auto-handling them — the Session forwards them as
      # `{:claude_chat_permission, …}` and answers via `respond_permission/3`
      # (the Agent SDK's canUseTool bridge, spoken raw). Plan mode is the
      # product default and EVERY plan session hits ExitPlanMode; without the
      # flag that ask never reaches Barkpark (the CLI auto-handles it), so the
      # proposed-plan card could never render. Consequence accepted: other
      # tools' asks in plan mode now also reach us as honest approval cards.
      "--permission-prompt-tool",
      "stdio",
      "--append-system-prompt",
      render_appendix()
    ]
  end

  # Replies render through Barkpark's paper engine (FromMarkdown -> blocks ->
  # Render). Teach the model the two upgrade fences and the native block
  # vocabulary the converter accepts, so it can answer with real Barkpark
  # blocks (charts, callouts, tables) instead of ASCII approximations.
  defp render_appendix do
    """
    Your replies render inside Barkpark Studio through its PortableDoc paper \
    engine. Write GitHub-flavored markdown. Two special fences upgrade a reply:

    1. ```mermaid — renders as a live diagram figure.
    2. ```portabledoc — a JSON array of native Barkpark blocks, rendered \
    exactly like published papers. Use it whenever data deserves richer form \
    than prose. Supported block types:
    {"type":"callout","tone":"info|success|warning|danger","title":"...","content":[{"type":"text","value":"..."}]}
    {"type":"chart","kind":"line|bars","caption":"...","series":[{"label":"...","points":[1,2,3]}],"axes":{"xLabels":["a","b","c"]}}
    {"type":"stats","items":[{"type":"stat","label":"...","value":"42","max":100,"spark":[1,2,3]}]}
    {"type":"table","head":[[{"type":"text","value":"Col"}]],"rows":[[[{"type":"text","value":"cell"}]]]}
    {"type":"divider"}

    Prefer a chart or stats block over a markdown table of numbers; prefer a \
    callout for warnings and key takeaways. Keep JSON valid — malformed \
    fences degrade to a raw code block.

    When your Barkpark tools (mcp__barkpark__*) are connected, use them to \
    read and file bp tasks, create and edit Papers, and search content — \
    read tools run without asking; writes surface an approval card to the \
    human. To plan AND execute a feature end-to-end, launch the epic cycle: \
    invoke the bp-epic-cycle skill via the Skill tool with the wish as its \
    argument — Skill(skill: "bp-epic-cycle", args: "<the user's one-sentence \
    wish>"); the workflow reads it as args.wish. Track follow-up work as bp \
    tasks, never as markdown TODO lists.
    """
  end

  @doc "Working directory for the subprocess (config `:cwd`, default server cwd)."
  @spec cwd() :: String.t()
  def cwd, do: Keyword.get(config(), :cwd) || File.cwd!()

  @doc """
  Start a chat session subprocess.

  `sink` is the pid that receives:

    * `{:claude_chat_event, map}` — one decoded stream-json event per NDJSON
      line the CLI emits (`system/init`, `stream_event`, `assistant`,
      `result`, …)
    * `{:claude_chat_exit, status, stderr_tail}` — the subprocess ended; the
      bounded tail of the child's captured stderr rides along (empty on a clean
      exit, `nil` on the crash/idle-reap paths that carry no captured stderr) so
      the UI can tell a rejected-argv death from an ordinary end (charter D54)
    * `{:claude_chat_error, :buffer_overflow, stderr_tail}` — the stdout
      line-reassembly buffer crossed `max_buffer_bytes/0`; the session closed the
      Port and stopped cleanly. Carries the same bounded stderr tail as an exit so
      the UI can surface the captured reason.

  The session monitors the sink and shuts the subprocess down when the sink
  dies, so an abandoned LiveView never leaks a `claude` process.

  `:session_opts` (charter D8) pins or resumes a session: `%{session_id: uuid}`
  starts a fresh pinned session, `%{session_id: uuid, resume: true}` resumes an
  existing one. Absent ⇒ an anonymous one-shot session (w1–w2c behavior).
  """
  @spec start_session(%{
          :sink => pid(),
          optional(:mode) => String.t(),
          optional(:session_opts) => map()
        }) :: {:ok, pid()} | {:error, term()}
  def start_session(%{sink: sink} = opts) when is_pid(sink) do
    cond do
      not enabled?() ->
        {:error, :disabled}

      true ->
        # Pass the mode THROUGH — build_args/2 is the single fail-closed seam now
        # (charter D9/D48): it clamps an UNARMED bypassPermissions to plan and lets
        # a legacy `default` spawn verbatim. Re-normalizing here would wrongly clamp
        # BOTH (armed bypass → plan, legacy default → plan), so it must not.
        __MODULE__.Session.start(%{
          sink: sink,
          mode: opts[:mode] || @default_mode,
          session_opts: Map.get(opts, :session_opts, %{})
        })
    end
  end

  @doc """
  Answer a pending `{:claude_chat_permission, …}` ask (charter D32). `decision`:

    * `:allow` — approve, echoing the ORIGINAL ask input back as `updatedInput`
      (the Session tracked it by `request_id` — never trust the caller to
      round-trip it). A bare `{"behavior":"allow"}` FAILS ExitPlanMode on the
      real binary (ZodError, mode stays plan); the CLI's own internal
      `checkPermissions` shape requires `updatedInput`, so plain allow always
      echoes it.
    * `{:allow, updated_input}` — approve with a CALLER-supplied `updatedInput`
      map. Question answers ride here as `%{"questions" => unchanged,
      "answers" => %{<question string> => <value>}}` (proven: the CLI keys
      internally by the question string; multiSelect = comma-joined labels).
    * `{:deny, message}` — refuse; `message` (required by the schema) travels
      back to the model so it can adjust (t3's deny_message).
  """
  @spec respond_permission(pid(), String.t(), :allow | {:allow, map()} | {:deny, String.t()}) ::
          :ok
  def respond_permission(session, request_id, decision)
      when is_pid(session) and is_binary(request_id) do
    GenServer.cast(session, {:respond_permission, request_id, decision})
  end

  @doc """
  Send a user turn to the session as a stream-json user message.

  A `GenServer.call` (charter D24) — the reply carries the REAL write outcome so
  the caller can tell a DISPATCHED turn (the model has it; keep the optimistic
  echo, clear the composer) from a failed one (withdraw the echo, hand the words
  back). `:ok` means the frame reached the port; `{:error, reason}` means it did
  not (a closed/absent port, a write that raised, or a session that has already
  gone — never a false `:ok`). The honesty bar is DISPATCHED, not delivered: a
  later result frame still reports the model's answer.

  `content` is EITHER a plain `String.t()` (the text-only default shape) OR a
  ready content-block list — `[%{"type" => "text", …}, %{"type" => "image",
  "source" => %{"type" => "base64", "media_type" => …, "data" => …}}]` — so a
  turn can carry pasted/dropped images alongside the text (charter D25, proven
  on the real binary v2.1.205: a mixed text+image content list is accepted and
  the model sees the image). A binary is wrapped into a single text block; a
  list rides the user frame verbatim.
  """
  @spec send_message(pid(), String.t() | [map()]) :: :ok | {:error, term()}
  def send_message(session, content)
      when is_pid(session) and (is_binary(content) or is_list(content)) do
    GenServer.call(session, {:send_user_message, content})
  catch
    # The session GenServer died between the caller's `ensure_session` and this
    # call (port exit, teardown). That is a failed dispatch, not a crash — the
    # composer must restore, so surface it as an honest {:error}.
    :exit, reason -> {:error, {:not_running, reason}}
  end

  @doc """
  Interrupt the running turn (charter D10). Writes a `control_request` frame
  with subtype `interrupt` on stdin — proven on the raw wire 2026-07-09: the
  CLI acks with a `control_response` (subtype `success`), aborts the turn, and
  the session SURVIVES (the terminal `result` carries
  `terminal_reason: "aborted_streaming"`, which the LiveView discriminates from
  a real error). Returns the minted `request_id` so the caller can match the
  ack (forwarded to the sink as a `{:claude_chat_event, control_response}`).
  """
  @spec interrupt(pid()) :: {:ok, String.t()}
  def interrupt(session) when is_pid(session) do
    control_request(session, %{"subtype" => "interrupt"})
  end

  @doc """
  Switch the permission mode of a live session in place (charter D12),
  replacing the context-destroying respawn. The wire key MUST be `mode`: the
  real binary treats the plausible-looking `permission_mode` key as a silent
  no-op (returns success with an EMPTY response). Returns the minted
  `request_id`; the LiveView must confirm the echoed `response.mode` before
  trusting the switch (subtype `success` alone is a vacuous-green trap).
  """
  @spec set_permission_mode(pid(), String.t()) :: {:ok, String.t()}
  def set_permission_mode(session, mode) when is_pid(session) and is_binary(mode) do
    control_request(session, %{"subtype" => "set_permission_mode", "mode" => mode})
  end

  @doc """
  Switch the model of a live session in place. Returns the minted `request_id`;
  the caller should verify the next `result` frame's `modelUsage` key actually
  changed before trusting the switch (the CLI acks `success` regardless).
  """
  @spec set_model(pid(), String.t()) :: {:ok, String.t()}
  def set_model(session, model) when is_pid(session) and is_binary(model) do
    control_request(session, %{"subtype" => "set_model", "model" => model})
  end

  @doc """
  Ask the CLI for its capability + slash-command list (charter D36a). Writes a
  bare `{"subtype":"initialize"}` control_request on stdin — proven on the real
  binary v2.1.205 to answer IMMEDIATELY at spawn, BEFORE any turn, with
  `response.commands` (`[%{"name", "description", "argumentHint", "aliases"}]`).
  Sent right after spawn by the Recorder; the ack dispatches as a TYPED
  `{:claude_chat_control, :initialize, request_id, response}` so it is not eaten
  by the catch-all. Returns the minted `request_id`.
  """
  @spec initialize(pid()) :: {:ok, String.t()}
  def initialize(session) when is_pid(session) do
    control_request(session, %{"subtype" => "initialize"})
  end

  # Mint a request_id and cast an outbound control_request frame. The id lets
  # the caller correlate the CLI's control_response ack (forwarded to the sink).
  defp control_request(session, request) when is_map(request) do
    request_id = mint_request_id()
    GenServer.cast(session, {:control_request, request_id, request})
    {:ok, request_id}
  end

  defp mint_request_id do
    "bp-req-" <> (8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  end

  @doc """
  Take over a running session's event stream (charter D20 — single writer).

  Two tabs must never each spawn a `claude --resume` process against the same
  session: two OS processes writing the CLI's own transcript concurrently. The
  `Session` registers under `{:via, Barkpark.StudioChat.SessionRegistry, uuid}`
  when its `session_id` is pinned, so the SECOND tab's `start_session/1` returns
  `{:error, {:already_started, pid}}` instead of spawning. That tab calls this
  to become the sole sink: the `Session` demonitors the previous sink, monitors
  the caller, and sends `{:claude_chat_detached}` to the old sink so its tab can
  show an honest "opened in another tab" banner and disable its composer. The
  old tab takes back the same way on its next send. Adopting into the SAME sink
  is a harmless no-op.
  """
  @spec adopt_sink(pid(), pid()) :: :ok
  def adopt_sink(session, new_sink) when is_pid(session) and is_pid(new_sink) do
    GenServer.cast(session, {:adopt_sink, new_sink})
  end

  @doc "Terminate the session subprocess."
  @spec close(pid()) :: :ok
  def close(session) when is_pid(session) do
    GenServer.cast(session, :close)
  end

  @doc """
  Split a stdout buffer into decoded NDJSON events and the trailing partial
  line. Non-JSON complete lines are dropped (logged at debug) — the CLI's
  stdout is JSON-only, but we never let a stray line crash the session.
  """
  @spec parse_chunk(String.t(), String.t()) :: {[map()], String.t()}
  def parse_chunk(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    parts = String.split(buffer <> chunk, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)

    events =
      complete
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, event} when is_map(event) ->
            [event]

          _ ->
            Logger.debug("claude chat: ignoring non-JSON stdout line (#{byte_size(line)} bytes)")
            []
        end
      end)

    {events, rest}
  end

  defp config, do: Application.get_env(:barkpark, :claude_chat, [])

  defmodule Session do
    @moduledoc """
    One chat subprocess. Owns the Port, assembles NDJSON lines off stdout,
    and forwards decoded events to the sink. Deliberately un-supervised and
    unlinked: it lives and dies with the LiveView that started it (the sink
    is monitored; sink death stops the session and the Port closes with it).
    """

    use GenServer, restart: :temporary

    require Logger

    alias BarkparkWeb.Studio.ClaudeChat

    # Single-writer registry (charter D20). When a session id is pinned, the
    # process registers here under the uuid so a SECOND tab that tries to start
    # the same session gets `{:error, {:already_started, pid}}` and adopts the
    # running process rather than spawning a second `claude --resume` writer.
    @registry Barkpark.StudioChat.SessionRegistry

    # The child's stderr is captured through this shell so stdout stays pristine
    # ndjson (charter D54). `/bin/sh` is POSIX-guaranteed on every host we run.
    @shell "/bin/sh"
    # Bound the exit reason we read back: at most the last few KB / lines of
    # stderr, so a chatty process can never blow up the exit message.
    @stderr_tail_bytes 8_192
    @stderr_tail_lines 20

    @spec start(%{sink: pid()}) :: {:ok, pid()} | {:error, term()}
    def start(opts) do
      case pinned_session_id(opts) do
        nil ->
          # Anonymous one-shot (no session identity) — nothing to serialize on,
          # so it stays unnamed (two anonymous chats never share a transcript).
          GenServer.start(__MODULE__, opts)

        uuid ->
          GenServer.start(__MODULE__, opts, name: {:via, Registry, {@registry, uuid}})
      end
    end

    # A pinned OR resumed session both key on the same minted uuid — the whole
    # point of D8's one-identity design: `--session-id` and `--resume` name the
    # same transcript, so both must register under it.
    defp pinned_session_id(opts) do
      case Map.get(opts, :session_opts, %{}) do
        %{session_id: id} when is_binary(id) -> id
        _ -> nil
      end
    end

    # All file paths used by this callback are minted below from the OS temp
    # directory and a server-owned session identity; none comes from a request.
    # sobelow_skip ["Traversal.FileModule"]
    @impl true
    def init(%{sink: sink} = opts) do
      session_opts = Map.get(opts, :session_opts, %{})

      # Give the subprocess its hands BEFORE the argv is assembled (charter
      # D63/D64): mint the session-scoped token and write the per-session temp
      # mcp-config here — init owns the impure work; `build_args/2` stays pure
      # (D9) and merely references the path. ONE mint feeds BOTH consumers
      # (charter D1): the mcp-config env block and the spawn env below. Fail
      # soft, never silent: a failed config write drops only the MCP lane (the
      # spawn env still carries the real token — bp-on-PATH keeps its hands);
      # a refused mint poisons the spawn env with the sentinel (D2) — never a
      # dead chat, never host-credential inheritance.
      mcp = setup_mcp(opts, session_opts)

      session_opts =
        case mcp do
          %{config_path: path} when is_binary(path) ->
            Map.put(session_opts, :mcp_config_path, path)

          _ ->
            session_opts
        end

      # Resolve the turn's EFFECTIVE execution profile ONCE from the session's
      # workspace (connectors D205 — the per-workspace consumer seam): a
      # workspace with `settings["chat"]["execution_profile"]` set wins over
      # the global config in both directions; nil workspace / missing row /
      # unset key / any lookup failure falls through to the global config and
      # thus :self_hosted (fail-safe, never fail-cloud). The stashed profile
      # feeds BOTH consumers below — the descriptor threading AND `command/2` —
      # so a cloud-profiled workspace can never get a cloud turn with no tool
      # descriptors (a half-resolution is banned by D205).
      session_opts = ClaudeChat.resolve_workspace_execution_profile(session_opts)

      # For a :cloud turn, fetch this workspace's tool-connector descriptors
      # HOST-side (the SAME fail-soft bridge idiom as setup_mcp) and thread them
      # into session_opts so `cloud_build_args/2` can emit the scoped
      # `--mcp-config-b64` (knob 3's CONFIG half, D126/D127). Self-hosted turns
      # are untouched — their descriptors ride the per-session mcp-config FILE
      # instead. No bridge / no workspace ⇒ [] ⇒ argv byte-identical to W12.
      session_opts = maybe_thread_cloud_tool_descriptors(session_opts)

      {exe, args} = ClaudeChat.command(Map.get(opts, :mode, "plan"), session_opts)

      case System.find_executable(exe) do
        nil ->
          # An init-time stop skips terminate/2 — release the minted credential
          # + temp config inline so neither outlives a spawn that never was.
          cleanup_mcp(%{mcp_token: mcp.token, mcp_config_path: mcp.config_path})
          {:stop, :binary_not_found}

        path ->
          # Capture the child's stderr WITHOUT polluting stdout (charter D54).
          # A rejected argv exits nonzero with the reason on stderr and ZERO
          # ndjson frames on stdout; a plain Port drops the only diagnosis, so
          # the UI keeps inviting a resume that re-dies identically. Spawn
          # through `/bin/sh -c 'exec "$0" "$@" 2>>file'`: `exec` REPLACES the
          # shell with `claude`, so Port close/signals still reach the CLI and
          # stdout stays pristine — only fd 2 is redirected to a bounded
          # per-session file we tail on exit. Transparent to any executable, so
          # the fake-subprocess test harness runs through it unchanged.
          stderr_path = stderr_path(opts)
          _ = File.rm(stderr_path)

          # The bp credential seam + secret scrub (charter D1/D3). The raw
          # minted token exists only here and inside the config file — the env
          # tuples hand it to the OS; state keeps the STRUCT for revocation,
          # never the secret. A refused/never-attempted mint injects the
          # poison sentinel, NEVER absence (D2): bp's precedence would
          # otherwise fall through to the host's persisted — possibly admin —
          # credentials. Charlists BOTH sides; the sibling args: stay binaries.
          env =
            ClaudeChat.spawn_env(
              mcp.raw || ClaudeChat.mint_refused_sentinel(),
              ClaudeChat.worker_id(pinned_session_id(opts))
            )

          port =
            Port.open(
              {:spawn_executable, @shell},
              [
                :binary,
                :exit_status,
                :hide,
                args: ["-c", ~s(exec "$0" "$@" 2>>"#{stderr_path}"), path | args],
                env: env,
                cd: ClaudeChat.cwd()
              ]
            )

          # Keep the monitor ref so an adopt can cleanly demonitor the outgoing
          # sink (a bare Process.monitor/1 leaks a ref that would fire a stale
          # DOWN and stop a session the new owner is still driving).
          sink_ref = Process.monitor(sink)

          {:ok,
           %{
             port: port,
             sink: sink,
             sink_ref: sink_ref,
             # The child's OS pid, read while the port is certainly alive.
             # `cleanup_stderr/1` waits on THIS pid before removing the capture
             # file: the shell creates it via `2>>` (O_CREAT) asynchronously
             # after Port.open, so an rm that merely follows Port.close races
             # that open and the shell RE-CREATES the file — every "passing"
             # close leaked one (spd-bl-claude-chat-stderr-leak).
             os_pid: port_os_pid(port),
             stderr_path: stderr_path,
             # The loopback credential + temp config (charter D63/D64): revoked
             # and removed in BOTH terminate clauses; the token's short TTL is
             # the crash backstop. The STRUCT rides state (for revocation) —
             # never the raw secret, which lives only in the spawn env + the
             # config file. `task_hands` is the queryable mint outcome the
             # onboarding card reads (charter D2 — no_task_hands, never silent).
             mcp_token: mcp.token,
             mcp_config_path: mcp.config_path,
             task_hands: mcp.mint,
             buffer: "",
             pending_controls: %{},
             # request_id → the ORIGINAL ask input, tracked so a plain `:allow`
             # echoes it back as `updatedInput` (charter D32 — a bare allow fails
             # ExitPlanMode; the CLI wants its own checkPermissions shape).
             pending_asks: %{}
           }}
      end
    rescue
      e ->
        Logger.warning("claude chat: failed to spawn subprocess: #{inspect(e)}")
        {:stop, :spawn_failed}
    end

    @impl true
    def handle_call({:send_user_message, content}, _from, state) do
      line =
        Jason.encode!(%{
          "type" => "user",
          "message" => %{
            "role" => "user",
            "content" => user_content_blocks(content)
          }
        }) <> "\n"

      # Reply with the REAL write outcome (charter D24) — the LiveView gates its
      # optimistic echo on a DISPATCHED frame, so a swallowed failure would lie.
      {:reply, safe_command(state.port, line), state}
    end

    # The queryable mint outcome (charter D2): what BARKPARK_API_TOKEN the
    # child actually got — a real minted token, the poison sentinel, or no
    # attempt at all. The onboarding-card slice renders no_task_hands off this.
    def handle_call(:task_hands, _from, state) do
      {:reply, state.task_hands, state}
    end

    @impl true
    def handle_cast({:respond_permission, request_id, decision}, state) do
      # Consume the tracked ask (charter D32): a plain `:allow` echoes its input
      # verbatim as `updatedInput`; a `{:allow, updated}` carries the caller's
      # map (question answers); a deny drops it. Pruned either way so the map
      # never grows unbounded across a long session.
      {ask, pending_asks} = Map.pop(state.pending_asks, request_id)
      original = ask && ask.input

      payload =
        case decision do
          :allow ->
            %{"behavior" => "allow", "updatedInput" => original || %{}}

          {:allow, updated} when is_map(updated) ->
            %{"behavior" => "allow", "updatedInput" => updated}

          {:deny, message} ->
            %{"behavior" => "deny", "message" => to_string(message)}
        end

      line =
        Jason.encode!(%{
          "type" => "control_response",
          "response" => %{
            "subtype" => "success",
            "request_id" => request_id,
            "response" => payload
          }
        }) <> "\n"

      safe_command(state.port, line)

      # An allowed ExitPlanMode IS the plan-approve fact: report it to the sink
      # AFTER the control_response is on the wire (stdio is serialized, so any
      # follow-up steer lands behind the CLI's own internal mode flip). Fact
      # only — the mode POLICY lives in the Recorder, never here. `ask` is nil
      # for an untracked request_id (a bare answer with no pending ask) — the
      # strict-boolean `and` needs the explicit nil check, never truthiness.
      if ask != nil and ask.tool_name == "ExitPlanMode" and
           (decision == :allow or match?({:allow, _}, decision)) do
        send(state.sink, {:claude_chat_plan_approved, request_id})
      end

      {:noreply, %{state | pending_asks: pending_asks}}
    end

    # Outbound control_request (interrupt / set_permission_mode / set_model).
    # The CLI answers with a control_response echoing this request_id. We map
    # request_id → kind here so the inbound ack dispatches as a TYPED
    # {:claude_chat_control, kind, request_id, response} (charter D17/D23) —
    # otherwise the ack falls through to the generic sink event and the ChatLive
    # catch-all eats it. The request_id rides the dispatch so the consumer can
    # ignore a stale ack from a superseded switch (correlate, don't guess).
    def handle_cast({:control_request, request_id, request}, state) do
      line =
        Jason.encode!(%{
          "type" => "control_request",
          "request_id" => request_id,
          "request" => request
        }) <> "\n"

      safe_command(state.port, line)

      state =
        case control_kind(request) do
          nil -> state
          kind -> put_in(state.pending_controls[request_id], kind)
        end

      {:noreply, state}
    end

    # Single-writer takeover (charter D20). A second tab that found this session
    # already running adopts it as the sole sink: demonitor the outgoing sink
    # (flush any in-flight DOWN so it can't stop us), monitor the newcomer, and
    # tell the old sink it was detached so its tab shows the honest banner. The
    # session lifetime now follows the NEW sink; the old tab takes back the same
    # way on its next send.
    def handle_cast({:adopt_sink, new_sink}, %{sink: old_sink} = state)
        when is_pid(new_sink) do
      if new_sink == old_sink do
        {:noreply, state}
      else
        if ref = state[:sink_ref], do: Process.demonitor(ref, [:flush])
        new_ref = Process.monitor(new_sink)
        send(old_sink, {:claude_chat_detached})
        {:noreply, %{state | sink: new_sink, sink_ref: new_ref}}
      end
    end

    def handle_cast(:close, state), do: {:stop, :normal, state}

    @impl true
    def handle_info({port, {:data, chunk}}, %{port: port} = state) do
      # Cap the line-reassembly buffer WHERE the bytes arrive (charter D126). The
      # CLI streams newline-delimited JSON, so parse_chunk normally hands back only
      # the trailing partial line — but a malformed/stalled stream that never emits
      # a newline would grow `state.buffer` without bound in this long-lived
      # per-session GenServer (the codex-twin scar-class). Check the accumulated
      # size BEFORE parse_chunk consumes it: on breach close the Port and stop the
      # session with a named overflow error. terminate/2 still runs (revokes the
      # MCP token + removes the stderr tmpfile) — port is nil'd so it closes once.
      buffered = byte_size(state.buffer) + byte_size(chunk)
      cap = ClaudeChat.max_buffer_bytes()

      if buffered > cap do
        Logger.warning(
          "claude chat: stdout buffer #{buffered} bytes exceeds #{cap}-byte cap; closing session"
        )

        if port in Port.list(), do: Port.close(port)

        send(
          state.sink,
          {:claude_chat_error, :buffer_overflow, read_stderr_tail(state[:stderr_path])}
        )

        {:stop, :normal, %{state | port: nil}}
      else
        {events, rest} = ClaudeChat.parse_chunk(state.buffer, chunk)
        # Thread state so a control_response ack can prune its pending entry.
        state = Enum.reduce(events, %{state | buffer: rest}, &dispatch_event/2)
        {:noreply, state}
      end
    end

    def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
      # Carry the bounded stderr tail (charter D54) so the UI can distinguish a
      # rejected-argv death (nonzero, zero frames — a resume would re-die) from
      # an ordinary end that resumes cleanly.
      send(state.sink, {:claude_chat_exit, status, read_stderr_tail(state[:stderr_path])})
      {:stop, :normal, %{state | port: nil}}
    end

    def handle_info({:DOWN, _ref, :process, sink, _reason}, %{sink: sink} = state) do
      {:stop, :normal, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, %{port: port} = state) when is_port(port) do
      # Closing the Port closes the subprocess's stdin; the CLI exits on EOF.
      if port in Port.list(), do: Port.close(port)
      cleanup_stderr(state)
      cleanup_mcp(state)
      :ok
    rescue
      _ -> :ok
    end

    def terminate(_reason, state) do
      cleanup_stderr(state)
      cleanup_mcp(state)
      :ok
    end

    # The stderr capture file must not outlive the session (charter D54) — remove
    # it on every teardown path (clean close, exit, crash). Best-effort.
    #
    # AFTER THE CHILD IS REAPED, not merely after Port.close
    # (spd-bl-claude-chat-stderr-leak): the spawn shell opens the `2>>` capture
    # file (O_CREAT) asynchronously after Port.open, so an immediate rm races
    # that open — if rm wins, the shell re-creates the file a moment later and
    # the capture OUTLIVES the session on every close of that shape (measured
    # 6/6 leaks on passing runs). Once the pid is gone the `2>>` open has
    # either happened or never will, so the rm below is race-free. The wait is
    # BOUNDED: on the exit-status path the child is already dead so it costs
    # one probe; the close-while-alive path polls `kill -0` for at most ~1s
    # and then removes best-effort anyway.
    # sobelow_skip ["Traversal.FileModule"]
    defp cleanup_stderr(%{stderr_path: path} = state) when is_binary(path) do
      await_child_exit(Map.get(state, :os_pid), 100)
      File.rm(path)
    end

    defp cleanup_stderr(_), do: :ok

    # The child's OS pid, read at spawn time (Port.info answers nil once the
    # port closes, which is exactly when cleanup needs the pid).
    defp port_os_pid(port) do
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end
    end

    # Bounded reap-wait: `kill -0` (signal 0) probes liveness without
    # signalling. ~10ms per round, `rounds` rounds — then give up and let the
    # caller proceed best-effort. A nil pid (spawn raced away) waits nothing.
    defp await_child_exit(nil, _rounds), do: :ok
    defp await_child_exit(_pid, 0), do: :ok

    defp await_child_exit(pid, rounds) when is_integer(pid) do
      case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
        {_, 0} ->
          Process.sleep(10)
          await_child_exit(pid, rounds - 1)

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end

    # The loopback credential + temp config must not outlive the session
    # (charter D63): revoke the token (idempotent — a re-revoke merely
    # re-stamps `revoked_at`) and remove the config file on EVERY teardown
    # path, mirroring cleanup_stderr. Total and best-effort: a dead Repo at
    # teardown must never turn a normal stop into a crash — the token's short
    # TTL is the crash backstop.
    # sobelow_skip ["Traversal.FileModule"]
    defp cleanup_mcp(%{mcp_token: token} = state) when not is_nil(token) do
      safe_revoke(token)
      cleanup_mcp_file(state)
    end

    defp cleanup_mcp(state) when is_map(state), do: cleanup_mcp_file(state)
    defp cleanup_mcp(_), do: :ok

    # The path was minted by `mcp_config_path/1` under the OS temp directory.
    # sobelow_skip ["Traversal.FileModule"]
    defp cleanup_mcp_file(%{mcp_config_path: path}) when is_binary(path), do: File.rm(path)
    defp cleanup_mcp_file(_), do: :ok

    # Revoke BY ID, never by the held struct: a row that vanished under us
    # (a test sandbox rollback; an operator hard-delete) is a clean
    # `:not_found` on the id path — a struct changeset would raise
    # StaleEntryError. `catch` covers DB exits (a Repo already shut down at
    # teardown) as well as exceptions: teardown never crashes over cleanup.
    # Sandbox-teardown races (the ownership process died WITH the session —
    # the row was rolled back with it) log at debug; anything else warns, and
    # the token's short TTL backstops a genuinely unreachable Repo.
    defp safe_revoke(%{id: token_id}) when is_binary(token_id) do
      _ = Barkpark.Auth.revoke_token(token_id)
      :ok
    rescue
      e in DBConnection.OwnershipError ->
        Logger.debug("claude chat: mcp token revoke skipped (sandbox gone): #{inspect(e)}")
        :ok

      e ->
        Logger.warning("claude chat: mcp token revoke failed: #{inspect(e)}")
        :ok
    catch
      :exit, reason ->
        Logger.debug("claude chat: mcp token revoke skipped (repo down): #{inspect(reason)}")
        :ok
    end

    defp safe_revoke(_), do: :ok

    # Mint the loopback credential + write the per-session mcp-config (charter
    # D63/D64). Only a session that carries a `:minter` principal — the chat
    # admin's api_token/user, threaded from the socket — gets hands, and never
    # more rights than that human holds (`Auth.create_claude_session_token/3`
    # authorizes the mint up front via Tenancy.Auth.authorize/3). ONE mint,
    # two consumers (charter D1): `raw` feeds the spawn env AND the config
    # file's env block; the STRUCT rides back for revocation. A failed config
    # write keeps the token alive (env-only hands — the Bash-lane bp still
    # works); a refused/crashed mint returns `:mint_refused` so init poisons
    # the env with the sentinel (D2) — the chat spawns either way, never dead.
    defp setup_mcp(opts, %{minter: minter}) when not is_nil(minter) do
      session_id = pinned_session_id(opts) || "anonymous"

      case Barkpark.Auth.create_claude_session_token(minter, session_id) do
        {:ok, {raw, token}} ->
          # The OTHER direction (connectors D69): fetch this workspace's TOOL
          # connectors from the bridge and fold them into the config as extra
          # `mcpServers` keys. Scoped to the MINTED token's workspace — the SAME
          # workspace the loopback bp token authorizes — so tool scope and chat
          # scope agree by construction, not by hope. Fail-soft: an instance with
          # no connect seam (or an unreachable bridge) simply gets no tool
          # servers, exactly as before this wave. The self-hosted mcp-config file
          # embeds each descriptor's own ticket-authenticated headersHelper, so the
          # surfaced tool-session ticket is unused on this path (it rides the
          # :cloud b64 payload only — W25-E).
          {_tool_ticket, descriptors} = tool_descriptors_for(token.workspace_id)

          %{
            mint: :minted,
            raw: raw,
            token: token,
            config_path: write_mcp_config(opts, raw, descriptors)
          }

        {:error, reason} ->
          Logger.warning(
            "claude chat: mcp token mint refused (#{inspect(reason)}) — poisoning task hands"
          )

          %{mint: :mint_refused, raw: nil, token: nil, config_path: nil}
      end
    rescue
      e ->
        Logger.warning("claude chat: mcp setup crashed (#{inspect(e)}) — poisoning task hands")

        %{mint: :mint_refused, raw: nil, token: nil, config_path: nil}
    end

    defp setup_mcp(_opts, _session_opts),
      do: %{mint: :not_attempted, raw: nil, token: nil, config_path: nil}

    # The tool-connector fetch (connectors D69/D73) — the outbound direction. Sign
    # a session-length tool ticket for `workspace_id` and ask the bridge which MCP
    # servers this workspace's agent may connect to. Every step is FAIL-SOFT to an
    # empty list, because a missing/broken tool seam must NEVER poison a chat
    # session (the loopback `barkpark` server is what makes the chat useful; tool
    # connectors are additive):
    #
    #   * no connect secret (the default instance)      -> {:error, :not_configured}
    #   * the bridge does not implement the callback     -> function_exported? false
    #   * the bridge is unreachable / refuses            -> {:error, _}
    #   * any crash                                      -> rescued
    #
    # ONLY a `{:ok, list}` yields tool servers. D38 holds: the bridge returns
    # NON-SECRET descriptors; the subprocess fetches the PAT via `headersHelper`;
    # Elixir never decrypts and never holds plaintext.
    #
    # Returns `{ticket, descriptors}`: the SAME workspace-scoped tool-session
    # ticket that authorized the descriptor fetch is surfaced so a :cloud turn can
    # thread it into the b64 mcp payload as `bpConnectorTicket` (W25-E, D214/D217)
    # — the shim reads it HOST-side to fetch each connector's FINISHED auth headers
    # from the bridge (the bridge owns decryption, D213). It is
    # minted EXACTLY ONCE here (never a second mint downstream); the self-hosted
    # mcp-config path ignores it (its descriptors carry a self-fetching
    # headersHelper). Any failure path returns `{nil, []}` — no ticket, no servers.
    defp tool_descriptors_for(workspace_id) when is_binary(workspace_id) do
      alias Barkpark.Connectors
      alias Barkpark.Connectors.ConnectTicket

      with {:ok, ticket} <- ConnectTicket.sign_tool(workspace_id),
           bridge when is_atom(bridge) and not is_nil(bridge) <- Connectors.bridge(),
           true <- Code.ensure_loaded?(bridge),
           true <- function_exported?(bridge, :fetch_tool_descriptors, 1),
           {:ok, descriptors} when is_list(descriptors) <- bridge.fetch_tool_descriptors(ticket) do
        {ticket, descriptors}
      else
        _ -> {nil, []}
      end
    rescue
      e ->
        Logger.warning(
          "claude chat: tool-descriptor fetch crashed (#{inspect(e)}) — no tool servers"
        )

        {nil, []}
    end

    defp tool_descriptors_for(_), do: {nil, []}

    # Thread the workspace's tool-connector descriptors into session_opts for a
    # :cloud turn only (knob 3 CONFIG half, D126/D127) — the SAME host-side,
    # fail-soft `tool_descriptors_for/1` fetch the self-hosted mcp-config uses,
    # keyed on the cloud turn's session-opts workspace_id (D110 guarantees it is
    # present). `cloud_build_args/2` reads `:tool_descriptors` and CloudPolicy
    # cross-checks them against the workspace's live installs. A self-hosted turn
    # is returned untouched (its descriptors ride the mcp-config file); a cloud
    # turn with no bridge/workspace gets `[]` ⇒ argv byte-identical to W12.
    # Reads the SAME per-spawn resolution `init/1` stashed into session_opts
    # (connectors D205) — never a second/global-only read, which would strip a
    # cloud-profiled workspace's tool descriptors.
    defp maybe_thread_cloud_tool_descriptors(session_opts) do
      if ClaudeChat.execution_profile(session_opts) == :cloud do
        # ONE `tool_descriptors_for/1` call ⇒ ONE mint: store the descriptors AND
        # the SAME tool-session ticket that authorized their fetch. `cloud_build_args/2`
        # emits the ticket as `bpConnectorTicket` in the b64 payload beside
        # `mcpServers` (W25-E, D214/D217) — the shim reads it HOST-side to fetch each
        # connector's FINISHED auth headers from the bridge. A turn with no bridge/workspace gets
        # `{nil, []}` ⇒ no descriptors, no ticket ⇒ argv byte-identical to W12.
        {ticket, descriptors} = tool_descriptors_for(Map.get(session_opts, :workspace_id))

        session_opts
        |> Map.put(:tool_descriptors, descriptors)
        |> Map.put(:tool_session_ticket, ticket)
      else
        session_opts
      end
    end

    # Serialize the mcp-config to its per-session temp file. Fail-soft to nil
    # (the MCP lane is lost, the spawn-env lane keeps the SAME token): the
    # mint stays valid, so a transient tmp-dir problem degrades hands, never
    # revokes them. Rescues internally so a post-mint crash can't leak the
    # token past setup_mcp's return.
    # `mcp_config_path/1` always anchors this file in `System.tmp_dir!/0`.
    # sobelow_skip ["Traversal.FileModule"]
    defp write_mcp_config(opts, raw, tool_descriptors) do
      path = mcp_config_path(opts)
      json = Jason.encode!(ClaudeChat.mcp_config(raw, tool_descriptors))

      # 0600 BEFORE the secret lands: create empty, clamp perms, then write.
      with :ok <- File.touch(path),
           :ok <- File.chmod(path, 0o600),
           :ok <- File.write(path, json) do
        path
      else
        {:error, reason} ->
          Logger.warning(
            "claude chat: mcp config write failed (#{inspect(reason)}) — env-only task hands"
          )

          _ = File.rm(path)
          nil
      end
    rescue
      e ->
        Logger.warning(
          "claude chat: mcp config write crashed (#{inspect(e)}) — env-only task hands"
        )

        nil
    end

    # The per-session temp mcp-config file — the stderr_path keying pattern
    # (pinned session id, or a unique anon token); removed on every teardown.
    defp mcp_config_path(opts) do
      token =
        case pinned_session_id(opts) do
          id when is_binary(id) -> id
          _ -> "anon-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
        end

      Path.join(System.tmp_dir!(), "barkpark-claude-#{token}.mcp.json")
    end

    # A per-session file for the child's stderr. Keyed by the pinned session id
    # (stable across a resume respawn) or a unique token for an anonymous chat;
    # lives under the OS temp dir and is removed on teardown.
    defp stderr_path(opts) do
      token =
        case pinned_session_id(opts) do
          id when is_binary(id) -> id
          _ -> "anon-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
        end

      Path.join(System.tmp_dir!(), "barkpark-claude-#{token}.stderr")
    end

    # The last few KB / lines of the child's stderr, for an honest exit reason.
    # Bounded (seek to EOF minus the byte cap, keep the trailing lines) so a
    # chatty process can never balloon the exit message; nil-safe for the paths
    # that carry no captured stderr.
    defp read_stderr_tail(nil), do: ""

    # `stderr_path/1` always anchors this file in `System.tmp_dir!/0`.
    # sobelow_skip ["Traversal.FileModule"]
    defp read_stderr_tail(path) do
      case File.open(path, [:read, :binary]) do
        {:ok, io} ->
          size =
            case :file.position(io, :eof) do
              {:ok, s} -> s
              _ -> 0
            end

          _ = :file.position(io, max(size - @stderr_tail_bytes, 0))

          data =
            case :file.read(io, @stderr_tail_bytes) do
              {:ok, d} -> d
              _ -> ""
            end

          File.close(io)

          data
          |> String.split("\n", trim: true)
          |> Enum.take(-@stderr_tail_lines)
          |> Enum.join("\n")
          |> String.trim()

        _ ->
          ""
      end
    end

    # Permission asks become a dedicated sink message; any other control
    # request gets an immediate error response so the CLI never hangs waiting
    # on a capability this bridge doesn't implement. Everything else flows
    # through as a plain chat event. Each clause RETURNS the (possibly updated)
    # state — the data handler reduces over events threading it.
    defp dispatch_event(
           %{
             "type" => "control_request",
             "request_id" => request_id,
             "request" => %{"subtype" => "can_use_tool"} = request
           },
           state
         ) do
      input = Map.get(request, "input", %{})

      send(
        state.sink,
        {:claude_chat_permission,
         %{
           request_id: request_id,
           tool_name: Map.get(request, "tool_name", "tool"),
           input: input,
           title: Map.get(request, "title"),
           decision_reason: Map.get(request, "decision_reason")
         }}
      )

      # Remember the ask's input so a plain `:allow` can echo it as
      # `updatedInput` (charter D32) — the answer seam never reconstructs it
      # from an untrusted round-trip. The tool_name rides along so the answer
      # seam can recognize an allowed ExitPlanMode (the plan-approve fact).
      put_in(state.pending_asks[request_id], %{
        input: input,
        tool_name: Map.get(request, "tool_name", "tool")
      })
    end

    defp dispatch_event(
           %{"type" => "control_request", "request_id" => request_id, "request" => request},
           state
         ) do
      line =
        Jason.encode!(%{
          "type" => "control_response",
          "response" => %{
            "subtype" => "error",
            "request_id" => request_id,
            "error" => "unsupported control request: #{Map.get(request, "subtype", "?")}"
          }
        }) <> "\n"

      safe_command(state.port, line)
      state
    end

    # The CLI's ack for one of OUR control_requests (interrupt / set_mode /
    # set_model). Match it by the request_id we minted and dispatch a TYPED
    # {:claude_chat_control, kind, request_id, response} (charter D17/D23) so
    # ChatLive can (a) assert the echoed mode instead of trusting a bare
    # subtype:success (D12) AND (b) correlate the ack to the SPECIFIC outbound
    # request by its id — a rapid double mode-switch acks twice and only the
    # LATEST outstanding request per kind may commit/revert; a stale ack is
    # dropped by the consumer. An untracked control_response (not one we sent)
    # flows through as a plain event — the previous behavior for any ack the
    # LiveView doesn't correlate.
    defp dispatch_event(%{"type" => "control_response", "response" => response} = event, state)
         when is_map(response) do
      request_id = Map.get(response, "request_id")

      case pop_pending(state, request_id) do
        {nil, state} ->
          send(state.sink, {:claude_chat_event, event})
          state

        {kind, state} ->
          send(
            state.sink,
            {:claude_chat_control, kind, request_id, Map.get(response, "response") || %{}}
          )

          state
      end
    end

    defp dispatch_event(event, state) do
      send(state.sink, {:claude_chat_event, event})
      state
    end

    # A plain string is the text-only default shape (wrap as ONE text block —
    # unchanged w1–w2 behavior); a caller-assembled content-block list (text +
    # base64 image blocks, charter D25) rides the user frame verbatim.
    defp user_content_blocks(text) when is_binary(text),
      do: [%{"type" => "text", "text" => text}]

    defp user_content_blocks(blocks) when is_list(blocks), do: blocks

    # Classify an outbound control_request by its subtype so the inbound ack can
    # be typed. Anything else (or a malformed request) is left untracked.
    defp control_kind(%{"subtype" => "interrupt"}), do: :interrupt
    defp control_kind(%{"subtype" => "set_permission_mode"}), do: :set_mode
    defp control_kind(%{"subtype" => "set_model"}), do: :set_model
    defp control_kind(%{"subtype" => "initialize"}), do: :initialize
    defp control_kind(_), do: nil

    # Pull a pending control's kind by request_id (nil if untracked/absent).
    defp pop_pending(state, request_id) when is_binary(request_id) do
      case Map.pop(state.pending_controls, request_id) do
        {nil, _} -> {nil, state}
        {kind, rest} -> {kind, %{state | pending_controls: rest}}
      end
    end

    defp pop_pending(state, _), do: {nil, state}

    # Honest write (charter D24): return the outcome instead of swallowing every
    # failure to `:ok`. A port that has already closed is NOT in `Port.list/0`;
    # writing to it would raise, so we check first and report `{:error, ...}`.
    # Outbound acks/control frames ignore the return; the user-turn write threads
    # it back to the composer so a lost frame is never rendered as sent.
    defp safe_command(port, data) when is_port(port) do
      if port in Port.list() do
        Port.command(port, data)
        :ok
      else
        {:error, :port_closed}
      end
    rescue
      e ->
        Logger.warning("claude chat: write to subprocess failed: #{inspect(e)}")
        {:error, e}
    end

    defp safe_command(_port, _data), do: {:error, :no_port}
  end
end
