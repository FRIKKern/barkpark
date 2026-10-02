defmodule Barkpark.PortableDoc.ProjectionMediaScopeTest do
  @moduledoc """
  The content>preview INVERSION SEAM (task-1e93b1d801ff4696, edge 1).

  `Barkpark.Content.Writer` and `Barkpark.Content.Papers.BlockOps` used to call
  `Barkpark.Preview.media_resolver/1` directly — a kernel→feature boundary edge
  whose whole content was "bind this scope". They now declare only the scope
  (`preview: %{media_scope: scope}`) and `PortableDoc.Projection` — which
  already owns the `Preview.project/3` call — binds the closure.

  Four arms, because a seam is only as good as what it still guarantees:

    1. BINDING — a `:media_scope` alone resolves a real scoped media file to its
       `og` rendition. Deleting `bind_media_resolver/1`'s scope clause reds only
       this arm (the resolver goes missing and the image degrades to nil).
    2. TENANCY — the bound closure is scoped: another workspace's media path
       resolves to nil, exactly as the pre-seam closure did.
    3. PRECEDENCE — an explicit `:media_resolver` still WINS (mix backfill, test
       stubs) and `:media_scope` never leaks into `Preview.project/3`'s opts.
    4. NO EDGE — the kernel source carries no compile-time reference to
       `Preview.media_resolver`, so the edge cannot silently come back.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.PortableDoc.Projection
  alias Barkpark.Preview
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @media_path "2026/09/seam-card.png"

  setup do
    slug = "seam-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, project} = Tenancy.create_project(ws, %{slug: slug <> "-p", name: slug})
    {:ok, dataset} = Tenancy.get_or_create_dataset(project.id, "production")

    media_file =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: "seam-card.png",
        original_name: "seam-card.png",
        path: @media_path,
        mime_type: "image/png",
        size: 16,
        dataset: "production",
        workspace_id: ws.id,
        project_id: project.id,
        dataset_id: dataset.id
      })
      |> Repo.insert!()

    %{ws: ws, project: project, media_file: media_file}
  end

  defp blocks do
    [
      %{"id" => "h", "type" => "heading", "level" => 1, "role" => "title", "text" => "Seam"},
      %{
        "id" => "f",
        "type" => "image",
        "role" => "featured",
        "src" => "/media/files/" <> @media_path,
        "alt" => "Card art"
      }
    ]
  end

  defp project_with(preview_opts) do
    b = blocks()
    Projection.project(%{}, b, b, %{preview: preview_opts})["preview"]
  end

  describe "the :media_scope seam" do
    test "a scope ALONE binds the resolver and resolves the og rendition", ctx do
      scope = [workspace_id: ctx.ws.id, project_id: ctx.project.id]

      preview = project_with(%{media_scope: scope, url: "/papers/seam", doc_type: "paper"})

      assert preview["image"]["url"] == "/media/renditions/#{ctx.media_file.id}/og"
      assert preview["image"]["width"] == 1200
      assert preview["image"]["height"] == 630
      assert preview["image"]["alt"] == "Card art"
      assert preview["url"] == "/papers/seam"
      assert preview["type"] == "paper"
    end

    test "the scope binding equals what the kernel used to build by hand", ctx do
      scope = [workspace_id: ctx.ws.id, project_id: ctx.project.id]

      seam = project_with(%{media_scope: scope, url: "/papers/seam", doc_type: "paper"})

      pre_seam =
        project_with(%{
          media_resolver: Preview.media_resolver(scope),
          url: "/papers/seam",
          doc_type: "paper"
        })

      assert seam == pre_seam
    end

    test "the bound closure is TENANCY-scoped — a foreign scope resolves nil" do
      {:ok, other} =
        Tenancy.create_workspace(%{
          slug: "seam-other-#{System.unique_integer([:positive])}",
          name: "other"
        })

      preview = project_with(%{media_scope: [workspace_id: other.id], doc_type: "paper"})

      assert preview["image"] == nil
      assert preview["title"] == "Seam"
    end

    test "an explicit :media_resolver WINS and :media_scope never leaks", ctx do
      stub = fn "/media/files/" <> _ ->
        %{"url" => "/stub/og", "width" => 1200, "height" => 630, "type" => "image/jpeg"}
      end

      preview =
        project_with(%{
          media_resolver: stub,
          media_scope: [workspace_id: ctx.ws.id],
          doc_type: "paper"
        })

      # The stub ran (not the scope-bound closure), and nothing choked on the
      # extra key — `Preview.project/3` never sees :media_scope.
      assert preview["image"]["url"] == "/stub/og"
    end

    test "neither key still degrades a media image to nil" do
      preview = project_with(%{doc_type: "paper"})
      assert preview["image"] == nil
    end
  end

  describe "the content>preview boundary edge stays retired" do
    @kernel_files [
      "lib/barkpark/content/writer.ex",
      "lib/barkpark/content/papers/block_ops.ex"
    ]

    test "no kernel file carries a compile-time Preview.media_resolver call" do
      for rel <- @kernel_files do
        src = File.read!(Path.join(File.cwd!(), rel))

        refute src =~ "Preview.media_resolver(",
               "#{rel} calls Preview.media_resolver/1 again — the content>preview " <>
                 "kernel→feature edge is back. Declare `media_scope:` instead; " <>
                 "PortableDoc.Projection.bind_media_resolver/1 binds the closure."

        refute src =~ "alias Barkpark.Preview\n",
               "#{rel} aliases Barkpark.Preview again (content>preview edge)."
      end
    end
  end
end
