defmodule Barkpark.Content.ValuerefResolveTest do
  @moduledoc """
  lvw-t1 — `Papers.resolve_values_in_blocks/3` (wire §3/§5 as amended), the
  batched valueref pre-resolve pass:

    1. A published canonical value resolves through the deep walk into the
       `%{{target, field} => string}` palette map (title included — it rides
       the envelope).
    2. D3 published-row preference: when the draft twin diverges, the
       PUBLISHED value wins.
    3. D5 `published_only: true`: a draft-only target does NOT resolve (no
       draft value ever leaks into an anonymous surface); without the gate the
       draft twin may resolve (the authorized Studio path).
    4. RENDER-THEN-READ redaction: a `visibility: "private"` field does NOT
       resolve for the (default) anonymous caller; an admin caller context
       resolves it — proof the read goes through the redacted envelope, not a
       caller-less `field_readable?`.
    5. Tenant scoping: an out-of-scope `workspace_id` resolves nothing.
    6. Scalar rule: maps/lists/empty strings never resolve (→ fallback);
       dot-path / `content.`-prefixed fields are dropped at collection time.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document}
  alias Barkpark.Repo

  @dataset "valueref_resolve_test"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "metric",
          "title" => "Metric",
          "visibility" => "public",
          "fields" => [
            %{"name" => "launch_delay", "type" => "string"},
            %{"name" => "secret_delay", "type" => "string", "visibility" => "private"}
          ]
        },
        @dataset
      )

    :ok
  end

  defp metric!(id, content) do
    {:ok, _} =
      Content.create_document(
        "metric",
        Map.merge(%{"_id" => id, "title" => "Metric #{id}"}, content),
        @dataset
      )

    id
  end

  defp publish!(id), do: ({:ok, doc} = Content.publish_document(id, "metric", @dataset)) && doc

  defp blocks_for(target, field) do
    [
      %{
        "id" => "b1",
        "type" => "paragraph",
        "content" => [
          %{"type" => "text", "value" => "Delay: "},
          %{
            "type" => "valueref",
            "target" => target,
            "field" => field,
            "fallback" => "12 weeks",
            "children" => [%{"type" => "text", "value" => "12 weeks"}]
          }
        ]
      }
    ]
  end

  test "a published canonical value resolves into the tuple-keyed palette map" do
    metric!("m-basic", %{"launch_delay" => "6 weeks"})
    publish!("m-basic")

    values = Content.resolve_values_in_blocks(blocks_for("m-basic", "launch_delay"), @dataset)

    assert values == %{{"m-basic", "launch_delay"} => "6 weeks"}
  end

  test "title resolves too — it rides the envelope" do
    metric!("m-title", %{"launch_delay" => "x"})
    publish!("m-title")

    values = Content.resolve_values_in_blocks(blocks_for("m-title", "title"), @dataset)

    assert values[{"m-title", "title"}] == "Metric m-title"
  end

  test "D3: the published row outranks a diverged draft twin" do
    metric!("m-twin", %{"launch_delay" => "6 weeks"})
    publish!("m-twin")

    # Publish consumes the draft twin; recreate a DIVERGED draft row directly
    # (the "edited after publish" state) so both spellings exist.
    %Document{}
    |> Document.changeset(%{
      doc_id: "drafts.m-twin",
      type: "metric",
      dataset: @dataset,
      title: "Metric m-twin",
      status: "draft",
      content: %{"launch_delay" => "7 weeks (draft)"},
      rev: Ecto.UUID.generate()
    })
    |> Repo.insert!()

    values = Content.resolve_values_in_blocks(blocks_for("m-twin", "launch_delay"), @dataset)

    assert values[{"m-twin", "launch_delay"}] == "6 weeks"
  end

  test "D5: published_only blocks a draft-only target; without the gate the draft resolves" do
    metric!("m-draft", %{"launch_delay" => "unpublished value"})

    blocks = blocks_for("m-draft", "launch_delay")

    assert Content.resolve_values_in_blocks(blocks, @dataset, published_only: true) == %{}

    assert Content.resolve_values_in_blocks(blocks, @dataset)[{"m-draft", "launch_delay"}] ==
             "unpublished value"
  end

  test "render-then-read: a private field stays redacted for the anonymous default, resolves for an admin" do
    metric!("m-priv", %{"launch_delay" => "ok", "secret_delay" => "classified"})
    publish!("m-priv")

    blocks = blocks_for("m-priv", "secret_delay")

    # Anonymous (the default caller context) — the redacted envelope carries no
    # private field, so the pair is simply absent → the node renders fallback.
    assert Content.resolve_values_in_blocks(blocks, @dataset) == %{}

    # Admin authority sees it — proof the value is read OFF THE ENVELOPE under
    # the caller's context (never a caller-less field_readable? bypass).
    values =
      Content.resolve_values_in_blocks(blocks, @dataset,
        caller_context: %CallerContext{is_admin: true}
      )

    assert values[{"m-priv", "secret_delay"}] == "classified"
  end

  test "tenant scoping: an out-of-scope workspace resolves nothing" do
    metric!("m-scope", %{"launch_delay" => "6 weeks"})
    publish!("m-scope")

    values =
      Content.resolve_values_in_blocks(blocks_for("m-scope", "launch_delay"), @dataset,
        workspace_id: Ecto.UUID.generate()
      )

    assert values == %{}
  end

  test "scalar rule: maps and empty strings never resolve; dot-path fields are never collected" do
    metric!("m-shape", %{
      "launch_delay" => "",
      "nested" => %{"deep" => "no"},
      "listy" => [1, 2]
    })

    publish!("m-shape")

    for field <- ["launch_delay", "nested", "listy"] do
      assert Content.resolve_values_in_blocks(blocks_for("m-shape", field), @dataset) == %{},
             "field #{field} must not resolve"
    end

    # Dot-path / content.-prefixed fields are wire violations, dropped at
    # collection time (no query, no resolution — fallback).
    assert Content.resolve_values_in_blocks(blocks_for("m-shape", "nested.deep"), @dataset) ==
             %{}

    assert Content.resolve_values_in_blocks(blocks_for("m-shape", "content.launch_delay"), @dataset) ==
             %{}
  end

  test "one batched pass resolves many pairs across targets and fields" do
    metric!("m-a", %{"launch_delay" => "6 weeks"})
    publish!("m-a")
    metric!("m-b", %{"launch_delay" => "9 weeks"})
    publish!("m-b")

    blocks = [
      %{
        "id" => "b1",
        "type" => "paragraph",
        "content" => [
          %{"type" => "valueref", "target" => "m-a", "field" => "launch_delay", "fallback" => "?"},
          %{"type" => "valueref", "target" => "m-a", "field" => "title", "fallback" => "?"},
          %{"type" => "valueref", "target" => "m-b", "field" => "launch_delay", "fallback" => "?"}
        ]
      }
    ]

    values = Content.resolve_values_in_blocks(blocks, @dataset)

    assert values == %{
             {"m-a", "launch_delay"} => "6 weeks",
             {"m-a", "title"} => "Metric m-a",
             {"m-b", "launch_delay"} => "9 weeks"
           }
  end
end
