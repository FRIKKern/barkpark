defmodule BarkparkCloud.Web.InternalPerimeter do
  @moduledoc """
  dr-w24-bl-internal-write-route-is-publicly-reachable — the NETWORK factor in
  front of the `/v1/internal/*` fleet-ops surface.

  MEASURED on prod (the row): an unauthenticated POST from a laptop to
  `https://barkpark.cloud/v1/internal/platform-deliveries` answered **401, not
  404**. The whole family is reachable from the open internet and one shared
  bearer (`WORKER_TOKEN`) is the only thing between it and the delivery record —
  a single-secret perimeter with no second factor anywhere.

  This module owns two things and nothing else:

    * `load!/2` — turning `INTERNAL_ALLOWED_CIDRS` into config AT BOOT, and
      REFUSING to boot a prod release that never declared it. It lives here, and
      not inline in `config/runtime.exs`, so the prod-required rule is a driven
      unit test rather than a line somebody read once.
    * `allowed?/2` — the membership decision `Web.Router.fence_internal_surface/2`
      makes on every `/v1/internal/*` request.

  ## Fail closed, in all three directions

  A perimeter that defaults OPEN when its config is unset is not a perimeter, so:

    * **Unset in prod is a BOOT REFUSAL**, not an open door. `cp-deploy.sh` builds
      the new slot aside and health-gates it before flipping Caddy, so a release
      that refuses to boot aborts the deploy (exit 14) and leaves the LIVE slot
      serving — the refusal costs a deploy, never an outage.
    * **A malformed entry raises at boot** rather than degrading the list into a
      silent no-op.
    * **An unrecognised config value, and a `nil`/malformed `remote_ip`, match
      nothing** — `allowed?/2`'s last clause is `false`.

  The one way to have no network factor is to say so out loud:
  `INTERNAL_ALLOWED_CIDRS=any`. That is a recorded operator decision with a name,
  not an unset variable — which is the whole difference this row is about.

  ## Who is supposed to be inside the fence

  Enumerated from the callers in this repo, because a caller nobody enumerated is
  the one that breaks in prod:

    1. **The Go provisioner** (`internal/provisioner/`, `/etc/barkpark-provisioner.env`
       on the control host) — it claims and completes every `*-jobs` route in the
       family.
    2. **The `bp` CLI in a human operator's hands**, from whatever address that
       human is sitting at today: `internal/cli/hetzner_instance_cmd.go` calls
       `GET /v1/internal/barkparks`, `POST /v1/internal/barkparks` and
       `POST /v1/internal/barkparks/:id/deprovision`.
    3. **The Barkpark prod box**, which posts `/v1/internal/platform-deliveries`
       from the box itself over SSH (dr-w24-s7 chose that shape deliberately, to
       keep the zero-new-credentials property).

  (2) is why the ranges cannot be guessed from this repo and why an operator must
  declare them: a laptop's address is not a property of the deployment. An
  operator who does not want to enumerate humans sets `any` and leans on the
  edge/Caddy half instead — an explicit choice, which is the point.
  """

  @doc """
  Resolve `INTERNAL_ALLOWED_CIDRS` at boot.

  `raw` is the environment variable's value (`nil` when unset) and `env` is
  `config_env()`. Unset in `:prod` raises; unset anywhere else yields `:any`,
  which is what `config/config.exs` ships so dev and test behave as they always
  have.
  """
  @spec load!(String.t() | nil, atom()) :: :any | [{:inet.ip_address(), non_neg_integer()}]
  def load!(nil, :prod) do
    raise """
    environment variable INTERNAL_ALLOWED_CIDRS is missing.

    It declares the source ranges allowed to reach the /v1/internal/* fleet-ops
    surface, whose only other gate is the shared WORKER_TOKEN. Refusing to boot
    is deliberate: defaulting to "everyone" would leave that single secret as the
    entire perimeter, which is the defect this variable exists to close
    (dr-w24-bl-internal-write-route-is-publicly-reachable).

    Set it to a comma-separated list, e.g.

        INTERNAL_ALLOWED_CIDRS="203.0.113.7/32,10.20.0.0/16"

    (a bare address means /32, or /128 for IPv6). Include every caller: the Go
    provisioner's host, any operator running `bp hetzner instance ...`, and the
    Barkpark box that posts platform deliveries.

    To run with NO network factor — leaning entirely on the edge — say so
    explicitly:

        INTERNAL_ALLOWED_CIDRS=any
    """
  end

  def load!(nil, _env), do: :any

  def load!(raw, _env) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        raise """
        INTERNAL_ALLOWED_CIDRS is set but empty. An empty value is ambiguous — it
        reads as both "nobody" and "I did not mean to set this". Give it ranges,
        or the explicit opt-out `any`.
        """

      "any" ->
        :any

      trimmed ->
        parsed =
          trimmed
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&parse_entry/1)

        if parsed == [] do
          raise """
          INTERNAL_ALLOWED_CIDRS #{inspect(raw)} contained no entries once blanks
          were dropped. Give it ranges, or the explicit opt-out `any`.
          """
        end

        parsed
    end
  end

  defp parse_entry(entry) do
    {addr, len} =
      case String.split(entry, "/", parts: 2) do
        [addr, len] -> {addr, len}
        [addr] -> {addr, nil}
      end

    address =
      case :inet.parse_address(String.to_charlist(addr)) do
        {:ok, address} ->
          address

        {:error, _} ->
          raise """
          INTERNAL_ALLOWED_CIDRS contains #{inspect(entry)}, whose address part
          #{inspect(addr)} is not a valid IP address. Expected a comma-separated
          list like "203.0.113.7/32,10.20.0.0/16" (a bare address means /32, or
          /128 for IPv6).
          """
      end

    max_len = if tuple_size(address) == 4, do: 32, else: 128

    prefix_length =
      case len do
        nil ->
          max_len

        len ->
          case Integer.parse(len) do
            {n, ""} when n >= 0 and n <= max_len ->
              n

            _ ->
              raise """
              INTERNAL_ALLOWED_CIDRS entry #{inspect(entry)} has an invalid prefix
              length #{inspect(len)}. Expected an integer between 0 and #{max_len}
              for this address family.
              """
          end
      end

    {address, prefix_length}
  end

  @doc """
  Is `ip` inside the configured perimeter?

  `config` is whatever `:internal_allowed_cidrs` holds. `:any` is the explicit
  opt-out. A list is checked by prefix. EVERYTHING ELSE — `nil` from a deleted
  key, a value of an unexpected shape — is `false`: the perimeter never widens by
  accident.
  """
  @spec allowed?(term(), term()) :: boolean()
  def allowed?(:any, _ip), do: true

  def allowed?(cidrs, ip) when is_list(cidrs) and is_tuple(ip),
    do: Enum.any?(cidrs, &in_cidr?(ip, &1))

  def allowed?(_config, _ip), do: false

  # v4 addresses never match a v6 range and vice versa: the tuple_size guard IS
  # the family check (4 vs 8), so a v4-mapped v6 probe cannot slip through a v4
  # range.
  defp in_cidr?(ip, {net, len})
       when tuple_size(ip) == tuple_size(net) and is_integer(len) do
    {width, total} = if tuple_size(ip) == 4, do: {256, 32}, else: {65_536, 128}

    if len < 0 or len > total do
      false
    else
      mask = Integer.pow(2, total - len)
      div(to_int(ip, width), mask) == div(to_int(net, width), mask)
    end
  end

  defp in_cidr?(_ip, _cidr), do: false

  defp to_int(tuple, width),
    do: tuple |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> acc * width + part end)
end
