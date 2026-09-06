defmodule BarkparkWeb.ScimDiscoveryController do
  @moduledoc """
  SCIM 2.0 discovery endpoints (era-w8-scim-conformance) — RFC 7644 §4.

  An IdP (Okta / Azure AD) probes these BEFORE it provisions to learn the
  server's capabilities and resource shapes:

    * `GET /scim/v2/ServiceProviderConfig` — feature flags (patch, filter, etag…)
    * `GET /scim/v2/ResourceTypes`        — the User + Group resource types
    * `GET /scim/v2/ResourceTypes/:id`    — one of them, by `id`
    * `GET /scim/v2/Schemas`              — the core User + Group schema attrs
    * `GET /scim/v2/Schemas/:id`          — one of them, by schema URN

  RFC 7644 §4 defines the single-resource forms as well as the collections, and
  a stricter client walks `ListResponse` → each `meta.location` → the single
  resource. Those `meta.location` URLs have been emitted since
  era-w8-scim-conformance while the routes behind them 404'd, so the discovery
  document pointed at itself and lied. An unknown `id` gets a SCIM Error 404 —
  the same typed envelope `/Users/:id` gives for an id this caller cannot see,
  never a bare Phoenix 404 page.

  Both single GETs are conditional (RFC 7644 §3.14 / RFC 9110 §13.1.2): the
  rendered document is content-addressed into a weak `ETag`, and a matching
  `If-None-Match` short-circuits to `304 Not Modified`. These documents are
  static per host, so an IdP that re-probes on every sync cycle transfers the
  bytes exactly once. The comparison is `BarkparkWeb.Http.IfNoneMatch` — the one
  matcher (charter D11), not a second local one.

  All of these sit behind the `:scim` pipeline (per-org bearer): fail-closed and
  consistent with every other SCIM route — an unauthenticated probe gets 401.
  """
  use BarkparkWeb, :controller

  alias BarkparkWeb.Http.IfNoneMatch
  alias BarkparkWeb.ScimResponse

  @spc_schema "urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"
  @rt_schema "urn:ietf:params:scim:schemas:core:2.0:ResourceType"
  @schema_schema "urn:ietf:params:scim:schemas:core:2.0:Schema"
  @user_urn "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_urn "urn:ietf:params:scim:schemas:core:2.0:Group"

  # GET /scim/v2/ServiceProviderConfig
  def service_provider_config(conn, _params) do
    json(conn, %{
      "schemas" => [@spc_schema],
      "documentationUri" => "https://barkpark.cloud/docs/scim",
      "patch" => %{"supported" => true},
      "bulk" => %{"supported" => false, "maxOperations" => 0, "maxPayloadSize" => 0},
      "filter" => %{"supported" => true, "maxResults" => ScimResponse.max_page()},
      "changePassword" => %{"supported" => false},
      "sort" => %{"supported" => false},
      "etag" => %{"supported" => true},
      "authenticationSchemes" => [
        %{
          "type" => "oauthbearertoken",
          "name" => "OAuth Bearer Token",
          "description" => "Per-organization SCIM bearer token.",
          "primary" => true
        }
      ],
      "meta" => %{
        "resourceType" => "ServiceProviderConfig",
        "location" =>
          ScimResponse.location(conn, "ServiceProviderConfig", "") |> String.trim_trailing("/")
      }
    })
  end

  # GET /scim/v2/ResourceTypes
  def resource_types(conn, _params) do
    resources = [
      resource_type(conn, "User", "/Users", @user_urn),
      resource_type(conn, "Group", "/Groups", @group_urn)
    ]

    json(conn, ScimResponse.list_response(resources, length(resources), 1))
  end

  # GET /scim/v2/ResourceTypes/:id
  def show_resource_type(conn, %{"id" => id}) do
    case id do
      "User" -> conditional(conn, resource_type(conn, "User", "/Users", @user_urn))
      "Group" -> conditional(conn, resource_type(conn, "Group", "/Groups", @group_urn))
      _ -> ScimResponse.error(conn, 404, "no ResourceType with that id")
    end
  end

  # GET /scim/v2/Schemas
  def schemas(conn, _params) do
    resources = [user_schema(conn), group_schema(conn)]
    json(conn, ScimResponse.list_response(resources, length(resources), 1))
  end

  # GET /scim/v2/Schemas/:id — `id` is the schema URN (RFC 7643 §7).
  def show_schema(conn, %{"id" => id}) do
    case id do
      @user_urn -> conditional(conn, user_schema(conn))
      @group_urn -> conditional(conn, group_schema(conn))
      _ -> ScimResponse.error(conn, 404, "no Schema with that id")
    end
  end

  # ── conditional GET (RFC 7644 §3.14) ──────────────────────────────────────

  # The document is its own validator: a weak ETag over the encoded body, so it
  # changes exactly when the bytes we would serve change (a schema edit, or a
  # different host in `meta.location`) and never otherwise. Emitted on BOTH
  # answers — a 304 must carry the validator that selected it, or the client has
  # nothing to send next time.
  defp conditional(conn, body) do
    etag = etag_for(body)
    conn = put_resp_header(conn, "etag", etag)

    if IfNoneMatch.match?(conn, etag) do
      send_resp(conn, 304, "")
    else
      json(conn, body)
    end
  end

  defp etag_for(body) do
    digest =
      body
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 8)
      |> Base.encode16(case: :lower)

    ~s(W/"scim-#{digest}")
  end

  # ── builders ──────────────────────────────────────────────────────────────

  defp resource_type(conn, id, endpoint, schema) do
    %{
      "schemas" => [@rt_schema],
      "id" => id,
      "name" => id,
      "endpoint" => endpoint,
      "schema" => schema,
      "meta" => %{
        "resourceType" => "ResourceType",
        "location" => ScimResponse.location(conn, "ResourceTypes", id)
      }
    }
  end

  defp user_schema(conn) do
    %{
      "schemas" => [@schema_schema],
      "id" => @user_urn,
      "name" => "User",
      "description" => "User Account",
      "attributes" => [
        attr("userName", "string", true, "server", uniqueness: "server"),
        attr("active", "boolean", false, "readWrite"),
        attr("externalId", "string", false, "readWrite")
      ],
      "meta" => %{
        "resourceType" => "Schema",
        "location" => ScimResponse.location(conn, "Schemas", @user_urn)
      }
    }
  end

  defp group_schema(conn) do
    %{
      "schemas" => [@schema_schema],
      "id" => @group_urn,
      "name" => "Group",
      "description" => "Group",
      "attributes" => [
        attr("displayName", "string", true, "readWrite"),
        members_attr()
      ],
      "meta" => %{
        "resourceType" => "Schema",
        "location" => ScimResponse.location(conn, "Schemas", @group_urn)
      }
    }
  end

  defp attr(name, type, required, mutability, opts \\ []) do
    %{
      "name" => name,
      "type" => type,
      "multiValued" => false,
      "required" => required,
      "caseExact" => false,
      "mutability" => mutability,
      "returned" => "default",
      "uniqueness" => Keyword.get(opts, :uniqueness, "none")
    }
  end

  defp members_attr do
    %{
      "name" => "members",
      "type" => "complex",
      "multiValued" => true,
      "required" => false,
      "mutability" => "readWrite",
      "returned" => "default",
      "subAttributes" => [
        attr("value", "string", false, "immutable"),
        attr("display", "string", false, "immutable")
      ]
    }
  end
end
