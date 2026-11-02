defmodule Barkpark.Content.Papers.RemintLedgerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Barkpark.Content.Papers.RemintLedger

  @now 1_800_000_000
  @a "lv:a"
  @b "lv:b"

  defp paragraph(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp section(id, children), do: %{"id" => id, "type" => "section", "blocks" => children}

  defp day(first, second),
    do: [section("s-day", [paragraph("p-day", first), paragraph("s-day-1", second)])]

  defp blocks, do: day("Left the car park at six.", "Fog by eight.")

  defp ledger(writer \\ @a), do: RemintLedger.record(%{}, [{"p-day", "s-day-1"}], @now, writer)

  defp patch(id, text),
    do: %{
      "op" => "patch-block",
      "id" => id,
      "patch" => %{"content" => [%{"type" => "text", "value" => text}]}
    }

  defp route(ledger, blocks, op, writer \\ @a),
    do: RemintLedger.route(ledger, blocks, op, @now, writer)

  test "a patch that continues only the fresh copy goes to it" do
    assert {%{"id" => "s-day-1"}, _} =
             route(ledger(), blocks(), patch("p-day", "Fog by eight. Clear."))
  end

  test "a patch that continues only the kept copy stays on it" do
    assert {%{"id" => "p-day"}, _} =
             route(ledger(), blocks(), patch("p-day", "Left the car park at six sharp."))
  end

  test "a deletion inside one copy is a continuation of that copy" do
    assert {%{"id" => "s-day-1"}, _} = route(ledger(), blocks(), patch("p-day", "Fog by."))
  end

  test "Enter at the end of a line: typing in the first line stays on it, though the empty copy continues anything" do
    blocks = day("Left the car park at six.", "")

    for text <- ["Left the car park at six. A", "Left the car park at six. Ab"] do
      assert {%{"op" => "patch-block", "id" => "p-day"}, _} =
               route(ledger(), blocks, patch("p-day", text))
    end
  end

  test "Enter at the start of a line: typing on the text goes to the moved text, typing on the empty line stays" do
    blocks = day("", "Left the car park at six.")

    assert {%{"id" => "s-day-1"}, _} =
             route(ledger(), blocks, patch("p-day", "So Left the car park at six."))

    assert {%{"id" => "p-day"}, _} = route(ledger(), blocks, patch("p-day", "So"))
  end

  test "copies that read the same tie without loss: the kept id takes it" do
    assert {%{"op" => "patch-block", "id" => "p-day"}, _} =
             route(ledger(), day("Fog.", "Fog."), patch("p-day", "Fog. Rain."))

    assert {%{"op" => "patch-block", "id" => "p-day"}, _} =
             route(ledger(), day("", ""), patch("p-day", "x"))
  end

  test "copies that read differently and tie are a doubt" do
    capture_log(fn ->
      assert {%{"op" => "insert-after"}, _} =
               route(ledger(), day("ab", "ac"), patch("p-day", "a"))
    end)
  end

  test "a replace-block is routed by the same rule" do
    replace = &%{"op" => "replace-block", "id" => "p-day", "block" => paragraph("p-day", &1)}

    assert {%{"id" => "s-day-1"}, _} = route(ledger(), blocks(), replace.("Fog by eight. Rain."))

    capture_log(fn ->
      assert {%{"op" => "insert-after", "block" => %{"id" => "p-day-1"}}, _} =
               route(ledger(), blocks(), replace.("Fog by nine."))
    end)
  end

  test "a patch that continues neither copy lands after the closer one and logs no text" do
    log =
      capture_log(fn ->
        assert {op, ledger} = route(ledger(), blocks(), patch("p-day", "Fog by nine."))

        assert op == %{
                 "op" => "insert-after",
                 "afterId" => "s-day-1",
                 "block" => paragraph("p-day-1", "Fog by nine.")
               }

        assert ledger["p-day"]["fresh"] == ["s-day-1", "p-day-1"]
        assert ledger["p-day"]["writer"] == @a
      end)

    assert log =~ ~s(patch-block on repeated id "p-day")
    refute log =~ "Fog"
  end

  test "the doubt block takes the patch's fields, never its template keys" do
    locked =
      Map.put(patch("p-day", "Fog by nine."), "patch", %{
        "content" => [%{"type" => "text", "value" => "Fog by nine."}],
        "locked" => true,
        "role" => "lede"
      })

    capture_log(fn ->
      assert {%{"block" => block}, _} = route(ledger(), blocks(), locked)
      assert block == paragraph("p-day-1", "Fog by nine.")
    end)
  end

  test "a patch that writes no field goes to the kept id" do
    op = %{"op" => "patch-block", "id" => "p-day", "patch" => %{}}
    assert {^op, _} = route(ledger(), blocks(), op)
  end

  test "a patch of another field is judged by that field" do
    forms = [
      %{"id" => "f", "type" => "form", "title" => "Sign up"},
      %{"id" => "f-1", "type" => "form", "title" => "Contact"}
    ]

    ledger = RemintLedger.record(%{}, [{"f", "f-1"}], @now, @a)
    op = %{"op" => "patch-block", "id" => "f", "patch" => %{"title" => "Contact us"}}
    assert {%{"id" => "f-1"}, _} = route(ledger, forms, op)
  end

  test "a copy held in a map field, like a figure's child, is found and kept" do
    held = [
      paragraph("p-day", "Left the car park at six."),
      %{"id" => "fig", "type" => "figure", "child" => paragraph("s-day-1", "Fog by eight.")}
    ]

    assert {%{"id" => "s-day-1"}, _} =
             route(ledger(), held, patch("p-day", "Fog by eight. Clear."))

    assert RemintLedger.settle(ledger(), held) == ledger()
  end

  test "a remove on a repeated id is skipped" do
    capture_log(fn ->
      assert {nil, _} = route(ledger(), blocks(), %{"op" => "remove-block", "id" => "p-day"})
    end)
  end

  test "with one copy left, a patch that continues it goes to it, and one that does not lands beside it" do
    only_fresh = [section("s-day", [paragraph("s-day-1", "Fog by eight.")])]

    assert {%{"id" => "s-day-1"}, _} =
             route(ledger(), only_fresh, patch("p-day", "Fog by eight. More."))

    capture_log(fn ->
      assert {%{"op" => "insert-after", "afterId" => "s-day-1"}, _} =
               route(ledger(), only_fresh, patch("p-day", "Left the car park at six. More."))
    end)
  end

  test "only the editor that sent the repeat is routed; others write as they always did" do
    op = patch("p-day", "Fog by eight. Clear.")
    assert {^op, ledger} = route(ledger(@a), blocks(), op, @b)
    assert ledger == ledger(@a)
    assert {^op, _} = route(ledger(@a), blocks(), op, nil)
  end

  test "a healed duplicate has no writer: every canvas editor is routed, a writer-less client is not" do
    healed = ledger(nil)
    op = patch("p-day", "Fog by eight. Clear.")
    assert {%{"id" => "s-day-1"}, _} = route(healed, blocks(), op, @b)
    assert {^op, _} = route(healed, blocks(), op, nil)
  end

  test "a routed write keeps the entry alive" do
    {_op, ledger} =
      RemintLedger.route(
        ledger(),
        blocks(),
        patch("p-day", "Fog by eight. Clear."),
        @now + 50,
        @a
      )

    assert ledger["p-day"]["at"] == @now + 50
  end

  test "an id outside the ledger passes through" do
    op = patch("p-other", "x")
    assert {^op, _} = route(ledger(), blocks(), op)
  end

  test "the writer naming a fresh id drops its entry; another writer naming it does not" do
    assert RemintLedger.forget_named(ledger(), patch("s-day-1", "x"), @a) == %{}

    assert RemintLedger.forget_named(
             ledger(),
             %{"op" => "insert-after", "afterId" => "s-day-1", "block" => paragraph("p-n", "")},
             @a
           ) == %{}

    assert RemintLedger.forget_named(ledger(), patch("p-day", "x"), @a) == ledger()
    assert RemintLedger.forget_named(ledger(), patch("s-day-1", "x"), @b) == ledger()
    assert RemintLedger.forget_named(ledger(), patch("s-day-1", "x"), nil) == ledger()
    assert RemintLedger.forget_named(ledger(nil), patch("s-day-1", "x"), @a) == ledger(nil)
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
        "a" => %{"fresh" => "a-1", "at" => @now, "writer" => @a},
        "b" => %{"fresh" => ["b-1"], "at" => "now", "writer" => @a},
        "c" => %{"fresh" => ["c-1"], "at" => @now, "writer" => 7},
        "d" => "x"
      },
      "rev" => 3
    }

    assert RemintLedger.load(content, @now) == %{}
    assert RemintLedger.load(nil, @now) == %{}
    assert RemintLedger.put(content, %{}) == %{"rev" => 3}
  end

  test "settle keeps an entry while any copy is left, holding only the fresh ids still there" do
    assert RemintLedger.settle(ledger(), blocks()) == ledger()

    assert RemintLedger.settle(ledger(), [paragraph("p-day", "x")]) ==
             put_in(ledger(), ["p-day", "fresh"], [])

    assert RemintLedger.settle(ledger(), [paragraph("s-day-1", "x")]) == ledger()
    assert RemintLedger.settle(ledger(), [paragraph("p-other", "x")]) == %{}
  end
end
