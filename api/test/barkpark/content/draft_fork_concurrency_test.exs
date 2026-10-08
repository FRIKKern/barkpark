defmodule Barkpark.Content.DraftForkConcurrencyTest do
  @moduledoc """
  task-324b4d00706a6cfb — concurrent FIRST patches to a PUBLISHED doc (no
  `drafts.<id>` row yet) all fork the draft and all land, instead of all but
  one 422ing on `documents_doc_id_type_dataset_id_index`.

  Exercises `Content.upsert_draft/6` — Studio's autosave path
  (`studio_live/shared.ex:521`), which merges each save onto a freshly-read
  `current` doc and retries on `rev_mismatch`, but (before this fix) NOT on
  the draft-fork unique-constraint error: two editors typing into different
  fields of a never-yet-drafted published doc at about the same moment both
  read `current` as the PUBLISHED row (no draft exists), both merge their one
  field onto it, and both attempt the INSERT. One wins; the other's insert
  409s on `doc_id` and was surfaced as a 422 instead of being retried.

  (The SDK `/v1/data/mutate` `"patch"` op is NOT this path — it already
  serializes per-document via `lock_patch_target`'s transaction-scoped
  advisory lock in `mutations.ex`, taken before its own read.)
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.Document
  alias Ecto.Adapters.SQL.Sandbox

  @dataset "production"
  @type_name "draft_fork_race_post"

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    ws = Barkpark.TenancyFixtures.default_workspace_id!()
    id = "draft-fork-race-#{System.unique_integer([:positive])}"

    fields = for n <- 1..20, do: "field#{n}"

    schema = %{
      "name" => @type_name,
      "title" => "Draft fork race post",
      "fields" => Enum.map(fields, &%{"name" => &1, "type" => "string"})
    }

    {:ok, _} = Content.upsert_schema(schema, @dataset, workspace_id: ws)
    {:ok, schema} = Content.get_schema(@type_name, @dataset, workspace_id: ws)

    {:ok, _draft} =
      Content.create_document(@type_name, %{"doc_id" => id, "title" => "race"}, @dataset,
        workspace_id: ws
      )

    {:ok, _published} = Content.publish_document(id, @type_name, @dataset, workspace_id: ws)

    # Precondition: the published doc exists and its draft does not — the
    # exact shape the race needs (a control, not an assumption).
    assert {:ok, %Document{status: "published"}} =
             Content.get_document(id, @type_name, @dataset, workspace_id: ws)

    assert {:error, :not_found} =
             Content.get_document("drafts." <> id, @type_name, @dataset, workspace_id: ws)

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from(d in Document, where: d.doc_id in ^[id, "drafts." <> id]))
      Content.delete_schema(@type_name, @dataset)
    end)

    {:ok, id: id, ws: ws, fields: fields, schema: schema}
  end

  test "20 parallel first patches (different fields) to one published doc all return ok and all fields land on the draft",
       %{id: id, ws: ws, fields: fields, schema: schema} do
    {:ok, published} = Content.get_document(id, @type_name, @dataset, workspace_id: ws)

    tasks =
      for field <- fields do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          Content.upsert_draft(
            published,
            @type_name,
            schema,
            %{field => "from #{field}"},
            @dataset,
            workspace_id: ws
          )
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 20_000))

    for {field, result} <- Enum.zip(fields, results) do
      assert match?({:ok, %Document{}, _validation_errors}, result),
             "#{field} did not land: #{inspect(result)}"
    end

    {:ok, draft} = Content.get_document("drafts." <> id, @type_name, @dataset, workspace_id: ws)

    for field <- fields do
      assert draft.content[field] == "from #{field}", "#{field} missing from the draft"
    end
  end
end
