defmodule BarkparkWeb.MutateBatchConnectionFaultTest do
  @moduledoc """
  task-f8233616de3513d4 — a refused/lost DB checkout on the mutate BATCH's own
  transaction answered 503 `internal_error` "unknown error
  (DBConnection.ConnectionError)" (8,011 times in run8-sweep2's pool-shed
  probe). It now answers the typed 503 `storage_unavailable` /
  `connection_unavailable` the single-document write twin (#15489) already
  gives, and nothing is written. Any OTHER exception at the same site still
  propagates untouched (the rescue is narrow).

  `async: false`: the fault seam is `Application.put_env`, which is global.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  @dataset "production"

  setup do
    token = "batch-fault-#{System.unique_integer([:positive])}"

    Auth.create_token(
      token,
      "dev",
      @dataset,
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    on_exit(fn -> Application.delete_env(:barkpark, :writer_fault) end)
    %{token: token}
  end

  defp mutate(token, id) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{
        "mutations" => [%{"createOrReplace" => %{"_id" => id, "_type" => "post", "title" => "t"}}]
      })
    )
  end

  test "a connection fault on the batch transaction is a typed 503, and nothing is written", %{
    token: t
  } do
    Application.put_env(
      :barkpark,
      :writer_fault,
      {:batch_transaction, DBConnection.ConnectionError,
       "connection not available and request was dropped from queue after 43ms"}
    )

    id = "batch-fault-#{System.unique_integer([:positive])}"
    resp = mutate(t, id)

    assert resp.status == 503, resp.resp_body
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "storage_unavailable"
    assert error["reason"] == "connection_unavailable"
    refute resp.resp_body =~ "internal_error"
    refute resp.resp_body =~ "unknown error"

    Application.delete_env(:barkpark, :writer_fault)
    assert {:error, :not_found} = Content.get_document("drafts." <> id, "post", @dataset)
  end

  # task-61dbf8a21cd155d1: on a 2 vCPU test instance an import batch got 500
  # `internal_error` after 15 s because the pool timeout came back as a VALUE,
  # which `Content.Errors` had no clause for. The import client resends a
  # smaller batch only on 503 `storage_unavailable`.
  test "a pool timeout RETURNED by the batch is the typed 503, and nothing is written", %{
    token: t
  } do
    Application.put_env(
      :barkpark,
      :writer_fault,
      {:batch_rollback,
       DBConnection.ConnectionError.exception(
         "client #PID<0.1.0> timed out because it queued and checked out the connection for longer than 15000ms"
       )}
    )

    id = "batch-returned-#{System.unique_integer([:positive])}"

    {resp, log} = ExUnit.CaptureLog.with_log(fn -> mutate(t, id) end)

    assert resp.status == 503, resp.resp_body
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "storage_unavailable"
    assert error["reason"] == "connection_unavailable"
    refute resp.resp_body =~ "internal_error"
    refute log =~ "no build/1 clause matched"

    Application.delete_env(:barkpark, :writer_fault)
    assert {:error, :not_found} = Content.get_document("drafts." <> id, "post", @dataset)
  end

  test "any other exception at the same site still propagates (the rescue is narrow)", %{token: t} do
    Application.put_env(
      :barkpark,
      :writer_fault,
      {:batch_transaction, RuntimeError, "not a connection fault"}
    )

    assert_raise RuntimeError, "not a connection fault", fn ->
      mutate(t, "batch-other-#{System.unique_integer([:positive])}")
    end
  end

  test "with no fault the batch lands (the seam is inert)", %{token: t} do
    assert mutate(t, "batch-ok-#{System.unique_integer([:positive])}").status == 200
  end
end
