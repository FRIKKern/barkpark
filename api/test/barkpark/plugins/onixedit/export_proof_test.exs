defmodule Barkpark.Plugins.OnixEdit.ExportProofTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Plugins.OnixEdit.Export.Validator

  @proof_path Path.expand("../../../fixtures/onix/onix-sample.xml", __DIR__)
  @fixture_path Path.expand("../../../fixtures/onix/full-book.json", __DIR__)

  # `<SentDateTime>` is stamped with `DateTime.utc_now/0` by default. The
  # proof regen mix task (`mix onix.export_proof`) pins it to a fixed
  # timestamp so the committed artifact is byte-stable; this normalization
  # keeps the assertion robust if someone runs the exporter live without
  # `sent_at`, or if a future regen uses a different pinned date.
  @sent_dt_pattern ~r{<SentDateTime>[^<]*</SentDateTime>}
  @sent_dt_token "<SentDateTime>NORMALIZED</SentDateTime>"

  test "Export.to_string/1 of full-book.json matches fixtures/onix/onix-sample.xml byte-for-byte (modulo SentDateTime)" do
    book = @fixture_path |> File.read!() |> Jason.decode!()
    assert {:ok, xml} = Export.to_string(book)

    expected = File.read!(@proof_path)

    actual_normalized = Regex.replace(@sent_dt_pattern, xml, @sent_dt_token)
    expected_normalized = Regex.replace(@sent_dt_pattern, expected, @sent_dt_token)

    if actual_normalized != expected_normalized do
      flunk("""
      Export drift detected — test/fixtures/onix/onix-sample.xml is stale.

      If this drift is intentional, regenerate the proof artifact:
        cd api && mix onix.export_proof

      Then re-run the test and commit the updated test/fixtures/onix/onix-sample.xml.
      """)
    end

    assert actual_normalized == expected_normalized
  end

  test "fixtures/onix/onix-sample.xml validates clean against ONIX 3.0 reference XSD" do
    xml = File.read!(@proof_path)
    assert :ok = Validator.validate_xsd(xml)
  end
end
