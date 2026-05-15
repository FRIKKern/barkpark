defmodule Barkpark.Plugins.OnixEdit.ImportRoundtripTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit.{Export, Importer}

  @fixture_path Path.expand("../../../fixtures/onix/full-book.json", __DIR__)
  @proof_path Path.expand("../../../../../proof/onix-sample.xml", __DIR__)
  @pinned_sent_at ~U[2026-04-29 12:00:00Z]

  test "XML → JSON → XML is byte-stable for the proof artifact" do
    xml1 = File.read!(@proof_path)

    {:ok, [product]} = Importer.parse(xml1)
    {:ok, xml2} = Export.to_string(product, sent_at: @pinned_sent_at)

    if xml1 != xml2 do
      diff_hint = first_diff_hint(xml1, xml2)

      flunk("""
      ONIX round-trip drift detected.

      The proof artifact was exported with sent_at = #{inspect(@pinned_sent_at)},
      so byte-stable round-trip is expected.

      First divergence (≈64 bytes):
      #{diff_hint}
      """)
    end

    assert xml1 == xml2
  end

  test "exporting full-book.json then importing then re-exporting is byte-stable" do
    book = @fixture_path |> File.read!() |> Jason.decode!()

    {:ok, xml1} = Export.to_string(book, sent_at: @pinned_sent_at)
    {:ok, [product]} = Importer.parse(xml1)
    {:ok, xml2} = Export.to_string(product, sent_at: @pinned_sent_at)

    if xml1 != xml2 do
      diff_hint = first_diff_hint(xml1, xml2)
      flunk("Round-trip drift on full-book.json fixture.\n\nFirst divergence:\n#{diff_hint}")
    end

    assert xml1 == xml2
  end

  test "parsing the proof artifact yields one product map with expected core fields" do
    xml = File.read!(@proof_path)
    {:ok, [product]} = Importer.parse(xml)

    assert product["_publishedId"] == "p9"
    assert product["notificationType"] == "03"
    assert product["productForm"] == "BB"
    assert product["productFormDetail"] == "B102"
    assert product["themaSubjectCategory"] == ["FBA", "FBC", "Y"]
    assert [%{"idValue" => "9788234567890", "productIdType" => "15"}] = product["productIdentifiers"]
    assert length(product["contributors"]) == 2
    assert length(product["productSupplies"]) == 2
  end

  defp first_diff_hint(a, b) do
    max = min(byte_size(a), byte_size(b))

    idx =
      Enum.find(0..(max - 1), fn i ->
        :binary.part(a, i, 1) != :binary.part(b, i, 1)
      end) || max

    start = max(idx - 32, 0)
    len_a = min(byte_size(a) - start, 96)
    len_b = min(byte_size(b) - start, 96)

    """
    at byte #{idx}:
      xml1: ...#{inspect(binary_part(a, start, len_a))}
      xml2: ...#{inspect(binary_part(b, start, len_b))}
    """
  end
end
