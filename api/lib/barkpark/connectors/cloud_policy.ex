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

  ## Knob 6 — the per-connector egress allowlist (D237/D238/D239, W29)

  The cloud sandbox runs deny-all egress (the W12 isolation wall). A connector's
  credential (W25) is useless if the MCP server inside the sandbox cannot reach
  its API host, so `cloud_egress_hosts/2` derives the MINIMAL widening: the
  workspace's INSTALLED tool connectors ∩ the host-fetched bridge descriptors,
  reduced to the sorted-unique set of each surviving descriptor's SANITIZED MCP
  host (`api.githubcopilot.com`, `mcp.linear.app` …). Egress hosts are a property
  of the connector TYPE (declared on its descriptor url), never of the install —
  a per-workspace list would be needless complexity for the same set. The wiring
  onto the shim argv (repeated `--egress-host <host>` pairs, pre-`--`) is
  `ClaudeChat.cloud_build_args/2`'s; this module only derives the set.

  Fail-closed by construction: NO tool install ⇒ `[]` (deny-all preserved, the
  isolation wall untouched); a connector with no INSTALL ⇒ contributes nothing (no
  cross-connector leak); a descriptor whose url fails the D239 shape sanitizer ⇒
  that connector contributes NO host (never a blanket, never `api.anthropic.com` —
  the shim's own env base, which is never a descriptor and so can never appear).
  The sanitizer is the SafeOutbound SHAPE half ONLY (https-only, non-blank host,
  userinfo-reject, ASCII DNS shape, IP-literal reject, default-port-only) with NO
  DNS resolution — pure over the descriptor string. LIVE egress enforcement is
  Vercel-Sandbox behavior riding `connectors-hg-live-isolated-cloud-turn`; this
  module proves only the ALLOWLIST DERIVATION the launch contract REQUESTS.
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

  @https_default_port 443

  @doc """
  The per-connector egress allowlist for a Cloud turn — knob 6's derivation half
  (D237/D238). The SAME `installs ∩ descriptors` fold as `cloud_mcp_servers/2`,
  reduced to the SORTED, UNIQUE set of each surviving descriptor's SANITIZED MCP
  host. A workspace with a GitHub install and a github descriptor yields exactly
  `["api.githubcopilot.com"]`; github+linear yields the two-host sorted set.

  Fail-closed, mirroring `cloud_mcp_servers/2`: a descriptor whose provider has no
  live tool-direction install for `workspace`, a non-http transport, the reserved
  `barkpark` name, a blank/absent url, OR a url that fails the D239 shape sanitizer
  contributes NO host (degrades the allowlist, never poisons it). An empty
  descriptor list or a garbage/nil workspace yields `[]` — NO widening, so the
  deny-all wall stays whole. NEVER a blanket allow, NEVER another connector's host,
  NEVER `api.anthropic.com` (which is not a descriptor and cannot appear).

  Pure over `(workspace-installs, descriptors)` and unit-testable by INJECTING
  descriptors; the sanitizer does ZERO DNS (SafeOutbound SHAPE half only). The
  WIRING of these hosts onto the sandbox argv (`--egress-host` pairs) lives in
  `ClaudeChat.cloud_build_args/2` and the shim; this module only derives the set.
  """
  @spec cloud_egress_hosts(term(), [map()]) :: [String.t()]
  def cloud_egress_hosts(_workspace, []), do: []

  def cloud_egress_hosts(workspace, descriptors) when is_list(descriptors) do
    installed =
      workspace
      |> connector_tool_providers()
      |> MapSet.new(& &1.provider)

    descriptors
    |> Enum.flat_map(fn descriptor ->
      case cloud_egress_host(descriptor, installed) do
        host when is_binary(host) -> [host]
        :skip -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def cloud_egress_hosts(_workspace, _descriptors), do: []

  # One bridge descriptor -> one sanitized egress host, or `:skip`. Reuses the
  # `cloud_tool_server_entry/2` gate (installed, http-transport, non-reserved
  # provider) then sanitizes the url's host per D239. Any failure = `:skip`.
  defp cloud_egress_host(
         %{"provider" => provider, "type" => "http", "url" => url},
         installed
       )
       when is_binary(provider) and provider != "" and provider != "barkpark" and
              is_binary(url) and url != "" do
    if MapSet.member?(installed, provider) do
      sanitize_egress_host(url)
    else
      :skip
    end
  end

  defp cloud_egress_host(_descriptor, _installed), do: :skip

  # D239 host sanitizer — the SafeOutbound SHAPE half ONLY, ZERO DNS (pure over the
  # string). `URI.new/1` strict-parse; REQUIRE scheme `https`; REQUIRE a non-blank
  # host; REJECT userinfo (refuse the whole descriptor); downcase; strip ONE
  # trailing dot; REQUIRE the ASCII DNS shape `^[a-z0-9.-]+$` (rejects IPv6
  # literals and any userinfo/port that leaked through); REJECT IPv4/IPv6 literals
  # (`:inet.parse_address` — a string parse, never a lookup); REJECT any non-default
  # port. On any rejection returns `:skip` so the connector contributes no host.
  defp sanitize_egress_host(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", userinfo: nil, host: host, port: port}}
      when is_binary(host) and host != "" ->
        normalized = host |> String.downcase() |> strip_one_trailing_dot()

        if valid_dns_host?(normalized) and default_https_port?(port) do
          normalized
        else
          :skip
        end

      _ ->
        :skip
    end
  end

  defp sanitize_egress_host(_), do: :skip

  defp strip_one_trailing_dot(host) do
    if String.ends_with?(host, "."),
      do: binary_part(host, 0, byte_size(host) - 1),
      else: host
  end

  # An ASCII DNS-shaped host that is NOT an IP literal. The shape regex already
  # rejects colons (IPv6) and userinfo; `:inet.parse_address` additionally rejects
  # a dotted-quad IPv4 that would otherwise pass the shape (both are pure parses).
  defp valid_dns_host?(host) do
    Regex.match?(~r/^[a-z0-9.-]+$/, host) and not ip_literal?(host)
  end

  defp ip_literal?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # Only the https default port (443) — anything else is a non-default port and is
  # rejected. `URI.new/1` fills 443 for a portless https url; `nil` is defensive.
  defp default_https_port?(port), do: port in [nil, @https_default_port]
end
