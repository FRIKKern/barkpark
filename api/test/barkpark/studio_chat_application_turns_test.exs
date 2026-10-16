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
    assert view.last_answer.query == "Actually, experienced practitioners"
    assert view.latest_turn.query == view.last_answer.query
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

    {:ok, later} =
      ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
        "query" => "  Later abandoned question\n",
        "request_id" => "abandoned",
        "expected_revision" => 1
      })

    {:ok, _} = ApplicationTurns.cancel(ctx.scope, ctx.login.id, session.id, later.id)
    assert {:ok, restored} = ApplicationTurns.read(ctx.scope, ctx.login.id, session.id)
    assert restored.last_answer.query == "New attempt"
    assert restored.last_answer.turn_id == next.id
    assert restored.last_answer.answer == result(next)["result"]["answer"]
    assert restored.latest_turn.query == "  Later abandoned question\n"
    assert restored.latest_turn.id == later.id
    assert restored.latest_turn.status == "cancelled"
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

  test "typed history pages whole turns without duplicates or internal lease fields", ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    {ids, _revision} =
      Enum.map_reduce(1..7, 0, fn n, revision ->
        {:ok, turn} =
          ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
            "query" => "  question #{n}\n",
            "request_id" => "history-#{n}",
            "expected_revision" => revision
          })

        if rem(n, 3) == 0 do
          {:ok, _} = ApplicationTurns.cancel(ctx.scope, ctx.login.id, session.id, turn.id)
          {turn.id, revision}
        else
          {:ok, receipt} = ApplicationTurns.commit(ctx.host, turn.id, result(turn))
          assert {:ok, ^receipt} = ApplicationTurns.commit(ctx.host, turn.id, result(turn))
          {turn.id, revision + 1}
        end
      end)

    assert {:ok, first} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{"limit" => "2"})

    assert first.revision == 5
    assert Enum.map(first.turns, & &1.turn_id) == Enum.take(ids, -2)
    {turns, pages} = history_pages(ctx, session.id, first, first.turns, 1)
    assert pages == 4
    assert Enum.map(turns, & &1.turn_id) == ids
    assert Enum.map(turns, & &1.query) == Enum.map(1..7, &"  question #{&1}\n")
    assert Enum.count(turns, &is_nil(&1.answer)) == 2

    for turn <- turns do
      assert turn.user_seq > 0

      if turn.answer do
        assert turn.answer.seq > turn.user_seq
        assert turn.committed_revision == turn.base_revision + 1
        assert turn.answer.answer["presentation"]["statements"] != []

        assert turn.answer.source_identities == [
                 %{"id" => "fictional-source", "revision" => "source-r1"}
               ]
      end
    end

    encoded = Jason.encode!(turns)

    for forbidden <- ~w(actor_session_id request_digest host_id credential binding),
        do: refute(String.contains?(encoded, forbidden))
  end

  defp committed_history(ctx, count, payload \\ &result/1) do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    turns =
      for n <- 1..count do
        {:ok, turn} =
          ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
            "query" => "  question #{n}\n",
            "request_id" => "history-#{n}",
            "expected_revision" => n - 1
          })

        {:ok, _} = ApplicationTurns.commit(ctx.host, turn.id, payload.(turn))
        turn
      end

    {session, turns}
  end

  test "history cursor binds owner, session, revision and fixed snapshot without hiding later questions",
       ctx do
    {session, turns} = committed_history(ctx, 3)

    {:ok, first} =
      ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{"limit" => "1"})

    {:ok, pending} =
      ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
        "query" => "New question after snapshot",
        "request_id" => "later",
        "expected_revision" => 3
      })

    {older, _} = history_pages(ctx, session.id, first, first.turns, 1)
    assert Enum.map(older, & &1.turn_id) == Enum.map(turns, & &1.id)
    {:ok, latest} = ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{})
    assert List.last(latest.turns).turn_id == pending.id
    assert List.last(latest.turns).answer == nil
    {:ok, another} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    assert {:error, :invalid_request} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, another.id, %{
               "cursor" => first.next_cursor
             })

    assert {:error, :not_found} =
             ApplicationTurns.history(
               {:personal, ctx.ws.id, Ecto.UUID.generate()},
               ctx.login.id,
               session.id,
               %{"cursor" => first.next_cursor}
             )

    assert {:error, :not_found} =
             ApplicationTurns.history(
               {:personal, Ecto.UUID.generate(), ctx.user.id},
               ctx.login.id,
               session.id,
               %{"cursor" => first.next_cursor}
             )

    {:ok, _} = ApplicationTurns.commit(ctx.host, pending.id, result(pending))

    assert {:error, :conflict} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{
               "cursor" => first.next_cursor
             })
  end

  test "history refuses malformed, tampered and expired cursors and returns explicit empty history",
       ctx do
    {:ok, empty} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    assert {:ok, %{turns: [], has_more: false, next_cursor: nil, snapshot_max_seq: 0}} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, empty.id, %{})

    {session, _} = committed_history(ctx, 2)

    {:ok, first} =
      ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{"limit" => "1"})

    for params <- [
          %{"limit" => "0"},
          %{"limit" => "11"},
          %{"limit" => "01"},
          %{"limit" => 1},
          %{"limit" => String.duplicate("9", 100)},
          %{"since" => "1"},
          %{"cursor" => first.next_cursor, "limit" => "1"},
          %{"cursor" => "invalid"},
          %{"cursor" => String.duplicate("a", 4097)}
        ] do
      assert {:error, :invalid_request} =
               ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, params)
    end

    {:ok, payload} =
      Phoenix.Token.verify(
        BarkparkWeb.Endpoint,
        "personal-application-history-v1",
        first.next_cursor,
        max_age: 3600
      )

    old =
      Phoenix.Token.sign(BarkparkWeb.Endpoint, "personal-application-history-v1", payload,
        signed_at: System.system_time(:second) - 3601
      )

    assert {:error, :invalid_request} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{"cursor" => old})

    changed =
      Phoenix.Token.sign(
        BarkparkWeb.Endpoint,
        "personal-application-history-v1",
        Map.put(payload, "before", 9_007_199_254_740_992)
      )

    assert {:error, :invalid_request} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{"cursor" => changed})
  end

  test "history rechecks current identity and binding but accepts fresh login for old committed turns",
       ctx do
    {session, _} = committed_history(ctx, 2)

    {:ok, first} =
      ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{"limit" => "1"})

    params = %{"cursor" => first.next_cursor}
    Accounts.revoke_user_session_token(ctx.raw)

    assert {:error, :session_lost} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, params)

    {:ok, fresh} = Accounts.create_user_session_token(ctx.user)
    {_, login} = Accounts.verify_user_session(fresh)
    assert {:ok, _} = ApplicationTurns.history(ctx.scope, login.id, session.id, params)
    membership = Barkpark.Tenancy.Auth.membership(ctx.user.id, ctx.ws.id, :user)
    Repo.delete!(membership)

    assert {:error, :forbidden} =
             ApplicationTurns.history(ctx.scope, login.id, session.id, params)

    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ctx.ws.id, ctx.user.id, "member", "user")
    {:ok, _} = StudioChat.archive_session(session.id, ctx.scope)

    assert {:error, :application_unavailable} =
             ApplicationTurns.history(ctx.scope, login.id, session.id, params)

    {:ok, _} = StudioChat.unarchive_session(session.id, ctx.scope)
    assert {:ok, _} = ApplicationTurns.history(ctx.scope, login.id, session.id, params)
    Application.delete_env(:barkpark, :personal_chat_applications)

    assert {:error, :application_unavailable} =
             ApplicationTurns.history(ctx.scope, login.id, session.id, params)
  end

  test "history terminalizes expired accepted work without another accept", ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    {:ok, turn} =
      ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
        "query" => "Expire",
        "request_id" => "expiry",
        "expected_revision" => 0
      })

    Repo.get!(Barkpark.ChatHosts.ExecutionLease, turn.id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:ok, %{revision: 0, turns: [item]}} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{})

    assert item.status == "expired"
    assert item.answer == nil
    assert item.committed_revision == nil
  end

  test "history refuses a malformed pending deadline without a server error", ctx do
    {:ok, session} = ApplicationTurns.create(ctx.scope, ctx.login.id, "test-app", %{})

    {:ok, turn} =
      ApplicationTurns.accept(ctx.scope, ctx.login.id, session.id, %{
        "query" => "Pending",
        "request_id" => "broken",
        "expected_revision" => 0
      })

    lease = Repo.get!(Barkpark.ChatHosts.ExecutionLease, turn.id)

    lease
    |> Ecto.Changeset.change(
      application_turn: Map.put(lease.application_turn, "deadline", "invalid")
    )
    |> Repo.update!()

    assert {:error, :history_invalid} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{})
  end

  test "history refuses damaged user, assistant and lease joins instead of displaying invented typed state",
       ctx do
    mutations = [
      fn _s, _l, q, _a ->
        q |> Ecto.Changeset.change(source_markdown: "Changed question") |> Repo.update!()
      end,
      fn _s, _l, _q, a ->
        a |> Ecto.Changeset.change(source_markdown: "Changed answer") |> Repo.update!()
      end,
      fn _s, _l, _q, a ->
        a
        |> Ecto.Changeset.change(metadata: put_in(a.metadata, ["application", "revision"], 99))
        |> Repo.update!()
      end,
      fn _s, l, _q, _a ->
        l
        |> Ecto.Changeset.change(application_turn: Map.put(l.application_turn, "message_id", 99))
        |> Repo.update!()
      end,
      fn _s, l, _q, _a ->
        l
        |> Ecto.Changeset.change(
          application_turn: Map.put(l.application_turn, "actor_user_id", Ecto.UUID.generate())
        )
        |> Repo.update!()
      end,
      fn _s, l, _q, _a ->
        l
        |> Ecto.Changeset.change(
          application_turn: put_in(l.application_turn, ["binding", "version"], "wrong")
        )
        |> Repo.update!()
      end,
      fn s, _l, q, _a ->
        StudioChat.append_message(s.id, %{
          role: "user",
          source_markdown: q.source_markdown,
          metadata: q.metadata
        })
      end,
      fn s, _l, _q, a ->
        StudioChat.append_message(s.id, %{
          role: "assistant",
          source_markdown: a.source_markdown,
          metadata: a.metadata
        })
      end,
      fn s, _l, _q, _a ->
        StudioChat.append_message(s.id, %{
          role: "assistant",
          source_markdown: "Orphan",
          metadata: %{}
        })
      end
    ]

    for mutate <- mutations do
      {session, [turn]} = committed_history(ctx, 1)
      [question, answer] = StudioChat.list_messages(session.id, ctx.scope)
      lease = Repo.get!(Barkpark.ChatHosts.ExecutionLease, turn.id)
      mutate.(session, lease, question, answer)

      assert {:error, :history_invalid} =
               ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{})
    end
  end

  test "UTF-8 page budget yields fewer whole turns and continuation never drops a large answer",
       ctx do
    payload = fn turn ->
      text = String.duplicate("ø", 25_000)

      result(turn)
      |> put_in(["result", "answer", "text"], text)
      |> put_in(["result", "answer", "presentation", "statements"], [
        %{"kind" => "limitation", "text" => text, "evidence_ids" => []}
      ])
    end

    {session, turns} = committed_history(ctx, 3, payload)

    assert {:ok, first} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{"limit" => "10"})

    assert length(first.turns) == 2
    assert first.has_more
    assert byte_size(Jason.encode!(first)) <= 256_000

    assert {:ok, second} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{
               "cursor" => first.next_cursor
             })

    assert Enum.map(second.turns ++ first.turns, & &1.turn_id) == Enum.map(turns, & &1.id)
    refute second.has_more
    assert byte_size(Jason.encode!(second)) <= 256_000

    [answer | _] =
      Enum.filter(StudioChat.list_messages(session.id, ctx.scope), &(&1.role == "assistant"))

    answer
    |> Ecto.Changeset.change(
      metadata:
        put_in(
          answer.metadata,
          ["application", "answer", "presentation", "oversized"],
          String.duplicate("x", 260_000)
        )
    )
    |> Repo.update!()

    assert {:error, :history_invalid} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, session.id, %{
               "cursor" => first.next_cursor
             })
  end

  defp history_pages(_ctx, _id, %{has_more: false, next_cursor: nil}, turns, count),
    do: {turns, count}

  defp history_pages(ctx, id, page, turns, count) do
    assert {:ok, older} =
             ApplicationTurns.history(ctx.scope, ctx.login.id, id, %{"cursor" => page.next_cursor})

    assert older.revision == page.revision
    assert older.snapshot_max_seq == page.snapshot_max_seq
    history_pages(ctx, id, older, older.turns ++ turns, count + 1)
  end
end
