defmodule BarkparkWeb.Studio.ConnectorsLiveTest do
  @moduledoc """
  THE CONNECT LOOP (Connectors D47–D55) — Studio's half, end to end.

  What this suite is actually defending:

    * **The two-minute claim is a PRODUCT, not a claim.** Click Connect, paste a
      token, confirm the bot, and Barkpark mints + labels + ships + reads back an
      install. Nothing here is hand-wired.
    * **A failed connect REVOKES the token it just minted.** A minted-but-unattached
      workspace `chat` token is a live credential nobody owns. Leaking one is
      strictly worse than failing the connect.
    * **The gate delta (D49).** A token that MOUNTS this page (global `admin`
      permission) but is not a member-admin of THIS workspace cannot connect. If
      that re-gate were missing, the in-process mint would be a privilege
      escalation relative to the HTTP endpoint it delegates to.
    * **No fake Connected, ever.** Bridge unreachable, secret absent, bridge
      refuses — every one of them renders honestly, and the card stays
      "Not connected" because the card is rendered from the DATABASE, not from a
      hopeful assign.
    * **No secret in the assigns (D38).** `credential_ref` / `chat_token_ref` are
      sealed blobs; they never reach a socket.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Connectors.Catalog
  alias Barkpark.Connectors.ConnectTicket
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Test.ConnectorsBridgeStub, as: Stub

  import Ecto.Query

  @secret "test-connect-secret"
  @telegram_key "8100000001"

  setup %{conn: conn} do
    ensure_default_scope!()

    {:ok, ws} = Tenancy.create_workspace(%{slug: "conn-ws", name: "Conn WS"})
    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    # WORKSPACE ADMIN — the legit operator. Global `admin` perms (so LiveAuth's
    # mount gate passes) AND an admin membership row in THIS workspace.
    admin_raw = "conn-admin-#{System.unique_integer([:positive])}"
    {:ok, admin} = Auth.create_token(admin_raw, "admin", "production", ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, admin.id, "admin")

    # THE GATE DELTA (D49). Same global `admin` permission — so it MOUNTS the
    # catalog exactly like the operator above — but only a `member` of this
    # workspace. It must not be able to connect anything.
    outsider_raw = "conn-outsider-#{System.unique_integer([:positive])}"

    {:ok, outsider} =
      Auth.create_token(outsider_raw, "outsider", "production", ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, outsider.id)

    on_exit(fn -> Application.delete_env(:barkpark, Barkpark.Connectors) end)

    configure(bridge: Barkpark.Connectors.BridgeClient, connect_secret: @secret)

    {:ok,
     conn: conn,
     ws: ws,
     path: "/w/#{ws.slug}/p/default/studio/connectors",
     admin_raw: admin_raw,
     outsider_raw: outsider_raw}
  end

  defp configure(opts) do
    base = [
      bridge_url: "http://127.0.0.1:4020/connectors",
      connect_secret: nil,
      bridge: Barkpark.Connectors.BridgeClient
    ]

    Application.put_env(:barkpark, Barkpark.Connectors, Keyword.merge(base, opts))
  end

  defp as(conn, raw), do: init_test_session(conn, %{"api_token" => raw})

  defp script(ws, overrides) do
    Stub.start(
      Map.merge(
        %{
          workspace_id: ws.id,
          provider: "telegram",
          validate: {:ok, %{install_key: @telegram_key, display_name: "Acme Ops Bot"}},
          connect: {:ok, %{install_key: @telegram_key, mounted: true}},
          disconnect: {:ok, %{removed: true}}
        },
        overrides
      )
    )

    configure(bridge: Stub, connect_secret: @secret)
  end

  defp live_tokens(ws, provider, key) do
    label = Catalog.token_label(provider, key)

    ApiToken
    |> where([t], t.workspace_id == ^ws.id and t.label == ^label)
    |> Repo.all()
  end

  defp connect!(view) do
    view |> element(~s([data-test-id="connector-connect-telegram"])) |> render_click()

    view
    |> form(~s(#connectors-connect-modal form), %{"credential" => "123:abc"})
    |> render_submit()

    view |> element(~s([data-test-id="connectors-confirm-connect"])) |> render_click()
  end

  # ── The catalog ────────────────────────────────────────────────────────────

  describe "the catalog" do
    test "lists all six providers, each wearing its real onboarding weight", %{
      conn: conn,
      path: path,
      admin_raw: raw
    } do
      {:ok, _view, html} = live(as(conn, raw), path)

      for %{id: id, name: name} <- Catalog.providers() do
        assert html =~ ~s(data-test-id="connector-card-#{id}")
        assert html =~ name
      end

      # The gates are stated, not hidden. Slack now connects over OAuth, so with no
      # Slack app configured on this instance its card shows the honest
      # not-configured note — never a broken button.
      assert html =~ "Add to Slack is not configured on this instance"
      assert html =~ ~s(data-test-id="connector-oauth-gate-slack")
      assert html =~ "your org&#39;s Azure admin"
      assert html =~ "App Review"
      assert html =~ "Self-hosted only"
    end

    test "with zero installs every card is Not connected — nothing is seeded", %{
      conn: conn,
      path: path,
      admin_raw: raw
    } do
      {:ok, view, _html} = live(as(conn, raw), path)
      html = render(view)

      assert html =~ "Not connected"

      for %{id: id} <- Catalog.providers() do
        refute html =~ ~s(data-test-id="connector-install-#{id}")
        refute html =~ ~s(data-test-id="connector-disconnect-#{id}")
      end
    end

    test "only CONNECTABLE providers get a Connect button (D51)", %{
      conn: conn,
      path: path,
      admin_raw: raw
    } do
      {:ok, _view, html} = live(as(conn, raw), path)

      assert html =~ ~s(data-test-id="connector-connect-telegram")
      assert html =~ ~s(data-test-id="connector-connect-discord")

      for id <- ~w(slack teams whatsapp imessage) do
        refute html =~ ~s(data-test-id="connector-connect-#{id}")
      end
    end

    test "an existing install renders as Connected, from the DATABASE", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      Repo.query!(
        """
        INSERT INTO chat_bridge.connector_installs
          (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
        VALUES ('telegram', $1, $2, 'SEALED-CREDENTIAL-BLOB', 'SEALED-CHAT-TOKEN-BLOB', now())
        """,
        [@telegram_key, ws.id]
      )

      {:ok, view, _html} = live(as(conn, raw), path)
      html = render(view)

      assert html =~ ~s(data-test-id="connector-install-telegram")
      assert html =~ @telegram_key
      assert html =~ "Connected"
      assert html =~ ~s(data-test-id="connector-disconnect-telegram")
      # …and the Connect button is gone.
      refute html =~ ~s(data-test-id="connector-connect-telegram")
    end

    test "NO SECRET reaches the socket (D38)", %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      Repo.query!(
        """
        INSERT INTO chat_bridge.connector_installs
          (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
        VALUES ('telegram', $1, $2, 'SEALED-CREDENTIAL-BLOB', 'SEALED-CHAT-TOKEN-BLOB', now())
        """,
        [@telegram_key, ws.id]
      )

      {:ok, view, _html} = live(as(conn, raw), path)

      refute render(view) =~ "SEALED"

      # installs is grouped by provider → a LIST per provider (D161). One telegram
      # install ⇒ a one-element list; the sealed blobs are absent from the member.
      [install] = :sys.get_state(view.pid).socket.assigns.installs["telegram"]
      refute Map.has_key?(install, :credential_ref)
      refute Map.has_key?(install, :chat_token_ref)
      refute inspect(:sys.get_state(view.pid).socket.assigns) =~ "SEALED"
    end
  end

  # ── Read-only postures (never a crash, never a fake Connected) ─────────────

  describe "honest degraded states" do
    test "no connect secret => read-only catalog + banner, no Connect buttons", %{
      conn: conn,
      path: path,
      admin_raw: raw
    } do
      configure(connect_secret: nil)

      {:ok, _view, html} = live(as(conn, raw), path)

      assert html =~ ~s(data-test-id="connectors-readonly-banner")
      assert html =~ "Connect is not configured on this instance"
      refute html =~ ~s(data-test-id="connector-connect-telegram")
      # The catalog still RENDERS — the operator can still see what exists.
      assert html =~ ~s(data-test-id="connector-card-telegram")
    end

    test "no secret + a forged open_connect event => flash, no dialog, no crash", %{
      conn: conn,
      path: path,
      admin_raw: raw
    } do
      configure(connect_secret: nil)

      {:ok, view, _html} = live(as(conn, raw), path)
      html = render_click(view, "open_connect", %{"provider" => "telegram"})

      refute html =~ ~s(data-test-id="connectors-connect-modal")
      assert Process.alive?(view.pid)
    end

    test "bridge UNREACHABLE => honest error, no token minted, card stays Not connected", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      script(ws, %{validate: {:error, :unreachable}})

      {:ok, view, _html} = live(as(conn, raw), path)
      view |> element(~s([data-test-id="connector-connect-telegram"])) |> render_click()

      html =
        view
        |> form(~s(#connectors-connect-modal form), %{"credential" => "123:abc"})
        |> render_submit()

      assert html =~ "The connectors bridge is not answering"
      assert render(view) =~ "Not connected"
      assert live_tokens(ws, "telegram", @telegram_key) == []
    end

    test "an invalid token => the bridge's OWN reason, verbatim", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      script(ws, %{validate: {:error, {:refused, "Telegram says: Unauthorized (401)"}}})

      {:ok, view, _html} = live(as(conn, raw), path)
      view |> element(~s([data-test-id="connector-connect-telegram"])) |> render_click()

      html =
        view
        |> form(~s(#connectors-connect-modal form), %{"credential" => "nope"})
        |> render_submit()

      assert html =~ "Telegram says: Unauthorized (401)"
      assert Catalog.installs_for_workspace(ws) == []
    end

    test "a stale/unknown event does not crash the LiveView", %{
      conn: conn,
      path: path,
      admin_raw: raw
    } do
      {:ok, view, _html} = live(as(conn, raw), path)
      render_hook(view, "totally-unknown-stale-event", %{})
      assert Process.alive?(view.pid)
    end
  end

  # ── THE GATE DELTA (D49 → W26/D219) ────────────────────────────────────────
  # W24 kept this principal out of the MINT (per-write re-gate); W26 closes the
  # hole one layer earlier: the `:scoped_admin` mount gate authorizes against
  # the TARGET workspace's membership role, so the outsider never mounts at
  # all. The per-write re-gate stays in the LV as belt-and-suspenders.

  describe "the mount gate is the TARGET-workspace admin gate (W26/D219)" do
    test "a flat-global-admin that is only a MEMBER of this workspace is REJECTED AT MOUNT", %{
      conn: conn,
      path: path,
      outsider_raw: raw,
      ws: ws
    } do
      script(ws, %{})

      # The W24 escalation shape: global `admin` permission, member-only role.
      token = Auth.verify_token(raw) |> elem(1)
      assert Auth.has_permission?(token, "admin")
      refute TenancyAuth.workspace_admin?(token, ws.id)

      # Pre-W26 this mounted the catalog. Now the mount itself is refused —
      # there is no view to fire events at.
      assert {:error, {:redirect, %{to: "/studio"}}} = live(as(conn, raw), path)

      assert Stub.calls() == []
      assert live_tokens(ws, "telegram", @telegram_key) == []
      assert Catalog.installs_for_workspace(ws) == []
    end
  end

  # ── THE LOOP ───────────────────────────────────────────────────────────────

  describe "connect" do
    test "validate → confirm → mint → /connect → the card flips to Connected", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      script(ws, %{})

      {:ok, view, _html} = live(as(conn, raw), path)

      # 1. Open — paste step.
      html = view |> element(~s([data-test-id="connector-connect-telegram"])) |> render_click()
      assert html =~ ~s(data-test-id="connectors-credential-input")

      # 2. Validate — the bridge identifies the bot. NOTHING is written yet.
      html =
        view
        |> form(~s(#connectors-connect-modal form), %{"credential" => "123:abc"})
        |> render_submit()

      assert html =~ "Acme Ops Bot"
      assert html =~ @telegram_key
      assert Catalog.installs_for_workspace(ws) == []
      assert live_tokens(ws, "telegram", @telegram_key) == []

      # 3. Confirm — mint, ship, mount.
      html = view |> element(~s([data-test-id="connectors-confirm-connect"])) |> render_click()

      assert html =~ "Telegram connected"
      assert html =~ ~s(data-test-id="connector-install-telegram")
      assert html =~ @telegram_key
      refute html =~ ~s(data-test-id="connectors-connect-modal")

      # The install is REAL — read back out of chat_bridge, joined to this workspace.
      assert [%{provider: "telegram", install_key: @telegram_key}] =
               Catalog.installs_for_workspace(ws)
    end

    test "the minted token is workspace-bound, [\"chat\"]-only, and LABELLED for revoke", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      script(ws, %{})
      {:ok, view, _html} = live(as(conn, raw), path)
      connect!(view)

      assert [%ApiToken{} = token] = live_tokens(ws, "telegram", @telegram_key)

      # The label is the ONLY handle disconnect has on this token.
      assert token.label == "connector:telegram:#{@telegram_key}"
      assert token.permissions == ["chat"]
      assert token.workspace_id == ws.id
      assert is_nil(token.revoked_at)

      # …and the membership it carries is `member`, never `admin` — a `chat` token
      # must not be able to mint more tokens.
      assert TenancyAuth.membership_role(token, ws.id) == "member"
      refute TenancyAuth.workspace_admin?(token, ws.id)
    end

    test "the RAW token crosses the seam exactly once, and never reaches the socket", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      script(ws, %{})
      {:ok, view, _html} = live(as(conn, raw), path)
      connect!(view)

      assert [{:validate, v_ticket, "123:abc"}, {:connect, c_ticket, "123:abc", chat_token}] =
               Stub.calls()

      # The ticket is a REAL signed ticket for THIS workspace + provider.
      assert [body, _sig] = String.split(v_ticket, ".")
      assert {:ok, json} = Base.url_decode64(body, padding: false)
      assert json =~ ~s("w":"#{ws.id}")
      assert json =~ ~s("p":"telegram")

      # Both calls carry a ticket for the SAME workspace + provider.
      assert [c_body, _] = String.split(c_ticket, ".")
      assert {:ok, c_json} = Base.url_decode64(c_body, padding: false)
      assert c_json =~ ~s("w":"#{ws.id}")
      assert c_json =~ ~s("p":"telegram")

      # The raw chat token went over the wire ONCE…
      assert is_binary(chat_token) and byte_size(chat_token) > 20

      # …and it is nowhere in the LiveView's state.
      refute inspect(:sys.get_state(view.pid).socket.assigns) =~ chat_token
      refute render(view) =~ chat_token

      # It authenticates as the workspace-bound chat token we minted.
      assert {:ok, %ApiToken{permissions: ["chat"], workspace_id: ws_id}} =
               Auth.verify_token(chat_token)

      assert ws_id == ws.id
    end

    test "A FAILED /connect REVOKES the just-minted token rather than leaking it", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      script(ws, %{connect: {:error, {:refused, "install_key already claimed"}}})

      {:ok, view, _html} = live(as(conn, raw), path)
      html = connect!(view)

      assert html =~ "install_key already claimed"

      # No install…
      assert Catalog.installs_for_workspace(ws) == []

      # …and the token that WAS minted is dead. A live chat token with no install
      # is a workspace credential nobody owns.
      assert [%ApiToken{} = token] = live_tokens(ws, "telegram", @telegram_key)
      refute is_nil(token.revoked_at)

      raw_chat = Stub.calls() |> List.last() |> elem(3)
      assert {:error, :unauthorized} = Auth.verify_token(raw_chat)

      # And the card never lied.
      assert render(view) =~ "Not connected"
    end

    test "the bridge installing a DIFFERENT key than we labelled is refused + revoked", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      script(ws, %{connect: {:ok, %{install_key: "9999999999", mounted: true}}})

      {:ok, view, _html} = live(as(conn, raw), path)
      html = connect!(view)

      assert html =~ "Nothing was connected"

      assert [%ApiToken{revoked_at: revoked}] = live_tokens(ws, "telegram", @telegram_key)
      refute is_nil(revoked)
    end
  end

  # ── DISCONNECT ─────────────────────────────────────────────────────────────

  describe "disconnect" do
    test "confirm → /disconnect → the labelled token is revoked → card back to Not connected", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      script(ws, %{})
      {:ok, view, _html} = live(as(conn, raw), path)
      connect!(view)

      assert [%ApiToken{revoked_at: nil}] = live_tokens(ws, "telegram", @telegram_key)

      # It CONFIRMS — disconnect is destructive, so it is never one stray click.
      html = view |> element(~s([data-test-id="connector-disconnect-telegram"])) |> render_click()
      assert html =~ ~s(data-test-id="connectors-disconnect-modal")
      assert html =~ "Disconnect Telegram?"

      html = view |> element(~s([data-test-id="connectors-confirm-disconnect"])) |> render_click()

      assert html =~ "Disconnected Telegram"
      assert html =~ "1 token revoked"
      assert html =~ "Not connected"
      assert Catalog.installs_for_workspace(ws) == []

      assert [%ApiToken{revoked_at: revoked}] = live_tokens(ws, "telegram", @telegram_key)
      refute is_nil(revoked)

      assert {:disconnect, _ticket, @telegram_key} = List.last(Stub.calls())
    end

    test "a bridge that REFUSES the disconnect does not revoke the token", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      script(ws, %{})
      {:ok, view, _html} = live(as(conn, raw), path)
      connect!(view)

      Stub.start(%{
        workspace_id: ws.id,
        provider: "telegram",
        validate: {:ok, %{install_key: @telegram_key, display_name: "Acme Ops Bot"}},
        connect: {:ok, %{install_key: @telegram_key, mounted: true}},
        disconnect: {:error, :unreachable}
      })

      view |> element(~s([data-test-id="connector-disconnect-telegram"])) |> render_click()
      html = view |> element(~s([data-test-id="connectors-confirm-disconnect"])) |> render_click()

      assert html =~ "Could not disconnect"

      # The adapter is still mounted with this credential — killing the token here
      # would leave a live bot that 401s on every message.
      assert [%ApiToken{revoked_at: nil}] = live_tokens(ws, "telegram", @telegram_key)
      assert [%{install_key: @telegram_key}] = Catalog.installs_for_workspace(ws)
    end

    test "TWO installs of one provider both render and each is INDEPENDENTLY disconnectable (D161)",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      script(ws, %{})

      # The bridge is the only writer; a workspace with two Telegram bots lands as
      # two rows. Inserted …002 before …001 to prove render order is install_key,
      # not insertion order.
      key_a = "8100000001"
      key_b = "8100000002"

      for key <- [key_b, key_a] do
        Repo.query!(
          """
          INSERT INTO chat_bridge.connector_installs
            (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
          VALUES ('telegram', $1, $2, 'SEALED-CREDENTIAL-BLOB', 'SEALED-CHAT-TOKEN-BLOB', now())
          """,
          [key, ws.id]
        )
      end

      {:ok, view, html} = live(as(conn, raw), path)

      # BOTH installs render — the pre-D161 collapse showed only the first, so the
      # second was invisible AND (its bare-provider handler already taken) unremovable.
      assert html =~ key_a
      assert html =~ key_b

      # Two disconnect buttons on the one card, each keyed by its install_key.
      disconnect = fn key ->
        ~s([data-test-id="connector-disconnect-telegram"][phx-value-install_key="#{key}"])
      end

      # Disconnect the SECOND install specifically — the one the old bare-provider
      # lookup could never reach.
      html = view |> element(disconnect.(key_b)) |> render_click()
      assert html =~ ~s(data-test-id="connectors-disconnect-modal")
      # The modal names the SPECIFIC install, not the first one.
      assert html =~ key_b

      html = view |> element(~s([data-test-id="connectors-confirm-disconnect"])) |> render_click()
      assert html =~ "Disconnected Telegram"

      # The bridge was asked to unmount the SECOND install by ITS OWN key.
      assert {:disconnect, _ticket, ^key_b} = List.last(Stub.calls())

      # …and the FIRST install survives — still rendered, still its own row.
      assert render(view) =~ key_a
      assert [%{install_key: ^key_a}] = Catalog.installs_for_workspace(ws)
    end
  end

  # ── ADD TO SLACK (OAuth) ───────────────────────────────────────────────────

  defp script_slack(ws, overrides \\ %{}) do
    Stub.start(
      Map.merge(
        %{
          workspace_id: ws.id,
          provider: "slack",
          stage_pending: {:ok, %{}},
          validate: {:ok, %{install_key: "T_X", display_name: "X"}},
          connect: {:ok, %{install_key: "T_X", mounted: true}},
          disconnect: {:ok, %{removed: true}}
        },
        overrides
      )
    )

    configure(
      bridge: Stub,
      connect_secret: @secret,
      slack_client_id: "123.456",
      slack_redirect_uri: "https://guerrilla.barkpark.cloud/connectors/oauth/slack/callback"
    )
  end

  describe "add to slack (oauth)" do
    test "the Slack card renders an external Add-to-Slack link carrying a signed ticket, and stages the chat token over loopback (D62/D63)",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      script_slack(ws)

      {:ok, view, html} = live(as(conn, raw), path)

      # No paste Connect button, no gate — a real external link instead.
      refute html =~ ~s(data-test-id="connector-connect-slack")
      refute html =~ ~s(data-test-id="connector-oauth-gate-slack")
      assert html =~ ~s(data-test-id="connector-add-to-slack-slack")
      assert html =~ ~s(href=")
      assert html =~ "slack.com/oauth/v2/authorize"

      # The href IS a Slack authorize URL carrying a valid signed connect ticket.
      url = :sys.get_state(view.pid).socket.assigns.oauth["slack"].add_url
      assert is_binary(url)
      uri = URI.parse(url)
      assert uri.host == "slack.com"
      assert uri.path == "/oauth/v2/authorize"
      q = URI.decode_query(uri.query)
      assert q["client_id"] == "123.456"
      assert q["scope"] =~ "chat:write"

      state = q["state"]
      # The state is a connect ticket for THIS workspace + slack, with a nonce.
      [body, sig] = String.split(state, ".")

      assert sig ==
               :crypto.mac(:hmac, :sha256, @secret, body) |> Base.url_encode64(padding: false)

      {:ok, json} = Base.url_decode64(body, padding: false)
      %{"w" => w, "p" => p, "n" => n} = Jason.decode!(json)
      assert w == ws.id
      assert p == "slack"
      assert n != ""

      # Studio staged the chat token over LOOPBACK under that SAME ticket, ahead of
      # the redirect (D63) — the raw token rode the stage, NEVER the URL.
      assert [{:stage_pending, ^state, chat_token}] = Stub.calls()
      assert is_binary(chat_token) and byte_size(chat_token) > 20
      refute url =~ chat_token

      # …and the staged token is a real workspace-bound `chat` token.
      assert {:ok, %ApiToken{permissions: ["chat"], workspace_id: ws_id}} =
               Auth.verify_token(chat_token)

      assert ws_id == ws.id

      # It is labelled for the OAuth flow (the callback learns install_key only
      # after the redirect, so it cannot be labelled by install_key yet).
      assert [%ApiToken{label: "connector:slack:oauth"}] =
               live_tokens(ws, "slack", "oauth")
    end

    test "a non-admin never mounts the catalog — NOTHING is minted or staged (D49 → W26)",
         %{conn: conn, path: path, outsider_raw: raw, ws: ws} do
      script_slack(ws)

      # W26: the target-workspace mount gate refuses the member-only principal
      # before the OAuth machinery (token mint + stage) can even run.
      assert {:error, {:redirect, %{to: "/studio"}}} = live(as(conn, raw), path)

      assert Stub.calls() == []
      assert live_tokens(ws, "slack", "oauth") == []
    end

    test "with no Slack app configured, the card shows the honest note — never a broken button",
         %{conn: conn, path: path, admin_raw: raw} do
      # setup's `configure` has a connect secret but no slack client id.
      {:ok, _view, html} = live(as(conn, raw), path)

      assert html =~ ~s(data-test-id="connector-oauth-gate-slack")
      assert html =~ "Add to Slack is not configured on this instance"
      refute html =~ ~s(data-test-id="connector-add-to-slack-slack")
    end

    test "a fresh page visit revokes the prior unclicked OAuth token before minting a new one",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      script_slack(ws)

      {:ok, view1, _html} = live(as(conn, raw), path)
      first = :sys.get_state(view1.pid).socket.assigns.oauth["slack"].add_url
      assert [%ApiToken{revoked_at: nil} = t1] = live_tokens(ws, "slack", "oauth")

      # A second visit mints a fresh token and revokes the stale one — at most one
      # unattached credential at a time.
      {:ok, view2, _html} = live(as(conn, raw), path)
      second = :sys.get_state(view2.pid).socket.assigns.oauth["slack"].add_url
      refute second == first

      tokens = live_tokens(ws, "slack", "oauth")
      # The first is now revoked; exactly one live token remains.
      assert Enum.any?(tokens, fn t -> t.id == t1.id and not is_nil(t.revoked_at) end)
      assert Enum.count(tokens, &is_nil(&1.revoked_at)) == 1
    end
  end

  # ── TOOL CONNECTORS (the OUTBOUND direction — D97–D105) ────────────────────

  defp script_github(ws, overrides \\ %{}) do
    Stub.start(
      Map.merge(
        %{
          workspace_id: ws.id,
          provider: "github",
          validate: {:ok, %{install_key: "octo-org", display_name: "octo-org"}},
          # A tool install mounts nothing (mounted: false) — the agent ACTS on it,
          # there is no live adapter to mount.
          connect: {:ok, %{install_key: "octo-org", mounted: false}},
          disconnect: {:ok, %{removed: true}}
        },
        overrides
      )
    )

    configure(bridge: Stub, connect_secret: @secret)
  end

  defp connect_github!(view) do
    view |> element(~s([data-test-id="connector-connect-github"])) |> render_click()

    view
    |> form(~s(#connectors-connect-modal form), %{"credential" => "github_pat_abc"})
    |> render_submit()

    view |> element(~s([data-test-id="connectors-confirm-connect"])) |> render_click()
  end

  describe "tool connectors" do
    test "the Tools section renders github + linear cards, distinct from the Channels section", %{
      conn: conn,
      path: path,
      admin_raw: raw
    } do
      {:ok, _view, html} = live(as(conn, raw), path)

      # Both sections exist, and the tool cards are their own thing.
      assert html =~ ~s(data-test-id="connectors-section-channels")
      assert html =~ ~s(data-test-id="connectors-section-tools")

      for %{id: id, name: name} <- Catalog.tool_providers() do
        assert html =~ ~s(data-test-id="connector-card-#{id}")
        assert html =~ name
      end

      # github is a PASTE tool — it gets a Connect button (reuses the connect loop).
      assert html =~ ~s(data-test-id="connector-connect-github")
      # linear is an OAUTH tool — no paste Connect button, exactly like Slack.
      refute html =~ ~s(data-test-id="connector-connect-linear")
    end

    test "with zero installs every tool card is Not connected — nothing is seeded", %{
      conn: conn,
      path: path,
      admin_raw: raw
    } do
      {:ok, view, _html} = live(as(conn, raw), path)
      html = render(view)

      for %{id: id} <- Catalog.tool_providers() do
        refute html =~ ~s(data-test-id="connector-install-#{id}")
        refute html =~ ~s(data-test-id="connector-disconnect-#{id}")
      end
    end

    test "github paste connect passes a NIL chat token, mints NOTHING, install lands chat_token_ref NULL",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      script_github(ws)

      {:ok, view, _html} = live(as(conn, raw), path)
      html = connect_github!(view)

      assert html =~ "GitHub connected"
      assert html =~ ~s(data-test-id="connector-install-github")

      # The bridge got a NIL chat token — a tool connect mints nothing (D101).
      assert [{:validate, _, "github_pat_abc"}, {:connect, _, "github_pat_abc", nil}] =
               Stub.calls()

      # No workspace chat token was minted for this install.
      assert live_tokens(ws, "github", "octo-org") == []

      # The install is real — read back out of chat_bridge, joined to this workspace.
      assert [%{provider: "github", install_key: "octo-org"}] =
               Catalog.installs_for_workspace(ws)

      # …and its chat_token_ref is NULL (a tool seals only the PAT).
      %{rows: [[ref]]} =
        Repo.query!(
          "SELECT chat_token_ref FROM chat_bridge.connector_installs " <>
            "WHERE provider = 'github' AND install_key = 'octo-org'"
        )

      assert is_nil(ref)
    end

    test "the Linear card shows the honest not-configured gate by default (no env plumbing)", %{
      conn: conn,
      path: path,
      admin_raw: raw
    } do
      # setup's `configure` has a connect secret but no linear client id.
      {:ok, _view, html} = live(as(conn, raw), path)

      assert html =~ ~s(data-test-id="connector-oauth-gate-linear")
      assert html =~ "Connect Linear is not configured on this instance"
      refute html =~ ~s(data-test-id="connector-add-to-slack-linear")
    end

    test "with a Linear OAuth app configured, the card renders an authorize link carrying response_type=code + a linear-bound signed state, NEVER Slack's URL, and stages/mints NOTHING",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      # A stub bridge so we can assert NOTHING crossed the wire, plus injected
      # Linear OAuth config (no Slack client id — Slack stays the honest gate).
      Stub.start(%{workspace_id: ws.id, provider: "linear"})

      configure(
        bridge: Stub,
        connect_secret: @secret,
        linear_client_id: "lin_123",
        linear_redirect_uri: "https://guerrilla.barkpark.cloud/connectors/oauth/linear/callback"
      )

      {:ok, view, html} = live(as(conn, raw), path)

      assert html =~ ~s(data-test-id="connector-add-to-slack-linear")
      refute html =~ ~s(data-test-id="connector-oauth-gate-linear")

      url = :sys.get_state(view.pid).socket.assigns.oauth["linear"].add_url
      uri = URI.parse(url)

      # The Linear authorize host — NEVER Slack's.
      assert uri.host == "linear.app"
      assert uri.path == "/oauth/authorize"
      refute url =~ "slack.com"

      q = URI.decode_query(uri.query)
      assert q["client_id"] == "lin_123"
      # THE load-bearing delta: Linear requires response_type=code (Slack omits it).
      assert q["response_type"] == "code"
      assert q["scope"] == "read"

      assert q["redirect_uri"] ==
               "https://guerrilla.barkpark.cloud/connectors/oauth/linear/callback"

      # The state is a connect ticket bound to THIS workspace + "linear".
      state = q["state"]
      [body, sig] = String.split(state, ".")

      assert sig ==
               :crypto.mac(:hmac, :sha256, @secret, body) |> Base.url_encode64(padding: false)

      {:ok, json} = Base.url_decode64(body, padding: false)
      %{"w" => w, "p" => p, "n" => n} = Jason.decode!(json)
      assert w == ws.id
      assert p == "linear"
      assert n != ""

      # D78 — the write IS the connect: NOTHING was staged or minted ahead of the
      # redirect. No stage_pending call, no chat token.
      assert Stub.calls() == []
      assert live_tokens(ws, "linear", "oauth") == []
    end

    test "a tool install owned by ANOTHER workspace never appears on this workspace's list (fail-closed)",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      {:ok, other} = Tenancy.create_workspace(%{slug: "conn-other", name: "Other"})

      Repo.query!(
        """
        INSERT INTO chat_bridge.connector_installs
          (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
        VALUES ('github', 'foreign-key', $1, 'SEALED-CREDENTIAL-BLOB', NULL, now())
        """,
        [other.id]
      )

      {:ok, _view, html} = live(as(conn, raw), path)

      refute html =~ "foreign-key"
      refute html =~ ~s(data-test-id="connector-install-github")
      assert Catalog.installs_for_workspace(ws) == []
    end

    test "disconnecting a tool deletes the install, flashes '0 tokens revoked', and does not crash",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      script_github(ws)

      {:ok, view, _html} = live(as(conn, raw), path)
      connect_github!(view)

      assert [%{provider: "github", install_key: "octo-org"}] =
               Catalog.installs_for_workspace(ws)

      # There was never a token to revoke — a tool connect mints nothing.
      view |> element(~s([data-test-id="connector-disconnect-github"])) |> render_click()
      html = view |> element(~s([data-test-id="connectors-confirm-disconnect"])) |> render_click()

      assert html =~ "Disconnected GitHub"
      assert html =~ "0 tokens revoked"
      assert html =~ "Not connected"
      assert Catalog.installs_for_workspace(ws) == []
      assert Process.alive?(view.pid)

      assert {:disconnect, _ticket, "octo-org"} = List.last(Stub.calls())
    end
  end

  # ── THE WEBHOOK / INTERACTIONS URL DISPLAY (D260) ──────────────────────────
  #
  # Studio mirrors the ops runbooks: it DISPLAYS the copyable per-install
  # webhook/interactions URL an operator pastes into a vendor portal. Phoenix
  # mounts no route (the Node bridge serves it behind Caddy) — this is a display
  # string, built from the PUBLIC base + path prefix, keyed by the bridge's own
  # `keySource` grammar. The public base has NO default: unconfigured ⇒ an honest
  # "endpoint unavailable" state, never a localhost paste error.

  defp seed_install(ws, provider, key) do
    Repo.query!(
      """
      INSERT INTO chat_bridge.connector_installs
        (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
      VALUES ($1, $2, $3, 'SEALED-CREDENTIAL-BLOB', 'SEALED-CHAT-TOKEN-BLOB', now())
      """,
      [provider, key, ws.id]
    )
  end

  # The base is set here, per-test (never in config/test.exs), so the nil branch
  # stays the zero-setup default and this env never leaks into another test.
  defp put_public_base(base) do
    Application.put_env(:barkpark, :capabilities_base_url, base)
    on_exit(fn -> Application.delete_env(:barkpark, :capabilities_base_url) end)
  end

  describe "the webhook / interactions URL display (D260)" do
    test "a PATH-keyed provider (discord) shows a per-install URL carrying the install_key, copyable, labelled 'Interactions Endpoint URL' + the deploy-before-save runbook",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      put_public_base("https://studio.test")
      app_id = "111111111111111111"
      seed_install(ws, "discord", app_id)

      {:ok, _view, html} = live(as(conn, raw), path)

      # The URL is per-install: the install_key IS a path segment (keySource "path").
      assert html =~ ~s(data-test-id="connector-webhook-discord")
      assert html =~ ~s(data-test-id="connector-webhook-url-discord")
      assert html =~ "https://studio.test/connectors/webhooks/discord/#{app_id}"

      # Discord's portal field is literally "Interactions Endpoint URL".
      assert html =~ "Interactions Endpoint URL"

      # The deploy-before-save PING runbook is linked (silent-removal failure mode).
      assert html =~ "connectors/docs/discord-byo-bot.md"
      assert html =~ "PING-validate"

      # A copy action wired to the CSP-allowlisted handler + data-url.
      assert html =~ ~s(data-test-id="connector-webhook-copy-discord")
      assert html =~ ~s(data-url="https://studio.test/connectors/webhooks/discord/#{app_id}")
      # The CSP-allowlisted copy handler is wired (its `'`-bearing body is
      # HTML-escaped in the attribute, so assert an unescaped, load-bearing
      # fragment — `data-url` above is the URL half of the same handler).
      assert html =~ "navigator.clipboard.writeText"
    end

    test "a PAYLOAD-keyed provider (slack) shows the APP-WIDE URL with NO install_key segment, linked to the Event Subscriptions step",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      put_public_base("https://studio.test")
      # A payload-keyed provider's URL is app-wide; the team is dug from the body.
      seed_install(ws, "slack", "T_TEAM")

      {:ok, _view, html} = live(as(conn, raw), path)

      assert html =~ ~s(data-test-id="connector-webhook-slack")
      assert html =~ "https://studio.test/connectors/webhooks/slack"

      # The install_key is NEVER a path segment for a payload-keyed provider.
      refute html =~ "webhooks/slack/T_TEAM"

      # Links the Event Subscriptions step (NOT the OAuth redirect step).
      assert html =~ "Event Subscriptions"
      assert html =~ "docs/ops/slack-app.md"
    end

    test "the base URL is trimmed of a trailing slash — the join never doubles it", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      put_public_base("https://studio.test/")
      seed_install(ws, "whatsapp", "1555000111")

      {:ok, _view, html} = live(as(conn, raw), path)

      assert html =~ "https://studio.test/connectors/webhooks/whatsapp/1555000111"
      refute html =~ "studio.test//connectors"
    end

    test "with NO public base configured the row is honest — 'endpoint unavailable', no URL, no copy button",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      # Deliberately do NOT set :capabilities_base_url — the nil default.
      Application.delete_env(:barkpark, :capabilities_base_url)
      seed_install(ws, "discord", "111111111111111111")

      {:ok, _view, html} = live(as(conn, raw), path)

      # The webhook block still renders (the provider HAS an endpoint)…
      assert html =~ ~s(data-test-id="connector-webhook-discord")
      # …but honestly, with no URL and no copy action — never a localhost guess.
      assert html =~ ~s(data-test-id="connector-webhook-unavailable-discord")
      assert html =~ "Endpoint unavailable"
      refute html =~ ~s(data-test-id="connector-webhook-url-discord")
      refute html =~ ~s(data-test-id="connector-webhook-copy-discord")
      refute html =~ "localhost"
      refute html =~ "127.0.0.1"
    end

    test "a LISTEN-ONLY connector (telegram polling) renders NO webhook endpoint at all", %{
      conn: conn,
      path: path,
      admin_raw: raw,
      ws: ws
    } do
      put_public_base("https://studio.test")
      seed_install(ws, "telegram", @telegram_key)

      {:ok, _view, html} = live(as(conn, raw), path)

      # The install renders, but telegram has no inbound HTTP webhook — no row.
      assert html =~ ~s(data-test-id="connector-install-telegram")
      refute html =~ ~s(data-test-id="connector-webhook-telegram")
      refute html =~ "webhooks/telegram"
    end
  end

  # ── The ticket the LiveView actually signs ─────────────────────────────────

  test "the LiveView signs the SAME ticket shape the golden vector pins", %{
    conn: conn,
    path: path,
    admin_raw: raw,
    ws: ws
  } do
    script(ws, %{})
    {:ok, view, _html} = live(as(conn, raw), path)
    connect!(view)

    [{:validate, ticket, _}, _] = Stub.calls()
    [body, sig] = String.split(ticket, ".")

    assert sig == :crypto.mac(:hmac, :sha256, @secret, body) |> Base.url_encode64(padding: false)

    {:ok, json} = Base.url_decode64(body, padding: false)
    %{"w" => w, "p" => p, "n" => n, "t" => t} = Jason.decode!(json)

    assert w == ws.id
    assert p == "telegram"
    assert String.length(n) == 16
    assert is_integer(t)

    # And ConnectTicket, replayed with the same nonce/clock, reproduces it exactly.
    assert {:ok, ^ticket} =
             ConnectTicket.sign(ws.id, "telegram", secret: @secret, nonce: n, issued_at_ms: t)
  end

  # ── OAUTH LIVE REFRESH (poll) + SLACK TOKEN RELABEL (D179) ─────────────────
  #
  # The OAuth return is a redirect in a DIFFERENT tab: the callback lands the
  # install, but the Studio card that launched the flow never re-reads. These two
  # legs close that: a bounded server poll flips the card to Connected with no
  # navigation, and once the install lands the Slack `:oauth` token is relabelled
  # to its canonical install_key label (closing the D48 dual-label limitation).
  describe "oauth live refresh (poll)" do
    test "a poll tick flips the card to Connected when the callback lands the install in another tab (no re-navigation)",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      script_slack(ws)

      {:ok, view, html} = live(as(conn, raw), path)

      # Mid-flight: the Add-to-Slack link is showing, no install yet, Not connected.
      assert html =~ ~s(data-test-id="connector-add-to-slack-slack")
      refute html =~ ~s(data-test-id="connector-disconnect-slack")

      # The OAuth callback lands the install in ANOTHER tab / process.
      Repo.query!(
        """
        INSERT INTO chat_bridge.connector_installs
          (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
        VALUES ('slack', 'T_TEAM', $1, 'SEALED-CREDENTIAL-BLOB', 'SEALED-CHAT-TOKEN-BLOB', now())
        """,
        [ws.id]
      )

      # A poll tick re-reads installs — the card flips to Connected with NO
      # navigation, no live_patch, no manual refresh.
      send(view.pid, :oauth_poll_tick)
      html = render(view)

      assert html =~ "Connected"
      assert html =~ ~s(data-test-id="connector-install-slack")
      assert html =~ "T_TEAM"
      assert html =~ ~s(data-test-id="connector-disconnect-slack")
      # …and the Add-to-Slack link is gone — the flow is complete.
      refute html =~ ~s(data-test-id="connector-add-to-slack-slack")
    end

    test "a poll tick is inert when nothing landed — the card stays honestly Not connected",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      script_slack(ws)

      {:ok, view, _html} = live(as(conn, raw), path)

      send(view.pid, :oauth_poll_tick)
      html = render(view)

      refute html =~ ~s(data-test-id="connector-install-slack")
      assert html =~ ~s(data-test-id="connector-add-to-slack-slack")
    end

    test "the poll is workspace-scoped: another workspace's install never surfaces here (D49 tenancy)",
         %{conn: conn, admin_raw: raw, ws: ws} do
      # The admin token is also an admin of a SECOND workspace, mounted separately.
      {:ok, other} = Tenancy.create_workspace(%{slug: "conn-poll-other", name: "Other"})
      {:ok, _proj} = Tenancy.create_project(other, %{slug: "default", name: "Default"})

      {:ok, admin} = Auth.verify_token(raw)
      {:ok, _} = TenancyAuth.create_membership(other.id, admin.id, "admin")

      script_slack(other)

      other_path = "/w/#{other.slug}/p/default/studio/connectors"
      {:ok, view, _html} = live(as(conn, raw), other_path)

      # An install lands for the FIRST workspace (ws), not for `other`.
      Repo.query!(
        """
        INSERT INTO chat_bridge.connector_installs
          (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
        VALUES ('slack', 'T_ELSEWHERE', $1, 'SEALED-CREDENTIAL-BLOB', 'SEALED-CHAT-TOKEN-BLOB', now())
        """,
        [ws.id]
      )

      # A poll tick on `other`'s view must never reflect ws's install.
      send(view.pid, :oauth_poll_tick)
      html = render(view)

      refute html =~ "T_ELSEWHERE"
      refute html =~ ~s(data-test-id="connector-install-slack")
      assert html =~ ~s(data-test-id="connector-add-to-slack-slack")
    end
  end

  describe "slack oauth token relabel (D179, closes the D48 limitation)" do
    test "reload relabels a live connector:slack:oauth token to its install_key label once the install lands",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      script_slack(ws)

      # The callback landed a Slack install…
      Repo.query!(
        """
        INSERT INTO chat_bridge.connector_installs
          (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
        VALUES ('slack', 'T_TEAM', $1, 'SEALED-CREDENTIAL-BLOB', 'SEALED-CHAT-TOKEN-BLOB', now())
        """,
        [ws.id]
      )

      # …and a live oauth-labelled token still exists (minted before the callback
      # knew the team_id, D62/D63).
      {:ok, _raw, oauth_token} =
        Auth.create_chat_token(Catalog.token_label("slack", "oauth"), "production", ws.id)

      assert oauth_token.label == "connector:slack:oauth"

      # Mount → handle_params → reload → reconcile relabels the oauth token.
      {:ok, _view, _html} = live(as(conn, raw), path)

      relabelled = Repo.get(ApiToken, oauth_token.id)
      assert relabelled.label == Catalog.token_label("slack", "T_TEAM")
      # Relabel, NOT revoke — the credential the install is using stays live.
      assert is_nil(relabelled.revoked_at)
      # No oauth-labelled token remains; disconnect now rides the install_key path.
      assert live_tokens(ws, "slack", "oauth") == []
    end

    test "reconcile is a no-op when no slack install exists — the pre-callback oauth label is preserved",
         %{conn: conn, path: path, admin_raw: raw, ws: ws} do
      script_slack(ws)

      # An oauth token exists but NO install has landed yet — the pre-callback
      # window. The token must keep its oauth label (nothing to reconcile to).
      {:ok, _raw, oauth_token} =
        Auth.create_chat_token(Catalog.token_label("slack", "oauth"), "production", ws.id)

      {:ok, _view, _html} = live(as(conn, raw), path)

      assert Repo.get(ApiToken, oauth_token.id).label == "connector:slack:oauth"
    end
  end
end
