defmodule BarkparkCloud.Workers.OAuthStateReaperTest do
  @moduledoc """
  cch-w2 — the `oauth_states` prune, wiring included.

  Both OAuth GET legs `Repo.insert!` a row per hit on an UNAUTHENTICATED route
  and the only DELETE in `cloud/` was `consume_state/2`'s single REDEEMED row, so
  every abandoned consent screen (and every scanner hit) left a permanent row.
  This proves the sweep actually mutates the DB through the real Sandbox, that it
  is idempotent, and — the part that usually rots — that the worker is genuinely
  SCHEDULED rather than merely written.

  `async: true` is safe because Oban runs in `:manual` mode (config/test.exs): no
  background poller touches the sandboxed connection, and `perform_job/2` runs
  the worker synchronously inside this test's own transaction.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.OAuth
  alias BarkparkCloud.Workers.OAuthStateReaper

  defp lapse!(provider) do
    row = Repo.one!(from(s in OAuth.State, where: s.provider == ^provider))

    Repo.update_all(
      from(s in OAuth.State, where: s.id == ^row.id),
      set: [
        expires_at:
          DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)
      ]
    )

    row
  end

  test "perform/1 reaps expired state rows and leaves live ones alone" do
    OAuth.mint_state("github")
    OAuth.mint_state("google")
    lapse!("github")

    assert {:ok, %{reaped: 1}} = perform_job(OAuthStateReaper, %{})
    assert Repo.aggregate(OAuth.State, :count) == 1
    assert Repo.one!(OAuth.State).provider == "google"
  end

  test "a sweep with nothing to do is a clean no-op (idempotent)" do
    OAuth.mint_state("github")

    assert {:ok, %{reaped: 0}} = perform_job(OAuthStateReaper, %{})
    assert {:ok, %{reaped: 0}} = perform_job(OAuthStateReaper, %{})
    assert Repo.aggregate(OAuth.State, :count) == 1
  end

  test "there is NO grace window — a row is reaped the moment it is unredeemable" do
    # Deliberate divergence from the visually-similar AgentRetentionWorker, which
    # DOES keep a day-scale grace. Its rows stay readable evidence past their
    # retention date; a lapsed nonce is the opposite — `consume_state/2` filters
    # `expires_at > now`, so the redemption path has ALREADY written this row off.
    # Keeping it would preserve nothing but the row count.
    state = OAuth.mint_state("github")
    lapse!("github")

    # Prove the write-off first: this state can no longer be redeemed at all,
    # even though its signature is intact and its payload `exp` is still live —
    # `consume_state/2`'s `expires_at > now` filter is what rejects it.
    assert {:error, :invalid_state} = OAuth.verify_state(state, "github")

    assert {:ok, %{reaped: 1}} = perform_job(OAuthStateReaper, %{})
    assert Repo.aggregate(OAuth.State, :count) == 0
  end

  test "the worker is actually SCHEDULED — per-minute on :maintenance, with dedup" do
    # A worker nobody runs prunes nothing. Assert the crontab entry, not just the
    # module's existence.
    crontab =
      :barkpark_cloud
      |> Application.get_env(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
        _ -> nil
      end)

    assert {"* * * * *", OAuthStateReaper} in crontab

    # Rides the cheap queue beside its twin DeviceAuthReaper, and collapses a
    # slow sweep plus the next tick into one in-flight job.
    assert OAuthStateReaper.__opts__()[:queue] == :maintenance
    assert OAuthStateReaper.__opts__()[:unique][:period] == 60
  end
end
