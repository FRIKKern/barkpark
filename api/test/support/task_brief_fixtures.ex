defmodule Barkpark.TaskBriefFixtures do
  @moduledoc """
  The smallest PortableDoc brief that satisfies the Tasks plugin's
  `:before_publish` wall (`Barkpark.Plugins.Tasks.portable_brief_gate/1`).

  That wall was INERT until task-c1f155da34d3338f: it matched the payload doc
  on a STRING `"type"` key while `Content.Lifecycle` fires `:before_publish`
  with a `%Content.Document{}` struct (atom keys), so no publish ever reached
  it. Every task fixture written before that fix could therefore publish with
  no brief at all. This module is what those fixtures use to become honest —
  one brief shape, in one place, so a later change to the block vocabulary is
  a single edit instead of a sweep.

  Not a label fixture in disguise: `Barkpark.LabelFixtures` satisfies the
  authoring wall (label spine + tag registry); this satisfies the brief wall.
  A task publishing through the real door needs both.
  """

  @doc """
  A two-block brief — a heading and a paragraph — using block types from the
  plugin's own `@tui_block_types` allowlist.
  """
  def brief do
    %{
      "version" => 1,
      "blocks" => [
        %{"id" => "purpose", "type" => "heading", "level" => 2, "text" => "Purpose"},
        %{
          "id" => "purpose-copy",
          "type" => "paragraph",
          "content" => [
            %{"type" => "text", "value" => "Fixture brief: satisfies the publish wall in tests."}
          ]
        }
      ]
    }
  end

  @doc "Puts `brief/0` onto a task content map, leaving an existing brief alone."
  def with_brief(%{} = content), do: Map.put_new(content, "brief", brief())
end
