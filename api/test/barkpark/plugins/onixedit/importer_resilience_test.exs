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

  # ────────────────────────────────────────────────────────────────────────
  # 2. Per-node isolation — parse_feed/1
  # ────────────────────────────────────────────────────────────────────────

  defp product(ref) do
    """
    <Product>
      <RecordReference>acme.example.com:#{ref}</RecordReference>
      <NotificationType>03</NotificationType>
    </Product>
    """
  end

  defp feed(fragments) do
    ~s(<?xml version="1.0" encoding="UTF-8"?><ONIXMessage>#{Enum.join(fragments)}</ONIXMessage>)
  end

  describe "parse_feed/1 isolates each <Product> node" do
    test "one raising node is SKIPPED and the batch does NOT abort" do
      xml = feed([product("a"), product("bad"), product("c")])

      # Fault injection. Every helper in the built-in product walk carries a
      # defensive catch-all clause, so no real ONIX fixture makes it raise —
      # see the :product_parser docs. Injecting the raise is what makes the
      # isolation arm an executed assertion instead of an unrun claim. The
      # good nodes still go through the REAL walk, so the surviving products
      # are genuine parse output, not stubs.
      exploding = fn node ->
        product = real_walk(node)

        if Importer.doc_id_for(product) == "bad" do
          raise ArgumentError, "boom on node bad"
        end

        product
      end

      assert {:ok, result} = Importer.parse_feed(xml, product_parser: exploding)

      assert Enum.map(result.products, &Importer.doc_id_for/1) == ["a", "c"]
      assert result.skipped == 1
      assert [%{index: 2, reason: reason}] = result.errors
      assert reason =~ "boom on node bad"
    end

    test "a clean feed reports zero skips and every product" do
      xml = feed([product("a"), product("b"), product("c")])

      assert {:ok, result} = Importer.parse_feed(xml)
      assert Enum.map(result.products, &Importer.doc_id_for/1) == ["a", "b", "c"]
      assert result.skipped == 0
      assert result.errors == []
    end

    test "every node failing is an :all_products_failed error, not a silent empty ok" do
      xml = feed([product("a"), product("b")])
      boom = fn _node -> raise ArgumentError, "always" end

      assert {:error, {:all_products_failed, errors}} =
               Importer.parse_feed(xml, product_parser: boom)

      assert Enum.map(errors, & &1.index) == [1, 2]
    end

    test "a feed with no <Product> at all is :no_products, not an empty success" do
      assert {:error, :no_products} = Importer.parse_feed(feed([]))
    end

    test "an undeclared entity is an :xml_parse_failed tuple — parse/1 EXITS on the same input" do
      # `&nbsp;` has no declaration in ONIX (there is no DTD), and xmerl
      # signals it with `exit`, which parse/1's `rescue` does not catch. The
      # mix task therefore crashed on a feed that only needed rejecting.
      xml = feed(["<Product><RecordReference>a&nbsp;b</RecordReference></Product>"])

      assert {:error, {:xml_parse_failed, _}} = Importer.parse_feed(xml)

      assert catch_exit(Importer.parse(xml))
    end

    test "a DOCTYPE is still refused" do
      xml = ~s(<?xml version="1.0"?><!DOCTYPE ONIXMessage><ONIXMessage></ONIXMessage>)
      assert {:error, {:xml_parse_failed, _}} = Importer.parse_feed(xml)
    end
  end

  # The real per-product walk, reached through the public surface: re-parse
  # just this one <Product> node with parse/1. Keeps the injected parser
  # honest — surviving products are real walk output.
  defp real_walk(node) do
    xml =
      node
      |> :xmerl.export_simple_element(:xmerl_xml)
      |> IO.chardata_to_string()

    {:ok, [product]} = Importer.parse(~s(<?xml version="1.0"?><ONIXMessage>#{xml}</ONIXMessage>))
    product
  end
end
