defmodule BarkparkWeb.Studio.InFlightActivationGuardTest do
  @moduledoc """
  spd-w19-click-loading-falls-through — the in-flight guard, pinned so a revert
  REDS OFFLINE.

  WHAT WAS WRONG. The shipped in-flight guard was one CSS declaration:
  `.phx-click-loading, .phx-submit-loading { pointer-events: none; opacity: .6 }`.
  `pointer-events: none` does not swallow a second press — it removes the
  in-flight element from HIT TESTING, so the press is delivered to whatever
  sits underneath. Wherever an in-flight control overlaps a DIFFERENT
  `phx-click` element (stacked rows, a header action over a row, an overlay),
  an impatient second press fires a server event the user never aimed at, and
  neither LiveView nor the press-answer hook can see it — the press never
  reaches the intended element at all.

  THE SHAPE THAT REPLACED IT (lead ruling, 2026-09-06): a DOCUMENT, CAPTURE
  phase click listener that calls `preventDefault` + `stopImmediatePropagation`
  when `event.target.closest(".phx-click-loading, .phx-submit-loading")` is
  non-null. The element stays in the hit test and the ACTIVATION is swallowed,
  so the worst case is a press that goes nowhere rather than a press that goes
  somewhere wrong. `opacity: .6` stays as the visual only. `phx-disable-with`
  is banned by charter D225 and this file pins that too.

  WHAT THIS FILE CAN AND CANNOT PROVE. It is a SOURCE pin: it asserts the two
  halves of the guard are in `root.html.heex` in the shape that was measured,
  and every assertion carries a SABOTAGE CONTROL so no check here is one whose
  failure has never been observed. It proves NOTHING about hit testing or event
  order — a browser is the only instrument for that, and the behavioural proof
  (a real overlap, a real second press, the wrong frame named, and the mutation
  in both directions) lives in `scripts/studio-inflight-guard-control.mjs`
  against `scripts/fixtures/studio-inflight-overlap.html`. This file exists
  because charter D241 requires the "reds when reverted" obligation to be
  carried under `api/test/**`: `scripts/**` and `tooling/**` dodge the required
  Elixir gate.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  defp sheet, do: File.read!(@root)

  describe "the visual half no longer removes the element from hit testing" do
    test "the .phx-click-loading rule carries opacity and NOT pointer-events" do
      [rule] =
        Regex.run(~r/^[ \t]*\.phx-click-loading,\s*\.phx-submit-loading\s*\{[^}]*\}/m, sheet())

      assert String.contains?(rule, "opacity: 0.6"),
             "the dim is the whole visual half of the guard: #{rule}"

      refute String.contains?(rule, "pointer-events"),
             "pointer-events on the in-flight rule is the fall-through itself — a second press " <>
               "is delivered to whatever sits underneath: #{rule}"
    end

    test "SABOTAGE CONTROL — the pointer-events check can fail" do
      restored =
        String.replace(
          sheet(),
          ".phx-click-loading, .phx-submit-loading { opacity: 0.6; }",
          ".phx-click-loading, .phx-submit-loading { pointer-events: none; opacity: 0.6; }"
        )

      [rule] =
        Regex.run(~r/^[ \t]*\.phx-click-loading,\s*\.phx-submit-loading\s*\{[^}]*\}/m, restored)

      assert String.contains?(rule, "pointer-events"),
             "this check cannot fail, so it is not a check"
    end
  end

  describe "the blocking half is fenced, and the fence is what the control reads" do
    test "exactly one BP-INFLIGHT-GUARD fence, well formed" do
      lines = String.split(sheet(), "\n")
      begins = Enum.count(lines, &(String.trim(&1) == "// BP-INFLIGHT-GUARD-BEGIN"))
      ends = Enum.count(lines, &(String.trim(&1) == "// BP-INFLIGHT-GUARD-END"))

      assert begins == 1,
             "scripts/studio-inflight-guard-control.mjs extracts the guard by this fence; " <>
               "#{begins} begin markers means it can no longer read the shipped code"

      assert ends == 1, "#{ends} end markers"
    end
  end

  # {short label, literal, why it is load-bearing}
  @guard_seam [
    {"the document listener", ~S|document.addEventListener("click", function (ev) {|,
     "DOCUMENT, not the desk root: the CSS rule this replaces was global, so a desk-scoped guard would leave the tab strip, the top bar, forms and the Papers editor with no re-fire protection at all"},
    {"the capture flag", ~S|}, true);|,
     "LiveView binds its own click on window in the BUBBLE phase (live_socket.js:830-833); only a capture listener runs first, and only then can it stop the event"},
    {"the in-flight test",
     ~S|var blocked = t.closest(".phx-click-loading, .phx-submit-loading");|,
     "the element stays in the hit test — this closest() is what identifies the press as one aimed at an in-flight control"},
    {"the propagation stop", ~S|ev.stopImmediatePropagation();|,
     "stopImmediatePropagation ends the event for every later listener in any phase, which is what makes the wrong server event impossible rather than merely unlikely"},
    {"the default-action stop", ~S|ev.preventDefault();|,
     "a swallowed press must not take the default action either — a link navigation, a checkbox toggle, an implicit form submit — all of which pointer-events:none also suppressed"},
    {"the words", ~S|var say = "Still working on your last press — that one was not sent.";|,
     "this guard now runs BEFORE the press-answer hook's bubble listener, so without it the hook's named discard (D263) would silently become silence again"}
  ]

  for {label, literal, why} <- @guard_seam do
    test "present: #{label}" do
      assert String.contains?(sheet(), unquote(literal)),
             "the in-flight guard lost #{unquote(label)}: #{unquote(why)}"
    end

    test "SABOTAGE CONTROL — #{label} check can fail" do
      sabotaged = String.replace(sheet(), unquote(literal), "")

      refute String.contains?(sabotaged, unquote(literal)),
             "this check cannot fail, so it is not a check: #{unquote(why)}"
    end
  end

  describe "charter D225 — phx-disable-with stays banned" do
    # The BARE NAME appears twice in this layout, both times in prose explaining
    # why it is not used. What D225 bans is the ATTRIBUTE, so that is what this
    # asserts — a `phx-disable-with=` anywhere in the sheet.
    test "the layout never reaches for the phx-disable-with attribute" do
      refute sheet() =~ ~r/phx-disable-with=/,
             "D225 bans phx-disable-with; the in-flight answer is the capture guard plus #bp-press-answer"
    end

    test "SABOTAGE CONTROL — the phx-disable-with check can fail" do
      assert String.replace(sheet(), "<body", ~s(<body phx-disable-with="…"), global: false) =~
               ~r/phx-disable-with=/,
             "this check cannot fail, so it is not a check"
    end
  end
end
