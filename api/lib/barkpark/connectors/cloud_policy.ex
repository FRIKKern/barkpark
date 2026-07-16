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
  `BarkparkWeb.Studio.ClaudeChat.cloud_claude_args/2` emits every belt from here —
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

  ## Knob 3 — the POLICY answer AND the CONFIG emission (D118/D126/D128)

  `connector_tool_providers/1` composes `Barkpark.Connectors.Catalog.installs_for_workspace/1`
  with `Catalog.direction/1 == :tool` — the pure policy answer to "which tool
  connectors may a Cloud turn reach". `cloud_mcp_servers/2` (W13) is the CONFIG
  half: it composes that policy answer with the host-fetched bridge descriptors
  into the exact `mcpServers` map the sandbox launch injects — `bridge answer ∩
  local install truth`, HTTP-only, `headersHelper` stripped, credential-less.
  This module OWNS the config; it still never touches the sandbox launch — the
  WIRING of the map onto the argv (`--mcp-config-b64`) is
  `ClaudeChat.cloud_build_args/2`'s, and the in-VM materialization is the shim's
  (`scripts/connectors/cloud-sandbox-runner.mjs`). The Go `bp mcp serve --tools
  <subset>` flag (`task-0c8b9214b7962152`) is the SEPARATE slice.

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

  @doc """
  The `:cloud` `mcpServers` map — knob 3's CONFIG half (D126/D128). The pure
  emission that composes knob 3's POLICY answer (`connector_tool_providers/1`,
  the workspace's live tool-direction installs) with the host-fetched, INJECTED
  bridge `descriptors`, and keeps ONLY a descriptor that clears BOTH gates:

    * its provider has a live tool-direction install for `workspace` (defense in
      depth — the emitted set is `bridge answer ∩ local install truth`, never the
      bridge's word alone), and
    * it is a well-formed `%{"type" => "http", "url" => <non-blank>}` descriptor
      whose provider is a non-empty id other than the reserved `barkpark`.

  A survivor emits `%{provider => %{"type" => "http", "url" => url}}`. The
  `headersHelper` is STRIPPED (the host-loopback curl that fetches the PAT is
  DEAD across the Firecracker boundary — D126) and NO credential ever rides this
  map; entries ship credential-less this wave. Fail-closed: a malformed
  descriptor, a non-http transport, a missing/blank url, the reserved name, or a
  provider with no tool install is DROPPED (degrades the toolset, never poisons
  it); an empty descriptor list or a garbage/nil workspace yields `%{}` WITHOUT
  touching the installs read. `Map.put_new` mirrors `ClaudeChat.mcp_config/2` so a
  rogue descriptor can never SHADOW an already-emitted provider.

  Pure over `(workspace-installs, descriptors)` — the emission is unit-testable
  by INJECTING descriptors, no live bridge. The WIRING of this map onto the
  sandbox launch (`--mcp-config-b64`) lives in `ClaudeChat.cloud_build_args/2`
  and the shim; this module only emits the config.
  """
  @spec cloud_mcp_servers(term(), [map()]) :: %{optional(String.t()) => map()}
  def cloud_mcp_servers(_workspace, []), do: %{}

  def cloud_mcp_servers(workspace, descriptors) when is_list(descriptors) do
    installed =
      workspace
      |> connector_tool_providers()
      |> MapSet.new(& &1.provider)

    Enum.reduce(descriptors, %{}, fn descriptor, acc ->
      case cloud_tool_server_entry(descriptor, installed) do
        {name, entry} -> Map.put_new(acc, name, entry)
        :skip -> acc
      end
    end)
  end

  def cloud_mcp_servers(_workspace, _descriptors), do: %{}

  # One bridge descriptor -> one `{provider, %{"type","url"}}` entry, or `:skip`.
  # Fail-closed (the `mcp_config/2` fold idiom, with `headersHelper` STRIPPED): the
  # provider must be a non-empty, non-`barkpark` id that ALSO has a tool-direction
  # install in `installed`; the transport must be `http`; the url a non-blank
  # binary. Anything else is dropped.
  defp cloud_tool_server_entry(
         %{"provider" => provider, "type" => "http", "url" => url},
         installed
       )
       when is_binary(provider) and provider != "" and provider != "barkpark" and
              is_binary(url) and url != "" do
    if MapSet.member?(installed, provider) do
      {provider, %{"type" => "http", "url" => url}}
    else
      :skip
    end
  end

  defp cloud_tool_server_entry(_descriptor, _installed), do: :skip
end
