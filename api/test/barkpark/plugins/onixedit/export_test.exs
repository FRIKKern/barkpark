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
      assert bin =~ ~s|<SentDateTime>2026-04-29T12:00:00Z</SentDateTime>|
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
