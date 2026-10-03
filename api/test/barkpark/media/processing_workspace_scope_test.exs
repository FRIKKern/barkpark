defmodule Barkpark.Media.ProcessingWorkspaceScopeTest do
  @moduledoc """
  task-b9bca4e256a79387: media uploaded in a NON-Default workspace never left
  `processing`.

  `Media.Processing.process/1`, the idempotency lookup in
  `Assets.ensure_for_upload/1` and `Checkout`'s read all called
  `Assets.find_by_media_file_id(file.id, dataset)` with NO scope. Unscoped,
  `Assets.scope_asset_dataset/3` resolves the dataset STRING inside the seeded
  Default project, so for a blob in any other workspace — whose asset doc
  carries THAT workspace's `dataset_id` — the lookup returned nil:

    * processing did nothing, so the asset sat at `processing` forever (no
      dimensions, no renditions, no ready/failed event);
    * a second `ensure_for_upload/1` could not see the first doc;
    * checkout / undo answered `:not_found`.

  The writes on the same paths already threaded `MediaFile.scope_opts(file)`;
  the reads now match. The Default-workspace control is green before and after.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.Media.Processing
  alias Barkpark.Media.Storage.{Checkout, MediaFile}
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @ds "production"

  setup do
    ensure_default_scope!()
    default_project = Tenancy.get_default_project()

    # The unscoped resolver reads the DEFAULT project; give it a `production`
    # dataset (as every real instance has) so the RED is the tenancy gap, not a
    # missing dataset row falling back to the string filter.
    unless Tenancy.get_dataset(default_project, @ds) do
      {:ok, _} = Tenancy.create_dataset(default_project, %{slug: @ds, name: @ds})
    end

    :ok
  end

  defp upload_in(ws, project) do
    {:ok, file} = create_media_file_in!(ws, project, %{mime_type: "image/png"}, @ds)
    {:ok, doc} = Assets.ensure_for_upload(file)
    {file, doc}
  end

  defp tenant do
    ws = create_workspace!("mpws-#{System.unique_integer([:positive])}")
    project = create_project!(ws, "mpws-p-#{System.unique_integer([:positive])}")
    {:ok, _} = Tenancy.create_dataset(project, %{slug: @ds, name: @ds})
    {ws, project}
  end

  defp status(doc_pk), do: Repo.get!(Document, doc_pk).content["bp_processing_status"]

  defp asset_docs_for(file) do
    Repo.aggregate(
      from(d in Document,
        where: d.type == "mediaAsset",
        where: fragment("?->>'mediaFileId' = ?", d.content, ^file.id)
      ),
      :count
    )
  end

  describe "a blob in a non-Default workspace" do
    test "processing moves its asset doc out of `processing`" do
      {ws, project} = tenant()
      {file, doc} = upload_in(ws, project)
      assert doc.workspace_id == ws.id
      assert status(doc.id) == "processing"

      :ok = Processing.process(file)

      refute status(doc.id) == "processing",
             "the pipeline never found this workspace's asset doc — it is stuck at processing"
    end

    test "a second ensure_for_upload/1 returns the SAME asset doc" do
      {ws, project} = tenant()
      {file, doc} = upload_in(ws, project)

      assert {:ok, again} = Assets.ensure_for_upload(file)
      assert again.id == doc.id
      assert asset_docs_for(file) == 1
    end

    test "checkout resolves the asset doc instead of answering not_found" do
      {ws, project} = tenant()
      {file, _doc} = upload_in(ws, project)

      assert {:ok, %Document{} = locked} = Checkout.checkout(file, "editor-1", @ds)
      assert locked.content["checkedOutBy"] == "editor-1"
      assert locked.workspace_id == ws.id
    end
  end

  test "CONTROL: a Default-workspace blob processes as before" do
    ws = Tenancy.get_default_workspace()
    project = Tenancy.get_default_project()
    {file, doc} = upload_in(ws, project)
    assert MediaFile.scope_opts(file)[:workspace_id] == ws.id

    :ok = Processing.process(file)
    refute status(doc.id) == "processing"
  end
end
