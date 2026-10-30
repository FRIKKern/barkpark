defmodule Barkpark.Tenancy.DatasetDeleteStallTest do
  @moduledoc """
  A big dataset delete must not hold the workspace (task-10608b4831a0e9b8).

  On guerrilla every write in the workspace waited for a running delete: each
  document's `Audit.emit/1` took the workspace's audit-chain advisory lock, and
  the one delete transaction held it until it ended. Real transactions here (no
  sandbox), so the lock is real.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Barkpark.{Audit, Auth, Content, Repo, Tenancy}
  alias Barkpark.Content.Document
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Dataset
  alias Barkpark.Tenancy.DatasetDelete.Runs
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag timeout: 900_000
  @endpoint BarkparkWeb.Endpoint

  @documents String.to_integer(System.get_env("DATASET_DELETE_STALL_DOCS", "400"))

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :infinity)
    tag = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "dsstall-#{tag}", name: "dsstall #{tag}"})
    {:ok, project} = Tenancy.create_project(ws, %{slug: "dsstall-p-#{tag}", name: "p"})

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :infinity)
      Application.delete_env(:barkpark, :dataset_delete_timeout_ms)

      for ds <- Tenancy.list_datasets(project),
          ds.slug != "production",
          do: Tenancy.delete_dataset(ds)

      Tenancy.delete_workspace(ws)
    end)

    %{ws: ws, project: project, opts: [workspace_id: ws.id, project_id: project.id]}
  end

  defp seed(slug, n, opts) do
    {:ok, _} = Content.upsert_schema(%{"name" => "post", "title" => "Post"}, slug, opts)

    1..n
    |> Enum.chunk_every(20)
    |> Enum.each(fn ids ->
      ops =
        for i <- ids,
            do: %{"create" => %{"_id" => "drafts.s#{i}", "_type" => "post", "title" => "t#{i}"}}

      {:ok, _} = Content.apply_mutations(ops, slug, opts)
    end)
  end

  defp documents(%Dataset{id: id}),
    do: Repo.aggregate(from(d in Document, where: d.dataset_id == ^id), :count)

  defp run_delete(project, wait_ms) do
    Runs.delete(project.id, "doomed", Tenancy.get_dataset(project, "doomed"), [], wait_ms)
  end

  # The run borrows its caller's connection, so a caller of its own keeps it
  # off the test's: the bystander writes need a connection the delete is not on.
  defp start_run(project) do
    parent = self()

    spawn_link(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :infinity)
      send(parent, {:started, run_delete(project, 0)})
      Process.sleep(:infinity)
    end)

    assert_receive {:started, :running}, 30_000
  end

  defp chain_held?(ws) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '50ms'")
      Audit.lock_chain!(ws.id)
    end)

    false
  rescue
    e in Postgrex.Error ->
      if e.postgres.code == :lock_not_available, do: true, else: reraise(e, __STACKTRACE__)
  end

  defp write_until_done(ws, project, opts, held \\ [], samples \\ []) do
    held = [chain_held?(ws) | held]
    started = System.monotonic_time(:millisecond)
    {:ok, _} = Content.create_document("post", %{"title" => "w"}, "bystander", opts)
    samples = [System.monotonic_time(:millisecond) - started | samples]
    Process.sleep(20)

    case run_delete(project, 0) do
      :running -> write_until_done(ws, project, opts, held, samples)
      result -> {result, held, samples}
    end
  end

  defp p95(samples),
    do: samples |> Enum.sort() |> Enum.at(max(ceil(length(samples) * 0.95) - 1, 0))

  defp run_pid(project) do
    [{_, {:running, pid}, _, _}] = :ets.lookup(Runs, {project.id, "doomed"})
    pid
  end

  test "a big delete finishes off the request and never stalls writes to another dataset",
       %{ws: ws, project: project, opts: opts} do
    seed("doomed", @documents, opts)
    seed("bystander", 1, opts)

    started = System.monotonic_time(:millisecond)
    start_run(project)
    {result, held, samples} = write_until_done(ws, project, opts)
    took = System.monotonic_time(:millisecond) - started
    held = Enum.count(held, & &1)

    IO.puts(
      "delete #{@documents} docs: #{took} ms; #{length(samples)} bystander writes, " <>
        "p95 #{p95(samples)} ms, max #{Enum.max(samples)} ms; audit chain held at " <>
        "#{held} of #{length(samples)} probes"
    )

    assert {:ok, %{documents: @documents}} = result
    assert Tenancy.get_dataset(project, "doomed") == nil
    assert length(samples) >= 5
    assert held / length(samples) < 0.25
  end

  defp edit_until_stopped(opts, parent, edits \\ 0) do
    receive do
      :stop -> send(parent, {:edits, edits})
    after
      0 ->
        ops =
          for i <- 1..120 |> Enum.take_random(3) |> Enum.sort(:desc),
              do: %{"patch" => %{"id" => "drafts.s#{i}", "set" => %{"title" => "edited"}}}

        Content.apply_mutations(ops, "doomed", opts)
        edit_until_stopped(opts, parent, edits + 1)
    end
  end

  test "edits racing the walk wait for the delete instead of deadlocking it",
       %{project: project, opts: opts} do
    seed("doomed", 120, opts)
    parent = self()

    editor =
      spawn_link(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :infinity)
        edit_until_stopped(opts, parent)
      end)

    Process.sleep(200)
    result = Tenancy.delete_dataset(Tenancy.get_dataset(project, "doomed"))
    send(editor, :stop)
    assert_receive {:edits, edits}, 30_000

    assert {:ok, %{documents: 120}} = result
    assert edits > 0
  end

  test "a delete over its time budget rolls back whole and answers a typed error",
       %{project: project, opts: opts} do
    seed("doomed", 100, opts)
    dataset = Tenancy.get_dataset(project, "doomed")
    Application.put_env(:barkpark, :dataset_delete_timeout_ms, 100)

    assert {:error, {:delete_failed, :timeout}} = Tenancy.delete_dataset(dataset)

    :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :infinity)
    assert %Dataset{} = Tenancy.get_dataset(project, "doomed")
    assert documents(dataset) == 100
  end

  test "a run killed mid-delete answers 503, leaves the dataset whole, and the next DELETE finishes it",
       %{ws: ws, project: project, opts: opts} do
    seed("doomed", 200, opts)
    dataset = Tenancy.get_dataset(project, "doomed")
    raw = "dsstall-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "dsstall", "production", ~w(read write admin))
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner", "api_token")
    parent = self()

    spawn_link(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :infinity)

      conn =
        BarkparkWeb.ConnCase.scoped_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> delete("/w/#{ws.slug}/p/#{project.slug}/v1/datasets/doomed")

      send(parent, {:answered, conn})
      Process.sleep(:infinity)
    end)

    Process.sleep(1_000)
    pid = run_pid(project)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert_receive {:answered, conn}, 10_000

    assert %{
             "error" => %{
               "code" => "storage_unavailable",
               "details" => %{"reason" => "dataset_delete_interrupted"}
             }
           } = json_response(conn, 503)

    assert documents(dataset) == 200
    assert {:ok, %{documents: 200}} = run_delete(project, 300_000)
    assert Tenancy.get_dataset(project, "doomed") == nil
  end
end
