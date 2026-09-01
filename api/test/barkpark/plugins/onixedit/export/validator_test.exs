defmodule Barkpark.Plugins.OnixEdit.Export.ValidatorTest do
  @moduledoc """
  WI5 — formal XSD validation gate.

  Tagged `@moduletag :validator`. Skipped on hosts without `xmllint`
  (libxml2-utils on Debian/Ubuntu, libxml2 on macOS Homebrew). CI installs
  libxml2-utils before `mix test`, so the gate runs by default in CI.
  """

  # async: false — the resource-bound tests toggle the global `:barkpark, Validator`
  # env (bin/timeout/max_bytes overrides), same race concern as magick_test.exs.
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Plugins.OnixEdit.Export.Validator

  @moduletag :validator

  setup_all do
    if System.find_executable("xmllint") do
      :ok
    else
      {:skip, "xmllint not on PATH — install libxml2-utils to run validator suite"}
    end
  end

  # Snapshot/restore the module env so a bound-test override never leaks into the
  # real-xmllint tests (which read no config and must see the default resolution).
  setup do
    prev = Application.get_env(:barkpark, Validator)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, Validator, prev),
        else: Application.delete_env(:barkpark, Validator)
    end)

    :ok
  end

  defp put_validator_cfg(overrides), do: Application.put_env(:barkpark, Validator, overrides)

  # An executable /bin/sh stub standing in for xmllint via the `bin:` override, so
  # the deadline is testable with no real libxml2 behaviour.
  defp write_stub(body) do
    path = Path.join(System.tmp_dir!(), "xmllint_stub_#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp load_fixture(name) do
    Path.join([File.cwd!(), "test", "fixtures", "onix", name <> ".json"])
    |> File.read!()
    |> Jason.decode!()
  end

  defp export_xml(book), do: Export.export(book, sent_at: ~U[2026-04-29 12:00:00Z])

  describe "happy path" do
    test "minimal-book.json produces XSD-valid ONIX" do
      book = load_fixture("minimal-book")
      {:ok, xml} = export_xml(book)
      assert :ok = Validator.validate_xsd(xml)
    end

    test "full-book.json produces XSD-valid ONIX with WI3+WI4+WI5.5 blocks" do
      book = load_fixture("full-book")
      {:ok, xml} = export_xml(book)
      assert :ok = Validator.validate_xsd(xml)
    end

    test "synthesized-supplier-book.json (no productSupplies) validates via synthesis path" do
      book = load_fixture("synthesized-supplier-book")
      {:ok, xml} = export_xml(book)
      assert :ok = Validator.validate_xsd(xml)
    end

    test "all three valid fixtures validate green in one sweep" do
      for name <- ["minimal-book", "full-book", "synthesized-supplier-book"] do
        book = load_fixture(name)
        {:ok, xml} = export_xml(book)

        result = Validator.validate_xsd(xml)

        assert result == :ok,
               "expected #{name}.json to validate against the EDItEUR XSD, got #{inspect(result)}"
      end
    end
  end

  describe "failure path" do
    test "broken-book.json (no productIdentifiers) fails XSD with ProductIdentifier reason" do
      book = load_fixture("broken-book")
      {:ok, xml} = export_xml(book)

      assert {:error, reasons} = Validator.validate_xsd(xml)
      assert is_list(reasons)
      assert reasons != []

      assert Enum.any?(reasons, fn line ->
               String.contains?(line, "ProductIdentifier") or
                 String.contains?(line, "fails to validate")
             end),
             "expected reasons to mention ProductIdentifier or fails to validate; got: #{inspect(reasons)}"
    end
  end

  describe "Export.validate_against_xsd/2 wrapper" do
    test "thin wrapper delegates to Validator.validate_xsd/2" do
      book = load_fixture("minimal-book")
      {:ok, xml} = export_xml(book)
      assert :ok = Export.validate_against_xsd(xml)
    end
  end

  describe "resource bounds" do
    test "oversized XML is rejected by the size cap BEFORE any tmp write or shell-out" do
      put_validator_cfg(max_bytes: 64)
      oversized = String.duplicate("<Padding/>", 100)

      assert byte_size(oversized) > 64
      assert {:error, [reason]} = Validator.validate_xsd(oversized)
      assert reason =~ "over the"
      assert reason =~ "cap"
    end

    # FAIL-BEFORE: run_xmllint called System.cmd directly, so this sleeper blocks
    # the export/Bokbasen worker for the full 2s and returns {out, 0} → :ok.
    # PASS-AFTER: the child is brutal-killed at the 150ms deadline → bounded error,
    # returned well under the 2s stub exit.
    test "a hung xmllint is time-boxed: bounded error AND the wall-clock is cut" do
      slow = write_stub("sleep 2\nexit 0\n")
      put_validator_cfg(bin: slow, timeout_ms: 150)

      {micros, result} = :timer.tc(fn -> Validator.validate_xsd("<ONIXMessage/>") end)

      assert {:error, [reason]} = result
      assert reason =~ "deadline"

      assert micros < 1_500_000,
             "validation blocked #{micros}µs — the deadline did not bound xmllint"
    end
  end

  describe "default_xsd_path/0" do
    test "resolves to an existing file under api/priv/onix/onix-3.0/" do
      path = Validator.default_xsd_path()
      assert File.exists?(path), "expected default XSD at #{path}"
      assert String.ends_with?(path, "ONIX_BookProduct_3.0_reference.xsd")
    end
  end
end
