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
end
