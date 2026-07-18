defmodule Barkpark.Connectors.CloudPolicyTest do
  @moduledoc """
  The :cloud execution profile's security posture, owned by
  `Barkpark.Connectors.CloudPolicy` (Connectors D116/D117/D118/D120 — the D24
  permission reversal at the POLICY layer).

  Four proof obligations, each proven at the layer it lives:

    1. **Knob 1 — the mode clamp** is a VALIDITY clamp (member verbatim, anything
       else including `bypassPermissions` → `"plan"`), and its valid set is exactly
       the CLI's modes minus bypass (no-drift vs `ClaudeChat.modes()`).
    2. **Knob 2 — the deny belts** are ONE list: the `--disallowedTools` set and
       the `--settings` deny JSON decode to the SAME tools (proven here at the
       source; the argv-vs-settings no-drift is pinned in `claude_chat_test.exs`).
    3. **Knob 3 — the policy half** — `connector_tool_providers/1` reads the real
       cross-schema `chat_bridge.connector_installs` (needs live Postgres) and
       returns ONLY tool-direction installs.

  The clamp is NEVER documented as tool confinement, and no live host-denial is
  faked — that observation rides `connectors-hg-live-isolated-cloud-turn`.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Connectors.CloudPolicy
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.ClaudeChat

  describe "cloud_permission_mode/1 — knob 1 validity clamp (D116)" do
    test "every Cloud-valid mode passes through verbatim" do
      for mode <- CloudPolicy.cloud_modes() do
        assert CloudPolicy.cloud_permission_mode(mode) == mode
      end
    end

    test "bypassPermissions clamps to plan — the reversal, not a pass-through" do
      assert CloudPolicy.cloud_permission_mode("bypassPermissions") == "plan"
    end

    test "an unknown/garbage/empty mode clamps to plan (fail-closed)" do
      for bad <- ["nonsense", "", "DROP TABLE", "default", nil, :plan, 42] do
        assert CloudPolicy.cloud_permission_mode(bad) == "plan"
      end
    end

    test "bypassPermissions is NOT a member of the Cloud-valid set" do
      refute "bypassPermissions" in CloudPolicy.cloud_modes()
    end

    test "NO-DRIFT — cloud_modes/0 equals ClaudeChat.modes() minus bypassPermissions" do
      assert CloudPolicy.cloud_modes() == ClaudeChat.modes() -- ["bypassPermissions"]
    end
  end

  describe "the deny belts — knob 2 (D117)" do
    test "cloud_disallowed_tools/0 is the host-FS/exec/network built-in set" do
      assert CloudPolicy.cloud_disallowed_tools() ==
               ~w(Bash Edit Write Read NotebookEdit WebFetch WebSearch Task)
    end

    test "settings_deny_json/0 is valid JSON decoding to permissions.deny == the deny list" do
      decoded = Jason.decode!(CloudPolicy.settings_deny_json())
      assert decoded == %{"permissions" => %{"deny" => CloudPolicy.cloud_disallowed_tools()}}
    end

    test "NO-DRIFT at the source — the settings deny list IS cloud_disallowed_tools/0" do
      deny = Jason.decode!(CloudPolicy.settings_deny_json())["permissions"]["deny"]
      assert deny == CloudPolicy.cloud_disallowed_tools()
    end
  end

  describe "connector_tool_providers/1 — knob 3 policy half (D118)" do
    setup do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "cloud-policy-ws", name: "Cloud Policy WS"})
      {:ok, ws: ws}
    end

    # The bridge is the only WRITER in production; tests write raw SQL (no Elixir
    # write path exists — adding one forks ownership of the table).
    defp insert_install(provider, key, ws_id) do
      Repo.query!(
        """
        INSERT INTO chat_bridge.connector_installs
          (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
        VALUES ($1, $2, $3, $4, $5, now())
        """,
        [provider, key, ws_id, "SEALED-CREDENTIAL-BLOB", "SEALED-CHAT-TOKEN-BLOB"]
      )
    end

    test "returns ONLY tool-direction installs, filtering channel installs out", %{ws: ws} do
      # github/linear are direction: :tool; telegram/discord are :channel.
      insert_install("github", "octocat/repo", ws.id)
      insert_install("telegram", "111:aaa", ws.id)
      insert_install("discord", "999888777", ws.id)

      providers =
        ws
        |> CloudPolicy.connector_tool_providers()
        |> Enum.map(& &1.provider)

      assert providers == ["github"]
    end

    test "returns BOTH tool providers when github AND linear are installed (channel filtered)",
         %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)
      insert_install("linear", "team-x", ws.id)
      insert_install("telegram", "111:aaa", ws.id)

      providers =
        ws
        |> CloudPolicy.connector_tool_providers()
        |> Enum.map(& &1.provider)

      # installs_for_workspace orders by provider asc.
      assert providers == ["github", "linear"]
    end

    test "a workspace with only channel installs yields no tool providers", %{ws: ws} do
      insert_install("telegram", "111:aaa", ws.id)

      assert CloudPolicy.connector_tool_providers(ws) == []
    end

    test "a workspace with no installs yields []", %{ws: ws} do
      assert CloudPolicy.connector_tool_providers(ws) == []
    end

    test "a garbage/nil workspace inherits the fail-safe [] (never a CastError 500)" do
      assert CloudPolicy.connector_tool_providers("not-a-uuid") == []
      assert CloudPolicy.connector_tool_providers(nil) == []
    end
  end

  # Knob 3's CONFIG half (D126/D128): the pure emission composing the policy answer
  # (installs) with INJECTED bridge descriptors. `bridge answer ∩ local install
  # truth`, HTTP-only, `headersHelper` STRIPPED, credential-less, fail-closed.
  describe "cloud_mcp_servers/2 — knob 3 CONFIG emission (D126/D128)" do
    setup do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "cloud-mcp-ws", name: "Cloud MCP WS"})
      {:ok, ws: ws}
    end

    # Bridge descriptors as fetch_tool_descriptors/1 returns them — WITH a
    # headersHelper the cloud emission must STRIP (dead across Firecracker, D126).
    defp gh_descriptor,
      do: %{
        "provider" => "github",
        "type" => "http",
        "url" => "https://api.githubcopilot.com/mcp/",
        "headersHelper" => "curl -sS http://127.0.0.1:4020/tool-headers/github"
      }

    defp linear_descriptor,
      do: %{
        "provider" => "linear",
        "type" => "http",
        "url" => "https://mcp.linear.app/mcp",
        "headersHelper" => "curl -sS http://127.0.0.1:4020/tool-headers/linear"
      }

    test "empty descriptors short-circuit to %{} (no installs read at all)" do
      assert CloudPolicy.cloud_mcp_servers("any-workspace", []) == %{}
    end

    test "a descriptor with no matching install is dropped (0 servers)", %{ws: ws} do
      assert CloudPolicy.cloud_mcp_servers(ws, [gh_descriptor()]) == %{}
    end

    test "1 install — exactly that provider's HTTP server, headersHelper STRIPPED", %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)

      assert CloudPolicy.cloud_mcp_servers(ws, [gh_descriptor(), linear_descriptor()]) ==
               %{"github" => %{"type" => "http", "url" => "https://api.githubcopilot.com/mcp/"}}
    end

    test "2 installs (github + linear) — both HTTP servers, headersHelper stripped", %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)
      insert_install("linear", "team-x", ws.id)

      assert CloudPolicy.cloud_mcp_servers(ws, [gh_descriptor(), linear_descriptor()]) ==
               %{
                 "github" => %{"type" => "http", "url" => "https://api.githubcopilot.com/mcp/"},
                 "linear" => %{"type" => "http", "url" => "https://mcp.linear.app/mcp"}
               }
    end

    test "a channel install never yields a tool server even with a matching descriptor",
         %{ws: ws} do
      insert_install("telegram", "111:aaa", ws.id)
      tg = %{"provider" => "telegram", "type" => "http", "url" => "https://example.test/mcp"}

      assert CloudPolicy.cloud_mcp_servers(ws, [gh_descriptor(), tg]) == %{}
    end

    test "malformed descriptors are dropped fail-closed; the one good install still emits",
         %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)

      malformed = [
        # wrong transport
        %{"provider" => "github", "type" => "stdio", "url" => "https://x.test"},
        # blank url
        %{"provider" => "github", "type" => "http", "url" => ""},
        # missing url
        %{"provider" => "github", "type" => "http"},
        # missing provider
        %{"type" => "http", "url" => "https://x.test"},
        # reserved loopback name (never shadow barkpark)
        %{"provider" => "barkpark", "type" => "http", "url" => "https://x.test"},
        # not a map
        "not-a-map",
        # the one good one
        gh_descriptor()
      ]

      assert CloudPolicy.cloud_mcp_servers(ws, malformed) ==
               %{"github" => %{"type" => "http", "url" => "https://api.githubcopilot.com/mcp/"}}
    end

    test "a garbage/nil workspace yields %{} (fail-safe, never a CastError 500)" do
      assert CloudPolicy.cloud_mcp_servers("not-a-uuid", [gh_descriptor()]) == %{}
      assert CloudPolicy.cloud_mcp_servers(nil, [gh_descriptor()]) == %{}
    end
  end

  # Knob 6 (D237/D238/D239, W29): the per-connector egress allowlist — the SAME
  # `installs ∩ descriptors` fold as cloud_mcp_servers/2, reduced to the sorted,
  # unique set of each surviving descriptor's D239-SANITIZED host. Fail-closed: no
  # install ⇒ no widening (deny-all preserved); a non-installed connector's host
  # never leaks; a shape-invalid url contributes nothing. Reuses insert_install/3
  # and gh_descriptor/0/linear_descriptor/0 (module-scope privates above).
  describe "cloud_egress_hosts/2 — knob 6 egress allowlist derivation (D237/D238/D239)" do
    setup do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "cloud-egress-ws", name: "Cloud Egress WS"})
      {:ok, ws: ws}
    end

    test "empty descriptors ⇒ [] (no widening, deny-all wall untouched)" do
      assert CloudPolicy.cloud_egress_hosts("any-workspace", []) == []
    end

    test "a descriptor with no matching install ⇒ [] (no cross-connector leak)", %{ws: ws} do
      assert CloudPolicy.cloud_egress_hosts(ws, [gh_descriptor()]) == []
    end

    test "1 github install ⇒ EXACTLY [\"api.githubcopilot.com\"] (set-equality)", %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)

      assert CloudPolicy.cloud_egress_hosts(ws, [gh_descriptor(), linear_descriptor()]) ==
               ["api.githubcopilot.com"]
    end

    test "github + linear installs ⇒ the two-host SORTED UNIQUE set", %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)
      insert_install("linear", "team-x", ws.id)

      assert CloudPolicy.cloud_egress_hosts(ws, [gh_descriptor(), linear_descriptor()]) ==
               ["api.githubcopilot.com", "mcp.linear.app"]
    end

    test "the allowlist NEVER contains a host not declared by an INSTALLED connector", %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)

      # linear descriptor present but NOT installed for this ws ⇒ its host is absent.
      hosts = CloudPolicy.cloud_egress_hosts(ws, [gh_descriptor(), linear_descriptor()])
      assert hosts == ["api.githubcopilot.com"]
      refute "mcp.linear.app" in hosts
      refute "api.anthropic.com" in hosts
    end

    test "duplicate descriptors for the same installed host collapse to one", %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)

      assert CloudPolicy.cloud_egress_hosts(ws, [gh_descriptor(), gh_descriptor()]) ==
               ["api.githubcopilot.com"]
    end

    # D239 sanitizer exercised with FIXED descriptor strings (zero DNS/network).
    # Each malformed github url ⇒ that connector contributes NO host (fail-closed).
    test "D239 sanitizer rejects http/userinfo/IP-literal/non-default-port/blank/underscore — fixed strings",
         %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)

      for bad_url <- [
            # not https
            "http://api.githubcopilot.com/mcp/",
            # userinfo (whole descriptor refused)
            "https://user@api.githubcopilot.com/mcp/",
            "https://user:pw@api.githubcopilot.com/mcp/",
            # IPv4 literal
            "https://192.168.1.1/mcp",
            # IPv6 literal
            "https://[::1]/mcp",
            # non-default port
            "https://api.githubcopilot.com:8443/mcp",
            # underscore — not the ASCII DNS shape
            "https://api_githubcopilot.com/mcp",
            # blank host
            "https:///mcp",
            # unparseable / no scheme
            "not-a-url"
          ] do
        d = %{"provider" => "github", "type" => "http", "url" => bad_url}

        assert CloudPolicy.cloud_egress_hosts(ws, [d]) == [],
               "expected [] (fail-closed) for #{inspect(bad_url)}"
      end
    end

    test "sanitizer downcases the host and strips one trailing dot", %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)

      d = %{
        "provider" => "github",
        "type" => "http",
        "url" => "https://API.GithubCopilot.com./mcp"
      }

      assert CloudPolicy.cloud_egress_hosts(ws, [d]) == ["api.githubcopilot.com"]
    end

    test "non-http transport / reserved barkpark / channel install contribute no host", %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)
      insert_install("telegram", "111:aaa", ws.id)

      descriptors = [
        %{
          "provider" => "github",
          "type" => "stdio",
          "url" => "https://api.githubcopilot.com/mcp/"
        },
        %{"provider" => "barkpark", "type" => "http", "url" => "https://x.test/mcp"},
        %{"provider" => "telegram", "type" => "http", "url" => "https://example.test/mcp"}
      ]

      assert CloudPolicy.cloud_egress_hosts(ws, descriptors) == []
    end

    test "a garbage/nil workspace yields [] (fail-safe, never a CastError 500)" do
      assert CloudPolicy.cloud_egress_hosts("not-a-uuid", [gh_descriptor()]) == []
      assert CloudPolicy.cloud_egress_hosts(nil, [gh_descriptor()]) == []
    end
  end

  # The D130 argv table: `ClaudeChat.cloud_build_args/2` over 0/1/2 tool installs,
  # asserting in EVERY row that W12's FULL deny belt (--tools "" + --disallowedTools
  # + --settings deny JSON) is still present alongside the new `--mcp-config-b64`
  # flag. Knob 3 ADDS connector tools; it NEVER re-opens the host-tool deny belt.
  describe "cloud_build_args argv table — belt + mcp flag over 0/1/2 installs (D130)" do
    setup do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "cloud-argv-ws", name: "Cloud Argv WS"})
      {:ok, ws: ws}
    end

    defp descriptors_for(providers) do
      urls = %{
        "github" => "https://api.githubcopilot.com/mcp/",
        "linear" => "https://mcp.linear.app/mcp"
      }

      Enum.map(providers, fn p ->
        %{
          "provider" => p,
          "type" => "http",
          "url" => Map.fetch!(urls, p),
          "headersHelper" => "curl http://127.0.0.1:4020/#{p}"
        }
      end)
    end

    defp assert_full_belt(args) do
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--tools", ""])

      disallowed = args |> Enum.drop_while(&(&1 != "--disallowedTools")) |> Enum.drop(1)
      assert disallowed == CloudPolicy.cloud_disallowed_tools()

      idx = Enum.find_index(args, &(&1 == "--settings"))
      assert Enum.at(args, idx + 1) == CloudPolicy.settings_deny_json()

      # W14 (D137/D141): every Cloud turn ALWAYS carries `--keep-sandbox` pre-`--`
      # (teardown stops-not-removes; the sandbox survives to the next turn). The
      # session flags are additive — the deny belt is invariant across turns.
      sep = Enum.find_index(args, &(&1 == "--"))
      keep = Enum.find_index(args, &(&1 == "--keep-sandbox"))
      assert is_integer(keep) and keep < sep, "--keep-sandbox must ride pre-`--`"
    end

    defp decode_mcp_flag(args) do
      sep = Enum.find_index(args, &(&1 == "--"))
      idx = Enum.find_index(args, &(&1 == "--mcp-config-b64"))
      assert is_integer(idx) and idx < sep, "--mcp-config-b64 must ride pre-`--`"
      # The Elixir argv NEVER carries the shim-owned host-path mcp flags (D127).
      refute "--mcp-config" in args
      refute "--strict-mcp-config" in args
      args |> Enum.at(idx + 1) |> Base.decode64!() |> Jason.decode!()
    end

    # W25-E (D214/D217): when the servers map is non-empty the b64 payload carries
    # the SAME per-turn tool-session ticket (threaded into session_opts beside the
    # descriptors) as a TOP-LEVEL `bpConnectorTicket` key beside `mcpServers` — the
    # wire contract the shim (W25-N) reads HOST-side to fetch each connector's
    # FINISHED auth headers from the bridge and embed them into the copied config
    # (the bridge owns decryption — D213). 0-server rows stay byte-identical W12: no flag,
    # and — even with a ticket in session_opts — no key (the ticket alone NEVER
    # forces the flag; the flag rides SOLELY on ≥1 surviving server).
    @tool_ticket "w25-e-tool-session-ticket-fixture"

    test "0 / 1 / 2 installs — belt intact in every row; flag present iff ≥1 server; bpConnectorTicket rides with ≥1 server",
         %{ws: ws} do
      # Row 0 — no installs, no descriptors: byte-identical W12 (no flag). Even a
      # ticket threaded into session_opts must NOT force the flag or the key.
      a0 =
        ClaudeChat.cloud_build_args("plan", %{
          workspace_id: ws.id,
          tool_descriptors: [],
          tool_session_ticket: @tool_ticket
        })

      refute "--mcp-config-b64" in a0
      assert_full_belt(a0)

      # Row 1 — github installed.
      insert_install("github", "octocat/repo", ws.id)

      a1 =
        ClaudeChat.cloud_build_args("plan", %{
          workspace_id: ws.id,
          tool_descriptors: descriptors_for(["github"]),
          tool_session_ticket: @tool_ticket
        })

      assert decode_mcp_flag(a1) == %{
               "mcpServers" => %{
                 "github" => %{"type" => "http", "url" => "https://api.githubcopilot.com/mcp/"}
               },
               "bpConnectorTicket" => @tool_ticket
             }

      assert_full_belt(a1)

      # Row 2 — github + linear installed.
      insert_install("linear", "team-x", ws.id)

      a2 =
        ClaudeChat.cloud_build_args("plan", %{
          workspace_id: ws.id,
          tool_descriptors: descriptors_for(["github", "linear"]),
          tool_session_ticket: @tool_ticket
        })

      assert decode_mcp_flag(a2) == %{
               "mcpServers" => %{
                 "github" => %{"type" => "http", "url" => "https://api.githubcopilot.com/mcp/"},
                 "linear" => %{"type" => "http", "url" => "https://mcp.linear.app/mcp"}
               },
               "bpConnectorTicket" => @tool_ticket
             }

      assert_full_belt(a2)
    end

    # W14 session identity (D135/D137/D139) rides ON TOP of the deny belt: a bound
    # session adds `--sandbox-id`/`--resume`, a fresh session adds `--session-id`,
    # and either way the full W12/W13 belt is invariant. Resume-ness derives from
    # the BINDING, never `resume:`/message_count (D139 LAW).
    test "session identity is additive to the belt — binding ⇒ --sandbox-id + --resume; fresh ⇒ --session-id (D135/D139)",
         %{ws: ws} do
      uuid = "22222222-2222-4222-8222-222222222222"

      # Fresh session (no binding): --session-id post-`--`, --keep-sandbox pre-`--`,
      # NO --sandbox-id. A `resume: true` transport flag does NOT force --resume.
      fresh =
        ClaudeChat.cloud_build_args("plan", %{
          workspace_id: ws.id,
          session_id: uuid,
          resume: true
        })

      assert Enum.chunk_every(fresh, 2, 1) |> Enum.member?(["--session-id", uuid])
      refute "--resume" in fresh
      refute "--sandbox-id" in fresh
      assert_full_belt(fresh)

      # Bound session: --sandbox-id <id> --keep-sandbox pre-`--`, --resume post-`--`,
      # NEVER --session-id — even with `resume: false`.
      bound =
        ClaudeChat.cloud_build_args("plan", %{
          workspace_id: ws.id,
          session_id: uuid,
          resume: false,
          cloud_sandbox_id: "sbx_policy_test_1"
        })

      sep = Enum.find_index(bound, &(&1 == "--"))
      sbx = Enum.find_index(bound, &(&1 == "--sandbox-id"))
      assert is_integer(sbx) and sbx < sep, "--sandbox-id must ride pre-`--`"
      assert Enum.at(bound, sbx + 1) == "sbx_policy_test_1"
      assert Enum.chunk_every(bound, 2, 1) |> Enum.member?(["--resume", uuid])
      refute "--session-id" in bound
      assert_full_belt(bound)
    end
  end
end
