defmodule BarkparkCloud.Sites.NodePortAllocator do
  @moduledoc """
  Allocates the per-site node-slot PORT BASE for a `kind=node` site (site-spawner
  W7, charter D68).

  A node site is served by a long-running Node SSR process behind a blue/green
  Caddy upstream flip — the same slot mechanism `deploy/instance-deploy.sh` uses
  for the instance itself. Each node site owns a PAIR of adjacent ports:

      blue  = port_base       (even)
      green = port_base + 1

  `allocate/0` picks the LOWEST-FREE EVEN base in `[7002, 7998]` by scanning the
  `port_base` of every existing site, so two node sites never collide on a slot.
  The base is assigned ONCE, at node-site creation, and never moves; `sites.port`
  (a separate column) stays the currently-LIVE serving port — whichever slot the
  Caddy upstream currently points at.

  `target_slot_port/1` returns the port of the IDLE slot for the next deploy: a
  node deploy builds+boots the new process on the idle slot, health-gates it, and
  only THEN flips the Caddy upstream to it (zero-downtime blue/green). The first
  deploy (no live port yet) targets blue.
  """

  import Ecto.Query, warn: false

  alias BarkparkCloud.Registry.Site
  alias BarkparkCloud.Repo

  # The loopback port window reserved for node slots. Lower bound is EVEN so the
  # base/base+1 pair always stays inside the window; stepping by 2 keeps every
  # base even (blue) with its odd neighbour (green) reserved implicitly.
  @port_min 7002
  @port_max 7998

  @doc "The inclusive `{min, max}` even-base window node slots are allocated from."
  @spec range() :: {pos_integer(), pos_integer()}
  def range, do: {@port_min, @port_max}

  @doc """
  The lowest-free EVEN port base in `[7002, 7998]`, scanning every existing
  site's `port_base`. Returns `{:ok, base}` or `{:error, :exhausted}` when every
  even base in the window is already taken.
  """
  @spec allocate() :: {:ok, pos_integer()} | {:error, :exhausted}
  def allocate do
    taken = taken_bases()

    @port_min..@port_max//2
    |> Enum.find(fn base -> not MapSet.member?(taken, base) end)
    |> case do
      nil -> {:error, :exhausted}
      base -> {:ok, base}
    end
  end

  @doc """
  The blue/green slot ports for a given base: `%{blue: base, green: base + 1}`.
  """
  @spec slot_ports(pos_integer()) :: %{blue: pos_integer(), green: pos_integer()}
  def slot_ports(base) when is_integer(base), do: %{blue: base, green: base + 1}

  @doc """
  The IDLE slot's port — where the NEXT node deploy builds+boots before the
  blue/green flip. The first deploy (no live port yet) targets blue (`port_base`);
  otherwise it targets whichever slot is NOT currently serving. Returns `nil` for
  a site with no allocated base (a non-node site).
  """
  @spec target_slot_port(Site.t()) :: pos_integer() | nil
  def target_slot_port(%Site{port_base: nil}), do: nil
  def target_slot_port(%Site{port_base: base, port: base}), do: base + 1
  def target_slot_port(%Site{port_base: base, port: port}) when port == base + 1, do: base
  def target_slot_port(%Site{port_base: base}), do: base

  # The set of port_base values already claimed by existing sites. A NULL
  # port_base (every static/container row) is excluded — only node sites hold one.
  defp taken_bases do
    from(s in Site, where: not is_nil(s.port_base), select: s.port_base)
    |> Repo.all()
    |> MapSet.new()
  end
end
