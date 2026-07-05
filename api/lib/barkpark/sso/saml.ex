defmodule Barkpark.Sso.Saml do
  @moduledoc """
  SAML 2.0 Service-Provider SSO (era-w3-saml). Barkpark is the SP; each org
  configures its IdP (`SamlConnection`). Signature verification and condition
  checks are delegated to the vetted `esaml` library (`esaml_sp:validate_assertion`)
  — never hand-rolled XML-dsig.

    * `authn_redirect_url/1` — SP-initiated: the redirect to the IdP SSO endpoint.
    * `consume/2` — the ACS: validate the POSTed SAML assertion (signature pinned
      to the IdP cert fingerprint, recipient = our ACS, audience = our entity id),
      then extract the subject email.

  Trust anchor: the IdP's signing cert fingerprint (`sha256:<base64>` of the DER).
  """
  require Record

  Record.defrecordp(:esaml_sp, Record.extract(:esaml_sp, from_lib: "esaml/include/esaml.hrl"))

  Record.defrecordp(
    :esaml_assertion,
    Record.extract(:esaml_assertion, from_lib: "esaml/include/esaml.hrl")
  )

  Record.defrecordp(
    :esaml_subject,
    Record.extract(:esaml_subject, from_lib: "esaml/include/esaml.hrl")
  )

  import Ecto.Query, warn: false
  alias Barkpark.Repo
  alias Barkpark.Sso.SamlConnection
  alias Barkpark.Tenancy.Organization

  @doc "Create a per-org SAML connection."
  @spec create_connection(map()) :: {:ok, SamlConnection.t()} | {:error, Ecto.Changeset.t()}
  def create_connection(attrs),
    do: %SamlConnection{} |> SamlConnection.changeset(attrs) |> Repo.insert()

  @doc "The active SAML connection for an org slug, or nil."
  @spec connection_for_org_slug(String.t()) :: SamlConnection.t() | nil
  def connection_for_org_slug(slug) when is_binary(slug) do
    Repo.one(
      from c in SamlConnection,
        join: o in Organization,
        on: o.id == c.organization_id,
        where: o.slug == ^slug and c.active == true
    )
  end

  @doc "Our SP entity id + ACS (consume) URL for `conn`'s org."
  def entity_id(slug), do: BarkparkWeb.Endpoint.url() <> "/saml/#{slug}/metadata"
  def acs_uri(slug), do: BarkparkWeb.Endpoint.url() <> "/v1/auth/saml/#{slug}/acs"

  @doc "The SP-initiated redirect URL to the IdP's SSO endpoint (contains the SAMLRequest)."
  @spec authn_redirect_url(SamlConnection.t(), String.t()) :: String.t()
  def authn_redirect_url(%SamlConnection{} = conn, slug) do
    sp = sp_for(conn, slug)
    req = :esaml_sp.generate_authn_request(to_charlist(conn.idp_sso_url), sp)

    :esaml_binding.encode_http_redirect(to_charlist(conn.idp_sso_url), req, :undefined, <<>>)
    |> to_string()
  end

  @doc """
  Consume a SAML assertion XML string at the ACS: verify the signature against
  the IdP cert fingerprint + validate recipient/audience/conditions (via esaml),
  then return `{:ok, email}`.
  """
  @spec consume(SamlConnection.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def consume(%SamlConnection{} = conn, xml, slug) when is_binary(xml) do
    sp = sp_for(conn, slug)

    {doc, _} = :xmerl_scan.string(to_charlist(xml), namespace_conformant: true)

    case :esaml_sp.validate_assertion(doc, sp) do
      {:ok, assertion} ->
        case subject_email(assertion) do
          nil -> {:error, :no_email}
          email -> {:ok, email}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:parse_error, Exception.message(e)}}
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp sp_for(conn, slug) do
    fp = cert_fingerprint(conn.idp_cert_pem)

    :esaml_sp.setup(
      esaml_sp(
        metadata_uri: to_charlist(entity_id(slug)),
        consume_uri: to_charlist(acs_uri(slug)),
        trusted_fingerprints: [to_charlist(fp)],
        idp_signs_assertions: true,
        idp_signs_envelopes: false
      )
    )
  end

  # NameID if it's an email, else an email-ish SAML attribute.
  defp subject_email(assertion) do
    subject = esaml_assertion(assertion, :subject)
    name = subject |> esaml_subject(:name) |> to_string()
    attrs = esaml_assertion(assertion, :attributes)

    cond do
      String.contains?(name, "@") -> name
      email = attr(attrs, [:email, :emailaddress, :mail]) -> email
      true -> nil
    end
  end

  defp attr(attrs, keys) do
    Enum.find_value(keys, fn k ->
      case :proplists.get_value(k, attrs) do
        :undefined -> nil
        v when is_list(v) -> to_string(v)
        _ -> nil
      end
    end)
  end

  # "sha256:<base64(sha256(DER cert))>" — the format esaml's trusted_fingerprints
  # matches against the signer cert.
  @spec cert_fingerprint(String.t()) :: String.t()
  def cert_fingerprint(pem) do
    der =
      pem
      |> :public_key.pem_decode()
      |> Enum.find_value(fn
        {:Certificate, der, _} -> der
        _ -> nil
      end)

    "sha256:" <> Base.encode64(:crypto.hash(:sha256, der))
  end
end
