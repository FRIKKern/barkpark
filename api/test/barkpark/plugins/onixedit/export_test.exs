defmodule Barkpark.Plugins.OnixEdit.ExportTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Plugins.OnixEdit.Export.{Header, Message}

  describe "export/2" do
    test "returns ok-iodata for a minimal book doc" do
      assert {:ok, iodata} = Export.export(%{"_publishedId" => "p1"})
      bin = IO.iodata_to_binary(iodata)
      assert String.starts_with?(bin, "<?xml ")
      assert bin =~ ~s|<ONIXMessage|
      assert bin =~ ~s|release="3.0"|
      assert bin =~ ~s|xmlns="http://ns.editeur.org/onix/3.0/reference"|
      assert bin =~ ~s|<RecordReference>barkpark.cloud:p1</RecordReference>|
    end

    test "strips drafts. prefix from RecordReference per Boss Q1 + draft model" do
      assert {:ok, iodata} = Export.export(%{"_publishedId" => "drafts.x"})
      bin = IO.iodata_to_binary(iodata)
      assert bin =~ ~s|<RecordReference>barkpark.cloud:x</RecordReference>|
    end
  end

  describe "record_reference/2" do
    test "default host is barkpark.cloud" do
      assert Export.record_reference("p1") == "barkpark.cloud:p1"
    end

    test "custom host overrides default" do
      assert Export.record_reference("x", "other.host") == "other.host:x"
    end

    test "strips drafts. prefix" do
      assert Export.record_reference("drafts.p1") == "barkpark.cloud:p1"
    end
  end

  describe "Header.build/1" do
    test "emits SenderName=barkpark.cloud, SentDateTime, MessageNote" do
      header = Header.build(dataset: "production", sent_at: ~U[2026-04-29 12:00:00Z])
      bin = header |> XmlBuilder.generate() |> IO.iodata_to_binary()

      assert bin =~ ~s|<SenderName>barkpark.cloud</SenderName>|
      assert bin =~ ~s|<SentDateTime>20260429T120000</SentDateTime>|
      assert bin =~ ~s|<MessageNote>Barkpark dataset:production</MessageNote>|
    end

    test "default dataset is production" do
      header = Header.build()
      bin = header |> XmlBuilder.generate() |> IO.iodata_to_binary()
      assert bin =~ "Barkpark dataset:production"
    end
  end

  describe "Message.wrap/2" do
    test "wraps an empty header + empty products list as well-formed XML" do
      header = XmlBuilder.element(:Header)
      iodata = Message.wrap(header, [])
      bin = IO.iodata_to_binary(iodata)

      assert String.starts_with?(bin, "<?xml ")
      assert bin =~ ~s|<ONIXMessage|
      assert bin =~ ~s|release="3.0"|
      assert bin =~ ~s|xmlns="http://ns.editeur.org/onix/3.0/reference"|
      assert bin =~ ~s|</ONIXMessage>|
      assert bin =~ ~s|<Header/>| or bin =~ ~s|<Header></Header>|
    end
  end

  defp load_fixture(name) do
    Path.join([File.cwd!(), "test", "fixtures", "onix", name <> ".json"])
    |> File.read!()
    |> Jason.decode!()
  end

  describe "WI6 — to_iodata/1 / to_string/1 / to_file/2" do
    setup do
      if System.find_executable("xmllint") do
        :ok
      else
        {:skip, "xmllint not on PATH — install libxml2-utils to run WI6 file-output gate"}
      end
    end

    test "to_iodata/1 returns ok-iodata containing <ONIXMessage for a valid book" do
      book = load_fixture("minimal-book")
      assert {:ok, iodata} = Export.to_iodata(book)
      bin = IO.iodata_to_binary(iodata)
      assert bin =~ ~s|<ONIXMessage|
      assert bin =~ ~s|release="3.0"|
      assert bin =~ ~s|<RecordReference>barkpark.cloud:p1</RecordReference>|
    end

    test "strips C0 control chars from text so a poisoned title still validates" do
      # A vertical tab (0x0B) pasted into a title — common from Word/PDF/InDesign.
      # XML 1.0 forbids it even escaped, so before the deep-strip xmllint rejected
      # the whole export ("PCDATA invalid Char value 11") → {:error, xsd_invalid}
      # and the document was permanently un-exportable / un-publishable.
      book =
        load_fixture("minimal-book")
        |> put_in(
          ["titleDetails", Access.at(0), "titleElements", Access.at(0), "titleText"],
          "Minimum\x0BBook"
        )

      assert {:ok, iodata} = Export.to_iodata(book)
      bin = IO.iodata_to_binary(iodata)
      refute bin =~ "\x0B"
      assert bin =~ ~s|<TitleText>MinimumBook</TitleText>|
    end

    test "to_string/1 returns a UTF-8 binary" do
      book = load_fixture("minimal-book")
      assert {:ok, bin} = Export.to_string(book)
      assert is_binary(bin)
      assert String.starts_with?(bin, "<?xml ")
      assert bin =~ ~s|</ONIXMessage>|
    end

    test "to_file/2 writes the same bytes to_string/1 returns" do
      book = load_fixture("minimal-book")

      path =
        Path.join(System.tmp_dir!(), "barkpark-wi6-#{System.unique_integer([:positive])}.onix")

      # Pin sent_at: each call stamps SentDateTime at render time, so two
      # unpinned calls straddling a second boundary produce different bytes.
      opts = [sent_at: ~U[2026-01-01 12:00:00Z]]

      try do
        assert :ok = Export.to_file(book, path, opts)
        assert {:ok, expected} = Export.to_string(book, opts)
        assert File.read!(path) == expected
      after
        _ = File.rm(path)
      end
    end

    test "to_iodata/1 short-circuits on XSD failure (broken-book has no productIdentifiers)" do
      book = load_fixture("broken-book")

      assert {:error, {:xsd_invalid, reasons}} = Export.to_iodata(book)
      assert is_list(reasons)
      assert reasons != []
    end

    test "to_string/1 propagates the xsd_invalid envelope" do
      book = load_fixture("broken-book")
      assert {:error, {:xsd_invalid, _reasons}} = Export.to_string(book)
    end

    test "to_file/2 does NOT touch the filesystem when XSD validation fails" do
      book = load_fixture("broken-book")

      path =
        Path.join(
          System.tmp_dir!(),
          "barkpark-wi6-fail-#{System.unique_integer([:positive])}.onix"
        )

      refute File.exists?(path)
      assert {:error, {:xsd_invalid, _reasons}} = Export.to_file(book, path)
      refute File.exists?(path), "to_file/2 must not write the file when validation fails"
    end
  end

  describe "xmllint sanity (informal — not the WI5 gate)" do
    @tag :xmllint
    test "minimal ONIXMessage is well-formed per xmllint --noout" do
      xmllint = System.find_executable("xmllint")

      if is_nil(xmllint) do
        IO.puts(
          "xmllint not on PATH — skipping informal well-formedness check (formal XSD validation gate is WI5)"
        )
      else
        {:ok, iodata} = Export.export(%{"_publishedId" => "p1"})
        path = Path.join(System.tmp_dir!(), "barkpark_onix_wi2_smoke.xml")
        File.write!(path, IO.iodata_to_binary(iodata))

        {output, exit_code} = System.cmd(xmllint, ["--noout", path], stderr_to_stdout: true)
        assert exit_code == 0, "xmllint --noout failed: " <> output
      end
    end
  end
end
