defmodule BarkparkWeb.Studio.StudioLiveSecondaryPaneBucketTest do
  @moduledoc """
  spd-b39 successor (task-2d359bf4fbe44929) — the secondary pane tells the
  truth at `narrow` and `phone`.

  ## What was wrong

  Charter D36 hid `.bp-secondary-pane` with a bucket-scoped `display: none`
  (`root.html.heex`). That closed the CRUSH — a rigid `flex: 0 0 360px` card
  beside a 560px protected document annihilated the document below 1024px —
  and left the STATE lying: the server kept rendering the whole read-only
  card, with every field value of the referenced document in it, and
  `@secondary_doc` stayed assigned. The markup was in the DOM: walkable by a
  screen reader, and carrying the desk's only close control inside the very
  box the stylesheet had removed.

  ## What is pinned here

    * The card is ABSENT FROM THE RENDERED HTML at `narrow` and `phone` —
      not hidden, not `aria-hidden`, not inert: absent. This is the strongest
      of the three shapes criterion 2 offers, and it is why nothing about
      focus or screen-reader order needs arguing: there is no node.
    * `@secondary_doc` SURVIVES the narrowing, and the card comes back on the
      way out. Silently dropping a user's chosen reference on a resize is the
      other way to make the state honest and it destroys context; this slice
      refused it, so the assign is pinned in both directions.
    * The editor header names the reference BY TITLE and offers
      `close-secondary` at exactly those two buckets — the card's own ✕ went
      away with the card, and it was the only one. (D36's own comment says
      "its own close/open control is in the editor header, which stays".
      That was false: `open-secondary-picker` is in the header, the ✕ never
      was. This test is the standing refutation.)
    * The D36 CSS rule itself is byte-identical. The yield is server-side and
      ADDITIVE: the stylesheet still defends any surface that renders the
      class without passing a bucket, and the instant between a resize and
      the `width-bucket` round trip.

  The bucket is pushed through the hooked element (`#studio-panes`), the same
  way `studio_live_width_bucket_test.exs` does it, so the assertions run on a
  desk whose bucket moved the way a real resize moves it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.TenancyFixtures

  @dataset "production"

  @root Path.expand("../../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  setup %{conn: conn} do
    {_ws, _proj} = TenancyFixtures.ensure_default_scope!()

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "text"}
          ]
        },
        @dataset
      )

    for {id, title, body} <- [
          {"p1", "Primary doc", "one"},
          {"p2", "Referenced doc", "two"}
        ] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "title" => title, "content" => %{"body" => body}},
          @dataset
        )
    end

    {:ok, conn: conn}
  end

  defp set_bucket(view, bucket) do
    view
    |> element("#studio-panes")
    |> render_hook("width-bucket", %{"bucket" => bucket})
  end

  defp secondary_assign(view), do: :sys.get_state(view.pid).socket.assigns.secondary_doc

  # Open the primary document, then open p2 as the read-only secondary. The
  # asserts inside are the HARNESS check: if the picker ever stops loading a
  # secondary, every bucket assertion below would pass vacuously.
  defp desk_with_secondary(conn) do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))
    _ = render_click(view, "open-secondary-picker", %{})
    html = render_click(view, "select-secondary", %{"id" => "p2"})

    assert html =~ ~s(data-test-id="secondary-pane"),
           "harness: the secondary card must render at the default wide bucket"

    assert secondary_assign(view), "harness: select-secondary must set @secondary_doc"

    {view, html}
  end

  describe "the card yields server-side below standard" do
    test "wide and standard still render it", %{conn: conn} do
      {view, _html} = desk_with_secondary(conn)

      for bucket <- ~w(wide standard) do
        html = set_bucket(view, bucket)

        assert html =~ ~s(data-test-id="secondary-pane"),
               "#{bucket} must keep rendering the secondary card — a 360px " <>
                 "reference still fits beside the document at 1024px and up"
      end
    end

    test "narrow and phone render NO secondary markup at all", %{conn: conn} do
      {view, _html} = desk_with_secondary(conn)

      for bucket <- ~w(narrow phone) do
        html = set_bucket(view, bucket)

        refute html =~ ~s(data-test-id="secondary-pane"),
               "#{bucket} must not render the secondary card — D36 hides it with " <>
                 "display:none, and shipping the markup anyway is the lie this " <>
                 "task closes"

        refute html =~ "bp-secondary-pane",
               "#{bucket} must emit no .bp-secondary-pane node, header or body"

        # The card's body — its read-only field table — is what actually costs
        # bytes on a phone connection and what a screen reader would have
        # walked. (The document's TITLE is deliberately still on the page at
        # these buckets: it is inside the header's "Close reference: …" label,
        # which is the indicator half of this task.)
        refute html =~ "Read-only — edit via primary pane.",
               "#{bucket} must not ship the card's read-only field table to a " <>
                 "client that cannot see it"
      end
    end

    test "nothing focusable or screen-reader-visible is left behind at narrow/phone",
         %{conn: conn} do
      {view, _html} = desk_with_secondary(conn)

      for bucket <- ~w(narrow phone) do
        html = set_bucket(view, bucket)

        # The card's ✕ is the only focusable node inside `.bp-secondary-pane`.
        # `display: none` would take it out of the tab order once the
        # stylesheet applied; absence takes it out of the DOCUMENT, which is
        # what a screen reader and an assistive tree read.
        refute html =~ ~s(data-test-id="close-secondary"),
               "#{bucket}: the card's own ✕ must not survive into a pane the " <>
                 "desk has decided not to render"

        refute html =~ ~s(aria-label="Close secondary pane"),
               "#{bucket}: no accessible name from the yielded pane may remain " <>
                 "in the accessibility tree"
      end
    end
  end

  describe "the state stays honest, and reversible" do
    test "@secondary_doc survives the narrowing and the card returns on the way out",
         %{conn: conn} do
      {view, _html} = desk_with_secondary(conn)

      _ = set_bucket(view, "phone")

      assert secondary_assign(view),
             "the assign must SURVIVE — dropping the user's chosen reference on a " <>
               "resize destroys context they picked deliberately"

      html = set_bucket(view, "wide")

      assert html =~ ~s(data-test-id="secondary-pane"),
             "widening back out must restore the card from the surviving assign"

      assert html =~ "Referenced doc"
    end

    test "the editor header names the reference and offers to close it at narrow/phone",
         %{conn: conn} do
      {view, _html} = desk_with_secondary(conn)

      for bucket <- ~w(narrow phone) do
        html = set_bucket(view, bucket)

        assert html =~ ~s(data-test-id="close-secondary-bucket"),
               "#{bucket}: with the card yielded, the header must carry the only " <>
                 "remaining close control"

        assert html =~ "Close reference: Referenced doc",
               "#{bucket}: the control must NAME the open reference — a bare " <>
                 "button is not an indicator that a secondary doc is open"
      end
    end

    test "the header control actually closes the secondary", %{conn: conn} do
      {view, _html} = desk_with_secondary(conn)
      _ = set_bucket(view, "narrow")

      html = render_click(view, "close-secondary", %{})

      refute html =~ ~s(data-test-id="close-secondary-bucket"),
             "once closed there is nothing to close, so the indicator must go"

      refute secondary_assign(view), "close-secondary must clear @secondary_doc"

      refute set_bucket(view, "wide") =~ ~s(data-test-id="secondary-pane"),
             "and widening must not resurrect a reference the user closed"
    end

    test "the header offers NO bucket close while the card is on screen", %{conn: conn} do
      {view, _html} = desk_with_secondary(conn)

      for bucket <- ~w(wide standard) do
        html = set_bucket(view, bucket)

        refute html =~ ~s(data-test-id="close-secondary-bucket"),
               "#{bucket}: the card's own ✕ is right there — a second close in " <>
                 "the header would be redundant chrome on the desk this epic is " <>
                 "trying to unclutter"
      end
    end
  end

  describe "criterion 1 — the D36 overflow fix is untouched" do
    # The yield is ADDITIVE. If this rule ever left the stylesheet, a surface
    # that renders `.bp-secondary-pane` without threading a bucket (a future
    # caller, a plugin, the instant between a resize and the width-bucket round
    # trip) would put a rigid 360px card back beside the protected document at
    # 375-1023px — exactly D36's measured annihilation (1024 → row overflows by
    # 80px; 600 → editor panel 240px; 500 → 140px; 375 → 15px, with
    # rowOverflow 0 in every case, so the D34 scroll valve never fires).
    #
    # The expectation is a LITERAL copied out of the stylesheet, never
    # re-derived from it (wide_geometry_lock_test's idiom, charter D94): a pin
    # that reads its own subject cannot fail from the only thing it guards.
    test "the narrow/phone display:none rule is still in root.html.heex, verbatim" do
      css = File.read!(@root)

      assert css =~
               ~s|html[data-width-bucket="narrow"] .bp-secondary-pane,\n    html[data-width-bucket="phone"] .bp-secondary-pane { display: none; }|,
             "D36's rule is the CSS half of this defence and this slice may not " <>
               "move a byte of it"
    end

    test "no configuration at narrow/phone puts a secondary card on the pane row" do
      # The Elixir half of the same claim, stated as the predicate rather than
      # as a list of the buckets that happen to exist today: the card renders
      # if and only if the bucket is one where it fits.
      alias BarkparkWeb.StudioComponents.EditorFields

      refute EditorFields.secondary_pane_bucket?("narrow")
      refute EditorFields.secondary_pane_bucket?("phone")
      assert EditorFields.secondary_pane_bucket?("standard")
      assert EditorFields.secondary_pane_bucket?("wide")
    end
  end
end
