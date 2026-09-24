defmodule BarkparkWeb.Studio.LockOnlyRefGuardTest do
  @moduledoc """
  task-b1254cbd3115c3e2 — the in-flight guard keys on the REF, not on the tint.

  WHAT WAS WRONG. The guard shipped by spd-w19-click-loading-falls-through asked
  one question: `event.target.closest(".phx-click-loading, .phx-submit-loading")`.
  That class is CONDITIONAL. In `phoenix_live_view.js`, `putRef` stamps
  `data-phx-ref-src` on every element it is handed BEFORE it decides anything
  else, and only reaches `classList.add("phx-<type>-loading")` on the `loading`
  branch:

      for(let{el:a,lock:l,loading:h}of e){
        if(!l&&!h)throw new Error("putRef requires lock or loading");
        if(a.setAttribute(N,this.refSrc()),      # N = "data-phx-ref-src"
           h&&a.setAttribute(ve,r),              # ve = "data-phx-ref-loading"
           l&&a.setAttribute(C,r),               # C  = "data-phx-ref-lock"
           !h||…)continue;                       # not loading: LEAVE NOW
        …
        a.classList.add(`phx-${i}-loading`);     # only reached when loading

  and `pushLinkPatch` is the one caller whose loading flag can be false:
  `o=e.isTrusted&&e.type!=="popstate"`. An UNTRUSTED click therefore leaves the
  element holding a LOCK-ONLY ref — `data-phx-ref-src` set, no class — and this
  repo makes untrusted clicks itself: BP-PREJOIN-QUEUE replays a queued press
  with `el.click()`.

  The consequence, measured: the next press on that element is dropped (by
  `bindClick`'s `!r.hasAttribute("data-phx-ref-src")` early return, or by
  `bindNav`'s own `preventDefault` + pending-link dedup for a `<.link patch>`),
  and the class-keyed guard cannot see any of it — no swallow, no words, no
  tint. The user gets an inert control with nothing to explain it.

  WHAT THIS FILE CAN AND CANNOT PROVE. It is a SOURCE pin, the same shape and
  for the same reason as `in_flight_activation_guard_test.exs`: charter D241
  puts the "reds when reverted" obligation under `api/test/**`, because
  `scripts/**` dodges the required Elixir gate. The BEHAVIOURAL proof — a real
  Chromium, the shipped `phoenix.js` + `phoenix_live_view.js`, a real
  `LiveSocket`, the ref produced by the vendor's own `putRef` on a real
  `pushLinkPatch`, a trusted control beside every untrusted reading, and two
  mutations — is `scripts/studio-lockonly-ref-control.mjs --self-test` against
  `scripts/fixtures/studio-lockonly-ref.html`.

  IT ALSO PINS THE PREMISE, NOT ONLY THE FIX. The whole argument for the new key
  rests on two properties of the VENDOR bundle, so those are asserted here
  directly against `api/priv/static/assets/phoenix_live_view.js`. A LiveView
  bump that changed either one would otherwise leave a guard whose comment is
  the only thing still claiming the ref is unconditional.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)
  @lv_js Path.expand("../../../priv/static/assets/phoenix_live_view.js", __DIR__)

  defp sheet, do: File.read!(@root)
  defp vendor, do: File.read!(@lv_js)

  # THE PRECONDITION, ASSERTED RATHER THAN ASSUMED. Every test below reads a
  # slice of the guard out of the fence; if the fence is gone, a `String.contains?`
  # against the whole 6000-line layout could still pass on unrelated prose.
  defp guard_body do
    lines = String.split(sheet(), "\n")
    b = Enum.find_index(lines, &(String.trim(&1) == "// BP-INFLIGHT-GUARD-BEGIN"))
    e = Enum.find_index(lines, &(String.trim(&1) == "// BP-INFLIGHT-GUARD-END"))

    assert is_integer(b) and is_integer(e) and e > b,
           "no well-formed BP-INFLIGHT-GUARD fence in root.html.heex (begin=#{inspect(b)}, " <>
             "end=#{inspect(e)}) — every assertion in this file would then be reading the wrong text"

    lines |> Enum.slice((b + 1)..(e - 1)) |> Enum.join("\n")
  end

  describe "the premise: in the shipped LiveView client the ref is unconditional and the class is not" do
    test "putRef stamps data-phx-ref-src before the not-loading early exit" do
      # The `!h||` is the load-bearing character: it is the early exit taken
      # when `loading` is false, and it sits AFTER the ref-src setAttribute and
      # BEFORE classList.add.
      assert String.contains?(
               vendor(),
               ~S|if(a.setAttribute(N,this.refSrc()),h&&a.setAttribute(ve,r),l&&a.setAttribute(C,r),!h|
             ),
             "putRef no longer stamps data-phx-ref-src unconditionally ahead of the not-loading " <>
               "exit. The guard's second arm is keyed on that attribute precisely because it " <>
               "cannot be absent when the class is present; if this shape changed, re-derive the " <>
               "key rather than trusting the comment in root.html.heex."
    end

    test "putRef adds the phx-*-loading class only on the loading branch" do
      assert String.contains?(vendor(), ~S|a.classList.add(`phx-${i}-loading`)|),
             "the class this guard used to be keyed on is no longer added by putRef at all"
    end

    test "pushLinkPatch passes a loading flag that is false for an untrusted click" do
      assert String.contains?(
               vendor(),
               ~S|o=e.isTrusted&&e.type!=="popstate",a=i?()=>this.putRef([{el:i,loading:o,lock:!0}]|
             ),
             "pushLinkPatch no longer derives its loading flag from isTrusted, so the lock-only " <>
               "ref this guard arm exists for may no longer be producible on that path"
    end

    test "bindClick still drops a press on an element that already holds a ref" do
      assert String.contains?(vendor(), ~S|!r.hasAttribute(N)&&this.debounce(r,n,"click"|),
             "bindClick's early return is the drop the guard is announcing; without it the " <>
               "second press is not dropped and the guard would be announcing a fiction"
    end

    test "SABOTAGE CONTROL — the vendor checks can fail" do
      broken = String.replace(vendor(), ~S|!r.hasAttribute(N)&&this.debounce(r,n,"click"|, "")

      refute String.contains?(broken, ~S|!r.hasAttribute(N)&&this.debounce(r,n,"click"|),
             "this check cannot fail, so it is not a check"
    end
  end

  describe "the guard's second arm" do
    test "the class arm is kept — the loading case it already covered must not regress" do
      assert String.contains?(
               guard_body(),
               ~S|var blocked = t.closest(".phx-click-loading, .phx-submit-loading");|
             ),
             "the class arm was removed rather than joined; a loading ref on a container " <>
               "(a form carrying phx-submit-loading) is covered by the class and not by the " <>
               "activation-target arm"
    end

    test "the ref arm is present and reads the ref off the element the press would activate" do
      body = guard_body()

      assert String.contains?(
               body,
               ~S|var activated = t.closest("[phx-click], [data-phx-link]");|
             ),
             "the guard does not resolve the ACTIVATION TARGET. Keying on a bare " <>
               "[data-phx-ref-src] would blanket-block the desk: #studio-panes " <>
               "(the pane_layout in studio_live/components.ex, phx_hook=\"WidthBucket\") carries a " <>
               "container ref of its own " <>
               "from the hook's mount push, so closest() would succeed for every press anywhere " <>
               "inside it — measured as the `bare [data-phx-ref-src] key` mutation arm in " <>
               "scripts/studio-lockonly-ref-control.mjs."

      assert String.contains?(
               body,
               ~S|if (activated && activated.hasAttribute("data-phx-ref-src")) blocked = activated;|
             ),
             "the guard resolves an activation target but does not test its ref, so a lock-only " <>
               "ref is still invisible to it"
    end

    test "the ref arm is keyed on the ref, never on a second class" do
      body = guard_body()

      assert String.contains?(body, "data-phx-ref-src"),
             "the guard body names no ref attribute at all, so the check below would pass " <>
               "vacuously on a guard that has no second arm"

      refute Regex.match?(
               ~r/closest\("\[phx-click\], \[data-phx-link\]"\).*phx-\w+-loading/s,
               body
             ),
             "the activation-target arm reached for another conditional class; the point of this " <>
               "change is that the ref cannot be absent in the circumstances the class is"
    end

    test "SABOTAGE CONTROL — the ref-arm checks can fail" do
      lines = String.split(sheet(), "\n")
      b = Enum.find_index(lines, &(String.trim(&1) == "// BP-INFLIGHT-GUARD-BEGIN"))
      e = Enum.find_index(lines, &(String.trim(&1) == "// BP-INFLIGHT-GUARD-END"))
      reverted = lines |> Enum.slice((b + 1)..(e - 1)) |> Enum.join("\n")

      reverted =
        String.replace(
          reverted,
          ~S|var activated = t.closest("[phx-click], [data-phx-link]");|,
          ""
        )

      refute String.contains?(
               reverted,
               ~S|var activated = t.closest("[phx-click], [data-phx-link]");|
             ),
             "this check cannot fail, so it is not a check"
    end
  end

  describe "the behavioural control is named from the code it proves" do
    test "root.html.heex points a reader at the control that measured this" do
      assert String.contains?(sheet(), "scripts/studio-lockonly-ref-control.mjs"),
             "the guard's comment must name the instrument, or the next reader re-derives the " <>
               "whole finding from prose"
    end

    test "the control and its fixture are committed" do
      repo = Path.expand("../../../..", __DIR__)

      for rel <- [
            "scripts/studio-lockonly-ref-control.mjs",
            "scripts/fixtures/studio-lockonly-ref.html"
          ] do
        assert File.exists?(Path.join(repo, rel)), "#{rel} is missing"
      end
    end
  end
end
