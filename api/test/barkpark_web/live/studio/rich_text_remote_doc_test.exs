defmodule BarkparkWeb.Studio.RichTextRemoteDocTest do
  @moduledoc """
  #28766 review: the change log is of one document (`editor_rt_doc`). A post
  on another is never read against it, even with its forget lost.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @name "doc[meta].rt"
  @was [
    %{
      "_type" => "block",
      "_key" => "b0",
      "children" => [%{"_type" => "span", "_key" => "s0", "text" => "one", "marks" => []}],
      "markDefs" => [],
      "style" => "normal"
    }
  ]
  @now [
    %{
      "_type" => "block",
      "_key" => "b0",
      "children" => [%{"_type" => "span", "_key" => "s0", "text" => "one B", "marks" => []}],
      "markDefs" => [],
      "style" => "normal"
    }
  ]

  defp socket(open) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        dataset: "production",
        editor_doc: %{doc_id: open, type: "t"},
        editor_rt_doc: PostIdentity.value("production", "t", "d1"),
        editor_rt_log: %{@name => [{100, @was, @now}]}
      }
    }
  end

  defp post, do: %{"meta" => %{"rt" => "<p>one A</p>"}}

  test "a post on the document the log is of, on an older number, is read against it" do
    assert {_doc, acts} = RichTextRemote.split(socket("d1"), post(), ["#{@name}|50"])
    refute acts == [current: @name]
  end

  test "a post on another document is A's as typed" do
    assert RichTextRemote.split(socket("d2"), post(), ["#{@name}|50"]) ==
             {post(), [current: @name]}
  end
end
