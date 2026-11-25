defmodule BarkparkWeb.Studio.StudioCleanMergeQuietTest do
  @moduledoc """
  task-3bb95fc2c7113518 (#28781 review): on the Studio surface, after a clean
  merge (two tabs edit their own words of one paragraph, both saved, no
  clash) both tabs said "Updated by another user". Nothing was lost, but it
  read like a conflict. The desk takes another user's save over a clean form
  in quietly (`EditorHost.quiet_remote/1`, task-22f40460dbb71b27), as
  TanStack's footer does; the Studio now does too. Over unsaved edits it is
  still a conflict and says so.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  @words "Updated by another user"

  setup %{conn: conn}, do: setup_doc(conn)

  for surface <- [:studio, :desk] do
    test "#{surface}: a clean merge of two tabs' words in one paragraph: neither tab says #{@words}",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      post_rt(a, "<p>ONE two</p>", 0)
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["ONE two"] end)

      html = post_rt(b, "<p>one TWO</p>", 0)
      refute html =~ "Someone else rewrote"
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["ONE TWO"] end)
      assert eventually(fn -> words(form(a)["meta"]["rt"]) == ["ONE TWO"] end)

      for view <- [a, b] do
        assert :sys.get_state(view.pid).socket.assigns.doc_conflict == false
        refute render(view) =~ @words
      end
    end
  end

  test "studio: another tab's save over a clean form says nothing", c do
    c = Map.put(c, :surface, :studio)
    {a, b} = {open(c), open(c)}

    send_post(b, "doc[meta].label", %{"doc[meta].label" => "l1"})
    assert eventually(fn -> form(a)["meta"]["label"] == "l1" end)
    refute render(a) =~ @words
  end
end
