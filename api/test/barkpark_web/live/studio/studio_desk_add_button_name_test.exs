defmodule BarkparkWeb.Studio.StudioDeskAddButtonNameTest do
  @moduledoc ~S"""
  spd-w18: the desk's "+" button says what it makes, out loud.

  The fourth thing PR #7567 landed and did not guard. `aria-label={"New
  #{pane.type_name}"}` was deleted from `studio_live/components.ex` with the
  three focus rings and the gate #7567 cited stayed green at 1747 tests, 0
  failures. Without it this button's content is a single decorative
  `<svg aria-hidden="true">`, so its accessible name is the empty string and
  a screen reader announces "button" — the owner's complaint ("the buttons
  looked inert") in its literal form.

  Why this lives at LiveView level and not next to the ring guard in
  `test/barkpark_web/components/`: the button is inline HEEx inside
  `studio_live_shell/1`, not an extractable function component, so the only
  place its rendered attributes exist is a mounted desk. The ring guard reads
  the sheet; this one reads the DOM.

  The assertion is the binary the DOM answers, not a string match on a
  particular wording: find the create control for a known post type, compute
  its accessible name, and require it to be non-empty and not the doc-agnostic
  glyph. Renaming "New author" to "Create author" must NOT red; deleting the
  label must.

  Harness copied from `desk_row_ladder_test.exs` — an isolated
  workspace/project/dataset with one taxonomy-group type, so `/studio/author`
  resolves to a doclist pane (a pane only renders "+" when it has a
  `type_name`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ws_slug "desk-addbtn-ws"
  @proj_slug "desk-addbtn-proj"
  @dataset "desk-addbtn-ds"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()

    {:ok, ws} = Tenancy.create_workspace(%{slug: @ws_slug, name: "DeskAddBtnWS"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: @proj_slug, name: "DeskAddBtnProj"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "DeskAddBtn"})

    raw = "desk-addbtn-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "desk-addbtn", "production", ["read", "write"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "member")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Authors",
          "icon" => "user",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset,
        scope
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn}
  end

  # The accessible name of an icon-only <button>: aria-label wins, then the
  # (aria-hidden-stripped) text content. `title` is the fallback of LAST
  # resort and deliberately does not count here — it is mouse-hover only in
  # several AT/browser pairs, which is exactly the trap this guard exists for.
  defp accessible_name(button) do
    case LazyHTML.attribute(button, "aria-label") do
      [label | _] -> String.trim(label)
      [] -> button |> LazyHTML.text() |> String.trim()
    end
  end

  defp desk(conn, selector) do
    {:ok, _view, html} =
      live(conn, "/w/#{@ws_slug}/p/#{@proj_slug}/d/#{@dataset}/studio/author")

    html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.to_list()
  end

  test "every create control in the Authors pane has a non-empty accessible name",
       %{conn: conn} do
    # Two render here: the header "+" and the empty-list CTA (the latter is
    # already guarded for existence in studio_live_empty_pane_test.exs — this
    # covers its NAME, which nothing did).
    buttons = desk(conn, ~s(button[phx-click="new-document"][phx-value-type="author"]))

    assert buttons != [],
           "the Authors pane rendered no create control at all — this guard is " <>
             "pointing at markup that moved (spd-w18)"

    for button <- buttons do
      name = accessible_name(button)

      refute name == "",
             """
             A desk create control has NO accessible name.

             With only a decorative <svg aria-hidden="true"> inside, a screen
             reader announces a bare "button" and a keyboard user has no way
             to know what it makes. Restore the aria-label on the
             new-document button in
             lib/barkpark_web/live/studio/studio_live/components.ex.

             Rendered: #{LazyHTML.to_html(button)}
             """

      # It names the THING, not the glyph: "+" would technically be non-empty
      # and still tell a listener nothing.
      refute String.downcase(name) in ["+", "plus", "add", "new"],
             ~s(a create control's name must say what it creates, not name ) <>
               ~s(the glyph — got #{inspect(name)})
    end
  end

  # spd-w18-share-access-btn-names: the two share-access controls that sit in
  # the SAME pane header as the "+" — icon-only over an aria-hidden svg, so
  # like the "+" their accessible name exists solely because of aria-label
  # (title= does not count; accessible_name/1 above ignores it on purpose).
  for {event, what} <- [
        {"airdrop-open", "share-access entry"},
        {"access-open", "access-panel entry"}
      ] do
    test "the pane-header #{what} (#{event}) has a non-empty accessible name",
         %{conn: conn} do
      event = unquote(event)
      what = unquote(what)

      [button] = desk(conn, ~s(button.pane-add-btn[phx-click="#{event}"]))

      # aria-label itself must carry the name: with only a decorative
      # <svg aria-hidden="true"> inside, stripped text is empty, so an empty
      # or absent aria-label leaves AT announcing a bare "button".
      assert [label | _] = LazyHTML.attribute(button, "aria-label"),
             """
             The #{what} (phx-click=#{event}) renders with NO aria-label.

             Its only content is a decorative <svg aria-hidden="true"> and its
             title= is mouse-hover only in several AT/browser pairs, so its
             accessible name is the EMPTY STRING. Restore the aria-label in
             lib/barkpark_web/live/studio/studio_live/components.ex.

             Rendered: #{LazyHTML.to_html(button)}
             """

      assert String.trim(label) != "",
             "the #{what}'s aria-label is present but blank — that is still " <>
               "an empty accessible name (phx-click=#{event})"
    end
  end

  test ~s(the header "+" button names the post type it creates), %{conn: conn} do
    # Scoped to `.pane-add-btn`: this is the icon-only one, the only control on
    # the desk whose name exists SOLELY because of its aria-label. The
    # empty-list CTA has visible text and is excluded on purpose.
    [button] =
      desk(conn, ~s(button.pane-add-btn[phx-click="new-document"][phx-value-type="author"]))

    name = accessible_name(button)

    assert String.downcase(name) =~ "author",
           ~s[the "+" button should name its post type ("New author"), so a ] <>
             ~s[listener knows which pane's + they are on; got #{inspect(name)}]
  end
end
