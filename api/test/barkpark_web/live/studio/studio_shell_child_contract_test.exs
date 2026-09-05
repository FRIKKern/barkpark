defmodule BarkparkWeb.Studio.StudioShellChildContractTest do
  @moduledoc """
  The `.studio-shell` CHILD CONTRACT, asserted as a contract — not as two
  instances of a bug.

  ## The rule

  `.studio-shell` (root.html.heex) is `display:flex; flex-direction:column;
  height:100vh; overflow:hidden`. Every Studio LiveView rendered through the
  `:studio` layout is a flex ITEM of that column. Because the shell clips and
  never scrolls, such a root must either FILL the remaining height and own its
  scroll, or delegate to something that does. A root that is only a centred
  `max-width` column does neither: the shell clips it and no input can move the
  viewport, so everything past the fold is UNREACHABLE — a plugin toggle below
  the fold is a toggle that does not work.

  The repo already stated this rule in prose (tasks board_live.ex, `.bp-page`);
  it had no enforcement, and five pages broke it.

  ## Why the checks are TEXT-based

  ExUnit has no layout engine — it can never observe a clipped box. It CAN
  observe the source fact that produces one. So this file reads the render
  source of every Studio LiveView and asserts the contract over its top-level
  nodes. The browser measurement is the instrument that decides the rule;
  this file is the tripwire that keeps a sixth page from re-learning it.

  ## Census, not a hand-list

  The set of LiveViews is DERIVED (`lib/barkpark_web/live/studio/*.ex` that
  `use BarkparkWeb, :live_view`), so a new Studio page is covered the moment it
  is added — it must satisfy the contract or be classified in `@exempt` with a
  reason. That is the whole point: a hand-list would have covered exactly the
  pages someone already thought about.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../../lib/barkpark_web", __DIR__)
  @studio_dir Path.join(@lib, "live/studio")
  @root_layout Path.join(@lib, "layouts/root.html.heex")

  # LiveViews that are NOT flex children of `.studio-shell`, with the reason.
  # A new entry here is a deliberate classification, not a waiver of the bug.
  @exempt %{
    "swatch_live.ex" =>
      "renders through the BARE `:swatch` layout (router :admin_swatch live_session) — " <>
        "it is an IFRAME cell with its own <html>, never a child of .studio-shell"
  }

  # `def render/1` bodies that delegate instead of carrying their own ~H.
  # {file => {file holding the delegate, "  def <name>(assigns) do"}}
  @delegates %{
    "studio_live.ex" =>
      {"live/studio/studio_live/components.ex", "  def studio_live_shell(assigns) do"}
  }

  # Component roots that are known to satisfy the contract, and why.
  @filler_components %{
    ".studio_page_scroll" =>
      "BarkparkWeb.Studio.PageScroll — flex:1 1 auto; min-height:0; overflow-y:auto",
    ".pane_layout" => "`.pane-layout { display:flex; flex:1; ... }` in root.html.heex"
  }

  describe "the premise this contract rests on" do
    test "`.studio-shell` really is a clipping, full-height flex column" do
      css = File.read!(@root_layout)

      shell =
        Regex.run(~r/\.studio-shell\s*\{[^}]*\}/, css)
        |> case do
          [rule] -> rule
          _ -> flunk("no `.studio-shell { … }` rule in root.html.heex — the premise moved")
        end

      assert shell =~ "height: 100vh",
             "`.studio-shell` no longer pins 100vh: #{shell}"

      assert shell =~ "overflow: hidden",
             "`.studio-shell` no longer clips: #{shell}"

      assert shell =~ "flex-direction: column",
             "`.studio-shell` is no longer a column: #{shell}"
    end
  end

  describe "every Studio LiveView root honours the shell contract" do
    test "census is derived from source and is not empty" do
      names = census() |> Enum.map(&Path.basename/1)

      # Non-vacuity: a broken glob would silently pass every other test here.
      assert length(names) >= 10,
             "expected the Studio LiveView census to hold at least 10 modules, got #{length(names)}: #{inspect(names)}"

      assert "settings_live.ex" in names
      assert "styleguide_live.ex" in names
    end

    test "every exemption still names a real file" do
      names = census() |> Enum.map(&Path.basename/1) |> MapSet.new()

      for {file, reason} <- @exempt do
        assert MapSet.member?(names, file),
               "#{file} is exempt but no longer in the census — drop the exemption (#{reason})"
      end
    end

    test "each non-exempt root fills the shell or owns a scroller" do
      offenders =
        for path <- census(),
            file = Path.basename(path),
            not Map.has_key?(@exempt, file),
            nodes = root_nodes(path),
            not Enum.any?(nodes, &filler?/1) do
          {file, Enum.map(nodes, &first_line/1)}
        end

      assert offenders == [],
             """
             These Studio LiveView roots are flex children of `.studio-shell`
             (height:100vh; overflow:hidden) but neither fill the remaining
             height nor own a scroller. Their content below the fold is
             UNREACHABLE — no scroll container exists anywhere in the subtree.

             #{Enum.map_join(offenders, "\n\n", fn {f, tags} -> "  #{f}\n" <> Enum.map_join(tags, "\n", &("    " <> &1)) end)}

             Fix: wrap the page's centred column in `<.studio_page_scroll>`
             (BarkparkWeb.Studio.PageScroll), or give the root
             `flex: 1 1 auto; min-height: 0` and its own scroll — the same
             thing `.bp-page` and `.pane-layout` already do.
             """
    end
  end

  describe "the two measured pages keep their reading measure (criterion 3)" do
    test "/studio/settings — scroller is the root, 720px column survives inside it" do
      body = render_body(Path.join(@studio_dir, "settings_live.ex"))

      assert [node | _] = root_nodes(Path.join(@studio_dir, "settings_live.ex"))
      assert first_line(node) =~ "<.studio_page_scroll"

      assert body =~ ~s|class="settings-live"|
      assert body =~ "max-width: 720px"
      assert body =~ "margin: 32px auto"

      # The column is INSIDE the scroller, not beside it.
      assert String.contains?(
               after_marker(body, "<.studio_page_scroll>"),
               ~s|class="settings-live"|
             )
    end

    test "/studio/styleguide — scroller is the root, 1080px column survives inside it" do
      path = Path.join(@studio_dir, "styleguide_live.ex")
      body = render_body(path)

      assert [node | _] = root_nodes(path)
      assert first_line(node) =~ "<.studio_page_scroll"

      assert body =~ ~s|id="sg-root"|
      assert body =~ "max-width: 1080px"
      assert body =~ "margin: 2rem auto"

      assert String.contains?(after_marker(body, "<.studio_page_scroll>"), ~s|id="sg-root"|)
    end
  end

  # ── census + parsing ────────────────────────────────────────────────────

  defp census do
    @studio_dir
    |> Path.join("*.ex")
    |> Path.wildcard()
    |> Enum.filter(&(File.read!(&1) =~ "use BarkparkWeb, :live_view"))
    |> Enum.sort()
  end

  # The `~H` body of `def render/1`, following a delegation when the function
  # has no sigil of its own.
  defp render_body(path) do
    file = Path.basename(path)

    case Map.fetch(@delegates, file) do
      {:ok, {rel, header}} -> heredoc(File.read!(Path.join(@lib, rel)), header)
      :error -> heredoc(File.read!(path), "  def render(assigns) do")
    end
  end

  defp heredoc(src, header) do
    lines = String.split(src, "\n")

    start =
      Enum.find_index(lines, &(&1 == header)) ||
        raise "no `#{header}` in this source — the contract test cannot find the render root"

    rest = Enum.drop(lines, start)

    open =
      Enum.find_index(rest, &(&1 == ~s(    ~H"""))) ||
        raise "`#{header}` has no `~H\"\"\"` body — add it to @delegates with the function that does"

    body = Enum.drop(rest, open + 1)
    close = Enum.find_index(body, &(&1 == ~s(    """))) || raise "unterminated ~H in #{header}"

    body |> Enum.take(close) |> Enum.join("\n")
  end

  # Top-level nodes of a render body: HEEx written by this repo indents the
  # body of `~H"""` inside a `def` at exactly four spaces, so a line that
  # starts a tag at column 4 opens a root-level node. Returns each node's
  # OPENING TAG text (attributes may span lines).
  defp root_nodes(path) do
    lines = path |> render_body() |> String.split("\n")

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {l, _} -> Regex.match?(~r/^    <[a-zA-Z.]/, l) end)
    |> Enum.map(fn {_, i} -> opening_tag(lines, i) end)
    |> Enum.reject(&skippable?/1)
  end

  defp opening_tag(lines, i), do: opening_tag(lines, i, Enum.at(lines, i), 0)

  defp opening_tag(_lines, _i, acc, taken) when taken >= 40, do: acc

  defp opening_tag(lines, i, acc, taken) do
    if closed?(acc) do
      acc
    else
      case Enum.at(lines, i + taken + 1) do
        nil -> acc
        next -> opening_tag(lines, i, acc <> "\n" <> next, taken + 1)
      end
    end
  end

  # `>` inside `{...}` interpolation is not the end of the tag.
  defp closed?(text), do: text |> String.replace(~r/\{[^{}]*\}/, "") |> String.contains?(">")

  # Chrome that carries no layout: comments, <style>/<script>, and elements
  # explicitly given zero size (e.g. the `#editor-focus-mirror` hook host).
  defp skippable?(tag) do
    String.starts_with?(String.trim_leading(tag), ["<%", "<style", "<script"]) or
      tag =~ ~r/display:\s*none/
  end

  defp filler?(tag) do
    trimmed = String.trim_leading(tag)

    Enum.any?(Map.keys(@filler_components), &String.starts_with?(trimmed, "<" <> &1)) or
      (tag =~ ~r/flex:\s*1\b/ and tag =~ ~r/min-height:\s*0\b/)
  end

  defp first_line(tag), do: tag |> String.split("\n") |> hd() |> String.trim()

  defp after_marker(body, marker) do
    [_ | rest] = String.split(body, marker, parts: 2)
    hd(rest)
  end
end
