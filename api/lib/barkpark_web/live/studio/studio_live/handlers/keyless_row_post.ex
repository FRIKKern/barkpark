defmodule BarkparkWeb.Studio.StudioLive.Handlers.KeylessRowPost do
  @moduledoc """
  A row posted with no `_key` over a row that has one (task-bbaf091ad00e7cda,
  #29165 review W3).

  The save fold (`Fields.fold_dot_paths/2`) writes a row's leaves to the row
  of its posted `_key`, and a row posted with none by its index. A composite
  row always posts its `_key` when it has one (`ArrayField.composite_row_body/5`
  in the old Studio and the desk's item dialog, `ObjectForm` for a typed
  member), and the store never gives a row a key A's page did not draw. So a
  keyless composite row's leaves that land on a keyed row at that index were
  typed on another row: another editor put the keyed row there. They are
  dropped, never written into it, and A's words are shown in the banner
  (`RichTextRemote.DroppedRows`).

  Only a composite row is read so. A reference, localized text, codelist or
  plain row posts no `_key` even when it has one, and keeps the index fold.
  The row is told by the schema's member type at that index, not by the
  leaves posted. A `_key` of `""` is no key.
  """

  alias BarkparkWeb.Studio.StudioLive.Path

  @doc """
  True when `row`, the form's row at `at` (a row path, `["rows", 0]`), has a
  `_key` and the schema's member there is a composite.
  """
  def over_keyed?(%{fields: fields}, form, at, %{"_key" => key})
      when is_list(fields) and is_binary(key) and key != "" do
    match?(%{"type" => "composite"}, Path.field_at(fields, at, form))
  end

  def over_keyed?(_schema, _form, _at, _row), do: false
end
