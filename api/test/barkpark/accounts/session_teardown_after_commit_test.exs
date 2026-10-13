defmodule Barkpark.Accounts.SessionTeardownAfterCommitTest do
  @moduledoc """
  Owner ruling #35, item 8: a session revoke made inside a transaction sends
  its socket teardown only after the transaction commits.

  SCIM `deprovision_user/3` revokes every session of the user inside one
  `Repo.transaction`. `revoke_all_user_sessions/1` broadcast the teardown at
  once, before the revoke committed, so a client reconnecting in that window
  re-authenticated on a session row that was still valid.

  The arms:

    * SCIM — while the deprovision transaction is still open (observed from
      a repo-query telemetry handler that runs in the calling process) the
      teardown is not in the subscriber's mailbox; after commit it is.
    * COMMIT / ROLLBACK — under `Accounts.with_session_teardown_after_commit/1`
      the teardown arrives after a committed transaction and never after a
      rolled-back one (whose revoke did not happen).
    * NO TRANSACTION — a revoke outside any transaction still tears down at
      once, wrapper or not.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.{Accounts, Repo, Tenancy}
  alias Barkpark.Accounts.UserSession
  alias BarkparkWeb.UserSocket

  defp user! do
    email = "teardown-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    user
  end

  # A live session for `user`, with the test process subscribed to its
  # teardown topic.
  defp subscribed_session!(user) do
    {:ok, plaintext} = Accounts.create_user_session_token(user)
    id = Repo.get_by!(UserSession, token_hash: UserSession.hash_token(plaintext)).id
    topic = UserSocket.session_disconnect_topic(id)
    Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
    {id, topic}
  end

  defp teardown_in_mailbox?(topic) do
    {:messages, messages} = Process.info(self(), :messages)

    Enum.any?(messages, fn
      %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"} -> true
      _ -> false
    end)
  end

  describe "SCIM deprovision" do
    test "the session teardown is not sent until the deprovision commits" do
      {:ok, org} =
        Tenancy.create_organization(%{
          slug: "td-org-#{System.unique_integer([:positive])}",
          name: "o"
        })

      {:ok, ws} =
        Tenancy.create_workspace(%{
          slug: "td-ws-#{System.unique_integer([:positive])}",
          name: "w"
        })

      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
      user = user!()
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
      {_id, topic} = subscribed_session!(user)

      # The membership delete runs after the session revoke, inside the same
      # transaction. Telemetry handlers run in the process that issued the
      # query, so this reads the test process's own mailbox at that moment.
      me = self()
      handler = "td-probe-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:barkpark, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == me and meta[:source] == "workspace_memberships" and Repo.in_transaction?() do
            send(me, {:probe, teardown_in_mailbox?(topic)})
          end
        end,
        nil
      )

      try do
        assert {:ok, %{sessions_revoked: 1}} = Barkpark.Scim.deprovision_user(org, user)
      after
        :telemetry.detach(handler)
      end

      assert_received {:probe, delivered_inside_transaction?}

      refute delivered_inside_transaction?,
             "the teardown reached the socket while the revoke was still uncommitted"

      assert_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end
  end

  describe "with_session_teardown_after_commit/1" do
    test "a committed revoke tears down after commit, not inside the transaction" do
      user = user!()
      {_id, topic} = subscribed_session!(user)

      result =
        Accounts.with_session_teardown_after_commit(fn ->
          Repo.transaction(fn ->
            {:ok, 1} = Accounts.revoke_all_user_sessions(user)
            teardown_in_mailbox?(topic)
          end)
        end)

      assert {:ok, false} = result
      assert_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "a rolled-back revoke sends no teardown and leaves the session live" do
      user = user!()
      {id, topic} = subscribed_session!(user)

      result =
        Accounts.with_session_teardown_after_commit(fn ->
          Repo.transaction(fn ->
            {:ok, 1} = Accounts.revoke_all_user_sessions(user)
            Repo.rollback(:abandoned)
          end)
        end)

      assert {:error, :abandoned} = result
      refute_received %Phoenix.Socket.Broadcast{topic: ^topic}
      assert is_nil(Repo.get!(UserSession, id).revoked_at)
    end

    test "a raise inside the wrapper drops the queue" do
      user = user!()
      {_id, topic} = subscribed_session!(user)

      assert_raise RuntimeError, fn ->
        Accounts.with_session_teardown_after_commit(fn ->
          Repo.transaction(fn ->
            {:ok, 1} = Accounts.revoke_all_user_sessions(user)
            raise "boom"
          end)
        end)
      end

      refute_received %Phoenix.Socket.Broadcast{topic: ^topic}

      # No deferral state outlives the wrapper: an unwrapped revoke inside a
      # transaction on this process tears down at once, as it always did.
      other = user!()
      {_id, other_topic} = subscribed_session!(other)
      {:ok, {:ok, 1}} = Repo.transaction(fn -> Accounts.revoke_all_user_sessions(other) end)
      assert_received %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}
    end
  end

  describe "outside a transaction" do
    test "the teardown still arrives at once" do
      user = user!()
      {_id, topic} = subscribed_session!(user)

      {:ok, 1} = Accounts.revoke_all_user_sessions(user)
      assert_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "inside the wrapper but outside a transaction, it arrives at once too" do
      user = user!()
      {_id, topic} = subscribed_session!(user)

      Accounts.with_session_teardown_after_commit(fn ->
        {:ok, 1} = Accounts.revoke_all_user_sessions(user)
        assert_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
        {:ok, :done}
      end)
    end
  end
end
