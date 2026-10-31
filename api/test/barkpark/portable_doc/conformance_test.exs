defmodule Barkpark.PortableDoc.ConformanceTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Barkpark.PortableDoc.Conformance

  @renderers ~w(editor-canvas elixir mobile pdrender pdrender-wasm react)
  @conformance Path.dirname(Conformance.report_path("elixir"))

  defp pack_types do
    Conformance.pack_dir()
    |> Path.join("blocks/*.golden.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!() |> Map.fetch!("type")))
  end

  defp committed do
    for path <- Path.wildcard(Path.join(@conformance, "*.json")),
        into: %{},
        do: {Path.basename(path, ".json"), path |> File.read!() |> Jason.decode!()}
  end

  test "the Elixir reader's committed report equals a fresh run" do
    assert Conformance.settle(Conformance.report(), false, false) == []
  end

  test "every renderer in this repo has a committed report" do
    assert Enum.sort(Map.keys(committed())) == @renderers
  end

  test "every committed report carries the pack's current stamp" do
    {stamp, _} = Conformance.load_pack!(Conformance.pack_dir())

    for {name, report} <- committed() do
      assert report["pack_stamp"] == stamp,
             "conformance/#{name}.json ran against another pack; rerun its runner (CONFORMANCE.md)"
    end
  end

  test "every committed report holds one row per pack block type, never fewer" do
    types = pack_types()
    assert length(types) == 80

    for {name, report} <- committed() do
      assert report["renderer"] == name
      assert report["compare"] in ~w(dom text)

      assert Enum.map(report["rows"], & &1["type"]) == types,
             "conformance/#{name}.json rows != pack types"

      for row <- report["rows"] do
        assert row["status"] in ~w(pass fail missing)
        assert row["status"] == "fail" == match?([_ | _], row["diff"])
      end
    end
  end

  test "no pack and an empty pack both refuse to run" do
    assert_raise RuntimeError, ~r/no golden pack/, fn ->
      Conformance.report("/nonexistent-pack")
    end

    empty =
      Path.join(System.tmp_dir!(), "bp-conformance-empty-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(empty, "blocks"))
    File.write!(Path.join(empty, "stamp.json"), "{}")

    try do
      assert_raise RuntimeError, ~r/zero block cases/, fn -> Conformance.report(empty) end
    after
      File.rm_rf!(empty)
    end
  end

  test "the shape ignores class order, attribute order and whitespace runs" do
    assert Conformance.diff(
             Conformance.shape(
               ~s(<div class="b a" data-x="1" role="note">  hi \n there <!-- c --></div>)
             ),
             Conformance.shape(~s(<div role="note" data-x="1" class="a b">hi there</div>))
           ) == []
  end

  test "the shape skips href, src, srcset, poster and id, and width/height on media only" do
    assert Conformance.diff(
             Conformance.shape(~s(<a href="/a" id="x" poster="p" srcset="s">t</a>)),
             Conformance.shape(~s(<a href="/b" id="y">t</a>))
           ) == []

    assert Conformance.diff(
             Conformance.shape(~s(<img width="1" height="2" alt="a">)),
             Conformance.shape(~s(<img width="3" height="4" alt="a">))
           ) == []

    assert Conformance.diff(
             Conformance.shape(~s(<svg width="1" height="1"></svg>)),
             Conformance.shape(~s(<svg width="2" height="1"></svg>))
           ) == [~s(root > svg[0]: attr width "1" != "2")]
  end

  test "the shape merges text split by a comment into one leaf" do
    assert Conformance.shape("<p>a<!-- -->b</p>") == Conformance.shape("<p>ab</p>")
  end

  test "the shape reds a wrong tag, class, attribute, style, text and child count" do
    golden = Conformance.shape(~s(<p class="a" data-k="1" style="color: red">x<b>y</b></p>))

    for {actual, expect} <- [
          {~s(<div class="a" data-k="1" style="color: red">x<b>y</b></div>), ~r/<div> != <p>/},
          {~s(<p class="b" data-k="1" style="color: red">x<b>y</b></p>),
           ~r/class \{b\} != \{a\}/},
          {~s(<p class="a" data-k="2" style="color: red">x<b>y</b></p>),
           ~r/attr data-k "2" != "1"/},
          {~s(<p class="a" data-k="1" style="color: blue">x<b>y</b></p>),
           ~r/style color "blue" != "red"/},
          {~s(<p class="a" data-k="1" style="color: red">z<b>y</b></p>), ~r/"z" != "x"/},
          {~s(<p class="a" data-k="1" style="color: red">x</p>), ~r/1 children \[#text\] != 2/}
        ] do
      assert [_ | _] = diffs = Conformance.diff(Conformance.shape(actual), golden)
      assert Enum.any?(diffs, &(&1 =~ expect)), "#{actual}: #{inspect(diffs)}"
    end
  end
end
