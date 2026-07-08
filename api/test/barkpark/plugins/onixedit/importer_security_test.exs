defmodule Barkpark.Plugins.OnixEdit.ImporterSecurityTest do
  @moduledoc """
  ONIX import runs on untrusted, publisher-supplied XML. These tests pin the
  hardening in `Importer.parse/1` against the two classic entity attacks:

    * billion-laughs — exponential internal-entity expansion → memory DoS
    * XXE — external entity referencing a local file / URL → data disclosure

  Both ride in a `<!DOCTYPE>` internal subset. The parser must refuse them
  (never expand), while a normal ONIX sample still parses cleanly.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit.Importer

  @proof_path Path.expand("../../../fixtures/onix/onix-sample.xml", __DIR__)

  # Classic "billion laughs": nested internal entities that would expand to
  # ~10^9 chars if the parser resolved them. Wrapped in a Product so a
  # non-hardened parser would reach expansion during the body walk.
  @billion_laughs """
  <?xml version="1.0"?>
  <!DOCTYPE ONIXMessage [
    <!ENTITY lol "lol">
    <!ENTITY lol1 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
    <!ENTITY lol2 "&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;">
    <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
    <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
  ]>
  <ONIXMessage>
    <Product><RecordReference>&lol4;</RecordReference></Product>
  </ONIXMessage>
  """

  # XXE: an external SYSTEM entity that, if resolved, would read a local file.
  @xxe_payload """
  <?xml version="1.0"?>
  <!DOCTYPE ONIXMessage [
    <!ENTITY xxe SYSTEM "file:///etc/passwd">
  ]>
  <ONIXMessage>
    <Product><RecordReference>&xxe;</RecordReference></Product>
  </ONIXMessage>
  """

  test "billion-laughs payload is rejected, not expanded" do
    # Run under a tight timeout: a vulnerable parser would burn CPU/memory
    # expanding entities and blow the deadline instead of returning fast.
    task = Task.async(fn -> Importer.parse(@billion_laughs) end)

    assert {:error, {:xml_parse_failed, _reason}} = Task.await(task, 5_000)
  end

  test "XXE external-entity payload is rejected (no file disclosure)" do
    assert {:error, {:xml_parse_failed, _reason}} = Importer.parse(@xxe_payload)
  end

  test "any DOCTYPE declaration is refused up front" do
    doctype_only = ~s(<?xml version="1.0"?>\n<!DOCTYPE ONIXMessage>\n<ONIXMessage/>)
    assert {:error, {:xml_parse_failed, reason}} = Importer.parse(doctype_only)
    assert reason =~ "DOCTYPE"
  end

  test "a normal ONIX sample (no DTD) still parses" do
    xml = File.read!(@proof_path)
    assert {:ok, [product]} = Importer.parse(xml)
    assert product["_publishedId"] == "p9"
    assert product["productForm"] == "BB"
  end
end
