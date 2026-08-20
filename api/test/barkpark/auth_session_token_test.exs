defmodule Barkpark.AuthSessionTokenTest do
  @moduledoc """
  scc-w12-mcp-loopback (charter D63) — `Auth.create_claude_session_token/3` +
  the ClaudeChat.Session mint/revoke lifecycle.

  The contract: the loopback credential is a REAL `kind: "api"` ApiToken (so
  `verify_token/1` accepts it — an Access grant token is PROVEN rejected
  there), with curated `read`/`write` permissions (never admin, never
  share-edit-*, never caller-supplied), a session-grade TTL (hours — NOT
  `clamp_ttl/1`'s 7-day share floor), workspace scoping, NO membership row,
  and an up-front `Tenancy.Auth.authorize/3` gate on the MINTER. The Session
  revokes it (idempotently) and removes the temp mcp-config in BOTH
  terminate/2 clauses; the TTL is only the crash backstop.

  `async: false` — the Session lifecycle tests spawn real subprocesses whose
  GenServers hit the Repo from their own processes (shared sandbox).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias BarkparkWeb.Plugs.RequireChatAccess
  alias BarkparkWeb.Studio.ClaudeChat

  import Barkpark.TenancyFixtures
  import Ecto.Query
  import Plug.Test
  import Plug.Conn

  @session_ttl_cap 24 * 3600
  @session_ttl_default 4 * 3600

  setup do
    ws = create_workspace!("claude-sess-ws")

    # The minter: the chat admin's principal — a member of the workspace with
    # write rights (create_token/5 inserts the membership row).
    raw_minter = "minter-#{System.unique_integer([:positive])}"

    {:ok, minter} =
      Auth.create_token(raw_minter, "chat admin", "production", ["read", "write"], ws.id)

    %{ws: ws, minter: minter}
  end

  defp live_session_token(session_id) do
    Repo.one(
      from(t in ApiToken,
        where: t.label == ^"claude-session #{session_id}" and is_nil(t.revoked_at)
      )
    )
  end

  # ── minting (charter D63) ────────────────────────────────────────────────

  describe "create_claude_session_token/3" do
    test "mints a short-lived, workspace-scoped, curated-permission api token",
         %{ws: ws, minter: minter} do
      sid = Ecto.UUID.generate()

      assert {:ok, {raw, %ApiToken{} = token}} =
               Auth.create_claude_session_token(minter, sid)

      assert String.starts_with?(raw, "bpcs_")
      assert token.label == "claude-session #{sid}"
      assert token.workspace_id == ws.id
      # curated REAL permissions — the loopback's task/doc/search verbs ride
      # the ordinary tiers, and `chat` reaches /v1/chat (herd-s4); NEVER admin,
      # NEVER opaque share perms.
      assert Enum.sort(token.permissions) == ["chat", "read", "write"]
      refute Auth.has_permission?(token, "admin")
      refute Enum.any?(token.permissions, &String.starts_with?(&1, "share-edit-"))
      # kind stays "api", so the single verify_token chokepoint accepts it
      # (the Access.mint grant-token path is PROVEN rejected there — D63).
      assert {:ok, verified} = Auth.verify_token(raw)
      assert verified.id == token.id
    end

    test "the REAL mint carries chat and RequireChatAccess resolves {:workspace, ws}, not 403",
         %{ws: ws, minter: minter} do
      # herd-s4: the loopback credential must reach /v1/chat. The mint carries
      # `chat` and is workspace-bound, so RequireChatAccess inherits a tenant
      # scope by construction — never instance-global, never a 403.
      assert {:ok, {_raw, %ApiToken{} = token}} =
               Auth.create_claude_session_token(minter, Ecto.UUID.generate())

      assert Auth.has_permission?(token, "chat")
      assert token.workspace_id == ws.id

      conn =
        conn(:get, "/v1/chat/sessions")
        |> assign(:api_token, token)
        |> RequireChatAccess.call(RequireChatAccess.init([]))

      refute conn.halted
      assert conn.assigns.chat_scope == {:workspace, ws.id}
    end

    test "default TTL is session-grade (hours), NOT clamp_ttl's 7-day share floor",
         %{minter: minter} do
      assert {:ok, {_raw, token}} =
               Auth.create_claude_session_token(minter, Ecto.UUID.generate())

      ttl = DateTime.diff(token.expires_at, DateTime.utc_now())
      assert_in_delta ttl, @session_ttl_default, 60
    end

    test "an oversized ttl clamps to the session cap; a small one is honored",
         %{minter: minter} do
      assert {:ok, {_raw, capped}} =
               Auth.create_claude_session_token(minter, Ecto.UUID.generate(),
                 ttl: 365 * 24 * 3600
               )

      assert DateTime.diff(capped.expires_at, DateTime.utc_now()) <= @session_ttl_cap + 60

      assert {:ok, {_raw, short}} =
               Auth.create_claude_session_token(minter, Ecto.UUID.generate(), ttl: 60)

      assert_in_delta DateTime.diff(short.expires_at, DateTime.utc_now()), 60, 30
    end

    test "permissions are NEVER caller-supplied — a :permissions opt is ignored",
         %{minter: minter} do
      assert {:ok, {_raw, token}} =
               Auth.create_claude_session_token(minter, Ecto.UUID.generate(),
                 permissions: ["admin"]
               )

      assert Enum.sort(token.permissions) == ["chat", "read", "write"]
      refute Auth.has_permission?(token, "admin")
    end

    test "the minted token gets NO membership row (share-token posture)",
         %{minter: minter} do
      assert {:ok, {_raw, token}} =
               Auth.create_claude_session_token(minter, Ecto.UUID.generate())

      refute Repo.exists?(
               from(m in Barkpark.Tenancy.Membership,
                 where: m.principal_id == ^token.id and m.principal_type == "api_token"
               )
             )
    end

    test "refuses a READ-ONLY minter — the token never exceeds the human's rights",
         %{ws: ws} do
      {:ok, reader} =
        Auth.create_token(
          "reader-#{System.unique_integer([:positive])}",
          "read-only member",
          "production",
          ["read"],
          ws.id
        )

      assert {:error, :forbidden} =
               Auth.create_claude_session_token(reader, Ecto.UUID.generate())
    end

    test "refuses a NON-MEMBER minter and a nil minter (fail-closed)", %{ws: ws} do
      stranger_ws = create_workspace!("claude-sess-other")

      {:ok, stranger} =
        Auth.create_token(
          "stranger-#{System.unique_integer([:positive])}",
          "other-ws admin",
          "production",
          ["read", "write"],
          stranger_ws.id
        )

      # a member elsewhere is not a member HERE
      assert {:error, :forbidden} =
               Auth.create_claude_session_token(stranger, Ecto.UUID.generate(),
                 workspace_id: ws.id
               )

      assert {:error, :forbidden} =
               Auth.create_claude_session_token(nil, Ecto.UUID.generate(), workspace_id: ws.id)
    end
  end

  # ── revocation (the primary teardown; TTL is only the backstop) ──────────

  describe "revoke_token/1 on a session token" do
    test "is idempotent and verify_token rejects after", %{minter: minter} do
      assert {:ok, {raw, token}} =
               Auth.create_claude_session_token(minter, Ecto.UUID.generate())

      assert {:ok, _} = Auth.verify_token(raw)
      assert {:ok, revoked} = Auth.revoke_token(token)
      assert revoked.revoked_at != nil
      # idempotent: a second revoke merely re-stamps, never errors
      assert {:ok, _} = Auth.revoke_token(revoked)
      assert {:error, :unauthorized} = Auth.verify_token(raw)
    end
  end

  # ── the Session lifecycle: mint on spawn, revoke + rm config on teardown ──

  describe "ClaudeChat.Session mint/revoke lifecycle (charter D63/D64)" do
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

    defp config_path(sid), do: Path.join(System.tmp_dir!(), "barkpark-claude-#{sid}.mcp.json")

    test "spawn mints + writes the config; close (terminate WITH port) revokes + removes it",
         %{minter: minter} do
      put_chat_config(command: {"cat", []})
      sid = Ecto.UUID.generate()

      {:ok, session} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: sid, minter: minter}
        })

      ref = Process.monitor(session)

      # the credential is live and the temp config carries it in the env block
      assert %ApiToken{} = live_session_token(sid)
      path = config_path(sid)
      assert File.exists?(path)
      config = path |> File.read!() |> Jason.decode!()
      server = config["mcpServers"]["barkpark"]
      assert server["args"] == ["mcp", "serve", "--tools", "all"]

      # the env block wins over any saved host config: BOTH url and token are
      # pinned, and the token is the freshly-minted SESSION credential (it
      # verifies to the claude-session row — never the host's admin token).
      env = server["env"]
      assert is_binary(env["BARKPARK_API_URL"]) and env["BARKPARK_API_URL"] != ""
      assert String.starts_with?(env["BARKPARK_API_TOKEN"], "bpcs_")
      assert {:ok, verified} = Auth.verify_token(env["BARKPARK_API_TOKEN"])
      assert verified.label == "claude-session #{sid}"

      ClaudeChat.close(session)
      assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000

      # first terminate clause (port still open): revoked + config removed
      assert live_session_token(sid) == nil
      assert {:error, :unauthorized} = Auth.verify_token(env["BARKPARK_API_TOKEN"])
      refute File.exists?(path)
    end

    test "a subprocess exit (terminate WITHOUT port) also revokes + removes",
         %{minter: minter} do
      put_chat_config(command: {"sh", ["-c", "exit 0"]})
      sid = Ecto.UUID.generate()

      {:ok, session} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: sid, minter: minter}
        })

      ref = Process.monitor(session)
      assert_receive {:claude_chat_exit, 0, _stderr}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000

      # second terminate clause (port already gone): same cleanup story
      assert live_session_token(sid) == nil
      refute File.exists?(config_path(sid))
    end

    test "no minter ⇒ no mint, no config — the chat spawns exactly as before",
         _ctx do
      put_chat_config(command: {"cat", []})
      sid = Ecto.UUID.generate()

      {:ok, session} =
        ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: sid}})

      refute Repo.exists?(from(t in ApiToken, where: t.label == ^"claude-session #{sid}"))

      refute File.exists?(config_path(sid))
      ClaudeChat.close(session)
    end

    test "a refused mint fails SOFT — the session still spawns, without hands",
         %{ws: ws} do
      {:ok, reader} =
        Auth.create_token(
          "soft-reader-#{System.unique_integer([:positive])}",
          "read-only member",
          "production",
          ["read"],
          ws.id
        )

      put_chat_config(command: {"cat", []})
      sid = Ecto.UUID.generate()

      {:ok, session} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: sid, minter: reader}
        })

      assert Process.alive?(session)
      assert live_session_token(sid) == nil
      refute File.exists?(config_path(sid))
      ClaudeChat.close(session)
    end
  end
end
