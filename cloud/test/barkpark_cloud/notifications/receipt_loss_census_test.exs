defmodule BarkparkCloud.Notifications.ReceiptLossCensusTest do
  @moduledoc """
  cch-w32-bl c2 — A THIRD RECEIPT-WRITE SITE CANNOT APPEAR WITHOUT AN
  ADJUDICATION.

  The row this file serves is not "these two branches are fixed"; it is "a
  branch of this class cannot be added silently again". So the guard is a
  BIDIRECTIONAL census between the source tree and
  `ReceiptLoss.sites/0`:

    * ARM (a) PRODUCED → ADJUDICATED. Every function in `cloud/lib` that writes
      a `notification_deliveries` row must be named in the register. A new
      writer reds here with its own name.
    * ARM (b) ADJUDICATED → PRODUCED. Every register entry's `anchor` must match
      live code in the file it names. This is the arm that keeps the register
      from certifying an absence that has since moved — an excused name is worse
      than a bare one, because somebody signed it.
    * ARM (c) TRACED → WIRED. A `:traced` entry must actually reach
      `ReceiptLoss.rescue_receipt/3` in its own file. The whole defect class is
      a handler that is PRESENT and never fires; a register that says "traced"
      over a bare `Logger.error` would rebuild it inside its own fix.

  ## What this does NOT prove

  It is a SOURCE scan. That the rescue RUNS, that it writes a row, and that the
  success path stays quiet are behavioural claims, and they are proved by
  driving the branch in `receipt_loss_test.exs` — not here. Arm (c) proves the
  call exists in the file, not that control reaches it.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Notifications.ReceiptLoss

  @lib_root Path.expand("../../../lib", __DIR__)

  # A broken extractor must RED, not report a clean tree.
  @writer_floor 4

  # A line writes a delivery row if it builds the struct or targets the schema
  # in a bulk insert. Both forms are present in cloud/lib today.
  @write_forms [
    ~r/%Delivery\{\}/,
    ~r/Repo\.insert_all\(\s*Delivery\b/
  ]

  defp lib_files do
    Path.wildcard(Path.join(@lib_root, "**/*.ex"))
  end

  # Everything after an unquoted `#` is prose. Without this the census counts
  # the `%Delivery{}` inside `Delivery`'s own comment about the compile cycle as
  # a writer — a FALSE producer, and it would red a clean tree.
  defp code_only(line) do
    line
    |> String.split(~r/(?<!\?)#/, parts: 2)
    |> hd()
  end

  defp enclosing_def(lines, index) do
    lines
    |> Enum.take(index + 1)
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*defp?\s+([a-z_][a-zA-Z0-9_?!]*)/, line) do
        [_, name] -> String.to_atom(name)
        nil -> nil
      end
    end)
  end

  # {relative file, enclosing function} for every delivery-write line.
  defp discovered_writers do
    writers =
      for path <- lib_files(),
          source = File.read!(path),
          String.contains?(source, "Delivery"),
          lines = String.split(source, "\n"),
          {line, index} <- Enum.with_index(lines),
          code = code_only(line),
          Enum.any?(@write_forms, &Regex.match?(&1, code)),
          fun = enclosing_def(lines, index),
          not is_nil(fun) do
        {Path.relative_to(path, @lib_root), fun}
      end

    Enum.uniq(writers)
  end

  defp adjudicated_writers do
    for entry <- ReceiptLoss.sites(), writer <- entry.writers, do: {entry.file, writer}
  end

  test "the extractor still finds the writers it is meant to police" do
    writers = discovered_writers()

    assert length(writers) >= @writer_floor,
           "found #{length(writers)} delivery writers, floor is #{@writer_floor} — " <>
             "the extractor is broken, not the tree: #{inspect(writers)}"

    # The two branches this census was cut for, by name.
    assert {"barkpark_cloud/notifications.ex", :record_delivery} in writers
    assert {"barkpark_cloud/notifications.ex", :log_chat_delivery} in writers
  end

  test "ARM (a): every delivery-write site in cloud/lib is adjudicated" do
    unadjudicated = discovered_writers() -- adjudicated_writers()

    assert unadjudicated == [],
           "a delivery-write site with no receipt-loss adjudication: " <>
             "#{inspect(unadjudicated)}. Add it to ReceiptLoss.sites/0 with " <>
             "either :traced (and the wiring) or :consented (and the reason a " <>
             "trace is impossible)."
  end

  test "ARM (b): every adjudicated site's anchor resolves to live code" do
    for entry <- ReceiptLoss.sites() do
      source = File.read!(Path.join(@lib_root, entry.file))

      assert Regex.match?(entry.anchor, source),
             "#{entry.site}'s anchor #{inspect(entry.anchor)} matches nothing in " <>
               "#{entry.file} — the register is reasoning about code that is gone."
    end
  end

  test "ARM (c): every :traced site actually reaches rescue_receipt/3" do
    for entry <- Enum.filter(ReceiptLoss.sites(), &(&1.adjudication == :traced)) do
      source = File.read!(Path.join(@lib_root, entry.file))
      call = ~r/ReceiptLoss\.rescue_receipt\(\s*:#{entry.site}\b/

      assert Regex.match?(call, source),
             "#{entry.site} is adjudicated :traced but nothing in #{entry.file} calls " <>
               "ReceiptLoss.rescue_receipt(:#{entry.site}, …) — a trace that is not wired."
    end
  end

  test "a :consented entry states why a trace is impossible, in its own words" do
    for entry <- Enum.filter(ReceiptLoss.sites(), &(&1.adjudication == :consented)) do
      assert byte_size(entry.why) > 80,
             "#{entry.site} is consented on a sentence too short to be a reason"
    end
  end
end
