defmodule Barkpark.Repo.Migrations.AddIpSourceToUserSessions do
  use Ecto.Migration

  # `user_sessions.ip_address` is the only IP column in `api/`, so it IS the
  # login audit trail. Until now every mint path resolved it with its own
  # `conn.remote_ip |> :inet.ntoa()` one-liner, which behind the co-located
  # Caddy (`reverse_proxy localhost:4000`) is ALWAYS the loopback hop — every
  # row said 127.0.0.1 and the trail could not tell one actor from another.
  #
  # The addresses now come from `Barkpark.RateLimiter.client_ip_with_source/1`,
  # which resolves EITHER a client address derived from a trusted front's
  # x-forwarded-for chain OR the verified TCP peer. Both are honest, but they
  # are different claims, and a column that silently means two things cannot be
  # audited — so the row records which one it holds.
  #
  # NULLABLE ON PURPOSE, AND NOT BACKFILLED. A NULL means "written before this
  # boundary existed", which is exactly what is true of every existing row.
  # Stamping them `peer` would be a fabricated provenance: those values were
  # produced by code that never consulted a trust boundary at all, and the
  # whole point of the column is to let a reader distinguish a derived address
  # from an undecided one. Leaving them NULL keeps the pre-fix rows legible AS
  # pre-fix rows.
  #
  # The degradation this makes queryable is not hypothetical. In `cloud/` the
  # same loopback guard was a PERMANENT no-op — Docker's hairpin NAT rewrote
  # the peer to the bridge gateway, so it never fired and 48 of 49 rows carried
  # 172.18.0.1 while looking perfectly valid (`cch-w1-peer-ip-pin`). With this
  # column, "the boundary stopped firing" is `WHERE ip_source = 'peer'` on every
  # row instead of an inference someone has to make by comparing rows.
  def change do
    alter table(:user_sessions) do
      add :ip_source, :string
    end
  end
end
