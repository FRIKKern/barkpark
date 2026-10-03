defmodule Barkpark.Seeds.DemoSeedReferencesResolveTest do
  @moduledoc """
  Every reference the demo seed stores must point at a document the seed
  also stores. Found dogfooding a fresh `mix ecto.setup`: the nine seeded
  posts carried `author: "Knut Melvaer"` — the author's NAME — while the
  `author` field is a reference to `author`, whose documents are `a1`–`a3`.
  Studio showed a dangling author chip on every post (the preview fetch
  404'd on `/author/Knut%20Melvaer`), and `?expand=author` and backlinks
  found nothing.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Repo

  import Ecto.Query

  setup do
    ExUnit.CaptureIO.capture_io(fn ->
      scope = Barkpark.Seeds.Shared.ensure_default_scope()
      Barkpark.Seeds.Demo.seed(scope)
    end)

    :ok
  end

  test "every stored reference value names a seeded document of the referenced type" do
    ref_fields =
      for %SchemaDefinition{name: type, fields: fields} <- Repo.all(SchemaDefinition),
          is_list(fields),
          %{"type" => "reference", "name" => name, "refType" => ref_type} <- fields,
          do: {type, name, ref_type}

    assert {"post", "author", "author"} in ref_fields

    dangling =
      for {type, field, ref_type} <- Enum.uniq(ref_fields),
          %Document{doc_id: id, content: content} <-
            Repo.all(from d in Document, where: d.type == ^type),
          value = (content || %{})[field],
          is_binary(value) and value != "",
          not Repo.exists?(
            from d in Document,
              where: d.type == ^ref_type and d.doc_id in [^value, ^("drafts." <> value)]
          ),
          do: "#{type}/#{id}.#{field} = #{inspect(value)} (no #{ref_type} with that id)"

    assert dangling == []
  end
end
