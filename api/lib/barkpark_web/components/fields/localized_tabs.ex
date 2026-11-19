defmodule BarkparkWeb.Components.Fields.LocalizedTabs do
  @moduledoc """
  A `localizedText` field in the desk: one tab per language, as the TanStack
  Studio draws it (barkpark-studio `LocalizedTextInput`, B06).

    * The tabs are a `tablist` named by the field's title. The field opens on
      its primary language, the first of `fallbackChain` it lists (else the
      first language). A language that holds text carries a dot, named
      ", has text".
    * One tab is in the Tab order; ArrowLeft and ArrowRight move to the
      previous and the next language (round), Home and End to the first and
      the last (`bp-desk-lang-tabs.js`). Tab goes on to that language's text.
    * Every language's control is in the form, its panel hidden unless its tab
      is selected, so the form posts each language under its own name
      (`doc[blurb].nob`), as the rows did. A tab's click is a `Phoenix.LiveView.JS`
      command: the browser selects it, nothing goes to the server, and the
      choice stays when the server redraws the field.
    * With the primary empty, a status line says which language readers get.

  The old Studio keeps its rows (`LocalizedTextField`): this is drawn only
  where the field has an `:id_base`, the desk.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Components.Fields.LocalizedTextField
  alias Phoenix.LiveView.JS

  @doc "The field, from `LocalizedTextField`'s assigns (with `:id_base`)."
  def localized_tabs(assigns) do
    field = assigns.field
    map = if is_map(assigns.value), do: assigns.value, else: %{}
    langs = languages(field.languages, map)
    primary = primary(field.fallback_chain || [], langs)

    # Called by hand from `Plugins.Adapter` (a plain map), as the rows are.
    assigns =
      Map.merge(assigns, %{
        langs: langs,
        primary: primary,
        map: map,
        fallback: fallback(map, primary, field.fallback_chain || [], langs),
        format: field.format || :plain,
        title: title(field),
        base: assigns.id_base
      })

    ~H"""
    <fieldset class="bp-field bp-field-localized" data-field-type="localizedText"
              data-field-name={@field.name} data-format={Atom.to_string(@format)}>
      <legend class="bp-field-title" id={@base <> "-label"}><%= @title %></legend>
      <div :if={@primary} class="localized" id={@base <> "-localized"}>
        <div class="lang-tabs" role="tablist" id={@base <> "-tabs"} aria-labelledby={@base <> "-label"}>
          <button
            :for={lang <- @langs}
            type="button"
            role="tab"
            id={tab_id(@base, lang)}
            data-lang={lang}
            aria-selected={to_string(lang == @primary)}
            aria-controls={panel_id(@base, lang)}
            tabindex={if lang == @primary, do: "0", else: "-1"}
            title={lang_label(lang, @primary)}
            phx-click={select(@base, lang)}
          ><%= lang %><span :if={filled?(@map, lang)} class="filled" aria-label={gettext(", has text")}></span></button>
        </div>
        <div id={@base <> "-panels"}>
          <div
            :for={lang <- @langs}
            role="tabpanel"
            id={panel_id(@base, lang)}
            aria-labelledby={tab_id(@base, lang)}
            hidden={lang != @primary}
          >
            <LocalizedTextField.lang_control
              field_name={@field.name}
              lang={lang}
              format={@format}
              value={text(@map, lang)}
              id={@base <> "." <> lang}
              name={input_name(@path, lang)}
              on_change={@on_change}
              readonly={@readonly}
              wrap_key={@wrap_key}
              title={@title}
              aria_label={lang_label(lang, @primary)}
            />
          </div>
        </div>
        <p :if={@fallback} class="localized-warning" role="status">
          <%= gettext("No %{primary} text: readers get the %{fallback} text instead.", primary: @primary, fallback: @fallback) %>
        </p>
      </div>
    </fieldset>
    """
  end

  # A tab's click: it is selected and in the Tab order, the others are not,
  # and its panel is the one shown. JS commands outlive the server's redraws.
  defp select(base, lang) do
    tabs = ~s([id="#{base}-tabs"] > [role="tab"])
    panels = ~s([id="#{base}-panels"] > [role="tabpanel"])

    JS.set_attribute({"aria-selected", "false"}, to: tabs)
    |> JS.set_attribute({"tabindex", "-1"}, to: tabs)
    |> JS.set_attribute({"aria-selected", "true"})
    |> JS.set_attribute({"tabindex", "0"})
    |> JS.set_attribute({"hidden", ""}, to: panels)
    |> JS.remove_attribute("hidden", to: ~s([id="#{panel_id(base, lang)}"]))
  end

  defp input_name("", lang), do: lang
  defp input_name(path, lang), do: path <> "." <> lang

  defp tab_id(base, lang), do: "#{base}-tab-#{lang}"
  defp panel_id(base, lang), do: "#{base}-panel-#{lang}"

  # The field's languages; with none declared, the ones its value holds.
  defp languages([_ | _] = langs, _map), do: langs
  defp languages(_none, map), do: map |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort()

  defp primary(chain, langs), do: Enum.find(chain, &(&1 in langs)) || List.first(langs)

  # What readers get when the primary is empty: the chain's next filled
  # language, else any filled one.
  defp fallback(map, primary, chain, langs) do
    if filled?(map, primary),
      do: nil,
      else: Enum.find(chain ++ langs, &(&1 in langs and filled?(map, &1)))
  end

  defp filled?(map, lang), do: text(map, lang) != ""

  defp text(map, lang) do
    case Map.get(map, lang) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp lang_label(lang, lang), do: gettext("%{lang} (primary)", lang: lang)
  defp lang_label(lang, _primary), do: lang

  defp title(%{title: t}) when is_binary(t) and t != "", do: t

  defp title(%{name: n}) when is_binary(n),
    do: n |> String.replace(~r/[_\-]+/, " ") |> String.capitalize()

  defp title(_), do: ""
end
