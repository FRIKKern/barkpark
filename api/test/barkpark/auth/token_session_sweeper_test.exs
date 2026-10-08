defmodule Barkpark.Auth.TokenSessionSweeperTest do
  @moduledoc """
  task-781cc7f06c5f4335 (ruling #16 rework half follow-up to
  task-57f23825b18ab55d) — the GC for `token_sessions`.

  Mirrors `Barkpark.PreviewToken.SweeperTest`'s shape: a worker that existed
  only as a compiled module and nothing in `lib/`, the Oban crontab, or the
  supervision tree called it would leave `token_sessions` append-only in
  production — one row per browser token sign-in that is never explicitly
  signed out of, each holding a Cloak-encrypted raw bearer.

  These tests pin:

    * the sweep is BOUNDED per statement (`sweep_token_sessions_batch/1`), so
      a cold first pass over a never-swept table is not one giant transaction;
    * it is SCHEDULED — the crontab entry exists and names this worker (an
      unwired worker reads exactly like a wired one from its own tests);
    * it reaps BOTH eligible arms (expired, and flagged-revoked-but-not-
      deleted), and leaves a live row alone.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Auth.TokenSession
  alias Barkpark.Auth.TokenSessionSweeper, as: Sweeper
  alias Barkpark.Repo

  defp insert_token!(raw) do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "sweeper-test",
        dataset: "test",
        permissions: ["read"]
      })
      |> Repo.insert()

    token
  end

  # Mints a real token_sessions row via create_token_session/2, then back-dates
  # its expires_at by `age_seconds` (so it reads as expired by `age_seconds -
  # the default validity window`, same technique preview_token_sweeper_test.exs
  # uses for its own table).
  defp insert_session!(label, opts \\ []) do
    raw = "sweeper-session-#{label}-" <> Ecto.UUID.generate()
    token = insert_token!(raw)
    {:ok, session_id} = Auth.create_token_session(raw, token)
    hash = TokenSession.hash_token(session_id)

    set =
      []
      |> maybe_put(:expires_at, Keyword.get(opts, :expires_at))
      |> maybe_put(:revoked_at, Keyword.get(opts, :revoked_at))

    if set != [] do
      from(s in TokenSession, where: s.session_hash == ^hash) |> Repo.update_all(set: set)
    end

    session_id
  end

  defp maybe_put(set, _key, nil), do: set
  defp maybe_put(set, key, value), do: Keyword.put(set, key, value)

  defp count, do: Repo.aggregate(from(s in TokenSession), :count)

  defp session_present?(session_id) do
    hash = TokenSession.hash_token(session_id)
    Repo.exists?(from(s in TokenSession, where: s.session_hash == ^hash))
  end

  setup do
    # This suite counts rows in a table other cases also write, so start from
    # a known floor — same convention as preview_token_sweeper_test.exs.
    Repo.delete_all(from(s in TokenSession))
    :ok
  end

  describe "Auth.sweep_token_sessions_batch/1 — bounded by construction" do
    test "one statement takes at most :sweep_batch_limit, oldest expires_at first" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      for n <- 1..5,
          do: insert_session!("bounded-#{n}", expires_at: DateTime.add(past, n, :second))

      prev = Application.get_env(:barkpark, :token_session, [])
      Application.put_env(:barkpark, :token_session, Keyword.put(prev, :sweep_batch_limit, 2))
      on_exit(fn -> Application.put_env(:barkpark, :token_session, prev) end)

      assert Auth.sweep_token_sessions_batch() == 2
      assert count() == 3
    end

    test "returns 0 over an empty backlog — the loop terminator" do
      assert Auth.sweep_token_sessions_batch() == 0
    end

    test "leaves a live, unexpired, unrevoked row alone" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      insert_session!("live", expires_at: future)

      assert Auth.sweep_token_sessions_batch() == 0
      assert count() == 1
    end

    test "reaps a flagged-revoked row even when NOT expired" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      insert_session!("flagged-revoked", expires_at: future, revoked_at: now)

      assert Auth.sweep_token_sessions_batch() == 1
      assert count() == 0
    end
  end

  describe "TokenSessionSweeper.sweep/1 — the worker" do
    test "a tick removes expired and flagged-revoked rows, leaves a live one" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      expired = insert_session!("expired", expires_at: past)
      revoked = insert_session!("revoked-flag", expires_at: future, revoked_at: now)
      live = insert_session!("live")

      assert %{deleted: 2} = Sweeper.sweep()

      refute session_present?(expired)
      refute session_present?(revoked)
      assert session_present?(live)
    end

    test "a tick over an empty backlog is a no-op, not an error" do
      assert %{deleted: 0, passes: 1} = Sweeper.sweep()
    end

    test "the loop finishes a backlog deeper than one batch" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      for n <- 1..5,
          do: insert_session!("deep-#{n}", expires_at: DateTime.add(past, n, :second))

      prev = Application.get_env(:barkpark, :token_session, [])
      Application.put_env(:barkpark, :token_session, Keyword.put(prev, :sweep_batch_limit, 2))
      on_exit(fn -> Application.put_env(:barkpark, :token_session, prev) end)

      # 2 + 2 + 1 deleting passes, plus the terminating empty one.
      assert %{deleted: 5, passes: 4} = Sweeper.sweep()
      assert count() == 0
    end
  end

  # THE WIRE. A worker nothing schedules is the defect this row is about.
  # Assert the SCHEDULE by reading the same crontab Oban is configured with, so
  # deleting the entry reds here — the module's own tests cannot tell a wired
  # worker from an unwired one.
  test "the sweeper is actually scheduled in the Oban crontab" do
    crontab =
      Application.get_env(:barkpark, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value([], fn
        {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
        _ -> nil
      end)

    assert Enum.any?(crontab, fn
             {_expr, Sweeper} -> true
             {_expr, Sweeper, _opts} -> true
             _ -> false
           end),
           "Barkpark.Auth.TokenSessionSweeper is not in the crontab — token_sessions grows forever again"
  end
end
