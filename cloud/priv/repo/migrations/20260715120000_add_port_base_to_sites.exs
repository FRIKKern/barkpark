defmodule BarkparkCloud.Repo.Migrations.AddPortBaseToSites do
  use Ecto.Migration

  # site-spawner W7 (charter D68): the node-slot runtime target needs a per-site
  # PORT PAIR for its blue/green slots (a long-running Node SSR process listens on
  # a loopback port and Caddy reverse-proxies to it — mirroring the instance
  # blue/green slot mechanism). `port_base` is the lowest-free EVEN base the
  # NodePortAllocator picks ONCE at node-site creation, scanning existing rows;
  # the blue slot listens on `port_base`, the green slot on `port_base + 1`. The
  # existing `sites.port` column stays the currently-LIVE serving port (whichever
  # slot the Caddy upstream points at after a switch).
  #
  # Nullable: static/container sites have no per-site process and keep port_base
  # NULL, so every existing row (all static/container today) is byte-identical.
  def change do
    alter table(:sites) do
      add :port_base, :integer
    end
  end
end
