defmodule PPCC2E004.RenderCandidates do
  alias Barkpark.PortableDoc.Render

  def run([manifest_path, output_dir]) do
    File.mkdir_p!(output_dir)

    manifest_path
    |> File.read!()
    |> Jason.decode!()
    |> Enum.each(fn %{"slug" => slug, "candidate_path" => candidate_path} ->
      blocks =
        candidate_path
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("blocks")

      article = Render.render_blocks(blocks, %{style: :article})
      email = Render.render_document(blocks, %{style: :email})

      File.write!(Path.join(output_dir, "#{slug}.studio.html"), article)
      File.write!(Path.join(output_dir, "#{slug}.studio.second.html"), article)
      File.write!(Path.join(output_dir, "#{slug}.email.html"), email)
      File.write!(Path.join(output_dir, "#{slug}.email.second.html"), email)
    end)
  end

  def run(_args) do
    IO.puts(
      :stderr,
      "usage: mix run --no-start render_candidates.exs <manifest.json> <output-dir>"
    )

    System.halt(2)
  end
end

PPCC2E004.RenderCandidates.run(System.argv())