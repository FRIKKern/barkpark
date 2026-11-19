defmodule BarkparkWeb.Studio.Desk.LocalizedStyle do
  @moduledoc """
  The look of a localizedText field's language tabs in the desk's form
  (`LocalizedTabs`), the TanStack Studio's (barkpark-studio
  `app/src/styles.css`: `.localized`, `.lang-tabs`, `.localized-warning`),
  in the desk's own colour tokens, so it follows light and dark.

    * The field is a plain field, its title over the tabs: not the boxed
      fieldset the old Studio draws for it.
    * The tabs sit in a row 2 px apart, 6 px over the text. A tab is the
      language code in 12 px semibold capitals, muted, 4 × 10 px in; filled
      under the pointer; the selected one on the strong fill in the field's ink.
    * A language with text carries a 5 px dot in the published green.
    * The status line under the text is 12 px in the warning ink.

  `DocStyle.sheet/1` draws these rules with the rest of the edit pane's.
  """

  @doc "The rules, for the edit pane's sheet."
  @spec css() :: String.t()
  def css do
    """
    .dk .dk-edit .bp-field-localized:has(> .localized) { margin: 0; padding: 0; border: 0; border-radius: 0; background: none; min-inline-size: 0; }
    .dk .dk-edit .localized { display: flex; flex-direction: column; gap: 6px; }
    .dk .dk-edit .lang-tabs { display: flex; gap: 2px; }
    .dk .dk-edit .lang-tabs [role=tab] { position: relative; padding: 4px 10px; border: 0; border-radius: 3px; background: none; font: inherit; font-size: 12px; font-weight: 600; text-transform: uppercase; color: var(--dk-muted); cursor: pointer; }
    .dk .dk-edit .lang-tabs [role=tab]:hover { background: var(--dk-card-hover); }
    .dk .dk-edit .lang-tabs [role=tab][aria-selected=true] { background: var(--dk-hover-strong); color: var(--dk-fg); }
    .dk .dk-edit .lang-tabs [role=tab]:focus-visible { outline: none; box-shadow: 0 0 0 1px var(--dk-bg), 0 0 0 3px var(--dk-focus-ring); }
    .dk .dk-edit .lang-tabs .filled { display: inline-block; width: 5px; height: 5px; margin-left: 5px; vertical-align: middle; border-radius: 50%; background: var(--dk-published); }
    .dk .dk-edit .localized-warning { margin: 0; font-size: 12px; color: var(--dk-warn-fg); }
    .dk .dk-edit .lang-tabs .has-error { display: inline-block; width: 5px; height: 5px; margin-left: 5px; vertical-align: middle; border-radius: 50%; background: var(--dk-critical-icon); }
    .dk .dk-edit .localized [role=tabpanel] > .error { display: block; margin-top: 4px; font-size: 12px; color: var(--dk-danger-text); }
    @media (pointer: coarse) { .dk .dk-edit .lang-tabs [role=tab] { min-width: 44px; min-height: 44px; } }
    """
  end
end
