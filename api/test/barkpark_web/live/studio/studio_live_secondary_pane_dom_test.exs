defmodule BarkparkWeb.StudioLiveSecondaryPaneDomTest do
  @moduledoc """
  The secondary picker's CLIENT-SIDE contract, asserted on rendered markup.

  Charter D96. This modal shipped dead: `.modal-card` carried an inline
  `onclick="event.stopPropagation()"`, and because LiveView's click handling
  is window-delegated that one attribute killed every `phx-click` inside the
  card — the ✕ did not close, no candidate selected, no flash, no console
  error, and the tell was that the modal simply stayed open. Every server
  handler was innocent the whole time.

  Five waves of green tests could not see it, and the reason is a lesson about
  test SHAPE, not test COUNT: the only covering test drove
  `render_click(view, "select-secondary", …)` over the socket. That invokes the
  handler directly and never touches the DOM, so it is structurally incapable
  of observing a client-side dispatch defect. A replacement that also drives
  the handler would prove exactly as little.

  So this file drives nothing. It renders the component and asserts on the
  markup a browser would actually receive: no inline event-handler attribute
  anywhere in the modal, the dismiss scoped by containment (`phx-click-away`
  on the card) rather than by cancelling events on the backdrop, and the
  interactive controls still carrying their bindings inside the card. It fails
  the moment the stop-propagation attribute is re-added.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.StudioComponents.EditorFields

  @candidates [
    %{id: "p1", title: "Alpha paper"},
    %{id: "p2", title: "Beta paper"}
  ]

  defp picker_html(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          show_secondary_picker: true,
          secondary_search: "",
          secondary_candidates: @candidates
        },
        overrides
      )

    render_component(&EditorFields.secondary_picker_modal/1, assigns)
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp query(html, selector), do: html |> doc() |> LazyHTML.query(selector)

  # Every attribute name on every element in the fragment.
  defp attr_names(html) do
    html
    |> query("*")
    |> LazyHTML.attributes()
    |> Enum.flat_map(fn attrs -> Enum.map(attrs, fn {name, _value} -> name end) end)
  end

  describe "no inline event handlers survive in the picker markup" do
    test "the modal card carries no onclick at all" do
      html = picker_html()

      refute html =~ "onclick",
             "the picker card must carry no inline onclick — a window-delegated " <>
               "LiveView click cannot survive one (charter D96)"

      refute html =~ "stopPropagation",
             "stop-propagation inside the card kills every phx-click in it"
    end

    test "no element anywhere in the modal carries any inline on* handler" do
      offenders =
        picker_html()
        |> attr_names()
        |> Enum.filter(&String.starts_with?(&1, "on"))
        |> Enum.uniq()

      assert offenders == [],
             "inline event handlers found in the secondary picker: #{inspect(offenders)} — " <>
               "the intent they serve must be expressed without cancelling delegated events"
    end
  end

  describe "the dismiss is scoped by containment, not by cancelling events" do
    test "the backdrop does not carry its own phx-click dismiss" do
      backdrop = picker_html() |> query(~s([data-test-id="secondary-picker-modal"]))

      assert Enum.count(backdrop) == 1

      assert LazyHTML.attribute(backdrop, "phx-click") == [],
             "a phx-click dismiss on the backdrop is what created the pressure to " <>
               "cancel events on the card; scope the dismiss instead"
    end

    test "the card dismisses on click-away and on escape" do
      card = picker_html() |> query(".modal-card")

      assert Enum.count(card) == 1
      assert LazyHTML.attribute(card, "phx-click-away") == ["close-secondary-picker"]
      assert LazyHTML.attribute(card, "phx-window-keydown") == ["close-secondary-picker"]
      assert LazyHTML.attribute(card, "phx-key") == ["escape"]
    end
  end

  describe "the controls inside the card still carry live bindings" do
    test "the closing control is inside the card and fires close-secondary-picker" do
      closer = picker_html() |> query(~s(.modal-card button[phx-click="close-secondary-picker"]))

      assert Enum.count(closer) == 1,
             "the ✕ must live inside the card and carry its own phx-click — it is the " <>
               "cheapest regression signal this defect has"
    end

    test "every candidate row is inside the card and fires select-secondary with its id" do
      rows = picker_html() |> query(~s(.modal-card li[phx-click="select-secondary"]))

      assert Enum.count(rows) == length(@candidates)
      assert LazyHTML.attribute(rows, "phx-value-id") == Enum.map(@candidates, & &1.id)

      assert LazyHTML.attribute(rows, "data-test-id") ==
               Enum.map(@candidates, &"secondary-candidate-#{&1.id}")
    end

    test "the empty state renders instead of rows when the filter matches nothing" do
      html = picker_html(%{secondary_search: "no-such-document"})

      assert html =~ "bp-secondary-empty"
      refute html =~ ~s(phx-click="select-secondary")
    end
  end

  test "nothing renders while the picker is closed" do
    assert picker_html(%{show_secondary_picker: false}) |> String.trim() == ""
  end
end
