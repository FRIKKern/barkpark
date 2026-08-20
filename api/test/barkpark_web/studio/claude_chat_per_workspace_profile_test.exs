defmodule BarkparkWeb.Studio.ClaudeChatPerWorkspaceProfileTest do
  @moduledoc """
  Per-workspace execution-profile routing (connectors Wave 23, charter
  D205/D206; task connectors-per-workspace-execution-profile).

  W11–W16 built the whole Cloud-runner crux behind a config-keyed
  `:execution_profile` resolver — but NOTHING ever set it per workspace, so
  every Barkpark Chat turn resolved the SAME global profile. This file proves
  the missing consumer seam: a workspace that opts into
  `settings["chat"]["execution_profile"] = "cloud"` gets its turns routed to
  the sandbox runner, while every other workspace (and the nil-workspace
  host-admin session) stays self-hosted — resolved ONCE per Session spawn in
  `Session.init/1`, feeding BOTH consumers (`command/2`'s exe/argv AND the
  cloud tool-descriptor threading).

  Everything offline at the config/argv layer (the LIVE cloud turn stays
  human-gated — `connectors-hg-live-isolated-cloud-turn`): the `:binary` and
  `:sandbox_runner` overrides are chmod+x marker shims, NEVER the `:command`
  tuple (vacuous-green law — `:command` bypasses `build_args/2` AND the
  profile branch entirely, claude_chat.ex moduledoc). The global
  `:execution_profile` config stays UNSET in the decisive tests, so a pass
  can only come from the per-workspace resolution.

  RED-FIRST: on the pre-change (global-only) resolver, the workspace-A tests
  fail with the self-hosted marker — the exact probe the Verify phase ran on
  origin/main ("got selfhosted-marker").
  """
  # async: false + Barkpark.DataCase ⇒ shared sandbox mode: the Session
  # GenServer resolves the workspace profile (and CloudPolicy's install
  # cross-check) from ITS process, which must reach this test's DB connection.
  use Barkpark.DataCase, async: false

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Workspace
  alias BarkparkWeb.Studio.ClaudeChat

  # A stub bridge for the tool-descriptor consumer (mirror of
  # claude_chat_test.exs's ToolBridgeStub, trimmed): answers ONE github
  # descriptor for a decoded TOOL-SESSION ticket. Workspace correctness is
  # carried by the install cross-check (CloudPolicy drops descriptors whose
  # provider has no install for the turn's workspace) + the `--workspace` argv.
  defmodule ProfileToolBridgeStub do
    @behaviour Barkpark.Connectors.Bridge

    @impl true
    def validate(_ticket, _credential), do: {:error, :unreachable}
    @impl true
    def connect(_ticket, _credential, _chat_token), do: {:error, :unreachable}
    @impl true
    def disconnect(_ticket, _install_key), do: {:error, :unreachable}
    @impl true
    def stage_pending(_ticket, _chat_token), do: {:error, :unreachable}

    @impl true
    def fetch_tool_descriptors(ticket) do
      with [body, _sig] <- String.split(ticket, ".", parts: 2),
           {:ok, json} <- Base.url_decode64(body, padding: false),
           {:ok, %{"p" => "tool-session"}} <- Jason.decode(json) do
        {:ok,
         [
           %{
             "provider" => "github",
             "type" => "http",
             "url" => "https://api.githubcopilot.com/mcp/"
           }
         ]}
      else
        _ -> {:ok, []}
      end
    end
  end

  # ── D205 storage: the Tenancy accessor pair ────────────────────────────────

  describe "workspace_chat_settings/1 (fail-safe read)" do
    test "a fresh workspace (no settings) resolves to the empty map" do
      ws = workspace!()
      assert ws.settings == %{}
      assert Tenancy.workspace_chat_settings(ws) == %{}
    end

    test "a stored chat map is returned verbatim" do
      ws = workspace!(%{settings: %{"chat" => %{"execution_profile" => "cloud"}}})
      assert Tenancy.workspace_chat_settings(ws) == %{"execution_profile" => "cloud"}
    end

    test "a nil workspace is guarded → empty map" do
      assert Tenancy.workspace_chat_settings(nil) == %{}
    end

    test "a workspace whose settings is nil (legacy row) → empty map" do
      assert Tenancy.workspace_chat_settings(%Workspace{settings: nil}) == %{}
    end

    test "a non-map chat value (malformed row) → empty map" do
      assert Tenancy.workspace_chat_settings(%Workspace{settings: %{"chat" => "cloud"}}) == %{}
    end
  end

  describe "set_workspace_chat_settings/2 (merge-in-place write)" do
    test "persists and round-trips through workspace_chat_settings/1" do
      ws = workspace!()

      assert {:ok, updated} =
               Tenancy.set_workspace_chat_settings(ws, %{"execution_profile" => "cloud"})

      assert updated.settings["chat"] == %{"execution_profile" => "cloud"}

      reloaded = Tenancy.get_workspace_by_id(ws.id)
      assert Tenancy.workspace_chat_settings(reloaded) == %{"execution_profile" => "cloud"}
    end

    test "accepts a workspace id binary" do
      ws = workspace!()

      assert {:ok, updated} =
               Tenancy.set_workspace_chat_settings(ws.id, %{"execution_profile" => "self_hosted"})

      assert updated.settings["chat"] == %{"execution_profile" => "self_hosted"}
    end

    test "preserves unrelated settings keys (merge, not replace)" do
      ws = workspace!(%{settings: %{"theme" => "evergreen", "other" => "keep-me"}})

      assert {:ok, updated} =
               Tenancy.set_workspace_chat_settings(ws, %{"execution_profile" => "cloud"})

      assert updated.settings["theme"] == "evergreen"
      assert updated.settings["other"] == "keep-me"
      assert updated.settings["chat"] == %{"execution_profile" => "cloud"}
    end

    test "rejects a non-map without touching the row" do
      ws = workspace!()
      assert {:error, :invalid_chat_settings} = Tenancy.set_workspace_chat_settings(ws, "cloud")
      assert Tenancy.get_workspace_by_id(ws.id).settings == %{}
    end

    test "a well-formed but absent id returns :not_found" do
      assert {:error, :not_found} =
               Tenancy.set_workspace_chat_settings(Ecto.UUID.generate(), %{
                 "execution_profile" => "cloud"
               })
    end
  end

  # ── D205 routing: one Session.init/1 resolution feeding BOTH consumers ─────

  describe "workspace-aware execution profile (connectors D205 — the missing consumer seam)" do
    test "workspace A (chat.execution_profile=cloud) routes to the SANDBOX runner — global config UNSET" do
      {marker, argv} = install_marker_shims()

      ws = workspace!()
      {:ok, _} = Tenancy.set_workspace_chat_settings(ws, %{"execution_profile" => "cloud"})

      spawn_and_wait(%{workspace_id: ws.id, session_id: Ecto.UUID.generate()})

      assert read_marker(marker) == "cloud-marker"
      # The cloud argv shape, not just the exe: the shim's own argv carries the
      # workspace principal (cloud_build_args/2 — D110).
      assert consecutive?(read_argv(argv), ["--workspace", ws.id])
    end

    test "workspace B (unset chat settings) stays SELF-HOSTED — global config UNSET" do
      {marker, argv} = install_marker_shims()

      ws = workspace!()
      spawn_and_wait(%{workspace_id: ws.id, session_id: Ecto.UUID.generate()})

      assert read_marker(marker) == "selfhosted-marker"
      refute "--workspace" in read_argv(argv)
    end

    test "nil workspace_id (host-admin/:global session) stays SELF-HOSTED" do
      {marker, _argv} = install_marker_shims()

      spawn_and_wait(%{session_id: Ecto.UUID.generate()})

      assert read_marker(marker) == "selfhosted-marker"
    end

    test "an unknown per-workspace value counts as UNSET → self-hosted (fail-safe)" do
      {marker, _argv} = install_marker_shims()

      ws = workspace!()
      {:ok, _} = Tenancy.set_workspace_chat_settings(ws, %{"execution_profile" => "mainframe"})

      spawn_and_wait(%{workspace_id: ws.id, session_id: Ecto.UUID.generate()})

      assert read_marker(marker) == "selfhosted-marker"
    end

    test "per-workspace self_hosted WINS over an explicit global :cloud config" do
      {marker, _argv} = install_marker_shims(execution_profile: :cloud)

      ws = workspace!()
      {:ok, _} = Tenancy.set_workspace_chat_settings(ws, %{"execution_profile" => "self_hosted"})

      spawn_and_wait(%{workspace_id: ws.id, session_id: Ecto.UUID.generate()})

      assert read_marker(marker) == "selfhosted-marker"
    end

    test "per-workspace cloud WINS over an explicit global :self_hosted config" do
      {marker, argv} = install_marker_shims(execution_profile: :self_hosted)

      ws = workspace!()
      {:ok, _} = Tenancy.set_workspace_chat_settings(ws, %{"execution_profile" => "cloud"})

      spawn_and_wait(%{workspace_id: ws.id, session_id: Ecto.UUID.generate()})

      assert read_marker(marker) == "cloud-marker"
      assert consecutive?(read_argv(argv), ["--workspace", ws.id])
    end

    test "the tool-descriptor threading follows the per-workspace profile — BOTH consumers, one resolution" do
      {marker, argv} = install_marker_shims()

      # A real tool-direction install (raw SQL — the bridge is production's only
      # writer) + a stub bridge: the cloud turn must carry --mcp-config-b64,
      # proving maybe_thread_cloud_tool_descriptors/1 read the SAME per-workspace
      # profile as command/2. A half-fix (only command/2 workspace-aware) would
      # route the exe to the sandbox but skip the descriptor threading — cloud
      # turn with NO tool servers (banned by D205) — and fail here.
      put_connectors_config(connect_secret: "w23-test-secret", bridge: ProfileToolBridgeStub)

      ws = workspace!()
      insert_install("github", "octocat/repo", ws.id)
      {:ok, _} = Tenancy.set_workspace_chat_settings(ws, %{"execution_profile" => "cloud"})

      spawn_and_wait(%{workspace_id: ws.id, session_id: Ecto.UUID.generate()})

      assert read_marker(marker) == "cloud-marker"

      args = read_argv(argv)
      idx = Enum.find_index(args, &(&1 == "--mcp-config-b64"))
      sep = Enum.find_index(args, &(&1 == "--"))

      assert is_integer(idx) and idx < sep,
             "a cloud-profiled workspace's turn must thread its tool descriptors " <>
               "(--mcp-config-b64 pre-`--`) — got #{inspect(args)}"

      decoded = args |> Enum.at(idx + 1) |> Base.decode64!() |> Jason.decode!()

      assert decoded["mcpServers"] == %{
               "github" => %{"type" => "http", "url" => "https://api.githubcopilot.com/mcp/"}
             }

      # W25 (D213): a cloud turn with >=1 surviving tool server also carries the
      # bpConnectorTicket the in-VM shim exchanges (host-side, D71 loopback) for
      # the connector's finished Authorization header — the credential itself
      # never transits Elixir or argv, only this non-secret ticket does.
      assert is_binary(decoded["bpConnectorTicket"]) and decoded["bpConnectorTicket"] != ""
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp workspace!(attrs \\ %{}) do
    slug = "ws-profile-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(Map.merge(%{slug: slug, name: "W23 #{slug}"}, attrs))
    ws
  end

  # Install the two marker shims as :binary (self-hosted) / :sandbox_runner
  # (cloud) — NEVER :command (vacuous-green law). Exactly one shim runs per
  # spawn; the marker file names which. `extra` adds config keys (e.g. an
  # explicit global :execution_profile for the wins-in-both-directions tests);
  # the decisive tests pass none, leaving the global UNSET.
  defp install_marker_shims(extra \\ []) do
    marker = capture_path("marker")
    argv = capture_path("argv")

    put_chat_config(
      [
        enabled: true,
        binary: marker_shim(marker, "selfhosted-marker", argv),
        sandbox_runner: marker_shim(marker, "cloud-marker", argv)
      ] ++ extra
    )

    {marker, argv}
  end

  # A one-shot marker shim: name itself in the marker file, capture its OWN
  # argv verbatim (one arg per line, empty args preserved), emit a terminal
  # result frame, EXIT (the Session dies :normal — the DOWN the spawner waits on).
  defp marker_shim(marker_file, marker, argv_file) do
    script = """
    #!/bin/sh
    printf '%s\\n' '#{marker}' > '#{marker_file}'
    printf '%s\\n' "$@" > '#{argv_file}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    """

    write_shim(script)
  end

  defp spawn_and_wait(session_opts) do
    {:ok, session} = ClaudeChat.start_session(%{sink: self(), session_opts: session_opts})
    ref = Process.monitor(session)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5_000
  end

  defp put_chat_config(config) do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, config)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end

  defp put_connectors_config(overrides) do
    prev = Application.get_env(:barkpark, Barkpark.Connectors)
    merged = Keyword.merge(prev || [], overrides)
    Application.put_env(:barkpark, Barkpark.Connectors, merged)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, Barkpark.Connectors, prev),
        else: Application.delete_env(:barkpark, Barkpark.Connectors)
    end)
  end

  # The bridge is production's only writer; tests write raw SQL (D54).
  defp insert_install(provider, key, ws_id) do
    Barkpark.Repo.query!(
      """
      INSERT INTO chat_bridge.connector_installs
        (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
      VALUES ($1, $2, $3, $4, $5, now())
      """,
      [provider, key, ws_id, "SEALED-CREDENTIAL-BLOB", "SEALED-CHAT-TOKEN-BLOB"]
    )
  end

  defp write_shim(script) do
    path =
      Path.join(
        System.tmp_dir!(),
        "claude_chat_profile_shim_#{System.pid()}_#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, script)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp read_marker(file), do: file |> wait_for_file() |> String.trim()

  # Read a captured argv, ONE arg per line, PRESERVING empty-string args (the
  # cloud argv carries `--tools ""`). Drop only the single trailing "" the
  # final newline produces.
  defp read_argv(file) do
    parts = file |> wait_for_file() |> String.split("\n")

    case List.last(parts) do
      "" -> Enum.drop(parts, -1)
      _ -> parts
    end
  end

  # Whether `pair` (a 2-element list) appears as CONSECUTIVE elements of `args`.
  defp consecutive?(args, pair), do: Enum.chunk_every(args, 2, 1) |> Enum.member?(pair)

  defp capture_path(kind) do
    file =
      Path.join(
        System.tmp_dir!(),
        "claude_chat_profile_#{kind}_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf(file)
    on_exit(fn -> File.rm_rf(file) end)
    file
  end

  defp wait_for_file(file, tries \\ 400) do
    cond do
      File.exists?(file) and File.read!(file) != "" -> File.read!(file)
      tries <= 0 -> flunk("capture file never written: #{file}")
      true -> Process.sleep(20) && wait_for_file(file, tries - 1)
    end
  end
end
