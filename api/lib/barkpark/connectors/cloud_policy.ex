defmodule Barkpark.Connectors.CloudPolicy do
  @moduledoc """
  The single legible owner of the `:cloud` execution profile's security posture
  (Connectors D116/D117/D118/D120 — the D24 permission reversal delivered at the
  ARGV/POLICY layer).

  Self-hosted Studio chat runs `claude` with the host user's FULL trust: the gate
  is the host account, `bypassPermissions` is reachable via the armed ceremony,
  and the model can read/edit/execute across the whole host filesystem. A
  Cloud-tenant turn MUST NOT inherit any of that. This module is the one place
  that answers "exactly what may a Cloud turn do", and
  `BarkparkWeb.Studio.ClaudeChat.cloud_claude_args/1` emits every belt from here —
  the self-hosted argv path never touches it (stays byte-identical).

  ## Knob 2 — the three enforced belts (the REAL client-side confinement, D117)

    1. `--tools ""` removes ALL built-in tools (probe: init frame `has_Bash=False`;
       CLI help verbatim: `"" to disable all tools`).
    2. `--disallowedTools <deny set>` structurally removes each host-FS/exec/network
       built-in — probe-proven to remove a tool without any bridge, never fails
       open (`cloud_disallowed_tools/0`).
    3. `--settings '{"permissions":{"deny":[...]}}'` as a JSON STRING carries the
       SAME deny list (`settings_deny_json/0`) into the CLI's flag-settings scope;
       permission rules MERGE across scopes and deny beats allow. A test pins
       argv-deny == settings-deny so the two belts cannot drift. The settings FILE
       vector is REJECTED — a malformed settings file fails OPEN silently under
       `-p` (truncated JSON → deny never loads, zero surfaced error), strictly
       weaker than the argv string.

  ## Knob 1 — the permission-mode clamp is a VALIDITY clamp, NOT a safety claim (D116)

  `cloud_permission_mode/1` clamps to `cloud_modes/0` (the CLI's valid modes minus
  `bypassPermissions`); anything unknown — `bypassPermissions` included — becomes
  `"plan"`, mirroring the self-hosted fail-closed idiom. This completes D24 knob 1
  beyond W11's never-emits-bypass down-payment. It MUST NOT be read as tool
  confinement: per the wave-12 live probe (below) the mode does not gate tools
  headless.

  ## Knob 3 — the POLICY half only (D118)

  `connector_tool_providers/1` composes `Barkpark.Connectors.Catalog.installs_for_workspace/1`
  with `Catalog.direction/1 == :tool` — the pure policy answer to "which tool
  connectors may a Cloud turn reach". The WIRING of these into the sandbox launch
  is owned by `task-0c8b9214b7962152` (the Go `bp mcp serve --tools <subset>`
  flag) and `connectors-cloud-sandbox-mcp-tools` (in-sandbox mcpServers) — NOT
  here. This module never touches the sandbox launch.

  ## Knob 5 — the unattended auto-approval policy (D120, WRITTEN, version-observed)

  A headless one-shot cloud turn has NO interactive permission gate. With the
  cloud argv EVERY permission-mode auto-approves tool calls (probed all five on
  `claude 2.1.211` — VERSION-OBSERVED, not contractual; the sandbox npm-installs
  claude fresh, so the version is asserted by `connectors-cloud-claude-version-pin`,
  not guaranteed here). Unattended tool safety therefore comes from, and ONLY
  from:

    1. the Firecracker sandbox boundary (no host reach),
    2. the key gate (the current cloud path 401s before any tool ask — W11),
    3. knob-2 tool REMOVAL (this module's deny belts),

  and NEVER from the permission mode. The D65 bare-`-p` auto-DENY datapoint was
  MCP-specific and does NOT generalize (built-in Bash auto-RAN in every mode).
  LIVE enforcement observation — a real sandbox actually DENYING a real host-touch
  — rides the human gate `connectors-hg-live-isolated-cloud-turn`; it is never
  fabricated here. This module proves only what the launch contract REQUESTS.
  """

  alias Barkpark.Connectors.Catalog

  # The CLI's valid `--permission-mode` values MINUS `bypassPermissions` (D116).
  # The authoritative set is the CLI's own reject list (probed: acceptEdits, auto,
  # bypassPermissions, manual, dontAsk, plan). Kept as a literal (no compile-time
  # dep on ClaudeChat's private @modes); a no-drift test pins this equal to
  # `ClaudeChat.modes() -- ["bypassPermissions"]`.
  @cloud_modes ~w(plan acceptEdits auto dontAsk manual)

  # The host-FS/exec/network built-in tools a Cloud turn may NEVER use (D117
  # belts b/c). Emitted BOTH as `--disallowedTools` argv AND inside the
  # `--settings` deny JSON (`settings_deny_json/0`) — the SAME list, pinned
  # no-drift so the two belts cannot diverge.
  @cloud_disallowed_tools ~w(Bash Edit Write Read NotebookEdit WebFetch WebSearch Task)

  @default_cloud_mode "plan"

  @doc """
  Clamp a permission mode to the Cloud-valid set (knob 1, D116). A member passes
  verbatim; anything else — an unknown string, or `bypassPermissions` — clamps to
  `"plan"` (fail-closed, mirroring the self-hosted idiom). A VALIDITY clamp, never
  a tool-confinement claim.
  """
  @spec cloud_permission_mode(term()) :: String.t()
  def cloud_permission_mode(mode) when mode in @cloud_modes, do: mode
  def cloud_permission_mode(_), do: @default_cloud_mode

  @doc "The Cloud-valid permission modes — the CLI's set minus `bypassPermissions` (D116)."
  @spec cloud_modes() :: [String.t()]
  def cloud_modes, do: @cloud_modes

  @doc "The built-in tools a Cloud turn is denied — host FS/exec/network built-ins (D117)."
  @spec cloud_disallowed_tools() :: [String.t()]
  def cloud_disallowed_tools, do: @cloud_disallowed_tools

  @doc """
  The `--settings` JSON STRING that carries the deny list into the CLI's
  flag-settings scope (D117 belt c). Built with `Jason.encode!` from the SAME
  `cloud_disallowed_tools/0` as the argv belt, so a test pins the two equal and
  they cannot drift.
  """
  @spec settings_deny_json() :: String.t()
  def settings_deny_json,
    do: Jason.encode!(%{"permissions" => %{"deny" => @cloud_disallowed_tools}})

  @doc """
  The tool connectors a Cloud turn for `workspace` may reach — knob 3's POLICY
  half ONLY (D118). `Catalog.installs_for_workspace/1` filtered to installs whose
  provider `Catalog.direction/1 == :tool` (github/linear). A pure read: the WIRING
  of these into the sandbox launch is owned by the two existing tasks, never this
  module. A garbage/nil/absent workspace inherits `installs_for_workspace/1`'s
  fail-safe `[]`.
  """
  @spec connector_tool_providers(term()) :: [map()]
  def connector_tool_providers(workspace) do
    workspace
    |> Catalog.installs_for_workspace()
    |> Enum.filter(fn %{provider: provider} -> Catalog.direction(provider) == :tool end)
  end
end
