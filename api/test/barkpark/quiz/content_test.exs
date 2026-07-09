defmodule Barkpark.Quiz.ContentTest do
  @moduledoc "P3 hq-p3-schema: quiz content type, doc→question parser, loader + fallback."
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Quiz
  alias Barkpark.Quiz.Content

  describe "to_question/2" do
    test "parses a full quiz content map (answer = the correct choice id)" do
      content = %{
        "prompt" => "Capital of Norway?",
        "time_limit" => 30,
        "choices" => [
          %{"id" => "a", "label" => "Oslo", "correct" => true},
          %{"id" => "b", "label" => "Bergen"}
        ]
      }

      q = Content.to_question(content, "quiz-1")
      assert q.id == "quiz-1"
      assert q.prompt == "Capital of Norway?"
      assert q.time_limit == 30
      assert q.choices == [%{id: "a", label: "Oslo"}, %{id: "b", label: "Bergen"}]
      assert q.answer == "a"
    end

    test "degrades gracefully on missing fields" do
      q = Content.to_question(%{}, "q")
      assert q.prompt == ""
      assert q.choices == []
      assert q.answer == nil
      assert q.time_limit == 20
    end

    test "uses title when prompt is absent" do
      assert Content.to_question(%{"title" => "T"}, "q").prompt == "T"
    end

    test "carries an optional image (nil when absent)" do
      assert Content.to_question(%{"image" => "/media/x.png"}, "q").image == "/media/x.png"
      assert Content.to_question(%{}, "q").image == nil
    end
  end

  describe "schema/0" do
    test "defines a PRIVATE quiz type with prompt + choices fields" do
      s = Content.schema()
      assert s.name == "quiz"
      # Private: the doc holds the answer key inline, so it must not be readable
      # via the anonymous public content API.
      assert s.visibility == "private"
      names = Enum.map(s.fields, & &1["name"])
      assert "prompt" in names
      assert "choices" in names
    end
  end

  describe "authoring (P4)" do
    test "the plugin registers the quiz type so quizzes can be created" do
      # Schema registration flows through the plugin's register_schemas/1
      # (Plugins.Bootstrap at boot) — the dead Content.register_schema/1
      # call-path was removed.
      [%SchemaDefinition{name: "quiz"} = s] = Barkpark.Plugins.Quiz.register_schemas([])

      assert {:ok, _} =
               Barkpark.Content.upsert_schema(
                 %{
                   "name" => s.name,
                   "title" => s.title,
                   "visibility" => s.visibility,
                   "fields" => s.fields
                 },
                 "production"
               )

      attrs =
        Map.put(Content.example_quiz(), "doc_id", "ex-#{System.unique_integer([:positive])}")

      assert {:ok, _} = Barkpark.Content.create_document("quiz", attrs, "production")
    end
  end

  describe "loader + fallback" do
    test "a missing quiz returns not_found" do
      assert {:error, :not_found} = Content.load_question("does-not-exist", "production")
    end

    test "question_or_default falls back to the Room default when not found" do
      assert Quiz.question_or_default("does-not-exist") == Barkpark.Quiz.Room.default_question()
    end
  end
end
