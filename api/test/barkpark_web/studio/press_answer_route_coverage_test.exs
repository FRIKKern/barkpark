defmodule BarkparkWeb.Studio.PressAnswerRouteCoverageTest do
  @moduledoc """
  task-66807dd8154e667d — the press answer must be INSTALLED on every Studio
  route that SERVES its region.

  THE DEFECT THIS PINS. `#bp-press-answer` (spd-w19 / charter D263) lives in
  `root.html.heex`, a sibling of `{@inner_content}`, so EVERY page rendered
  through that root layout serves it. The listener that writes to it used to
  ride `Hooks.WidthBucket`, whose element is `#studio-panes` — and
  `#studio-panes` has exactly one render site in the tree
  (`StudioLive.Components`, `<.pane_layout id="studio-panes"
  phx_hook="WidthBucket">`). `…/studio/media` and `…/studio/api-tester` are
  their own LiveViews and render no pane row, so the hook never mounted there
  and the press answer was never installed, while the region, the whole
  `.studio-bar` and its 10 `.studio-tab` anchors were served in full.

  That is the shape this lane keeps finding: an artefact asserting a property
  the code lacks. Here the false claim is made by an ELEMENT. A reader of the
  HTML sees a `role="status" aria-live="polite"` region and concludes the
  surface is covered; a census that greps the served body for the region counts
  it as present. Both are right about the markup and wrong about the behaviour.

  MEASURED, not inferred, before the fix — deployed guerrilla, served
  `e02e4296d`, authenticated served bodies, `phx-hook` enumerated over markup
  with `<script>`/`<style>`/comments stripped (the inline layout script MENTIONS
  `studio-panes` and `bp-press-answer` in prose, so a raw-body grep reports
  TRUE on the very routes that lack the element):

      …/d/production/studio            4 hooks  EditorFocus, PresenceIdentity,
                                                ThemeToggle,
                                                WidthBucket#studio-panes   CONTROL
      …/d/production/studio/media      1 hook   ThemeToggle only
      …/d/production/studio/api-tester 1 hook   ThemeToggle only

  The CONTROL is what makes the one-element sets a measurement rather than a
  probe that listed nothing.

  THE REMEDY PINNED HERE. The press answer is its own hook, `Hooks.PressAnswer`,
  mounted on `<div class="studio-bar" id="studio-bar" phx-hook="PressAnswer">`
  (`Nav.studio_topbar/1`) — the one piece of Studio chrome every Studio route
  renders INSIDE its LiveView root. `WidthBucket` keeps the width half.

  WHAT THIS FILE DOES NOT CLAIM. It does not prove the region SPEAKS. That
  needs a real LiveSocket stamping real refs and is the deployed proof's job
  (`press_answer_region_guard_test.exs` draws the same line). What it proves is
  the thing that was false: on these routes something is now LISTENING, and the
  installer is not gated on a pane row they do not have.
  """
  use BarkparkWeb.ConnCase, async: false

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)
  @dataset "production"
  @admin_token "press-answer-route-coverage-admin-token"

  # The desk is the CONTROL: it has always installed the press answer, so it is
  # the arm that proves the enumeration below can report a hook at all.
  @control {"the desk (CONTROL)", "/d/#{@dataset}/studio"}
  @subjects [
    {"the media library", "/d/#{@dataset}/studio/media"},
    {"the API tester", "/d/#{@dataset}/studio/api-tester"}
  ]

  setup %{conn: conn} do
    {:ok, _} =
      Barkpark.Auth.create_token(
        @admin_token,
        "press answer route coverage admin",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
  end

  # ── the instrument ──────────────────────────────────────────────────────
  #
  # `phx-hook` enumerated over MARKUP only. The inline layout script is served
  # in the same body and spells these names out in prose, so a whole-body regex
  # counts a comment as an installation — the exact over-count that would make
  # this test pass on the broken build.
  defp markup(html) do
    html
    |> String.replace(~r{<script\b.*?</script>}s, "")
    |> String.replace(~r{<style\b.*?</style>}s, "")
    |> String.replace(~r{<!--.*?-->}s, "")
  end

  defp hook_set(html) do
    ~r/phx-hook="([^"]+)"/
    |> Regex.scan(markup(html))
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp serves_region?(html), do: markup(html) =~ ~s(id="bp-press-answer")

  defp fetch(conn, path), do: conn |> get(scoped_studio(path)) |> html_response(200)

  # ── c0: the instrument can report a hook at all ─────────────────────────

  describe "the instrument" do
    test "reports a non-empty hook set on the control route", %{conn: conn} do
      {_label, path} = @control
      set = fetch(conn, path) |> hook_set()

      assert "PressAnswer" in set

      assert "WidthBucket" in set,
             "the desk stopped installing WidthBucket — the width half moved or broke, " <>
               "and every 'not installed' verdict below is now unreadable"

      assert length(set) > 1,
             "the desk enumerated #{inspect(set)}; a probe that can only ever " <>
               "report one name cannot distinguish a missing hook from a broken scan"
    end

    test "reports the ABSENCE of a name that is genuinely not installed", %{conn: conn} do
      {_label, path} = @control
      set = fetch(conn, path) |> hook_set()

      refute "NoSuchHookNameExistsAnywhere" in set,
             "the enumeration matched a name no element carries — it is not reading attributes"
    end

    test "the mutation arm: strip the attribute and the predicate goes false", %{conn: conn} do
      {_label, path} = @control
      html = fetch(conn, path)

      assert "PressAnswer" in hook_set(html)

      sabotaged =
        String.replace(html, ~s(phx-hook="PressAnswer"), ~s(data-was-hook="PressAnswer"))

      refute sabotaged == html, "the sabotage changed nothing — the needle was never there"

      refute "PressAnswer" in hook_set(sabotaged),
             "the predicate still reports PressAnswer installed after every one of its " <>
               "attributes was removed — it cannot red, so its greens mean nothing"

      assert serves_region?(sabotaged),
             "the sabotage removed the region too — then this arm would be testing the " <>
               "wrong thing. The region is served independently of the hook, which IS the defect."
    end
  end

  # ── c1: the predicate, over the routes ──────────────────────────────────

  describe "every Studio route that serves the region installs its listener" do
    test "the control route serves both", %{conn: conn} do
      {label, path} = @control
      html = fetch(conn, path)

      assert serves_region?(html), "#{label}: the region is gone"
      assert "PressAnswer" in hook_set(html), "#{label}: nothing listens"
    end

    for {label, path} <- @subjects do
      test "#{label} serves the region AND installs PressAnswer", %{conn: conn} do
        html = fetch(conn, unquote(path))

        assert serves_region?(html),
               "#{unquote(label)}: the region stopped being served. If that is deliberate, " <>
                 "note that the in-flight guard and the pre-join press queue in " <>
                 "root.html.heex are unconditional document listeners that write to it " <>
                 "and are scoped on `#studio-panes, .studio-bar` — .studio-bar is served " <>
                 "here, so removing the region re-silences a swallowed press."

        assert "PressAnswer" in hook_set(html),
               "#{unquote(label)}: the press-answer region is SERVED and its listener is " <>
                 "NOT installed. Enumerated hook set: " <>
                 inspect(hook_set(fetch(conn, unquote(path)))) <>
                 ". The tab strip and top bar on this route answer a press with nothing, " <>
                 "while the markup claims an announced live region."

        refute markup(html) =~ ~s(id="studio-panes"),
               "#{unquote(label)} now renders a pane row. That is not a failure of the " <>
                 "press answer, but it voids this test's subject: the whole point is a " <>
                 "route WITHOUT #studio-panes that still gets the listener."
      end
    end
  end

  # ── c2: the installer is not gated on the pane row ──────────────────────

  describe "the source seam" do
    setup do: {:ok, sheet: File.read!(@root)}

    test "the click listener is installed by PressAnswer, not by WidthBucket", %{sheet: sheet} do
      [_, press_answer_body] = String.split(sheet, "Hooks.PressAnswer = {", parts: 2)
      [width_bucket_body] = [between(sheet, "Hooks.WidthBucket = {", "Hooks.PressAnswer = {")]

      assert press_answer_body =~ ~s|document.addEventListener("click", this._paOnClick)|,
             "Hooks.PressAnswer no longer installs the press listener"

      refute width_bucket_body =~ "_paOnPress",
             "the press answer is back inside Hooks.WidthBucket, whose element is " <>
               "#studio-panes — the routes above lose it again and this file's route " <>
               "assertions would still pass if the attribute were left behind"

      refute width_bucket_body =~ "_paOnClick",
             "WidthBucket still touches the press listener"
    end

    test "the mutation arm: a sheet with the listener line cut out reds the same check", %{
      sheet: sheet
    } do
      needle = ~s|document.addEventListener("click", this._paOnClick)|
      assert String.contains?(sheet, needle)

      cut = String.replace(sheet, needle, "/* cut */")
      [_, press_answer_body] = String.split(cut, "Hooks.PressAnswer = {", parts: 2)

      refute press_answer_body =~ needle,
             "removing the only listener install left the predicate true — it is not " <>
               "reading the line it names"
    end
  end

  defp between(s, open, close) do
    [_, rest] = String.split(s, open, parts: 2)
    [body | _] = String.split(rest, close, parts: 2)
    body
  end
end
