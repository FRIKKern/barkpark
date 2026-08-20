defmodule Barkpark.StudioChat.ProbeTest do
  @moduledoc """
  Deterministic readiness-probe tests. No real `claude`/`bp`/`codex` anywhere:
  each lane's binary is overridden (config `:studio_chat_probe`) with a `chmod
  +x` sh script that emits that branch's EXACT `claude --version` /
  `claude auth status --json` output and exit code (VACUOUS-GREEN LAW — the fake
  drives the real find_executable → System.cmd → Jason.decode parse path).
  """
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat.Probe

  # ── config seam ───────────────────────────────────────────────────────────

  defp put_probe_config(config) do
    prev = Application.get_env(:barkpark, :studio_chat_probe)
    Application.put_env(:barkpark, :studio_chat_probe, config)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :studio_chat_probe, prev),
        else: Application.delete_env(:barkpark, :studio_chat_probe)
    end)
  end

  # A chmod +x fake binary whose body is `script`. Returns the absolute path,
  # which find_executable resolves directly. Cleaned up on exit.
  defp fake_binary(script) do
    path =
      Path.join(System.tmp_dir!(), "probe_fake_#{System.unique_integer([:positive])}.sh")

    File.write!(path, "#!/bin/sh\n" <> script)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # A fake `claude` dispatching on argv: `--version` prints a version (exit 0);
  # `auth status --json` prints `auth_json` and exits `auth_exit`.
  defp fake_claude(auth_json, auth_exit) do
    fake_binary("""
    case "$1" in
      --version) echo "2.1.207 (Claude Code)"; exit 0 ;;
      auth) echo '#{auth_json}'; exit #{auth_exit} ;;
      *) exit 0 ;;
    esac
    """)
  end

  defp fake_codex(version, account_response, behavior \\ :respond) do
    account_branch =
      case behavior do
        :respond -> "echo '#{account_response}'"
        :garbage -> "echo 'not-json'"
        :stall -> "sleep 2"
      end

    fake_binary("""
    if [ "$1" = "--version" ]; then
      echo "codex-cli #{version}"
      exit 0
    fi

    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          echo '{"id":1,"result":{"codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux","userAgent":"codex-cli/#{version}"}}'
          ;;
        *'"method":"account/read"'*)
          #{account_branch}
          ;;
      esac
    done
    """)
  end

  describe "probe(:claude)" do
    test "binary missing → honest not-found struct (no version, not authed)" do
      put_probe_config(claude_binary: "definitely-not-a-real-claude-binary-xyzzy")

      assert %Probe{
               provider: :claude,
               binary: false,
               path: nil,
               version: nil,
               authed?: false,
               account: nil
             } = Probe.probe(:claude)
    end

    test "present + unauthed (exit 1 / loggedIn:false) → authed?: false, version still read" do
      path = fake_claude(~s({"loggedIn":false,"authMethod":"none"}), 1)
      put_probe_config(claude_binary: path)

      probe = Probe.probe(:claude)

      assert probe.provider == :claude
      assert probe.binary == true
      assert probe.path == path
      assert probe.version == "2.1.207"
      assert probe.authed? == false
      assert probe.account == nil
    end

    test "present + authed (exit 0 / loggedIn:true) → account fields populated" do
      json =
        ~s({"loggedIn":true,"authMethod":"oauth","email":"root@guerrilla.no",) <>
          ~s("orgName":"Guerrilla","subscriptionType":"max"})

      path = fake_claude(json, 0)
      put_probe_config(claude_binary: path)

      probe = Probe.probe(:claude)

      assert probe.binary == true
      assert probe.version == "2.1.207"
      assert probe.authed? == true

      assert probe.account == %{
               email: "root@guerrilla.no",
               org: "Guerrilla",
               subscription: "max",
               method: "oauth"
             }
    end

    test "expired credentials are indistinguishable from never-logged-in → authed?: false BY DESIGN" do
      # The runtime cannot tell an expired token from a never-logged-in one
      # without an API call — claude reports the SAME loggedIn:false shape. The
      # probe degrades both to not-authed (charter D2).
      path = fake_claude(~s({"loggedIn":false,"authMethod":"none"}), 1)
      put_probe_config(claude_binary: path)

      assert %Probe{authed?: false, account: nil} = Probe.probe(:claude)
    end

    test "garbage (non-JSON) auth output degrades to not-authed, never crashes" do
      path =
        fake_binary("""
        case "$1" in
          --version) echo "2.1.207 (Claude Code)"; exit 0 ;;
          auth) echo 'not json at all'; exit 0 ;;
          *) exit 0 ;;
        esac
        """)

      put_probe_config(claude_binary: path)

      assert %Probe{binary: true, authed?: false, account: nil, version: "2.1.207"} =
               Probe.probe(:claude)
    end
  end

  describe "probe(:claude) is time-boxed (resource bound)" do
    # FAIL-BEFORE: the unbounded `defp run/2` called System.cmd directly, so this
    # sleeper stub blocks each of the two shell-outs (--version, auth status) for
    # 2s → probe returns ~4s later with version "2.1.207" and authed?: true.
    #
    # PASS-AFTER: each shell-out is brutal-killed at the 150ms deadline, so the
    # version/auth reads degrade to the honest not-ready shape AND the whole probe
    # returns well under the 2s a single stub would take to exit on its own.
    test "a stalled claude CLI degrades to not-ready AND the wall-clock is cut" do
      slow =
        fake_binary("""
        case "$1" in
          --version) sleep 2; echo "2.1.207 (Claude Code)"; exit 0 ;;
          auth) sleep 2; echo '{"loggedIn":true,"authMethod":"oauth"}'; exit 0 ;;
          *) exit 0 ;;
        esac
        """)

      put_probe_config(claude_binary: slow, timeout_ms: 150)

      {micros, probe} = :timer.tc(fn -> Probe.probe(:claude) end)

      # Binary is present, but the wedged shell-outs yield the not-ready struct.
      assert probe.binary == true
      assert probe.version == nil
      assert probe.authed? == false
      assert probe.account == nil

      assert micros < 1_500_000,
             "probe blocked #{micros}µs — the deadline did not bound the claude shell-outs"
    end
  end

  describe "probe(:bp)" do
    test "present → binary/path reported; authed?: nil (mint-driven, no login step)" do
      path = fake_binary("exit 0\n")
      put_probe_config(bp_binary: path)

      assert %Probe{
               provider: :bp,
               binary: true,
               path: ^path,
               version: nil,
               authed?: nil,
               account: nil
             } = Probe.probe(:bp)
    end

    test "missing → binary: false, authed? still nil (not-applicable)" do
      put_probe_config(bp_binary: "definitely-not-a-real-bp-binary-xyzzy")

      assert %Probe{provider: :bp, binary: false, path: nil, authed?: nil} = Probe.probe(:bp)
    end
  end

  describe "probe(:codex) — pinned app-server account/read readiness" do
    test "missing on a real host → binary: false (the expected everyday state)" do
      put_probe_config(codex_binary: "definitely-not-a-real-codex-binary-xyzzy")

      assert %Probe{
               provider: :codex,
               binary: false,
               path: nil,
               version: nil,
               authed?: false,
               account: nil
             } = Probe.probe(:codex)
    end

    test "present but unauthed uses account/read without a paid turn" do
      path =
        fake_codex("0.144.1", ~s({"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}))

      put_probe_config(codex_binary: path, timeout_ms: 500)

      assert %Probe{
               provider: :codex,
               binary: true,
               path: ^path,
               version: "0.144.1",
               authed?: false,
               ready?: false,
               reason: :not_authenticated
             } = Probe.probe(:codex)
    end

    test "present and authed reports only account/read metadata" do
      path =
        fake_codex(
          "0.144.1",
          ~s({"id":2,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}})
        )

      put_probe_config(codex_binary: path, timeout_ms: 500)

      assert %Probe{
               version: "0.144.1",
               authed?: true,
               ready?: true,
               reason: nil,
               account: %{"type" => "apiKey"}
             } = Probe.probe(:codex)
    end

    test "incompatible version fails closed before app-server startup" do
      path =
        fake_codex(
          "0.144.4",
          ~s({"id":2,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}})
        )

      put_probe_config(codex_binary: path, timeout_ms: 500)

      assert %Probe{ready?: false, authed?: false, reason: :incompatible_version} =
               Probe.probe(:codex)
    end

    test "garbage and timeout both degrade to named not-ready states" do
      garbage = fake_codex("0.144.1", "", :garbage)
      put_probe_config(codex_binary: garbage, timeout_ms: 500)
      assert %Probe{ready?: false, reason: :malformed_response} = Probe.probe(:codex)

      stalled = fake_codex("0.144.1", "", :stall)
      put_probe_config(codex_binary: stalled, timeout_ms: 100)
      assert %Probe{ready?: false, reason: :timeout} = Probe.probe(:codex)
    end
  end
end
