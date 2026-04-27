defmodule BarkparkWeb.Components.Fields.LocalizedTextField do
  @moduledoc """
  HEEx form component for v2 `localizedText` field type
  (masterplan-20260425-085425, Phase 0 lines 55+58, Decision 15).

  One input per language listed in `field.languages`. Plain format renders
  a `<textarea>`; rich format renders a `<textarea>` with a marker class
  (`bp-localized-rich`) — a richer widget is a Phase 5+ concern, not a
  Phase 0 blocker.

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
  """

  use Phoenix.Component

  alias Barkpark.Content.LocalizedText

  attr :field, :map, required: true
  attr :value, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :path, :string, default: ""

  def localized_text_field(assigns) do
    assigns =
      assigns
      |> Map.put_new(:value, %{})
      |> Map.put_new(:errors, %{})
      |> Map.put_new(:on_change, nil)
      |> Map.put_new(:path, "")

    field = assigns.field
    value_map = assigns.value || %{}
    languages = field.languages || []
    chain = field.fallback_chain || []

    primary = LocalizedText.primary_language(chain)
    resolution = LocalizedText.resolve(value_map, chain)
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
          <textarea
            class={textarea_class(@format)}
            id={"#{@base_id}-#{lang}"}
            name={input_name(@base_path, lang)}
            phx-change={@on_change}
            data-lang={lang}
          ><%= Map.get(@value_map, lang, "") %></textarea>
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
