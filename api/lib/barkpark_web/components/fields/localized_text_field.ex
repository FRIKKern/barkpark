defmodule BarkparkWeb.Components.Fields.LocalizedTextField do
  @moduledoc """
  HEEx form component for v2 `localizedText` field type
  (masterplan-20260425-085425, Phase 0 lines 55+58, Decision 15).

  One input per language listed in `field.languages`. Plain format renders
  a `<textarea>`; rich format renders a `<bp-rich-text-editor>` Web
  Component (Task #11 WI4) bridged via a hidden input + `BarkparkFieldBridge`
  hook, mirroring the v1 `richText` clause in
  `BarkparkWeb.Components.FieldInputs.input/1`.

  ## Fallback chain wiring

  When the primary translation (first explicit language in
  `field.fallback_chain`) is missing but a fallback returns a value, an
  inline `<span class="warning">` is rendered indicating which fallback
  language is in use. This is the **missing-primary warning** required by
  Phase 0 line 58. Severity is encoded as `data-severity="warning"` for
  the Phase 3 severity DSL to consume later.

  Resolution itself is delegated to `Barkpark.Content.LocalizedText.resolve/2`.

  ## Assigns

    * `:field` (required) — `%Field{type: "localizedText", languages: [...], format: :plain | :rich, fallback_chain: [...]}`
    * `:value` — `%{language => text}` map (defaults to `%{}`)
    * `:errors` — `%{language => [error_message, ...]}` (defaults to `%{}`)
    * `:on_change` — `phx-change` event name
    * `:path` — input name path (optional)
    * `:readonly` — disable each language's `<textarea>` (defaults to `false`).
  """

  use Phoenix.Component

  alias Barkpark.Content.LocalizedText

  # Mirrors the sentinel in `Barkpark.Content.LocalizedText` — used as the
  # DISPLAY fallback when a field has no configured `fallback_chain`.
  @first_non_empty "first-non-empty"

  attr :field, :map, required: true
  attr :value, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :path, :string, default: ""
  attr :readonly, :boolean, default: false

  def localized_text_field(assigns) do
    assigns =
      assigns
      |> Map.put_new(:value, %{})
      |> Map.put_new(:errors, %{})
      |> Map.put_new(:on_change, nil)
      |> Map.put_new(:path, "")
      |> Map.put_new(:readonly, false)

    field = assigns.field
    value_map = assigns.value || %{}
    languages = field.languages || []
    chain = field.fallback_chain || []

    # With no configured fallback chain (the schema-parse default `[]`),
    # `LocalizedText.resolve/2` would always return `{:error, :no_value}` and the
    # display site below would flag valid content as untranslated. For DISPLAY
    # resolution only, treat an empty chain as "first non-empty language" so a
    # field WITH content resolves and only a genuinely empty map shows the banner.
    # The stored data contract / API (which returns the full map) is untouched.
    resolve_chain = if chain == [], do: [@first_non_empty], else: chain

    primary = LocalizedText.primary_language(chain)
    resolution = LocalizedText.resolve(value_map, resolve_chain)
    warning = build_warning(primary, resolution)

    assigns =
      assigns
      |> Map.put(:title, title_for(field))
      |> Map.put(:languages, languages)
      |> Map.put(:format, field.format || :plain)
      |> Map.put(:value_map, value_map)
      |> Map.put(:warning, warning)
      |> Map.put(:resolution, resolution)
      |> Map.put(:base_id, "f-#{field.name}")
      |> Map.put(:base_path, assigns.path)

    ~H"""
    <fieldset class="bp-field bp-field-localized" data-field-type="localizedText"
              data-field-name={@field.name} data-format={Atom.to_string(@format)}>
      <legend class="bp-field-title"><%= @title %></legend>

      <%= if @warning do %>
        <span class="warning bp-localized-warning"
              data-severity="warning"
              data-missing-primary={@warning.primary}
              data-using-fallback={@warning.using}>
          primary translation `<%= @warning.primary %>` missing — using fallback `<%= @warning.using %>`
        </span>
      <% end %>

      <%= if @resolution == {:error, :no_value} and @value_map != %{} do %>
        <span class="error bp-localized-empty" data-severity="error">no translation available</span>
      <% end %>

      <%= for lang <- @languages do %>
        <div class="bp-localized-row" data-lang={lang}>
          <label class="bp-field-label" for={"#{@base_id}-#{lang}"}>
            <%= lang %><%= if @warning && @warning.primary == lang, do: " (primary, missing)" %>
          </label>
          <%= if @format == :rich do %>
            <div id={"bp-rt-wrap-#{@field.name}-#{lang}"} phx-update="ignore" phx-hook="BarkparkFieldBridge">
              <input
                type="hidden"
                id={"#{@base_id}-#{lang}"}
                name={input_name(@base_path, lang)}
                value={Map.get(@value_map, lang, "")}
                phx-debounce="500"
                data-lang={lang}
              />
              <bp-rich-text-editor
                value={Map.get(@value_map, lang, "")}
                data-bridge-target={"#{@base_id}-#{lang}"}
                data-lang={lang}
                class="bp-localized-rich"
              ></bp-rich-text-editor>
            </div>
          <% else %>
            <textarea
              class={textarea_class(@format)}
              id={"#{@base_id}-#{lang}"}
              name={input_name(@base_path, lang)}
              phx-change={@on_change}
              disabled={@readonly}
              data-lang={lang}
            ><%= Map.get(@value_map, lang, "") %></textarea>
          <% end %>
          <%= for err <- lang_errors(@errors, lang) do %>
            <span class="error" data-error-for={lang}><%= err %></span>
          <% end %>
        </div>
      <% end %>
    </fieldset>
    """
  end

  # ─── private ────────────────────────────────────────────────────────────────

  defp build_warning(nil, _), do: nil

  defp build_warning(primary, {:ok, lang, _text}) when lang != primary do
    %{primary: primary, using: lang}
  end

  defp build_warning(_, _), do: nil

  defp textarea_class(:rich), do: "bp-input bp-textarea bp-localized-rich"
  defp textarea_class(_), do: "bp-input bp-textarea"

  defp input_name("", lang), do: lang
  defp input_name(path, lang), do: "#{path}.#{lang}"

  defp lang_errors(errors, lang) when is_map(errors) do
    case Map.get(errors, lang) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp lang_errors(_, _), do: []

  defp title_for(%{title: t}) when is_binary(t) and t != "", do: t
  defp title_for(%{name: n}) when is_binary(n), do: humanize(n)
  defp title_for(_), do: ""

  defp humanize(name) do
    name
    |> String.replace(~r/[_\-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
