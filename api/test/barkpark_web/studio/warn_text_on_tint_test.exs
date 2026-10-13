defmodule BarkparkWeb.Studio.WarnTextOnTintTest do
  @moduledoc """
  task-98bc0a831eecc140: amber text on its own amber tint (the draft badge, the
  private and offline badges, the unpublish history pill, …) read 3.26:1 in the
  light theme. The ruling added a text-on-tint voice, `--warn-text`, emitted
  from design/tokens.json `color.onTint`; fills, dots and borders keep the
  amber. This is a rule over the source, not a list of sites: any style that
  puts amber text on the warn tint uses the text voice.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)
  @root Path.join(@lib, "barkpark_web/layouts/root.html.heex")

  defp sources do
    Path.wildcard(Path.join(@lib, "**/*.{ex,heex}"))
  end

  defp tinted_lines do
    for path <- sources(),
        {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        String.contains?(line, "warn-soft") and line =~ ~r/(^|[;\s"{])color:\s*var\(--warn/,
        do: {Path.relative_to(path, @lib), n, String.trim(line)}
  end

  test "amber text on the warn tint uses the text-on-tint voice" do
    lines = tinted_lines()
    # Not vacuous: the draft, private and offline badges are among them.
    assert length(lines) >= 5, "found only #{length(lines)} amber-on-tint style(s)"

    offenders =
      for {path, n, line} <- lines,
          not (line =~ ~r/color:\s*var\(--warn-text\)/),
          do: "#{path}:#{n}: #{line}"

    assert offenders == [],
           "amber text on the warn tint without --warn-text:\n" <> Enum.join(offenders, "\n")
  end

  # warn-text is now the per-theme AA walk (ruling on task-399a8a237f339eb1):
  # evergreen light lands at 29.5% (the old fixed step gave 30%), clearing AA on the tint over
  # both bg and muted-surface.
  test "the Studio root defines the text-on-tint voices in light and dark" do
    css = File.read!(@root)
    assert css =~ "--warn-text: hsl(35 92% 29.5%);"
    assert css =~ "--warn-text: hsl(38 94% 56%);"

    for voice <- ~w(ok-text danger-text info-text primary-text) do
      assert css =~ "--#{voice}: hsl(", "the Studio root emits --#{voice}"
    end
  end
end
