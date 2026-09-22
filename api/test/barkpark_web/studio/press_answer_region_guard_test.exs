defmodule BarkparkWeb.Studio.PressAnswerRegionGuardTest do
  @moduledoc """
  spd-w19 (reviewer follow-up) — the press answer, pinned so a revert REDS
  OFFLINE.

  The slice that shipped `#bp-press-answer` proved it on the DEPLOYED build with
  a real Chrome and a real LiveSocket, which is the only place the ref mechanics
  can be observed — and then carried NO `api/test/**` coverage at all. Charter
  D241 is explicit about why that is not enough: `tooling/**` dodges the required
  Elixir gate, no studio-journey job may ever gate a merge, and therefore *every*
  "reds when the fix is reverted" obligation in this wave has to be carried by a
  test under `api/test/**`. Without this file, a future edit to
  `root.html.heex` could delete the live region, the honesty seam, or both, and
  the whole required gate would stay green.

  Two kinds of assertion, and neither is prose:

    1. THE REGION IS IN THE SERVED HTML. A real authenticated `GET` of the desk,
       asserted on `html_response/2` — the conn-rendered page, which is where the
       region has to live (inside the LiveView root morphdom can patch it
       mid-announce and the announcement is dropped).
    2. THE HONESTY SEAM IS IN THE HOOK. `grep -F` over the layout source for the
       three things that make the clear evidence-bound rather than optimistic —
       the URL comparison, the `aria-current` signature, and the neutral word.
       Each one carries a SABOTAGE CONTROL: the same predicate re-run against a
       copy of the sheet with that line cut out must come back false, so no check
       here can be one whose failure nobody has observed.

  Deliberately NOT asserted: anything about ref timing, the 16 ms probe verdict,
  or the discard branch. Those need a real LiveSocket stamping real refs; they
  are the deployed proof's job and this file does not pretend otherwise.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest, only: [live: 2, render: 1]

  alias Barkpark.Auth

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)
  @dataset "production"
  @admin_token "press-answer-region-guard-admin-token"

  defp sheet, do: File.read!(@root)

  describe "the region is in the SERVED html, outside the LiveView root" do
    setup %{conn: conn} do
      {:ok, _} =
        Auth.create_token(
          @admin_token,
          "press answer guard admin",
          @dataset,
          [
            "read",
            "write",
            "admin"
          ],
          Barkpark.TenancyFixtures.default_workspace_id!()
        )

      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "an authenticated desk GET carries the named, announced press region", %{conn: conn} do
      html =
        conn
        |> get(scoped_studio("/d/#{@dataset}/studio"))
        |> html_response(200)

      assert html =~ ~s(id="bp-press-answer"),
             "the press answer region is gone from the served page — a press has nothing to speak through"

      assert html =~ ~s(data-test-id="press-answer")
      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-live="polite")
      assert html =~ ~s(aria-atomic="true")
    end

    test "it ships EMPTY, so a settled desk carries no residue", %{conn: conn} do
      html =
        conn
        |> get(scoped_studio("/d/#{@dataset}/studio"))
        |> html_response(200)

      # The element is written as an empty container and `:empty{display:none}`
      # hides it. A page that shipped words in it would announce them on load.
      assert html =~ ~r/id="bp-press-answer"[^>]*>\s*<\/div>/,
             "the region shipped with content in it — it would announce on page load"

      assert sheet() =~ ".bp-press-answer:empty { display: none; }",
             "without the :empty rule an idle desk carries a visible empty pill"
    end
  end

  describe "the region sits OUTSIDE the LiveView root (structural, not incidental)" do
    test "it is a sibling of {@inner_content}, after it, not nested in it" do
      s = sheet()

      inner = :binary.match(s, "{@inner_content}")
      region = :binary.match(s, ~s(id="bp-press-answer"))

      assert inner != :nomatch, "the layout no longer renders {@inner_content}"
      assert region != :nomatch, "the press answer region is gone from the layout"

      {inner_at, _} = inner
      {region_at, _} = region

      assert region_at > inner_at,
             "the region must render AFTER {@inner_content}, as its sibling — inside the LiveView root morphdom can patch it mid-announce"
    end
  end

  describe "the honesty seam is in the hook, and each check can fail" do
    # {short label, literal, why it is load-bearing}
    @honesty_seam [
      {"the URL-patch witness", ~S|if (location.href !== p.url) return p.name|,
       "a URL patch is the only evidence that licenses \"Opened\""},
      # `p.root` (spd-w19-press-answer-outside-panes): the witness is now computed
      # over the press's OWN surface so a chrome press is judged against the chrome.
      # For a pane press `p.root` IS `#studio-panes`, i.e. the scope this literal
      # covered before, so the property is unchanged and only its spelling moved.
      {"the aria-current witness", ~S|if (this._paCurrentSig(p.root) !== p.sig) return p.name|,
       "an aria-current move is the only evidence that licenses \"Selected\""},
      {"the neutral word", "this._paRelease(word || \"Done.\")",
       "with neither witness the answer must be NEUTRAL — #item-rest answers the server and changes nothing, so a ref-drop clear saying \"Opened.\" would announce a success for a dead row"}
    ]

    for {label, literal, why} <- @honesty_seam do
      test "present: #{label}" do
        assert String.contains?(sheet(), unquote(literal)),
               "the press answer's clear is no longer bound to observed evidence: #{unquote(why)}"
      end

      test "SABOTAGE CONTROL — #{label} check can fail" do
        sabotaged = String.replace(sheet(), unquote(literal), "")

        refute String.contains?(sabotaged, unquote(literal)),
               "this check cannot fail, so it is not a check: #{unquote(why)}"
      end
    end

    test "the lost-press branch speaks rather than staying silent" do
      s = sheet()

      assert String.contains?(s, "That press did not reach the server — press it again."),
             "a press LiveView never put on the wire is the owner's actual complaint; silence there is the bug"

      assert String.contains?(s, "No answer from the server after 8 seconds."),
             "the unbounded tint must be replaced by a NAMED ceiling"
    end

    test "the delegated listener stays off window, so it still runs first" do
      s = sheet()

      # spd-w19-press-answer-outside-panes moved this from `this.el` to
      # `document`: `.studio-bar` is a SIBLING of `#studio-panes`, so a
      # container listener can never see a chrome press. The property the old
      # assertion was really protecting is unchanged and is what is asserted
      # here — NOT `window`. LiveView binds its click on `window` in the bubble
      # phase and `window` is the last bubble target, so a document listener is
      # still strictly earlier and can still read the pre-drop ref state.
      assert String.contains?(s, ~S|document.addEventListener("click", this._paOnClick)|),
             "running BEFORE LiveView's window listener is the whole discard-detection mechanism"

      refute String.contains?(s, ~S|window.addEventListener("click", this._paOnClick)|),
             "a window listener would fire after LiveView's and could not see the pre-drop ref state"

      refute String.contains?(s, ~S|document.addEventListener("click", this._paOnClick, true)|),
             "capture phase would run before the in-flight guard and re-break the swallowed-press wording"
    end
  end

  describe "the chrome surfaces answer through the SAME region (spd-w19-press-answer-outside-panes)" do
    # Each entry: {label, literal, why it is load-bearing}. Every one carries a
    # sabotage control below, for the same reason the honesty seam does — a
    # check whose failure nobody has observed is not a check.
    @chrome_seam [
      {"the chrome scope resolver",
       ~S<return el.closest("#studio-panes") || el.closest(".studio-bar");>,
       "`.studio-bar` is the top bar AND (as `.studio-bar-tabs`) the studio-tab strip; without it the answer stops at the pane row"},
      {"the document-level listener", ~S|document.addEventListener("click", this._paOnClick);|,
       "`.studio-bar` is a SIBLING of `#studio-panes`, so a container listener can never see a chrome press"},
      {"the anchor branch", "_paOnChromeAnchor(ev, t) {",
       "every `.studio-tab` is a plain `<a href>` with no phx-click, so without an anchor shape the tab strip is still unanswered"},
      {"the anchor's neutral clear",
       ~S|if (to.href === location.href) { this._paRelease("Done."); return; }|,
       "the ACTIVE tab answers and changes nothing; naming it \"Opening\" would trade the old silence for a new lie"},
      {"the in-flight guard follows the same scope",
       ~S|blocked.closest("#studio-panes, .studio-bar")|,
       "the guard runs BEFORE the hook and stops the event; scoped to the pane row it would re-silence every swallowed chrome press"},
      {"the sighted half follows too", ~S|.studio-bar [aria-busy="true"] {|,
       "the region answers a screen reader; without this rule a sighted user pressing a top-bar control still sees only the wordless tint"}
    ]

    for {label, literal, why} <- @chrome_seam do
      test "present: #{label}" do
        assert String.contains?(sheet(), unquote(literal)),
               "the press answer no longer reaches the chrome: #{unquote(why)}"
      end

      test "SABOTAGE CONTROL — #{label} check can fail" do
        sabotaged = String.replace(sheet(), unquote(literal), "")

        refute String.contains?(sabotaged, unquote(literal)),
               "this check cannot fail, so it is not a check: #{unquote(why)}"
      end
    end

    test "the widened scope did NOT widen the aria-current signature to the document" do
      # A document-wide signature would let an unrelated surface certify a press
      # it had nothing to do with. The witness stays scoped to the press's own
      # surface, which for a pane press is `#studio-panes` exactly as before.
      s = sheet()

      assert String.contains?(
               s,
               ~S<var nodes = (root || this.el).querySelectorAll("[aria-current]")>
             ),
             "the aria-current witness must be computed over the press's OWN surface"

      refute String.contains?(s, ~S|document.querySelectorAll("[aria-current]")|),
             "a document-wide aria-current signature lets an unrelated surface certify this press"
    end
  end

  describe "the live-region census, counted in the response body, in BOTH states" do
    # WHY THIS BLOCK CHANGED SHAPE (task-608a990062b134b2).
    #
    # It used to assert ONE live region on a clean authenticated desk GET and
    # stop there. That assertion is true of the clean desk and BLIND to the
    # state the owner actually lands in: the post-login redirect. Measured on a
    # real `POST /login` -> follow, the served body carries TWO — the second
    # being `Nav.studio_flash/1` (components/studio_components/nav.ex),
    # `<div class="flash flash-info" role="status" aria-live="polite" ...>`,
    # markup that predates `#bp-press-answer` entirely.
    #
    # Two regions is a PRECONDITION, not a defect, and the race the old
    # comment feared does not occur — see the "they do not race" block below,
    # which pins the three structural facts that rule it out. So the invariant
    # is narrowed rather than the count re-asserted: exactly ONE live region in
    # the served body ships EMPTY, and it is this one. A live region announces
    # CHANGES made after registration; a region that arrives pre-populated in
    # the initial document announces nothing on load. One empty region = one
    # announcer armed by the load.
    #
    # Removing `aria-live` from the flash would be a REGRESSION, not a fix: a
    # LiveView `put_flash` after mount genuinely has to announce, and
    # `studio_live_save_status_test.exs` already pins that it does.

    setup %{conn: conn} do
      {:ok, _} =
        Auth.create_token(
          @admin_token <> "-census",
          "press answer census admin",
          @dataset,
          ["read", "write", "admin"],
          Barkpark.TenancyFixtures.default_workspace_id!()
        )

      {:ok, conn: conn, token: @admin_token <> "-census"}
    end

    # Counted, never asserted-by-existence. "There is exactly one" is a claim
    # about the ABSENCE of a second one, and an absence is never caught by
    # reading the first hit. Both the explicit attribute and the two IMPLICIT
    # live roles are counted, because `role="alert"`/`role="status"` announce
    # without carrying `aria-live` at all — counting only the attribute would
    # report "one" on a page with three announcers.
    defp live_region_count(html) do
      explicit = Regex.scan(~r/\saria-live\s*=/, html) |> length()
      implicit = Regex.scan(~r/\srole\s*=\s*"(?:alert|status|log)"/, html) |> length()
      {explicit, implicit}
    end

    # The narrowed predicate: live regions that ship EMPTY, i.e. the ones a
    # page load ARMS. A region carrying text in the initial document is inert —
    # nothing changed in it, so nothing is announced.
    @empty_live_region ~r/<(\w+)[^>]*?(?:\saria-live\s*=|\srole\s*=\s*"(?:alert|status|log)")[^>]*>\s*<\/\1>/

    defp empty_live_regions(html) do
      @empty_live_region |> Regex.scan(html) |> Enum.map(&hd/1)
    end

    defp clean_desk(conn, token) do
      conn
      |> init_test_session(%{"api_token" => token})
      |> get(scoped_studio("/d/#{@dataset}/studio"))
      |> html_response(200)
    end

    # The owner's actual landing: sign in for real and follow the redirect, so
    # the flash is carried by the REAL controller path (SessionController.create
    # -> put_flash(:info, "Signed in.") -> redirect) rather than stuffed into
    # the session by the test.
    defp post_login_body(conn, token) do
      dest = scoped_studio("/d/#{@dataset}/studio")
      redirected = post(conn, "/login", %{"token" => token, "return_to" => dest})

      assert redirected.status == 302,
             "the sign-in POST no longer redirects, so this body is not the post-login body: #{redirected.status}"

      redirected |> recycle() |> get(dest) |> html_response(200)
    end

    test "CONTROL — the clean authenticated desk serves exactly one, and the counter can say two",
         %{conn: conn, token: token} do
      html = clean_desk(conn, token)

      assert {1, 1} == live_region_count(html),
             "the clean desk no longer carries exactly one live region: #{inspect(live_region_count(html))}"

      # THE COUNTER CONTROL. Append a second, complete live region to the SAME
      # body the assertion above passed on. A counter that cannot say two proves
      # nothing by saying one.
      doubled = html <> ~s(<div id="imposter" role="status" aria-live="polite"></div>)

      assert {2, 2} == live_region_count(doubled),
             "the counter cannot distinguish one live region from two, so its verdict of one is vacuous: #{inspect(live_region_count(doubled))}"
    end

    test "the post-login body serves TWO, and the second one is the flash banner",
         %{conn: conn, token: token} do
      html = post_login_body(conn, token)

      assert {2, 2} == live_region_count(html),
             "the post-login body no longer carries the two-region state this guard was narrowed for: #{inspect(live_region_count(html))} — re-read the reasoning above before changing the number"

      # The second node, quoted in full, exactly as `Nav.studio_flash/1` emits
      # it. Naming the source is the point: this markup predates the press
      # answer region and is not its second region.
      assert html =~
               ~s(<div class="flash flash-info" role="status" aria-live="polite" style="margin: 8px 16px 0;">Signed in.</div>),
             "the flash banner from BarkparkWeb.StudioComponents.Nav.studio_flash/1 is not in the post-login body in the shape this census was measured against"
    end

    test "EXACTLY ONE EMPTY live region — in BOTH states — and it is the press answer",
         %{conn: conn, token: token} do
      for {label, html} <-
            [{"clean desk", clean_desk(conn, token)}] ++
              [{"post-login (flash) body", post_login_body(build_conn(), token)}] do
        empties = empty_live_regions(html)

        assert length(empties) == 1,
               "#{label}: #{length(empties)} live regions ship EMPTY, so #{length(empties)} announcers are armed by the load — exactly one may be: #{inspect(empties)}"

        assert hd(empties) =~ ~s(id="bp-press-answer"),
               "#{label}: the one empty live region is not the press answer: #{hd(empties)}"
      end
    end

    test "MUTATION ARM — a second EMPTY live region REDS the assertion above",
         %{conn: conn, token: token} do
      html = post_login_body(conn, token)

      assert length(empty_live_regions(html)) == 1

      sabotaged = html <> ~s(<div id="imposter" role="status" aria-live="polite"></div>)

      assert length(empty_live_regions(sabotaged)) == 2,
             "the empty-region predicate cannot see a second armed announcer, so its verdict of one is vacuous"
    end

    test "MUTATION ARM — a FILLED live region does NOT move the count, so the predicate discriminates",
         %{conn: conn, token: token} do
      # Without this arm, `empty_live_regions/1` could simply be
      # `live_region_count/1` under another name and the whole narrowing would
      # be a relabelling. The flash node in the body above is already one such
      # filled region; a second one must still leave the count at one.
      html = post_login_body(conn, token)

      filled = html <> ~s(<div id="filled-imposter" role="status" aria-live="polite">words</div>)

      assert length(empty_live_regions(filled)) == 1,
             "the predicate counts filled regions too, so it is the old count wearing a new name"

      assert live_region_count(filled) == {3, 3},
             "the filled region was not actually appended, so this arm measured nothing"
    end

    test "MUTATION ARM — stripping the press answer's live attributes REDS it to zero",
         %{conn: conn, token: token} do
      html = clean_desk(conn, token)

      stripped =
        String.replace(
          html,
          ~s(role="status" aria-live="polite" aria-atomic="true" data-test-id="press-answer"),
          ~s(data-test-id="press-answer")
        )

      assert length(empty_live_regions(stripped)) == 0,
             "the press answer can lose role/aria-live and this guard still reports one armed announcer"
    end
  end

  describe "they do not race: the two regions are structurally unable to collide" do
    # The three facts that turn "two live regions exist" from a defect into a
    # precondition. Each is measured, not asserted in prose, and each REDS if a
    # future edit moves the press answer into the patchable tree or makes the
    # flash ship empty.
    setup %{conn: conn} do
      token = @admin_token <> "-race"

      {:ok, _} =
        Auth.create_token(
          token,
          "press answer race admin",
          @dataset,
          ["read", "write", "admin"],
          Barkpark.TenancyFixtures.default_workspace_id!()
        )

      {:ok, conn: init_test_session(conn, %{"api_token" => token})}
    end

    test "the flash is INSIDE the patchable LiveView tree and the press answer is NOT",
         %{conn: conn} do
      conn = Plug.Conn.put_session(conn, "phoenix_flash", %{"info" => "race-probe-flash"})

      {:ok, view, mount_html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio"))

      patchable = render(view)

      # CONTROL: the region IS in the full served document…
      assert mount_html =~ ~s(id="bp-press-answer"),
             "the press answer is not in the served document at all — this test would pass vacuously"

      # …and the flash IS in the part morphdom patches, so the probe can see it.
      assert patchable =~ "race-probe-flash",
             "the flash is not in the patchable tree, so this run cannot compare the two"

      # THE FINDING: morphdom's tree does not contain the press answer, so a
      # flash patch can never touch it and the two writes cannot collide.
      refute patchable =~ "bp-press-answer",
             "the press answer moved INSIDE the LiveView root — morphdom can now patch it mid-announce, and the two regions CAN now collide"
    end

    test "the flash region ships PRE-POPULATED, so the load arms only the press answer",
         %{conn: conn} do
      conn = Plug.Conn.put_session(conn, "phoenix_flash", %{"info" => "race-probe-flash"})

      html =
        conn
        |> get(scoped_studio("/d/#{@dataset}/studio"))
        |> html_response(200)

      assert html =~ ~r/<div class="flash flash-info"[^>]*>race-probe-flash<\/div>/,
             "the flash region no longer ships with its text in the initial document; if it now arrives empty and fills later, it becomes a SECOND armed announcer and the refutation this block records no longer holds"

      assert html =~ ~r/id="bp-press-answer"[^>]*>\s*<\/div>/,
             "the press answer no longer ships empty"
    end

    test "the press answer is written synchronously at click, not over the socket" do
      s = sheet()

      # A socket round trip separates the flash write from this one; two POLITE
      # regions changing in different ticks queue rather than interleave. The
      # listener being a plain (non-async, non-deferred) click handler is what
      # makes that separation structural.
      assert String.contains?(s, ~S|document.addEventListener("click", this._paOnClick)|),
             "the press answer write is no longer a synchronous click handler, so it can now land in the same tick as a socket-driven flash patch"

      assert String.contains?(s, "_paSay(text) {"),
             "the direct textContent write is gone; a write routed through the server would land in the same diff as a flash"
    end
  end
end
