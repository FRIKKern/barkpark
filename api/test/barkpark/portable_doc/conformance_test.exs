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

  test "strict mode reds every row that is not a pass" do
    report = Conformance.report()
    red = %{report | rows: [%{type: "t", status: :missing} | report.rows]}
    assert "strict: t is missing" in Conformance.settle(red, false, true)
    assert Conformance.settle(report, false, true) == []
  end

  test "check mode reds a stale stamp and names a drifted row" do
    report = Conformance.report()
    assert [_] = Conformance.settle(%{report | pack_stamp: "stale"}, false, false)
    [first | rest] = report.rows

    assert [drift] =
             Conformance.settle(
               %{report | rows: [%{first | status: :missing} | rest]},
               false,
               false
             )

    assert drift =~ "row #{first.type} drifted"
    assert ["reference: " <> _] = Conformance.settle(%{report | reference: false}, false, false)

    assert ["committed 80 rows, pack has 79"] =
             Conformance.settle(%{report | rows: rest}, false, false)
  end

  test "a reader that renders the unknown-type probe refuses to run" do
    assert_raise RuntimeError, ~r/cannot see a missing type/, fn ->
      Conformance.report(Conformance.pack_dir(), fn _ -> "<p>drawn</p>" end)
    end
  end

  test "a fail row carries at most 12 diff lines and counts the rest" do
    lines = Enum.map(1..13, &"d#{&1}")
    assert %{status: :fail, diff: diff} = Conformance.verdict("t", lines)
    assert diff == Enum.take(lines, 12) ++ ["… 1 more"]
    assert Conformance.verdict("t", Enum.take(lines, 12)).diff == Enum.take(lines, 12)
    assert Conformance.verdict("t", []) == %{type: "t", status: :pass}
  end

  test "every renderer in this repo has a committed report" do
    assert Enum.sort(Map.keys(committed())) == @renderers
  end

  test "only the Elixir reader is marked the reference the goldens were built from" do
    for {name, report} <- committed() do
      assert Map.get(report, "reference", false) == (name == "elixir"), name
    end
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
        assert row["status"] in ~w(pass fail missing unchecked)
        assert row["status"] == "fail" == match?([_ | _], row["diff"])
        assert row["status"] != "unchecked" or report["compare"] == "text"
        assert Map.get(row, "via", "host-paint") == "host-paint"
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

  test "the shape compares every attribute: URLs, ids and media sizes included" do
    for {actual, golden, line} <- [
          {~s(<a href="/a">t</a>), ~s(<a href="/b">t</a>),
           ~s(root > a[0]: attr href "/a" != "/b")},
          {~s(<a id="x">t</a>), ~s(<a id="y">t</a>), ~s(root > a[0]: attr id "x" != "y")},
          {~s(<img alt="a">), ~s(<img src="s" alt="a">), ~s(root > img[0]: attr src="s" missing)},
          {~s(<img width="1">), ~s(<img width="3">), ~s(root > img[0]: attr width "1" != "3")}
        ] do
      assert Conformance.diff(Conformance.shape(actual), Conformance.shape(golden)) == [line]
    end
  end

  test "the shape keeps text inside pre and textarea exactly as written" do
    golden = Conformance.shape("<pre><code>a\n  b</code></pre>")
    assert [_] = Conformance.diff(Conformance.shape("<pre><code>a b</code></pre>"), golden)
    assert [_] = Conformance.diff(Conformance.shape("<pre><code>a\nb</code></pre>"), golden)

    assert [_] =
             Conformance.diff(
               Conformance.shape("<textarea>a  b</textarea>"),
               Conformance.shape("<textarea>a b</textarea>")
             )
  end

  test "the shape keeps the space between inline siblings and trims only list edges" do
    for {glued, spaced} <- [
          {"<p>a<b>b</b>c</p>", "<p>a <b>b</b> c</p>"},
          {"<p><b>a</b>b</p>", "<p><b>a</b> b</p>"},
          {"<p>a<b>b</b></p>", "<p>a <b>b</b></p>"}
        ] do
      assert Conformance.diff(Conformance.shape(glued), Conformance.shape(spaced)) != [], glued
    end

    assert Conformance.diff(
             Conformance.shape("<p>  a <b> b </b>  c </p>"),
             Conformance.shape("<p>a <b>b</b> c</p>")
           ) == []
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
