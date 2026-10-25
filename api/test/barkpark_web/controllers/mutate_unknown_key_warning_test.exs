defmodule BarkparkWeb.MutateUnknownKeyWarningTest do
  @moduledoc """
  An unknown top-level body key on POST /v1/data/mutate/:dataset is named in a
  non-fatal `mutate.unknown_key` warning; the batch still applies
  (task-778e3617070bce11). The door used to drop such keys without a trace,
  which is how `dryRun` wrote for real before it was honoured.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  @dataset "test"

  setup do
    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "test",
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  defp mutate(body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(body))
  end

  defp create(id), do: [%{"create" => %{"_id" => id, "_type" => "post", "title" => "T"}}]

  defp unknown_key_warnings(resp) do
    resp.resp_body
    |> Jason.decode!()
    |> Map.get("warnings", [])
    |> Enum.filter(&(&1["code"] == "mutate.unknown_key"))
  end

  test "unknown keys are named in one advisory warning and the batch still writes" do
    id = "unknown-key-#{System.unique_integer([:positive])}"

    resp = mutate(%{"mutations" => create(id), "dryrun" => true, "returnIds" => true})

    assert resp.status == 200, resp.resp_body
    assert [warning] = unknown_key_warnings(resp)
    assert warning["severity"] == "advisory"
    assert warning["message"] =~ "dryrun, returnIds"
    assert {:ok, _} = Content.get_document("drafts." <> id, "post", @dataset)
  end

  test "control: known keys only (mutations, dryRun) carry no unknown-key warning" do
    id = "known-key-#{System.unique_integer([:positive])}"

    assert [] = mutate(%{"mutations" => create(id)}) |> unknown_key_warnings()

    assert [] =
             mutate(%{"mutations" => create(id <> "-dry"), "dryRun" => true})
             |> unknown_key_warnings()
  end

  test "visibility is a known key; a value other than sync, async or deferred is refused" do
    id = "visibility-#{System.unique_integer([:positive])}"

    resp = mutate(%{"mutations" => create(id), "visibility" => "async"})
    assert resp.status == 200, resp.resp_body
    assert [] = unknown_key_warnings(resp)

    resp = mutate(%{"mutations" => create(id <> "-bad"), "visibility" => "later"})
    assert resp.status == 400
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "malformed"
    assert {:error, _} = Content.get_document("drafts." <> id <> "-bad", "post", @dataset)
  end

  # task-b59e4d73521e07a7 — a key INSIDE a mutation the server does not read.
  defp unknown_mutation_key_warnings(resp) do
    resp.resp_body
    |> Jason.decode!()
    |> Map.get("warnings", [])
    |> Enum.filter(&(&1["code"] == "mutate.unknown_mutation_key"))
  end

  test "an unknown key inside a mutation is named, per mutation, and the batch still writes" do
    id = "inner-key-#{System.unique_integer([:positive])}"
    doc = %{"_id" => id, "_type" => "post", "title" => "T"}

    resp =
      mutate(%{
        "mutations" => [
          %{"createOrReplace" => doc, "pubish" => true},
          %{"create" => Map.put(doc, "_id", id <> "-2"), "returnId" => true, "ifMatch" => "x"}
        ]
      })

    assert resp.status == 200, resp.resp_body
    assert [warning] = unknown_mutation_key_warnings(resp)
    assert warning["severity"] == "advisory"
    assert warning["message"] =~ "mutations[0]: pubish"
    assert warning["message"] =~ "mutations[1]: ifMatch, returnId"
    assert {:ok, _} = Content.get_document("drafts." <> id, "post", @dataset)
  end

  test "control: the verbs and the direct-publish flag carry no inner-key warning" do
    id = "inner-known-#{System.unique_integer([:positive])}"
    doc = %{"_id" => id, "_type" => "post", "title" => "T"}

    resp = mutate(%{"mutations" => [%{"createOrReplace" => doc, "publish" => true}]})
    assert resp.status == 200, resp.resp_body
    assert [] = unknown_mutation_key_warnings(resp)

    resp =
      mutate(%{"mutations" => [%{"patch" => %{"id" => id, "type" => "post", "set" => %{}}}]})

    assert [] = unknown_mutation_key_warnings(resp)
  end
end
