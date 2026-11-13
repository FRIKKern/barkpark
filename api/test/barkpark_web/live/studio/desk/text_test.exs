defmodule BarkparkWeb.Studio.Desk.TextTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.Desk.Text

  test "spell writes each byte that is not text as its escape and keeps the rest" do
    assert Text.spell(<<"a", 0, "é", 0xFF, 0xC3, "(", "😀">>) == "a%00é%FF%C3(😀"
    assert Text.spell("") == ""
  end

  # task-f98c8d2b977b737e: each byte was put in front of the rest, so the whole
  # tail was copied once per byte. 400,000 NULs took 20 seconds or more that
  # way and take about 0.1 s in one pass (0.2 s on a loaded machine); five
  # seconds stands far from both.
  test "a long splat of bad bytes is spelled in one pass" do
    bytes = 400_000
    splat = :binary.copy(<<0>>, bytes)

    task = Task.async(fn -> :timer.tc(fn -> Text.text_only(splat) end) end)

    assert {:ok, {micros, spelled}} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    assert spelled == :binary.copy("%2500", bytes)
    assert micros < 5_000_000
  end
end
