defmodule Barkpark.Sso.FlowSweeper do
  @moduledoc """
  Deletes expired rows from `sso_flows`.

  A started OIDC or social sign-in stores one row that expires after 10
  minutes. The callback deletes the row it takes, and `Flow.put/3` deletes
  expired rows when the next sign-in starts. A sign-in that is started and
  never finished on an instance where nobody signs in afterwards stays in the
  table. This worker removes it. The row holds an encrypted PKCE verifier, so
  it should not outlive its expiry.

  It runs every 10 minutes from the Oban crontab on the `default` queue. One
  tick deletes at most `limit * @max_passes` rows; the oldest go first and the
  next tick takes the rest.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Barkpark.Sso.Flow

  @max_passes 20

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, sweep()}

  @doc "Run one tick. Returns `%{deleted: n, passes: p}`."
  @spec sweep(DateTime.t(), pos_integer()) :: %{
          deleted: non_neg_integer(),
          passes: pos_integer()
        }
  def sweep(now \\ DateTime.utc_now(), limit \\ 5_000), do: do_sweep(now, limit, 0, 1)

  defp do_sweep(now, limit, deleted, pass) do
    case Flow.sweep_expired_batch(now, limit) do
      0 ->
        log(deleted, pass)

      n when pass >= @max_passes ->
        log(deleted + n, pass)

      n ->
        do_sweep(now, limit, deleted + n, pass + 1)
    end
  end

  defp log(deleted, passes) do
    if deleted > 0,
      do: Logger.info("Sso.FlowSweeper removed #{deleted} expired sign-in flow(s)")

    %{deleted: deleted, passes: passes}
  end
end
