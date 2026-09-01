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
              %{"agentRole" => "06", "agentName" => "Bokbasen"}
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

  describe "CollateralDetail — Norwegian-locale Text language semantics (ISO 639-2/B)" do
    test "language=\"nob\" when localizedText resolves to nob" do
      element =
        CollateralDetail.build(%{
          "collateralDetail" => %{
            "textContents" => [
              %{
                "textType" => "03",
                "text" => %{"nob" => "Norsk tekst", "eng" => "English text"}
              }
            ]
          }
        })

      bin = element |> XmlBuilder.generate() |> IO.iodata_to_binary()
      assert bin =~ ~s|<Text language="nob">Norsk tekst</Text>|
      refute bin =~ ~s|<Text language="nb-NO">|
      refute bin =~ ~s|<Text language="eng">|
      refute bin =~ ~s|<Text language="en">|
    end

    test "language=\"eng\" + Logger.warning when only English description supplied" do
      log =
        capture_log([level: :warning], fn ->
          element =
            CollateralDetail.build(%{
              "collateralDetail" => %{
                "textContents" => [
                  %{"textType" => "03", "text" => %{"eng" => "English-only description."}}
                ]
              }
            })

          bin = element |> XmlBuilder.generate() |> IO.iodata_to_binary()
          assert bin =~ ~s|<Text language="eng">English-only description.</Text>|
          refute bin =~ ~s|<Text language="en">|
        end)

      assert log =~ "TextContent fell back to English"
    end

    test "unmapped locale falls back to eng + Logger.warning" do
      log =
        capture_log([level: :warning], fn ->
          element =
            CollateralDetail.build(%{
              "collateralDetail" => %{
                "textContents" => [
                  %{"textType" => "03", "text" => %{"klingon" => "tlhIngan Hol jatlh."}}
                ]
              }
            })

          bin = element |> XmlBuilder.generate() |> IO.iodata_to_binary()
          assert bin =~ ~s|<Text language="eng">tlhIngan Hol jatlh.</Text>|
        end)

      assert log =~ "non-Norwegian, non-English language"
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

    test "synthesizes complete Supplier when productSupplies is absent" do
      bin =
        xml(%{
          "_publishedId" => "p1",
          "publishingDetail" => %{
            "publishers" => [%{"publishingRole" => "01", "publisherName" => "Demo Forlag"}]
          }
        })

      assert bin =~ ~s|<ProductSupply>|
      assert bin =~ ~s|<CountriesIncluded>NO</CountriesIncluded>|
      assert bin =~ ~s|<Supplier>|
      assert bin =~ ~s|<SupplierRole>09</SupplierRole>|
      assert bin =~ ~s|<SupplierName>Demo Forlag</SupplierName>|
      assert bin =~ ~s|<ProductAvailability>20</ProductAvailability>|
      assert bin =~ ~s|<UnpricedItemType>01</UnpricedItemType>|
      refute bin =~ ~s|<Price>|

      # Ordering: SupplierRole before SupplierName (inside Supplier),
      # and Supplier → ProductAvailability → UnpricedItemType inside SupplyDetail.
      role_pos = position(bin, "<SupplierRole>")
      name_pos = position(bin, "<SupplierName>")
      avail_pos = position(bin, "<ProductAvailability>")
      unpriced_pos = position(bin, "<UnpricedItemType>")

      assert role_pos < name_pos
      assert name_pos < avail_pos
      assert avail_pos < unpriced_pos
    end

    test "synthesized Supplier falls back to imprintName when no publisher present" do
      bin =
        xml(%{
          "_publishedId" => "p_only_imprint",
          "publishingDetail" => %{"imprint" => %{"imprintName" => "Boutique Imprint"}}
        })

      assert bin =~ ~s|<SupplierName>Boutique Imprint</SupplierName>|
    end

    test "synthesized Supplier emits placeholder name when neither publisher nor imprint is present" do
      bin = xml(%{"_publishedId" => "p_unknown"})

      assert bin =~ ~s|<SupplierName>Unknown publisher</SupplierName>|
      assert bin =~ ~s|<UnpricedItemType>01</UnpricedItemType>|
    end

    test "PublisherRepresentative emits AgentRole before AgentName (XSD-required ordering)" do
      bin = xml(full_book())

      assert bin =~ ~s|<PublisherRepresentative>|
      assert bin =~ ~s|<AgentRole>06</AgentRole>|
      assert bin =~ ~s|<AgentName>Bokbasen</AgentName>|

      role_pos = position(bin, "<AgentRole>")
      name_pos = position(bin, "<AgentName>")
      assert role_pos < name_pos
    end

    test "PublisherRepresentative defaults agentRole to 07 when book.json omits it" do
      element =
        ProductSupply.build(%{
          "productSupplies" => [
            %{
              "marketPublishingDetail" => %{
                "publisherRepresentatives" => [%{"agentName" => "Default Agent"}]
              }
            }
          ]
        })

      bin = element |> List.first() |> XmlBuilder.generate() |> IO.iodata_to_binary()
      assert bin =~ ~s|<AgentRole>07</AgentRole>|
      assert bin =~ ~s|<AgentName>Default Agent</AgentName>|
    end

    test "build/2 returns a list of <ProductSupply> elements" do
      result = ProductSupply.build(full_book())
      assert is_list(result)
      assert length(result) == 1
    end

    test "MarketPublishingDetail injects the MANDATORY MarketPublishingStatus after the representative run" do
      bin = xml(full_book())

      assert bin =~ ~s|<MarketPublishingDetail>|
      # Default List 68 status "04" (Active) is injected when book.json omits it.
      assert bin =~ ~s|<MarketPublishingStatus>04</MarketPublishingStatus>|

      # XSD sequence: PublisherRepresentative* then MarketPublishingStatus.
      rep_pos = position(bin, "<PublisherRepresentative>")
      status_pos = position(bin, "<MarketPublishingStatus>")
      assert rep_pos < status_pos
    end

    test "explicit marketPublishingStatus overrides the default" do
      element =
        ProductSupply.build(%{
          "productSupplies" => [
            %{
              "marketPublishingDetail" => %{
                "marketPublishingStatus" => "02",
                "publisherRepresentatives" => [%{"agentName" => "Rep"}]
              }
            }
          ]
        })

      bin = element |> List.first() |> XmlBuilder.generate() |> IO.iodata_to_binary()
      assert bin =~ ~s|<MarketPublishingStatus>02</MarketPublishingStatus>|
      refute bin =~ ~s|<MarketPublishingStatus>04</MarketPublishingStatus>|
    end
  end

  describe "MarketPublishingDetail — real XSD gate (Export.to_iodata via xmllint)" do
    @tag :validator
    test "full_book with an explicit marketPublishingDetail now renders XSD-VALID XML" do
      if System.find_executable("xmllint") do
        # Regression guard: before the fix, an explicit <MarketPublishingDetail>
        # emitted only <PublisherRepresentative> and omitted the mandatory
        # <MarketPublishingStatus> → xmllint rejected the whole export →
        # {:error, {:xsd_invalid, _}} → HTTP export 500 / Bokbasen blocked.
        assert {:ok, _iodata} = Export.to_iodata(full_book())
      else
        IO.puts("xmllint not on PATH — skipping real XSD gate (CI installs libxml2-utils)")
      end
    end

    @tag :validator
    test "a complete book WITHOUT any marketPublishingDetail is unchanged and still XSD-valid" do
      if System.find_executable("xmllint") do
        book =
          full_book()
          |> update_in(
            ["productSupplies", Access.at(0)],
            &Map.delete(&1, "marketPublishingDetail")
          )

        assert {:ok, iodata} = Export.to_iodata(book)
        refute IO.iodata_to_binary(iodata) =~ ~s|<MarketPublishingDetail>|
      else
        IO.puts("xmllint not on PATH — skipping real XSD gate (CI installs libxml2-utils)")
      end
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
        {:agent_role, ["06", "07"]},
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
        result = apply(Codelists, fun, [code])

        assert match?({:ok, ^code}, result),
               "expected Codelists.#{fun}/1 to resolve #{inspect(code)}, got #{inspect(result)}"
      end
    end

    test "every list raises ArgumentError on unknown code" do
      funs = [
        :publishing_date_role,
        :supplier_role,
        :agent_role,
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

  describe "incomplete-but-valid book — ONIX-mandatory children present" do
    # A description with no contentAudience previously omitted the XSD-mandatory
    # <ContentAudience> → invalid XML → export 500. It must now default to "00".
    defp book_missing_content_audience do
      full_book()
      |> update_in(
        ["collateralDetail", "textContents", Access.at(0)],
        &Map.delete(&1, "contentAudience")
      )
      |> update_in(
        ["collateralDetail", "supportingResources", Access.at(0)],
        &Map.delete(&1, "contentAudience")
      )
    end

    test "TextContent without contentAudience still emits <ContentAudience>00</ContentAudience>" do
      bin = xml(book_missing_content_audience())

      assert bin =~ ~s|<TextContent>|
      assert bin =~ ~s|<ContentAudience>00</ContentAudience>|
    end

    test "SupportingResource without contentAudience still emits ResourceContentType + ContentAudience + ResourceMode" do
      bin =
        full_book()
        |> update_in(
          ["collateralDetail", "supportingResources", Access.at(0)],
          &Map.delete(&1, "contentAudience")
        )
        |> xml()

      assert bin =~ ~s|<SupportingResource>|
      assert bin =~ ~s|<ResourceContentType>01</ResourceContentType>|
      assert bin =~ ~s|<ContentAudience>00</ContentAudience>|
      assert bin =~ ~s|<ResourceMode>03</ResourceMode>|
    end

    test "SupportingResource missing a mandatory child (resourceMode) is dropped entirely" do
      bin =
        full_book()
        |> update_in(
          ["collateralDetail", "supportingResources", Access.at(0)],
          &Map.delete(&1, "resourceMode")
        )
        |> xml()

      refute bin =~ ~s|<SupportingResource>|
      # the description TextContent still present, so CollateralDetail survives
      assert bin =~ ~s|<TextContent>|
    end

    test "year-only publishing date carries dateformat=\"05\" (ONIX List 55)" do
      bin =
        full_book()
        |> put_in(["publishingDetail", "publishingDates", Access.at(0), "date"], "2026")
        |> xml()

      assert bin =~ ~s|<Date dateformat="05">2026</Date>|
    end

    test "year-month publishing date carries dateformat=\"01\" (ONIX List 55)" do
      bin =
        full_book()
        |> put_in(["publishingDetail", "publishingDates", Access.at(0), "date"], "2026-04")
        |> xml()

      assert bin =~ ~s|<Date dateformat="01">202604</Date>|
    end

    test "full YYYYMMDD publishing date is unchanged — no dateformat attribute" do
      bin = xml(full_book())

      assert bin =~ ~s|<Date>20260429</Date>|
      refute bin =~ ~s|<Date dateformat="00">|
    end
  end

  describe "XSD gate — incomplete book now validates (skipped when xmllint missing)" do
    setup do
      if System.find_executable("xmllint") do
        :ok
      else
        {:skip, "xmllint not on PATH — install libxml2-utils to run the XSD gate"}
      end
    end

    # A minimal, real-world-shaped book. No explicit `productSupplies` so the
    # ProductSupply default is synthesized (avoids an unrelated MarketPublishingDetail
    # gap in full_book's explicit supply block, which is outside this fix's scope).
    defp valid_complete_book do
      %{
        "_publishedId" => "pv",
        "productIdentifiers" => [%{"productIdType" => "15", "idValue" => "9788234567890"}],
        "productForm" => "BB",
        "titleDetails" => [
          %{
            "titleType" => "01",
            "titleElements" => [%{"titleElementLevel" => "01", "titleText" => "Min nye bok"}]
          }
        ],
        "contributors" => [
          %{"contributorRole" => "A01", "personName" => %{"keyNames" => "Hamsun"}}
        ],
        "collateralDetail" => %{
          "textContents" => [
            %{
              "textType" => "03",
              "contentAudience" => "00",
              "text" => %{"nob" => "Norsk beskrivelse."}
            }
          ],
          "supportingResources" => [
            %{
              "resourceContentType" => "01",
              "contentAudience" => "00",
              "resourceMode" => "03",
              "resourceVersions" => [
                %{"resourceForm" => "02", "resourceLink" => "https://api.barkpark.cloud/c.jpg"}
              ]
            }
          ]
        },
        "publishingDetail" => %{
          "publishers" => [%{"publishingRole" => "01", "publisherName" => "Acme Pub"}],
          "publishingDates" => [%{"publishingDateRole" => "01", "date" => "2026-04-29"}]
        }
      }
    end

    test "incomplete book (no contentAudience + year-only pub date) passes XSD validation" do
      book =
        valid_complete_book()
        |> update_in(
          ["collateralDetail", "textContents", Access.at(0)],
          &Map.delete(&1, "contentAudience")
        )
        |> update_in(
          ["collateralDetail", "supportingResources", Access.at(0)],
          &Map.delete(&1, "contentAudience")
        )
        |> put_in(["publishingDetail", "publishingDates", Access.at(0), "date"], "2026")

      assert {:ok, _iodata} = Export.to_iodata(book)
    end

    test "complete book still passes XSD validation (regression)" do
      assert {:ok, _iodata} = Export.to_iodata(valid_complete_book())
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
