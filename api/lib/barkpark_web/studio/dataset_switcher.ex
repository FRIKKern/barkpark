defmodule BarkparkWeb.Studio.DatasetSwitcher do
  @moduledoc """
  Function component: renders a <select> of known datasets that navigates
  to `/studio/:new_dataset[/:subpath]` on change, preserving the current
  section (structure / media / api-tester).

  The section is DERIVED from `current_path` by `BarkparkWeb.Studio.Section`
  — the raw suffix is carried in the `data-section-suffix` attribute and read
  by the (now static, CSP-hashable) onchange handler as
  `this.dataset.sectionSuffix`, with no JS quoting (the browser stores and
  returns the literal string).
  """

  use Phoenix.Component

  alias Barkpark.Content
  alias BarkparkWeb.Studio.Section

  attr :current, :string, required: true
  attr :current_path, :string, default: nil

  def switcher(assigns) do
    datasets = Content.list_datasets()
    assigns = assign(assigns, :datasets, datasets)

    ~H"""
    <label class="dataset-switcher">
      <span class="dataset-switcher-label">Dataset</span>
      <%!-- `form-input` gives the select the themed chrome (appearance:none,
            token border/bg/text, the custom caret, the focus ring) so no
            native unthemed dropdown leaks; `dataset-switcher-select` layers
            the compact top-bar sizing on top (sup-w1 PART C). --%>
      <select
        class="dataset-switcher-select form-input"
        data-section-suffix={Section.suffix(@current_path, @current)}
        onchange={BarkparkWeb.CSP.dataset_switch_onchange()}
      >
        <%= for ds <- @datasets do %>
          <option value={ds} selected={ds == @current}><%= ds %></option>
        <% end %>
      </select>
    </label>
    """
  end
end
