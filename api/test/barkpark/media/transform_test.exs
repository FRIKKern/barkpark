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

    test "known-but-unapplied vocabulary is listed for a 400" do
      assert Transform.unsupported(%{"dpr" => "2", "blur" => "5", "w" => "10"}) == [
               "dpr",
               "blur"
             ]
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
