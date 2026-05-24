defmodule Barkpark.Plugins.Media.Codelists do
  @moduledoc """
  Bundled codelists for the Media plugin (`media:asset_role`, `media:license`).
  """

  alias Barkpark.Content.Codelists

  @plugin "media"

  @doc "Idempotent seeder invoked at boot via `codelist_seeders/0`."
  @spec seed_all() :: :ok
  def seed_all do
    {:ok, _} =
      Codelists.register(@plugin, "media:asset_role", %{
        issue: "1",
        name: "Media asset role",
        values: [
          %{code: "cover", translations: [%{language: "eng", label: "Cover"}]},
          %{code: "hero", translations: [%{language: "eng", label: "Hero"}]},
          %{code: "thumbnail", translations: [%{language: "eng", label: "Thumbnail"}]},
          %{code: "sample", translations: [%{language: "eng", label: "Sample"}]},
          %{code: "attachment", translations: [%{language: "eng", label: "Attachment"}]},
          %{code: "logo", translations: [%{language: "eng", label: "Logo"}]}
        ]
      })

    {:ok, _} =
      Codelists.register(@plugin, "media:license", %{
        issue: "1",
        name: "Media license",
        values: [
          %{code: "all-rights-reserved", translations: [%{language: "eng", label: "All rights reserved"}]},
          %{code: "cc-by", translations: [%{language: "eng", label: "CC BY"}]},
          %{code: "cc-by-sa", translations: [%{language: "eng", label: "CC BY-SA"}]},
          %{code: "cc0", translations: [%{language: "eng", label: "CC0"}]},
          %{code: "editorial", translations: [%{language: "eng", label: "Editorial use only"}]}
        ]
      })

    {:ok, _} =
      Codelists.register(@plugin, "media:relation_type", %{
        issue: "1",
        name: "Media asset relation",
        values: [
          %{code: "variant", translations: [%{language: "eng", label: "Variant"}]},
          %{code: "parent", translations: [%{language: "eng", label: "Parent"}]},
          %{code: "child", translations: [%{language: "eng", label: "Child"}]},
          %{code: "source", translations: [%{language: "eng", label: "Source"}]},
          %{code: "derived", translations: [%{language: "eng", label: "Derived from"}]},
          %{code: "related", translations: [%{language: "eng", label: "Related"}]}
        ]
      })

    :ok
  end
end
