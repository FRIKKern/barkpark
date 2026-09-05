defmodule Barkpark.Api.OpenApi do
  @moduledoc """
  Emit an OpenAPI 3.1 document for the `/v1` CMS surface, GENERATED from the
  same capabilities manifest the CLI/MCP/SDK already consume
  (`Barkpark.Plugins.Capabilities`) — so the published spec can never drift
  from the routes.

  ## Why transform the manifest instead of annotating controllers

  Coolify generates its `openapi.yaml` from `swagger-php` attributes scattered
  across every controller (`app/Http/Controllers/Api/OpenApi.php` holds the
  shared response components; each action carries `#[OA\...]` attributes).
  Barkpark already has a richer machine-readable source — the
  registry-assembled manifest, which carries `http.method`, `path_template`,
  `auth_tier`, `args`, `flags`, `id` (→ `operationId`) and `noun` (→ tag) per
  command — so we fold THAT into OpenAPI paths/operations. One generator, zero
  per-controller macros, and it reuses work already done for the CLI.

  ## Pure-ish

  `spec/1` is pure given a manifest map. `spec/0` builds the ADMIN-tier manifest
  with `project: false` — the un-projected superset — so the published doc lists
  EVERY operation regardless of the reader's token. An OpenAPI document is a
  catalogue of the surface, not a per-caller view; the existence-hiding
  projection stays a `/v1/capabilities` runtime concern.

  The §9 error table (`Barkpark.Content.Errors`) is the single source for the
  `Error` schema enum — the generator reads `Content.Errors.known_codes/0` so a
  code added to the runtime is reflected in the spec without a second edit.
  """

  alias Barkpark.Content.Errors
  alias Barkpark.Plugins.Capabilities

  @openapi_version "3.1.0"

  @doc """
  Build the OpenAPI 3.1 spec for the full CMS surface (admin superset).

  Uses `project: false` so the spec is the complete catalogue — every
  operation, not just those visible to a given tier.
  """
  @spec spec() :: map()
  def spec do
    "admin"
    |> Capabilities.manifest(project: false)
    |> spec()
  end

  @doc """
  Transform a capabilities manifest map into an OpenAPI 3.1 document. Pure.
  """
  @spec spec(map()) :: map()
  def spec(%{} = manifest) do
    server = Map.get(manifest, "server", %{})
    commands = Map.get(manifest, "commands", [])
    nouns = Map.get(manifest, "nouns", [])

    %{
      "openapi" => @openapi_version,
      "info" => info(server),
      "servers" => servers(server),
      "tags" => tags(nouns),
      "paths" => paths(commands),
      "components" => %{
        "securitySchemes" => security_schemes(),
        "responses" => shared_error_responses(),
        "schemas" => shared_schemas()
      }
    }
  end

  # ── Document metadata ──────────────────────────────────────────────────────

  defp info(server) do
    name = Map.get(server, "name", "barkpark")

    %{
      "title" => "#{name} CMS API",
      "version" => Map.get(server, "version", "0.0.0"),
      "description" =>
        "The Barkpark headless-CMS `/v1` REST surface, generated from the " <>
          "capabilities manifest served at `GET /v1/capabilities`. Auth is a " <>
          "bearer token (`Authorization: Bearer <token>`); the minimum required " <>
          "permission for each operation is annotated as `x-barkpark-scope`."
    }
  end

  defp servers(server) do
    [%{"url" => Map.get(server, "base_url", "http://localhost:4000")}]
  end

  defp tags(nouns) do
    nouns
    |> Enum.map(fn noun ->
      %{"name" => Map.get(noun, "name"), "description" => Map.get(noun, "summary", "")}
    end)
    |> Enum.reject(&is_nil(&1["name"]))
  end

  # ── Paths ──────────────────────────────────────────────────────────────────

  # Each manifest command yields one OpenAPI operation at its flat path, plus a
  # second operation at the scoped `/w/{workspace_slug}/p/{project_slug}/...`
  # mirror when the command declares a `scoped_prefix` (so the doc documents
  # both the flat and tenant-scoped forms the router actually serves).
  defp paths(commands) do
    commands
    |> Enum.flat_map(&path_entries/1)
    |> Enum.group_by(fn {path, _method, _op} -> path end)
    |> Map.new(fn {path, entries} ->
      {path, Map.new(entries, fn {_path, method, op} -> {method, op} end)}
    end)
  end

  defp path_entries(cmd) do
    method = cmd |> get_in(["http", "method"]) |> to_string() |> String.downcase()
    template = get_in(cmd, ["http", "path_template"])

    flat = {openapi_path(template), method, operation(cmd, template)}

    case Map.get(cmd, "scoped_prefix") do
      prefix when is_binary(prefix) and prefix != "" ->
        scoped_template = prefix <> template
        [flat, {openapi_path(scoped_template), method, operation(cmd, scoped_template)}]

      _ ->
        [flat]
    end
  end

  # `:placeholder` → `{placeholder}` — the OpenAPI path-templating form.
  defp openapi_path(template) do
    Regex.replace(~r/:([a-zA-Z_][a-zA-Z0-9_]*)/, template, "{\\1}")
  end

  defp operation(cmd, template) do
    tier = Map.get(cmd, "auth_tier", "admin")

    %{
      "operationId" => operation_id(cmd, template),
      "summary" => Map.get(cmd, "summary", ""),
      "tags" => [Map.get(cmd, "noun")] |> Enum.reject(&is_nil/1),
      "security" => security_for(tier),
      "x-barkpark-scope" => tier,
      "parameters" => parameters(cmd, template),
      "responses" => responses_for(cmd, template)
    }
    |> maybe_put_request_body(cmd, template)
  end

  # The flat path uses the bare command id (`doc.get`); the scoped mirror gets a
  # suffix so operationIds stay unique across the two paths.
  defp operation_id(cmd, template) do
    base = Map.get(cmd, "id", "operation")
    if String.starts_with?(template, "/w/"), do: base <> ".scoped", else: base
  end

  # ── Parameters ─────────────────────────────────────────────────────────────

  defp parameters(cmd, template) do
    placeholders = path_placeholders(template)
    args = Map.get(cmd, "args", []) || []
    flags = Map.get(cmd, "flags", []) || []
    method = cmd |> get_in(["http", "method"]) |> to_string() |> String.upcase()

    path_params = Enum.map(placeholders, &path_param/1)

    # A declared arg/flag whose name is NOT a path placeholder becomes a query
    # param on reads (GET/HEAD); on writes it rides the request body instead.
    query_source = if method in ~w(GET HEAD), do: args ++ flags, else: []

    query_params =
      query_source
      |> Enum.reject(fn item -> Map.get(item, "name") in placeholders end)
      |> Enum.map(&query_param/1)

    idempotency_param(template, method) ++ path_params ++ query_params
  end

  # ── Idempotency-Key ────────────────────────────────────────────────────────
  #
  # DECLARED, because an undeclared dedup door is a door nobody uses. The
  # `Idempotency-Key` header is server-honoured ONLY where
  # `BarkparkWeb.Plugs.Idempotency` is actually mounted — the two mutate routes,
  # via `pipeline :idempotent` (router.ex) and `pipeline :scoped_mutate`
  # (router.ex). Advertising it on every write would be a LIE: a POST to a route
  # without the plug accepts the header and silently dedups nothing, which is
  # strictly worse than not offering it, because the caller then trusts a retry
  # that double-applies.
  #
  # So the allowlist below mirrors the router, not the method. If you mount the
  # plug on another pipeline, add its path template here — and if you REMOVE it
  # from one, remove the template, or the spec starts promising dedup the server
  # does not do. `openapi_idempotent_routes_test.exs` re-derives this list from
  # router.ex and reds on either drift.
  @idempotent_templates ["/v1/data/mutate/:dataset"]

  defp idempotency_param(template, method) when method in ~w(POST PUT PATCH DELETE) do
    # The scoped mirror (`/w/:workspace_slug/p/:project_slug` + the flat
    # template) rides `:scoped_mutate`, which mounts the same plug — so both
    # spellings of an allowlisted route get the header.
    if Enum.any?(@idempotent_templates, &String.ends_with?(template, &1)) do
      [
        %{
          "name" => "Idempotency-Key",
          "in" => "header",
          "required" => false,
          "description" =>
            "Opaque client-generated key that makes this write safe to retry. " <>
              "The FIRST request carrying a given key executes; a later request with " <>
              "the same key replays that original response byte-for-byte (with " <>
              "`Idempotency-Replay: true`) instead of applying the mutation again — so " <>
              "a client whose request timed out can retry without double-filing. A " <>
              "concurrent request holding the same key is refused 409 " <>
              "`idempotency_key_in_use`; the handler never runs twice. Keys are scoped " <>
              "to the presenting token AND the request path, so two tenants cannot " <>
              "collide on one key, and they expire after 24h. Generate ONE key per " <>
              "logical operation and reuse it across that operation's retries — a fresh " <>
              "key per attempt is exactly the double-write this header prevents.",
          "schema" => %{"type" => "string"}
        }
      ]
    else
      []
    end
  end

  defp idempotency_param(_template, _method), do: []

  defp path_placeholders(template) do
    Regex.scan(~r/:([a-zA-Z_][a-zA-Z0-9_]*)/, template)
    |> Enum.map(fn [_, name] -> name end)
  end

  defp path_param(name) do
    %{
      "name" => name,
      "in" => "path",
      "required" => true,
      "schema" => %{"type" => "string"}
    }
  end

  defp query_param(item) do
    %{
      "name" => Map.get(item, "name"),
      "in" => "query",
      "required" => Map.get(item, "required", false),
      "description" => Map.get(item, "summary", ""),
      "schema" => %{"type" => json_type(Map.get(item, "type", "string"))}
    }
  end

  # ── Request body ───────────────────────────────────────────────────────────

  defp maybe_put_request_body(op, cmd, template) do
    method = cmd |> get_in(["http", "method"]) |> to_string() |> String.upcase()

    if method in ~w(POST PUT PATCH) do
      Map.put(op, "requestBody", request_body(cmd, template))
    else
      op
    end
  end

  defp request_body(cmd, template) do
    placeholders = path_placeholders(template)
    flags = Map.get(cmd, "flags", []) || []
    file_flag? = Enum.any?(flags, fn f -> Map.get(f, "type") == "file" end)

    content =
      if file_flag? do
        # `file`-typed flags are raw uploads (e.g. media bytes, mutation NDJSON).
        %{
          "application/octet-stream" => %{"schema" => %{"type" => "string", "format" => "binary"}}
        }
      else
        %{"application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Document"}}}
      end

    body_fields =
      (Map.get(cmd, "args", []) || [])
      |> Enum.reject(fn a -> Map.get(a, "name") in placeholders end)

    %{
      "required" => true,
      "description" => body_description(cmd, body_fields),
      "content" => content
    }
  end

  defp body_description(cmd, body_fields) do
    cond do
      Map.get(cmd, "batch", false) ->
        "An atomic batch of mutations (create/patch/publish/unpublish/delete)."

      body_fields != [] ->
        names = body_fields |> Enum.map(&Map.get(&1, "name")) |> Enum.join(", ")
        "Request body fields: #{names}."

      true ->
        "Request body."
    end
  end

  # ── Responses ──────────────────────────────────────────────────────────────

  defp responses_for(cmd, template) do
    method = cmd |> get_in(["http", "method"]) |> to_string() |> String.upcase()
    tier = Map.get(cmd, "auth_tier", "admin")
    has_path_param? = path_placeholders(template) != []

    base = %{"200" => success_response(cmd)}

    base
    |> maybe_ref(tier != "none", ["401", "403"])
    |> maybe_ref(has_path_param?, ["404"])
    |> maybe_ref(method in ~w(POST PUT PATCH DELETE), ["409", "412", "422"])
    |> Map.put("429", %{"$ref" => "#/components/responses/RateLimited"})
  end

  # Per-command 200 bodies that are NOT a Document. The default below points every
  # command at `#/components/schemas/Document`, which is right for the data API
  # and wrong for the handful of auth verbs that answer a receipt. pds-w36 c0:
  # POST /v1/auth/reset answers `{ok, sessionsRevoked}` (auth_controller.ex
  # `json(conn, %{ok: true, sessionsRevoked: sessions_revoked})`) and the spec
  # promised a Document — so the JS SDK and docs/auth-user-sessions.md carried a
  # field the manifest never declared. Keyed by command id; add a row when a
  # verb answers a receipt shape, never widen the default.
  @receipt_schemas %{
    "auth.reset" => %{
      "type" => "object",
      "required" => ["ok", "sessionsRevoked"],
      "properties" => %{
        "ok" => %{"type" => "boolean", "enum" => [true]},
        "sessionsRevoked" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" =>
            "Count of the user's OTHER sessions revoked by this reset (the current one stays live)."
        }
      },
      "additionalProperties" => false
    }
  }

  defp success_response(cmd) do
    schema =
      case Map.fetch(@receipt_schemas, Map.get(cmd, "id")) do
        {:ok, receipt} -> receipt
        :error -> %{"$ref" => "#/components/schemas/Document"}
      end

    %{
      "description" =>
        if(Map.get(cmd, "writes", false), do: "Mutation applied.", else: "Success."),
      "content" => %{"application/json" => %{"schema" => schema}}
    }
  end

  @status_to_response %{
    "401" => "Unauthorized",
    "403" => "Forbidden",
    "404" => "NotFound",
    "409" => "Conflict",
    "412" => "PreconditionFailed",
    "422" => "ValidationFailed"
  }

  defp maybe_ref(responses, false, _statuses), do: responses

  defp maybe_ref(responses, true, statuses) do
    Enum.reduce(statuses, responses, fn status, acc ->
      name = Map.fetch!(@status_to_response, status)
      Map.put(acc, status, %{"$ref" => "#/components/responses/#{name}"})
    end)
  end

  # ── Security ───────────────────────────────────────────────────────────────

  # `none` → public (empty security); every higher tier requires the bearer
  # token. `scoped_admin`/`ingest` also require a token — they are never anon.
  defp security_for("none"), do: []
  defp security_for(_tier), do: [%{"bearerAuth" => []}]

  defp security_schemes do
    %{
      "bearerAuth" => %{
        "type" => "http",
        "scheme" => "bearer",
        "description" =>
          "An API token minted via `bp token` / the Studio. The minimum " <>
            "permission tier per operation is annotated as `x-barkpark-scope`."
      }
    }
  end

  # ── Shared components — lift the §9 error table into the spec ───────────────

  defp shared_schemas do
    %{
      "Error" => %{
        "type" => "object",
        "required" => ["error"],
        "description" =>
          "The canonical v1 error envelope (docs/api-v1.md §9). `code` is the " <>
            "stable machine key; `request_id` mirrors the `x-request-id` header.",
        "properties" => %{
          "error" => %{
            "type" => "object",
            "required" => ["code", "message"],
            "properties" => %{
              "code" => %{"type" => "string", "enum" => error_code_enum()},
              "message" => %{"type" => "string"},
              "request_id" => %{
                "type" => "string",
                "description" => "Mirrors the `x-request-id` response header."
              },
              "hint" => %{
                "type" => "string",
                "description" => "An imperative one-line fix suggestion, when available."
              },
              "details" => %{"type" => "object", "additionalProperties" => true}
            }
          }
        }
      },
      # A deliberately open document envelope. v1 of this slug ships
      # operation-level schemas; per-type bodies (schema-v2 field defs) are a
      # follow-up — see the module doc / design §A.3.
      "Document" => %{
        "type" => "object",
        "description" =>
          "A Barkpark document. `_id`/`_type`/`_rev` are always present; the " <>
            "remaining fields are schema-defined (see GET /v1/schemas/:dataset).",
        "additionalProperties" => true,
        "properties" => %{
          "_id" => %{"type" => "string"},
          "_type" => %{"type" => "string"},
          "_rev" => %{"type" => "string"}
        }
      }
    }
  end

  @doc """
  The `Error.code` enum, sourced from the live `Content.Errors` code table so
  the spec and the runtime can never silently diverge.
  """
  @spec error_code_enum() :: [String.t()]
  def error_code_enum do
    Errors.known_codes() |> Enum.sort()
  end

  defp shared_error_responses do
    %{
      "Unauthorized" => err_resp("Missing or invalid token."),
      "Forbidden" => err_resp("Token lacks the required permission."),
      "NotFound" => err_resp("Resource not found in this scope."),
      "Conflict" => err_resp("Document already exists."),
      "PreconditionFailed" => err_resp("`ifRevisionID` did not match the current `_rev`."),
      "ValidationFailed" => err_resp("Document failed schema validation."),
      "RateLimited" => err_resp("Rate limit exceeded.", retry_after: true)
    }
  end

  defp err_resp(description, opts \\ []) do
    base = %{
      "description" => description,
      "content" => %{
        "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Error"}}
      }
    }

    if Keyword.get(opts, :retry_after, false) do
      Map.put(base, "headers", %{
        "Retry-After" => %{
          "description" => "Seconds to wait before retrying.",
          "schema" => %{"type" => "integer"}
        }
      })
    else
      base
    end
  end

  # ── Type mapping ───────────────────────────────────────────────────────────

  defp json_type("int"), do: "integer"
  defp json_type("bool"), do: "boolean"
  defp json_type("file"), do: "string"
  defp json_type(_), do: "string"
end
