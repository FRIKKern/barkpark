defmodule Barkpark.Plugins.OnixEdit.Export.WI4Test do
  @moduledoc """
  WI4 — CollateralDetail + PublishingDetail + ProductSupply + Norwegian-locale defaults.

  Pure unit tests; no DB, no LiveView. Uses `ExUnit.CaptureLog.capture_log/1`
  for the Logger.warning assertion on the en-fallback path.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Barkpark.Plugins.OnixEdit.Export

  alias Barkpark.Plugins.OnixEdit.Export.{
    Codelists,
    CollateralDetail,
    ProductSupply,
    PublishingDetail
  }

  defp xml(book_doc) do
    book_doc
    |> Export.to_xml()
    |> IO.iodata_to_binary()
  end

  defp full_book do
    %{
      "_publishedId" => "p9",
      "productIdentifiers" => [
        %{"productIdType" => "15", "idValue" => "9788234567890"}
      ],
      "productForm" => "BB",
      "titleDetails" => [
        %{
          "titleType" => "01",
          "titleElements" => [
            %{"titleElementLevel" => "01", "titleText" => "Min nye bok"}
          ]
        }
      ],
      "contributors" => [
        %{
          "contributorRole" => "A01",
          "personName" => %{"keyNames" => "Hamsun"}
        }
      ],
      "collateralDetail" => %{
        "textContents" => [
          %{
            "textType" => "03",
            "contentAudience" => "00",
            "text" => %{
              "nob" => "Norsk beskrivelse av boken.",
              "eng" => "English description of the book."
            }
          }
        ],
        "supportingResources" => [
          %{
            "resourceContentType" => "01",
            "contentAudience" => "00",
            "resourceMode" => "03",
            "resourceVersions" => [
              %{
                "resourceForm" => "02",
                "resourceLink" => "https://api.barkpark.cloud/media/p9-cover.jpg"
              }
            ]
          }
        ]
      },
      "publishingDetail" => %{
        "imprint" => %{"imprintName" => "Demo Forlag"},
        "publishers" => [
          %{"publishingRole" => "01", "publisherName" => "Acme Pub"}
        ],
        "publishingDates" => [
          %{"publishingDateRole" => "01", "date" => "2026-04-29"}
        ]
      },
      "productSupplies" => [
        %{
          "market" => %{
            "territory" => %{"countries" => ["NO"]}
          },
          "marketPublishingDetail" => %{
            "publisherRepresentatives" => [
              %{"agentName" => "Bokbasen"}
            ]
          },
          "supplyDetails" => [
            %{
              "supplier" => %{"supplierRole" => "09", "supplierName" => "Acme Pub"},
              "productAvailability" => "20",
              "prices" => [
                %{"priceType" => "02", "priceAmount" => "299.00", "currencyCode" => "NOK"}
              ]
            }
          ]
        }
      ]
    }
  end

  describe "full book — all 3 detail blocks emit; child element order in <Product> is canonical" do
    test "every WI4 block present, namespace correct" do
      bin = xml(full_book())

      assert bin =~ ~s|<ONIXMessage|
      assert bin =~ ~s|xmlns="http://ns.editeur.org/onix/3.0/reference"|

      assert bin =~ ~s|<DescriptiveDetail>|
      assert bin =~ ~s|<CollateralDetail>|
      assert bin =~ ~s|<PublishingDetail>|
      assert bin =~ ~s|<ProductSupply>|
    end

    test "canonical ONIX 3.0 child order in <Product>" do
      bin = xml(full_book())

      record_ref = position(bin, "<RecordReference>")
      notification = position(bin, "<NotificationType>")
      product_id = position(bin, "<ProductIdentifier>")
      descriptive = position(bin, "<DescriptiveDetail>")
      collateral = position(bin, "<CollateralDetail>")
      publishing = position(bin, "<PublishingDetail>")
      product_supply = position(bin, "<ProductSupply>")

      assert record_ref < notification
      assert notification < product_id
      assert product_id < descriptive
      assert descriptive < collateral
      assert collateral < publishing
      assert publishing < product_supply
    end

    test "Norwegian-locale defaults — NOK currency + NO territory both present" do
      bin = xml(full_book())

      assert bin =~ ~s|<CountriesIncluded>NO</CountriesIncluded>|
      assert bin =~ ~s|<CurrencyCode>NOK</CurrencyCode>|
    end

    test "publishingDate emitted in compact YYYYMMDD" do
      bin = xml(full_book())
      assert bin =~ ~s|<Date>20260429</Date>|
    end
  end

  describe "CollateralDetail — Norwegian-locale Text language semantics" do
    test "nb-NO when localizedText resolves to nob" do
      element =
        CollateralDetail.build(%{
          "collateralDetail" => %{
            "textContents" => [
              %{"text" => %{"nob" => "Norsk tekst", "eng" => "English text"}}
            ]
          }
        })

      bin = element |> XmlBuilder.generate() |> IO.iodata_to_binary()
      assert bin =~ ~s|<Text language="nb-NO">Norsk tekst</Text>|
      refute bin =~ ~s|<Text language="en">|
    end

    test "en + Logger.warning when only English description supplied" do
      log =
        capture_log([level: :warning], fn ->
          element =
            CollateralDetail.build(%{
              "collateralDetail" => %{
                "textContents" => [
                  %{"text" => %{"eng" => "English-only description."}}
                ]
              }
            })

          bin = element |> XmlBuilder.generate() |> IO.iodata_to_binary()
          assert bin =~ ~s|<Text language="en">English-only description.</Text>|
        end)

      assert log =~ "TextContent fell back to English"
    end

    test "missing supportingResources → CollateralDetail emits TextContent only; well-formed" do
      bin =
        full_book()
        |> Map.update!("collateralDetail", &Map.delete(&1, "supportingResources"))
        |> xml()

      assert bin =~ ~s|<CollateralDetail>|
      assert bin =~ ~s|<TextContent>|
      refute bin =~ ~s|<SupportingResource>|
    end

    test "missing both textContents and supportingResources → CollateralDetail returns nil" do
      assert CollateralDetail.build(%{"collateralDetail" => %{}}) == nil
      assert CollateralDetail.build(%{}) == nil
    end
  end

  describe "ProductSupply — defaults & no empty Price" do
    test "missing prices → SupplyDetail has Supplier + ProductAvailability but NO Price element" do
      book =
        full_book()
        |> put_in(["productSupplies", Access.at(0), "supplyDetails", Access.at(0), "prices"], [])

      bin = xml(book)

      assert bin =~ ~s|<Supplier>|
      assert bin =~ ~s|<ProductAvailability>20</ProductAvailability>|
      refute bin =~ ~s|<Price>|
      refute bin =~ ~s|<Price/>|
    end

    test "missing productSupplies entirely → synthesized default ProductSupply with NO + 09 + 20" do
      bin = xml(%{"_publishedId" => "p1"})

      assert bin =~ ~s|<ProductSupply>|
      assert bin =~ ~s|<CountriesIncluded>NO</CountriesIncluded>|
      assert bin =~ ~s|<SupplierRole>09</SupplierRole>|
      assert bin =~ ~s|<ProductAvailability>20</ProductAvailability>|
      refute bin =~ ~s|<Price>|
    end

    test "build/2 returns a list of <ProductSupply> elements" do
      result = ProductSupply.build(full_book())
      assert is_list(result)
      assert length(result) == 1
    end
  end

  describe "PublishingDetail — nil-when-empty" do
    test "book with no imprint/publishers/publishingDates → entire <PublishingDetail> omitted" do
      book = %{
        "_publishedId" => "px",
        "publishingDetail" => %{}
      }

      bin = xml(book)

      refute bin =~ ~s|<PublishingDetail>|
      refute bin =~ ~s|<PublishingDetail/>|
    end

    test "book without publishingDetail field at all → omitted" do
      assert PublishingDetail.build(%{}) == nil
    end

    test "imprint only → PublishingDetail emits with just Imprint child" do
      element =
        PublishingDetail.build(%{
          "publishingDetail" => %{"imprint" => %{"imprintName" => "Demo Forlag"}}
        })

      bin = element |> XmlBuilder.generate() |> IO.iodata_to_binary()
      assert bin =~ ~s|<Imprint>|
      assert bin =~ ~s|<ImprintName>Demo Forlag</ImprintName>|
      refute bin =~ ~s|<Publisher>|
      refute bin =~ ~s|<PublishingDate>|
    end

    test "ISO date with time component is stripped to compact YYYYMMDD" do
      element =
        PublishingDetail.build(%{
          "publishingDetail" => %{
            "publishingDates" => [%{"date" => "2026-04-29T10:30:00Z"}]
          }
        })

      bin = element |> XmlBuilder.generate() |> IO.iodata_to_binary()
      assert bin =~ ~s|<Date>20260429</Date>|
    end
  end

  describe "Codelists — 10 new lists resolve known codes; raise on unknown" do
    test "every dispatched code resolves to itself" do
      cases = [
        {:publishing_date_role, ["01", "11", "12"]},
        {:supplier_role, ["02", "09"]},
        {:price_type, ["02", "04", "41"]},
        {:product_availability, ["10", "20", "22", "50"]},
        {:country_code, ["NO", "SE", "DK", "FI", "IS", "GB", "US", "DE"]},
        {:currency_code, ["NOK", "SEK", "DKK", "EUR", "USD", "GBP"]},
        {:text_type, ["01", "02", "03"]},
        {:content_audience, ["00", "01", "03"]},
        {:resource_content_type, ["01", "03", "04", "17"]},
        {:resource_mode, ["02", "03", "04", "05", "06"]}
      ]

      for {fun, codes} <- cases, code <- codes do
        assert {:ok, ^code} = apply(Codelists, fun, [code]),
               "expected Codelists.#{fun}/1 to resolve #{inspect(code)}"
      end
    end

    test "every list raises ArgumentError on unknown code" do
      funs = [
        :publishing_date_role,
        :supplier_role,
        :price_type,
        :product_availability,
        :country_code,
        :currency_code,
        :text_type,
        :content_audience,
        :resource_content_type,
        :resource_mode
      ]

      for fun <- funs do
        assert_raise ArgumentError, ~r/unknown_/, fn ->
          apply(Codelists, fun, ["ZZ-not-a-code"])
        end
      end
    end
  end

  describe "informal xmllint sanity (skipped when binary missing)" do
    @tag :xmllint
    test "full WI4 book → xmllint --noout reports well-formed" do
      xmllint = System.find_executable("xmllint")

      if is_nil(xmllint) do
        IO.puts(
          "xmllint not on PATH — skipping informal well-formedness check (formal XSD validation gate is WI5)"
        )
      else
        bin = xml(full_book())
        path = Path.join(System.tmp_dir!(), "barkpark_onix_wi4_smoke.xml")
        File.write!(path, bin)

        {output, exit_code} = System.cmd(xmllint, ["--noout", path], stderr_to_stdout: true)
        assert exit_code == 0, "xmllint --noout failed: " <> output
      end
    end
  end

  # ---- helpers --------------------------------------------------------------

  defp position(bin, needle) do
    case :binary.match(bin, needle) do
      {pos, _len} -> pos
      :nomatch -> raise "needle not found: #{needle}"
    end
  end
end
