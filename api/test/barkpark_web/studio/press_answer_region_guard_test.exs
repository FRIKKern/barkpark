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

  alias Barkpark.Auth

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)
  @dataset "production"
  @admin_token "press-answer-region-guard-admin-token"

  defp sheet, do: File.read!(@root)

  describe "the region is in the SERVED html, outside the LiveView root" do
    setup %{conn: conn} do
      {:ok, _} =
        Auth.create_token(@admin_token, "press answer guard admin", @dataset, [
          "read",
          "write",
          "admin"
        ])

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
      {"the aria-current witness", ~S|if (this._paCurrentSig() !== p.sig) return p.name|,
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

    test "the delegated listener stays on the container, never on window" do
      s = sheet()

      assert String.contains?(s, ~S|this.el.addEventListener("click", this._paOnClick)|),
             "running BEFORE LiveView's window listener is the whole discard-detection mechanism"

      refute String.contains?(s, ~S|window.addEventListener("click", this._paOnClick)|),
             "a window listener would fire after LiveView's and could not see the pre-drop ref state"
    end
  end
end
