alias Barkpark.StudioChat.StreamSegments
drive = fn text, chunk ->
  s = StreamSegments.new(1)
  {s, frames, _t} =
    text
    |> String.graphemes()
    |> Enum.chunk_every(chunk)
    |> Enum.map(&Enum.join/1)
    |> Enum.reduce({s, [], 0}, fn d, {s, acc, t} ->
      {s, f} = StreamSegments.advance(s, d, t)
      {s, acc ++ f, t + 100}
    end)
  {_s, f2} = StreamSegments.settle(s, text)
  frames ++ f2
end
one_para = "A headless CMS is a content management system that stores content but has no front end. It exposes content through an API instead."
multi = "First paragraph about the thing.\n\nSecond paragraph continues the thought.\n\nThird paragraph lands the point.\n\nFourth and final paragraph.\n"
numbers = Enum.map_join(1..40, "\n", &("line #{&1}"))
for {label, txt} <- [{"ONE PARAGRAPH", one_para}, {"BLANK-LINE MULTI", multi}, {"ONE PER LINE, NO BLANKS", numbers}] do
  fr = drive.(txt, 20)
  IO.puts("\n== #{label} == frames=#{length(fr)}")
  for f <- fr do
    case f do
      {:stable, p} -> IO.puts("  stable turn=#{p.turn} from=#{p.from} to=#{p.to} blocks=#{length(p.blocks)}")
      {:stable_end, p} -> IO.puts("  stable_end turn=#{p.turn} from=#{p.from} reason=#{p.reason}")
    end
  end
end
