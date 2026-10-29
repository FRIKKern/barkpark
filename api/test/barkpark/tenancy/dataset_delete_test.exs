defmodule Barkpark.Tenancy.DatasetDeleteTest do
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{AccountsFixtures, Audit, Content, Repo, Tenancy, UserPrefs, Webhooks}
  alias Barkpark.Content.{Document, MutationEvent, Revision, SchemaDefinition}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Search.Synonyms
  alias Barkpark.Tenancy.{Dataset, DatasetDelete}
  alias Barkpark.Webhooks.Webhook

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
        WHERE c.table_schema = 'public' AND c.column_name IN ('dataset', 'scope', 'scope_dataset')
          AND c.table_name NOT IN (
            SELECT table_name FROM information_schema.columns
            WHERE table_schema = 'public' AND column_name LIKE '%dataset_id'
          )
        GROUP BY c.table_name
        """)

      not_tenant = ~w(idempotency_keys)
      classified = DatasetDelete.swept_tables() ++ DatasetDelete.retained_tables() ++ not_tenant

      unclassified = for [table] <- rows, table not in classified, do: table

      assert unclassified == [],
             "classify these in Barkpark.Tenancy.DatasetDelete: #{inspect(unclassified)}"
    end

    test "every table with a dataset_id column is in exactly one class" do
      classes = DatasetDelete.dataset_id_tables()
      classified = classes |> Map.values() |> List.flatten()

      assert classified == Enum.uniq(classified)
      assert Enum.sort(classified) == Enum.sort(Map.keys(dataset_id_columns()))
    end

    test "a cascade alone is trusted only where the FK exists and a NULL dataset_id cannot hide a row" do
      %{cascade: cascade, cascade_and_string: with_string, walked: walked, not_tenant: not_tenant} =
        DatasetDelete.dataset_id_tables()

      columns = dataset_id_columns()
      fks = fk_rules()

      for table <- cascade ++ with_string ++ walked do
        assert fks[table] == "c", "#{table}: no ON DELETE CASCADE FK to datasets"
      end

      for table <- not_tenant, do: refute(Map.has_key?(fks, table), "#{table} has an FK")

      for table <- cascade, table not in DatasetDelete.append_only_tables() do
        %{nullable: nullable, named: named} = columns[table]

        refute nullable and named,
               "#{table}: its dataset_id may be NULL and it names the dataset by string, " <>
                 "so the cascade misses rows; move it to cascade_and_string"
      end
    end
  end

  defp dataset_id_columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.table_name, bool_or(c.column_name LIKE '%dataset_id' AND c.is_nullable = 'YES'),
             bool_or(c.column_name IN ('dataset', 'scope', 'scope_dataset'))
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
      WHERE c.table_schema = 'public'
      GROUP BY c.table_name
      HAVING bool_or(c.column_name LIKE '%dataset_id')
      """)

    for [table, nullable, named] <- rows,
        into: %{},
        do: {table, %{nullable: nullable, named: named}}
  end

  defp fk_rules do
    %{rows: rows} =
      Repo.query!("""
      SELECT cl.relname, c.confdeltype FROM pg_constraint c
      JOIN pg_class cl ON cl.oid = c.conrelid
      JOIN pg_class pl ON pl.oid = c.confrelid
      WHERE c.contype = 'f' AND pl.relname = 'datasets'
      """)

    Map.new(rows, fn [table, rule] -> {table, rule} end)
  end

  defp webhook!(ws, project, slug) do
    {:ok, hook} =
      Webhooks.create_webhook(
        %{"name" => "hook-#{slug}", "url" => "https://example.com/#{slug}", "dataset" => slug},
        workspace_id: ws.id,
        project_id: project.id
      )

    hook
  end

  defp synonym_rows(scope) do
    Repo.all(
      from s in "search_synonyms",
        where: s.scope == ^scope,
        select: {type(s.workspace_id, Ecto.UUID), type(s.dataset_id, Ecto.UUID)}
    )
  end

  describe "rows a writer leaves without a dataset_id" do
    test "a webhook leaves with its dataset and stays gone when the name is reused",
         %{ws: ws, project: project, user: user} do
      dataset = seed(ws, project, "j10-5", user)
      _sibling = seed(ws, project, "j10-6", user)
      doomed = webhook!(ws, project, "j10-5")
      kept = webhook!(ws, project, "j10-6")

      assert {:ok, receipt} = Tenancy.delete_dataset(dataset)

      assert receipt.swept["webhooks"] == 1
      refute Repo.get(Webhook, doomed.id)
      assert Repo.get(Webhook, kept.id)

      {:ok, _} = Tenancy.get_or_create_dataset(project, "j10-5")
      scope = [workspace_id: ws.id, project_id: project.id]
      assert Webhooks.active_webhooks_for("j10-5", "create", "post", scope) == []
    end

    test "a workspace synonym leaves with the workspace's dataset", %{ws: ws, project: project} do
      {:ok, _} = Synonyms.create("docs", "j10-s1", %{"from" => "a", "to" => "b"}, ws.id)
      {:ok, dataset} = Tenancy.get_or_create_dataset(project, "j10-s1")

      assert {:ok, %{swept: %{"search_synonyms" => 1}}} = Tenancy.delete_dataset(dataset)
      assert synonym_rows("j10-s1") == []
    end
  end

  describe "another workspace's rows" do
    test "a workspace synonym is not stamped with the Default project's dataset", %{ws: ws} do
      {_default_ws, default_project} = ensure_default_scope!()

      {:ok, _} = Synonyms.create("docs", "j10-s2", %{"from" => "a", "to" => "b"}, ws.id)
      {:ok, _} = Synonyms.create("docs", "j10-s2", %{"from" => "c", "to" => "d"})

      %{id: default_id} = Tenancy.get_dataset(default_project, "j10-s2")
      assert Enum.sort(synonym_rows("j10-s2")) == Enum.sort([{ws.id, nil}, {nil, default_id}])
    end

    test "deleting a Default-project dataset detaches, never deletes, another workspace's rows",
         %{ws: ws} do
      {_default_ws, default_project} = ensure_default_scope!()
      {:ok, _} = Synonyms.create("docs", "j10-s3", %{"from" => "a", "to" => "b"}, ws.id)
      {:ok, default_ds} = Tenancy.get_or_create_dataset(default_project, "j10-s3")

      Repo.update_all(
        from(s in "search_synonyms", where: s.workspace_id == type(^ws.id, Ecto.UUID)),
        set: [dataset_id: Ecto.UUID.dump!(default_ds.id)]
      )

      assert {:ok, receipt} = Tenancy.delete_dataset(default_ds)

      assert receipt.detached == %{"search_synonyms" => 1}
      assert synonym_rows("j10-s3") == [{ws.id, nil}]
    end
  end

  test "the delete is appended to the workspace's audit chain",
       %{ws: ws, project: project, user: user} do
    dataset = seed(ws, project, "j10-9", user)

    assert {:ok, _} =
             Tenancy.delete_dataset(dataset, actor_type: "api_token", actor_id: "token-1")

    assert [event] =
             Repo.all(
               from e in Audit.Event,
                 where: e.workspace_id == ^ws.id and e.action == "dataset_deleted"
             )

    assert %{category: "content_mutation", subject: subject, actor_id: "token-1"} = event
    assert subject == dataset.id
    assert %{"dataset" => "j10-9", "documents" => 2, "media_files" => 1} = event.metadata
    assert Audit.verify_chain(ws.id) == :ok
  end

  test "a failure at the last step rolls the whole delete back",
       %{ws: ws, project: project, user: user} do
    dataset = seed(ws, project, "j10-10", user)
    before = census(dataset, ws)

    Repo.query!(
      "CREATE FUNCTION ds_delete_refuse() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'refused'; END $$ LANGUAGE plpgsql"
    )

    Repo.query!(
      "CREATE TRIGGER ds_delete_refuse BEFORE DELETE ON datasets FOR EACH ROW EXECUTE FUNCTION ds_delete_refuse()"
    )

    assert_raise Postgrex.Error, fn -> Tenancy.delete_dataset(dataset) end

    assert Repo.get(Dataset, dataset.id)
    assert census(dataset, ws) == before
    refute Repo.exists?(from e in Audit.Event, where: e.action == "dataset_deleted")
  end
end
