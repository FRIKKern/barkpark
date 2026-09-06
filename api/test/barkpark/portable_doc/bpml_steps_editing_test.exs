defmodule Barkpark.PortableDoc.BpmlStepsEditingTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.UnprintableError

  for body_key <- ["children", "blocks", "content"] do
    @body_key body_key
    test "step row identity and #{@body_key} body survive BPML" do
      paragraph = %{
        "id" => "step-body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Visible step evidence"}]
      }

      block = %{
        "id" => "procedure",
        "type" => "steps",
        "steps" => [
          %{"id" => "row-1", "title" => "Prepare & verify", @body_key => [paragraph]},
          %{"id" => "row-2", "title" => "Empty body", "blocks" => []}
        ]
      }

      printed = Bpml.print_blocks([block])
      assert printed =~ "Visible step evidence"
      assert {:ok, [parsed]} = Bpml.parse_blocks(printed)

      assert parsed["steps"] == [
               %{"id" => "row-1", "title" => "Prepare & verify", "blocks" => [paragraph]},
               %{"id" => "row-2", "title" => "Empty body", "blocks" => []}
             ]

      assert Bpml.print_blocks([parsed]) == printed
    end
  end

  test "legacy step rows without identity do not gain an id" do
    block = %{
      "type" => "steps",
      "steps" => [%{"title" => "Legacy row", "blocks" => []}]
    }

    assert {:ok, [^block]} = block |> then(&Bpml.print_blocks([&1])) |> Bpml.parse_blocks()
  end

  test "a hidden shadow body refuses instead of disappearing or becoming visible" do
    child = %{"type" => "paragraph", "text" => "Hidden authored body"}

    for visible <- [[], [%{"type" => "paragraph", "text" => "Different visible body"}]],
        shadow <- ["blocks", "content"] do
      block = %{
        "type" => "steps",
        "steps" => [%{"title" => "Conflict", "children" => visible, shadow => [child]}]
      }

      assert_raise UnprintableError, fn -> Bpml.print_blocks([block]) end
    end
  end

  test "malformed authoritative children never expose a legacy shadow body" do
    for malformed <- [%{}, "", "invalid", 0, true] do
      block = %{
        "type" => "steps",
        "steps" => [
          %{
            "children" => malformed,
            "blocks" => [%{"type" => "paragraph", "text" => "Hidden legacy body"}]
          }
        ]
      }

      assert_raise UnprintableError, fn -> Bpml.print_blocks([block]) end
    end
  end

  test "absent children retain the legacy body fallback" do
    child = %{
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "Visible legacy body"}]
    }

    for absent <- [nil, false] do
      block = %{
        "type" => "steps",
        "steps" => [%{"children" => absent, "blocks" => [child]}]
      }

      assert {:ok, [parsed]} = block |> then(&Bpml.print_blocks([&1])) |> Bpml.parse_blocks()
      assert parsed["steps"] == [%{"blocks" => [child]}]
    end
  end

  test "equal duplicate bodies canonicalize once without loss" do
    child = %{
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "Same authored body"}]
    }

    block = %{
      "type" => "steps",
      "steps" => [
        %{"id" => "same", "children" => [child], "blocks" => [child], "content" => [child]}
      ]
    }

    printed = Bpml.print_blocks([block])
    assert {:ok, [parsed]} = Bpml.parse_blocks(printed)
    assert parsed["steps"] == [%{"id" => "same", "blocks" => [child]}]
    assert Bpml.print_blocks([parsed]) == printed
  end
end
