defmodule Barkpark.Tenancy.DatasetDeleteTest do
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{AccountsFixtures, Audit, Auth, Content, Repo, Tenancy, UserPrefs, Webhooks}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.{Document, MutationEvent, Revision, SchemaDefinition}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Media.WhereUsed
  alias Barkpark.Search.Synonyms
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
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

    assert Enum.map(receipt.steps, & &1.step) ==
             ~w(scope lock refuse_shared_search refuse_media detach exemptions media documents
                sweep_strings sweep_fk_strings tokens dataset audit_event audit_lock audit_flush
                commit broadcast)

    assert Enum.all?(receipt.steps, &(is_integer(&1.ms) and &1.ms >= 0))
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

  test "a second delete of the same dataset is :not_found and changes nothing",
       %{ws: ws, project: project, user: user} do
    dataset = seed(ws, project, "j10-d1", user)
    assert {:ok, _} = Tenancy.delete_dataset(dataset)

    assert {:error, :not_found} = Tenancy.delete_dataset(dataset)

    assert Repo.aggregate(
             from(e in Audit.Event,
               where: e.workspace_id == ^ws.id and e.action == "dataset_deleted"
             ),
             :count
           ) == 1
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

  describe "what lives past the dataset" do
    test "a global synonym keyed to a Default-project dataset refuses the delete and survives" do
      {_default_ws, default_project} = ensure_default_scope!()
      {:ok, _} = Synonyms.create("docs", "j10-g1", %{"from" => "a", "to" => "b"})
      default_ds = Tenancy.get_dataset(default_project, "j10-g1")

      assert {:error, {:shared_search, %{"search_synonyms" => 1}}} =
               Tenancy.delete_dataset(default_ds)

      assert Repo.get(Dataset, default_ds.id)
      assert synonym_rows("j10-g1") == [{nil, default_ds.id}]
    end

    test "media another dataset embeds by URL refuses the delete; its own documents do not",
         %{ws: ws, project: project} do
      {:ok, shown} = create_media_file_in!(ws, project, %{}, "j10-m1")
      {:ok, own} = create_media_file_in!(ws, project, %{}, "j10-m1")
      path = WhereUsed.delivery_path(shown)
      {:ok, _} = create_document_in!(ws, project, "post", %{"body" => path}, "production")

      {:ok, _} =
        create_document_in!(
          ws,
          project,
          "post",
          %{"body" => WhereUsed.delivery_path(own)},
          "j10-m1"
        )

      dataset = Tenancy.get_dataset(project, "j10-m1")

      assert {:error, {:media_referenced, [%{media_id: media_id, count: 1}]}} =
               Tenancy.delete_dataset(dataset)

      assert media_id == shown.id
      assert Repo.get(MediaFile, shown.id)
      assert Repo.get(Dataset, dataset.id)
    end

    test "a token bound to the dataset is revoked; one whose slug lives on elsewhere is kept",
         %{ws: ws, project: project, user: user} do
      dataset = seed(ws, project, "j10-t1", user)
      second = create_project!(ws)
      _twin = seed(ws, second, "j10-t2", user)
      shared = seed(ws, project, "j10-t2", user)
      doomed = bound_token!(ws, "j10-t1")
      kept = bound_token!(ws, "j10-t2")

      assert {:ok, %{tokens_revoked: 1}} = Tenancy.delete_dataset(dataset)
      assert {:ok, %{tokens_revoked: 0}} = Tenancy.delete_dataset(shared)

      assert Repo.get(ApiToken, doomed.id).revoked_at
      refute Repo.get(ApiToken, kept.id).revoked_at
    end

    test "a revoked token's sockets are told to disconnect after the commit",
         %{ws: ws, project: project, user: user} do
      dataset = seed(ws, project, "j10-t3", user)
      token = bound_token!(ws, "j10-t3")
      BarkparkWeb.Endpoint.subscribe(BarkparkWeb.UserSocket.disconnect_topic(token.id))

      assert {:ok, %{tokens_revoked: 1}} = Tenancy.delete_dataset(dataset)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end

  defp bound_token!(ws, dataset) do
    raw = "ds-bound-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "bound", dataset, ~w(read write))
    token = token |> Ecto.Changeset.change(dataset_bound: true) |> Repo.update!()
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "member", "api_token")
    token
  end

  test "the delete is appended to the workspace's audit chain",
       %{ws: ws, project: project, user: user} do
    dataset = seed(ws, project, "j10-9", user)

    actor = bound_token!(ws, "j10-9")
    assert {:ok, _} = Tenancy.delete_dataset(dataset, actor: actor)

    assert [event] =
             Repo.all(
               from e in Audit.Event,
                 where: e.workspace_id == ^ws.id and e.action == "dataset_deleted"
             )

    actor_id = to_string(actor.id)
    assert %{category: "content_mutation", subject: subject, actor_id: ^actor_id} = event
    assert subject == dataset.id

    assert %{"dataset" => "j10-9", "documents" => 2, "tokens_revoked" => [^actor_id]} =
             event.metadata

    assert [revoke] =
             Repo.all(
               from e in Audit.Event,
                 where: e.action == "token_revoked" and e.subject == ^actor_id
             )

    assert %{workspace_id: workspace_id, actor_type: "api_token", actor_id: ^actor_id} = revoke
    assert workspace_id == ws.id
    assert revoke.metadata["dataset_deleted"] == dataset.id
    assert Audit.verify_chain(ws.id) == :ok
  end

  test "a failure at the last step rolls the whole delete back",
       %{ws: ws, project: project, user: user} do
    dataset = seed(ws, project, "j10-10", user)
    token = bound_token!(ws, "j10-10")
    BarkparkWeb.Endpoint.subscribe(BarkparkWeb.UserSocket.disconnect_topic(token.id))
    before = census(dataset, ws)

    Repo.query!(
      "CREATE FUNCTION ds_delete_refuse() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'refused'; END $$ LANGUAGE plpgsql"
    )

    Repo.query!(
      "CREATE TRIGGER ds_delete_refuse BEFORE DELETE ON datasets FOR EACH ROW EXECUTE FUNCTION ds_delete_refuse()"
    )

    assert {:error, {:delete_failed, :database, steps}} = Tenancy.delete_dataset(dataset)
    assert %{step: "dataset"} = List.last(steps)
    assert Enum.at(steps, -2).step == "tokens"

    assert Repo.get(Dataset, dataset.id)
    assert census(dataset, ws) == before

    refute Repo.exists?(
             from e in Audit.Event,
               where: e.workspace_id == ^ws.id and e.action == "dataset_deleted"
           )

    refute Repo.get(ApiToken, token.id).revoked_at
    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
  end

  defmodule RefuseDeleteHook do
    @moduledoc false
    def lifecycle_hooks, do: %{before_delete: [&__MODULE__.refuse/1]}
    def refuse(_payload), do: {:halt, "refused"}
  end

  describe "a deadlock" do
    setup do
      Repo.query!("CREATE SEQUENCE ds_delete_deadlocks")

      Repo.query!("""
      CREATE FUNCTION ds_delete_deadlock() RETURNS trigger AS $$
      BEGIN
        IF nextval('ds_delete_deadlocks') <= current_setting('ds_delete.deadlocks')::int THEN
          RAISE EXCEPTION 'deadlock' USING ERRCODE = '40P01';
        END IF;
        RETURN OLD;
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!(
        "CREATE TRIGGER ds_delete_deadlock BEFORE DELETE ON datasets FOR EACH ROW EXECUTE FUNCTION ds_delete_deadlock()"
      )

      :ok
    end

    test "is tried again, and the receipt times the attempt that finished",
         %{ws: ws, project: project, user: user} do
      dataset = seed(ws, project, "j10-11", user)
      Repo.query!("SET ds_delete.deadlocks = 2")

      assert {:ok, %{steps: steps}} = Tenancy.delete_dataset(dataset)
      assert Enum.count(steps, &(&1.step == "dataset")) == 1
      refute Repo.get(Dataset, dataset.id)
    end

    test "answers :contended after 5 tries, stopped in the dataset step",
         %{ws: ws, project: project, user: user} do
      dataset = seed(ws, project, "j10-12", user)
      Repo.query!("SET ds_delete.deadlocks = 5")

      assert {:error, {:delete_failed, :contended, steps}} = Tenancy.delete_dataset(dataset)
      assert %{step: "dataset"} = List.last(steps)
      assert Repo.get(Dataset, dataset.id)
    end
  end

  test "progress/1 is empty for a process with no delete running, live or gone" do
    assert DatasetDelete.progress(self()) == []

    gone = spawn(fn -> :ok end)
    ref = Process.monitor(gone)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert DatasetDelete.progress(gone) == []
  end

  test "a hook that halts a document delete answers its halt and leaves the dataset whole",
       %{ws: ws, project: project, user: user} = ctx do
    dataset = seed(ws, project, "j10-11", user)
    before = census(dataset, ws)
    Barkpark.PluginEnv.with_plugins([RefuseDeleteHook], ctx)

    assert {:error, {:halted, "refused"}} = Tenancy.delete_dataset(dataset)
    assert Repo.get(Dataset, dataset.id)
    assert census(dataset, ws) == before
  end
end
