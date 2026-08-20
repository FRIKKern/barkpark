defmodule Barkpark.PortableDoc.Render.RouteTest do
  @moduledoc """
  The route block (sport tracks): the encoded-polyline decoder proven by
  encode→decode round-trip (the encoder lives HERE, test-side — production only
  ever decodes), the SVG shape (path + start/finish markers, presentation
  attributes only), the meta/caption row, both style variants, and the honest
  empty box for absent/malformed data.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Render.DataViz

  # ── test-side encoder (Google polyline algorithm) ───────────────────────────

  defp encode_polyline(points) do
    {out, _} =
      Enum.reduce(points, {"", {0, 0}}, fn {lat, lng}, {acc, {plat, plng}} ->
        ilat = round(lat * 1.0e5)
        ilng = round(lng * 1.0e5)
        {acc <> encode_value(ilat - plat) <> encode_value(ilng - plng), {ilat, ilng}}
      end)

    out
  end

  defp encode_value(v) do
    import Bitwise
    v = if v < 0, do: bnot(v <<< 1), else: v <<< 1
    encode_chunks(v, "")
  end

  defp encode_chunks(v, acc) do
    import Bitwise

    if v >= 0x20 do
      encode_chunks(v >>> 5, acc <> <<((v &&& 0x1F) ||| 0x20) + 63>>)
    else
      acc <> <<v + 63>>
    end
  end

  # A plausible little loop around a lake — enough turns to exercise deltas in
  # all four sign quadrants.
  @track [
    {59.9615, 10.7735},
    {59.9642, 10.7761},
    {59.9668, 10.7742},
    {59.9689, 10.7788},
    {59.9701, 10.7845},
    {59.9683, 10.7891},
    {59.9651, 10.7902},
    {59.9628, 10.7867},
    {59.9611, 10.7801},
    {59.9615, 10.7735}
  ]

  defp block(extra \\ %{}) do
    Map.merge(
      %{"type" => "route", "polyline" => encode_polyline(@track)},
      extra
    )
  end

  describe "polyline decoder" do
    test "encode→decode round-trips to 5-decimal precision" do
      decoded = DataViz.decode_polyline(encode_polyline(@track))
      assert length(decoded) == length(@track)

      for {{lat, lng}, {elat, elng}} <- Enum.zip(decoded, @track) do
        assert_in_delta lat, elat, 1.0e-5
        assert_in_delta lng, elng, 1.0e-5
      end
    end

    test "the Google reference vector decodes exactly" do
      # The documented example from the polyline algorithm spec.
      assert DataViz.decode_polyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@") == [
               {38.5, -120.2},
               {40.7, -120.95},
               {43.252, -126.453}
             ]
    end

    test "a malformed tail drops at the last whole pair, never invents" do
      good = encode_polyline(Enum.take(@track, 3))
      assert length(DataViz.decode_polyline(good <> "_p")) == 3
    end

    test "non-strings and empties yield no points" do
      assert DataViz.decode_polyline(nil) == []
      assert DataViz.decode_polyline("") == []
    end
  end

  describe "SVG rendering" do
    test "draws the track path with start/finish markers, presentation attrs only" do
      html = DataViz.route_html(block())

      assert html =~ ~s(<svg class="bp-route__map")
      assert html =~ ~s(fill="none" stroke=)
      assert html =~ "stroke-linejoin=\"round\""
      # start ring + finish dot
      assert html =~ ~s(stroke="#2f9e63")
      assert html =~ ~s(fill="#c65a3f")
      # a closed loop starts and ends at the same projected point
      [_, sx] = Regex.run(~r/<circle cx="([\d.]+)" cy="[\d.]+" r="5\.5" fill="none"/, html)
      [_, fx] = Regex.run(~r/<circle cx="([\d.]+)" cy="[\d.]+" r="5\.5" fill="#c65a3f"/, html)
      assert sx == fx
    end

    test "meta row renders the present display strings, in order, and skips absent" do
      html =
        DataViz.route_html(
          block(%{"sport" => "sykling", "distance" => "42.3 km", "duration" => "1t 48m"})
        )

      assert html =~ "sykling"
      assert html =~ "42.3 km"
      assert html =~ "1t 48m"
      assert html =~ ~r/sykling.*42\.3 km.*1t 48m/s
    end

    test "caption renders italic and escaped" do
      html = DataViz.route_html(block(%{"caption" => "Rundt <vannet> & hjem"}))
      assert html =~ "Rundt &lt;vannet&gt; &amp; hjem"
    end

    test "article reads the accent token; email carries literal hex" do
      article = DataViz.route_html(block(), :article)
      email = DataViz.route_html(block(), :email)

      assert article =~ "var(--paper-accent"
      refute email =~ "var("
      assert email =~ ~r/stroke="#[0-9a-fA-F]{6}"/
    end

    test "fewer than two points is the honest empty box" do
      assert DataViz.route_html(%{"type" => "route"}) =~ "bp-dataviz--empty"
      assert DataViz.route_html(%{"type" => "route", "polyline" => "??"}) =~ "bp-dataviz--empty"
    end
  end

  describe "BPML round-trip" do
    test "route blocks round-trip byte-equal through the notation" do
      blocks = [
        %{
          "id" => "r1",
          "type" => "route",
          "sport" => "løping",
          "distance" => "10.2 km",
          "elevation" => "184 m",
          "duration" => "52m",
          "caption" => "Morgenrunden",
          "polyline" => encode_polyline(@track)
        }
      ]

      bpml = Bpml.print_blocks(blocks)
      assert bpml =~ ~s(<route id="r1" sport="løping" distance="10.2 km")
      assert {:ok, parsed} = Bpml.parse_blocks(bpml)
      assert parsed == blocks
    end

    test "the whole render pipeline accepts a route block" do
      html = Barkpark.PortableDoc.Render.render_blocks([block()], %{style: :article})
      assert html =~ "bp-route__map"
    end
  end
end
