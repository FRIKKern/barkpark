defmodule Barkpark.PortableDoc.Render.BlockDepth do
  @moduledoc """
  A block past the depth limit becomes the notice, and a list item keeps it
  (task-a6a57717506de979).

  A block at block depth `Validate.max_depth/0` (100) is replaced by
  `notice_block/0`: a paragraph holding the notice. A list item draws only its
  list children, so without a mark the notice would be dropped there, and the
  block would go away with no notice. The notice block carries the atom key
  `:capped`, which JSON can't carry: a stored paragraph with `"capped": true` in
  a list item's children is still dropped. js/packages/react (blocks/depth.ts,
  list-children.ts) and apps/mobile (model.ts, core-prose.tsx) mark it the
  same way, with a module Symbol.
  """

  alias Barkpark.PortableDoc.Render.Chrome

  @doc "The block that stands in for a block past the depth limit."
  @spec notice_block() :: map()
  def notice_block,
    do: %{:capped => true, "type" => "paragraph", "text" => Chrome.t("Nested too deep to show")}

  @doc "A list item's child that is not a list: `[draw.(child)]` for the notice block, else `[]`."
  @spec keep(term(), (map() -> term())) :: list()
  def keep(%{capped: true} = child, draw), do: [draw.(child)]
  def keep(_child, _draw), do: []
end
