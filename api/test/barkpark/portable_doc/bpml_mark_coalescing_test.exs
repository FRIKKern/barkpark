defmodule Barkpark.PortableDoc.BpmlMarkCoalescingTest do
  @moduledoc """
  The BPML round trip must be a FIXED POINT: print → parse → print has to be
  byte-identical to the first print. It was not, for 12 of the 570 printable
  published papers, and the shape was always the same — a mark run split at an
  inline-code boundary.

      stored   %{"type" => "strong",
                 "children" => [text "Phase ", %{"type" => "code", "value" => "Ping"}]}
      print 1  <b>Phase <code>Ping</code></b>
      parse    [text marks: ["strong"],  text marks: ["strong", "code"]]
      print 2  <b>Phase </b><b><code>Ping</code></b>      # ← different bytes

  Every character survives, so this is not destruction — it is CHURN: `bp paper
  pull` followed by `bp paper push` with no edit rewrote the stored paper, and
  `bp paper diff` reported a change on a file the author never touched.

  The printer now emits inline content as a mark TREE (`inline_run/2`): adjacent
  nodes sharing a leading run of marks are wrapped in that run once. These tests
  pin both halves of that — that runs coalesce when they share a prefix, and
  that they do NOT coalesce when they merely look similar (a different mark, or
  the same marks in a different order, are different markup and must stay so).
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.UnprintableError

  defp text(value, marks \\ []), do: %{"type" => "text", "marks" => marks, "value" => value}
  defp code(value), do: %{"type" => "code", "value" => value}
  defp para(content), do: %{"id" => "p", "type" => "paragraph", "content" => content}

  defp print(blocks), do: Bpml.print_blocks(blocks)

  defp reprint(blocks) do
    first = print(blocks)
    assert {:ok, reparsed} = Bpml.parse_blocks(first)
    {first, Bpml.print_blocks(reparsed)}
  end

  describe "the golden case: chat-plan-83959fbd5740 line 9" do
    # The list item VERBATIM from the published paper's stored blocks, trimmed
    # to the run that churns. If this ever splits again the test names the
    # paper, not an abstraction.
    # NOTE: module attributes are evaluated at compile time and cannot call the
    # `text/2` / `code/1` helpers above, so the inline nodes are spelled out.
    @phase_ping %{
      "id" => "block-8",
      "type" => "list",
      "ordered" => false,
      "items" => [
        [
          %{
            "type" => "strong",
            "children" => [
              %{"type" => "text", "value" => "Phase "},
              %{"type" => "code", "value" => "Ping"}
            ]
          },
          %{"type" => "text", "value" => " — one "},
          %{"type" => "code", "value" => "agent()"},
          %{"type" => "text", "value" => " call with a small JSON schema."}
        ]
      ]
    }

    test "prints the mark run as ONE <b> and survives a second print unchanged" do
      {first, second} = reprint([@phase_ping])

      assert first =~ "<li><b>Phase <code>Ping</code></b> — one <code>agent()</code>"
      refute first =~ "<b>Phase </b><b>"
      assert second == first
      # The split spelling is the defect; it must not appear on EITHER print.
      refute second =~ "<b>Phase </b><b>"
    end

    test "a third print is the same fixed point" do
      {first, second} = reprint([@phase_ping])
      assert {:ok, reparsed} = Bpml.parse_blocks(second)
      assert Bpml.print_blocks(reparsed) == first
    end
  end

  describe "adjacent runs sharing a mark prefix coalesce" do
    test "a deeper run nests inside the shared one" do
      content = [
        text("a", ["strong"]),
        text("b", ["strong", "code"]),
        text("c", ["strong"])
      ]

      assert print([para(content)]) == ~s(<p id="p"><b>a<code>b</code>c</b></p>\n)
    end

    test "an unmarked node ends the run and a later marked node reopens it" do
      content = [text("a", ["strong"]), text("b"), text("c", ["strong"])]

      assert print([para(content)]) == ~s(<p id="p"><b>a</b>b<b>c</b></p>\n)
    end

    test "a node-spelled code inline joins the open run (the churn shape, directly)" do
      content = [%{"type" => "strong", "children" => [text("Phase "), code("Ping")]}]

      {first, second} = reprint([para(content)])

      assert first == ~s(<p id="p"><b>Phase <code>Ping</code></b></p>\n)
      assert second == first
    end
  end

  describe "coalescing stops at a boundary the parser can hand back" do
    # The counterweight: coalescing must not run the other way and destroy an
    # element boundary that survives a parse on its own. Two adjacent runs with
    # EXACTLY the same marks are two elements; merging them made 3 papers churn
    # (owner-decision-queue-2026-08-24 and the two deploy-reliability rulings)
    # in the first cut of this fix.
    test "two runs with identical marks stay two elements" do
      assert print([para([text("a", ["strong"]), text("b", ["strong"])])]) ==
               ~s(<p id="p"><b>a</b><b>b</b></p>\n)
    end

    test "two adjacent node-spelled code inlines stay two <code> elements" do
      {first, second} = reprint([para([code("tr -d '"), code("x")])])

      assert first == ~s(<p id="p"><code>tr -d '</code><code>x</code></p>\n)
      assert second == first
    end

    test "identical-mark siblings are a fixed point, not a merge that re-splits" do
      {first, second} = reprint([para([text("a", ["code"]), text("b", ["code"])])])

      assert first == ~s(<p id="p"><code>a</code><code>b</code></p>\n)
      assert second == first
    end

    test "a shared prefix over runs of DIFFERENT depth still merges" do
      # The discriminator: same prefix, different depth → one <b>. Same prefix,
      # same depth → two <b>. Both are pinned so neither rule can swallow the
      # other.
      content = [text("a", ["strong"]), text("b", ["strong", "code"])]

      assert print([para(content)]) == ~s(<p id="p"><b>a<code>b</code></b></p>\n)
    end
  end

  describe "coalescing does not merge markup that differs" do
    test "different marks stay separate elements" do
      assert print([para([text("a", ["strong"]), text("b", ["em"])])]) ==
               ~s(<p id="p"><b>a</b><i>b</i></p>\n)
    end

    test "the same marks in a different ORDER stay separate — the nesting differs" do
      content = [text("a", ["strong", "em"]), text("b", ["em", "strong"])]

      assert print([para(content)]) == ~s(<p id="p"><b><i>a</i></b><i><b>b</b></i></p>\n)
    end

    test "a link is not swallowed by an open mark run" do
      content = [
        text("a", ["strong"]),
        %{"type" => "link", "href" => "/x", "children" => [text("b")]}
      ]

      assert print([para(content)]) == ~s(<p id="p"><b>a</b><a href="/x">b</a></p>\n)
    end
  end

  describe "the typed refusals survive the rewrite" do
    test "an unknown mark still raises kind :mark" do
      e =
        assert_raise UnprintableError, fn ->
          print([para([text("a", ["blink"])])])
        end

      assert e.kind == :mark
      assert e.type == "blink"
    end

    test "an unknown mark DEEPER in a shared run still raises" do
      e =
        assert_raise UnprintableError, fn ->
          print([para([text("a", ["strong"]), text("b", ["strong", "blink"])])])
        end

      assert e.kind == :mark
      assert e.type == "blink"
    end

    test "a non-list marks value takes the typed refusal instead of crashing to a 500" do
      e =
        assert_raise UnprintableError, fn ->
          print([para([%{"type" => "text", "marks" => "strong", "value" => "a"}])])
        end

      assert e.kind == :mark
    end
  end

  describe "idempotence over the mixed shapes the corpus stores" do
    @shapes [
      {"strong wrapping text + code",
       [
         %{
           "type" => "strong",
           "children" => [
             %{"type" => "text", "value" => "Phase "},
             %{"type" => "code", "value" => "Ping"}
           ]
         }
       ]},
      {"em wrapping code only",
       [%{"type" => "em", "children" => [%{"type" => "code", "value" => "x"}]}]},
      {"two runs with identical marks",
       [
         %{"type" => "text", "marks" => ["strong"], "value" => "a"},
         %{"type" => "text", "marks" => ["strong"], "value" => "b"}
       ]},
      {"strong then plain then strong",
       [
         %{"type" => "text", "marks" => ["strong"], "value" => "a"},
         %{"type" => "text", "marks" => [], "value" => " b "},
         %{"type" => "text", "marks" => ["strong"], "value" => "c"}
       ]},
      {"nested strong/em/code",
       [%{"type" => "text", "marks" => ["strong", "em", "code"], "value" => "a"}]},
      {"link between two runs",
       [
         %{"type" => "text", "marks" => ["strong"], "value" => "a"},
         %{
           "type" => "link",
           "href" => "/x",
           "children" => [%{"type" => "text", "marks" => ["em"], "value" => "b"}]
         },
         %{"type" => "text", "marks" => ["strong"], "value" => "c"}
       ]},
      {"underline and strike runs",
       [
         %{"type" => "text", "marks" => ["underline"], "value" => "a"},
         %{"type" => "text", "marks" => ["strike"], "value" => "b"}
       ]}
    ]

    for {label, content} <- @shapes do
      test "print → parse → print is a fixed point: #{label}" do
        {first, second} = reprint([para(unquote(Macro.escape(content)))])
        assert second == first
      end
    end
  end
end
