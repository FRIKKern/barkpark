defmodule Barkpark.Content.WriterSanitizerWarningIdTest do
  # task-6428a147dd5c0cd4 (#28404 r6 review) asked whether the writer's
  # `attrs["doc_id"]` could be nil when the sanitizer logs. Both doors put the
  # row's `doc_id` into attrs before they scrub (`do_create_document`,
  # `admitted_upsert_document`), so it is not: these tests pin that, through
  # a real write, and pass on the code they were written against.
  #
  # Nothing stored is known to need more than three passes, so the cap is
  # lowered to one through the app env (it can only lower it). That touches
  # global config: not async.
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content
  alias Barkpark.PortableDoc.HtmlSanitizer
  alias Barkpark.PortableDoc.HtmlSanitizer.Cache

  @unsettled ~s(<p>body</p><ul><li>z<div><aside><li>y</li></aside></div></li></ul>)

  setup do
    # A scrub's output is cached per node, so its fail-closed warning fires
    # once per body, id and policy version (`HtmlSanitizer.Cache`). Each test
    # here reads the warning, so each starts with nothing cached.
    Cache.invalidate()
    prev = Application.get_env(:barkpark, HtmlSanitizer)
    Application.put_env(:barkpark, HtmlSanitizer, max_passes: 1)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, HtmlSanitizer, prev),
        else: Application.delete_env(:barkpark, HtmlSanitizer)
    end)
  end

  test "a create with no id names the id the write lands on" do
    {result, log} =
      with_log(fn ->
        Content.create_document(
          "paper",
          %{"title" => "Unsettled", "body_html" => @unsettled},
          "production"
        )
      end)

    assert {:ok, doc} = result
    assert is_binary(doc.doc_id)
    assert log =~ "did not settle"
    assert log =~ ~s(id="#{doc.doc_id}")
    refute log =~ "id=nil"
    assert doc.content["body_html"] == "<p>body z y</p>"
  end

  test "an upsert names the id it writes" do
    {result, log} =
      with_log(fn ->
        Content.upsert_document(
          "paper",
          %{"doc_id" => "unsettled-upsert", "title" => "U", "body_html" => @unsettled},
          "production"
        )
      end)

    assert {:ok, doc} = result
    assert log =~ ~s(id="#{doc.doc_id}")
    refute log =~ "id=nil"
  end
end
