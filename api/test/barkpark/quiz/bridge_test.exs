defmodule Barkpark.Quiz.BridgeTest do
  @moduledoc """
  P4 hq-p4-bridge: a Studio quiz edit updates the live room. async:false so the
  supervised Bridge process shares the test's sandboxed DB connection.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Quiz}

  setup do
    Content.upsert_schema(
      %{
        "name" => "quiz",
        "title" => "Quiz",
        "visibility" => "public",
        "fields" => Quiz.Content.schema().fields
      },
      "production"
    )

    n = System.unique_integer([:positive])
    pin = "TB#{n}"
    qid = "quiz-#{n}"
    # Joins never start rooms (Decision N) — the host is the sole creator.
    {:ok, _pid} = Quiz.ensure_room(pin)
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin, qid: qid}
  end

  # Create + publish (load_question reads the published perspective, and a
  # publish is what fires the real bridge).
  defp publish_quiz(qid, prompt, choices), do: publish_quiz_in(qid, prompt, choices, "production")

  defp publish_quiz_in(qid, prompt, choices, dataset) do
    {:ok, _} =
      Content.upsert_document(
        "quiz",
        %{"doc_id" => qid, "prompt" => prompt, "choices" => choices},
        dataset
      )

    {:ok, _} = Content.publish_document(qid, "quiz", dataset)
  end

  test "binding a room to a quiz loads its question", %{pin: pin, qid: qid} do
    publish_quiz(qid, "Original?", [%{"id" => "a", "label" => "A", "correct" => true}])
    Quiz.join(pin, "p1", "Alice")
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))

    assert :ok = Quiz.bind_quiz(pin, qid)
    assert_receive {:quiz, ^pin, {:question_updated, %{prompt: "Original?"}}}, 1000
    assert Quiz.state(pin).question.prompt == "Original?"
  end

  test "a quiz edit + publish updates the live room (the live-edit superpower)", %{
    pin: pin,
    qid: qid
  } do
    publish_quiz(qid, "Original?", [%{"id" => "a", "label" => "A"}])
    Quiz.join(pin, "p1", "Alice")
    Quiz.bind_quiz(pin, qid)
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))

    # Edit the quiz, then signal the publish (Content defers its own broadcast
    # inside the sandbox txn, so we drive the documented {:document_changed} term).
    publish_quiz(qid, "EDITED LIVE", [%{"id" => "a", "label" => "A"}])

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      "documents:production",
      {:document_changed, %{type: "quiz", doc_id: qid}}
    )

    assert_receive {:quiz, ^pin, {:question_updated, %{prompt: "EDITED LIVE"}}}, 2000
    assert Quiz.state(pin).question.prompt == "EDITED LIVE"
  end

  test "a REAL publish reaches the Bridge over the Default workspace's keyed topic", %{
    pin: pin,
    qid: qid
  } do
    # task-b7e81f26e959106c: the global `documents:<dataset>` topic no longer
    # announces a workspace-owned document in ANY shape, and a flat quiz write
    # lands in the seeded Default workspace — so the Bridge only hears a quiz
    # publish if it joined `documents:ws:<default>:<dataset>`. No hand-driven
    # `{:document_changed, …}` here: the producer's real frame is the subject.
    publish_quiz(qid, "Original?", [%{"id" => "a", "label" => "A"}])
    Quiz.join(pin, "p1", "Alice")
    Quiz.bind_quiz(pin, qid)
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))

    publish_quiz(qid, "EDITED FOR REAL", [%{"id" => "a", "label" => "A"}])

    assert_receive {:quiz, ^pin, {:question_updated, %{prompt: "EDITED FOR REAL"}}}, 2000
    assert Quiz.state(pin).question.prompt == "EDITED FOR REAL"
  end

  test "the same quiz_id bound in two datasets does not cross-inject content", %{qid: qid} do
    Content.upsert_schema(
      %{
        "name" => "quiz",
        "title" => "Quiz",
        "visibility" => "public",
        "fields" => Quiz.Content.schema().fields
      },
      "staging"
    )

    pin_prod = "TBP#{System.unique_integer([:positive])}"
    pin_stag = "TBS#{System.unique_integer([:positive])}"
    {:ok, _} = Quiz.ensure_room(pin_prod)
    {:ok, _} = Quiz.ensure_room(pin_stag)

    on_exit(fn ->
      Quiz.stop_room(pin_prod)
      Quiz.stop_room(pin_stag)
    end)

    publish_quiz_in(qid, "PROD CONTENT", [%{"id" => "a", "label" => "A"}], "production")
    publish_quiz_in(qid, "STAGING CONTENT", [%{"id" => "a", "label" => "A"}], "staging")

    Quiz.join(pin_prod, "p1", "Alice")
    Quiz.join(pin_stag, "p2", "Bob")
    Quiz.bind_quiz(pin_prod, qid, "production")
    Quiz.bind_quiz(pin_stag, qid, "staging")

    # Subscribe to each room's live topic BEFORE the broadcast so no reload signal
    # is missed. Both rooms already applied their bind-time question, so the mailbox
    # holds no stale {:question_updated} for these topics.
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin_prod))
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin_stag))

    # A publish on production reloads BOTH pins bound to this quiz_id — each must
    # reload from ITS OWN dataset, never inject production's content into staging.
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      "documents:production",
      {:document_changed, %{type: "quiz", doc_id: qid}}
    )

    # Await the reload's OWN signal, not a fixed sleep: the Bridge re-applies each
    # pin's question (Room.apply_question), which re-broadcasts {:question_updated}
    # on that room's topic. Under CI scheduler load the async reload can take >200ms,
    # so a fixed Process.sleep(200) races it → false-red. assert_receive proceeds the
    # instant each reload lands and only fails if it genuinely never does. The staging
    # message carrying "STAGING CONTENT" (never "PROD CONTENT") is the deterministic
    # proof of no cross-injection.
    assert_receive {:quiz, ^pin_prod, {:question_updated, %{prompt: "PROD CONTENT"}}}, 2000
    assert_receive {:quiz, ^pin_stag, {:question_updated, %{prompt: "STAGING CONTENT"}}}, 2000

    assert Quiz.state(pin_prod).question.prompt == "PROD CONTENT"
    assert Quiz.state(pin_stag).question.prompt == "STAGING CONTENT"
  end

  describe "binding lifetime (hq-bridge-binding-gc)" do
    # The Bridge is a singleton GenServer shared by the whole (async: false)
    # run, and the :DOWN it acts on is asynchronous, so these assertions poll
    # its OWN index rather than sleeping a fixed amount.
    defp await_bindings(fun, remaining_ms \\ 2000) do
      bindings = Quiz.Bridge.bindings()

      cond do
        fun.(bindings) ->
          bindings

        remaining_ms <= 0 ->
          flunk("binding index never satisfied: #{inspect(bindings)}")

        true ->
          Process.sleep(20)
          await_bindings(fun, remaining_ms - 20)
      end
    end

    defp pins_for(bindings, qid), do: bindings |> Map.get(qid, %{}) |> Map.keys()

    test "a reaped room's pin is retired from the index", %{pin: pin, qid: qid} do
      publish_quiz(qid, "Original?", [%{"id" => "a", "label" => "A"}])
      assert :ok = Quiz.bind_quiz(pin, qid)
      assert pin in pins_for(await_bindings(&(pin in pins_for(&1, qid))), qid)

      # The room's real death path — the same one the idle timer takes.
      Quiz.stop_room(pin)

      refute pin in pins_for(await_bindings(&(pin not in pins_for(&1, qid))), qid)
    end

    test "the GC retires only the dead pin — a live sibling in another dataset stays bound",
         %{qid: qid} do
      Content.upsert_schema(
        %{
          "name" => "quiz",
          "title" => "Quiz",
          "visibility" => "public",
          "fields" => Quiz.Content.schema().fields
        },
        "staging"
      )

      n = System.unique_integer([:positive])
      dead_pin = "TGD#{n}"
      live_pin = "TGL#{n}"
      {:ok, _} = Quiz.ensure_room(dead_pin)
      {:ok, _} = Quiz.ensure_room(live_pin)
      on_exit(fn -> Quiz.stop_room(live_pin) end)

      publish_quiz_in(qid, "PROD CONTENT", [%{"id" => "a", "label" => "A"}], "production")
      publish_quiz_in(qid, "STAGING CONTENT", [%{"id" => "a", "label" => "A"}], "staging")

      Quiz.bind_quiz(dead_pin, qid, "production")
      Quiz.bind_quiz(live_pin, qid, "staging")
      await_bindings(&(dead_pin in pins_for(&1, qid) and live_pin in pins_for(&1, qid)))

      Quiz.stop_room(dead_pin)

      bindings = await_bindings(&(dead_pin not in pins_for(&1, qid)))
      # The surviving sibling keeps BOTH its entry and its own dataset — a GC
      # that dropped the quiz_id wholesale would fail here.
      assert live_pin in pins_for(bindings, qid)
      assert bindings[qid][live_pin] == "staging"

      # And it is still LIVE-bound, not merely present: a publish still reaches it.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(live_pin))
      publish_quiz_in(qid, "STAGING EDITED", [%{"id" => "a", "label" => "A"}], "staging")

      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        "documents:production",
        {:document_changed, %{type: "quiz", doc_id: qid}}
      )

      assert_receive {:quiz, ^live_pin, {:question_updated, %{prompt: "STAGING EDITED"}}}, 2000
    end

    test "the sweep retires a pin bound while no room was live — the monitor cannot see it",
         %{qid: qid} do
      publish_quiz(qid, "Original?", [%{"id" => "a", "label" => "A"}])

      # Nothing forbids binding ahead of a room, and Barkpark.Quiz.BridgeSandboxCascadeTest
      # does exactly this. There is no process to monitor, so this entry is the
      # one the :DOWN path structurally cannot retire.
      roomless = "TNR#{System.unique_integer([:positive])}"
      refute Quiz.Room.whereis(roomless)
      assert :ok = Quiz.bind_quiz(roomless, qid)
      assert roomless in pins_for(Quiz.Bridge.bindings(), qid)

      # A LIVE sibling in the same index must survive the same sweep.
      live_pin = "TNL#{System.unique_integer([:positive])}"
      {:ok, _} = Quiz.ensure_room(live_pin)
      on_exit(fn -> Quiz.stop_room(live_pin) end)
      Quiz.bind_quiz(live_pin, qid)

      bindings = Quiz.Bridge.sweep()

      refute roomless in pins_for(bindings, qid)
      assert live_pin in pins_for(bindings, qid)
    end

    test "a reaped-then-recreated room rebinds to the CURRENT question, not the default",
         %{pin: pin, qid: qid} do
      publish_quiz(qid, "Original?", [%{"id" => "a", "label" => "A"}])
      Quiz.bind_quiz(pin, qid)
      assert Quiz.state(pin).question.prompt == "Original?"
      await_bindings(&(pin in pins_for(&1, qid)))

      # Reap. The room process holds the last-applied question, so its death
      # loses it — this is the state a returning audience would land in.
      Quiz.stop_room(pin)
      await_bindings(&(pin not in pins_for(&1, qid)))

      # Meanwhile the quiz moved on while no room existed.
      publish_quiz(qid, "EDITED WHILE REAPED", [%{"id" => "a", "label" => "A"}])

      {:ok, _} = Quiz.ensure_room(pin)

      assert Quiz.state(pin).question.prompt == Quiz.Room.default_question().prompt,
             "a recreated room must start on the default — otherwise this test proves nothing"

      # The rebind the host mount performs. It must land the CURRENT question
      # immediately, without waiting for a further publish.
      assert :ok = Quiz.bind_quiz(pin, qid)
      assert Quiz.state(pin).question.prompt == "EDITED WHILE REAPED"

      # ...and the re-indexed binding still receives LATER publishes.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
      publish_quiz(qid, "EDITED AFTER REBIND", [%{"id" => "a", "label" => "A"}])

      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        "documents:production",
        {:document_changed, %{type: "quiz", doc_id: qid}}
      )

      assert_receive {:quiz, ^pin, {:question_updated, %{prompt: "EDITED AFTER REBIND"}}}, 2000
    end
  end

  describe "rebinding a pin to a second quiz (hq-bridge-rebind-retires-old-quiz)" do
    test "the old quiz is retired from the index AND its publishes stop reaching the room",
         %{pin: pin} do
      n = System.unique_integer([:positive])
      quiz_a = "quiz-a-#{n}"
      quiz_b = "quiz-b-#{n}"

      # The CONTROL pin: bound to quiz_a and never rebound. It is what separates
      # "the rebind retired ONE pin's stale entry" from "the Bridge stopped
      # delivering quiz_a to anybody" — criterion 2 passes on both without it.
      sibling = "TRS#{n}"
      {:ok, _} = Quiz.ensure_room(sibling)
      on_exit(fn -> Quiz.stop_room(sibling) end)

      publish_quiz(quiz_a, "QUIZ A", [%{"id" => "a", "label" => "A"}])
      publish_quiz(quiz_b, "QUIZ B", [%{"id" => "a", "label" => "A"}])

      assert :ok = Quiz.bind_quiz(sibling, quiz_a)
      assert :ok = Quiz.bind_quiz(pin, quiz_a)
      assert :ok = Quiz.bind_quiz(pin, quiz_b)

      # C1 — read the INDEX, not the room. bind/3 and bindings/0 are both
      # synchronous calls on the same GenServer, so this needs no polling.
      bindings = Quiz.Bridge.bindings()
      assert pin in pins_for(bindings, quiz_b)

      refute pin in pins_for(bindings, quiz_a),
             "rebinding #{pin} to #{quiz_b} left it still indexed under #{quiz_a}"

      # ...and the retirement was surgical: the sibling's own quiz_a entry stays.
      assert sibling in pins_for(bindings, quiz_a)
      assert Quiz.state(pin).question.prompt == "QUIZ B"

      Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(sibling))

      publish_quiz(quiz_a, "QUIZ A EDITED", [%{"id" => "a", "label" => "A"}])

      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        "documents:production",
        {:document_changed, %{type: "quiz", doc_id: quiz_a}}
      )

      # C3 first — it is also the BARRIER: the Bridge fans a publish out to every
      # indexed pin inside one handle_info, so the sibling's arrival proves the
      # quiz_a fan-out has already run. Only then is the refute below about a
      # message that was never sent rather than one not yet sent.
      assert_receive {:quiz, ^sibling, {:question_updated, %{prompt: "QUIZ A EDITED"}}}, 2000

      # C2 — the arm that matters.
      refute_receive {:quiz, ^pin, {:question_updated, _}}, 300

      assert Quiz.state(pin).question.prompt == "QUIZ B",
             "a publish of the OLD quiz reverted the room's question underneath its players"
    end

    test "a rebind in one dataset leaves the SAME pin's binding in another dataset alone" do
      Content.upsert_schema(
        %{
          "name" => "quiz",
          "title" => "Quiz",
          "visibility" => "public",
          "fields" => Quiz.Content.schema().fields
        },
        "staging"
      )

      n = System.unique_integer([:positive])
      pin = "TRX#{n}"
      quiz_s = "quiz-s-#{n}"
      quiz_a = "quiz-xa-#{n}"
      quiz_b = "quiz-xb-#{n}"
      {:ok, _} = Quiz.ensure_room(pin)
      on_exit(fn -> Quiz.stop_room(pin) end)

      publish_quiz_in(quiz_s, "STAGING CONTENT", [%{"id" => "a", "label" => "A"}], "staging")
      publish_quiz(quiz_a, "QUIZ A", [%{"id" => "a", "label" => "A"}])
      publish_quiz(quiz_b, "QUIZ B", [%{"id" => "a", "label" => "A"}])

      # The same pin string in two datasets is TWO bindings, not one.
      assert :ok = Quiz.bind_quiz(pin, quiz_s, "staging")
      assert :ok = Quiz.bind_quiz(pin, quiz_a, "production")
      assert :ok = Quiz.bind_quiz(pin, quiz_b, "production")

      bindings = Quiz.Bridge.bindings()
      assert pin in pins_for(bindings, quiz_b)
      refute pin in pins_for(bindings, quiz_a)

      # The cross-dataset sibling survives, keeping its OWN dataset. An
      # over-eager retire that keys on the pin alone reds here with right: [].
      assert pin in pins_for(bindings, quiz_s)
      assert bindings[quiz_s][pin] == "staging"

      # Present is not enough — it must still be LIVE-bound.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
      publish_quiz_in(quiz_s, "STAGING EDITED", [%{"id" => "a", "label" => "A"}], "staging")

      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        "documents:staging",
        {:document_changed, %{type: "quiz", doc_id: quiz_s}}
      )

      assert_receive {:quiz, ^pin, {:question_updated, %{prompt: "STAGING EDITED"}}}, 2000
    end
  end

  test "a non-quiz document change is ignored", %{pin: pin, qid: qid} do
    publish_quiz(qid, "Original?", [%{"id" => "a", "label" => "A"}])
    Quiz.join(pin, "p1", "Alice")
    Quiz.bind_quiz(pin, qid)
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      "documents:production",
      {:document_changed, %{type: "post", doc_id: "something-else"}}
    )

    refute_receive {:quiz, ^pin, {:question_updated, _}}, 300
  end
end
