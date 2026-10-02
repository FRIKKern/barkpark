defmodule Barkpark.Webhooks.DisabledEndpointResumeTest do
  @moduledoc """
  task-6c6553bcb157856a — a scheduled retry (RetryWorker) or a stuck-delivery
  re-drive (StuckDeliverySweeper) rebuilt its payload after checking only that
  the webhook ROW still existed, so it still POSTed to an endpoint a PERSON had
  disabled in the meantime. Now such a resume is abandoned: no POST, the row
  goes terminal with a reason, and the endpoint's failure streak is untouched.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.{Delivery, PayloadRebuild, RetryWorker, Webhook}

  defmodule RecordingHTTP do
    def post(url, _body, _headers) do
      pid = Application.get_env(:barkpark, :test_recv_pid)
      if pid, do: send(pid, {:webhook_post, url})
      {:ok, 200}
    end
  end

  setup do
    prev = Application.get_env(:barkpark, :webhook_http_adapter)
    prev_private = Application.fetch_env(:barkpark, :allow_private_outbound)
    Application.put_env(:barkpark, :webhook_http_adapter, RecordingHTTP)
    Application.put_env(:barkpark, :test_recv_pid, self())
    Application.put_env(:barkpark, :allow_private_outbound, true)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :webhook_http_adapter, prev),
        else: Application.delete_env(:barkpark, :webhook_http_adapter)

      case prev_private do
        {:ok, v} -> Application.put_env(:barkpark, :allow_private_outbound, v)
        :error -> Application.delete_env(:barkpark, :allow_private_outbound)
      end

      Application.delete_env(:barkpark, :test_recv_pid)
    end)

    :ok
  end

  defp pending_delivery(attrs) do
    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => "resume",
        "url" => "http://example.test/resume",
        "dataset" => "production",
        "secret" => "s3cr3t-value-long"
      })

    {:ok, ev} =
      %MutationEvent{}
      |> Ecto.Changeset.change(%{
        dataset: "production",
        type: "post",
        doc_id: "r-#{System.unique_integer([:positive])}",
        mutation: "update",
        rev: "rev-#{System.unique_integer([:positive])}",
        document: %{"_id" => "r", "title" => "T"},
        inserted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    {:ok, d} = Webhooks.claim_delivery(wh.id, ev.id)
    wh = wh |> Ecto.Changeset.change(attrs) |> Repo.update!()
    {wh, Repo.get!(Delivery, d.id)}
  end

  defp run_retry(%Delivery{} = d) do
    RetryWorker.perform(%Oban.Job{
      args: %{
        "delivery_id" => d.id,
        "attempt" => 1,
        "fence" => DateTime.to_iso8601(d.updated_at)
      }
    })
  end

  test "a retry for a hand-DISABLED endpoint does not POST and goes terminal" do
    {wh, d} = pending_delivery(%{active: false, auto_disabled_at: nil})

    assert {:disabled, _} = PayloadRebuild.rebuild(d)
    assert :ok = run_retry(d)

    refute_received {:webhook_post, _}
    row = Repo.get!(Delivery, d.id)
    assert row.status == "failed_giveup"
    assert row.last_error_text =~ "endpoint_disabled"
    assert Repo.get!(Webhook, wh.id).consecutive_failures == 0
  end

  test "CONTROL: the same retry for an ACTIVE endpoint delivers" do
    {_wh, d} = pending_delivery(%{})

    assert {:ok, _, _} = PayloadRebuild.rebuild(d)
    assert :ok = run_retry(d)
    assert_receive {:webhook_post, "http://example.test/resume"}
  end

  test "CONTROL: an AUTO-disabled endpoint still rebuilds (its half-open probe owns that exit)" do
    {_wh, d} =
      pending_delivery(%{
        active: false,
        auto_disabled_at: DateTime.truncate(DateTime.utc_now(), :second),
        consecutive_failures: 20
      })

    assert {:ok, _, _} = PayloadRebuild.rebuild(d)
  end
end
