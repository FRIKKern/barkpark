defmodule Barkpark.Quiz.Content do
  @moduledoc """
  P3 content model (`/papers/hyperquiz-content-model`): the `quiz` document type
  and the bridge from a stored Barkpark content doc to the in-memory question
  shape the Room serves.

  A quiz is a first-class Barkpark document (schema-v2), so designers author and
  (P4) live-edit it in Studio. `to_question/2` parses a stored doc's content into
  the Room shape `%{id, prompt, choices: [%{id, label}], answer}`; `load_question/2`
  fetches a published quiz by id and parses it. The Room keeps its hardcoded
  fallback (`Barkpark.Quiz.Room.default_question/0`) so a missing/absent quiz never
  breaks a room — P1/P2 behaviour is unchanged when no quiz is selected.
  """

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition

  @doc """
  The schema-v2 definition for the `quiz` document type. **Private** visibility:
  the doc stores the correct answer inline (`"correct" => true`), so it must NOT
  be anonymously readable via the public content API or players could fetch the
  answer key. Players never read it directly — the Room loads it server-side
  (`load_question/2`, an internal call not gated by visibility) and broadcasts an
  answer-stripped question. Registered into a dataset at P4 (Studio authoring).
  """
  @spec schema() :: SchemaDefinition.t()
  def schema do
    %SchemaDefinition{
      name: "quiz",
      title: "Quiz",
      icon: "❓",
      visibility: "private",
      dataset: "production",
      fields: [
        %{"name" => "title", "title" => "Title", "type" => "string"},
        %{"name" => "prompt", "title" => "Question prompt", "type" => "text"},
        %{"name" => "image", "title" => "Question image", "type" => "image"},
        %{
          "name" => "time_limit",
          "title" => "Time limit (seconds)",
          "type" => "number",
          "default" => 20
        },
        %{
          "name" => "choices",
          "title" => "Choices",
          "type" => "arrayOf",
          "ordered" => true,
          "of" => %{
            "type" => "composite",
            "fields" => [
              %{"name" => "id", "title" => "Id", "type" => "string"},
              %{"name" => "label", "title" => "Label", "type" => "string"},
              %{
                "name" => "correct",
                "title" => "Correct?",
                "type" => "boolean",
                "default" => false
              }
            ]
          }
        }
      ]
    }
  end

  @doc """
  Parse a quiz doc's `content` map (string-keyed, as stored) into the Room's
  question shape. Missing fields degrade gracefully (empty prompt, no choices,
  nil answer). `answer` is the id of the choice flagged `"correct" => true`.
  """
  @spec to_question(map(), String.t()) :: map()
  def to_question(content, id) when is_map(content) do
    raw_choices = Map.get(content, "choices", []) || []

    %{
      id: id,
      prompt: Map.get(content, "prompt") || Map.get(content, "title") || "",
      image: Map.get(content, "image"),
      time_limit: Map.get(content, "time_limit", 20),
      choices: Enum.map(raw_choices, &%{id: &1["id"], label: &1["label"]}),
      answer: Enum.find_value(raw_choices, fn c -> if c["correct"], do: c["id"] end)
    }
  end

  @doc """
  Load a published quiz by id and parse it into a question.
  `{:ok, question}` or `{:error, :not_found}` when no such quiz exists.
  """
  @spec load_question(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def load_question(quiz_id, dataset \\ "production") when is_binary(quiz_id) do
    case Content.get_document(quiz_id, "quiz", dataset) do
      {:ok, doc} -> {:ok, to_question(doc_content(doc), doc_id(doc, quiz_id))}
      %{} = doc -> {:ok, to_question(doc_content(doc), doc_id(doc, quiz_id))}
      _ -> {:error, :not_found}
    end
  end

  defp doc_content(doc), do: Map.get(doc, :content) || Map.get(doc, "content") || %{}
  defp doc_id(doc, fallback), do: Map.get(doc, :id) || Map.get(doc, :_id) || fallback

  # Schema registration now flows through the plugin callback
  # `Barkpark.Plugins.Quiz.register_schemas/1` → `Plugins.Bootstrap` at boot
  # (idempotent on (name, dataset)); the former `register_schema/1` here was dead
  # code (never wired to boot) and has been removed. Once the schema is
  # registered, the EXISTING Studio is the authoring UI — quizzes are
  # created/edited/published like any document; publishing drives the live-edit
  # bridge. (Honest gap: no bespoke quiz-builder screen — Studio's generic
  # document editor is the authoring surface.)

  @doc "Example quiz content (seed it; Studio then edits/publishes it)."
  @spec example_quiz() :: map()
  def example_quiz do
    %{
      "doc_id" => "example-quiz",
      "prompt" => "What powers Barkpark's realtime layer?",
      "choices" => [
        %{"id" => "a", "label" => "Phoenix Channels + PubSub", "correct" => true},
        %{"id" => "b", "label" => "Carrier pigeons"},
        %{"id" => "c", "label" => "Polling every 5 seconds"},
        %{"id" => "d", "label" => "Pure willpower"}
      ]
    }
  end
end
