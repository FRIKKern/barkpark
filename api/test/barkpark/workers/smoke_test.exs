defmodule Barkpark.Workers.SmokeTest do
  use Barkpark.DataCase, async: true
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.Workers.Smoke

  test "perform/1 returns the echoed message" do
    assert {:ok, "hello"} = perform_job(Smoke, %{"echo" => "hello"})
  end

  test "perform/1 returns :ok for empty args" do
    assert :ok = perform_job(Smoke, %{})
  end

  test "enqueued job runs successfully via Oban.drain_queue/1" do
    {:ok, _job} = Oban.insert(Smoke.new(%{"echo" => "drained"}))

    assert %{success: 1, failure: 0, snoozed: 0} = Oban.drain_queue(queue: :default)
  end
end
