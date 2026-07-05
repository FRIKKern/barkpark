defmodule Barkpark.Sso.Domains do
  @moduledoc """
  Domain-verification + SSO auto-routing (era-w3-jit-domain).

  An org claims a domain (`request_verification/2`), publishes the returned DNS
  TXT token, and `verify/1` confirms ownership by resolving the domain's TXT
  records. Only a **verified** domain routes: `route_for_email/1` maps an
  email's domain to the owning org — the login router then sends the user to
  that org's SSO.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Sso.OrgDomain
  alias Barkpark.Sso.Domains.Resolver
  alias Barkpark.Tenancy.Organization

  @token_prefix "barkpark-verify="

  @doc """
  Claim `domain` for `org` and return the record with the DNS TXT token the org
  must publish (`barkpark-verify=<random>`). Idempotent per domain.
  """
  @spec request_verification(Organization.t(), String.t()) ::
          {:ok, OrgDomain.t()} | {:error, term()}
  def request_verification(%Organization{id: org_id}, domain) when is_binary(domain) do
    token = @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    %OrgDomain{}
    |> OrgDomain.changeset(%{organization_id: org_id, domain: domain, dns_token: token})
    |> Repo.insert()
  end

  @doc """
  Verify a claimed domain: resolve its TXT records and, if the expected token is
  present, stamp `verified_at`. Returns `{:ok, domain}` or `{:error, reason}`.
  """
  @spec verify(String.t()) :: {:ok, OrgDomain.t()} | {:error, term()}
  def verify(domain) when is_binary(domain) do
    case Repo.get_by(OrgDomain, domain: String.downcase(domain)) do
      nil ->
        {:error, :not_found}

      %OrgDomain{dns_token: token} = row ->
        if token in Resolver.txt_records(domain) do
          {:ok,
           row
           |> OrgDomain.changeset(%{verified_at: DateTime.utc_now()})
           |> Repo.update!()}
        else
          {:error, :txt_record_absent}
        end
    end
  end

  @doc "The VERIFIED-domain record for an email's domain, or nil (unverified never routes)."
  @spec verified_for_email(String.t()) :: OrgDomain.t() | nil
  def verified_for_email(email) when is_binary(email) do
    case domain_of(email) do
      nil ->
        nil

      domain ->
        Repo.one(
          from d in OrgDomain,
            where: d.domain == ^domain and not is_nil(d.verified_at)
        )
    end
  end

  @doc "The Organization to route `email` to (its domain is verified), or nil."
  @spec route_for_email(String.t()) :: Organization.t() | nil
  def route_for_email(email) do
    case verified_for_email(email) do
      %OrgDomain{organization_id: oid} -> Repo.get(Organization, oid)
      nil -> nil
    end
  end

  defp domain_of(email) do
    case String.split(email, "@") do
      [_, domain] when domain != "" -> String.downcase(domain)
      _ -> nil
    end
  end
end
