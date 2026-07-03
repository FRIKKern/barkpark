defmodule BarkparkCloud.Registry.HetznerCatalog do
  @moduledoc """
  The Hetzner action catalog — the control-plane proxy's ALLOWLIST, as pure
  data (epic charter decision 3). Every `/v1/hetzner/*` proxy call derives its
  upstream path from an entry in THIS list; a path not produced from a catalog
  template is unreachable by construction. No prefix matching, no free-form
  passthrough — `fetch/2` is an exact `(resource, verb)` lookup.

  ## Entry shape

      %{
        resource: :servers,                       # the Hetzner resource kind
        verb:     :list,                          # what the action does
        method:   :get | :post | :delete,         # upstream HTTP method
        path:     "/v1/servers/{id}/actions/reboot",  # EXACT upstream template
        tier:     :read | :mutate | :destroy,     # danger tier (charter dec. 5)
        params:   ["id"]                          # allowed body/query/path keys
      }

  Paths are templates relative to the Hetzner Cloud API host — the upstream
  host itself lives at the proxy call site, never in (or served from) the
  catalog. `{id}` is the only placeholder form.

  ## Tiers — what ships when

  * `:read` — served NOW by `GET /v1/hetzner/overview` (wave 1, this module's
    `read_entries/0`). Free of confirmation.
  * `:mutate` — DECLARED here, not yet routed. Wave 3 wires them through the
    proxy with an audit event per call (charter decision 3).
  * `:destroy` — declared, not routed. Every destroy entry carries a
    `"confirm"` param: the server-verified typed-resource-name echo slot the
    wave-3 proxy will demand before touching the upstream (charter decision 5).

  This module is deliberately PURE — no HTTP, no config, no deps — so the
  allowlist itself is unit-testable without a network and auditable at a
  glance.
  """

  @type tier :: :read | :mutate | :destroy
  @type entry :: %{
          resource: atom(),
          verb: atom(),
          method: :get | :post | :delete,
          path: String.t(),
          tier: tier(),
          params: [String.t()]
        }

  # ── The nine overview read kinds (charter envelope `resources` keys) ──
  # `params` names the allowed QUERY keys for reads; the overview fan-out pins
  # `type=backup` on the images read (Hetzner models backups as images).
  @reads [
    %{
      resource: :servers,
      verb: :list,
      method: :get,
      path: "/v1/servers",
      tier: :read,
      params: []
    },
    %{
      resource: :volumes,
      verb: :list,
      method: :get,
      path: "/v1/volumes",
      tier: :read,
      params: []
    },
    %{
      resource: :networks,
      verb: :list,
      method: :get,
      path: "/v1/networks",
      tier: :read,
      params: []
    },
    %{
      resource: :firewalls,
      verb: :list,
      method: :get,
      path: "/v1/firewalls",
      tier: :read,
      params: []
    },
    %{
      resource: :load_balancers,
      verb: :list,
      method: :get,
      path: "/v1/load_balancers",
      tier: :read,
      params: []
    },
    %{
      resource: :floating_ips,
      verb: :list,
      method: :get,
      path: "/v1/floating_ips",
      tier: :read,
      params: []
    },
    %{
      resource: :primary_ips,
      verb: :list,
      method: :get,
      path: "/v1/primary_ips",
      tier: :read,
      params: []
    },
    %{
      resource: :dns_zones,
      verb: :list,
      method: :get,
      path: "/v1/zones",
      tier: :read,
      params: []
    },
    %{
      resource: :backups,
      verb: :list,
      method: :get,
      path: "/v1/images",
      tier: :read,
      params: ["type"]
    }
  ]

  # ── Mutations (wave 3 — declared, NOT routed this wave) ──
  # Single-confirm tier. `create_snapshot` maps to Hetzner's create_image
  # action with type=snapshot.
  @mutations [
    %{
      resource: :servers,
      verb: :reboot,
      method: :post,
      path: "/v1/servers/{id}/actions/reboot",
      tier: :mutate,
      params: ["id"]
    },
    %{
      resource: :servers,
      verb: :poweron,
      method: :post,
      path: "/v1/servers/{id}/actions/poweron",
      tier: :mutate,
      params: ["id"]
    },
    %{
      resource: :servers,
      verb: :poweroff,
      method: :post,
      path: "/v1/servers/{id}/actions/poweroff",
      tier: :mutate,
      params: ["id"]
    },
    %{
      resource: :servers,
      verb: :create_snapshot,
      method: :post,
      path: "/v1/servers/{id}/actions/create_image",
      tier: :mutate,
      params: ["id", "description", "type"]
    }
  ]

  # ── Destroys (wave 3 — declared, NOT routed this wave) ──
  # Every entry carries "confirm": the typed-resource-name echo the proxy will
  # verify server-side before the upstream DELETE (charter decision 5).
  @destroys [
    %{
      resource: :servers,
      verb: :delete,
      method: :delete,
      path: "/v1/servers/{id}",
      tier: :destroy,
      params: ["id", "confirm"]
    },
    %{
      resource: :volumes,
      verb: :delete,
      method: :delete,
      path: "/v1/volumes/{id}",
      tier: :destroy,
      params: ["id", "confirm"]
    },
    %{
      resource: :networks,
      verb: :delete,
      method: :delete,
      path: "/v1/networks/{id}",
      tier: :destroy,
      params: ["id", "confirm"]
    },
    %{
      resource: :firewalls,
      verb: :delete,
      method: :delete,
      path: "/v1/firewalls/{id}",
      tier: :destroy,
      params: ["id", "confirm"]
    },
    %{
      resource: :load_balancers,
      verb: :delete,
      method: :delete,
      path: "/v1/load_balancers/{id}",
      tier: :destroy,
      params: ["id", "confirm"]
    },
    %{
      resource: :floating_ips,
      verb: :delete,
      method: :delete,
      path: "/v1/floating_ips/{id}",
      tier: :destroy,
      params: ["id", "confirm"]
    },
    %{
      resource: :primary_ips,
      verb: :delete,
      method: :delete,
      path: "/v1/primary_ips/{id}",
      tier: :destroy,
      params: ["id", "confirm"]
    },
    %{
      resource: :dns_zones,
      verb: :delete,
      method: :delete,
      path: "/v1/zones/{id}",
      tier: :destroy,
      params: ["id", "confirm"]
    },
    %{
      resource: :backups,
      verb: :delete,
      method: :delete,
      path: "/v1/images/{id}",
      tier: :destroy,
      params: ["id", "confirm"]
    }
  ]

  @catalog @reads ++ @mutations ++ @destroys

  @doc "The full catalog — every action the proxy will EVER allow, all tiers."
  @spec catalog() :: [entry()]
  def catalog, do: @catalog

  @doc """
  The `:read`-tier entries — the only tier the proxy serves this wave. One
  entry per charter overview kind, in envelope key order.
  """
  @spec read_entries() :: [entry()]
  def read_entries, do: Enum.filter(@catalog, &(&1.tier == :read))

  @doc """
  Exact-match lookup by `(resource, verb)` — the proxy's ONLY way to obtain an
  upstream path. Returns `{:ok, entry}` or `:error`. No prefix matching, no
  string coercion: anything but the exact atom pair misses.
  """
  @spec fetch(atom(), atom()) :: {:ok, entry()} | :error
  def fetch(resource, verb) do
    case Enum.find(@catalog, &(&1.resource == resource and &1.verb == verb)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end
end
