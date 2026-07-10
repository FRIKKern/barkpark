defmodule Barkpark.Content.LabelSpineTest do
  @moduledoc """
  The weighted-label spine (authoring-excellence D2) — the pure, cross-member
  rules the field DSL cannot express. Pure `validate/1`: every rule, every
  pathological case, and the shape of the `{field, rule, fix}` error details.

  The validator is UNMOUNTED this slice — these tests exercise it directly; no
  publish path calls it yet (mount is ae-w1-publish-wall-mount).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.LabelSpine

  # A minimal well-labelled document.
  defp ok_content(overrides \\ %{}) do
    Map.merge(
      %{
        "description" => "A concise, non-trivial description of the document.",
        "tags" => [
          %{
            "tag" => "obsidian",
            "strength" => 80,
            "rationale" => "Central to the note-taking workflow."
          },
          %{
            "tag" => "search",
            "strength" => 45,
            "rationale" => "Findability is the north-star metric."
          }
        ]
      },
      overrides
    )
  end

  describe "the happy path" do
    test "a well-labelled document passes" do
      assert LabelSpine.validate(ok_content()) == :ok
    end

    test "exactly 1 tag (lower bound) passes" do
      content =
        ok_content(%{
          "tags" => [
            %{
              "tag" => "solo",
              "strength" => 50,
              "rationale" => "The single defining topic of this doc."
            }
          ]
        })

      assert LabelSpine.validate(content) == :ok
    end

    test "exactly 12 tags (upper bound) passes" do
      tags =
        for i <- 1..12 do
          %{
            "tag" => "tag-#{i}",
            "strength" => i,
            "rationale" => "A distinct rationale for tag number #{i} here."
          }
        end

      assert LabelSpine.validate(ok_content(%{"tags" => tags})) == :ok
    end
  end

  describe "description" do
    test "missing description fails with field/rule/fix" do
      content = ok_content() |> Map.delete("description")
      assert {:error, {:label_spine, details}} = LabelSpine.validate(content)
      assert details.field == "description"
      assert is_binary(details.rule)
      assert is_binary(details.fix)
    end

    test "blank description fails" do
      assert {:error, {:label_spine, %{field: "description"}}} =
               LabelSpine.validate(ok_content(%{"description" => "   "}))
    end

    test "trivial (too-short) description fails" do
      assert {:error, {:label_spine, %{field: "description"}}} =
               LabelSpine.validate(ok_content(%{"description" => "short"}))
    end

    test "non-string description fails" do
      assert {:error, {:label_spine, %{field: "description"}}} =
               LabelSpine.validate(ok_content(%{"description" => 42}))
    end
  end

  describe "tag count bounds (1..12)" do
    test "count 0 (empty list) fails" do
      assert {:error, {:label_spine, %{field: "tags"}}} =
               LabelSpine.validate(ok_content(%{"tags" => []}))
    end

    test "missing tags fails" do
      content = ok_content() |> Map.delete("tags")
      assert {:error, {:label_spine, %{field: "tags"}}} = LabelSpine.validate(content)
    end

    test "non-list tags fails" do
      assert {:error, {:label_spine, %{field: "tags"}}} =
               LabelSpine.validate(ok_content(%{"tags" => "obsidian"}))
    end

    test "count 13 (over the ceiling) fails" do
      tags =
        for i <- 1..13 do
          %{
            "tag" => "tag-#{i}",
            "strength" => i,
            "rationale" => "Distinct rationale for tag #{i} here."
          }
        end

      assert {:error, {:label_spine, %{field: "tags", rule: rule}}} =
               LabelSpine.validate(ok_content(%{"tags" => tags}))

      assert rule =~ "12"
    end
  end

  describe "per-entry: tag" do
    test "missing tag key fails, carrying the index" do
      content =
        ok_content(%{
          "tags" => [
            %{
              "tag" => "ok-tag",
              "strength" => 60,
              "rationale" => "A perfectly fine rationale here."
            },
            %{"strength" => 40, "rationale" => "This entry has no tag key at all here."}
          ]
        })

      assert {:error, {:label_spine, details}} = LabelSpine.validate(content)
      assert details.field == "tag"
      assert details.index == 1
    end

    test "tag violating ^[a-z0-9-]+$ fails" do
      content =
        ok_content(%{
          "tags" => [
            %{
              "tag" => "Obsidian!",
              "strength" => 60,
              "rationale" => "Uppercase and bang are illegal here."
            }
          ]
        })

      assert {:error, {:label_spine, %{field: "tag", index: 0}}} = LabelSpine.validate(content)
    end

    test "a non-map entry fails" do
      content = ok_content(%{"tags" => ["not-an-object"]})
      assert {:error, {:label_spine, %{field: "tags", index: 0}}} = LabelSpine.validate(content)
    end
  end

  describe "per-entry: strength" do
    test "non-integer (float) strength fails" do
      content =
        ok_content(%{
          "tags" => [
            %{
              "tag" => "obsidian",
              "strength" => 80.5,
              "rationale" => "Floats are not allowed as strength."
            }
          ]
        })

      assert {:error, {:label_spine, %{field: "strength", index: 0}}} =
               LabelSpine.validate(content)
    end

    test "strength below 1 fails" do
      content =
        ok_content(%{
          "tags" => [
            %{
              "tag" => "obsidian",
              "strength" => 0,
              "rationale" => "Zero is below the 1 floor here."
            }
          ]
        })

      assert {:error, {:label_spine, %{field: "strength"}}} = LabelSpine.validate(content)
    end

    test "strength above 100 fails" do
      content =
        ok_content(%{
          "tags" => [
            %{
              "tag" => "obsidian",
              "strength" => 101,
              "rationale" => "101 is above the ceiling here."
            }
          ]
        })

      assert {:error, {:label_spine, %{field: "strength"}}} = LabelSpine.validate(content)
    end

    test "missing strength fails" do
      content =
        ok_content(%{
          "tags" => [
            %{"tag" => "obsidian", "rationale" => "No strength key present on this entry."}
          ]
        })

      assert {:error, {:label_spine, %{field: "strength"}}} = LabelSpine.validate(content)
    end
  end

  describe "per-entry: rationale" do
    test "missing rationale fails" do
      content = ok_content(%{"tags" => [%{"tag" => "obsidian", "strength" => 80}]})

      assert {:error, {:label_spine, %{field: "rationale", index: 0}}} =
               LabelSpine.validate(content)
    end

    test "too-short rationale fails" do
      content =
        ok_content(%{
          "tags" => [%{"tag" => "obsidian", "strength" => 80, "rationale" => "too short"}]
        })

      assert {:error, {:label_spine, %{field: "rationale"}}} = LabelSpine.validate(content)
    end

    test "non-string rationale fails" do
      content =
        ok_content(%{"tags" => [%{"tag" => "obsidian", "strength" => 80, "rationale" => 123}]})

      assert {:error, {:label_spine, %{field: "rationale"}}} = LabelSpine.validate(content)
    end
  end

  describe "cross-member: distinct strengths (⟹ unique main tag)" do
    test "a strength tie is rejected" do
      content =
        ok_content(%{
          "tags" => [
            %{
              "tag" => "obsidian",
              "strength" => 50,
              "rationale" => "Tied strength with the second tag here."
            },
            %{
              "tag" => "search",
              "strength" => 50,
              "rationale" => "Tied strength with the first tag here."
            }
          ]
        })

      assert {:error, {:label_spine, %{field: "strength", rule: rule}}} =
               LabelSpine.validate(content)

      assert rule =~ "distinct"
    end
  end

  describe "cross-member: duplicate tag" do
    test "the same tag twice is rejected" do
      content =
        ok_content(%{
          "tags" => [
            %{
              "tag" => "obsidian",
              "strength" => 80,
              "rationale" => "First occurrence of the obsidian tag."
            },
            %{
              "tag" => "obsidian",
              "strength" => 40,
              "rationale" => "Second occurrence of the obsidian tag."
            }
          ]
        })

      assert {:error, {:label_spine, %{field: "tag", rule: rule}}} = LabelSpine.validate(content)
      assert rule =~ "twice"
    end
  end

  describe "error details are documentation" do
    test "every error carries string field, rule and fix" do
      {:error, {:label_spine, details}} = LabelSpine.validate(%{})
      assert is_binary(details.field)
      assert is_binary(details.rule)
      assert is_binary(details.fix)
    end

    test "a non-map content is rejected cleanly" do
      assert {:error, {:label_spine, %{field: "content"}}} = LabelSpine.validate("not a map")
    end
  end

  describe "main_tag/1 derivation" do
    test "derives the argmax tag from valid weighted tags" do
      assert LabelSpine.main_tag(ok_content()) == {:ok, "obsidian"}
    end

    test "returns :error when strengths tie (no unique maximum)" do
      content =
        ok_content(%{
          "tags" => [
            %{
              "tag" => "a",
              "strength" => 50,
              "rationale" => "Tied strength, so no unique max here."
            },
            %{
              "tag" => "b",
              "strength" => 50,
              "rationale" => "Tied strength, so no unique max here."
            }
          ]
        })

      assert LabelSpine.main_tag(content) == :error
    end

    test "returns :error when there are no valid tags" do
      assert LabelSpine.main_tag(%{}) == :error
    end
  end

  describe "atom-keyed content (test-builder convenience)" do
    test "atom keys validate the same as string keys" do
      content = %{
        description: "A concise, non-trivial description of the document.",
        tags: [
          %{
            tag: "obsidian",
            strength: 80,
            rationale: "Central to the note-taking workflow here."
          },
          %{tag: "search", strength: 45, rationale: "Findability is the north-star metric here."}
        ]
      }

      assert LabelSpine.validate(content) == :ok
    end
  end
end
