defmodule Barkpark.Plugins.OnixEdit.Export.CodelistRegistryTest do
  @moduledoc """
  The ONIX exporter must resolve against the FULL vendored EDItEUR
  enumerations, not a hand-written starter subset.

  Until 2026-09 `Export.Codelists` held ~10 Thema codes, 6 currencies, 8
  countries and 19 contributor roles. A publisher who picked any of the other
  9,177 Thema codes in Studio — the Studio dropdown is registry-backed — got a
  valid document that the exporter REFUSED. Every pin below is a code that
  exists in the vendored snapshot and did NOT exist in that starter map, so
  restoring the starter map reds this file.

  The counterpart arm is just as load-bearing: a code that is genuinely
  absent from the enumeration must still refuse, and must refuse LOUDLY —
  never a silent drop, never a placeholder.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Plugins.OnixEdit.Export.{CodelistSource, Codelists}

  # Codes the pre-2026-09 starter maps did NOT carry. The comment is the
  # EDItEUR label, so a reader can check the pin against the snapshot by eye.
  @thema_beyond_starter %{
    # Fantasy romance / Romantic fantasy
    "FMR" => :thema,
    # Children's / Teenage fiction: General, modern and contemporary fiction
    "YFB" => :thema,
    # Gender studies: women and girls
    "JBSF1" => :thema
  }

  defp minimal_book do
    %{
      "_publishedId" => "codelist-registry-p1",
      "productIdentifiers" => [%{"productIdType" => "03", "idValue" => "9788234567890"}],
      "productForm" => "BB",
      "titleDetails" => [
        %{
          "titleType" => "01",
          "titleElements" => [%{"titleElementLevel" => "01", "titleText" => "Min bok"}]
        }
      ],
      "contributors" => [
        %{
          "contributorRole" => "A01",
          "personName" => %{"personName" => "Knut Hamsun", "keyNames" => "Hamsun"}
        }
      ]
    }
  end

  defp xml(doc), do: doc |> Export.to_xml() |> IO.iodata_to_binary()

  describe "Thema resolves against the full 1.6 snapshot, not a starter subset" do
    test "every code from the row's empirical proof now resolves" do
      for {code, :thema} <- @thema_beyond_starter do
        assert Codelists.thema(code) == {:ok, code},
               "#{code} is a real Thema 1.6 code and must resolve"
      end
    end

    test "the enumeration is the whole snapshot — size matches the vendored file" do
      # Control: count the file itself rather than trusting a number typed
      # into the test. A curated subset reds here no matter how it is spelled.
      expected = map_size(CodelistSource.thema())

      assert Codelists.size(:thema) == expected
      assert expected > 9_000, "Thema 1.6 carries 9,187 codes; got #{expected}"
    end

    test "labels come from the snapshot too" do
      assert Codelists.thema_label("FMR") == "Fantasy romance / Romantic fantasy"
    end

    test "a Thema code beyond the starter map survives the whole render" do
      bin = minimal_book() |> Map.put("themaSubjectCategory", ["FMR", "JBSF1"]) |> xml()

      assert bin =~ ~s|<SubjectCode>FMR</SubjectCode>|
      assert bin =~ ~s|<SubjectCode>JBSF1</SubjectCode>|
    end
  end

  describe "the numeric ONIX lists resolve against the XSD the validator uses" do
    test "codes the starter maps omitted now resolve" do
      # currency: the starter map held 6 (NOK SEK DKK EUR USD GBP)
      assert Codelists.currency_code("CAD") == {:ok, "CAD"}
      assert Codelists.currency_code("JPY") == {:ok, "JPY"}
      assert Codelists.currency_code("CHF") == {:ok, "CHF"}
      # country: the starter map held 8, all European + US
      assert Codelists.country_code("CA") == {:ok, "CA"}
      assert Codelists.country_code("JP") == {:ok, "JP"}
      # contributor role: the starter map held 19 of 124
      assert Codelists.contributor_role("A38") == {:ok, "A38"}
      assert Codelists.contributor_role("B25") == {:ok, "B25"}
    end

    test "each list is the XSD's whole enumeration, code for code" do
      sources = CodelistSource.onix_lists([17, 91, 96, 150, 175])

      pairs = [
        {:contributor_role, 17},
        {:country_code, 91},
        {:currency_code, 96},
        {:product_form, 150},
        {:product_form_detail, 175}
      ]

      for {name, number} <- pairs do
        expected = sources |> Map.fetch!(number) |> Map.keys() |> MapSet.new()

        assert Codelists.size(name) == MapSet.size(expected),
               "#{name} must carry all #{MapSet.size(expected)} List#{number} codes"

        # Every XSD code resolves — an exporter that emits against a narrower
        # set than the validator accepts is the defect this row retired.
        for code <- expected do
          assert apply(Codelists, name, [code]) == {:ok, code}
        end
      end
    end
  end

  describe "ERRATA — the two list numbers the old docstring got wrong" do
    # The pre-2026-09 module filed PublishingDateRole under List 23 (actually
    # Extent type) and SupplierRole under List 25 (actually Illustration and
    # other content type). Generating from the number makes the number
    # load-bearing: List 23 has no "01" at all, so a regression to it reds
    # here AND takes every full-book export down with it.
    test "PublishingDateRole is List 163, not List 23" do
      lists = CodelistSource.onix_lists([163, 23])

      assert Codelists.publishing_date_role("01") == {:ok, "01"}
      assert Codelists.size(:publishing_date_role) == map_size(Map.fetch!(lists, 163))
      refute Map.has_key?(Map.fetch!(lists, 23), "01")
    end

    test "SupplierRole is List 93, not List 25" do
      lists = CodelistSource.onix_lists([93, 25])

      assert Codelists.supplier_role("09") == {:ok, "09"}
      assert Codelists.size(:supplier_role) == map_size(Map.fetch!(lists, 93))
      assert Codelists.size(:supplier_role) != map_size(Map.fetch!(lists, 25))
    end
  end

  describe "a genuinely absent code still REFUSES — it is never dropped" do
    test "the resolver raises with the codelist named" do
      assert_raise ArgumentError, ~r/unknown_thema_code: "BOGUS"/, fn ->
        Codelists.thema("BOGUS")
      end

      assert_raise ArgumentError, ~r/unknown_currency_code_code: "QQQ"/, fn ->
        Codelists.currency_code("QQQ")
      end

      assert_raise ArgumentError, ~r/unknown_product_form_code: "QQ"/, fn ->
        Codelists.product_form("QQ")
      end
    end

    test "a non-string code still trips the guard rather than resolving" do
      assert_raise FunctionClauseError, fn -> Codelists.thema(93) end
    end

    test "to_iodata converts the refusal into {:error, {:invalid_code, …}} naming the code" do
      if System.find_executable("xmllint") do
        doc = Map.put(minimal_book(), "themaSubjectCategory", ["BOGUS"])

        assert {:error, {:invalid_code, detail}} = Export.to_iodata(doc)
        assert detail["codelist"] == "thema"
        assert detail["code"] == "BOGUS"
      else
        # Without xmllint the XSD gate cannot run; the resolver refusal is
        # still the thing under test, so assert it at the render boundary.
        doc = Map.put(minimal_book(), "themaSubjectCategory", ["BOGUS"])
        assert_raise ArgumentError, ~r/unknown_thema_code/, fn -> xml(doc) end
      end
    end

    test "the refusal is not a silent drop: no XML is produced at all" do
      doc = Map.put(minimal_book(), "themaSubjectCategory", ["FMR", "BOGUS"])

      assert_raise ArgumentError, ~r/unknown_thema_code: "BOGUS"/, fn -> xml(doc) end

      # …and with the bad code removed the good one is still emitted, so the
      # raise above is about BOGUS, not about the Subject block generally.
      good = Map.put(minimal_book(), "themaSubjectCategory", ["FMR"])
      assert xml(good) =~ ~s|<SubjectCode>FMR</SubjectCode>|
    end
  end

  describe "an export carrying beyond-starter codes passes the XSD gate" do
    @tag :xmllint
    test "Thema FMR + currency CAD validate against the vendored ONIX XSD" do
      if System.find_executable("xmllint") do
        doc =
          minimal_book()
          |> Map.put("themaSubjectCategory", ["FMR"])
          |> Map.put("productSupplies", [
            %{
              "supplyDetails" => [
                %{
                  "supplier" => %{"supplierRole" => "09", "supplierName" => "Forlaget"},
                  "productAvailability" => "20",
                  "prices" => [
                    %{"priceType" => "02", "priceAmount" => "349.00", "currencyCode" => "CAD"}
                  ]
                }
              ]
            }
          ])

        assert {:ok, iodata} = Export.to_iodata(doc)
        bin = IO.iodata_to_binary(iodata)
        assert bin =~ ~s|<SubjectCode>FMR</SubjectCode>|
        assert bin =~ ~s|<CurrencyCode>CAD</CurrencyCode>|
      else
        IO.puts("xmllint not on PATH — skipping XSD-gate arm")
      end
    end
  end
end
