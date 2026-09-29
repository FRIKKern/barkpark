defmodule Barkpark.ObanJobPoolTest do
  @moduledoc """
  `jpf-bl-oban-pool-partition`: an Oban job body runs on the job pool
  (`Barkpark.Repo.Jobs`), not on the pool HTTP uses, and the job pool is in the
  supervision tree exactly where Oban needs it. The arithmetic behind the pool
  size is pinned in test/config/oban_pool_budget_test.exs; the load proof is in
  the PR (scripts/mutate-load before/after).
  """
  # NOT async: flips the global `:oban_pool_size` env and starts a REAL named
  # pool (the sandbox cannot be the second pool — see Barkpark.Repo).
  use Barkpark.DataCase, async: false

  alias Barkpark.Application, as: App
  alias Barkpark.Repo

  defmodule ProbeWorker do
    use Oban.Worker, queue: :default

    @impl true
    def perform(%Oban.Job{args: %{"reply_to" => reply_to}}) do
      %{rows: [[backend]]} = Repo.query!("select pg_backend_pid()")

      send(
        :erlang.list_to_pid(String.to_charlist(reply_to)),
        {:job_ran, Repo.get_dynamic_repo(), backend}
      )

      :ok
    end
  end

  setup do
    # Restore by FETCH, not get: in :test the key is ABSENT, and put_env(k, nil)
    # would leave it present-as-nil for every later test (it did — CI order
    # reddened runtime_oban_pool_size_test's `== 0` with nil).
    prev = Application.fetch_env(:barkpark, :oban_pool_size)

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(:barkpark, :oban_pool_size, value)
        :error -> Application.delete_env(:barkpark, :oban_pool_size)
      end
    end)

    :ok
  end

  defp run_probe_job do
    previous = Repo.get_dynamic_repo()

    try do
      reply_to = self() |> :erlang.pid_to_list() |> to_string()
      assert :ok = Oban.Testing.perform_job(ProbeWorker, %{"reply_to" => reply_to}, repo: Repo)
      assert_receive {:job_ran, repo, backend}
      {repo, backend}
    after
      # `perform_job/3` runs the executor in THIS process, so the router's
      # put_dynamic_repo/1 lands here; put it back for the rest of the test.
      Repo.put_dynamic_repo(previous)
    end
  end

  defp web_backend do
    %{rows: [[backend]]} = Repo.query!("select pg_backend_pid()")
    backend
  end

  describe "the router" do
    test "a job body runs on the job pool — a different Postgres backend than the web pool's" do
      Application.put_env(:barkpark, :oban_pool_size, 1)
      [spec] = Repo.job_pool_child_specs()
      start_supervised!(spec)

      {repo, job_backend} = run_probe_job()

      assert repo == Repo.job_pool_name()
      refute job_backend == web_backend()
    end

    test "control: with no job pool running, the job stays on the shared repo" do
      refute Process.whereis(Repo.job_pool_name())

      {repo, job_backend} = run_probe_job()

      assert repo == Repo
      assert job_backend == web_backend()
    end

    test "the handler is attached to Oban's job-start event" do
      router = &Repo.route_job_to_job_pool/4
      handlers = :telemetry.list_handlers([:oban, :job, :start])

      assert Enum.any?(handlers, fn h -> h.function == router end),
             "no [:oban, :job, :start] handler routes job bodies onto the job pool"
    end
  end

  describe "the job pool's child spec" do
    test "a key present with value nil reads as 0 and starts no pool" do
      Application.put_env(:barkpark, :oban_pool_size, nil)
      assert Repo.job_pool_size() == 0
      assert Repo.job_pool_child_specs() == []
    end

    test "size 0 (the :test default) starts no pool" do
      Application.put_env(:barkpark, :oban_pool_size, 0)
      assert Repo.job_pool_child_specs() == []
    end

    test "a real pool, sized from config, with job-side timing, never the sandbox" do
      Application.put_env(:barkpark, :oban_pool_size, 4)
      [%{id: id, start: {Repo, :start_link, [opts]}}] = Repo.job_pool_child_specs()

      assert id == Repo.job_pool_name()
      assert opts[:name] == Repo.job_pool_name()
      assert opts[:pool_size] == 4
      assert opts[:pool] == DBConnection.ConnectionPool
      assert opts[:queue_target] == 10_000
      assert opts[:queue_interval] == 60_000
      assert opts[:timeout] == 60_000
    end
  end

  describe "placement in the supervision tree" do
    defp children(mode) do
      App.child_specs([], [repo: Repo], [], [], mode)
    end

    defp job_pool_index(specs),
      do: Enum.find_index(specs, &match?(%{id: id} when id == Repo.Jobs, &1))

    defp oban_index(specs), do: Enum.find_index(specs, &match?({Oban, _}, &1))

    test ":full starts the job pool immediately before Oban" do
      Application.put_env(:barkpark, :oban_pool_size, 4)
      specs = children(:full)

      assert job_pool_index(specs) != nil
      assert job_pool_index(specs) + 1 == oban_index(specs)
    end

    test ":seed (Oban inert) and :one_shot (no Oban) start no job pool" do
      Application.put_env(:barkpark, :oban_pool_size, 4)

      assert job_pool_index(children(:seed)) == nil
      assert job_pool_index(children(:one_shot)) == nil
    end

    test "size 0 leaves the :full list without a job pool" do
      Application.put_env(:barkpark, :oban_pool_size, 0)
      assert job_pool_index(children(:full)) == nil
      assert oban_index(children(:full)) != nil
    end
  end
end
