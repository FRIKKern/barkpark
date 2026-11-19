defmodule Barkpark.Content.StrengthenOnPublishTest do
  @moduledoc """
  task-3fa8b7a435a9ed83 — a reference picked before its target was published
  waits as `{_ref, _weak: true, _strengthenOnPublish: {...}}`. Every publish
  the server runs (scheduled, the mutate `publish` action, the direct
  publish) turns it strong once the target has a published version in the
  same dataset and tenant, as Sanity Studio's publish does. A target with no
  published version, and a weak reference the author chose, stay as they are.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}
  alias Barkpark.Content.{CallerContext, ScheduledPublishes}

  @ds "production"
  @author "sop_author"
  @post "sop_post"

  setup do
    {ws, _project} = TenancyFixtures.ensure_default_scope!()
    opts = [workspace_id: ws.id]
    put_schemas!(opts)

    publish_author!("ann", opts)
    publish_author!("bea", opts)
    {:ok, _} = Content.create_document(@author, %{"doc_id" => "cid", "title" => "cid"}, @ds, opts)

    %{opts: opts, ws: ws}
  end

  defp put_schemas!(opts) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @author, "title" => "Author", "visibility" => "public", "fields" => []},
        @ds,
        opts
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @post,
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "editor", "type" => "reference", "to" => [%{"type" => @author}]},
            %{
              "name" => "credits",
              "type" => "array",
              "of" => [%{"type" => "reference", "to" => [%{"type" => @author}]}]
            },
            %{
              "name" => "seo",
              "type" => "object",
              "fields" => [
                %{"name" => "by", "type" => "reference", "to" => [%{"type" => @author}]}
              ]
            }
          ]
        },
        @ds,
        opts
      )
  end

  defp publish_author!(id, opts) do
    {:ok, _} = Content.create_document(@author, %{"doc_id" => id, "title" => id}, @ds, opts)
    {:ok, _} = Content.publish_document(id, @author, @ds, opts)
  end

  defp waiting(id),
    do: %{
      "_type" => "reference",
      "_ref" => id,
      "_weak" => true,
      "_strengthenOnPublish" => %{"type" => @author}
    }

  defp strong(id), do: %{"_type" => "reference", "_ref" => id}

  defp draft!(id, content, opts) do
    {:ok, _} =
      Content.create_document(
        @post,
        %{"doc_id" => id, "title" => id, "content" => content},
        @ds,
        opts
      )
  end

  defp published_content(id, opts) do
    {:ok, doc} = Content.get_document(id, @post, @ds, opts)
    assert doc.status == "published"
    doc.content
  end

  describe "every publish door strengthens a waiting reference to a published target" do
    test "a scheduled publish", %{opts: opts, ws: ws} do
      draft!("sop-sched", %{"editor" => waiting("ann")}, opts)

      raw = "sop-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "sop", @ds, ["read", "write"], ws.id)
      ctx = CallerContext.from_token(token, workspace_id: ws.id)
      at = DateTime.add(DateTime.utc_now(), 3600)

      {:ok, row} =
        ScheduledPublishes.schedule(@post, "sop-sched", @ds, at,
          caller_context: ctx,
          workspace_id: ws.id
        )

      assert {:ok, %{status: "published"}} = ScheduledPublishes.run(row.id)
      assert published_content("sop-sched", opts)["editor"] == strong("ann")
    end

    test "the mutate publish action", %{opts: opts} do
      draft!("sop-mutate", %{"editor" => waiting("ann")}, opts)

      assert {:ok, _} =
               Content.apply_mutations(
                 [%{"publish" => %{"id" => "sop-mutate", "type" => @post}}],
                 @ds,
                 opts
               )

      assert published_content("sop-mutate", opts)["editor"] == strong("ann")
    end

    test "the direct publish", %{opts: opts} do
      direct = %{
        "createOrReplace" => %{
          "_id" => "sop-direct",
          "_type" => @post,
          "title" => "sop-direct",
          "editor" => waiting("ann")
        },
        "publish" => true
      }

      assert {:ok, _} = Content.apply_mutations([direct], @ds, opts)
      assert published_content("sop-direct", opts)["editor"] == strong("ann")
    end
  end

  test "a target with only a draft leaves the reference waiting", %{opts: opts} do
    draft!("sop-unpub", %{"editor" => waiting("cid")}, opts)
    {:ok, _} = Content.publish_document("sop-unpub", @post, @ds, opts)

    assert published_content("sop-unpub", opts)["editor"] == waiting("cid")
  end

  test "a published target of another type than the marker names leaves it waiting",
       %{opts: opts} do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "sop_other", "title" => "Other", "visibility" => "public", "fields" => []},
        @ds,
        opts
      )

    {:ok, _} =
      Content.create_document("sop_other", %{"doc_id" => "pat", "title" => "pat"}, @ds, opts)

    {:ok, _} = Content.publish_document("pat", "sop_other", @ds, opts)

    draft!("sop-wrong-type", %{"editor" => waiting("pat")}, opts)
    {:ok, _} = Content.publish_document("sop-wrong-type", @post, @ds, opts)

    assert published_content("sop-wrong-type", opts)["editor"] == waiting("pat")
  end

  test "a marker with weak: true goes on publish and the reference stays weak",
       %{opts: opts} do
    declared = fn id -> put_in(waiting(id), ["_strengthenOnPublish", "weak"], true) end

    draft!(
      "sop-declared-weak",
      %{"editor" => declared.("ann"), "seo" => %{"by" => declared.("cid")}},
      opts
    )

    {:ok, _} = Content.publish_document("sop-declared-weak", @post, @ds, opts)
    content = published_content("sop-declared-weak", opts)

    # Published target and draft-only target alike.
    assert content["editor"] == Map.put(strong("ann"), "_weak", true)
    assert content["seo"]["by"] == Map.put(strong("cid"), "_weak", true)
  end

  test "a weak reference without _strengthenOnPublish stays weak", %{opts: opts} do
    chosen = %{"_type" => "reference", "_ref" => "ann", "_weak" => true}
    draft!("sop-chosen", %{"editor" => chosen}, opts)
    {:ok, _} = Content.publish_document("sop-chosen", @post, @ds, opts)

    assert published_content("sop-chosen", opts)["editor"] == chosen
  end

  test "nested in an array of references and in an object", %{opts: opts} do
    draft!(
      "sop-nested",
      %{
        "credits" => [
          Map.put(waiting("ann"), "_key", "k1"),
          Map.put(waiting("cid"), "_key", "k2"),
          Map.put(waiting("bea"), "_key", "k3")
        ],
        "seo" => %{"by" => waiting("bea")}
      },
      opts
    )

    {:ok, _} = Content.publish_document("sop-nested", @post, @ds, opts)
    content = published_content("sop-nested", opts)

    assert content["credits"] == [
             Map.put(strong("ann"), "_key", "k1"),
             Map.put(waiting("cid"), "_key", "k2"),
             Map.put(strong("bea"), "_key", "k3")
           ]

    assert content["seo"] == %{"by" => strong("bea")}
  end

  test "a publish whose scope names no workspace strengthens nothing", %{opts: opts} do
    draft!("sop-noscope", %{"editor" => waiting("ann")}, opts)
    {:ok, _} = Content.publish_document("sop-noscope", @post, @ds, [])

    assert published_content("sop-noscope", opts)["editor"] == waiting("ann")
  end

  test "a published target with the same id in another workspace does not count",
       %{opts: opts} do
    other_ws = TenancyFixtures.create_workspace!()
    other_project = TenancyFixtures.create_project!(other_ws)
    other = [workspace_id: other_ws.id, project_id: other_project.id]
    put_schemas!(other)
    publish_author!("elsewhere", other)

    draft!("sop-tenant", %{"editor" => waiting("elsewhere")}, opts)
    {:ok, _} = Content.publish_document("sop-tenant", @post, @ds, opts)
    assert published_content("sop-tenant", opts)["editor"] == waiting("elsewhere")

    # In its own workspace the same target does strengthen.
    draft!("sop-tenant-own", %{"editor" => waiting("elsewhere")}, other)
    {:ok, _} = Content.publish_document("sop-tenant-own", @post, @ds, other)
    assert published_content("sop-tenant-own", other)["editor"] == strong("elsewhere")
  end
end
