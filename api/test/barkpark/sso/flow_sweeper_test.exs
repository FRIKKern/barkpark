defmodule Barkpark.Sso.FlowSweeperTest do
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Sso.Flow
  alias Barkpark.Sso.FlowSweeper, as: Sweeper

  setup do
    Repo.delete_all(from(f in Flow))
    :ok
  end

  # Flow.put/3 deletes expired rows itself, so start every flow first and
  # back-date afterwards.
  defp start!(state), do: :ok = Flow.put("oidc:test", state, %{nonce: "n", code_verifier: "v"})

  defp expire!(state, expires_at) do
    h = :crypto.hash(:sha256, state)
    from(f in Flow, where: f.state_hash == ^h) |> Repo.update_all(set: [expires_at: expires_at])
  end

  defp count, do: Repo.aggregate(from(f in Flow), :count)

  test "a tick deletes expired flows and keeps a live one" do
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    Enum.each(["expired-1", "expired-2", "live"], &start!/1)
    expire!("expired-1", past)
    expire!("expired-2", past)

    assert %{deleted: 2} = Sweeper.sweep()
    assert count() == 1
    assert {:ok, _} = Flow.take("oidc:test", "live")
  end

  test "a tick over an empty table deletes nothing" do
    assert %{deleted: 0, passes: 1} = Sweeper.sweep()
  end

  test "a backlog deeper than one batch is finished in several passes" do
    past = DateTime.add(DateTime.utc_now(), -3600, :second)
    for n <- 1..5, do: start!("deep-#{n}")
    for n <- 1..5, do: expire!("deep-#{n}", DateTime.add(past, n, :second))

    assert Flow.sweep_expired_batch(DateTime.utc_now(), 2) == 2
    assert %{deleted: 3, passes: 3} = Sweeper.sweep(DateTime.utc_now(), 2)
    assert count() == 0
  end

  test "the sweeper is in the Oban crontab" do
    crontab =
      Application.get_env(:barkpark, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value([], fn
        {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
        _ -> nil
      end)

    assert Enum.any?(crontab, &match?({_, Sweeper}, &1))
  end
end
