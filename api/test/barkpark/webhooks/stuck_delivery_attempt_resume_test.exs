defmodule Barkpark.Webhooks.StuckDeliveryAttemptResumeTest do
  @moduledoc """
  task-bcbef83443504e1c — the stuck-delivery sweeper re-drove a row through
  `Dispatcher.redeliver/4`, which restarts at attempt 1: every sweep reset the
  count, `attempts` ran backwards, and `max_attempts` was never enforced across
  sweeps. It now resumes at the row's stored `attempts + 1` and gives up once
  the budget is spent. The Retry-After clamp also sits strictly below the
  sweeper's threshold, so a server-directed retry is never itself sweepable.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.{Delivery, Dispatcher, StuckDeliverySweeper}

  defmodule Always500 do
    def post(url, _body, _headers) do
      pid = Application.get_env(:barkpark, :test_recv_pid)
      if pid, do: send(pid, {:webhook_post, url})
      {:ok, 500}
    end
  end

  setup do
    prev = Application.get_env(:barkpark, :webhook_http_adapter)
    prev_private = Application.fetch_env(:barkpark, :allow_private_outbound)
    Application.put_env(:barkpark, :webhook_http_adapter, Always500)
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

  # A pending row that has ALREADY spent `spent` attempts, stranded long enough
  # ago to be swept.
  defp stranded(spent) do
    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => "sweep-resume",
        "url" => "http://example.test/sweep",
        "dataset" => "production",
        "events" => ["delete"],
        "secret" => "s3cr3t-value-long"
      })

    {:ok, ev} =
      %MutationEvent{}
      |> Ecto.Changeset.change(%{
        dataset: "production",
        type: "post",
        doc_id: "sw-#{System.unique_integer([:positive])}",
        mutation: "delete",
        rev: "rev-#{System.unique_integer([:positive])}",
        document: %{"_id" => "sw"},
        inserted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    {:ok, d} = Webhooks.claim_delivery(wh.id, ev.id)
    old = DateTime.add(DateTime.utc_now(), -3600, :second)

    from(x in Delivery, where: x.id == ^d.id)
    |> Repo.update_all(set: [attempts: spent, last_status_code: 500, updated_at: old])

    d.id
  end

  test "a sweep RESUMES at attempts + 1 — the count never runs backwards" do
    max = Dispatcher.max_attempts()
    id = stranded(max - 1)

    StuckDeliverySweeper.sweep(0)

    assert_receive {:webhook_post, "http://example.test/sweep"}
    refute_receive {:webhook_post, _}, 50
    row = Repo.get!(Delivery, id)
    assert row.status == "failed_giveup"
    assert row.attempts == max
  end

  test "a row that already spent its budget gives up without posting again" do
    max = Dispatcher.max_attempts()
    id = stranded(max)

    StuckDeliverySweeper.sweep(0)

    refute_receive {:webhook_post, _}, 50
    row = Repo.get!(Delivery, id)
    assert row.status == "failed_giveup"
    assert row.attempts == max
    assert row.last_error_text =~ "exhausted"
  end

  test "the Retry-After clamp sits strictly below the sweeper's stuck threshold" do
    assert Dispatcher.retry_after_max_ms() < StuckDeliverySweeper.stuck_after_seconds() * 1000
  end
end
