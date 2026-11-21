defmodule BarkparkWeb.Studio.Desk.ReadonlyFields do
  @moduledoc """
  The fields of a document shown read-only in the desk, the published
  version (`PublishedView`) or an old revision (`RevisionView`), sit in a
  disabled fieldset; the field group tabs above them do not, so they still
  switch groups, as the TanStack Studio's do (`select-group` writes nothing
  and both views take it). Nothing in the fields can be typed in or pressed,
  and a write sent anyway is refused (`PublishedView.refuses?/2`,
  `RevisionView.refuses?/2`).

  The holder around the whole form (`EditorHost`) is not disabled: the
  shell's own header controls are hidden in the desk, and their events are
  refused in both views.

  Outside the desk the panel is drawn as it was, with no fieldset.
  """

  use Phoenix.Component

  alias BarkparkWeb.Studio.Desk.{PublishedView, RevisionView}

  attr :parent_assigns, :map, required: true
  slot :inner_block, required: true

  @doc "The group tabs' panel, in a fieldset that is disabled while a read-only view is shown."
  def fields(%{parent_assigns: %{desk_base: base} = parent} = assigns) when is_binary(base) do
    assigns = assign(assigns, :readonly, readonly?(parent))

    ~H"""
    <fieldset class="dk-readonly-fields" disabled={@readonly} data-desk-readonly-fields={@readonly}>
      {render_slot(@inner_block)}
    </fieldset>
    """
  end

  def fields(assigns) do
    ~H"""
    {render_slot(@inner_block)}
    """
  end

  @doc "Whether the desk shows the published version or an old revision in the form's place."
  def readonly?(assigns), do: RevisionView.shown?(assigns) or PublishedView.shown?(assigns)

  @doc """
  Whether `event` is refused by either view, as the editor's guard refuses it
  (`EditorHost`). A control drawn for an event, such as the conflict banner's
  Reload, is disabled exactly when this holds, so it is never drawn live and
  then refused.
  """
  def refused?(event, assigns),
    do: RevisionView.refuses?(event, assigns) or PublishedView.refuses?(event, assigns)
end
