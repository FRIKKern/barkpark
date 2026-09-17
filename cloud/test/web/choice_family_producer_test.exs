defmodule BarkparkCloud.Web.ChoiceFamilyProducerTest do
  @moduledoc """
  THE `.choice*` FAMILY IN `cloud/priv/static/app.css` HAS A PRODUCER, OR IT IS
  NOT THERE.

  cch-w26-s4 deleted `openProviderPicker()` — its only forward caller,
  `#cred-back`, was rewired to the launch wizard. That function was the ONLY
  producer of `.choice-list`, `.choice`, `.choice-main`, `.choice-name`,
  `.choice-sub`, `.choice-chev` and `.choice-tag`. `app.css` was outside that
  slice's file fence, so eleven rules outlived their markup for a whole epic and
  nothing measured it: `__css_check.mjs`'s E2 runs the OTHER direction (a class
  EMITTED with no rule). Its headline "N classes checked" is a count of EMITTED
  classes, so it cannot move when a CSS rule is deleted — a green there is a
  green with no subject for this defect. This test is the missing direction.

  IT IS A PREDICATE, NOT A DELETE LIST. The heads are DERIVED from the
  stylesheet on every run, so a `.choice-whatever` added tomorrow with no
  markup reds here without anyone editing this file. Equally, a retired head
  that comes BACK together with real markup is fine — having a producer is the
  whole rule.

  ONE MEMBER OF THE FAMILY IS LIVE AND MUST STAY: `.choice-ico` (and
  `.choice-ico.sm`, and the `.modal-head .choice-ico` size override) paints
  through `openProviderCredential()`'s modal-head tile and the providers roster
  mini-tile, and both `choice-ico` entries in `__css_check.mjs`'s
  ALLOW_PREFIXES are earned by exactly those two emission sites. Deleting it
  with its dead siblings is the mistake this row could most easily make, so
  that is asserted too, in both directions.

  PROSE IS NOT A PRODUCER. The bare token `choice` occurs 16 times in `app.js`
  and every one is comment text ("a view choice, not a…"). A raw `grep -c` over
  the file therefore reports the dead family as live. The scan below reads only
  STRING LITERALS in comment-stripped `app.js` and `class="…"` attribute values
  in the HTML surfaces.

  Pure file reading — no DB, no router.
  """
  use ExUnit.Case, async: true

  @static Path.expand("../../priv/static", __DIR__)

  # ── the predicate, as pure functions so the self-test below can drive it ──

  @doc false
  def strip_css_comments(css), do: Regex.replace(~r|/\*.*?\*/|s, css, " ")

  @doc false
  def declared_heads(css) do
    css
    |> strip_css_comments()
    |> then(&Regex.scan(~r/\.(choice[a-z0-9-]*)/, &1))
    |> Enum.map(fn [_, head] -> head end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  def js_string_literals(js) do
    js
    |> then(&Regex.replace(~r|/\*.*?\*/|s, &1, " "))
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r|^\s*//|, &1))
    |> Enum.join("\n")
    |> then(&Regex.scan(~r/"([^"\n]*)"|'([^'\n]*)'/, &1))
    |> Enum.map(fn
      [_, a] -> a
      [_, a, ""] -> a
      [_, "", b] -> b
      [_, a, _] -> a
    end)
  end

  @doc false
  def html_class_values(html) do
    ~r/class="([^"]*)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, v] -> v end)
  end

  @doc false
  def producer_count(head, pools) do
    rx = Regex.compile!("(^|[^a-z0-9_-])" <> Regex.escape(head) <> "([^a-z0-9_-]|$)")
    Enum.count(pools, &Regex.match?(rx, &1))
  end

  @doc false
  def census(css, pools) do
    for head <- declared_heads(css), into: %{}, do: {head, producer_count(head, pools)}
  end

  # ── the live tree ──────────────────────────────────────────────────────────

  defp read!(name), do: File.read!(Path.join(@static, name))

  defp live_css, do: read!("app.css")

  defp live_pools do
    js_string_literals(read!("app.js")) ++
      html_class_values(read!("index.html")) ++
      html_class_values(read!("styleguide.html"))
  end

  test "every .choice* rule in app.css has at least one producer" do
    c = census(live_css(), live_pools())
    dead = c |> Enum.filter(fn {_, n} -> n == 0 end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    assert dead == [],
           "unproduced .choice* rule(s) in cloud/priv/static/app.css: " <>
             Enum.map_join(dead, ", ", &(". " <> &1)) <>
             ". Nothing in app.js's string literals or the HTML class attributes " <>
             "emits them, so they paint nothing. Either ship the markup that " <>
             "produces them, or delete the rules. Full census: #{inspect(c)}"
  end

  test "POSITIVE CONTROL — .choice-ico is still declared and still produced" do
    c = census(live_css(), live_pools())

    assert Map.has_key?(c, "choice-ico"),
           "`.choice-ico` is gone from app.css. It is the ONE live member of the " <>
             "family — openProviderCredential()'s modal-head tile and the providers " <>
             "roster mini-tile both emit it, and __css_check.mjs's two `choice-ico` " <>
             "ALLOW_PREFIXES entries are earned by them (E19 reds on a waiver that " <>
             "absolves nothing). Removing it with its dead siblings is the mistake. " <>
             "Census: #{inspect(c)}"

    assert c["choice-ico"] > 0,
           "the producer scan found ZERO emission sites for `.choice-ico`. Either " <>
             "the markup was deleted, or this scan has gone blind — in which case " <>
             "the test above passes over a family it can no longer see. Census: " <>
             "#{inspect(c)}"
  end

  test "SELF-TEST — the predicate reds on a dead head and stays quiet on a live one" do
    css = ".choice-ghost { color: red; }\n.choice-ico { color: blue; }\n"
    pools = ["modal-head", "choice-ico brand-hetzner"]

    assert census(css, pools) == %{"choice-ghost" => 0, "choice-ico" => 1},
           "the predicate cannot tell a dead head from a live one on a two-rule " <>
             "fixture, so its verdict on app.css means nothing."
  end

  test "SELF-TEST — a head named only in a CSS COMMENT is not a declaration" do
    css =
      "/* the retired .choice-list head is named here, in prose */\n.choice-ico { color: blue; }\n"

    assert declared_heads(css) == ["choice-ico"],
           "comment text is being read as a selector. The tombstone comment above " <>
             "the .choice-ico block names every head it retired, so this would red " <>
             "the whole suite on a file that is correct."
  end

  test "SELF-TEST — prose in app.js is not a producer" do
    js = ~S|// folding is a view choice, not a policy
const x = "choice-ico sm";
|
    pools = js_string_literals(js)

    assert producer_count("choice", pools) == 0,
           "a comment mentioning the word `choice` counted as a producer — that is " <>
             "the raw-grep failure this scan exists to avoid (16 such hits in app.js)."

    assert producer_count("choice-ico", pools) == 1,
           "the string-literal extractor missed a real emission site."
  end
end
