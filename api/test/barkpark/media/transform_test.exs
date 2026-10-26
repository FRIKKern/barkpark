defmodule Barkpark.Media.TransformTest do
  @moduledoc """
  The on-demand transform contract (task-50cabce448b02af7, #23016) at the
  pure layer: parameter parsing and clamping, the normalised cache key, the
  focal-point and format defaults, and the geometry the backend executes.
  No libvips needed.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.Transform

  defp plan!(params) do
    {:ok, plan} = Transform.parse(params)
    plan
  end

  describe "parse/1" do
    test "reads every supported parameter" do
      plan =
        plan!(%{
          "w" => "300",
          "h" => "200",
          "fit" => "crop",
          "rect" => "10,20,300,400",
          "fp-x" => "0.25",
          "fp-y" => "0.75",
          "fm" => "webp",
          "q" => "80"
        })

      assert plan.w == 300
      assert plan.h == 200
      assert plan.fit == "crop"
      assert plan.rect == {10, 20, 300, 400}
      assert plan.fp == {0.25, 0.75}
      assert plan.crop == ["focalpoint"]
      assert plan.fm == "webp"
      assert plan.q == 80
    end

    test "defaults: fit=clip, q=75, no format until resolved" do
      plan = plan!(%{"w" => "50"})
      assert plan.fit == "clip"
      assert plan.q == 75
      assert plan.fm == nil
      assert plan.crop == []
    end

    test "sizes clamp to max_dimension instead of failing" do
      assert plan!(%{"w" => "99999"}).w == Transform.max_dimension()
    end

    test "sizes above 100 round up to a multiple of 10; small sizes stay exact" do
      assert plan!(%{"w" => "1199"}).w == 1200
      assert plan!(%{"w" => "828"}).w == 830
      assert plan!(%{"w" => "1200", "h" => "630"}).h == 630
      assert plan!(%{"w" => "64"}).w == 64
    end

    test "q rounds to a multiple of 5" do
      assert plan!(%{"q" => "77"}).q == 75
      assert plan!(%{"q" => "1"}).q == 5
    end

    test "fm=jpeg is jpg; auto=format is a flag" do
      assert plan!(%{"fm" => "jpeg"}).fm == "jpg"
      assert plan!(%{"auto" => "format"}).auto_format
    end

    test "crop modes are sorted so order does not change the cache key" do
      assert plan!(%{"crop" => "top,left"}).crop == ["left", "top"]
      assert plan!(%{"crop" => "left,top"}).crop == ["left", "top"]
    end

    test "a bad value is refused, naming the parameter" do
      for {params, name} <- [
            {%{"w" => "abc"}, "w"},
            {%{"w" => "0"}, "w"},
            {%{"fit" => "stretch"}, "fit"},
            {%{"rect" => "1,2,3"}, "rect"},
            {%{"rect" => "0,0,0,10"}, "rect"},
            {%{"fp-x" => "1.5"}, "fp-x"},
            {%{"fm" => "bmp"}, "fm"},
            {%{"q" => "101"}, "q"},
            {%{"auto" => "compress"}, "auto"},
            {%{"crop" => "entropy,top"}, "crop"}
          ] do
        result = Transform.parse(params)

        assert match?({:error, {:invalid_param, ^name, _msg}}, result),
               "expected #{inspect(params)} to be refused on #{name}, got #{inspect(result)}"
      end
    end
  end

  describe "requested?/1 and unsupported/1" do
    test "signed-URL and cache-buster params are not transform params" do
      refute Transform.requested?(%{"_" => "sig", "exp" => "1", "v" => "2"})
      assert Transform.requested?(%{"w" => "10"})
      assert Transform.requested?(%{"fp-x" => "0.5"})
    end

    test "nothing @sanity/image-url sends is refused any more (task-e1512b7d39b345c2)" do
      params = Map.new(~w(dpr blur sharp flip or quality bg invert sat pad), &{&1, "1"})
      assert Transform.unsupported(params) == []
      assert Transform.requested?(%{"dpr" => "2"})
    end
  end

  describe "@sanity/image-url parameters (task-e1512b7d39b345c2)" do
    test "dpr multiplies w and h, so it shares the plain size's cache file" do
      assert plan!(%{"w" => "100", "h" => "50", "dpr" => "2"}) |> Map.take([:w, :h]) == %{
               w: 200,
               h: 100
             }

      assert Transform.cache_name(plan!(%{"w" => "300", "dpr" => "1.5"})) ==
               Transform.cache_name(plan!(%{"w" => "450"}))

      assert {:error, {:invalid_param, "dpr", _}} = Transform.parse(%{"w" => "10", "dpr" => "9"})
    end

    test "blur, bg, pad, flip, or, invert and sat parse; sharp is ignored; quality stands in for q" do
      p =
        plan!(%{
          "blur" => "52",
          "bg" => "f00",
          "pad" => "8",
          "flip" => "hv",
          "or" => "270",
          "invert" => "true",
          "sat" => "-100",
          "sharp" => "40",
          "quality" => "60"
        })

      assert {p.blur, p.bg, p.pad, p.flip, p.orient, p.invert, p.gray, p.q} ==
               {50, {255, 0, 0, 255}, 8, "hv", 270, true, true, 60}

      assert plan!(%{"bg" => "8000ff00"}).bg == {0, 255, 0, 128}
      assert plan!(%{"sat" => "40"}).gray == false
      assert plan!(%{"fm" => "pjpg"}).fm == "jpg"

      for {k, v} <- [
            {"blur", "-1"},
            {"bg", "zz"},
            {"pad", "x"},
            {"flip", "d"},
            {"or", "45"},
            {"invert", "maybe"},
            {"sat", "200"}
          ],
          do: assert({:error, {:invalid_param, ^k, _}} = Transform.parse(%{k => v}))
    end

    test "fit=scale stretches to the box; fit=fillmax fills it without scaling up" do
      assert Transform.geometry(plan!(%{"w" => "100", "h" => "100", "fit" => "scale"}), 600, 400).resize ==
               {100, 100}

      g = Transform.geometry(plan!(%{"w" => "1000", "h" => "1000", "fit" => "fillmax"}), 600, 400)
      assert {g.resize, g.pad} == {{600, 400}, {1000, 1000}}
    end

    test "a URL without the new parameters keeps its cache key" do
      assert Transform.canonical(
               plan!(%{
                 "w" => "1200",
                 "fm" => "webp",
                 "q" => "85",
                 "sharp" => "10",
                 "sat" => "20"
               })
             ) ==
               "v1;w=1200;h=-;fit=clip;crop=;rect=-;fp=-;fm=webp;q=85;wm=none"

      assert Transform.canonical(
               plan!(%{"w" => "100", "fm" => "jpg", "blur" => "10", "flip" => "h"})
             ) =~ ~r/;blur=10;flip=h\z/
    end
  end

  describe "canonical/2 and cache_name/2" do
    test "the same transform written two ways shares one cache file" do
      a = %{"w" => "1199", "fit" => "crop", "h" => "630", "q" => "77", "fm" => "webp"}
      b = %{"fm" => "webp", "q" => "75", "h" => "630", "w" => "1200", "fit" => "crop"}
      assert Transform.cache_name(plan!(a)) == Transform.cache_name(plan!(b))
    end

    test "the watermark profile is part of the key" do
      plan = plan!(%{"w" => "100", "fm" => "jpg"})
      refute Transform.cache_name(plan, nil) == Transform.cache_name(plan, "draft")
    end

    test "the cache name is a fixed-length hex hash plus the format" do
      name = Transform.cache_name(plan!(%{"w" => "100", "fm" => "avif"}))
      assert name =~ ~r/\A[0-9a-f]{32}\.avif\z/
    end
  end

  describe "resolve/2" do
    test "a stored focal point applies when the URL crops without one" do
      plan =
        %{"w" => "100", "h" => "100", "fit" => "crop"}
        |> plan!()
        |> Transform.resolve(focal_point: {0.9, 0.2})

      assert plan.fp == {0.9, 0.2}
      assert plan.crop == ["focalpoint"]
    end

    test "the URL's own fp-x/fp-y or crop mode wins over the stored point" do
      plan =
        %{"w" => "100", "h" => "100", "fit" => "crop", "fp-x" => "0.1"}
        |> plan!()
        |> Transform.resolve(focal_point: {0.9, 0.2})

      assert plan.fp == {0.1, 0.5}

      plan =
        %{"w" => "100", "h" => "100", "fit" => "crop", "crop" => "top"}
        |> plan!()
        |> Transform.resolve(focal_point: {0.9, 0.2})

      assert plan.fp == nil
    end

    test "a stored point is ignored when the plan does not crop" do
      plan = %{"w" => "100"} |> plan!() |> Transform.resolve(focal_point: {0.9, 0.2})
      assert plan.fp == nil
    end

    test "a stored point moves into rect coordinates" do
      plan =
        %{"w" => "100", "h" => "100", "fit" => "crop", "rect" => "500,0,500,1000"}
        |> plan!()
        |> Transform.resolve(focal_point: {0.75, 0.5}, source_size: {1000, 1000})

      assert plan.fp == {0.5, 0.5}
    end

    test "auto=format picks AVIF, then WebP, from Accept" do
      base = plan!(%{"w" => "100", "auto" => "format"})

      assert Transform.resolve(base, accept: "image/avif,image/webp,*/*", avif?: true).fm ==
               "avif"

      assert Transform.resolve(base, accept: "image/avif,image/webp,*/*", avif?: false).fm ==
               "webp"

      assert Transform.resolve(base, accept: "*/*", source_mime: "image/png").fm == "png"
    end

    test "no fm keeps the source format; gif becomes png; unknown becomes jpg" do
      base = plan!(%{"w" => "100"})
      assert Transform.resolve(base, source_mime: "image/jpeg").fm == "jpg"
      assert Transform.resolve(base, source_mime: "image/gif").fm == "png"
      assert Transform.resolve(base, source_mime: "image/webp").fm == "webp"
    end

    test "fm=avif falls back to webp when the backend cannot encode AVIF" do
      assert Transform.resolve(plan!(%{"fm" => "avif"}), avif?: false).fm == "webp"
    end
  end

  # task-a99abd94ae4c2381: auto=format serves WebP when the AVIF encode would
  # not fit `avif_budget_ms` (default 1500) on this node.
  describe "resolve/2 AVIF time budget" do
    @browser "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"

    defp auto(params, opts) do
      params
      |> Map.put("auto", "format")
      |> plan!()
      |> Transform.resolve([accept: @browser, avif?: true] ++ opts)
    end

    test "AVIF when the estimated encode fits the budget" do
      # 1200 x 1235 = 1.48 MP at 1000 ms/MP is 1482 ms.
      assert auto(%{"w" => "1200"}, source_size: {2151, 2214}, avif_ms_per_megapixel: 1000).fm ==
               "avif"
    end

    test "WebP when the estimated encode exceeds the budget" do
      # 1.48 MP at 1100 ms/MP is 1630 ms.
      assert auto(%{"w" => "1200"}, source_size: {2151, 2214}, avif_ms_per_megapixel: 1100).fm ==
               "webp"

      # The same node still answers AVIF for a small width.
      assert auto(%{"w" => "640"}, source_size: {2151, 2214}, avif_ms_per_megapixel: 1100).fm ==
               "avif"
    end

    test "the estimate uses the cropped output size, not the source" do
      opts = [source_size: {4000, 3000}, avif_ms_per_megapixel: 3000]
      assert auto(%{"w" => "600", "h" => "600", "fit" => "crop"}, opts).fm == "avif"
      # 1000 x 750 at 3000 ms/MP is 2250 ms; the 12 MP source would be 36 s.
      assert auto(%{"w" => "1000"}, opts).fm == "webp"
    end

    test "without the source size, w x h or the given side squared is the estimate" do
      opts = [avif_ms_per_megapixel: 1000]
      assert auto(%{"w" => "1300", "h" => "1300"}, opts).fm == "webp"
      assert auto(%{"w" => "1000"}, opts).fm == "avif"
      assert auto(%{"h" => "1300"}, opts).fm == "webp"
    end

    test "with no size at all, a measured cost picks WebP" do
      assert auto(%{"q" => "80"}, avif_ms_per_megapixel: 10).fm == "webp"
    end

    test "no measured cost means no budget" do
      assert auto(%{"q" => "80"}, []).fm == "avif"
      assert auto(%{"w" => "4000"}, avif_ms_per_megapixel: nil).fm == "avif"
    end

    test "the cost function runs only when AVIF is a candidate" do
      boom = fn -> flunk("cost measured for a request that cannot get AVIF") end
      plan = plan!(%{"w" => "100", "auto" => "format"})

      assert Transform.resolve(plan,
               accept: "image/webp,*/*",
               avif?: true,
               avif_ms_per_megapixel: boom
             ).fm ==
               "webp"

      assert Transform.resolve(plan, accept: @browser, avif?: false, avif_ms_per_megapixel: boom).fm ==
               "webp"

      assert Transform.resolve(plan,
               accept: @browser,
               avif?: true,
               avif_ms_per_megapixel: fn -> 1 end
             ).fm ==
               "avif"
    end

    test "fm=avif ignores the budget" do
      plan = plan!(%{"w" => "4000", "fm" => "avif"})

      assert Transform.resolve(plan, accept: @browser, avif?: true, avif_ms_per_megapixel: 1.0e6).fm ==
               "avif"
    end
  end

  describe "AVIF encoder settings" do
    test "avif_quality/1 maps every q bucket to an AVIF quality at or below it" do
      # `parse/1` rounds q to a multiple of 5, so these are all the q a plan holds.
      for q <- 5..100//5 do
        aq = Transform.avif_quality(q)
        assert aq in 1..100
        assert aq <= q
      end

      assert Transform.avif_quality(75) == 55
      assert Transform.avif_quality(84) == Transform.avif_quality(85)
      assert Transform.avif_quality(90) == 79
    end

    test "avif_quality/1 never decreases as q rises" do
      qs = Enum.map(1..100, &Transform.avif_quality/1)
      assert qs == Enum.sort(qs)
    end

    test "the default effort is 1 and the default budget 1500 ms" do
      assert Transform.avif_effort() == 1
      assert Transform.avif_budget_ms() == 1500
    end

    test "only an AVIF key carries the encoder tag" do
      assert Transform.canonical(plan!(%{"w" => "100", "fm" => "avif"})) =~
               ~r/;enc=avif-e1-qm1\z/

      for fm <- ~w(jpg png webp) do
        assert Transform.encoder_tag(plan!(%{"fm" => fm})) == nil
      end
    end

    test "JPEG, PNG and WebP keys are unchanged, so their cached files keep serving" do
      plan = plan!(%{"w" => "1200", "fm" => "webp", "q" => "85"})

      assert Transform.canonical(plan) ==
               "v1;w=1200;h=-;fit=clip;crop=;rect=-;fp=-;fm=webp;q=85;wm=none"
    end
  end

  describe "output_pixels/2" do
    test "uses the geometry when the source size is known" do
      assert Transform.output_pixels(plan!(%{"w" => "300"}), {600, 400}) == 300 * 200

      assert Transform.output_pixels(
               plan!(%{"w" => "300", "h" => "300", "fit" => "fill"}),
               {600, 400}
             ) ==
               300 * 300

      assert Transform.output_pixels(plan!(%{"rect" => "0,0,50,40"}), {600, 400}) == 50 * 40
      assert Transform.output_pixels(plan!(%{}), {600, 400}) == 600 * 400
    end

    test "falls back to the plan's sides without a source size" do
      assert Transform.output_pixels(plan!(%{"w" => "300", "h" => "200"}), nil) == 60_000
      assert Transform.output_pixels(plan!(%{"w" => "300"}), nil) == 90_000
      assert Transform.output_pixels(plan!(%{}), nil) == nil
    end
  end

  describe "geometry/3" do
    test "width only keeps the aspect" do
      assert %{resize: {300, 200}, crop: nil} =
               Transform.geometry(plan!(%{"w" => "300"}), 600, 400)
    end

    test "clip fits inside the box and may upscale; max never upscales" do
      clip = plan!(%{"w" => "1200", "h" => "1200"})
      assert Transform.geometry(clip, 600, 400).resize == {1200, 800}

      max = plan!(%{"w" => "1200", "h" => "1200", "fit" => "max"})
      assert Transform.geometry(max, 600, 400).resize == {600, 400}
    end

    test "crop covers the box and cuts it centred" do
      geo = Transform.geometry(plan!(%{"w" => "200", "h" => "200", "fit" => "crop"}), 600, 400)
      assert geo.resize == {300, 200}
      assert geo.crop == {50, 0, 200, 200}
    end

    test "crop with a focal point centres on it, clamped to the edges" do
      right = plan!(%{"w" => "200", "h" => "200", "fit" => "crop", "fp-x" => "0.9"})
      assert Transform.geometry(right, 600, 400).crop == {100, 0, 200, 200}

      left = plan!(%{"w" => "200", "h" => "200", "fit" => "crop", "fp-x" => "0.0"})
      assert Transform.geometry(left, 600, 400).crop == {0, 0, 200, 200}
    end

    test "crop=entropy hands the cut to libvips" do
      geo =
        Transform.geometry(
          plan!(%{"w" => "200", "h" => "200", "fit" => "crop", "crop" => "entropy"}),
          600,
          400
        )

      assert geo.crop == {:smart, "entropy", 200, 200}
    end

    test "fill fits inside and pads to the exact box" do
      geo = Transform.geometry(plan!(%{"w" => "300", "h" => "300", "fit" => "fill"}), 600, 400)
      assert geo.resize == {300, 200}
      assert geo.pad == {300, 300}
    end

    test "min crops to the aspect without upscaling a small source" do
      geo = Transform.geometry(plan!(%{"w" => "2000", "h" => "1000", "fit" => "min"}), 600, 400)
      assert geo.resize == nil
      assert geo.crop == {0, 50, 600, 300}
    end

    test "rect is cut first and clamped to the source" do
      geo = Transform.geometry(plan!(%{"rect" => "500,300,400,400", "w" => "50"}), 600, 400)
      assert geo.rect == {500, 300, 100, 100}
      assert geo.resize == {50, 50}
    end
  end
end
