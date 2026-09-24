defmodule BarkparkWeb.Studio.PressAnswerRefusalWordTest do
  @moduledoc """
  task-ce909110bce2fddf — the press-answer region must not say "Done." for a
  press the server REFUSED.

  THE DEFECT. The press-answer hook in `root.html.heex` settles a press by
  looking for two witnesses: a URL patch ("Opened …") and an `aria-current`
  move ("Selected …"). With NEITHER it used to release `"Done."`, described in
  the source as neutral. It is not neutral to the person hearing it — every
  Studio handler that answers a `phx-click` with an unchanged socket was
  getting a completed-action word, including an AUTHORIZATION refusal
  (`Scope.switch_workspace/2`) and a `publish` with no document open. A user
  who saw nothing presses again; a user told "Done." walks away.

  TWO HALVES, BOTH PINNED HERE.

    * CLIENT — the evidence-free branch now CLEARS instead of inventing a
      word. One line, and it covers every silent handler at once.
    * SERVER — the refusal names itself. `switch_workspace/2`'s
      `can_reach_workspace?` arm now flashes, matching the sibling arm four
      lines below it that always has, and `Doc.publish/1`, `Doc.unpublish/1`
      and `Doc.duplicate_doc/1` flash on their no-document `else` arms.

  WHY THE HOOK GOES QUIET RATHER THAN SAYING SOMETHING ELSE. "No change." was
  the other candidate and it is FALSE in the opposite direction: a successful
  publish changes a badge and raises a flash, and this hook watches neither,
  so it would announce "No change." over a change. The only claim the hook has
  evidence for is that the round trip happened, which is not actionable. The
  outcome word therefore belongs to the server, which knows the reason and
  already owns an announced banner (`Nav.studio_flash/1` — `role="status"` /
  `aria-live="polite"` for info, `role="alert"` / `aria-live="assertive"` for
  errors). Every hook branch that HAS evidence still speaks; the last block in
  this file pins that, so the fix cannot be over-corrected into total silence.

  HOW THE DRIVEN PRESSES AND THE SOURCE ASSERTIONS FIT TOGETHER. `#bp-press-answer`
  is filled by client JS that `mix test` cannot run. So the driven presses
  establish the PRECONDITION mechanically — after this real press, neither
  witness moved, therefore `_paSettleWord` returns null and `_paSettle`'s
  fallback is the word the user gets — and the source assertions pin what that
  fallback is. Neither half is load-bearing alone, and the precondition is
  measured rather than assumed.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)
  @dataset "production"

  # Words an interface uses for a completed action. The hook may emit none of
  # them from the branch that has no evidence.
  @completion_words ~w(Done Saved Success Succeeded Complete Completed Finished Published Updated)

  defp sheet, do: File.read!(@root)

  # The `_paSettle` body with `//` comment lines removed. The prose above the
  # release explains what "Done." got wrong and therefore CONTAINS the word —
  # stripping comments is what makes "this branch cannot emit a completion
  # word" a claim about CODE rather than about prose.
  defp settle_code do
    [_, rest] = String.split(sheet(), "      _paSettle(p) {", parts: 2)
    [body, _] = String.split(rest, "\n      },", parts: 2)

    body
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim(&1), "//"))
    |> Enum.join("\n")
  end

  # The hook's second witness: the set of `aria-current` values on the page.
  # `_paCurrentSig` builds its signature from exactly these nodes, so if this
  # set is identical before and after a press, that witness did not move.
  defp aria_current_sig(html) do
    ~r/aria-current="([^"]*)"/ |> Regex.scan(html) |> Enum.map(&List.last/1) |> Enum.sort()
  end

  defp flash_error(view), do: :sys.get_state(view.pid).socket.assigns.flash["error"] || ""

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()

    {:ok, foreign_ws} = Tenancy.create_workspace(%{slug: "pa-foreign", name: "Foreign Co"})
    {:ok, _} = Tenancy.create_project(foreign_ws, %{slug: "secret", name: "Secret"})

    {:ok, member_ws} = Tenancy.create_workspace(%{slug: "pa-member", name: "Member Co"})
    {:ok, _} = Tenancy.create_project(member_ws, %{slug: "blog", name: "Blog"})

    raw = "press-answer-refusal-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "press answer refusal", @dataset, ["read", "write"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(member_ws.id, token.id, "member")

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     foreign_ws: foreign_ws,
     member_ws: member_ws}
  end

  defp mount_studio(conn) do
    {:error, {:redirect, %{to: to}}} = live(conn, "/studio/#{@dataset}")
    live(conn, to)
  end

  describe "a driven press whose handler answers with an unchanged socket" do
    test "publish with NO open document moves neither witness, so the settle fallback is what the user gets",
         %{conn: conn, member_ws: member_ws} do
      {:ok, view, _html} = mount_studio(conn)

      # PRECONDITION, MEASURED: this desk really is the no-document shape, so
      # `Doc.publish/1` takes the `else` arm under test and not the real
      # publish path.
      assert is_nil(:sys.get_state(view.pid).socket.assigns[:editor_doc]),
             "a document is open, so this press does NOT reach the silent else arm of Doc.publish/1"

      before = render(view)

      render_click(view, "publish", %{})

      after_html = render(view)

      # WITNESS 1 — no URL patch. A push_patch would have made "Opened …" the
      # settle word and this press would never reach the fallback. There is no
      # `refute_patched/2` in LiveViewTest, so the absence is taken by letting
      # `assert_patch/2` time out — and the CONTROL below drives an honoured
      # switch on this same view and shows the same helper does see a patch.
      patched? =
        try do
          assert_patch(view, 100)
          true
        rescue
          # `assert_patch/2` raises ArgumentError ("expected … to patch, but
          # got none") rather than an assertion error when nothing patches.
          ArgumentError -> false
          ExUnit.AssertionError -> false
        end

      refute patched?,
             "the press patched the URL, so its settle word is \"Opened …\" and this is not the witness-less case under test"

      # WITNESS 2 — the aria-current set is byte-identical, so `_paCurrentSig`
      # is unchanged and "Selected …" is not the settle word either.
      assert aria_current_sig(before) == aria_current_sig(after_html),
             "the aria-current signature moved, so this press is not the witness-less case under test"

      # CONTROL FOR THE PATCH PROBE. The same `assert_patch/2`, on the same
      # view, DOES see a patch when one happens — so the "no patch" verdict
      # above measured something. An honoured switch is the cheapest press
      # that patches.
      render_click(view, "switch-workspace", %{"workspace" => member_ws.slug})

      assert assert_patch(view, 500) =~ "/w/#{member_ws.slug}/",
             "the patch probe never fires, so its silence above is vacuous"

      # Therefore `_paSettleWord` returns null for the publish press and the
      # user hears `_paSettle`'s fallback — which must not be a completion word.
      for word <- @completion_words do
        refute settle_code() =~ "\"#{word}",
               ~s|#bp-press-answer answers a REFUSED press with the completion word "#{word}" — a user told that walks away from a press that never ran|
      end
    end

    test "the refused workspace switch leaves the scope unchanged and NAMES the refusal",
         %{conn: conn, foreign_ws: foreign_ws} do
      {:ok, view, _html} = mount_studio(conn)

      before = :sys.get_state(view.pid).socket.assigns.current_workspace.slug

      render_click(view, "switch-workspace", %{"workspace" => foreign_ws.slug})

      assigns = :sys.get_state(view.pid).socket.assigns

      # PRECONDITION: the refusal really fired (the membership gate held).
      assert assigns.current_workspace.slug == before,
             "MEMBERSHIP GATE BREACH: the switch was honoured, so no refusal is under test here"

      # THE REFUSAL SPEAKS. Its sibling cond arm has always flashed; this one
      # answered with an unchanged socket, which the press region could only
      # report as a round trip that happened.
      #
      # The WORDING is the one sentence the not-found arm answers too
      # (task-1829c2e22b31b2d6): a refusal-only "You do not have access to
      # that workspace" told a forged press which slugs exist. The contract
      # this test pins — the refusal is named, not mute — is unchanged; the
      # no-oracle half is pinned by studio_live_switch_workspace_oracle_test.exs.
      assert flash_error(view) ==
               "Could not open that workspace — it does not exist, or you do not have access to it",
             "an AUTHORIZATION refusal a user can reach is still mute: #{inspect(flash_error(view))}"
    end
  end

  describe "the settle fallback, pinned so a revert REDS" do
    test "the evidence-free branch CLEARS the region instead of naming an outcome" do
      assert settle_code() =~ "this._paRelease(word || \"\")",
             "the settle fallback no longer clears — with neither witness the hook has no outcome it is entitled to name"
    end

    test "SABOTAGE CONTROL — the clear check can fail" do
      sabotaged = String.replace(settle_code(), "this._paRelease(word || \"\")", "")

      refute sabotaged =~ "this._paRelease(word || \"\")",
             "this check cannot fail, so it is not a check"
    end

    test "the active-tab anchor branch clears too, for the same reason" do
      assert sheet() =~ ~S|if (to.href === location.href) { this._paRelease(""); return; }|,
             "pressing the tab you are already on answers and changes nothing; a completion word there is the same lie"
    end
  end

  describe "the branches that DO have evidence still speak (no over-correction into silence)" do
    @speaking [
      {"the URL-patch witness", ~S|return p.name ? "Opened “" + p.name + "”." : "Opened.";|},
      {"the aria-current witness",
       ~S|return p.name ? "Selected “" + p.name + "”." : "Selected.";|},
      {"the lost press", "That press did not reach the server — press it again."},
      {"the discarded press", "Still working on your last press — that one was not sent."},
      {"the named ceiling", "No answer from the server after 8 seconds."},
      {"the press itself", ~S|this._paSay(p.name ? "Working on “" + p.name + "”…" : "Working…");|}
    ]

    for {label, literal} <- @speaking do
      test "still speaks: #{label}" do
        assert String.contains?(sheet(), unquote(literal)),
               "the fix was over-corrected: a branch that HAS evidence went silent too"
      end
    end
  end
end
