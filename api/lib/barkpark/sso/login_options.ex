defmodule Barkpark.Sso.LoginOptions do
  @moduledoc """
  What the browser `/login` page offers (task-9963609c3ef5276f).

  Each part shows only when the instance holds the data that makes it work, so
  an instance with no SSO connection, no verified domain and no passkey renders
  the same page as before this module existed.

    * `buttons/0`: one button per active OIDC or SAML connection, but only when
      exactly one organization on the instance has an active connection. A
      self-hosted instance with one Entra org gets "Sign in with Microsoft".
      With two or more connected orgs the page names none of them, so an
      anonymous visitor cannot read the instance's customer list off it.
    * `routing?/0` and `route_for_email/1`: an email on a verified domain of an
      org with an active connection goes to that org's start URL. OIDC wins
      when an org has both. Only a visitor who types an address on the domain
      learns the org slug, as `POST /v1/auth/sso/route` already allowed.
    * `passkeys?/0`: the passkey button shows when at least one passkey is
      registered on the instance. The page then shows it only to a browser
      that supports WebAuthn.

  An org is SSO-only when its `allowed_auth_methods` names `"sso"` and not
  `"password"` (`bp org auth-methods <org> sso`).
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Sso.{Domains, OidcConnection, SamlConnection}
  alias Barkpark.Tenancy.Organization

  @type button :: %{
          protocol: :oidc | :saml,
          provider: :microsoft | :generic,
          org_slug: String.t(),
          start_path: String.t(),
          sso_only: boolean()
        }

  @type route :: %{
          protocol: :oidc | :saml,
          org_slug: String.t(),
          start_path: String.t(),
          sso_only: boolean()
        }

  @doc "The SSO buttons for the login page; `[]` unless exactly one org has an active connection."
  @spec buttons() :: [button()]
  def buttons do
    connections = active_connections()

    case connections |> Enum.map(& &1.org.id) |> Enum.uniq() do
      [_one_org] -> Enum.map(connections, &to_button/1)
      _ -> []
    end
  end

  @doc "Does any verified domain belong to an org with an active connection?"
  @spec routing?() :: boolean()
  def routing? do
    Repo.exists?(
      from d in Barkpark.Sso.OrgDomain,
        where:
          not is_nil(d.verified_at) and
            (d.organization_id in subquery(active_org_ids(OidcConnection)) or
               d.organization_id in subquery(active_org_ids(SamlConnection)))
    )
  end

  @doc """
  Where to send `email`: its verified domain's org, through that org's active
  OIDC connection, else its active SAML connection. nil when the domain is not
  verified or the org has no active connection.
  """
  @spec route_for_email(String.t()) :: route() | nil
  def route_for_email(email) when is_binary(email) do
    with %Organization{} = org <- Domains.route_for_email(String.trim(email)),
         protocol when protocol in [:oidc, :saml] <- protocol_for(org) do
      %{
        protocol: protocol,
        org_slug: org.slug,
        start_path: start_path(protocol, org.slug),
        sso_only: sso_only?(org)
      }
    else
      _ -> nil
    end
  end

  def route_for_email(_), do: nil

  @doc "Is at least one passkey registered on this instance?"
  @spec passkeys?() :: boolean()
  def passkeys?, do: Repo.exists?(Barkpark.Accounts.WebauthnCredential)

  @doc "Does `org` allow SSO and not password sign-in?"
  @spec sso_only?(Organization.t()) :: boolean()
  def sso_only?(%Organization{allowed_auth_methods: methods}) when is_list(methods),
    do: "sso" in methods and "password" not in methods

  def sso_only?(_org), do: false

  @doc "The browser start path for `protocol` and `slug`."
  @spec start_path(:oidc | :saml, String.t()) :: String.t()
  def start_path(:oidc, slug), do: "/v1/auth/oidc/#{URI.encode_www_form(slug)}/start"
  def start_path(:saml, slug), do: "/v1/auth/saml/#{URI.encode_www_form(slug)}/start"

  defp protocol_for(%Organization{id: id}) do
    cond do
      Repo.exists?(from c in OidcConnection, where: c.organization_id == ^id and c.active) ->
        :oidc

      Repo.exists?(from c in SamlConnection, where: c.organization_id == ^id and c.active) ->
        :saml

      true ->
        nil
    end
  end

  defp active_org_ids(schema),
    do: from(c in schema, where: c.active == true, select: c.organization_id)

  defp active_connections do
    oidc =
      Repo.all(
        from c in OidcConnection,
          join: o in Organization,
          on: o.id == c.organization_id,
          where: c.active == true,
          select: {c.issuer, o}
      )
      |> Enum.map(fn {issuer, org} -> %{protocol: :oidc, url: issuer, org: org} end)

    saml =
      Repo.all(
        from c in SamlConnection,
          join: o in Organization,
          on: o.id == c.organization_id,
          where: c.active == true,
          select: {c.idp_sso_url, o}
      )
      |> Enum.map(fn {url, org} -> %{protocol: :saml, url: url, org: org} end)

    oidc ++ saml
  end

  defp to_button(%{protocol: protocol, url: url, org: org}) do
    %{
      protocol: protocol,
      provider: provider(url),
      org_slug: org.slug,
      start_path: start_path(protocol, org.slug),
      sso_only: sso_only?(org)
    }
  end

  # Entra ID issues from login.microsoftonline.com (v2) or sts.windows.net (v1),
  # and its SAML endpoint is on login.microsoftonline.com too.
  defp provider(url) when is_binary(url) do
    case URI.parse(url).host do
      host when host in ["login.microsoftonline.com", "sts.windows.net"] -> :microsoft
      _ -> :generic
    end
  end

  defp provider(_url), do: :generic
end
