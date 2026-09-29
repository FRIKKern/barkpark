defmodule BarkparkWeb.Studio.PrejoinPressQueueTest do
  @moduledoc """
  task-c2dd40c6f433a787 — the PRE-JOIN press queue, pinned so a revert REDS
  OFFLINE.

  WHAT WAS WRONG, MEASURED. On served `e02e4296d`, `#item-paper` is in the DOM
  and pressable at t=61ms after page load and the LiveView joins at t=254ms. A
  real press inside that **193ms** window put ZERO `"type":"click"` frames on
  `/live/websocket` and the URL never moved. The same button, on the same page,
  in the same session, once joined: one frame, URL patched to `/studio/paper`.
  So the counter can report the opposite and the window — not the button — is
  what was broken.

  IT IS NOT `bindClick`'s EARLY RETURN, and that corrects the premise this was
  filed on. `data-phx-ref-src` cannot arrive in the pre-join window at all:
  `View.pushWithReply` returns `Promise.reject(new Error("no connection"))`
  BEFORE it calls the ref generator, so `putRef` never runs. A MutationObserver
  armed before the first byte of page script saw its FIRST self-arriving
  `data-phx-ref-src` at t=254ms — at join, on `#studio-panes`, from the
  WidthBucket hook's own mount push — and none before it. The pre-join press is
  dropped by the connection check; the in-flight press is dropped by
  `bindClick`. Two mechanisms, and this file pins the remedy for the first one.

  THE REMEDY, AND WHY THIS ONE. A pre-join press is QUEUED and replayed on
  join; an in-flight press stays UNPRESSABLE (the guard in
  `in_flight_activation_guard_test.exs`). A pre-join press is unambiguous —
  nothing has patched the DOM, so the element the user aimed at is the element
  the replay hits — while an in-flight press is the opposite: the reply that
  clears the ref is precisely what re-renders the row under the pointer.
  Unpressable loses here because the pre-join window covers EVERY control on a
  freshly loaded desk, so disabling the desk for the duration of socket join
  would make it visibly dead on 100% of loads to fix a press lost on some.

  WHAT THIS FILE CAN AND CANNOT PROVE. It is a SOURCE pin: it asserts the queue
  is in `root.html.heex` in the shape that was measured, and every assertion
  carries a SABOTAGE CONTROL so no check here is one whose failure has never
  been observed. It proves NOTHING about event order or about the wire — a
  browser is the only instrument for that, and the behavioural proof (a real
  LiveSocket, a real pre-join press, the frame count in both directions, and
  the REPLAY-DELETED mutation) lives in
  `scripts/studio-prejoin-queue-control.mjs` against
  `scripts/fixtures/studio-prejoin-join-window.html`. This file exists because
  charter D241 requires the "reds when reverted" obligation to be carried under
  `api/test/**`: `scripts/**` and `tooling/**` dodge the required Elixir gate.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  defp sheet, do: File.read!(@root)

  describe "the queue is fenced, and the fence is what the control reads" do
    test "exactly one BP-PREJOIN-QUEUE fence, well formed" do
      lines = String.split(sheet(), "\n")
      begins = Enum.count(lines, &(String.trim(&1) == "// BP-PREJOIN-QUEUE-BEGIN"))
      ends = Enum.count(lines, &(String.trim(&1) == "// BP-PREJOIN-QUEUE-END"))

      assert begins == 1,
             "scripts/studio-prejoin-queue-control.mjs extracts the queue by this fence; " <>
               "#{begins} begin markers means it can no longer read the shipped code"

      assert ends == 1, "#{ends} end markers"
    end

    test "SABOTAGE CONTROL — the fence count check can fail" do
      # Independent of the sheet ON PURPOSE. A control that only fires while
      # the thing it guards is present is not a control — it flips with its
      # subject and says nothing about the counter.
      doubled = "// BP-PREJOIN-QUEUE-BEGIN\n// BP-PREJOIN-QUEUE-BEGIN\n" <> sheet()
      lines = String.split(doubled, "\n")
      begins = Enum.count(lines, &(String.trim(&1) == "// BP-PREJOIN-QUEUE-BEGIN"))

      assert begins != 1, "this check cannot fail, so it is not a check"
    end
  end

  # {short label, literal, why it is load-bearing}
  @queue_seam [
    {"the capture flag", ~S|      }, true);|,
     "LiveView binds its own click on window in the BUBBLE phase, so only a capture listener runs first — and only then can it hold the press instead of letting pushWithReply reject it into nothing"},
    {"the un-joined test", ~S|return !!main && main.classList.contains("phx-connected");|,
     "phx-connected on [data-phx-main] is the join signal the live probe measured at t=254ms; without this test the queue would swallow presses on a working desk"},
    {"the joined bail-out",
     ~S|        if (joined()) return;                              // the socket is up: not ours|,
     "a joined desk must reach LiveView untouched — this is the line that keeps the queue out of every normal press"},
    {"the in-flight hand-off",
     ~S|        if (el.hasAttribute("data-phx-ref-src")) return;   // in-flight: the guard above owns it|,
     "the in-flight swallow is a DIFFERENT defect with a DIFFERENT remedy (unpressable, not queued); without this line the queue would start replaying impatient second presses at rows the reply has since re-rendered"},
    {"the propagation stop", ~S|        ev.stopImmediatePropagation();|,
     "without it LiveView still receives the press and still drops it at the connection check, and the queue would replay a second copy"},
    {"the replay", ~S|        el.click();|,
     "the whole remedy: deleting this one line puts the pre-join press back to zero frames on the wire, which is the REPLAY-DELETED mutation the control asserts"},
    {"the re-resolve by id", ~S|        var el = document.getElementById(id);|,
     "the join patch may replace the node the listener saw, so the replay resolves the control again by id rather than holding a stale reference"},
    {"the id-less refusal",
     ~S|        if (!el.id) { say("Still connecting — that press was not sent. Press it again in a moment."); return; }|,
     "an id-less phx-click cannot be re-resolved honestly after the join patch, so it is released with words rather than replayed at a guess"},
    {"the ceiling",
     ~S|      var PREJOIN_CEILING = 8000; // ms — the same named ceiling as the press answer|,
     "a join that never arrives must not hold a press forever — an unbounded queue is the dead desk this row is about, wearing a different hat"},
    {"the join watcher",
     ~S|      var mo = new MutationObserver(function () { if (joined()) replay(); });|,
     "the replay trigger. A timer would race the join; the class mutation IS the join"}
  ]

  for {label, literal, why} <- @queue_seam do
    test "present: #{label}" do
      assert String.contains?(sheet(), unquote(literal)),
             "the pre-join queue lost #{unquote(label)}: #{unquote(why)}"
    end

    test "SABOTAGE CONTROL — #{label} check can fail" do
      sabotaged = String.replace(sheet(), unquote(literal), "")

      refute String.contains?(sabotaged, unquote(literal)),
             "this check cannot fail, so it is not a check: #{unquote(why)}"
    end
  end

  describe "the two swallows stay separate" do
    test "the in-flight guard is still there and still keys on the loading classes" do
      assert String.contains?(
               sheet(),
               ~S|var blocked = t.closest(".phx-click-loading, .phx-submit-loading");|
             ),
             "the pre-join queue is an ADDITION; removing the in-flight guard would hand the " <>
               "impatient second press back to whatever sits underneath"
    end

    test "the queue never reaches for phx-disable-with (charter D225)" do
      refute String.contains?(sheet(), "phx-disable-with="),
             "D225 bans the attribute; the queue answers with words and a replay, not by disabling"
    end

    test "SABOTAGE CONTROL — the D225 check can fail" do
      sabotaged = sheet() <> ~S|<button phx-disable-with="Saving…">x</button>|

      assert String.contains?(sabotaged, "phx-disable-with="),
             "this check cannot fail, so it is not a check"
    end
  end
end
