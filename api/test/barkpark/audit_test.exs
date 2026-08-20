defmodule Barkpark.AuditTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Audit
  alias Barkpark.Audit.{Chain, Event}
  alias Barkpark.{Accounts, Content, Webhooks}
  alias BarkparkWeb.{AuthController, SessionIssuer}

  @strong_password "correct-horse-battery-42"

  @ws Ecto.UUID.generate()
  @ws_b Ecto.UUID.generate()

  defp emit!(attrs) do
    {:ok, ev} = Audit.emit(Map.merge(%{category: "auth", action: "login_succeeded"}, attrs))
    ev
  end

  describe "emit/1 — append + hash chain" do
    test "first row of a workspace chains off genesis; returns the event" do
      ev = emit!(%{workspace_id: @ws, actor_id: "u1"})

      assert ev.id
      assert ev.category == "auth"
      assert is_nil(ev.prev_hash)
      assert ev.hash == Chain.hash(chain_fields(ev), Chain.genesis())
    end

    test "second row chains off the first (prev_hash = first.hash)" do
      a = emit!(%{workspace_id: @ws, action: "login_succeeded", actor_id: "u1"})
      b = emit!(%{workspace_id: @ws, action: "session_revoked", actor_id: "u1"})

      assert b.prev_hash == a.hash
      assert :ok == Audit.verify_chain(@ws)
    end

    test "stamps occurred_at when absent" do
      ev = emit!(%{workspace_id: @ws})
      assert %DateTime{} = ev.occurred_at
    end

    test "rejects an unknown category" do
      assert {:error, %Ecto.Changeset{}} = Audit.emit(%{category: "bogus", action: "x"})
    end
  end

  describe "per-workspace isolation" do
    test "each workspace keeps an independent chain, both verifiable" do
      emit!(%{workspace_id: @ws, action: "login_succeeded", actor_id: "a"})
      emit!(%{workspace_id: @ws_b, action: "login_succeeded", actor_id: "b"})
      emit!(%{workspace_id: @ws, action: "session_revoked", actor_id: "a"})

      # ws_b's single row is genesis-rooted, independent of ws's two rows.
      [b_row] = Audit.list_for_workspace(@ws_b)
      assert is_nil(b_row.prev_hash)

      assert :ok == Audit.verify_chain(@ws)
      assert :ok == Audit.verify_chain(@ws_b)
    end
  end

  describe "append-only enforcement (DB trigger)" do
    test "UPDATE is rejected at the DB layer" do
      ev = emit!(%{workspace_id: @ws})

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("UPDATE audit_events SET action = 'tampered' WHERE id = $1", [ev.id])
      end
    end

    test "DELETE is rejected at the DB layer" do
      ev = emit!(%{workspace_id: @ws})

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM audit_events WHERE id = $1", [ev.id])
      end
    end
  end

  describe "verify_chain — tamper detection (pure)" do
    test "Chain.verify flags a row whose hash was altered" do
      good = %{
        id: 1,
        category: "auth",
        action: "login_succeeded",
        subject: nil,
        actor_type: "user",
        actor_id: "u1",
        workspace_id: @ws,
        project_id: nil,
        metadata: %{},
        occurred_at: DateTime.utc_now(),
        prev_hash: nil,
        hash: nil
      }

      good = %{good | hash: Chain.hash(good, Chain.genesis())}
      assert :ok == Chain.verify([good])

      tampered = %{good | action: "session_revoked"}
      assert {:error, {:broken_at, 1}} = Chain.verify([tampered])
    end
  end

  describe "content mutation emits an audit event (integration)" do
    test "create_document writes a content_mutation row for the doc" do
      dataset = "test"

      {:ok, doc} =
        Content.create_document(
          "author",
          %{"_id" => "audit-author-1", "title" => "Audited"},
          dataset,
          user_id: "editor-42"
        )

      rows = Repo.all(from e in Event, where: e.category == "content_mutation")
      assert row = Enum.find(rows, &(&1.subject == doc.doc_id))
      assert row.action == "document.create"
      assert row.actor_type == "user"
      assert row.actor_id == "editor-42"
      assert row.metadata["type"] == "author"
      assert row.metadata["dataset"] == dataset
    end
  end

  # ── era-w8: the silent auth-event call sites now emit ────────────────────────

  describe "session mint emits an audit event (session_issuer.ex)" do
    test "SessionIssuer.issue writes an auth/session_minted row for the user" do
      user = register!("mint@example.com")

      SessionIssuer.issue(build_conn(), user)

      assert emitted?("auth", "session_minted", user.id)
    end

    test "the mfa_verified flag rides through to metadata" do
      user = register!("mint-mfa@example.com")

      SessionIssuer.issue(build_conn(), user, mfa_verified: true)

      row = one!("auth", "session_minted", user.id)
      assert row.metadata["mfa_verified"] == true
    end
  end

  describe "failed login emits a constant-shape audit event (auth_controller.ex)" do
    test "an unknown email emits auth/login_failed with NO subject (no existence leak)" do
      AuthController.login(build_conn(), %{"email" => "ghost@example.com", "password" => "nope"})

      assert Repo.exists?(
               from e in Event, where: e.category == "auth" and e.action == "login_failed"
             )

      # Constant shape: the event carries no user id / subject, so its presence
      # can never distinguish a real account from an unknown one.
      row = Repo.one!(from e in Event, where: e.action == "login_failed")
      assert is_nil(row.subject)
      assert row.metadata == %{"reason" => "invalid_credentials"}
    end

    test "a KNOWN email with the wrong password emits the SAME shape as an unknown one" do
      register!("real@example.com")

      AuthController.login(build_conn(), %{"email" => "real@example.com", "password" => "wrong"})

      row = Repo.one!(from e in Event, where: e.action == "login_failed")
      # Identical to the unknown-email case: nil subject, same metadata — the
      # audit log itself is not an enumeration oracle.
      assert is_nil(row.subject)
      assert row.metadata == %{"reason" => "invalid_credentials"}
    end

    test "DENY-path: a SUCCESSFUL login emits no login_failed event" do
      register!("good@example.com")

      AuthController.login(build_conn(), %{
        "email" => "good@example.com",
        "password" => @strong_password
      })

      refute Repo.exists?(from e in Event, where: e.action == "login_failed")
    end
  end

  describe "self-service logout emits an audit event (auth_controller.ex)" do
    test "logout writes an auth/logout row attributed to the session's user" do
      user = register!("bye@example.com")
      {:ok, token} = Accounts.create_user_session_token(user)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)

      AuthController.logout(conn, %{})

      assert emitted?("auth", "logout", user.id)
    end

    test "DENY-path: a logout with no bearer/cookie emits nothing" do
      AuthController.logout(build_conn(), %{})

      refute Repo.exists?(from e in Event, where: e.action == "logout")
    end
  end

  describe "password reset emits an audit event (auth_controller.ex)" do
    test "reset with a valid token writes an auth/password_reset row" do
      user = register!("reset-me@example.com")
      {:ok, token} = Accounts.build_email_token(user, "reset")

      AuthController.reset(build_conn(), %{
        "token" => token,
        "password" => "a-brand-new-passphrase-99"
      })

      assert emitted?("auth", "password_reset", user.id)
    end

    test "DENY-path: reset with an invalid token emits nothing" do
      AuthController.reset(build_conn(), %{"token" => "garbage", "password" => "whatever-99-abc"})

      refute Repo.exists?(from e in Event, where: e.action == "password_reset")
    end
  end

  describe "webhook CRUD emits audit events (webhooks.ex)" do
    test "create writes a plugin_settings/webhook_created row for the hook" do
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "Audited hook",
          "url" => "http://example.com/hook",
          "dataset" => "test"
        })

      assert emitted?("plugin_settings", "webhook_created", wh.id)
      row = one!("plugin_settings", "webhook_created", wh.id)
      assert row.metadata["name"] == "Audited hook"
      # Field hygiene: the signing secret is never on the audit trail.
      refute Map.has_key?(row.metadata, "secret")
    end

    test "update writes a plugin_settings/webhook_updated row" do
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "Before",
          "url" => "http://example.com/hook",
          "dataset" => "test"
        })

      {:ok, _} = Webhooks.update_webhook(wh, %{"name" => "After"})

      assert emitted?("plugin_settings", "webhook_updated", wh.id)
    end

    test "delete writes a plugin_settings/webhook_deleted row" do
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "Doomed",
          "url" => "http://example.com/hook",
          "dataset" => "test"
        })

      {:ok, _} = Webhooks.delete_webhook(wh)

      assert emitted?("plugin_settings", "webhook_deleted", wh.id)
    end

    test "DENY-path: a rejected create (missing url) emits no webhook event" do
      {:error, _cs} = Webhooks.create_webhook(%{"name" => "No URL", "dataset" => "test"})

      refute Repo.exists?(
               from e in Event,
                 where: e.category == "plugin_settings" and e.action == "webhook_created"
             )
    end
  end

  # ── helpers for the era-w8 emit tests ────────────────────────────────────────

  defp register!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @strong_password})
    user
  end

  defp build_conn do
    Plug.Test.conn(:post, "/")
    |> Plug.Test.init_test_session(%{})
  end

  defp emitted?(category, action, subject) do
    Repo.exists?(
      from e in Event,
        where: e.category == ^category and e.action == ^action and e.subject == ^subject
    )
  end

  defp one!(category, action, subject) do
    Repo.one!(
      from e in Event,
        where: e.category == ^category and e.action == ^action and e.subject == ^subject
    )
  end

  defp chain_fields(ev) do
    %{
      category: ev.category,
      action: ev.action,
      subject: ev.subject,
      actor_type: ev.actor_type,
      actor_id: ev.actor_id,
      workspace_id: ev.workspace_id,
      project_id: ev.project_id,
      metadata: ev.metadata,
      occurred_at: ev.occurred_at
    }
  end
end
