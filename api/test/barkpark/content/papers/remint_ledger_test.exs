defmodule Barkpark.Content.Papers.RemintLedgerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Barkpark.Content.Papers.RemintLedger

  @now 1_800_000_000

  defp paragraph(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp section(id, children), do: %{"id" => id, "type" => "section", "blocks" => children}

  defp blocks,
    do: [
      section("s-day", [
        paragraph("p-day", "Left the car park at six."),
        paragraph("s-day-1", "Fog by eight.")
      ])
    ]

  defp ledger, do: RemintLedger.record(%{}, [{"p-day", "s-day-1"}], @now)

  defp patch(id, text),
    do: %{
      "op" => "patch-block",
      "id" => id,
      "patch" => %{"content" => [%{"type" => "text", "value" => text}]}
    }

  test "a patch that continues only the fresh copy goes to it" do
    assert {%{"id" => "s-day-1"}, _} =
             RemintLedger.route(ledger(), blocks(), patch("p-day", "Fog by eight. Clear."), @now)
  end

  test "a patch that continues only the kept copy stays on it" do
    assert {%{"id" => "p-day"}, _} =
             RemintLedger.route(
               ledger(),
               blocks(),
               patch("p-day", "Left the car park at six sharp."),
               @now
             )
  end

  test "a deletion inside one copy is a continuation of that copy" do
    assert {%{"id" => "s-day-1"}, _} =
             RemintLedger.route(ledger(), blocks(), patch("p-day", "Fog by."), @now)
  end

  test "a replace-block is routed by the same rule" do
    replace = &%{"op" => "replace-block", "id" => "p-day", "block" => paragraph("p-day", &1)}

    assert {%{"id" => "s-day-1"}, _} =
             RemintLedger.route(ledger(), blocks(), replace.("Fog by eight. Rain."), @now)

    capture_log(fn ->
      assert {%{"op" => "insert-after", "block" => %{"id" => "p-day-1"}}, _} =
               RemintLedger.route(ledger(), blocks(), replace.("Fog by nine."), @now)
    end)
  end

  test "a patch that continues neither copy lands after the closer one and logs no text" do
    log =
      capture_log(fn ->
        assert {op, ledger} =
                 RemintLedger.route(ledger(), blocks(), patch("p-day", "Fog by nine."), @now)

        assert op == %{
                 "op" => "insert-after",
                 "afterId" => "s-day-1",
                 "block" => paragraph("p-day-1", "Fog by nine.")
               }

        assert ledger["p-day"]["fresh"] == ["s-day-1", "p-day-1"]
      end)

    assert log =~ ~s(patch-block on repeated id "p-day")
    refute log =~ "Fog"
  end

  test "a patch both copies continue is a doubt too" do
    both = [
      section("s-day", [paragraph("p-day", "Fog."), paragraph("s-day-1", "Fog.")])
    ]

    capture_log(fn ->
      assert {%{"op" => "insert-after", "afterId" => "p-day"}, _} =
               RemintLedger.route(ledger(), both, patch("p-day", "Fog. Rain."), @now)
    end)
  end

  test "a patch that writes no text field goes to the kept id" do
    op = %{"op" => "patch-block", "id" => "p-day", "patch" => %{}}
    assert {^op, _} = RemintLedger.route(ledger(), blocks(), op, @now)
  end

  test "a patch of another field is judged by that field" do
    forms = [
      %{"id" => "f", "type" => "form", "title" => "Sign up"},
      %{"id" => "f-1", "type" => "form", "title" => "Contact"}
    ]

    ledger = RemintLedger.record(%{}, [{"f", "f-1"}], @now)
    op = %{"op" => "patch-block", "id" => "f", "patch" => %{"title" => "Contact us"}}
    assert {%{"id" => "f-1"}, _} = RemintLedger.route(ledger, forms, op, @now)
  end

  test "a copy held in a map field, like a figure's child, is found and kept" do
    held = [
      paragraph("p-day", "Left the car park at six."),
      %{"id" => "fig", "type" => "figure", "child" => paragraph("s-day-1", "Fog by eight.")}
    ]

    assert {%{"id" => "s-day-1"}, _} =
             RemintLedger.route(ledger(), held, patch("p-day", "Fog by eight. Clear."), @now)

    assert RemintLedger.settle(ledger(), held) == ledger()
  end

  test "a remove on a repeated id is skipped" do
    capture_log(fn ->
      assert {nil, _} =
               RemintLedger.route(
                 ledger(),
                 blocks(),
                 %{"op" => "remove-block", "id" => "p-day"},
                 @now
               )
    end)
  end

  test "an id outside the ledger, or with one copy left, passes through" do
    op = patch("p-other", "x")
    assert {^op, _} = RemintLedger.route(ledger(), blocks(), op, @now)

    alone = [section("s-day", [paragraph("p-day", "Left.")])]
    op = patch("p-day", "Fog.")
    assert {^op, _} = RemintLedger.route(ledger(), alone, op, @now)
  end

  test "an op naming a fresh id drops the entry: that editor has the new ids" do
    assert RemintLedger.forget_named(ledger(), patch("s-day-1", "x")) == %{}

    assert RemintLedger.forget_named(ledger(), %{
             "op" => "insert-after",
             "afterId" => "s-day-1",
             "block" => paragraph("p-n", "")
           }) == %{}

    assert RemintLedger.forget_named(ledger(), patch("p-day", "x")) == ledger()
  end

  test "an entry lives 24 hours after it was last written" do
    content = RemintLedger.put(%{}, ledger())
    assert RemintLedger.ttl_seconds() == 24 * 3600
    assert RemintLedger.load(content, @now + 24 * 3600 - 1) == ledger()
    assert RemintLedger.load(content, @now + 24 * 3600) == %{}
  end

  test "load drops malformed entries and put removes an empty ledger" do
    content = %{
      "id_remints" => %{
        "a" => %{"fresh" => [], "at" => @now},
        "b" => %{"fresh" => ["b-1"], "at" => "now"},
        "c" => "x"
      },
      "rev" => 3
    }

    assert RemintLedger.load(content, @now) == %{}
    assert RemintLedger.load(nil, @now) == %{}
    assert RemintLedger.put(content, %{}) == %{"rev" => 3}
  end

  test "settle keeps only entries with two copies still present" do
    assert RemintLedger.settle(ledger(), blocks()) == ledger()
    assert RemintLedger.settle(ledger(), [paragraph("p-day", "x")]) == %{}
    assert RemintLedger.settle(ledger(), [paragraph("s-day-1", "x")]) == %{}
  end
end
