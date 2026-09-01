defmodule BarkparkWeb.Integration.V1MediaProcessingScopeAndBrickTest do
  @moduledoc """
  `task-51ee1a486ca8b9d4` — the external-processing callback door
  (`POST /v1/media/:dataset/processing/:id/callback`).

  Two independent defects, both proved here against the STORE rather than the
  response body, because the response is rendered from the very map the
  controller just built and would agree with itself either way.

  ## 1. The asset-doc read and the asset-doc WRITE carry no tenancy

  `V1.MediaProcessingController.callback/2` resolved the companion `mediaAsset`
  document with `Media.asset_doc_for_file(file, dataset)` and wrote it back with
  `Content.upsert_document(@asset_type, attrs, file.dataset, source: :api)` —
  neither threading the blob's own `{workspace_id, project_id}`.

  Unscoped, `Assets.scope_asset_dataset/3` resolves the `dataset` STRING inside
  the **seeded Default project** (`Tenancy.scope_project_id([])`), so for a blob
  living in any other workspace the lookup resolves a different `dataset_id`
  and returns nil → the callback 404s for every workspace-scoped asset. The
  write half is worse in the other direction: `WriteScope.put_scope_attrs/2`
  falls back to the Default workspace/project when opts carry no scope, so a
  write that DID resolve another tenant's doc would re-stamp it into Default —
  moving the row out of its own tenancy.

  The near-identical sibling write, `Media.patch_asset_metadata/3`
  (`media.ex:449-454`), already threads `Assets.file_scope_opts(file)`. So does
  the sibling READ at `v1/media_controller.ex:599`. This door was the odd one
  out; the fix is to match them.

  `Media.get_file/2` at the top of `callback/2` is deliberately NOT scoped and
  is not part of this fix: the pipeline is `:media_processing_callback`
  (`RequireMediaProcessingCallbackToken`, ONE instance-wide shared secret) on a
  FLAT route with no `/w/:ws/p/:proj` prefix, so the conn carries no tenant to
  clamp to. The blob id IS the tenant resolver here, exactly as it is for a
  webhook; `file_scope_opts(file)` then confines everything downstream to what
  that resolution produced.

  ## 2. A poisoned metadata key permanently 500s the callback for that asset

  `maybe_merge_metadata/2` merged the caller's `params["metadata"]` LAST and
  accepted any binary key with a non-nil value — including the two control keys
  the controller itself owns. One callback carrying
  `metadata: %{"bp_external_processing" => "x"}` persisted that STRING into the
  jsonb content. Every SUBSEQUENT callback for the same blob then evaluated

      ("x" || %{}) |> Map.put("provider", ...)

  which raises `BadMapError` → 500, forever, for that asset. Two halves are
  needed: the merge must not be able to overwrite the control keys (so it
  cannot happen again), and the read of the stored value must tolerate a
  non-map (so an ALREADY-poisoned row heals instead of staying bricked).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @ds "production"
  @asset_type "mediaAsset"

  defp callback_conn,
    do:
      put_req_header(
        build_conn(),
        "authorization",
        "Bearer test-media-processing-callback-token"
      )

  # A workspace + project + a `production` dataset, a blob stamped into it, and
  # the companion asset doc created through the SAME helper the upload path uses
  # (`Assets.ensure_for_upload/1` → `create_draft/1` → `file_scope_opts/1`), so
  # the doc carries this tenant's workspace_id/project_id/dataset_id exactly as
  # a real upload would.
  defp tenant(label) do
    ws = create_workspace!("mpcb-ws-#{label}-#{System.unique_integer([:positive])}")
    project = create_project!(ws, "mpcb-pr-#{label}-#{System.unique_integer([:positive])}")
    {:ok, dataset} = Tenancy.create_dataset(project, %{slug: @ds, name: @ds})
    {:ok, file} = create_media_file_in!(ws, project, %{}, @ds)
    {:ok, doc} = Assets.ensure_for_upload(file)

    %{ws: ws, project: project, dataset: dataset, file: file, doc: doc}
  end

  # The SEEDED Default workspace/project — the only tenancy the unscoped doc
  # lookup on today's `main` can resolve. The brick tests below use it
  # deliberately: on unmodified `main` a workspace-scoped blob 404s at the doc
  # lookup and never reaches `patch_callback/4` at all, so a brick test built on
  # one would red for the WRONG reason and go green the moment the scoping half
  # landed. Anchored here, the brick reds as a 500 with the scoping untouched.
  defp default_tenant do
    ws = Tenancy.get_default_workspace()
    project = Tenancy.get_default_project()
    dataset = Tenancy.get_dataset(project, @ds)
    {:ok, file} = create_media_file_in!(ws, project, %{}, @ds)
    {:ok, doc} = Assets.ensure_for_upload(file)

    %{ws: ws, project: project, dataset: dataset, file: file, doc: doc}
  end

  defp scope(t), do: [workspace_id: t.ws.id, project_id: t.project.id]

  # Read the asset doc back THROUGH the tenant's own scope — the store, not the
  # response. A fix that only made the response look right would not move this.
  defp stored(t), do: Assets.find_by_media_file_id(t.file.id, @ds, scope(t))

  defp post_callback(t, params) do
    post(callback_conn(), "/v1/media/#{@ds}/processing/#{t.file.id}/callback", params)
  end

  setup do
    ensure_default_scope!()
    default_project = Tenancy.get_default_project()

    # The unscoped resolver reads the DEFAULT project — give it a `production`
    # dataset to resolve so the RED below is the tenancy gap and not merely a
    # missing dataset row.
    unless Tenancy.get_dataset(default_project, @ds) do
      {:ok, _} = Tenancy.create_dataset(default_project, %{slug: @ds, name: @ds})
    end

    :ok
  end

  describe "the callback is confined to the blob's own tenancy" do
    test "a callback for a workspace-scoped blob updates THAT workspace's asset doc" do
      t = tenant("a")

      resp = post_callback(t, %{"status" => "processing", "provider" => "transcoder"})

      assert resp.status == 200,
             "the callback 404s for every workspace-scoped asset: the doc lookup " <>
               "resolves the dataset STRING in the DEFAULT project (got #{resp.status})"

      doc = stored(t)

      assert doc, "no mediaAsset doc is visible under the blob's own workspace scope"
      assert doc.content["bp_processing_status"] == "processing"
      assert doc.content["bp_external_processing"]["provider"] == "transcoder"
    end

    test "the write-back keeps the asset doc in its own workspace/project/dataset" do
      t = tenant("b")

      assert post_callback(t, %{"status" => "processing"}).status == 200

      row = Repo.get_by(Content.Document, doc_id: t.doc.doc_id, type: @asset_type)

      assert row, "the asset doc row vanished"

      # The discriminator for the WRITE half specifically: an unscoped
      # upsert_document/4 resolves the Default workspace/project and re-stamps
      # the row into it.
      assert row.workspace_id == t.ws.id,
             "the callback re-homed the asset doc into another workspace"

      assert row.project_id == t.project.id,
             "the callback re-homed the asset doc into another project"

      assert row.dataset_id == t.dataset.id,
             "the callback re-homed the asset doc into another dataset"
    end

    test "a callback for tenant A's blob does not touch tenant B's asset doc" do
      a = tenant("x")
      b = tenant("y")

      # Snapshot B BEFORE, and compare after. Asserting a literal value here
      # would measure the FIXTURE, not the leak: `Assets.create_draft/1` stamps
      # `bp_processing_status: "processing"` at birth for any `image/*` blob, so
      # `refute b.content["bp_processing_status"] == "processing"` fails on a
      # perfectly confined callback. The unchanged-snapshot form cannot go
      # vacuous that way.
      b_before = stored(b)

      assert post_callback(a, %{"status" => "ready", "provider" => "a-proc"}).status == 200

      a_doc = stored(a)
      b_after = stored(b)

      assert a_doc.content["bp_processing_status"] == "ready"
      assert a_doc.content["bp_external_processing"]["provider"] == "a-proc"

      assert b_after.content == b_before.content,
             "tenant B's asset doc content moved on a callback addressed to tenant A's blob"

      assert b_after.rev == b_before.rev,
             "tenant B's asset doc was re-written on a callback addressed to tenant A's blob"

      refute get_in(b_after.content, ["bp_external_processing", "provider"]) == "a-proc",
             "tenant B's asset doc grew tenant A's processing record"
    end
  end

  describe "a malformed or replayed callback cannot brick the asset" do
    test "metadata cannot overwrite the control keys the controller owns" do
      t = default_tenant()

      assert post_callback(t, %{
               "status" => "ready",
               "provider" => "transcoder",
               "metadata" => %{
                 "bp_external_processing" => "x",
                 "bp_processing_status" => "totally-bogus"
               }
             }).status == 200

      doc = stored(t)

      assert is_map(doc.content["bp_external_processing"]),
             "caller metadata overwrote bp_external_processing with " <>
               inspect(doc.content["bp_external_processing"])

      assert doc.content["bp_external_processing"]["provider"] == "transcoder"

      assert doc.content["bp_processing_status"] == "ready",
             "caller metadata overwrote the controller-owned processing status"
    end

    test "a second callback after a poison attempt still succeeds (no permanent brick)" do
      t = default_tenant()

      assert post_callback(t, %{
               "status" => "processing",
               "metadata" => %{"bp_external_processing" => "x"}
             }).status == 200

      second = post_callback(t, %{"status" => "ready", "provider" => "transcoder"})

      assert second.status == 200,
             "the callback path for this asset is bricked: a replayed callback got " <>
               "#{second.status} (BadMapError on Map.put/3 over the poisoned string)"

      assert stored(t).content["bp_processing_status"] == "ready"
    end

    test "an ALREADY-poisoned asset doc heals instead of staying stranded" do
      t = default_tenant()

      # Simulate a row poisoned before the fix shipped: bp_external_processing
      # is a bare string in the persisted jsonb.
      {:ok, _} =
        Content.upsert_document(
          @asset_type,
          %{
            "doc_id" => t.doc.doc_id,
            "title" => t.doc.title,
            "status" => t.doc.status,
            "content" => Map.put(t.doc.content, "bp_external_processing", "x")
          },
          @ds,
          [source: :api] ++ scope(t)
        )

      assert stored(t).content["bp_external_processing"] == "x",
             "the poison fixture did not persist — this test would be vacuous"

      resp = post_callback(t, %{"status" => "ready", "provider" => "transcoder"})

      assert resp.status == 200,
             "an asset poisoned before the fix is permanently stranded (got #{resp.status})"

      healed = stored(t).content["bp_external_processing"]

      assert is_map(healed), "expected the poisoned value to be replaced, got #{inspect(healed)}"
      assert healed["provider"] == "transcoder"
    end

    test "positive control: ordinary metadata keys still merge" do
      t = default_tenant()

      assert post_callback(t, %{
               "status" => "ready",
               "provider" => "transcoder",
               "metadata" => %{"altText" => "a pixel", "durationMs" => 1234, "skipped" => nil}
             }).status == 200

      content = stored(t).content

      assert content["altText"] == "a pixel"
      assert content["durationMs"] == 1234
      refute Map.has_key?(content, "skipped")
      assert content["bp_processing_status"] == "ready"
    end
  end
end
