defmodule BarkparkWeb.Studio.ModalFocusGuardTest do
  @moduledoc """
  Run-8 dialog sweep: every aria-modal dialog in api/lib must manage focus the
  one shared way, the `ModalFocus` hook (/assets/bp-modal-focus.js): focus in,
  Tab kept inside, focus back to the trigger on close. Three had drifted
  (the schema-action ConfirmModal, the chat palette, the paper reader's diff
  dialog), each fixed by hand-rolled or missing code.

  This is a PREDICATE over the source, not a list: a new `aria-modal="true"`
  anywhere in api/lib that carries no `phx-hook="ModalFocus"` on itself or
  close inside its subtree reds here. There is no allowlist. The floor keeps
  the scan from passing by finding nothing, and the control proves the check
  can fail.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)
  @asset Path.expand("../../../priv/static/assets/bp-modal-focus.js", __DIR__)
  @layouts Path.expand("../../../lib/barkpark_web/layouts", __DIR__)

  # The dialog's opening tag plus this many following lines may carry the hook
  # (the chat palette's sits on its inner card, the overlay owns ChatPalette).
  @subtree_lines 25

  # 18 aria-modal dialogs exist today (2026-10-10). A count that falls below the
  # floor means the scan broke, not that dialogs vanished.
  @floor 18

  defp sources do
    Path.wildcard(Path.join(@lib, "**/*.{ex,heex}"))
    |> Enum.map(&{Path.relative_to(&1, @lib), File.read!(&1)})
  end

  # Every aria-modal dialog in `text` with no ModalFocus near its opening tag.
  defp unmanaged(text) do
    lines = String.split(text, "\n")

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _} -> String.contains?(line, ~s(aria-modal="true")) end)
    |> Enum.map(fn {_line, i} ->
      start = tag_start(lines, i)
      window = lines |> Enum.slice(start, i - start + 1 + @subtree_lines) |> Enum.join("\n")
      {i + 1, String.contains?(window, ~s(phx-hook="ModalFocus"))}
    end)
  end

  # The line the dialog's opening tag starts on: the nearest line at or above
  # `i` that opens an element.
  defp tag_start(lines, i) do
    Enum.find(i..0//-1, i, fn j -> Regex.match?(~r/^\s*<[a-zA-Z]/, Enum.at(lines, j)) end)
  end

  test "every aria-modal dialog in api/lib uses the shared ModalFocus hook" do
    found =
      for {path, text} <- sources(), {line, ok?} <- unmanaged(text), do: {path, line, ok?}

    assert length(found) >= @floor,
           "the scan found #{length(found)} aria-modal dialogs, below the floor of #{@floor}; the predicate is broken"

    missing = for {path, line, false} <- found, do: "#{path}:#{line}"

    assert missing == [],
           "aria-modal dialogs with no ModalFocus hook (focus in, Tab trap, focus back on close): #{inspect(missing)}"
  end

  test "CONTROL: a dialog stripped of its hook is caught" do
    {_, text} = Enum.find(sources(), fn {path, _} -> path =~ "confirm_modal.ex" end)
    assert Enum.all?(unmanaged(text), fn {_, ok?} -> ok? end)

    stripped = String.replace(text, ~s(phx-hook="ModalFocus"), "")
    assert Enum.any?(unmanaged(stripped), fn {_, ok?} -> not ok? end)
  end

  test "both layouts load the shared helper and register it as ModalFocus" do
    assert File.read!(@asset) =~ "window.BarkparkModalFocus = {"

    root = File.read!(Path.join(@layouts, "root.html.heex"))
    assert root =~ ~s(<script src="/assets/bp-modal-focus.js"></script>)
    assert root =~ "Hooks.ModalFocus = window.BarkparkModalFocus;"

    paper = File.read!(Path.join(@layouts, "bulldocs.html.heex"))
    assert paper =~ ~s(<script src="/assets/bp-modal-focus.js"></script>)
    assert paper =~ "PaperHooks.ModalFocus = window.BarkparkModalFocus;"
  end
end
