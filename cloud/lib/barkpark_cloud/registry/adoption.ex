defmodule BarkparkCloud.Registry.Adoption do
  @moduledoc """
  Attach an already-running box to a team (`POST /v1/barkparks/adopt`,
  `bp barkparks adopt`). The team-facing twin of the worker-only
  `POST /v1/internal/barkparks`: same row write (`Registry.adopt_barkpark/3`,
  so the plan quota and the url/slug uniqueness apply), with three things the
  operator door never had.

      caller --{url, host, admin_token}--> Cloud
        1. bind:  url must be https; SafeUrl.pin/1 resolves it once and the
                  approved address must be `host`
        2. proof: GET  <host>/v1/capabilities   (caller's token) → auth_tier admin
                  GET  <host>/v1/tokens/current (caller's token) → workspace
        3. mint:  POST <host>/w/<ws>/p/default/v1/tokens/elevated (caller's token)
                  label "barkpark cloud admin" → Cloud's OWN admin token
                  GET  <host>/v1/capabilities   (Cloud's token) → admin
        4. row:   Registry.adopt_barkpark/3 stores Cloud's token, never the caller's
        5. arm:   Registry.refresh_update_status/1 — the hourly measurement; an
                  unarmed box gets its enable_apply job from that same path

  PROOF OF CONTROL. Only someone holding an admin token on the box answering at
  `url` can attach it, and `host` (the address the provisioner worker later
  reaches as root for enable_apply) must be the address `SafeUrl.pin/1`
  approves for `url` (the first public address it resolves to). Every request
  goes to that address, with the url's name as the Host header and TLS server
  name, so the box that proved control is the box Cloud records. A url whose
  name resolves to several addresses binds only to the first one.

  CLOUD NEVER KEEPS THE CALLER'S TOKEN. It is used for the three requests above
  and dropped. The stored credential is the one Cloud mints, labelled exactly
  `barkpark cloud admin` so `bp token rotate` refuses it (#21469). A box
  without `/v1/tokens/current` or `/v1/tokens/elevated` is refused with
  `:box_too_old`; there is no fallback to storing the caller's token.

  If the row write fails after the mint (quota race, a url claimed in between),
  the minted token is revoked on the box, best-effort, and the failure returned.

  Transport: the `:studio_link_http_client` seam every instance call uses
  (verified TLS, no redirects). No resolver is injected here: SafeUrl's
  resolver seam stays test-only (SafeUrlResolverRatchetTest), and the
  binding decision is the pure `bind_pinned/2`, tested on its own.
  """

  import Ecto.Query, warn: false
  require Logger

  alias BarkparkCloud.Billing
  alias BarkparkCloud.Notifications.SafeUrl
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}
  alias BarkparkCloud.Repo

  @cloud_label "barkpark cloud admin"
  @project "default"
  @dataset "production"

  @typedoc "Why an adoption was refused. Nothing is stored on any of these."
  @type refusal ::
          {:invalid, Ecto.Changeset.t()}
          | {:invalid_field, atom(), String.t()}
          | :already_attached
          | :limit_reached
          | {:unsafe_url, atom()}
          | {:host_mismatch, [String.t()]}
          | :unreachable
          | {:not_admin, String.t() | nil, non_neg_integer()}
          | {:box_too_old, String.t()}
          | {:mint_refused, non_neg_integer(), String.t() | nil}
          | :minted_token_not_admin
          | {:row, Ecto.Changeset.t() | :limit_reached}

  @doc "The label Cloud's own credential carries on an adopted box."
  @spec cloud_label() :: String.t()
  def cloud_label, do: @cloud_label

  @doc """
  Adopt the box described by `params` (`"name"`, `"slug"`, `"url"`, `"host"`,
  `"admin_token"`) into `team`. Returns `{:ok, barkpark, report}` where
  `report` carries the box workspace, the id of Cloud's minted credential and
  what Cloud armed, or `{:error, refusal}`.
  """
  @spec adopt(BarkparkCloud.Accounts.Team.t(), map()) ::
          {:ok, Barkpark.t(), map()} | {:error, refusal()}
  def adopt(team, params) when is_map(params) do
    with {:ok, attrs, caller_token} <- validate(team, params),
         :ok <- not_attached(attrs),
         :ok <- quota_open(team),
         {:ok, target} <- bind_target(attrs.url, attrs.host),
         :ok <- prove_admin(target, caller_token),
         {:ok, workspace} <- token_workspace(target, caller_token),
         {:ok, minted} <- mint_cloud_credential(target, workspace, caller_token),
         :ok <- prove_minted(target, workspace, minted),
         {:ok, bp} <- create_row(team, attrs, target, workspace, minted) do
      {bp, armed} = arm(bp)

      {:ok, bp,
       %{
         workspace: workspace,
         credential_id: minted.id,
         credential_label: @cloud_label,
         armed: armed
       }}
    end
  end

  # ── 0. input ──────────────────────────────────────────────────────────────

  defp validate(team, params) do
    token = params["admin_token"]
    host = params["host"] |> to_trimmed()

    attrs = %{
      name: params["name"],
      slug: params["slug"],
      url: params["url"],
      host: host,
      mode: "managed",
      team_id: team.id
    }

    cs = Barkpark.changeset(%Barkpark{}, attrs)

    cond do
      not (is_binary(token) and String.trim(token) != "") ->
        {:error, {:invalid_field, :admin_token, "an admin token for the box is required"}}

      not (is_binary(params["url"]) and String.trim(params["url"]) != "") ->
        {:error, {:invalid_field, :url, "the box's https:// url is required"}}

      not ip_literal?(host) ->
        {:error,
         {:invalid_field, :host,
          "must be the box's public IP address (Cloud's worker reaches it there)"}}

      SafeUrl.literal_internal_host?(host) ->
        {:error, {:unsafe_url, :ssrf_blocked}}

      not cs.valid? ->
        {:error, {:invalid, cs}}

      true ->
        url = Ecto.Changeset.get_field(cs, :url)
        {:ok, %{attrs | url: url} |> Map.delete(:team_id), String.trim(token)}
    end
  end

  defp to_trimmed(v) when is_binary(v), do: String.trim(v)
  defp to_trimmed(_), do: nil

  defp ip_literal?(host) when is_binary(host),
    do: match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(host)))

  defp ip_literal?(_), do: false

  # ── 1. already attached / quota ───────────────────────────────────────────

  # Any team's row, on purpose: a box is attached once. The refusal names no
  # team, so it leaks nothing a public url does not already say.
  defp not_attached(%{url: url, host: host}) do
    if Repo.exists?(from(b in Barkpark, where: b.url == ^url or b.host == ^host)),
      do: {:error, :already_attached},
      else: :ok
  end

  # An early read so a team at its ceiling never mints a token on the box. The
  # authoritative, locked check is still `register_barkpark/2` inside the write.
  defp quota_open(team) do
    if Billing.barkpark_limit_reached?(team), do: {:error, :limit_reached}, else: :ok
  end

  # ── 2. bind url → host, behind SafeUrl ────────────────────────────────────

  defp bind_target(url, host) do
    case SafeUrl.pin(url) do
      {:ok, pinned} -> bind_pinned(pinned, host)
      {:error, reason} -> {:error, {:unsafe_url, reason}}
    end
  end

  @doc """
  The binding decision, given what `SafeUrl.pin/1` approved for the url: the
  pinned address must be `host`. Returns the request target (base url on that
  address, plus the Host header and TLS server name when the url named a host)
  or `{:error, {:host_mismatch, [approved_address]}}`. Pure; public for tests.
  """
  @spec bind_pinned(
          %{url: String.t(), host: String.t() | nil, server_name: String.t() | nil},
          String.t()
        ) ::
          {:ok, map()} | {:error, {:host_mismatch, [String.t()]}}
  def bind_pinned(%{url: pinned_url, host: host_header, server_name: server_name}, host) do
    uri = URI.parse(pinned_url)

    with {:ok, want} <- :inet.parse_strict_address(String.to_charlist(host)),
         {:ok, got} <- :inet.parse_address(String.to_charlist(strip_brackets(uri.host || ""))) do
      if got == want do
        {:ok,
         %{
           base: URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port}),
           host_header: host_header,
           server_name: server_name
         }}
      else
        {:error, {:host_mismatch, [ntoa(got)]}}
      end
    else
      _ -> {:error, {:host_mismatch, [to_string(uri.host)]}}
    end
  end

  defp strip_brackets("[" <> rest), do: String.trim_trailing(rest, "]")
  defp strip_brackets(h), do: h

  defp ntoa(addr), do: addr |> :inet.ntoa() |> to_string()

  # ── 3. proof with the caller's token ──────────────────────────────────────

  defp prove_admin(target, token) do
    case request(target, :get, "/v1/capabilities", token) do
      {:ok, 200, %{"auth_tier" => "admin"}} -> :ok
      {:ok, 200, body} -> {:error, {:not_admin, body["auth_tier"], 200}}
      {:ok, status, _} -> {:error, {:not_admin, nil, status}}
      {:error, :unreachable} -> {:error, :unreachable}
    end
  end

  # The box's own statement of whose token this is. Its workspace is where
  # Cloud's credential is minted, and it binds the row to that workspace.
  defp token_workspace(target, token) do
    case request(target, :get, "/v1/tokens/current", token) do
      {:ok, 200, %{"token" => %{} = t}} ->
        {:ok, blank_to(t["workspace"], "default")}

      {:ok, 404, _} ->
        {:error, {:box_too_old, "GET /v1/tokens/current"}}

      {:ok, status, _} ->
        {:error, {:not_admin, nil, status}}

      {:error, :unreachable} ->
        {:error, :unreachable}
    end
  end

  defp blank_to(v, default) when is_binary(v), do: if(String.trim(v) == "", do: default, else: v)
  defp blank_to(_, default), do: default

  defp mint_cloud_credential(target, workspace, token) do
    body = %{
      label: @cloud_label,
      permissions: ["read", "write", "admin"],
      dataset: @dataset,
      no_expiry: true
    }

    case request(target, :post, scoped(workspace, "/v1/tokens/elevated"), token, body) do
      {:ok, status, %{"token" => raw, "id" => id}}
      when status in 200..299 and is_binary(raw) and raw != "" ->
        {:ok, %{token: raw, id: id}}

      {:ok, 404, _} ->
        {:error, {:box_too_old, "POST /v1/tokens/elevated"}}

      {:ok, status, body} ->
        {:error, {:mint_refused, status, body["reason"] || body["code"] || body["message"]}}

      {:error, :unreachable} ->
        {:error, :unreachable}
    end
  end

  defp prove_minted(target, workspace, minted) do
    case request(target, :get, "/v1/capabilities", minted.token) do
      {:ok, 200, %{"auth_tier" => "admin"}} ->
        :ok

      _ ->
        revoke_minted(target, workspace, minted)
        {:error, :minted_token_not_admin}
    end
  end

  # ── 4. the row ────────────────────────────────────────────────────────────

  defp create_row(team, attrs, target, workspace, minted) do
    case Registry.adopt_barkpark(team, attrs, admin_token: minted.token) do
      {:ok, bp} ->
        {:ok, bp}

      {:error, reason} ->
        revoke_minted(target, workspace, minted)
        {:error, {:row, reason}}
    end
  end

  # Best-effort: a token Cloud minted but cannot store must not outlive the
  # refusal. A failed revoke is logged with the token id (never the secret).
  defp revoke_minted(target, workspace, %{id: id, token: token}) do
    case request(target, :delete, scoped(workspace, "/v1/tokens/#{id}"), token) do
      {:ok, status, _} when status in 200..299 ->
        :ok

      other ->
        Logger.warning(
          "adopt: could not revoke Cloud's minted token #{inspect(id)} on #{target.base} " <>
            "(#{inspect(other)}); revoke it on the box"
        )
    end
  end

  # ── 5. arm, the way the hourly measurement does ───────────────────────────

  # `refresh_update_status/1` reads the box's self-update state with the stored
  # credential, persists `apply_arming`, and on "unarmed" files the enable_apply
  # job (consent-gated: autoupdate on, not suspended, host set). That is the
  # path every provisioned box rides each hour; adopt runs it once now.
  defp arm(bp) do
    bp =
      case Registry.refresh_update_status(bp) do
        {:ok, %Barkpark{} = updated} -> updated
        _ -> Registry.get_barkpark(bp.id) || bp
      end

    self_update =
      case bp.apply_arming do
        "armed" ->
          %{status: "armed", detail: "the box applies updates (apply_enabled: true)"}

        "unarmed" ->
          if enable_apply_queued?(bp),
            do: %{
              status: "arming",
              detail:
                "enable_apply job queued; Cloud's worker sets BARKPARK_SELF_UPDATE_APPLY=1 on #{bp.host} over SSH"
            },
            else: %{
              status: "unarmed",
              detail: "the box refuses to apply updates and no job was queued"
            }

        _ ->
          %{
            status: "unknown",
            detail:
              "the box did not report apply_enabled (update_state: #{bp.update_state || "unknown"}); the hourly sweep re-measures"
          }
      end

    {bp,
     %{
       credential: %{
         status: "stored",
         detail: "Cloud's own admin token, labelled \"#{@cloud_label}\""
       },
       self_update: self_update,
       autoupdate: %{status: if(bp.autoupdate_enabled, do: "on", else: "off")},
       monitoring_agent: %{
         status: "not_installed",
         detail:
           "no Cloud job installs barkpark-agent on a box Cloud did not provision; " <>
             "health stays unknown until an agent reports"
       }
     }}
  end

  defp enable_apply_queued?(bp) do
    Repo.exists?(
      from(j in ProvisionJob,
        where:
          j.barkpark_id == ^bp.id and j.kind == "enable_apply" and
            j.status in ["pending", "claimed"]
      )
    )
  end

  # ── transport ─────────────────────────────────────────────────────────────

  defp scoped(workspace, path),
    do: "/w/#{URI.encode(workspace, &URI.char_unreserved?/1)}/p/#{@project}" <> path

  defp request(target, method, path, bearer, body \\ nil) do
    headers =
      [
        {"Authorization", "Bearer " <> bearer},
        {"Accept", "application/json"},
        {"Content-Type", "application/json"}
      ]
      |> then(fn h -> if target.host_header, do: [{"Host", target.host_header} | h], else: h end)

    req =
      %{
        method: method,
        url: target.base <> path,
        headers: headers,
        body: if(body, do: Jason.encode!(body), else: "")
      }
      |> then(fn r ->
        if target.server_name, do: Map.put(r, :server_name, target.server_name), else: r
      end)

    case http_client().request(req) do
      {:ok, %{status: status, body: resp}} when is_integer(status) ->
        case Jason.decode(resp || "") do
          {:ok, %{} = decoded} -> {:ok, status, decoded}
          _ -> {:ok, status, %{}}
        end

      _ ->
        {:error, :unreachable}
    end
  end

  defp http_client do
    Application.get_env(
      :barkpark_cloud,
      :studio_link_http_client,
      BarkparkCloud.Billing.HttpClient
    )
  end
end
