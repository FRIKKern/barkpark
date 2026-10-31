defmodule Mix.Tasks.Barkpark.PortableDoc.Conformance do
  @moduledoc """
  The Elixir reader's conformance runner: renders every golden pack case with
  `Render.render_block/2` (style `:article`), compares it with the golden's
  `expectedHtml` by normalised DOM shape, and writes
  `priv/portable_doc/conformance/elixir.json`. The shape and the report are
  defined in `priv/portable_doc/conformance/CONFORMANCE.md`.

      MIX_ENV=test mix barkpark.portable_doc.conformance          # check against the committed report
      CONFORMANCE_WRITE=1 MIX_ENV=test mix barkpark.portable_doc.conformance
      CONFORMANCE_STRICT=1 MIX_ENV=test mix barkpark.portable_doc.conformance
  """
  @compile {:no_warn_undefined, LazyHTML}
  @shortdoc "Run the Elixir reader against the PortableDoc golden pack"

  use Mix.Task

  alias Barkpark.PortableDoc.Render

  @portable_doc Path.expand("../../../priv/portable_doc", __DIR__)
  @variable_attrs ~w(href src srcset poster id)
  @sizing_hint_tags ~w(img video audio iframe source embed canvas object)
  @diff_cap 12

  def pack_dir, do: Path.join(@portable_doc, "goldens")
  def report_path(renderer), do: Path.join([@portable_doc, "conformance", renderer <> ".json"])

  @impl Mix.Task
  def run(_args) do
    report = report()

    problems =
      settle(
        report,
        System.get_env("CONFORMANCE_WRITE") == "1",
        System.get_env("CONFORMANCE_STRICT") == "1"
      )

    counts = Enum.frequencies_by(report.rows, & &1.status)

    Mix.shell().info(
      "elixir: #{counts[:pass] || 0} pass, #{counts[:fail] || 0} fail, #{counts[:missing] || 0} missing of #{length(report.rows)}"
    )

    for p <- problems, do: Mix.shell().error(p)
    if problems != [], do: exit({:shutdown, 1})
  end

  def report(dir \\ pack_dir()) do
    {stamp, cases} = load_pack!(dir)

    case row(%{
           "type" => "conformance-unknown",
           "input" => %{"type" => "conformance-unknown"},
           "expectedHtml" => ""
         }) do
      %{status: :missing} -> :ok
      r -> raise "the runner cannot see a missing type: an unknown block read as #{r.status}"
    end

    %{
      renderer: "elixir",
      compare: "dom",
      pack_stamp: stamp,
      ran_at_sha: head_sha(),
      rows: Enum.map(cases, &row/1)
    }
  end

  def load_pack!(dir) do
    stamp_path = Path.join(dir, "stamp.json")
    unless File.exists?(stamp_path), do: raise("no golden pack at #{dir}")
    files = dir |> Path.join("blocks/*.golden.json") |> Path.wildcard() |> Enum.sort()
    if files == [], do: raise("golden pack at #{dir} has zero block cases")
    stamp = :crypto.hash(:sha256, File.read!(stamp_path)) |> Base.encode16(case: :lower)
    {stamp, Enum.map(files, &(&1 |> File.read!() |> Jason.decode!()))}
  end

  def settle(report, write?, strict?) do
    path = report_path(report.renderer)

    drift =
      cond do
        write? ->
          File.write!(path, encode(report))
          []

        not File.exists?(path) ->
          ["#{path} is not committed; run with CONFORMANCE_WRITE=1"]

        true ->
          committed = path |> File.read!() |> Jason.decode!()
          fresh = report |> encode() |> Jason.decode!()

          for key <- ~w(renderer compare pack_stamp rows),
              committed[key] != fresh[key],
              do: "#{key} drifted from #{path}; rerun with CONFORMANCE_WRITE=1"
      end

    drift ++
      for(
        %{status: s} = r <- report.rows,
        strict? and s != :pass,
        do: "strict: #{r.type} is #{s}"
      )
  end

  def encode(report) do
    rows =
      Enum.map(report.rows, fn r ->
        Jason.OrderedObject.new(
          [type: r.type, status: Atom.to_string(r.status)] ++
            if(r[:diff], do: [diff: r.diff], else: [])
        )
      end)

    Jason.OrderedObject.new(
      renderer: report.renderer,
      compare: report.compare,
      pack_stamp: report.pack_stamp,
      ran_at_sha: report.ran_at_sha,
      rows: rows
    )
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp row(%{"type" => type, "input" => input, "expectedHtml" => golden}) do
    case shape(Render.render_block(input, %{style: :article})) do
      [%{classes: ["bp-unknown-block"]}] -> %{type: type, status: :missing}
      actual -> verdict(type, diff(actual, shape(golden)))
    end
  end

  def verdict(type, []), do: %{type: type, status: :pass}

  def verdict(type, diffs) when length(diffs) > @diff_cap,
    do: %{
      type: type,
      status: :fail,
      diff: Enum.take(diffs, @diff_cap) ++ ["… #{length(diffs) - @diff_cap} more"]
    }

  def verdict(type, diffs), do: %{type: type, status: :fail, diff: diffs}

  defp head_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: @portable_doc, stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  def shape(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.to_tree() |> nodes()

  defp nodes(tree) do
    tree
    |> Enum.reject(&match?({:comment, _}, &1))
    |> Enum.chunk_by(&is_binary/1)
    |> Enum.flat_map(fn
      [t | _] = texts when is_binary(t) ->
        case squash(Enum.join(texts)) do
          "" -> []
          text -> [%{text: text}]
        end

      elements ->
        Enum.map(elements, &element/1)
    end)
  end

  defp element({tag, attrs, children}) do
    tag = String.downcase(tag)
    attrs = Enum.map(attrs, fn {k, v} -> {String.downcase(k), v} end)

    %{
      tag: tag,
      classes:
        attrs |> attr("class") |> String.split(~r/\s+/u, trim: true) |> Enum.uniq() |> Enum.sort(),
      attrs:
        for(
          {k, v} <- attrs,
          k not in ["class", "style"],
          not variable?(tag, k),
          into: %{},
          do: {k, squash(v)}
        ),
      style: parse_style(attr(attrs, "style")),
      children: nodes(children)
    }
  end

  defp attr(attrs, name), do: Enum.find_value(attrs, "", fn {k, v} -> k == name && v end)

  defp variable?(tag, k),
    do: k in @variable_attrs or (k in ~w(width height) and tag in @sizing_hint_tags)

  defp squash(s), do: s |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp parse_style(raw) do
    for decl <- String.split(raw, ";"),
        [prop, value] <- [String.split(decl, ":", parts: 2)],
        prop = prop |> String.trim() |> String.downcase(),
        prop != "",
        into: %{},
        do: {prop, squash(value)}
  end

  def diff(actual, golden), do: diff_list(actual, golden, "root", []) |> Enum.reverse()

  defp diff_list(actual, golden, path, out) do
    out =
      if length(actual) != length(golden),
        do: [
          "#{path}: #{length(actual)} children [#{Enum.map_join(actual, ",", &label/1)}] != #{length(golden)} [#{Enum.map_join(golden, ",", &label/1)}]"
          | out
        ],
        else: out

    actual
    |> Enum.zip(golden)
    |> Enum.with_index()
    |> Enum.reduce(out, fn {{a, g}, i}, acc ->
      diff_node(a, g, "#{path} > #{label(g)}[#{i}]", acc)
    end)
  end

  defp diff_node(%{text: t}, %{text: t}, _path, out), do: out

  defp diff_node(a, g, path, out) when is_map_key(a, :text) or is_map_key(g, :text),
    do: ["#{path}: #{leaf(a)} != #{leaf(g)}" | out]

  defp diff_node(%{tag: a}, %{tag: g}, path, out) when a != g,
    do: ["#{path}: <#{a}> != <#{g}>" | out]

  defp diff_node(a, g, path, out) do
    out =
      if a.classes != g.classes,
        do: [
          "#{path}: class {#{Enum.join(a.classes, " ")}} != {#{Enum.join(g.classes, " ")}}" | out
        ],
        else: out

    out = diff_map(a.attrs, g.attrs, path, "attr", out)
    out = diff_map(a.style, g.style, path, "style", out)
    diff_list(a.children, g.children, path, out)
  end

  defp diff_map(a, g, path, kind, out) do
    (Map.keys(a) ++ Map.keys(g))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(out, fn k, acc ->
      case {a[k], g[k]} do
        {nil, v} -> ["#{path}: #{kind} #{k}=\"#{v}\" missing" | acc]
        {v, nil} -> ["#{path}: #{kind} #{k}=\"#{v}\" extra" | acc]
        {v, v} -> acc
        {av, gv} -> ["#{path}: #{kind} #{k} \"#{av}\" != \"#{gv}\"" | acc]
      end
    end)
  end

  defp leaf(%{text: t}), do: "\"#{t}\""
  defp leaf(%{tag: tag}), do: "<#{tag}>"

  defp label(%{text: _}), do: "#text"
  defp label(%{tag: tag, classes: []}), do: tag
  defp label(%{tag: tag, classes: classes}), do: Enum.join([tag | classes], ".")
end
