defmodule BarkparkWeb.Studio.StudioLiveFlashGettextTest do
  @moduledoc """
  task-c5d0e4932ebfb28d: every StudioLive flash a person reads goes through
  gettext. A `put_flash` whose message is a bare English string literal reads
  English in every workspace's language, so this scan fails on one.
  """
  use ExUnit.Case, async: true

  @roots [
    "lib/barkpark_web/live/studio/studio_live.ex",
    "lib/barkpark_web/live/studio/studio_live"
  ]

  defp files do
    Enum.flat_map(@roots, fn root ->
      if File.dir?(root), do: Path.wildcard(Path.join(root, "**/*.ex")), else: [root]
    end)
  end

  # `put_flash(…, :kind, "Capitalised literal…")` — on one line or wrapped,
  # the message being the last argument.
  @bare ~r/put_flash\(\s*(?:[a-z_@.\[\]]+\s*,\s*)?:\w+\s*,\s*"[A-Z]/s

  test "the scan sees StudioLive's flashes" do
    count =
      files()
      |> Enum.map(&File.read!/1)
      |> Enum.map(&length(Regex.scan(~r/put_flash\(/, &1)))
      |> Enum.sum()

    assert count > 50, "found only #{count} put_flash calls — the scan is broken"
  end

  test "no StudioLive flash is a bare English literal" do
    offenders =
      for file <- files(),
          [hit] <- Regex.scan(@bare, File.read!(file)),
          do: "#{file}: #{String.slice(hit, 0, 80)}"

    assert offenders == []
  end

  test "the bare-literal pattern catches both the one-line and the wrapped form" do
    assert Regex.match?(@bare, ~s|put_flash(socket, :error, "Failed to delete")|)
    assert Regex.match?(@bare, ~s|put_flash(\n  :error,\n  "This asset is checked out"\n)|)
    refute Regex.match?(@bare, ~s|put_flash(socket, :error, gettext("Failed to delete"))|)
  end
end
