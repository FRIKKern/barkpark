defmodule BarkparkWeb.MutateCriteriaKeyAllowlistTest do
  @moduledoc """
  pds-bl-stray-keys-on-acceptance-criteria over HTTP: `bp doc patch` and
  `bp task create`'s mutate shapes (a `patch` set and a `createOrReplace`) on
  a task refuse an unknown acceptance_criteria key with a 422 whose body names
  the key and the allowed set; a declared-key write lands.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Validation

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    token = "crit-keys-#{System.unique_integer([:positive])}"
    Auth.create_token(token, "dev", @dataset, ["read", "write", "admin"], ws.id)
    %{token: token}
  end

  defp mutate(token, mutations) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp task(id, criteria),
    do: %{
      "_id" => id,
      "_type" => "task",
      "title" => id,
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" => criteria
    }

  test "createOrReplace with an unknown criterion key is a 422 naming it and the allowed set", %{
    token: t
  } do
    resp =
      mutate(t, [
        %{
          "createOrReplace" =>
            task("ck-#{System.unique_integer([:positive])}", [
              %{"criterion" => "ships", "weight" => 1, "text" => "ships"}
            ])
        }
      ])

    assert resp.status == 422, resp.resp_body
    assert resp.resp_body =~ ~s(\\"text\\")
    assert resp.resp_body =~ Enum.join(Validation.criterion_keys(), ", ")
  end

  test "patch set of criteria with an unknown key is a 422; with declared keys it lands", %{
    token: t
  } do
    id = "ck-#{System.unique_integer([:positive])}"

    assert mutate(t, [
             %{"createOrReplace" => task(id, [%{"criterion" => "ships", "met" => false}])}
           ]).status == 200

    bad =
      mutate(t, [
        %{
          "patch" => %{
            "id" => id,
            "type" => "task",
            "set" => %{"acceptance_criteria" => [%{"criterion" => "ships", "index" => 0}]}
          }
        }
      ])

    assert bad.status == 422, bad.resp_body
    assert bad.resp_body =~ ~s(\\"index\\")

    good =
      mutate(t, [
        %{
          "patch" => %{
            "id" => id,
            "type" => "task",
            "set" => %{"acceptance_criteria" => [%{"criterion" => "ships", "weight" => 2}]}
          }
        }
      ])

    assert good.status == 200, good.resp_body
  end
end
