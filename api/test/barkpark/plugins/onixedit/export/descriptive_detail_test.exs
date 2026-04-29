defmodule Barkpark.Plugins.OnixEdit.Export.DescriptiveDetailTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Plugins.OnixEdit.Export.{Codelists, DescriptiveDetail}

  defp xml(book_doc) do
    book_doc
    |> Export.to_xml()
    |> IO.iodata_to_binary()
  end

  defp descriptive_detail_xml(book_doc) do
    case DescriptiveDetail.build(book_doc) do
      nil -> ""
      element -> element |> XmlBuilder.generate() |> IO.iodata_to_binary()
    end
  end

  defp minimal_book do
    %{
      "_publishedId" => "p1",
      "productIdentifiers" => [
        %{"productIdType" => "03", "idValue" => "9788234567890"}
      ],
      "productForm" => "BB",
      "titleDetails" => [
        %{
          "titleType" => "01",
          "titleElements" => [
            %{"titleElementLevel" => "01", "titleText" => "Min bok"}
          ]
        }
      ],
      "contributors" => [
        %{
          "contributorRole" => "A01",
          "personName" => %{
            "personName" => "Knut Hamsun",
            "namesBeforeKey" => "Knut",
            "keyNames" => "Hamsun"
          }
        }
      ]
    }
  end

  describe "minimal book — exactly 4 DescriptiveDetail sub-blocks" do
    test "ProductComposition + ProductForm + TitleDetail + Contributor present; no ProductFormDetail or Subject" do
      bin = xml(minimal_book())

      assert bin =~ ~s|<ProductComposition>00</ProductComposition>|
      assert bin =~ ~s|<ProductForm>BB</ProductForm>|
      assert bin =~ ~s|<TitleDetail>|
      assert bin =~ ~s|<TitleText>Min bok</TitleText>|
      assert bin =~ ~s|<Contributor>|
      assert bin =~ ~s|<ContributorRole>A01</ContributorRole>|
      assert bin =~ ~s|<KeyNames>Hamsun</KeyNames>|

      refute bin =~ ~s|<ProductFormDetail>|
      refute bin =~ ~s|<MainSubject>|
      refute bin =~ ~s|<Subject>|
    end

    test "ProductIdentifier sits at Product level, before DescriptiveDetail" do
      bin = xml(minimal_book())

      assert bin =~ ~s|<ProductIdentifier>|
      assert bin =~ ~s|<ProductIDType>03</ProductIDType>|
      assert bin =~ ~s|<IDValue>9788234567890</IDValue>|

      pi_index = :binary.match(bin, "<ProductIdentifier>") |> elem(0)
      dd_index = :binary.match(bin, "<DescriptiveDetail>") |> elem(0)
      assert pi_index < dd_index, "ProductIdentifier must precede DescriptiveDetail"

      nt_index = :binary.match(bin, "<NotificationType>") |> elem(0)
      assert nt_index < pi_index, "NotificationType must precede ProductIdentifier"
    end
  end

  describe "multi-Thema book — Boss Q3 main-subject convention" do
    test "first Thema → MainSubject, remaining → Subject; ordering preserved" do
      doc =
        minimal_book()
        |> Map.put("themaSubjectCategory", ["FBA", "FBC", "Y"])

      bin = descriptive_detail_xml(doc)

      assert bin =~ ~s|<MainSubject>|

      assert bin =~
               ~r|<MainSubject>\s*<MainSubjectSchemeIdentifier>93</MainSubjectSchemeIdentifier>\s*<SubjectSchemeVersion>1.5</SubjectSchemeVersion>\s*<SubjectCode>FBA</SubjectCode>\s*</MainSubject>|s

      subject_codes =
        Regex.scan(
          ~r|<Subject>\s*<SubjectSchemeIdentifier>93</SubjectSchemeIdentifier>\s*<SubjectSchemeVersion>1.5</SubjectSchemeVersion>\s*<SubjectCode>([A-Z0-9]+)</SubjectCode>\s*</Subject>|s,
          bin
        )
        |> Enum.map(&Enum.at(&1, 1))

      assert subject_codes == ["FBC", "Y"]
    end

    test "single Thema → only MainSubject, no <Subject>" do
      doc = Map.put(minimal_book(), "themaSubjectCategory", ["F"])
      bin = descriptive_detail_xml(doc)

      assert bin =~ ~s|<MainSubject>|
      assert bin =~ ~s|<SubjectCode>F</SubjectCode>|
      refute bin =~ ~r|<Subject>\s*<SubjectSchemeIdentifier>|s
    end
  end

  describe "full book — 7 sub-blocks populated (Product- and DescriptiveDetail-level)" do
    test "all sub-blocks present and ProductIdentifier emits once per identifier" do
      doc =
        minimal_book()
        |> Map.put("productIdentifiers", [
          %{"productIdType" => "03", "idValue" => "9788234567890"},
          %{"productIdType" => "15", "idValue" => "9788234567890"}
        ])
        |> Map.put("productFormDetail", "B102")
        |> Map.put("themaSubjectCategory", ["FBA", "FBC"])

      bin = xml(doc)

      assert bin =~ ~s|<ONIXMessage|
      assert bin =~ ~s|xmlns="http://ns.editeur.org/onix/3.0/reference"|
      assert bin =~ ~s|<RecordReference>barkpark.cloud:p1</RecordReference>|
      assert bin =~ ~s|<NotificationType>03</NotificationType>|
      assert bin =~ ~s|<ProductIDType>03</ProductIDType>|
      assert bin =~ ~s|<ProductIDType>15</ProductIDType>|
      assert bin =~ ~s|<DescriptiveDetail>|
      assert bin =~ ~s|<ProductComposition>00</ProductComposition>|
      assert bin =~ ~s|<ProductForm>BB</ProductForm>|
      assert bin =~ ~s|<ProductFormDetail>B102</ProductFormDetail>|
      assert bin =~ ~s|<TitleDetail>|
      assert bin =~ ~s|<Contributor>|
      assert bin =~ ~s|<MainSubject>|
      assert bin =~ ~s|<SubjectCode>FBA</SubjectCode>|
      assert bin =~ ~s|<SubjectCode>FBC</SubjectCode>|

      pi_count =
        Regex.scan(~r|<ProductIdentifier>|, bin)
        |> length()

      assert pi_count == 2
    end
  end

  describe "subtitle absence" do
    test "no <Subtitle> emitted when titleElement.subtitle is missing" do
      bin = descriptive_detail_xml(minimal_book())
      refute bin =~ ~s|<Subtitle>|
    end

    test "no <Subtitle> emitted when subtitle is blank" do
      doc =
        Map.put(minimal_book(), "titleDetails", [
          %{
            "titleType" => "01",
            "titleElements" => [
              %{"titleElementLevel" => "01", "titleText" => "Min bok", "subtitle" => "  "}
            ]
          }
        ])

      bin = descriptive_detail_xml(doc)
      refute bin =~ ~s|<Subtitle>|
    end

    test "<Subtitle> emitted when present" do
      doc =
        Map.put(minimal_book(), "titleDetails", [
          %{
            "titleType" => "01",
            "titleElements" => [
              %{
                "titleElementLevel" => "01",
                "titleText" => "Min bok",
                "subtitle" => "En roman"
              }
            ]
          }
        ])

      bin = descriptive_detail_xml(doc)
      assert bin =~ ~s|<Subtitle>En roman</Subtitle>|
    end
  end

  describe "codelist resolution" do
    test "known Thema code → {:ok, code}" do
      assert Codelists.thema("F") == {:ok, "F"}
      assert Codelists.thema("FBA") == {:ok, "FBA"}
    end

    test "unknown Thema code raises with clear message" do
      assert_raise ArgumentError, ~r/unknown_thema_code: "ZZZ"/, fn ->
        Codelists.thema("ZZZ")
      end
    end

    test "known ContributorRole code → {:ok, code}" do
      assert Codelists.contributor_role("A01") == {:ok, "A01"}
      assert Codelists.contributor_role("B06") == {:ok, "B06"}
    end

    test "unknown ContributorRole code raises" do
      assert_raise ArgumentError, ~r/unknown_contributor_role_code: "Z99"/, fn ->
        Codelists.contributor_role("Z99")
      end
    end

    test "known ProductForm code → {:ok, code}" do
      assert Codelists.product_form("BB") == {:ok, "BB"}
      assert Codelists.product_form("EB") == {:ok, "EB"}
    end

    test "unknown ProductForm code raises" do
      assert_raise ArgumentError, ~r/unknown_product_form_code: "ZZ"/, fn ->
        Codelists.product_form("ZZ")
      end
    end

    test "known ProductFormDetail code → {:ok, code}" do
      assert Codelists.product_form_detail("E101") == {:ok, "E101"}
    end

    test "unknown ProductFormDetail code raises" do
      assert_raise ArgumentError, ~r/unknown_product_form_detail_code: "X999"/, fn ->
        Codelists.product_form_detail("X999")
      end
    end

    test "unknown Thema code in book.themaSubjectCategory raises during build" do
      doc = Map.put(minimal_book(), "themaSubjectCategory", ["BOGUS"])

      assert_raise ArgumentError, ~r/unknown_thema_code: "BOGUS"/, fn ->
        xml(doc)
      end
    end

    test "unknown ProductForm in book.productForm raises during build" do
      doc = Map.put(minimal_book(), "productForm", "ZZ")

      assert_raise ArgumentError, ~r/unknown_product_form_code: "ZZ"/, fn ->
        xml(doc)
      end
    end
  end

  describe "informal xmllint sanity (formal XSD gate is WI5)" do
    @tag :xmllint
    test "minimal-book ONIXMessage is well-formed per xmllint --noout" do
      case System.find_executable("xmllint") do
        nil ->
          IO.puts(
            "xmllint not on PATH — skipping informal well-formedness check (formal XSD validation gate is WI5)"
          )

        bin_path ->
          path = Path.join(System.tmp_dir!(), "barkpark_onix_wi3_minimal.xml")
          File.write!(path, xml(minimal_book()))

          {output, exit_code} = System.cmd(bin_path, ["--noout", path], stderr_to_stdout: true)
          assert exit_code == 0, "xmllint --noout failed: " <> output
      end
    end

    @tag :xmllint
    test "full-book ONIXMessage is well-formed per xmllint --noout" do
      case System.find_executable("xmllint") do
        nil ->
          IO.puts(
            "xmllint not on PATH — skipping informal well-formedness check (formal XSD validation gate is WI5)"
          )

        bin_path ->
          doc =
            minimal_book()
            |> Map.put("productFormDetail", "B102")
            |> Map.put("themaSubjectCategory", ["FBA", "FBC"])

          path = Path.join(System.tmp_dir!(), "barkpark_onix_wi3_full.xml")
          File.write!(path, xml(doc))

          {output, exit_code} = System.cmd(bin_path, ["--noout", path], stderr_to_stdout: true)
          assert exit_code == 0, "xmllint --noout failed: " <> output
      end
    end
  end
end
