defmodule Barkpark.PortableDoc.Render.ContainerRenderOptsTest do
  # task-00c1e5bae06da161: every container block renders its children with the
  # caller's render options. Two resolution paths are measured per container:
  #
  #   * the PALETTE path — `:embeds` rides the walk palette; a container whose
  #     child is walked with a fresh palette drops it (the embed degrades to its
  #     `paper-embed--unresolved` placeholder);
  #   * the PRE-PASS path — `:paper_links` is stamped onto the block by
  #     `Render.prepare_block/2`; a container that composes its child without
  #     that pre-pass drops it (the card shows the bare slug, not the title).
  #
  # Each container is also rendered at top level as the control: the SAME
  # opts resolve there, so a red here is the container, never the fixture.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  @embed %{"id" => "e1", "type" => "embed", "target" => "Target Note"}
  @paper_links %{"id" => "pl", "type" => "paper-links", "refs" => ["daily-x"]}

  @opts %{
    embeds: %{"Target Note" => "<p>EMBEDDED-BODY</p>"},
    paper_links: %{
      "daily-x" => %{
        title: "LIVE-TITLE",
        description: "d",
        event_type: "release",
        rev: 3,
        updated_at: "2026"
      }
    }
  }

  # {name, wrap-fn, styles}. A container whose email leg is a different
  # emitter is measured at both styles.
  @containers [
    {"columns", &__MODULE__.columns/1, [:article, :email]},
    {"section (stack)", &__MODULE__.section_stack/1, [:article, :email]},
    {"section (grid)", &__MODULE__.section_grid/1, [:article]},
    {"terminal", &__MODULE__.terminal/1, [:article, :email]},
    {"tabs", &__MODULE__.tabs/1, [:article, :email]},
    {"figure", &__MODULE__.figure/1, [:article, :email]},
    {"card", &__MODULE__.card/1, [:article, :email]},
    {"expandable", &__MODULE__.expandable/1, [:article, :email]},
    {"steps", &__MODULE__.steps/1, [:article, :email]}
  ]

  def columns(b), do: %{"type" => "columns", "columns" => [[b], []]}
  def section_stack(b), do: %{"type" => "section", "blocks" => [b]}

  def section_grid(b),
    do: %{"type" => "section", "layout" => %{"mode" => "grid", "tracks" => 2}, "blocks" => [b]}

  def terminal(b), do: %{"type" => "terminal", "title" => "t", "blocks" => [b]}
  def tabs(b), do: %{"type" => "tabs", "tabs" => [%{"label" => "A", "blocks" => [b]}]}
  def figure(b), do: %{"type" => "figure", "child" => b, "caption" => "c"}
  def card(b), do: %{"type" => "card", "slots" => %{"body" => [b]}}
  def expandable(b), do: %{"type" => "expandable", "summary" => "s", "blocks" => [b]}
  def steps(b), do: %{"type" => "steps", "steps" => [%{"title" => "t", "blocks" => [b]}]}

  for {name, wrap, styles} <- @containers, style <- styles do
    @wrap wrap
    @style style

    test "#{name} at #{style}: a nested embed resolves through the caller's :embeds" do
      opts = Map.put(@opts, :style, @style)

      # Control: the same block at top level resolves.
      assert Render.render_block(@embed, opts) =~ "EMBEDDED-BODY"

      html = Render.render_block(@wrap.(@embed), opts)
      assert html =~ "EMBEDDED-BODY"
      refute html =~ "paper-embed--unresolved"
    end

    test "#{name} at #{style}: a nested paper-links block gets the caller's :paper_links" do
      opts = Map.put(@opts, :style, @style)

      assert Render.render_block(@paper_links, opts) =~ "LIVE-TITLE"

      assert Render.render_block(@wrap.(@paper_links), opts) =~ "LIVE-TITLE"
    end
  end

  test "opts reach a container nested in a container (columns in a stack section in tabs)" do
    inner = columns(@paper_links) |> section_stack() |> tabs()
    html = Render.render_block(inner, Map.put(@opts, :style, :article))
    assert html =~ "LIVE-TITLE"
  end

  test "a nested child still renders at evergreen when the caller passes a theme (charter D8)" do
    theme = %{brand: "#ff0000", text: "#00ff00", muted: "#0000ff", rule: "#ff00ff"}

    child = %{
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "link",
          "href" => "https://x.test",
          "children" => [%{"type" => "text", "value" => "x"}]
        }
      ]
    }

    # Control: the theme DOES move the child's bytes at top level ...
    refute Render.render_block(child, %{style: :email, theme: theme}) ==
             Render.render_block(child, %{style: :email})

    # ... and does not inside a container: the carried opts hold :theme back.
    assert Render.render_block(columns(child), %{style: :email, theme: theme}) ==
             Render.render_block(columns(child), %{style: :email})
  end

  test "the transient _render_opts key never reaches the output" do
    for {_name, wrap, _} <- @containers do
      html = Render.render_block(wrap.(@paper_links), Map.put(@opts, :style, :article))
      refute html =~ "_render_opts"
    end
  end
end
