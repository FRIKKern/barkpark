args = Enum.reject(System.argv(), &(&1 == "--"))
[style_name, input] = args

style =
  case style_name do
    "studio" -> :article
    "email" -> :email
    other -> raise ArgumentError, "unknown exact render surface: #{other}"
  end

candidate = input |> File.read!() |> Jason.decode!()
html = Barkpark.PortableDoc.Render.render_document(candidate["blocks"], %{style: style})
IO.binwrite(html)
