defmodule Barkpark.Tenancy.DatasetDeleteTest do
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{AccountsFixtures, Content, Repo, Tenancy, UserPrefs}
  alias Barkpark.Content.{Document, MutationEvent, Revision, SchemaDefinition}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Tenancy.{Dataset, DatasetDelete}

  setup do
    ws = create_workspace!()
    project = create_project!(ws)
    other_ws = create_workspace!()
    other_project = create_project!(other_ws)

    user =
      AccountsFixtures.register_user(
        "ds-delete-#{System.unique_integer([:positive])}@example.com"
      )

    %{ws: ws, project: project, other_ws: other_ws, other_project: other_project, user: user}
  end

  defp seed(ws, project, slug, user) do
    opts = [workspace_id: ws.id, project_id: project.id]
    {:ok, _} = Content.upsert_schema(%{"name" => "post", "title" => "Post"}, slug, opts)
    {:ok, draft} = Content.create_document("post", %{"title" => "one"}, slug, opts)
    {:ok, _} = Content.publish_document(draft.doc_id, "post", slug, opts)
    {:ok, _} = Content.create_document("post", %{"title" => "two"}, slug, opts)
    {:ok, _} = create_media_file_in!(ws, project, %{}, slug)
    {:ok, _} = UserPrefs.put(user.id, ws.id, slug, "desk", %{"open" => true})

    Repo.insert_all("scheduled_publishes", [
      %{
        id: Ecto.UUID.bingenerate(),
        workspace_id: Ecto.UUID.dump!(ws.id),
        project_id: Ecto.UUID.dump!(project.id),
        dataset: slug,
        type: "post",
        doc_id: "later-#{project.slug}",
        publish_at: ~N[2030-01-01 00:00:00],
        principal_type: "user",
        principal_id: Ecto.UUID.dump!(user.id),
        inserted_at: NaiveDateTime.utc_now(),
        updated_at: NaiveDateTime.utc_now()
      }
    ])

    Tenancy.get_dataset(project, slug)
  end

  defp census(%Dataset{id: id, slug: slug}, ws) do
    %{
      documents: count(from d in Document, where: d.dataset_id == ^id),
      revisions: count(from r in Revision, where: r.dataset_id == ^id),
      schemas: count(from s in SchemaDefinition, where: s.dataset_id == ^id),
      events: count(from e in MutationEvent, where: e.dataset_id == ^id),
      media:
        count(
          from m in MediaFile,
            where:
              m.dataset_id == ^id or
                (is_nil(m.dataset_id) and m.dataset == ^slug and m.workspace_id == ^ws.id)
        ),
      prefs:
        count(
          from p in "user_prefs",
            where: p.workspace_id == type(^ws.id, Ecto.UUID) and p.dataset == ^slug
        ),
      scheduled:
        count(
          from s in "scheduled_publishes",
            where: s.workspace_id == type(^ws.id, Ecto.UUID) and s.dataset == ^slug
        )
    }
  end

  defp count(query), do: Repo.aggregate(query, :count)

  test "removes the dataset with its documents, history, schemas, media, prefs and schedules",
       %{ws: ws, project: project, user: user} do
    dataset = seed(ws, project, "j10-1", user)
    before = census(dataset, ws)
    assert Enum.all?(before, fn {_, n} -> n > 0 end), inspect(before)

    assert {:ok, receipt} = Tenancy.delete_dataset(dataset)

    assert receipt.dataset.id == dataset.id
    assert receipt.documents == 2
    assert receipt.media_files == 1
    assert %{"user_prefs" => 1, "scheduled_publishes" => 1} = receipt.swept
    assert Repo.get(Dataset, dataset.id) == nil
    assert Enum.all?(census(dataset, ws), fn {_, n} -> n == 0 end), inspect(census(dataset, ws))
  end

  test "leaves a sibling dataset and the same slug in another workspace untouched",
       %{ws: ws, project: project, other_ws: other_ws, other_project: other_project, user: user} do
    doomed = seed(ws, project, "j10-2", user)
    sibling = seed(ws, project, "j10-3", user)
    same_slug = seed(other_ws, other_project, "j10-2", user)
    sibling_before = census(sibling, ws)
    same_slug_before = census(same_slug, other_ws)

    assert {:ok, _} = Tenancy.delete_dataset(doomed)

    assert census(sibling, ws) == sibling_before
    assert census(same_slug, other_ws) == same_slug_before
  end

  test "a slug another project of the workspace also uses keeps its workspace-keyed prefs",
       %{ws: ws, project: project, user: user} do
    second = create_project!(ws)
    doomed = seed(ws, project, "j10-4", user)
    _twin = seed(ws, second, "j10-4", user)

    assert {:ok, receipt} = Tenancy.delete_dataset(doomed)

    refute Map.has_key?(receipt.swept, "user_prefs")
    assert %{"open" => true} = UserPrefs.get(user.id, ws.id, "j10-4", "desk")
    assert receipt.swept["scheduled_publishes"] == 1
  end

  test "refuses production and deletes nothing", %{ws: ws, project: project} do
    production = Tenancy.get_or_create_dataset(project, "production") |> elem(1)
    {:ok, _} = create_document_in!(ws, project, "post", %{}, "production")

    assert {:error, :production_dataset} = Tenancy.delete_dataset(production)
    assert Repo.get(Dataset, production.id)
    assert count(from d in Document, where: d.dataset_id == ^production.id) > 0
  end

  describe "the table classification stays complete" do
    test "every FK to datasets cascades, except api_tokens which keeps its slug binding" do
      %{rows: rows} =
        Repo.query!("""
        SELECT cl.relname, c.confdeltype FROM pg_constraint c
        JOIN pg_class cl ON cl.oid = c.conrelid
        JOIN pg_class pl ON pl.oid = c.confrelid
        WHERE c.contype = 'f' AND pl.relname = 'datasets'
        """)

      assert rows != []

      for [table, rule] <- rows do
        expected = if table == "api_tokens", do: "n", else: "c"

        assert rule == expected,
               "#{table} FK to datasets has delete rule #{rule}; classify it in DatasetDelete"
      end
    end

    test "every table naming a dataset by string is swept or deliberately retained" do
      %{rows: rows} =
        Repo.query!("""
        SELECT c.table_name FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
        WHERE c.table_schema = 'public' AND c.column_name IN ('dataset', 'scope')
          AND c.table_name NOT IN (
            SELECT table_name FROM information_schema.columns
            WHERE table_schema = 'public' AND column_name = 'dataset_id'
          )
        GROUP BY c.table_name
        """)

      not_tenant = ~w(idempotency_keys)
      classified = DatasetDelete.swept_tables() ++ DatasetDelete.retained_tables() ++ not_tenant

      unclassified = for [table] <- rows, table not in classified, do: table

      assert unclassified == [],
             "classify these in Barkpark.Tenancy.DatasetDelete: #{inspect(unclassified)}"
    end
  end
end
