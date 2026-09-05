defmodule Mix.Tasks.Onix.ImportTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit.Importer
  alias Mix.Tasks.Onix.Import

  # These tests pin the exit-code contract: mix onix.import must FAIL LOUDLY
  # (raise Mix.Error → non-zero exit) instead of silently exiting 0 when the
  # import did nothing useful. The two silent-success bugs are:
  #   1. every product failed → previously exited 0
  #   2. zero <Product> elements matched → previously exited 0

  describe "summarize/1 (per-product exit-code contract)" do
    test "all products ok → :ok, no raise" do
      assert Import.summarize([:ok, :ok, :ok]) == :ok
    end

    test "any product failed → raises Mix.Error (non-zero exit)" do
      assert_raise Mix.Error, ~r/1 of 3 product\(s\) failed/, fn ->
        Import.summarize([:ok, :error, :ok])
      end
    end

    test "every product failed → raises Mix.Error (non-zero exit)" do
      assert_raise Mix.Error, ~r/2 of 2 product\(s\) failed/, fn ->
        Import.summarize([:error, :error])
      end
    end
  end

  describe "run/1 (zero-product no-op)" do
    test "0 <Product> parsed → raises Mix.Error mentioning the namespace hint" do
      path = Path.join(System.tmp_dir!(), "onix-empty-#{System.unique_integer([:positive])}.xml")

      # Valid ONIX-ish envelope with NO <Product> elements. --dry-run so the
      # task never touches app.start / the DB; it must still fail non-zero.
      File.write!(path, ~s(<?xml version="1.0"?><ONIXMessage><Header/></ONIXMessage>))

      try do
        assert_raise Mix.Error, ~r/0 <Product> elements parsed/, fn ->
          Import.run([path, "--dry-run"])
        end
      after
        File.rm(path)
      end
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 3. Withdrawal notices (NotificationType 05 / DeletionText)
  # ────────────────────────────────────────────────────────────────────────
  #
  # Before this branch, handle_product/3 created a draft for EVERY product
  # unconditionally, so a withdrawn ISBN resurfaced as a new draft on every
  # sync.

  describe "withdrawal?/1 classification" do
    test "NotificationType 05 is a withdrawal" do
      assert Import.withdrawal?(%{"notificationType" => "05"})
    end

    test "a non-empty DeletionText is a withdrawal even without the 05 code" do
      assert Import.withdrawal?(%{"notificationType" => "03", "deletionText" => "Out of print"})
    end

    test "the normal 03 notification is NOT a withdrawal" do
      refute Import.withdrawal?(%{"notificationType" => "03"})
      refute Import.withdrawal?(%{})
    end

    test "a whitespace-only DeletionText is NOT a withdrawal" do
      refute Import.withdrawal?(%{"notificationType" => "03", "deletionText" => "   "})
    end
  end

  describe "withdrawal notices parsed straight out of ONIX XML" do
    defp withdrawal_xml(ref, inner) do
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <ONIXMessage>
        <Product>
          <RecordReference>acme.example.com:#{ref}</RecordReference>
          #{inner}
        </Product>
      </ONIXMessage>
      """
    end

    test "a NotificationType=05 feed classifies as a withdrawal end to end" do
      {:ok, %{products: [product]}} =
        Importer.parse_feed(withdrawal_xml("wd-1", "<NotificationType>05</NotificationType>"))

      assert product["notificationType"] == "05"
      assert Import.withdrawal?(product)
    end

    test "a DeletionText feed classifies as a withdrawal end to end" do
      xml =
        withdrawal_xml(
          "wd-2",
          "<NotificationType>03</NotificationType><DeletionText>Withdrawn by publisher</DeletionText>"
        )

      {:ok, %{products: [product]}} = Importer.parse_feed(xml)

      assert product["deletionText"] == "Withdrawn by publisher"
      assert Import.withdrawal?(product)
    end
  end

  describe "handle_product/3 --dry-run routing" do
    test "a withdrawal prints 'would withdraw', NOT 'would create'" do
      product = %{"_publishedId" => "wd-dry-1", "notificationType" => "05"}

      output =
        capture_shell(fn -> assert Import.handle_product(product, "production", true) == :ok end)

      assert output =~ "would withdraw: wd-dry-1"
      refute output =~ "would create"
    end

    test "a normal product still prints 'would create'" do
      product = %{"_publishedId" => "ok-dry-1", "notificationType" => "03"}

      output =
        capture_shell(fn -> assert Import.handle_product(product, "production", true) == :ok end)

      assert output =~ "would create: drafts.ok-dry-1"
      refute output =~ "would withdraw"
    end
  end

  defp capture_shell(fun) do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      fun.()
      drain_shell([])
    after
      Mix.shell(previous)
    end
  end

  defp drain_shell(acc) do
    receive do
      {:mix_shell, _kind, [message]} -> drain_shell([message | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
