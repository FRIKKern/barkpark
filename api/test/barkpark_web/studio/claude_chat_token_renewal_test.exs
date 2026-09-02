defmodule BarkparkWeb.Studio.ClaudeChatTokenRenewalTest do
  @moduledoc """
  task-cth-bl-token-renewal — a long chat session must not lose its hands when
  the minted `bpcs_` credential's TTL runs out.

  Nothing here simulates expiry. The credential is minted with a REAL one-second
  TTL through auth.ex's own `ttl:` opt (reached from `:claude_chat` config, so
  auth.ex is untouched), the clock really passes it, and the proof that the old
  credential is dead and the new one lives is a REAL task verb over HTTP
  (`GET /v1/tasks/ready`) through the ordinary `verify_token/1` chokepoint —
  the same door `bp` walks through.

  `async: false`: the Session spawns real subprocesses whose GenServers hit the
  Repo from their own processes (shared sandbox).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias BarkparkWeb.Studio.ClaudeChat

  setup do
    ensure_default_scope!()
    ws = create_workspace!("chat-renew-ws-#{System.unique_integer([:positive])}")

    {:ok, minter} =
      Auth.create_token(
        "renew-minter-#{System.unique_integer([:positive])}",
        "chat admin",
        "production",
        ["read", "write"],
        ws.id
      )

    prev_chat = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev_chat,
        do: Application.put_env(:barkpark, :claude_chat, prev_chat),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    %{ws: ws, minter: minter}
  end

  # `cat` is the suite's standing echo-server stand-in for `claude`: a real
  # Port, a real child, zero provider dependency.
  defp chat_config(extra \\ []) do
    Application.put_env(:barkpark, :claude_chat, [command: {"cat", []}] ++ extra)
  end

  defp config_path(sid), do: Path.join(System.tmp_dir!(), "barkpark-claude-#{sid}.mcp.json")

  # The credential exactly as the MCP consumer reads it: out of the per-session
  # 0600 config file's env block. Asserting on this (never on process state)
  # is what makes "the consumer was refreshed" a real claim.
  defp config_token(sid) do
    config_path(sid)
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["mcpServers", "barkpark", "env", "BARKPARK_API_TOKEN"])
  end

  defp start_chat(sid, minter) do
    ClaudeChat.start_session(%{
      sink: self(),
      session_opts: %{session_id: sid, minter: minter}
    })
  end

  # Close AND WAIT. A chat Session is a live GenServer with a Port child and,
  # since this slice, a credential clock that touches the Repo. Letting one
  # outlive its test leaves it ticking against a sandbox that is being torn
  # down — which reds whichever test runs next, not this one.
  defp stop_chat(session) do
    if Process.alive?(session) do
      ref = Process.monitor(session)
      ClaudeChat.close(session)

      receive do
        {:DOWN, ^ref, :process, ^session, _} -> :ok
      after
        5_000 -> :timeout
      end
    else
      :ok
    end
  end

  # A REAL task verb, through the real router and the real token chokepoint.
  defp task_verb_status(raw) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> get("/v1/tasks/ready?limit=1")
    |> Map.fetch!(:status)
  end

  defp session_tokens(sid) do
    Repo.all(from(t in ApiToken, where: t.label == ^"claude-session #{sid}"))
  end

  defp live_session_tokens(sid) do
    Enum.filter(session_tokens(sid), &is_nil(&1.revoked_at))
  end

  # ── criterion 0: expired -> renewed -> a real task verb works again ───────

  describe "the renewal loop (criterion 0)" do
    test "a really-expired credential is named, renewed in place, and a real task verb works again",
         %{minter: minter} do
      # A one-second TTL through auth.ex's own opt — the only thing shortened
      # is the clock, not the code path.
      chat_config(task_token_ttl_s: 1)
      sid = Ecto.UUID.generate()

      {:ok, session} = start_chat(sid, minter)
      on_exit(fn -> stop_chat(session) end)

      old_raw = config_token(sid)
      assert String.starts_with?(old_raw, "bpcs_")

      # The TTL really elapses. No clock stub, no injected verdict.
      Process.sleep(1_200)

      # THE NAMED STATE, read off the session's own credential clock.
      assert ClaudeChat.task_hands(session) == :expired

      # …and it is not a label: the credential is genuinely dead on the wire.
      assert task_verb_status(old_raw) == 401

      # Renew in place — same process, same Port, no respawn, no reload.
      chat_config()
      assert {:ok, info} = ClaudeChat.renew_task_token(session)
      assert info.config_refreshed
      # The honest half: a live child's environment cannot be rewritten.
      assert info.env_rearm_required

      new_raw = config_token(sid)
      assert new_raw != old_raw
      assert String.starts_with?(new_raw, "bpcs_")

      # THE PROOF: a real task verb succeeds afterwards, on the credential the
      # MCP consumer will actually read. (This 200 is also what makes the 401
      # above non-vacuous — same route, same token family.)
      assert task_verb_status(new_raw) == 200

      # Never `:minted`: the running child's shell lane still holds the retired
      # value, and saying otherwise would be the silent failure D2 bans.
      assert ClaudeChat.task_hands(session) == :rearmed
    end

    test "the clock loop renews BEFORE the first failure, without anyone asking",
         %{minter: minter} do
      # A credential minted inside its own renew-ahead skew is due immediately,
      # so the session's own timer does the work — no `renew_task_token/1` call
      # anywhere in this test, and no expiry ever reached.
      chat_config(task_token_ttl_s: 120, task_token_renew_skew_s: 3600, task_token_check_ms: 50)
      sid = Ecto.UUID.generate()

      {:ok, session} = start_chat(sid, minter)
      on_exit(fn -> stop_chat(session) end)

      original = config_token(sid)

      # The renewal announces itself to the sink so the card can flip in place.
      assert_receive {:claude_chat_task_hands, :rearmed}, 2_000

      assert config_token(sid) != original
      assert ClaudeChat.task_hands(session) == :rearmed
      # It renewed ahead of expiry: the retired credential still had ~2 minutes.
      assert {:error, :unauthorized} = Auth.verify_token(original)

      # Stop the fast-ticking session here, not at on_exit — nothing after this
      # line needs it, and a 50ms Repo-touching timer has no business outliving
      # the assertion it exists to prove.
      stop_chat(session)
    end
  end

  # ── criterion 1: one consumer refreshed, predecessor revoked, no leak ─────

  describe "atomic replacement (criterion 1)" do
    test "the config consumer is refreshed, the predecessor revoked, and 0600 survives",
         %{minter: minter} do
      chat_config()
      sid = Ecto.UUID.generate()

      {:ok, session} = start_chat(sid, minter)
      old_raw = config_token(sid)
      assert {:ok, _} = Auth.verify_token(old_raw)

      assert {:ok, _info} = ClaudeChat.renew_task_token(session)
      new_raw = config_token(sid)

      # The predecessor is revoked — not merely left to time out.
      assert {:error, :unauthorized} = Auth.verify_token(old_raw)
      assert {:ok, verified} = Auth.verify_token(new_raw)
      assert verified.label == "claude-session #{sid}"
      # Never more rights than the mint it replaces.
      assert Enum.sort(verified.permissions) == ["chat", "read", "write"]
      refute Auth.has_permission?(verified, "admin")

      # The replacement landed behind the same 0600 clamp as the original.
      assert {:ok, %File.Stat{mode: mode}} = File.stat(config_path(sid))
      assert Bitwise.band(mode, 0o077) == 0

      # Exactly one live credential for this session at every point.
      assert [_one] = live_session_tokens(sid)

      # NO TOKEN OUTLIVES TEARDOWN — the predecessor died at renewal, the
      # replacement dies here.
      assert stop_chat(session) == :ok

      assert live_session_tokens(sid) == []
      assert {:error, :unauthorized} = Auth.verify_token(new_raw)
      refute File.exists?(config_path(sid))
    end

    test "renewal never writes either credential to the log or to its own reply",
         %{minter: minter} do
      chat_config()
      sid = Ecto.UUID.generate()

      {:ok, session} = start_chat(sid, minter)
      on_exit(fn -> stop_chat(session) end)
      old_raw = config_token(sid)

      log =
        capture_log(fn ->
          assert {:ok, info} = ClaudeChat.renew_task_token(session)
          send(self(), {:renew_info, info})
        end)

      assert_received {:renew_info, info}
      new_raw = config_token(sid)

      refute log =~ old_raw
      refute log =~ new_raw
      refute log =~ "bpcs_"

      # The reply the LiveView sees carries a clock and two booleans — never a
      # secret. (The pushed verdict is a bare atom by construction.)
      rendered = inspect(info)
      refute rendered =~ old_raw
      refute rendered =~ new_raw
      refute rendered =~ "bpcs_"
    end
  end

  # ── criterion 2: every failure fails closed, with no orphan credential ────

  describe "fail-closed renewal (criterion 2)" do
    test "a refused mint keeps the OLD credential and creates nothing", %{minter: minter} do
      chat_config()
      sid = Ecto.UUID.generate()

      {:ok, session} = start_chat(sid, minter)
      on_exit(fn -> stop_chat(session) end)
      old_raw = config_token(sid)

      # Take the minter's rights away mid-session: the very next mint is
      # refused by the up-front Tenancy.Auth.authorize/3 gate.
      Repo.delete_all(from(m in Barkpark.Tenancy.Membership, where: m.principal_id == ^minter.id))

      assert capture_log(fn ->
               assert {:error, {:mint_refused, _reason}} = ClaudeChat.renew_task_token(session)
             end) =~ "keeping the old credential"

      # The old credential is untouched — a refused renewal must never turn
      # into an immediate outage.
      assert config_token(sid) == old_raw
      assert {:ok, _} = Auth.verify_token(old_raw)
      # …and no half-born replacement exists anywhere.
      assert length(session_tokens(sid)) == 1
    end

    test "a session with no refreshable consumer REFUSES to mint an unreadable credential",
         %{minter: minter} do
      chat_config()
      sid = Ecto.UUID.generate()

      # Make the spawn-time config write fail (a directory where the file goes)
      # so the session has env-only hands — and a live child's env can never be
      # rewritten. A replacement would be readable by nobody.
      File.mkdir_p!(config_path(sid))
      on_exit(fn -> File.rm_rf(config_path(sid)) end)

      {:ok, session} = start_chat(sid, minter)
      on_exit(fn -> stop_chat(session) end)

      assert length(session_tokens(sid)) == 1
      assert {:error, :no_refreshable_consumer} = ClaudeChat.renew_task_token(session)
      # No orphan: refusing to mint is the whole point.
      assert length(session_tokens(sid)) == 1
    end

    test "concurrent renewal requests produce exactly ONE replacement", %{minter: minter} do
      chat_config()
      sid = Ecto.UUID.generate()

      {:ok, session} = start_chat(sid, minter)
      on_exit(fn -> stop_chat(session) end)

      results =
        1..6
        |> Task.async_stream(fn _ -> ClaudeChat.renew_task_token(session) end,
          max_concurrency: 6,
          timeout: 20_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      # Five of the six are answered without minting — two mints for one expiry
      # is exactly how an orphan credential is born.
      assert Enum.count(results, &(&1 == {:ok, :already_renewed})) == 5

      # Original + exactly one replacement; exactly one of them still live.
      assert length(session_tokens(sid)) == 2
      assert [_one] = live_session_tokens(sid)
    end

    test "a close racing a renewal leaves no credential behind", %{minter: minter} do
      chat_config()
      sid = Ecto.UUID.generate()

      {:ok, session} = start_chat(sid, minter)
      ref = Process.monitor(session)

      # Both messages land in the same mailbox; the GenServer serializes them,
      # so teardown can never interleave with a half-finished swap.
      renewal = Task.async(fn -> ClaudeChat.renew_task_token(session) end)
      ClaudeChat.close(session)

      # Either outcome is fine — a renewal that won the race, or one that found
      # the session already gone. What is NOT fine is a credential left behind.
      outcome = Task.await(renewal, 20_000)
      assert match?({:ok, _}, outcome) or match?({:error, _}, outcome)

      assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000

      assert live_session_tokens(sid) == []
      refute File.exists?(config_path(sid))
    end

    test "a renewed session reports :rearmed, never :minted — the child was NOT re-armed",
         %{minter: minter} do
      chat_config()
      sid = Ecto.UUID.generate()

      {:ok, session} = start_chat(sid, minter)
      on_exit(fn -> stop_chat(session) end)

      assert ClaudeChat.task_hands(session) == :minted
      assert {:ok, info} = ClaudeChat.renew_task_token(session)

      # The running child's `BARKPARK_API_TOKEN` is fixed at Port.open. The
      # contract says so out loud instead of claiming a re-arm it cannot do.
      assert info.env_rearm_required
      assert ClaudeChat.task_hands(session) == :rearmed
      refute ClaudeChat.task_hands(session) == :minted
    end

    test "a handless session has nothing to renew" do
      chat_config()
      sid = Ecto.UUID.generate()

      # No minter ⇒ no mint ⇒ the env carries the poison sentinel by design.
      {:ok, session} =
        ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: sid}})

      on_exit(fn -> stop_chat(session) end)

      assert {:error, :not_attempted} = ClaudeChat.renew_task_token(session)
      assert session_tokens(sid) == []
    end

    test "renewing a dead session is an error, not a crash", %{minter: minter} do
      chat_config()
      sid = Ecto.UUID.generate()

      {:ok, session} = start_chat(sid, minter)
      assert stop_chat(session) == :ok

      assert {:error, :session_gone} = ClaudeChat.renew_task_token(session)
    end
  end

  # ── the pure clock classifier the whole decision reads off ────────────────

  describe "token_phase/1" do
    test "classifies live / renew-due / expired / unknown" do
      chat_config(task_token_renew_skew_s: 300)
      now = DateTime.utc_now()

      assert ClaudeChat.token_phase(DateTime.add(now, 3600)) == :live
      assert ClaudeChat.token_phase(DateTime.add(now, 60)) == :renew_due
      assert ClaudeChat.token_phase(DateTime.add(now, -1)) == :expired
      assert ClaudeChat.token_phase(nil) == :unknown
    end
  end
end
