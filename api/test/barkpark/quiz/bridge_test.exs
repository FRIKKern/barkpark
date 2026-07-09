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

    # A publish on production reloads BOTH pins bound to this quiz_id — each must
    # reload from ITS OWN dataset, never inject production's content into staging.
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      "documents:production",
      {:document_changed, %{type: "quiz", doc_id: qid}}
    )

    Process.sleep(200)

    assert Quiz.state(pin_prod).question.prompt == "PROD CONTENT"
    assert Quiz.state(pin_stag).question.prompt == "STAGING CONTENT"
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
