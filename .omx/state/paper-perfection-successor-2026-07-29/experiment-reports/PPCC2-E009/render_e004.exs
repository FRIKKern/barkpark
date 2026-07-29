defmodule PPCC2E009.RenderE004 do
  alias Barkpark.PortableDoc.Render

  def run([manifest_path, output_dir]) do
    File.mkdir_p!(output_dir)

    results =
      manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(fn %{"key" => key, "candidate_path" => candidate_path} ->
        try do
          blocks =
            candidate_path
            |> File.read!()
            |> Jason.decode!()
            |> Map.fetch!("blocks")

          studio = Render.render_blocks(blocks, %{style: :article})
          email = Render.render_document(blocks, %{style: :email})
          studio_path = Path.join(output_dir, "#{key}.studio.html")
          email_path = Path.join(output_dir, "#{key}.email.html")
          File.write!(studio_path, studio)
          File.write!(email_path, email)

          %{
            "key" => key,
            "status" => "rendered",
            "studio_path" => studio_path,
            "email_path" => email_path
          }
        rescue
          error ->
            %{
              "key" => key,
              "status" => "rejected",
              "error_type" => inspect(error.__struct__),
              "error" => Exception.message(error)
            }
        end
      end)

    File.write!(
      Path.join(output_dir, "render-results.json"),
      Jason.encode!(results, pretty: true) <> "\n"
    )
  end

  def run(_args) do
    IO.puts(:stderr, "usage: render_e004.exs <manifest.json> <output-dir>")
    System.halt(2)
  end
end

PPCC2E009.RenderE004.run(System.argv())
