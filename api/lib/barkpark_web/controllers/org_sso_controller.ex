defmodule BarkparkWeb.OrgSsoController do
  @moduledoc """
  `/v1/admin/orgs` sets up organizations and their OIDC sign-in without a
  server shell (task-25386fa77a664587). The routes ride
  `[:api, :require_admin, :require_platform_operator]`: an org's identity
  connection is instance-wide authority, the same tier as `OrgAdminLive`.

  Every change writes an `auth` audit event naming the org. A client secret is
  never returned or written to an audit event; responses say only whether one is
  set.
  """
  use BarkparkWeb, :controller

  action_fallback BarkparkWeb.FallbackController

  alias Barkpark.{Audit, Repo, Tenancy}
  alias Barkpark.Sso.{Domains, Oidc, OidcConnection, OrgDomain}
  alias Barkpark.Tenancy.Organization

  # Entra ID settings a create or an update may set (PR #24225, #24251), and
  # require_group_match.
  @entra_fields ~w(scopes token_endpoint_auth_method tenant_id strict_validation trust_idp_mfa mfa_acr require_group_match)

  # Fields an update may change. A new issuer is a new connection: delete it
  # and create it again. The secret changes only through `rotate_secret/2`.
  @update_fields ~w(client_id groups_claim group_role_mappings active client_secret_expires_at) ++
                   @entra_fields

  def create(conn, params) do
    attrs = %{slug: params["slug"], name: params["name"] || params["slug"]}

    with {:ok, org} <- Tenancy.create_organization(attrs) do
      audit(conn, org, "organization_created", %{})
      conn |> put_status(:created) |> json(org_json(org))
    end
  end

  def attach_workspace(conn, %{"org_slug" => slug, "workspace_slug" => ws_slug}) do
    with {:ok, org} <- fetch_org(slug),
         %{} = ws <- Tenancy.get_workspace_by_slug(ws_slug) || {:error, :not_found},
         {:ok, ws} <- Tenancy.assign_workspace_to_organization(ws, org.id) do
      audit(conn, org, "workspace_organization_changed", %{"workspace_slug" => ws.slug})
      json(conn, %{organization: org.slug, workspace: ws.slug})
    end
  end

  def set_auth_methods(conn, %{"org_slug" => slug} = params) do
    with {:ok, methods} <- Map.fetch(params, "methods"),
         {:ok, org} <- fetch_org(slug),
         {:ok, org} <-
           Tenancy.set_organization_allowed_auth_methods(org.id, split(methods), actor(conn)) do
      json(conn, org_json(org))
    else
      error when error in [:error, {:error, :invalid_policy}] ->
        invalid(
          "methods",
          "use null or a list from: #{Enum.join(Organization.auth_methods(), ", ")}"
        )

      other ->
        other
    end
  end

  def create_oidc(conn, %{"org_slug" => slug} = params) do
    with {:ok, org} <- fetch_org(slug),
         issuer when is_binary(issuer) <- params["issuer"] || invalid("issuer", "is required"),
         {:ok, endpoints} <- discover(issuer),
         attrs =
           params
           |> Map.take(
             ["client_id", "client_secret", "groups_claim", "group_role_mappings"] ++
               ["client_secret_expires_at"] ++ @entra_fields
           )
           |> expiry_date()
           |> Map.merge(Map.new(endpoints, fn {k, v} -> {Atom.to_string(k), v} end))
           |> Map.put("organization_id", org.id),
         {:ok, c} <- Oidc.create_connection(attrs) |> mapping_error() do
      audit(conn, org, "oidc_connection_created", %{
        "issuer" => c.issuer,
        "client_id" => c.client_id
      })

      conn |> put_status(:created) |> json(oidc_json(org, c))
    end
  end

  def update_oidc(conn, %{"org_slug" => slug} = params) do
    attrs = params |> Map.take(@update_fields) |> expiry_date()

    with {:ok, org, c} <- fetch_oidc(slug),
         {:ok, c} <- Oidc.update_connection(c, attrs) |> mapping_error() do
      audit(conn, org, "oidc_connection_updated", %{"fields" => Enum.sort(Map.keys(attrs))})
      json(conn, oidc_json(org, c))
    end
  end

  def rotate_secret(conn, %{"org_slug" => slug} = params) do
    with {:ok, org, c} <- fetch_oidc(slug),
         secret when is_binary(secret) and secret != "" <-
           params["client_secret"] || invalid("client_secret", "is required"),
         # The stored expiry belonged to the old secret, so a rotation without
         # a new date clears it.
         attrs =
           %{"client_secret" => secret}
           |> Map.put("client_secret_expires_at", params["client_secret_expires_at"])
           |> expiry_date(),
         {:ok, c} <- Oidc.update_connection(c, attrs) do
      audit(conn, org, "oidc_client_secret_rotated", %{
        "client_secret_expires_at" =>
          c.client_secret_expires_at && DateTime.to_iso8601(c.client_secret_expires_at)
      })

      json(conn, oidc_json(org, c))
    end
  end

  def delete_oidc(conn, %{"org_slug" => slug}) do
    with {:ok, org, c} <- fetch_oidc(slug),
         {:ok, _} <- Oidc.delete_connection(c) do
      audit(conn, org, "oidc_connection_deleted", %{"issuer" => c.issuer})
      json(conn, %{organization: org.slug, deleted: true})
    end
  end

  def add_domain(conn, %{"org_slug" => slug} = params) do
    with {:ok, org} <- fetch_org(slug),
         domain when is_binary(domain) <- params["domain"] || invalid("domain", "is required"),
         {:ok, d} <- Domains.request_verification(org, domain) do
      audit(conn, org, "org_domain_requested", %{"domain" => d.domain})
      conn |> put_status(:created) |> json(domain_json(d))
    end
  end

  def verify_domain(conn, %{"org_slug" => slug, "domain" => domain}) do
    with {:ok, org} <- fetch_org(slug),
         %OrgDomain{} <-
           Repo.get_by(OrgDomain, organization_id: org.id, domain: String.downcase(domain)) ||
             {:error, :not_found},
         {:ok, d} <- Domains.verify(domain) do
      audit(conn, org, "org_domain_verified", %{"domain" => d.domain})
      json(conn, domain_json(d))
    else
      {:error, :txt_record_absent} ->
        invalid("domain", "the DNS TXT record with the verification token was not found")

      other ->
        other
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp fetch_org(slug) when is_binary(slug) do
    case Tenancy.get_organization_by_slug(slug) do
      %Organization{} = org -> {:ok, org}
      nil -> {:error, {:not_found, "organization not found"}}
    end
  end

  defp fetch_oidc(slug) do
    with {:ok, org} <- fetch_org(slug) do
      case Repo.get_by(OidcConnection, organization_id: org.id) do
        %OidcConnection{} = c -> {:ok, org, c}
        nil -> {:error, {:not_found, "organization has no OIDC connection"}}
      end
    end
  end

  defp discover(issuer) do
    case Oidc.discover(issuer) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        {:error,
         {:validation_failed, "SSO setting", %{"issuer" => ["discovery document: #{reason}"]},
          "Check that issuer is the provider's issuer URL, such as " <>
            "https://login.microsoftonline.com/<tenant id>/v2.0, and send the request again. " <>
            Barkpark.SetupDocs.see(:oidc)}}
    end
  end

  # Entra prints the expiry as an ISO 8601 time; an operator may type a date.
  # A bare date means midnight UTC at the start of that day.
  defp expiry_date(%{"client_secret_expires_at" => v} = attrs) when is_binary(v) do
    v = String.trim(v)

    value =
      cond do
        v == "" -> nil
        Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, v) -> v <> "T00:00:00Z"
        true -> v
      end

    Map.put(attrs, "client_secret_expires_at", value)
  end

  defp expiry_date(attrs), do: attrs

  # The CLI sends one comma-separated string; JSON callers send a list or null.
  defp split(methods) when is_binary(methods),
    do: methods |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp split(methods), do: methods

  defp mapping_error({:error, {:unknown_role, names}}),
    do: invalid("group_role_mappings", "unknown role(s): #{Enum.join(names, ", ")}")

  defp mapping_error({:error, :no_owner_mapping}),
    do:
      invalid(
        "group_role_mappings",
        "maps no group to owner. Each sign-in sets the role from the user's groups, " <>
          "so this mapping would leave the organization with no owner. Map the owners group to owner"
      )

  defp mapping_error(result), do: result

  defp invalid(field, message),
    do:
      {:error,
       {:validation_failed, "SSO setting", %{field => [message]},
        "Correct #{field} and send the request again."}}

  defp actor(conn) do
    case conn.assigns[:api_token] do
      %{id: id} -> [actor_type: "api_token", actor_id: to_string(id)]
      _ -> []
    end
  end

  defp audit(conn, org, action, metadata) do
    opts = actor(conn)

    Audit.emit(%{
      category: "auth",
      action: action,
      subject: org.id,
      actor_type: Keyword.get(opts, :actor_type, "admin"),
      actor_id: Keyword.get(opts, :actor_id),
      metadata: Map.merge(%{"organization_id" => org.id, "org_slug" => org.slug}, metadata)
    })
  end

  defp org_json(org),
    do: %{
      id: org.id,
      slug: org.slug,
      name: org.name,
      allowed_auth_methods: org.allowed_auth_methods
    }

  defp oidc_json(org, c),
    do: %{
      organization: org.slug,
      issuer: c.issuer,
      client_id: c.client_id,
      client_secret_set: is_binary(c.client_secret) and c.client_secret != "",
      authorization_endpoint: c.authorization_endpoint,
      token_endpoint: c.token_endpoint,
      jwks_uri: c.jwks_uri,
      groups_claim: c.groups_claim,
      group_role_mappings: c.group_role_mappings,
      require_group_match: c.require_group_match,
      scopes: c.scopes,
      token_endpoint_auth_method: c.token_endpoint_auth_method,
      tenant_id: c.tenant_id,
      strict_validation: c.strict_validation,
      trust_idp_mfa: c.trust_idp_mfa,
      mfa_acr: c.mfa_acr,
      client_secret_expires_at: c.client_secret_expires_at,
      active: c.active
    }

  defp domain_json(d),
    do: %{
      domain: d.domain,
      dns_txt_record: d.dns_token,
      verified: not is_nil(d.verified_at),
      verified_at: d.verified_at
    }
end
