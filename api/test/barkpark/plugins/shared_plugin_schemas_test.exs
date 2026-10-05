defmodule Barkpark.Plugins.SharedPluginSchemasTest do
  @moduledoc """
  Plugin schemas are GLOBAL rows that every workspace reads
  (task-be5eaec4a5b9e524, orchestrator ruling A).

  `Plugins.Bootstrap` installs each plugin schema twice: the Default-workspace
  row it always wrote, and a shared row with `workspace_id`, `project_id` and
  `dataset_id` all NULL. `Content.Schema.get_schema_raw/3` falls back to the
  shared row when the caller's workspace owns no row of that name.

  The test that fails if that fallback is removed:
  "the write door enforces a shared schema's rule in a workspace outside Default".
  Without the fallback the workspace has no schema, `validate_document/5`
  answers `{:ok, _}`, and the create lands.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{SchemaDefinition, Validation, Writer}
  alias Barkpark.Plugins.{Bootstrap, Registry}
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures

  @dataset "production"

  defmodule RuleStub do
    @moduledoc false
    alias Barkpark.Content.SchemaDefinition

    def schema_name, do: "shared_plugin_rule_stub"

    def register_schemas(_opts) do
      [
        %SchemaDefinition{
          name: schema_name(),
          title: "Plugin Title",
          visibility: "private",
          fields: [
            %{"name" => "headline", "type" => "string", "validation" => %{"required" => true}}
          ],
          dataset: "production"
        }
      ]
    end
  end

  setup do
    {default_ws, default_project} = TenancyFixtures.ensure_default_scope!()
    ws = TenancyFixtures.create_workspace!()
    project = TenancyFixtures.create_project!(ws)

    %{
      default_scope: {default_ws.id, default_project.id},
      default_opts: [workspace_id: default_ws.id, project_id: default_project.id],
      opts: [workspace_id: ws.id, project_id: project.id]
    }
  end

  defp install(module, ctx),
    do: Bootstrap.install_for_plugin(%{name: "shared-test", module: module}, ctx.default_scope)

  defp shared_row(name) do
    from(s in SchemaDefinition,
      where: s.name == ^name and is_nil(s.workspace_id) and is_nil(s.dataset_id)
    )
    |> Repo.one()
  end

  defp enforce_validation! do
    previous = Application.get_env(:barkpark, Validation)
    Application.put_env(:barkpark, Validation, enforce_datasets: [@dataset])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, Validation, previous),
        else: Application.delete_env(:barkpark, Validation)
    end)
  end

  test "a workspace outside Default reads the shared row", ctx do
    assert {:ok, 1} = install(RuleStub, ctx)

    assert {:ok, %SchemaDefinition{workspace_id: nil, title: "Plugin Title"}} =
             Content.get_schema(RuleStub.schema_name(), @dataset, ctx.opts)

    assert {:ok, %SchemaDefinition{workspace_id: nil}} =
             Content.resolve_schema(RuleStub.schema_name(), @dataset, ctx.opts)
  end

  test "a shared row declaring public does not open anonymous reads in a workspace", ctx do
    assert {:ok, 1} = install(RuleStub, ctx)
    name = RuleStub.schema_name()

    {1, _} =
      Repo.update_all(where(SchemaDefinition, id: ^shared_row(name).id),
        set: [visibility: "public"]
      )

    Barkpark.Content.WriteScope.reset_request_memo()

    assert {:ok, %{visibility: "public"}} = Content.get_schema(name, @dataset, ctx.opts)
    refute Content.schema_public?(name, @dataset, ctx.opts)
  end

  test "the write door enforces a shared schema's rule in a workspace outside Default", ctx do
    assert {:ok, 1} = install(RuleStub, ctx)
    enforce_validation!()
    type = RuleStub.schema_name()

    assert {:error, %{"headline" => _}} =
             Writer.validate_document(type, "t", %{}, @dataset, ctx.opts)

    assert {:error, {:schema_validation_failed, %{"headline" => _}}} =
             Content.create_document(type, %{"title" => "no headline"}, @dataset, ctx.opts)

    assert {:ok, doc} =
             Content.create_document(
               type,
               %{"title" => "ok", "headline" => "Here"},
               @dataset,
               ctx.opts
             )

    assert doc.workspace_id == Keyword.fetch!(ctx.opts, :workspace_id)
  end

  test "a workspace's own row of the same name wins, and its writes never touch the shared row",
       ctx do
    assert {:ok, 1} = install(RuleStub, ctx)
    name = RuleStub.schema_name()
    shared = shared_row(name)

    assert {:ok, own} =
             Content.upsert_schema(
               %{"name" => name, "title" => "Tenant Title", "fields" => []},
               @dataset,
               ctx.opts
             )

    assert own.workspace_id == Keyword.fetch!(ctx.opts, :workspace_id)
    assert {:ok, %{id: id}} = Content.get_schema(name, @dataset, ctx.opts)
    assert id == own.id
    assert {:ok, _} = Writer.validate_document(name, "t", %{}, @dataset, ctx.opts)

    # Deleting in the workspace removes its own row only; the shared one stays
    # and is read again.
    assert {:ok, _} = Content.delete_schema(name, @dataset, ctx.opts)
    assert shared_row(name).updated_at == shared.updated_at
    assert {:ok, %{id: shared_id}} = Content.get_schema(name, @dataset, ctx.opts)
    assert shared_id == shared.id

    # With nothing of its own, a delete in the workspace finds nothing.
    assert {:error, _} = Content.delete_schema(name, @dataset, ctx.opts)
    assert shared_row(name)
  end

  test "Default reads exactly what it read before the shared row existed", ctx do
    assert {:ok, 1} = install(RuleStub, ctx)
    name = RuleStub.schema_name()

    read = fn ->
      Barkpark.Content.WriteScope.reset_request_memo()

      {
        Content.get_schema(name, @dataset, ctx.default_opts),
        Content.get_schema(name, @dataset),
        Content.list_schemas(@dataset, ctx.default_opts),
        Content.list_schemas(@dataset)
      }
    end

    with_shared = read.()
    {{:ok, default_row}, _, _, _} = with_shared
    refute is_nil(default_row.workspace_id)

    Repo.delete!(shared_row(name))
    assert read.() == with_shared
  end

  test "with no plugin registered, bootstrap installs no shared rows" do
    declared =
      Registry.all()
      |> Enum.flat_map(fn %{module: m} ->
        if Code.ensure_loaded?(m) and function_exported?(m, :register_schemas, 1),
          do: Enum.map(m.register_schemas([]), & &1.name),
          else: []
      end)

    # The app's own boot ran bootstrap outside the sandbox; start from none.
    shared_q = from(s in SchemaDefinition, where: is_nil(s.workspace_id) and is_nil(s.dataset_id))
    Repo.delete_all(shared_q)

    Bootstrap.register_all_schemas()

    shared =
      from(s in SchemaDefinition,
        where: is_nil(s.workspace_id) and is_nil(s.dataset_id),
        select: s.name
      )
      |> Repo.all()

    # Plugins off (BARKPARK_PLUGINS=): `declared` is empty, so this is zero rows.
    assert shared -- declared == []
    if declared == [], do: assert(shared == [])
  end

  # Plugins-off: installs the Media plugin's mediaAsset schema.
  @tag :requires_plugins
  test "a member outside Default creates, patches and publishes a mediaAsset with alt text",
       ctx do
    assert {:ok, 2} = install(Barkpark.Plugins.Media, ctx)
    doc_id = "shared-asset-#{System.unique_integer([:positive])}"

    assert {:ok, %{workspace_id: nil}} = Content.resolve_schema("mediaAsset", @dataset, ctx.opts)

    assert {:ok, _} =
             Content.create_document(
               "mediaAsset",
               %{"doc_id" => doc_id, "title" => "Cover", "altText" => %{"eng" => "A dog"}},
               @dataset,
               ctx.opts
             )

    assert {:ok, _} =
             Content.upsert_document(
               "mediaAsset",
               %{
                 "doc_id" => doc_id,
                 "title" => "Cover",
                 "content" => %{"altText" => %{"eng" => "A dog on a sofa"}}
               },
               @dataset,
               ctx.opts
             )

    assert {:ok, published} = Content.publish_document(doc_id, "mediaAsset", @dataset, ctx.opts)
    assert published.content["altText"] == %{"eng" => "A dog on a sofa"}
    assert published.workspace_id == Keyword.fetch!(ctx.opts, :workspace_id)

    # The Studio editor's own resolver: without the shared row the workspace
    # has no mediaAsset schema (the "No schema for mediaAsset" screen).
    Repo.delete!(shared_row("mediaAsset"))
    Barkpark.Content.WriteScope.reset_request_memo()
    assert :error = Content.resolve_schema("mediaAsset", @dataset, ctx.opts)
  end
end
