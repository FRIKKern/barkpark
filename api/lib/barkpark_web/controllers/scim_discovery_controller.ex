defmodule BarkparkWeb.ScimDiscoveryController do
  @moduledoc """
  SCIM 2.0 discovery endpoints (era-w8-scim-conformance) — RFC 7644 §4.

  An IdP (Okta / Azure AD) probes these BEFORE it provisions to learn the
  server's capabilities and resource shapes:

    * `GET /scim/v2/ServiceProviderConfig` — feature flags (patch, filter, etag…)
    * `GET /scim/v2/ResourceTypes`        — the User + Group resource types
    * `GET /scim/v2/Schemas`              — the core User + Group schema attrs

  All three sit behind the `:scim` pipeline (per-org bearer): fail-closed and
  consistent with every other SCIM route — an unauthenticated probe gets 401.
  """
  use BarkparkWeb, :controller

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

  # GET /scim/v2/Schemas
  def schemas(conn, _params) do
    resources = [user_schema(conn), group_schema(conn)]
    json(conn, ScimResponse.list_response(resources, length(resources), 1))
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
