defmodule BarkparkCloud.Registry.InstanceApiCatalog do
  @moduledoc """
  The instance-API proxy's ALLOWLIST, as pure data (epic charter decision D46 —
  the `HetznerCatalog` pattern applied to a managed instance's OWN HTTP API).

  The control plane never free-form-proxies to a customer's Barkpark instance:
  every `/v1/barkparks/:id/api/*` router match names ONE catalog capability, and
  the upstream path is DERIVED from that capability's template by exact lookup. A
  path not produced from a catalog template is unreachable by construction — no
  prefix matching, no passthrough. `fetch/1` is an exact capability-id lookup and
  `render_path/2` is the ONLY way to turn a template into a concrete path.

  ## Catalog v1 — webhooks only

      capability          method  upstream template                                        tier
      ─────────────────   ──────  ───────────────────────────────────────────────────────  ──────
      webhook.list        GET     /v1/webhooks/{dataset}                                    :read
      webhook.show        GET     /v1/webhooks/{dataset}/{id}                               :read
      webhook.create      POST    /v1/webhooks/{dataset}                                    :mutate
      webhook.update      PUT     /v1/webhooks/{dataset}/{id}                               :mutate
      webhook.delete      DELETE  /v1/webhooks/{dataset}/{id}                               :mutate
      webhook.rotate      POST    /v1/webhooks/{dataset}/{id}/rotate                        :mutate
      webhook.deliveries  GET     /v1/webhooks/{dataset}/{id}/deliveries                    :read
      webhook.replay      POST    /v1/webhooks/{dataset}/{id}/deliveries/{event_id}/replay  :mutate

  `webhook.update` also serves enable/disable — the GUI/CLI PUTs `{active: bool}`
  through the SAME capability rather than a bespoke toggle endpoint.

  ## Tiers — and why there is NO :destroy tier here (charter decision D46)

  The instance catalog v1 has exactly two tiers:

    * `:read`   — free, no side effect (list / show / deliveries).
    * `:mutate` — a single-confirm write. **`webhook.delete` is `:mutate`, not
      `:destroy`.** A webhook is recreatable config (URL + events + a fresh
      secret), not durable data like a server or a volume, so its deletion does
      not earn the typed-resource-name ceremony the Hetzner catalog reserves for
      `:destroy`. The GUI adds a typed-confirm affordance later; the tier stays
      `:mutate`. There are intentionally ZERO `:destroy` entries here — the
      catalog tests pin that as a tripwire against a copy-paste of the Hetzner
      grammar.

  ## Response envelope — ONE contract, two surfaces (charter decision D51)

  The proxy normalises every instance reply into a uniform envelope so the future
  GUI webhooks tab and the `bp` CLI twin read exactly ONE shape:

      success   %{"ok" => true, "resource" => "webhook", "data" => <instance payload>}
      failure   %{"ok" => false, "error" => %{"code" => "<slug>", ...}}

  Failure codes the proxy emits (honest degradation — never a hang, never a raw
  exception):

    * `not_live`               — the instance is still provisioning (no url yet); HTTP 409.
    * `no_admin_token`         — a pre-feature instance row has no stored admin token; HTTP 404.
    * `decrypt_failed`         — the stored admin-token ciphertext is tampered; HTTP 500.
    * `instance_unreachable`   — connect failure / bounded-timeout; HTTP 502, with `"reachable" => false`.
    * `capability_unavailable` — the instance is too OLD for a C5 endpoint (an
      upstream 404 on rotate / deliveries / replay — the three routes C5 adds
      to the instance API; the CRUD routes predate C4 and never map this way);
      HTTP 502, with a `"hint"` to update the instance.
    * `upstream_error`         — any other non-2xx from the instance, relayed
      with the instance's OWN status so a caller can tell 404-not-found from
      422-invalid.

  This module is deliberately PURE — no HTTP, no DB, no config — so the allowlist
  is unit-testable without a network and auditable at a glance. The router
  (`BarkparkCloud.Web.Router`) owns admin-token custody, the bounded-timeout
  relay, the audit write on every `:mutate`, and the envelope normalisation.
  """

  @type tier :: :read | :mutate
  @type entry :: %{
          capability: atom(),
          method: :get | :post | :put | :delete,
          path: String.t(),
          tier: tier(),
          params: [String.t()]
        }

  # `params` names the placeholder keys the path template consumes (`{dataset}`,
  # `{id}`, `{event_id}`). `render_path/2` substitutes only these and refuses a
  # template that references a key the entry did not declare.
  @catalog [
    %{
      capability: :"webhook.list",
      method: :get,
      path: "/v1/webhooks/{dataset}",
      tier: :read,
      params: ["dataset"]
    },
    %{
      capability: :"webhook.show",
      method: :get,
      path: "/v1/webhooks/{dataset}/{id}",
      tier: :read,
      params: ["dataset", "id"]
    },
    %{
      capability: :"webhook.create",
      method: :post,
      path: "/v1/webhooks/{dataset}",
      tier: :mutate,
      params: ["dataset"]
    },
    %{
      capability: :"webhook.update",
      method: :put,
      path: "/v1/webhooks/{dataset}/{id}",
      tier: :mutate,
      params: ["dataset", "id"]
    },
    %{
      capability: :"webhook.delete",
      method: :delete,
      path: "/v1/webhooks/{dataset}/{id}",
      tier: :mutate,
      params: ["dataset", "id"]
    },
    %{
      capability: :"webhook.rotate",
      method: :post,
      path: "/v1/webhooks/{dataset}/{id}/rotate",
      tier: :mutate,
      params: ["dataset", "id"]
    },
    %{
      capability: :"webhook.deliveries",
      method: :get,
      path: "/v1/webhooks/{dataset}/{id}/deliveries",
      tier: :read,
      params: ["dataset", "id"]
    },
    %{
      capability: :"webhook.replay",
      method: :post,
      path: "/v1/webhooks/{dataset}/{id}/deliveries/{event_id}/replay",
      tier: :mutate,
      params: ["dataset", "id", "event_id"]
    }
  ]

  @placeholder ~r/\{([a-z_]+)\}/

  # The only characters a substituted value may carry — the RFC 3986 unreserved
  # set. Everything else (`/`, `?`, `#`, `%`, whitespace, …) could reshape the
  # upstream URL's path, query, or fragment and is refused by `render_path/2`.
  @safe_value ~r/^[A-Za-z0-9._~-]+$/

  @doc "The full catalog — every capability the proxy will EVER dispatch, all tiers."
  @spec catalog() :: [entry()]
  def catalog, do: @catalog

  @doc """
  Exact-match lookup by capability id (e.g. `:"webhook.list"`). Returns
  `{:ok, entry}` or `:error`. No prefix matching, no string coercion: anything
  but the exact atom misses — a route can only reach an upstream template through
  a capability that is spelled EXACTLY right in this list.
  """
  @spec fetch(atom()) :: {:ok, entry()} | :error
  def fetch(capability) do
    case Enum.find(@catalog, &(&1.capability == capability)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc """
  Render a catalog entry's path template into a concrete upstream path by
  substituting `{placeholder}`s from `values` (a `%{"key" => binary}` map).

  Returns `{:ok, path}`, or `{:error, {:missing_param, key}}` when a required
  placeholder has no non-empty binary value, `{:error, {:bad_param, key}}` when
  the value carries a character that could reshape the URL, or
  `{:error, {:unknown_param, key}}` when a template references a key the entry
  did not declare in `:params` (a guard against a mis-authored template
  smuggling a substitution past the allowlist).

  A substituted value must match `^[A-Za-z0-9._~-]+$` — the RFC 3986
  unreserved set. Anything else (`/` traversal, `?` query injection,
  `#` fragment, `%` double-encoding, whitespace) is rejected as `:bad_param`:
  a value must never be able to reshape the path, the query string, or the
  fragment of the upstream URL. Dataset slugs, UUIDs, and prefixed ids
  (`wh_42`, `evt_9`) all fit; nothing hostile does.
  """
  @spec render_path(entry(), %{optional(String.t()) => term()}) ::
          {:ok, String.t()}
          | {:error, {:missing_param | :bad_param | :unknown_param, String.t()}}
  def render_path(%{path: template, params: allowed}, values) when is_map(values) do
    template
    |> placeholders()
    |> Enum.reduce_while({:ok, template}, fn key, {:ok, acc} ->
      cond do
        key not in allowed ->
          {:halt, {:error, {:unknown_param, key}}}

        true ->
          case Map.get(values, key) do
            v when is_binary(v) and v != "" ->
              if Regex.match?(@safe_value, v),
                do: {:cont, {:ok, String.replace(acc, "{#{key}}", v)}},
                else: {:halt, {:error, {:bad_param, key}}}

            _ ->
              {:halt, {:error, {:missing_param, key}}}
          end
      end
    end)
  end

  @doc "The distinct placeholder keys a template references, in first-seen order."
  @spec placeholders(String.t()) :: [String.t()]
  def placeholders(template) do
    @placeholder
    |> Regex.scan(template, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end
end
