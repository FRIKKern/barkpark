defmodule BarkparkWeb.Studio.Desk.TagsStyle do
  @moduledoc """
  The look of a tags field in the desk's form (`TagsField`), the TanStack
  Studio's (barkpark-studio `app/src/styles.css`: `.tags-box`, `.tag`,
  `.tags-input`, and `.field:has(> .tags-box)`), in the desk's own colour
  tokens, so it follows light and dark with the rest of the desk.

    * The field sits 4 px nearer the field above, and its label 11 px over
      the box, as Sanity draws a fieldset.
    * One box, at least 35 px tall, 4 px in, ringed 1 px; the ring is blue
      while the input has the focus. The chips and the input wrap in it,
      4 px apart.
    * A chip is the tag at 15 px on the upload fill, 8 px in on the left,
      then a 25 px × in the chip's muted ink, filled under the pointer.
    * The input takes the rest of the line, at least 120 px, unringed.
    * Touch phones get a 44 px ×.
    * An array whose `of` names no type draws its items as the same chips,
      read-only, with no box (`ArrayField`).

  `DocStyle.sheet/1` draws these rules with the rest of the edit pane's.
  """

  @doc "The rules, for the edit pane's sheet."
  @spec css() :: String.t()
  def css do
    """
    .dk .dk-edit .editor-field:has(> .bp-field-tags) { margin-top: -4px; }
    .dk .dk-edit .bp-field-tags > label { display: block; margin: 0 0 11px; padding: 0; font-size: 13px; line-height: 19px; font-weight: 500; letter-spacing: 0; text-transform: none; color: var(--dk-fg); }
    .dk .dk-edit .tags-box { box-sizing: border-box; display: flex; flex-wrap: wrap; align-items: center; gap: 4px; min-height: 35px; padding: 4px; border-radius: 1px; box-shadow: inset 0 0 0 1px var(--dk-line); cursor: text; }
    .dk .dk-edit .tags-box:focus-within { box-shadow: inset 0 0 0 1px var(--dk-focus-ring); }
    .dk .dk-edit .tags-box .tag { display: inline-flex; align-items: center; gap: 4px; font-size: 15px; line-height: 23px; padding: 2px 0 2px 8px; border-radius: 3px; background: var(--dk-upload-fill); color: var(--dk-fg); }
    .dk .dk-edit .tags-box .tag button { display: inline-grid; place-items: center; width: 25px; height: 25px; margin: -1px 0; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-tag-x); cursor: pointer; }
    .dk .dk-edit .tags-box .tag button:hover { background: var(--dk-hover-strong); color: var(--dk-fg-strong); }
    .dk .dk-edit .tags-box .tag button svg { width: 21px; height: 21px; }
    .dk .dk-edit .tags-input { flex: 1; min-width: 120px; font: inherit; font-size: 15px; line-height: 23px; padding: 2px 8px; border: 0; outline: none; background: none; color: var(--dk-input-fg); }
    .dk .dk-edit .tags-input::placeholder { color: var(--dk-placeholder); }
    .dk .dk-edit .bp-array-read-only-items { display: flex; flex-wrap: wrap; gap: 4px; }
    .dk .dk-edit .bp-array-read-only-items .tag { font-size: 15px; line-height: 23px; padding: 2px 8px; border-radius: 3px; background: var(--dk-upload-fill); color: var(--dk-fg); overflow-wrap: anywhere; }
    @media (max-width: 768px) and (pointer: coarse) { .dk .dk-edit .tags-box .tag button { width: 44px; height: 44px; } }
    """
  end
end
