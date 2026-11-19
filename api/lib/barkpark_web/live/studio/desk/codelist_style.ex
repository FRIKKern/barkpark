defmodule BarkparkWeb.Studio.Desk.CodelistStyle do
  @moduledoc """
  The look of a tree codelist in the desk's form (`TreeCodelistDesk`), the
  TanStack Studio's (barkpark-studio `app/src/styles.css`, B05:
  `.codelist-tree-field`, `.codelist-current`, `.codelist-search`,
  `.codelist-tree`), in the desk's own colour tokens, so it follows light and
  dark with the rest of the desk.

    * No box around the field (the Studio's codelist box is the old
      Studio's); the current code, the search and the tree stack 6 px apart.
    * The current code line is 13 px: the code in mono, its label path in
      the text colour (red "Not in the list" for a code the list does not
      hold), and a 25 px × at its end.
    * The search box is the desk's text input; "Clear" is a ghost button.
    * The tree is 280 px at most and scrolls, ringed 1 px; a row is 13 px,
      4 px over and under, lit under the pointer, filled when it is the
      picked code, and outlined in the selection blue when the keys put the
      focus on it. The code is muted, the ▶ a 16 px muted column.
    * Touch phones get 44 px rows, ▶, × and Clear.

  `DocStyle.sheet/1` draws these rules with the rest of the edit pane's.
  """

  @doc "The rules, for the edit pane's sheet."
  @spec css() :: String.t()
  def css do
    """
    .dk .dk-edit .bp-field-codelist:has(> .codelist-tree-field) { margin: 0; padding: 0; border: 0; border-radius: 0; background: none; }
    .dk .dk-edit .codelist-tree-field { display: flex; flex-direction: column; gap: 6px; }
    .dk .dk-edit .codelist-tree-field .mono { font-family: var(--font-mono); font-size: 13px; }
    .dk .dk-edit .codelist-tree-field .muted { color: var(--dk-muted); }
    .dk .dk-edit .codelist-current { display: flex; align-items: center; gap: 8px; font-size: 13px; color: var(--dk-fg); }
    .dk .dk-edit .codelist-current .codelist-label { flex: 1; min-width: 0; color: var(--dk-fg); overflow-wrap: anywhere; }
    .dk .dk-edit .codelist-current .codelist-label.invalid { color: var(--dk-danger-text); }
    .dk .dk-edit .codelist-current .icon-btn { box-sizing: border-box; display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); font: inherit; cursor: pointer; }
    .dk .dk-edit .codelist-current .icon-btn:hover { background: var(--dk-icon-btn-hover); color: var(--dk-icon-btn-hover-fg); }
    .dk .dk-edit .codelist-search { display: flex; gap: 6px; }
    .dk .dk-edit .codelist-search .input { flex: 1; min-width: 0; display: block; width: 100%; font: inherit; }
    .dk .dk-edit .codelist-search .btn { font: inherit; font-size: 13px; font-weight: 500; padding: 6px 12px; border: 0; border-radius: 3px; background: none; color: var(--dk-fg); cursor: pointer; }
    .dk .dk-edit .codelist-search .btn:hover { background: var(--dk-icon-btn-hover); }
    .dk .dk-edit .codelist-tree { list-style: none; margin: 0; padding: 4px 0; max-height: 280px; overflow: auto; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--dk-line); font-size: 13px; color: var(--dk-fg); }
    .dk .dk-edit .codelist-tree [role="treeitem"] { display: flex; align-items: baseline; gap: 6px; margin: 0; padding-top: 4px; padding-bottom: 4px; padding-right: 8px; cursor: pointer; }
    .dk .dk-edit .codelist-tree [role="treeitem"]:hover { background: var(--dk-icon-btn-hover); }
    .dk .dk-edit .codelist-tree [role="treeitem"]:focus-visible { outline: 2px solid var(--dk-selected); outline-offset: -2px; }
    .dk .dk-edit .codelist-tree [role="treeitem"][aria-selected="true"] { background: var(--dk-hover-strong); font-weight: 500; }
    .dk .dk-edit .codelist-tree .mono { color: var(--dk-muted); }
    .dk .dk-edit .codelist-toggle { display: inline-grid; place-items: center; width: 16px; flex-shrink: 0; font-size: 10px; color: var(--dk-muted); }
    .dk .dk-edit .codelist-empty { margin: 4px 0 0; font-size: 13px; }
    @media (max-width: 768px) and (pointer: coarse) {
      .dk .dk-edit .codelist-tree [role="treeitem"] { min-height: 44px; align-items: center; }
      .dk .dk-edit .codelist-toggle { width: 44px; height: 44px; }
      .dk .dk-edit .codelist-current .icon-btn, .dk .dk-edit .codelist-search .btn { min-width: 44px; min-height: 44px; }
    }
    """
  end
end
