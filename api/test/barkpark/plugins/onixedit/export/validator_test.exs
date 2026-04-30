defmodule Barkpark.Plugins.OnixEdit.Export.ValidatorTest do
  @moduledoc """
  WI5 — formal XSD validation gate.

  Tagged `@moduletag :validator`. Skipped on hosts without `xmllint`
  (libxml2-utils on Debian/Ubuntu, libxml2 on macOS Homebrew). CI installs
  libxml2-utils before `mix test`, so the gate runs by default in CI.
  """

  use ExUnit.Case, async: true

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

        assert :ok = Validator.validate_xsd(xml),
               "expected #{name}.json to validate against the EDItEUR XSD"
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

  describe "default_xsd_path/0" do
    test "resolves to an existing file under api/priv/onix/onix-3.0/" do
      path = Validator.default_xsd_path()
      assert File.exists?(path), "expected default XSD at #{path}"
      assert String.ends_with?(path, "ONIX_BookProduct_3.0_reference.xsd")
    end
  end
end
