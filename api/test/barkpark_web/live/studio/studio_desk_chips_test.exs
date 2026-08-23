defmodule BarkparkWeb.Studio.StudioDeskChipsTest do
  @moduledoc """
  spd-w18-desk-chips-answer — the desk filter chips answer when touched.

  Before this slice the chips claimed `role="tablist"`/`role="tab"` with
  `aria-selected={active}` — no aria-controls, no tabpanel anywhere in the
  Studio tree, no roving tabindex; HEEx rendered the boolean as a BARE
  VALUELESS `aria-selected` when true and omitted it when false (neither a
  valid ARIA boolean); and `role="tab"` on an `<a href>` overwrote the link
  role, so AT stopped announcing a control that navigates. Per charter D244
  (and D79: an ARIA state attribute that never changes truthfully is worse
  than its absence) the resolution is to DROP the fake tab semantics — the
  chips are plain links, every one Tab-reachable — and speak selection as
  `aria-current="true"`, the desk rows' own vocabulary (documented once, in
  `StudioComponents.Panes`' moduledoc).

  ZERO tests rendered a chip before this file (grep for bp-desk-chip over
  api/test returned nothing), which is how the bare-valueless-attribute
  markup shipped unseen.

  The keyboard-operability arm for the bulk checkbox rides here too: the
  spd-bl-doc-checkbox slice made it a real `<button role="checkbox">`
  (attributes pinned in panes_test.exs); this file drives the ACTIVATION
  path through a mounted desk and asserts selection actually toggles —
  a role without an activation path is not operability. A native button's
  Enter/Space produce exactly the click event driven here.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Repo

  @dataset "production"

  setup do
    # Direct SchemaDefinition insert: `desk_groups` is a top-level schema
    # column (not a field), and this pins the two-chip shape deterministically.
    %Barkpark.Content.SchemaDefinition{}
    |> Barkpark.Content.SchemaDefinition.changeset(%{
      name: "post",
      title: "Posts",
      visibility: "public",
      dataset: @dataset,
      fields: [%{"name" => "title", "title" => "Title", "type" => "string"}],
      desk_groups: [
        %{"name" => "news", "title" => "News"},
        %{"name" => "docs", "title" => "Docs"}
      ]
    })
    |> Repo.insert!()

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "chips-probe-post", "title" => "Chips Probe", "content" => %{}},
        @dataset
      )

    :ok
  end

  defp chips(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(".bp-desk-chip")
    |> Enum.to_list()
  end

  test "chips are plain links: aria-current on the active one, silence on the rest, no tab lies",
       %{conn: conn} do
    {:ok, _view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/post") <> "?desk=news")

    # The STRIP claims no tab semantics — scoped to the chip strip's own
    # subtree (the editor's field-group tabs elsewhere on the page are a
    # different surface and not this task's subject).
    strip_html =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".bp-desk-filter")
      |> Enum.map(&LazyHTML.to_html/1)
      |> Enum.join()

    assert strip_html != "", "the desk chip strip must render for a desk-grouped schema"
    refute strip_html =~ ~s(role="tablist"), "the fake tablist must be gone (charter D244)"
    refute strip_html =~ ~s(role="tab"), "role=tab on an <a href> overwrites the link role"

    refute strip_html =~ "aria-selected",
           "aria-selected is only meaningful inside a real tablist"

    assert [_, _] = all = chips(html)

    {active, inactive} =
      case all do
        [a, b] ->
          if LazyHTML.attribute(a, "aria-current") != [], do: {a, b}, else: {b, a}
      end

    # The active chip announces itself with a REAL boolean value — never the
    # bare valueless attribute the old aria-selected={true} rendered.
    assert LazyHTML.attribute(active, "aria-current") == ["true"],
           "active chip markup: #{LazyHTML.to_html(active)}"

    assert active |> LazyHTML.text() |> String.trim() == "News"

    # The inactive chip is silent — no aria-current at all, valueless or not.
    assert LazyHTML.attribute(inactive, "aria-current") == [],
           "inactive chip markup: #{LazyHTML.to_html(inactive)}"

    # Both remain LINKS (Tab-reachable; N tab stops is the correct link
    # grammar — a roving one-tab-stop pattern belongs to the tablist D244
    # rejected).
    for chip <- all do
      assert LazyHTML.attribute(chip, "href") != [], LazyHTML.to_html(chip)
      assert LazyHTML.attribute(chip, "role") == [], LazyHTML.to_html(chip)
    end
  end

  test "the bulk checkbox ACTIVATION path toggles selection through a mounted desk",
       %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post"))

    selector = ~s([data-test-id="doc-checkbox-chips-probe-post"])
    assert html =~ ~s(data-test-id="doc-checkbox-chips-probe-post")

    # Activate (a native <button>'s Enter/Space produce exactly this click).
    html2 = view |> element(selector) |> render_click()

    [box] = html2 |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.to_list()

    assert LazyHTML.attribute(box, "aria-checked") == ["true"],
           "activation must TOGGLE selection, not only carry attributes"

    assert html2 =~ "is-bulk-checked"

    # …and activating again unchecks.
    html3 = view |> element(selector) |> render_click()
    [box3] = html3 |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.to_list()
    assert LazyHTML.attribute(box3, "aria-checked") == ["false"]
    refute html3 =~ "is-bulk-checked"
  end
end
