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

  describe "probe(:codex) — designed-not-built stub" do
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

    test "present binary is reported honestly, but no version/auth is probed (lane not wired)" do
      path = fake_binary("exit 0\n")
      put_probe_config(codex_binary: path)

      assert %Probe{provider: :codex, binary: true, path: ^path, version: nil, authed?: false} =
               Probe.probe(:codex)
    end
  end
end
