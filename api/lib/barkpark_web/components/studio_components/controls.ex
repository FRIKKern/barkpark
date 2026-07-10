defmodule BarkparkWeb.StudioComponents.Controls do
  @moduledoc """
  **StudioComponents.Controls** — the tokenized Studio form-control kit
  (studio-ui-premium sup-w1).

  Thin function components that WRAP the CSS primitives already emitted into
  `root.html.heex` (`.btn`, `.card`/`.card-header`, `.form-input` — including
  the themed `select.form-input` and `textarea.form-input` —, `.form-checkbox`
  and `.form-switch`). Every control here draws its color from a design token
  (`var(--…)`) via those classes, so a Studio screen built on this kit has ZERO
  native/unthemed controls and passes `scripts/studio-literal-check.sh` by
  construction — no inline color literal ever appears.

  Why a kit and not raw classes at each call site: it keeps the tokenized
  markup in ONE place (label/control alignment, switch anatomy, hint color),
  so a screen reads as one designed surface instead of a scatter of ad-hoc
  `<select style="…">`. Attributes pass through (`name`, `value`, `phx-*`,
  `data-*`, `aria-*`) so LiveView forms keep working unchanged.

  This is deliberately NOT `StudioComponents.EditorFields` — that kit is
  coupled to the editor form model. These primitives are form-agnostic.

  ## Components

    * `bp_card/1` — a `.card` section with padded body (structure, not chrome).
    * `bp_section_header/1` — a weighted `<h2>` title + optional description.
    * `bp_field_row/1` — an aligned label column + control + optional hint slot.
    * `bp_input/1` — a `.form-input` text/password/url/number input.
    * `bp_textarea/1` — a `.form-input` textarea (`mono` for code/JSON).
    * `bp_select/1` — a themed `select.form-input` (no native dropdown chrome).
    * `bp_switch/1` — the `.form-switch` track+thumb over a real checkbox.
    * `bp_checkbox/1` — a `.form-checkbox` labeled checkbox.
    * `bp_radio/1` — a `.form-radio` labeled radio for one-of-N choices.
  """
  use Phoenix.Component

  @doc """
  A `.card` section: tokenized surface + border + radius, with a padded body.

  Pass `aria-labelledby` (or any `aria-*`/`data-*`) through — they land on the
  `<section>`. The body slot holds a `bp_section_header` plus the section's
  controls.
  """
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def bp_card(assigns) do
    ~H"""
    <section id={@id} class={["card" | List.wrap(@class)]} style="margin-bottom: 24px;" {@rest}>
      <div style="padding: 20px 24px;">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc """
  A weighted section header — a `.h2` title with an optional description line.

  The description renders through the inner block and uses `var(--fg-muted)`
  for a legible (not dim) secondary tone. Pass `id` so a wrapping card can
  point its `aria-labelledby` at the title.
  """
  attr :id, :string, default: nil
  attr :title, :string, required: true
  slot :inner_block

  def bp_section_header(assigns) do
    ~H"""
    <div style="margin-bottom: 16px;">
      <h2 id={@id} class="h2" style="margin: 0;">{@title}</h2>
      <p :if={@inner_block != []} class="text-sm" style="margin: 6px 0 0; color: var(--fg-muted);">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  @doc """
  An aligned field row: a fixed label column + the control + an optional hint.

  The label column is a fixed width so successive rows align into a clean
  control column (premium-tool rhythm). The `hint` slot renders under the
  control in `var(--muted-text)` — never `--fg-dim`, so a hint stays readable
  against the theme background (WCAG AA).
  """
  attr :label, :string, required: true
  attr :for, :string, default: nil
  attr :required, :boolean, default: false
  slot :inner_block, required: true
  slot :hint

  def bp_field_row(assigns) do
    ~H"""
    <div style="display: grid; grid-template-columns: minmax(0, 12rem) minmax(0, 1fr); gap: 16px; align-items: start; margin-bottom: 16px;">
      <label class="form-label" for={@for} style="margin: 8px 0 0;">
        {@label}<span :if={@required} style="color: var(--destructive); margin-left: 2px;">*</span>
      </label>
      <div style="min-width: 0;">
        {render_slot(@inner_block)}
        <p :if={@hint != []} class="text-sm" style="margin: 6px 0 0; color: var(--muted-text);">
          {render_slot(@hint)}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  A tokenized text-like input (`.form-input`). `type` may be any HTML text
  input type (text, password, url, number, email, …).
  """
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :type, :string, default: "text"
  attr :id, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(autocomplete readonly form list inputmode pattern)

  def bp_input(assigns) do
    ~H"""
    <input
      type={@type}
      name={@name}
      id={@id}
      value={@value}
      placeholder={@placeholder}
      required={@required}
      disabled={@disabled}
      class={["form-input" | List.wrap(@class)]}
      {@rest}
    />
    """
  end

  @doc """
  A tokenized textarea (`textarea.form-input`). Set `mono` for code/JSON,
  which switches the face to `var(--font-mono)` (still a token — no literal).

  `class` appends to the base `form-input` (mirrors `bp_input`) so a call site
  can carry a sizing/idiom class (e.g. the API tester's `api-body-textarea`
  min-height + mono face) without dropping the themed base. `spellcheck` rides
  the `:rest` passthrough for code fields that want the red squiggle off.
  """
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :id, :string, default: nil
  attr :rows, :integer, default: 6
  attr :placeholder, :string, default: nil
  attr :mono, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(readonly form spellcheck)

  def bp_textarea(assigns) do
    ~H"""
    <textarea
      name={@name}
      id={@id}
      rows={@rows}
      placeholder={@placeholder}
      class={["form-input" | List.wrap(@class)]}
      style={@mono && "font-family: var(--font-mono);"}
      {@rest}
    >{@value}</textarea>
    """
  end

  @doc """
  A themed select (`select.form-input`) — no native dropdown chrome. `options`
  is a list of either scalars (`"evergreen"`), `{value, label}` tuples, or
  `{group_label, [option, …]}` tuples (a nested list becomes an `<optgroup>`);
  the option whose value matches `value` is marked `selected`.

  Pass `prompt` to lead with a disabled, value-less placeholder option
  (selected while `value` is blank) — the "Choose a field…" affordance.
  """
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true
  attr :prompt, :string, default: nil
  attr :id, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(form)

  def bp_select(assigns) do
    assigns = assign(assigns, :entries, normalize_options(assigns.options))

    ~H"""
    <select name={@name} id={@id} disabled={@disabled} class="form-input" {@rest}>
      <option :if={@prompt} value="" disabled selected={to_string(@value) == ""}>{@prompt}</option>
      <%= for entry <- @entries do %>
        <%= case entry do %>
          <% {:optgroup, group_label, opts} -> %>
            <optgroup label={group_label}>
              <option
                :for={{val, label} <- opts}
                value={val}
                selected={to_string(@value) == val}
              >{label}</option>
            </optgroup>
          <% {val, label} -> %>
            <option value={val} selected={to_string(@value) == val}>{label}</option>
        <% end %>
      <% end %>
    </select>
    """
  end

  @doc """
  The Sanity-style switch (`.form-switch`): a track + thumb driven by a real,
  visually-hidden checkbox (keeps form semantics, keyboard toggle and a11y).
  The on/off state is also stated in words via `.form-switch-state`.

  Pass `phx-click`/`phx-change` + `phx-value-*` (accepted as globals) to wire
  it to a LiveView event, and `aria-label` when the switch stands alone with
  no adjacent text label.
  """
  attr :name, :string, default: nil
  attr :checked, :boolean, default: false
  attr :on_label, :string, default: "On"
  attr :off_label, :string, default: "Off"
  attr :id, :string, default: nil
  attr :value, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(form)

  def bp_switch(assigns) do
    ~H"""
    <label class="form-switch">
      <input
        type="checkbox"
        name={@name}
        id={@id}
        value={@value}
        checked={@checked}
        disabled={@disabled}
        {@rest}
      />
      <span class="form-switch-track" aria-hidden="true"></span>
      <%!-- Both words ship in the DOM and CSS `:checked` picks the visible one,
            so the word stays truthful when the switch toggles inside a
            submit-only form (no LiveView re-render — e.g. plugin settings).
            aria-hidden: the real checkbox announces state to AT. --%>
      <span class="form-switch-state" aria-hidden="true"><span class="form-switch-state-off">{@off_label}</span><span class="form-switch-state-on">{@on_label}</span></span>
    </label>
    """
  end

  @doc """
  A tokenized labeled checkbox (`.form-checkbox`) — accent-color themed, for
  the cases a plain check (not a switch) is the right affordance.
  """
  attr :name, :string, default: nil
  attr :label, :string, required: true
  attr :checked, :boolean, default: false
  attr :id, :string, default: nil
  attr :value, :string, default: nil
  attr :rest, :global, include: ~w(form)

  def bp_checkbox(assigns) do
    ~H"""
    <label class="form-checkbox">
      <input
        type="checkbox"
        name={@name}
        id={@id}
        value={@value}
        checked={@checked}
        {@rest}
      />
      <span>{@label}</span>
    </label>
    """
  end

  @doc """
  A tokenized labeled radio (`.form-radio`) — the `bp_checkbox` sibling for
  one-of-N choices. Give sibling radios the same `name` so the browser groups
  them; the real `<input type="radio">` keeps form semantics, keyboard arrows
  and a11y. The label rides the `inner_block` slot so callers write the choice
  text (or richer markup) inline:

      <.bp_radio name="duration" value="1d" checked>1 day</.bp_radio>
  """
  attr :name, :string, default: nil
  attr :checked, :boolean, default: false
  attr :id, :string, default: nil
  attr :value, :string, default: nil
  attr :rest, :global, include: ~w(form required)
  slot :inner_block, required: true

  def bp_radio(assigns) do
    ~H"""
    <label class="form-radio">
      <input
        type="radio"
        name={@name}
        id={@id}
        value={@value}
        checked={@checked}
        {@rest}
      />
      <span>{render_slot(@inner_block)}</span>
    </label>
    """
  end

  # Option normalization: a scalar becomes `{v, v}`, a `{value, label}` tuple is
  # stringified, and a `{group_label, [option, …]}` tuple (nested list) becomes
  # an `{:optgroup, label, [{val, label}, …]}` entry the renderer draws as an
  # `<optgroup>`.
  defp normalize_options(options) do
    Enum.map(options, fn
      {group_label, opts} when is_list(opts) ->
        {:optgroup, to_string(group_label), Enum.map(opts, &normalize_leaf/1)}

      leaf ->
        normalize_leaf(leaf)
    end)
  end

  defp normalize_leaf({value, label}), do: {to_string(value), to_string(label)}
  defp normalize_leaf(value), do: {to_string(value), to_string(value)}
end
