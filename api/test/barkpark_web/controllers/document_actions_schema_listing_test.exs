defmodule BarkparkWeb.DocumentActionsSchemaListingTest do
  @moduledoc """
  task-025f9425c4c13018 — `GET …/v1/data/doc/:dataset/:type/:id/actions`
  lists every action a schema declares, on any type, singletons included,
  next to the built-ins. A plugin may still drop ITS OWN actions where they
  cannot act: OnixEdit's book-only actions are left out on a non-book type
  (#23039), which is why a fixture `volume` declaring OnixEdit's action name
  saw it vanish. A neutral action name is never caught by that rule.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Plugins.Registry
  alias Barkpark.Tenancy

  @dataset "doc-actions-listing"

  @neutral %{
    "name" => "send-for-review",
    "label" => "Send for review",
    "kind" => "modal",
    "icon" => "send",
    "modal" => %{"title" => "Send for review?", "steps" => ["dryrun", "real"]}
  }

  setup do
    Application.delete_env(:barkpark, :plugins)
    Registry.reset()

    on_exit(fn ->
      Application.delete_env(:barkpark, :plugins)
      Registry.reset()
    end)

    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    for {name, extra} <- [
          {"volume",
           %{"actions" => [@neutral, Map.put(@neutral, "name", "publish_to_bokbasen")]}},
          {"settingsdoc", %{"singleton" => true, "actions" => [@neutral]}}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          Map.merge(
            %{
              "name" => name,
              "title" => name,
              "visibility" => "public",
              "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
            },
            extra
          ),
          @dataset,
          scope
        )
    end

    for {type, id} <- [{"volume", "volume-01"}, {"settingsdoc", "settingsdoc"}] do
      {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "T"}, @dataset, scope)
    end

    raw = "doc-actions-listing-" <> Base.encode16(:crypto.strong_rand_bytes(6))
    {:ok, token} = Barkpark.Auth.create_token(raw, "admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "admin", "api_token")

    %{ws: ws, proj: proj, raw: raw}
  end

  defp names(%{ws: ws, proj: proj, raw: raw}, type, id) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> get("/w/#{ws.slug}/p/#{proj.slug}/v1/data/doc/#{@dataset}/#{type}/#{id}/actions")
    |> json_response(200)
    |> Map.fetch!("actions")
    |> Enum.map(& &1["name"])
  end

  test "a schema-declared action is listed next to the built-ins", ctx do
    names = names(ctx, "volume", "volume-01")
    assert "send-for-review" in names
    assert "delete-doc" in names
  end

  test "a singleton lists its schema-declared actions; only built-ins are withheld", ctx do
    names = names(ctx, "settingsdoc", "settingsdoc")
    assert "send-for-review" in names
    refute "delete-doc" in names
  end

  test "with OnixEdit on, its book-only action leaves a non-book; a neutral one stays", ctx do
    :ok = Registry.register(Barkpark.Plugins.OnixEdit, %{"plugin_name" => "onixedit"})

    names = names(ctx, "volume", "volume-01")
    assert "send-for-review" in names
    refute "publish_to_bokbasen" in names
  end
end
