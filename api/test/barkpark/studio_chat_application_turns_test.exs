defmodule Barkpark.StudioChatApplicationTurnsTest do
  use Barkpark.DataCase, async: false
  import Barkpark.TenancyFixtures
  alias Barkpark.{Accounts, ChatHosts, Repo, StudioChat}
  alias Barkpark.StudioChat.ApplicationTurns

  setup do
    ws = create_workspace!()

    {:ok, user} =
      Accounts.register_user(%{
        email: "application-#{System.unique_integer([:positive])}@example.com",
        password: "application test password"
      })

    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {_, login} = Accounts.verify_user_session(raw)

    {:ok, enrollment} =
      ChatHosts.issue_enrollment(ws.id, %{name: "application executor", approved_roots: []})

    {:ok, enrolled} = ChatHosts.enroll(enrollment.enrollment_token)
    {:ok, host} = ChatHosts.authenticate(enrolled.credential)
    previous = Application.get_env(:barkpark, :personal_chat_applications)

    Application.put_env(:barkpark, :personal_chat_applications, %{
      "test-app" => %{
        workspace_id: ws.id,
        host_id: host.id,
        version: "1",
        contract_version: "test-context/1"
      }
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :personal_chat_applications, previous),
        else: Application.delete_env(:barkpark, :personal_chat_applications)
    end)

    %{ws: ws, user: user, login: login, raw: raw, host: host, scope: {:personal, ws.id, user.id}}
  end

  defp result(turn, audience \\ "first-year students") do
    %{
      "epoch" => turn.epoch,
      "expected_revision" => turn.base_revision,
      "request_digest" => turn.request_digest,
      "result" => %{
        "contract_version" => "test-context/1",
        "context" => %{"audience" => audience, "language" => "nb"},
        "selection" => [
          %{"title_id" => "fictional", "product_id" => "fictional-print", "revision" => "r1"}
        ],
        "source_identities" => [%{"id" => "fictional-source", "revision" => "source-r1"}],
        "answer" => %{
          "id" => "fictional-answer",
          "text" => "Fictional test answer",
          "presentation" => %{
            "statements" => [
              %{"kind" => "limitation", "text" => "Fictional test answer", "evidence_ids" => []}
            ],
            "citations" => []
          }
        }
      }
    }
  end

  test "two durable committed turns retain context and revision with exact source identities",
       ctx do
    assert {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    assert {:ok, first} =
             ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
               "query" => "For first-year students, in Norwegian",
               "request_id" => "first",
               "expected_revision" => 0
             })

    assert {:ok, work} = ApplicationTurns.fetch(ctx.host, first.id)
    assert work.context == %{}
    assert work.actor_user_id == ctx.user.id
    assert {:ok, committed} = ApplicationTurns.commit(ctx.host, first.id, result(first))
    assert committed.revision == 1

    assert {:ok, second} =
             ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
               "query" => "Actually, experienced practitioners",
               "request_id" => "second",
               "expected_revision" => 1
             })

    assert {:ok, work} = ApplicationTurns.fetch(ctx.host, second.id)
    assert work.context == %{"audience" => "first-year students", "language" => "nb"}
    assert work.source_identities == [%{"id" => "fictional-source", "revision" => "source-r1"}]

    assert {:ok, final} =
             ApplicationTurns.commit(
               ctx.host,
               second.id,
               result(second, "experienced practitioners")
             )

    assert final.revision == 2
    assert {:ok, view} = ApplicationTurns.read(ctx.scope, ctx.login.id, session.id)
    assert view.context["language"] == "nb"
    assert view.context["audience"] == "experienced practitioners"
    assert view.last_answer.turn_id == second.id
    assert view.last_answer.revision == 2
    assert view.last_answer.answer == result(second)["result"]["answer"]

    assert Enum.map(StudioChat.list_messages(session.id, ctx.scope), & &1.role) == [
             "user",
             "assistant",
             "user",
             "assistant"
           ]

    assert {:error, :personal_chat_runtime_unavailable} = StudioChat.runtime_access(session.id)
  end

  test "same request and result replay exactly, conflicting payload or stale context cannot overwrite",
       ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})
    request = %{"query" => "Original question", "request_id" => "same", "expected_revision" => 0}
    {:ok, turn} = ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, request)
    assert {:ok, ^turn} = ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, request)

    assert {:error, :conflict} =
             ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
               request
               | "query" => "Altered"
             })

    payload = result(turn)
    assert {:ok, committed} = ApplicationTurns.commit(ctx.host, turn.id, payload)
    assert {:ok, ^committed} = ApplicationTurns.commit(ctx.host, turn.id, payload)

    assert {:error, :conflict} =
             ApplicationTurns.commit(ctx.host, turn.id, result(turn, "Changed replay"))

    assert {:error, :conflict} =
             ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
               request
               | "request_id" => "new"
             })

    assert length(StudioChat.list_messages(session.id, ctx.scope)) == 2
  end

  test "pending work survives process-local queue loss and only one turn owns a context revision",
       ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    request = %{
      "query" => "Persist this question",
      "request_id" => "durable",
      "expected_revision" => 0
    }

    {:ok, turn} = ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, request)
    Barkpark.ChatHosts.Transport.revoke(ctx.host.id)
    assert {:ok, work} = ApplicationTurns.fetch(ctx.host, turn.id)
    assert work.query == request["query"]

    assert {:error, :turn_in_progress} =
             ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
               request
               | "request_id" => "other"
             })

    assert {:error, :stale_fence} =
             ChatHosts.accept_event(ctx.host, %{
               lease_id: turn.id,
               epoch: turn.epoch,
               cursor: 1,
               idempotency_key: "forged",
               event: %{kind: "turn_completed"}
             })
  end

  test "Stop fences late commits without altering the committed context", ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    {:ok, turn} =
      ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
        "query" => "Stop this",
        "request_id" => "stop",
        "expected_revision" => 0
      })

    assert {:ok, cancelled} =
             ApplicationTurns.cancel(ctx.scope, ctx.login.id, session.id, turn.id)

    assert cancelled.status == "cancelled"
    assert cancelled.epoch == turn.epoch + 1
    assert {:error, :conflict} = ApplicationTurns.commit(ctx.host, turn.id, result(turn))
    assert {:ok, view} = ApplicationTurns.read(ctx.scope, ctx.login.id, session.id)
    assert view.revision == 0
    assert view.context == %{}
    assert Enum.map(StudioChat.list_messages(session.id, ctx.scope), & &1.role) == ["user"]

    assert {:ok, next} =
             ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
               "query" => "New attempt",
               "request_id" => "next",
               "expected_revision" => 0
             })

    assert {:ok, _} = ApplicationTurns.commit(ctx.host, next.id, result(next))

    assert {:error, :conflict} =
             ApplicationTurns.cancel(ctx.scope, ctx.login.id, session.id, next.id)
  end

  test "expired work cannot be revived by a host heartbeat", ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    {:ok, turn} =
      ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
        "query" => "Expire this",
        "request_id" => "expire",
        "expected_revision" => 0
      })

    lease = Repo.get!(Barkpark.ChatHosts.ExecutionLease, turn.id)

    lease
    |> Ecto.Changeset.change(
      application_turn:
        Map.put(
          lease.application_turn,
          "deadline",
          DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1))
        )
    )
    |> Repo.update!()

    assert {:ok, _} = ChatHosts.heartbeat(ctx.host, %{})
    assert {:error, :turn_unavailable} = ApplicationTurns.fetch(ctx.host, turn.id)
    assert {:error, :turn_unavailable} = ApplicationTurns.commit(ctx.host, turn.id, result(turn))
    assert {:ok, view} = ApplicationTurns.read(ctx.scope, ctx.login.id, session.id)
    assert view.latest_turn.status == "expired"
    assert view.latest_turn.epoch == turn.epoch + 1
    assert view.revision == 0
    assert view.last_answer == nil
    assert {:ok, again} = ApplicationTurns.read(ctx.scope, ctx.login.id, session.id)
    assert again.latest_turn == view.latest_turn
  end

  test "current login revocation refuses machine work without advancing context", ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    {:ok, turn} =
      ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
        "query" => "Revoke this",
        "request_id" => "revoke",
        "expected_revision" => 0
      })

    Accounts.revoke_user_session_token(ctx.raw)
    assert {:error, :session_lost} = ApplicationTurns.fetch(ctx.host, turn.id)
    assert {:error, :session_lost} = ApplicationTurns.commit(ctx.host, turn.id, result(turn))
    assert Repo.get!(Barkpark.StudioChat.Session, session.id).application_state["revision"] == 0
  end

  test "shortened lease expiry and host revocation are terminal on owner reconnect", ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})
    request = %{"query" => "Short lease", "request_id" => "short", "expected_revision" => 0}
    {:ok, turn} = ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, request)

    Repo.get!(Barkpark.ChatHosts.ExecutionLease, turn.id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:error, :turn_unavailable} = ApplicationTurns.fetch(ctx.host, turn.id)
    assert {:ok, view} = ApplicationTurns.read(ctx.scope, ctx.login.id, session.id)
    assert view.latest_turn.status == "expired"
    assert {:ok, same} = ApplicationTurns.cancel(ctx.scope, ctx.login.id, session.id, turn.id)
    assert same == view.latest_turn

    {:ok, next} =
      ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
        request
        | "request_id" => "next"
      })

    {:ok, _} = ChatHosts.revoke(ctx.ws.id, ctx.host.id)
    assert {:error, :forbidden} = ApplicationTurns.commit(ctx.host, next.id, result(next))
    assert {:ok, revoked} = ApplicationTurns.read(ctx.scope, ctx.login.id, session.id)
    assert revoked.latest_turn.status == "revoked"
    assert revoked.revision == 0
  end

  test "account export retains typed application answer and erasure removes accepted work", ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    {:ok, turn} =
      ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
        "query" => "Private question",
        "request_id" => "private",
        "expected_revision" => 0
      })

    {:ok, _} = ApplicationTurns.commit(ctx.host, turn.id, result(turn))
    export = Accounts.Privacy.export_subject(ctx.user)
    [chat] = export.personal_chats
    assert chat.application_state["context"]["audience"] == "first-year students"

    assert Enum.any?(
             chat.messages,
             &(&1.metadata["application"]["answer"] == result(turn)["result"]["answer"])
           )

    assert {:ok, _} = Accounts.Privacy.erase_subject(ctx.user)
    assert Repo.get(Barkpark.StudioChat.Session, session.id) == nil
    assert Repo.get(Barkpark.ChatHosts.ExecutionLease, turn.id) == nil
  end

  test "removed membership, archived session and changed profile cannot be bypassed", ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    {:ok, turn} =
      ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
        "query" => "Bound work",
        "request_id" => "bound",
        "expected_revision" => 0
      })

    membership = Barkpark.Tenancy.Auth.membership(ctx.user.id, ctx.ws.id, :user)
    Repo.delete!(membership)
    assert {:error, :forbidden} = ApplicationTurns.fetch(ctx.host, turn.id)
    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ctx.ws.id, ctx.user.id, "member", "user")
    {:ok, _} = StudioChat.archive_session(session.id, ctx.scope)

    assert {:error, :application_unavailable} =
             ApplicationTurns.commit(ctx.host, turn.id, result(turn))

    {:ok, _} = StudioChat.unarchive_session(session.id, ctx.scope)
    assert {:error, :conflict} = ApplicationTurns.commit(ctx.host, turn.id, result(turn))
    Application.delete_env(:barkpark, :personal_chat_applications)
    assert {:error, :application_unavailable} = ApplicationTurns.fetch(ctx.host, turn.id)
  end

  test "wrong personal scope, foreign host, rotated credential and client state are refused",
       ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    assert {:error, :not_found} =
             ApplicationTurns.read(
               {:personal, ctx.ws.id, Ecto.UUID.generate()},
               ctx.login.id,
               session.id
             )

    assert {:error, :not_found} =
             ApplicationTurns.read(
               {:personal, Ecto.UUID.generate(), ctx.user.id},
               ctx.login.id,
               session.id
             )

    for field <- [
          "context",
          "messages",
          "selection",
          "source_identities",
          "actor_user_id",
          "host_id"
        ] do
      assert {:error, :invalid_request} =
               ApplicationTurns.accept(
                 ctx.scope,
                 ctx.login.id,
                 session.id,
                 Map.put(
                   %{"query" => "Forged", "request_id" => "forge", "expected_revision" => 0},
                   field,
                   %{}
                 )
               )
    end

    {:ok, turn} =
      ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
        "query" => "Bound",
        "request_id" => "host",
        "expected_revision" => 0
      })

    assert {:error, :not_found} =
             ApplicationTurns.fetch(%{ctx.host | id: Ecto.UUID.generate()}, turn.id)

    assert {:ok, _} = ChatHosts.rotate_credential(ctx.host)
    assert {:error, :forbidden} = ApplicationTurns.fetch(ctx.host, turn.id)
  end

  test "two real Postgres connections cannot commit different results for one accepted turn" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      ws = create_workspace!()

      {:ok, user} =
        Accounts.register_user(%{
          email: "application-race-#{System.unique_integer([:positive])}@example.com",
          password: "application race test password"
        })

      try do
        {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
        {:ok, raw} = Accounts.create_user_session_token(user)
        {_, login} = Accounts.verify_user_session(raw)

        {:ok, enrollment} =
          ChatHosts.issue_enrollment(ws.id, %{name: "race executor", approved_roots: []})

        {:ok, enrolled} = ChatHosts.enroll(enrollment.enrollment_token)
        {:ok, host} = ChatHosts.authenticate(enrolled.credential)

        Application.put_env(:barkpark, :personal_chat_applications, %{
          "test-app" => %{
            workspace_id: ws.id,
            host_id: host.id,
            version: "1",
            contract_version: "test-context/1"
          }
        })

        scope = {:personal, ws.id, user.id}
        {:ok, session} = ApplicationTurns.create(scope, login.id, "test-app", %{})

        {:ok, turn} =
          ApplicationTurns.accept(scope, login.id, session.id, %{
            "query" => "Concurrent result",
            "request_id" => "race",
            "expected_revision" => 0
          })

        parent = self()

        tasks =
          for audience <- ["first", "second"] do
            Task.async(fn ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                send(parent, {:ready, self()})

                receive do
                  :go -> ApplicationTurns.commit(host, turn.id, result(turn, audience))
                after
                  5000 -> flunk("race barrier timed out")
                end
              end)
            end)
          end

        try do
          pids =
            for _ <- 1..2 do
              assert_receive {:ready, pid}, 5000
              pid
            end

          Enum.each(pids, &send(&1, :go))
          results = Enum.map(tasks, &Task.await(&1, 10_000))
          assert Enum.count(results, &match?({:ok, _}, &1)) == 1
          assert Enum.count(results, &(&1 == {:error, :conflict})) == 1

          assert Repo.get!(Barkpark.StudioChat.Session, session.id).application_state["revision"] ==
                   1

          assert length(StudioChat.list_messages(session.id, scope)) == 2
        after
          Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
        end
      after
        assert {:ok, _} = Barkpark.Tenancy.delete_workspace(ws)

        assert Repo.aggregate(
                 from(s in Barkpark.StudioChat.Session, where: s.owner_workspace_id == ^ws.id),
                 :count
               ) == 0

        Repo.delete!(user)
      end
    end)
  end
end
