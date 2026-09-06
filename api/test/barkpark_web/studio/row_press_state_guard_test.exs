defmodule BarkparkWeb.Studio.RowPressStateGuardTest do
  @moduledoc """
  The PRESSED ROW carries a named pending state of its own — pinned so a revert
  REDS OFFLINE, in the required Elixir gate.

  WHAT ALREADY SHIPPED, and what this file does NOT re-prove. spd-w19 (charter
  D263/D265) put `#bp-press-answer` on the page: a `role="status"
  aria-live="polite"` region written by the delegated listener in
  `Hooks.WidthBucket`, with a 16 ms no-ref probe and an 8 s named ceiling. That
  is guarded by `press_answer_region_guard_test.exs` and
  `in_flight_activation_guard_test.exs` and is untouched here.

  WHAT THIS FILE GUARDS. That announcement is PAGE-level. A screen-reader user
  is told what happened; a sighted user looking at the pressed Structure row
  still saw only `.phx-click-loading{opacity:0.6}` — the wordless grey wash the
  repo owner read as a dead control. So the hook now stamps `aria-busy="true"`
  on the pressed control itself and `#studio-panes [aria-busy="true"]` gives it
  a moving progress bar. Two halves, and BOTH are asserted: the state (what
  assistive tech reports and what a test can name) and the paint (what the eye
  gets).

  THE TWO ARMS, AND WHY THEY ARE STRUCTURAL AND NOT A `grep`. A press state is
  only worth anything if it is SET on press and CLEARED on every way the press
  can end — including the ways that are not a success. So the predicates are
  bound to the two functions that own that lifecycle:

    * ARM 1 — the set lives inside `_paOnPress`. Mutation: delete it. The
      pressed row is never marked, and `sets the state on press` reds.
    * ARM 2 — the clear lives inside `_paRelease`, which is the SINGLE release
      path (settle, ref-drop, detach, the 16 ms refusal, the 8 s ceiling,
      pagehide, destroyed all funnel through it). Two mutations: delete it, and
      — the one that matters — MOVE it into `_paSettle`. Moving it keeps the
      literal in the file, so a whole-sheet `grep` stays green while a REFUSED
      press is left stuck busy forever. `clears the state on release` reds on
      both.

  Deliberately NOT asserted: ref timing, real AT output, or that the bar is
  visible to a human eye. Those need a real LiveSocket and a real browser and
  are the deployed proof's job.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)
  @dataset "production"
  @admin_token "row-press-state-guard-admin-token"

  @set ~S|p.el.setAttribute("aria-busy", "true");|
  @clear ~S|if (prev && prev.el) prev.el.removeAttribute("aria-busy");|

  defp sheet, do: File.read!(@root)

  # The body of one member of the WidthBucket hook object. Members sit at exactly
  # six spaces of indentation and every line inside a body is deeper, so the next
  # six-space member name is an exact terminator — no brace counting, and no way
  # for a nested `this._paX` reference to end the slice early.
  defp member_body(s, name) do
    case String.split(s, "      #{name}", parts: 2) do
      [_, rest] ->
        Regex.split(~r/\n      (?:_pa[A-Za-z_]+|_PA_[A-Z_]+|mounted|destroyed)/, rest, parts: 2)
        |> hd()

      _ ->
        flunk(
          "`#{name}` is gone from the layout — the press lifecycle this guard pins no longer exists"
        )
    end
  end

  # ARM 1: is the pending state SET on the pressed element, inside _paOnPress?
  defp sets_on_press?(s), do: String.contains?(member_body(s, "_paOnPress(ev) {"), @set)

  # ARM 2: is it CLEARED inside _paRelease — the one path every ending shares?
  defp clears_on_release?(s), do: String.contains?(member_body(s, "_paRelease(text) {"), @clear)

  describe "the pressed row carries the state (ARM 1: set on press)" do
    test "the hook stamps aria-busy on the pressed control" do
      assert sets_on_press?(sheet()),
             "the pressed row carries no state of its own — a sighted user is back to the grey `.phx-click-loading` tint the owner read as a dead control"
    end

    test "MUTATION — delete the set: `sets the state on press` reds" do
      mutant = String.replace(sheet(), @set, "")

      refute sets_on_press?(mutant),
             "this check cannot lose, so it is not a check: a build that never marks the pressed row must red here"
    end
  end

  describe "the state clears on EVERY ending (ARM 2: cleared on release)" do
    test "the clear lives in _paRelease, the single release path" do
      assert clears_on_release?(sheet()),
             "nothing clears aria-busy — a pressed row would stay busy forever, which is worse than the tint it replaced"
    end

    test "MUTATION — delete the clear: `clears the state on release` reds" do
      mutant = String.replace(sheet(), @clear, "")

      refute clears_on_release?(mutant),
             "this check cannot lose, so it is not a check"
    end

    test "MUTATION — MOVE the clear into _paSettle: still reds, though the literal survives" do
      # The dangerous shape, and the reason this guard is not a whole-sheet grep:
      # a clear that runs only on a happy settle leaves a REFUSED press (16 ms
      # no-ref, or the 8 s ceiling) stuck busy — while the literal is still in
      # the file, so `sheet() =~ @clear` would stay green.
      moved =
        sheet()
        |> String.replace(@clear, "")
        |> String.replace(
          "      _paSettle(p) {\n        var word = this._paSettleWord(p);",
          "      _paSettle(p) {\n        #{@clear}\n        var word = this._paSettleWord(p);"
        )

      assert String.contains?(moved, @clear),
             "the mutation did not apply — the literal must survive, that is the whole point of this arm"

      refute clears_on_release?(moved),
             "the check is satisfied by the literal existing ANYWHERE, so a refused press left stuck busy would ship green"
    end
  end

  describe "the sighted half is painted, and it is additive" do
    test "the busy row gets a MOVING bar, not another static tint" do
      s = sheet()

      assert String.contains?(s, ~S|#studio-panes [aria-busy="true"]::after|),
             "the state is invisible to a sighted user — the row-level half of the fix is gone"

      assert String.contains?(s, "@keyframes bp-row-busy"),
             "a still mark is exactly what the owner already reads as dead; the paint must move"

      assert String.contains?(s, ".phx-click-loading, .phx-submit-loading { opacity: 0.6; }"),
             "this adds a row state, it does not remove LiveView's own in-flight tint"
    end

    test "reduced motion still gets a CHANGE, not a hidden bar" do
      s = sheet()

      assert s =~
               ~r/prefers-reduced-motion: reduce\)\s*\{\s*#studio-panes \[aria-busy="true"\]::after \{\s*animation: none; transform: scaleX\(1\)/,
             "`animation: none` alone leaves the bar at scaleX(0) — invisible, which hands reduced-motion users the dead control back"
    end
  end

  describe "it actually ships in the served page" do
    setup %{conn: conn} do
      {:ok, _} =
        Auth.create_token(@admin_token, "row press state guard admin", @dataset, [
          "read",
          "write",
          "admin"
        ])

      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "an authenticated desk GET carries both halves of the row state", %{conn: conn} do
      html =
        conn
        |> get(scoped_studio("/d/#{@dataset}/studio"))
        |> html_response(200)

      assert html =~ ~S|#studio-panes [aria-busy="true"]::after|,
             "the busy paint is not in the served sheet, so no desk press can show it"

      assert html =~ @set,
             "the hook that stamps the row state is not in the served page"

      assert html =~ @clear,
             "the hook that clears the row state is not in the served page"
    end
  end
end
