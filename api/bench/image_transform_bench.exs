# Image transform bench: cold transform time and output size per format.
#
# Run from api/:
#
#     mix run --no-start bench/image_transform_bench.exs [path/to/large.jpg] [q]
#
# For w=256, 640 and 1200 and each of jpg, webp and avif, it runs the full
# libvips pipeline (`Barkpark.Media.ImageBackend.Vix.transform/4`: open,
# thumbnail from the file, encode, write) 5 times and prints the median time
# and the output size. Every run writes a new file, so every run is cold; no
# rendition cache is involved.
#
# Without a path it writes a 4000x3000 JPEG of blurred noise over gradients to
# a temp file and uses that. A real photo gives more useful AVIF numbers: noise
# is the slowest kind of content for an AV1 encoder. `q` defaults to 75.
#
# It also prints the format `auto=format` picks for a browser Accept header at
# each width, from `Barkpark.Media.Transform.resolve/2` with this node's
# measured AVIF cost.

alias Barkpark.Media.ImageBackend.Vix, as: VixBackend
alias Barkpark.Media.Transform
alias Vix.Vips.Operation, as: Op

{src, q} =
  case System.argv() do
    [path, q | _] -> {path, String.to_integer(q)}
    [path] -> {path, 75}
    [] -> {nil, 75}
  end

generated? = is_nil(src)

src =
  src ||
    (fn ->
       {:ok, noise} = Op.gaussnoise(4000, 3000, sigma: 48.0, mean: 128.0)
       {:ok, noise} = Op.gaussblur(noise, 1.2)
       {:ok, xyz} = Op.xyz(4000, 3000)
       {:ok, x} = Op.extract_band(xyz, 0)
       {:ok, y} = Op.extract_band(xyz, 1)
       {:ok, r} = Op.linear(x, [255.0 / 4000], [0.0])
       {:ok, b} = Op.linear(y, [255.0 / 3000], [0.0])
       {:ok, r} = Op.add(r, noise)
       {:ok, b} = Op.add(b, noise)
       {:ok, img} = Op.bandjoin([r, noise, b])
       {:ok, img} = Op.cast(img, :VIPS_FORMAT_UCHAR)
       path = Path.join(System.tmp_dir!(), "bp-bench-#{System.unique_integer([:positive])}.jpg")
       {:ok, _} = Image.write(img, path, quality: 90)
       path
     end).()

{:ok, info} = Image.open(src)

IO.puts(
  "source #{src}: #{Image.width(info)}x#{Image.height(info)}, #{File.stat!(src).size} B, q=#{q}"
)

IO.puts("vips #{Vix.Vips.version()}, schedulers #{System.schedulers_online()}")

out_dir = Path.join(System.tmp_dir!(), "bp-bench-out-#{System.unique_integer([:positive])}")
File.mkdir_p!(out_dir)

median = fn xs -> xs |> Enum.sort() |> Enum.at(div(length(xs), 2)) end

run = fn w, fm ->
  {:ok, plan} = Transform.parse(%{"w" => to_string(w), "q" => to_string(q), "fm" => fm})

  samples =
    for i <- 1..5 do
      dest = Path.join(out_dir, "#{w}-#{i}.#{fm}")
      {us, :ok} = :timer.tc(fn -> VixBackend.transform(src, dest, plan, nil) end)
      {us / 1000, File.stat!(dest).size}
    end

  {median.(Enum.map(samples, &elem(&1, 0))), samples |> List.last() |> elem(1)}
end

IO.puts("\n| w | format | median ms (of 5) | bytes |")
IO.puts("|---|---|---|---|")

for w <- [256, 640, 1200], fm <- ["jpg", "webp", "avif"] do
  {ms, bytes} = run.(w, fm)
  IO.puts("| #{w} | #{fm} | #{:erlang.float_to_binary(ms, decimals: 0)} | #{bytes} |")
end

if function_exported?(VixBackend, :avif_ms_per_megapixel, 0) do
  cost = VixBackend.avif_ms_per_megapixel()
  IO.puts("\nAVIF cost on this node: #{inspect(cost)} ms per megapixel")

  for w <- [256, 640, 1200] do
    {:ok, plan} = Transform.parse(%{"w" => to_string(w), "q" => to_string(q), "auto" => "format"})

    fm =
      Transform.resolve(plan,
        accept: "image/avif,image/webp,*/*",
        source_size: {Image.width(info), Image.height(info)},
        source_mime: "image/jpeg",
        avif?: VixBackend.avif?(),
        avif_ms_per_megapixel: cost
      ).fm

    IO.puts("auto=format w=#{w}: #{fm}")
  end
end

File.rm_rf!(out_dir)
if generated?, do: File.rm!(src)
