defmodule Barkpark.Plugins.OnixEdit.ImporterResilienceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Robustness of the ONIX import path — the three defects this file pins:

    1. `doc_id_for/1`'s id-less fallback was `imported-<random>`, so a record
       with no `<RecordReference>` and no `<ProductIdentifier>` drew a fresh
       id on every re-sync and duplicated instead of deduping.
    2. `parse/1` maps every `<Product>` under ONE function-level rescue, so a
       single raising node aborts the whole publisher feed. `parse_feed/1`
       isolates each node.
    3. ONIX withdraw notices (`NotificationType` 05, or a non-empty
       `<DeletionText>`) were parsed but never acted on.
  """

  alias Barkpark.Plugins.OnixEdit.Importer

  # ────────────────────────────────────────────────────────────────────────
  # 1. Deterministic fallback id
  # ────────────────────────────────────────────────────────────────────────

  # An id-less product: no <RecordReference>, no <ProductIdentifier>.
  defp idless_xml(title, contributor) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ONIXMessage>
      <Product>
        <NotificationType>03</NotificationType>
        <DescriptiveDetail>
          <ProductForm>BC</ProductForm>
          <TitleDetail>
            <TitleType>01</TitleType>
            <TitleElement>
              <TitleElementLevel>01</TitleElementLevel>
              <TitleText>#{title}</TitleText>
            </TitleElement>
          </TitleDetail>
          <Contributor>
            <SequenceNumber>1</SequenceNumber>
            <ContributorRole>A01</ContributorRole>
            <PersonName>#{contributor}</PersonName>
          </Contributor>
        </DescriptiveDetail>
      </Product>
    </ONIXMessage>
    """
  end

  describe "doc_id_for/1 fallback is deterministic" do
    test "the SAME id-less record parsed twice yields the SAME id" do
      xml = idless_xml("Skogen om natten", "Ingrid Bakke")

      {:ok, [first]} = Importer.parse(xml)
      {:ok, [second]} = Importer.parse(xml)

      # Guard the premise: we really are on the fallback arm, not on
      # _publishedId or productIdentifiers.
      refute Map.has_key?(first, "_publishedId")
      refute Map.has_key?(first, "productIdentifiers")

      id_a = Importer.doc_id_for(first)
      id_b = Importer.doc_id_for(second)

      assert String.starts_with?(id_a, "imported-")
      assert id_a == id_b
    end

    test "the same id is stable across a re-parse of freshly-built XML (re-sync)" do
      a = idless_xml("Skogen om natten", "Ingrid Bakke")
      b = idless_xml("Skogen om natten", "Ingrid Bakke")

      {:ok, [p1]} = Importer.parse(a)
      {:ok, [p2]} = Importer.parse(b)

      assert Importer.doc_id_for(p1) == Importer.doc_id_for(p2)
    end

    test "two genuinely different id-less records do NOT collide" do
      {:ok, [p1]} = Importer.parse(idless_xml("Skogen om natten", "Ingrid Bakke"))
      {:ok, [p2]} = Importer.parse(idless_xml("Fjellet om dagen", "Ola Nordmann"))
      {:ok, [p3]} = Importer.parse(idless_xml("Skogen om natten", "Ola Nordmann"))

      ids = [Importer.doc_id_for(p1), Importer.doc_id_for(p2), Importer.doc_id_for(p3)]

      assert length(Enum.uniq(ids)) == 3
    end

    test "a record with no title, contributor or product form still hashes deterministically" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ONIXMessage>
        <Product><NotificationType>03</NotificationType><RecordSourceName>Acme</RecordSourceName></Product>
      </ONIXMessage>
      """

      {:ok, [p]} = Importer.parse(xml)
      {:ok, [p_again]} = Importer.parse(xml)

      assert Importer.doc_id_for(p) == Importer.doc_id_for(p_again)
      assert String.starts_with?(Importer.doc_id_for(p), "imported-")
    end

    test "a real id still wins over the fallback" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ONIXMessage>
        <Product>
          <RecordReference>acme.example.com:book-1</RecordReference>
        </Product>
      </ONIXMessage>
      """

      {:ok, [p]} = Importer.parse(xml)
      assert Importer.doc_id_for(p) == "book-1"
    end
  end
end
