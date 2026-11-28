defmodule BarkparkWeb.Studio.BigObjectRichTextAutosaveCostTest do
  @moduledoc """
  task-6a5c3e075299d4bc. One autosave of an object rich text holding 50k
  inline objects (a 7.4 MB post) cost the LiveView process 264M reductions
  with `_bp_rt_seen` and 328M without (main at dc54bf7ea1, about 8-9 s): the
  post was parsed up to five times and the stored value drawn as often.
  The field must still save, within the bound.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias Barkpark.Content.PortableText

  @moduletag :studio_live
  @moduletag timeout: 300_000
  @objects 50_000
  # 135M: a post that is not the drawn HTML is compared with the image's
  # plain read, as on main (#29288 r1 review, option (a)): one more parse
  # of the image, about 11M here. Measured 112.4M seen, 122.5M not.
  @bound 135_000_000

  defp span(k, t), do: %{"_type" => "span", "_key" => k, "text" => t, "marks" => []}
  defp chip(k), do: %{"_type" => "chip", "_key" => k, "v" => 1}

  defp para(k, children),
    do: %{
      "_type" => "block",
      "_key" => k,
      "style" => "normal",
      "markDefs" => [],
      "children" => children
    }

  defp big(anchor) do
    objects = for i <- 0..(@objects - 1)//1, do: chip("o#{i}")

    [
      para("k", [span("h", "head ")] ++ objects ++ [span("t", " tail end")]),
      para("a", [span("as", anchor)])
    ]
  end

  setup %{conn: conn}, do: {:ok, setup_doc(conn)}

  defp reductions(pid), do: elem(Process.info(pid, :reductions), 1)

  for seen? <- [true, false] do
    test "an autosave of a #{@objects}-object rich text, seen=#{seen?}: saved, under the bound",
         c do
      id = c.id <> "-big"
      meta = %{"label" => "l0", "rt" => big("anchor"), "rt2" => [block("q1", "second")]}

      {:ok, _} =
        Content.create_document(
          c.type,
          %{
            "doc_id" => id,
            "title" => "T0",
            "content" => %{"body" => [block("b1", "b")], "meta" => meta}
          },
          "production"
        )

      c = %{c | id: id}
      {:ok, a, _} = live(c.conn, "#{c.root}/_desk/#{c.type};#{c.id}")
      render_async(a, 60_000)
      assert eventually(fn -> has_element?(a, "#editor-form") end)

      v = born(a)

      fields = %{
        "doc[meta].label" => "l0",
        "doc[meta].rt" => PortableText.to_html(big("anchor A"))
      }

      fields =
        if unquote(seen?),
          do: Map.put(fields, "_bp_rt_seen", ["doc[meta].rt|#{v.seq}"]),
          else: fields

      _ = :sys.get_state(a.pid)
      r0 = reductions(a.pid)
      send_post(a, "doc[meta].rt", fields)
      spent = reductions(a.pid) - r0

      assert words(stored(c)["meta"]["rt"]) |> List.last() == "anchor A"
      assert length(hd(stored(c)["meta"]["rt"])["children"]) == @objects + 2

      # On main at dc54bf7ea1: 263.9M seen, 328.3M not.
      assert spent < @bound, "the autosave spent #{Float.round(spent / 1.0e6, 1)}M reductions"
    end
  end
end
