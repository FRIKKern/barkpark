defmodule BarkparkWeb.Plugs.LegacyDeprecation do
  @moduledoc """
  Adds Deprecation/Sunset/Link headers to legacy `/api/*` routes.

  THIS PLUG IS A HEADER-STAMPER, NOT A GATE. It never halts, never reads a
  credential, never narrows scope. So the effective mount of the one legacy
  route that pipes through `[:api, LegacyDeprecation]` — `GET /api/schemas`
  (`router.ex`, the last surviving legacy scope) — is the bare shared `:api`
  pipeline: the type list a caller receives is chosen by `AssignDefaultScope`
  when no credential verifies, not by the credential the caller presented
  (`LegacyController.schemas/2` → `Content.list_schemas(scope_opts(conn))`).

  RULING (task-427005376f730ff4, lead-security-3 with main, 2026-09-05):
  recorded as the LOWEST-severity member of the stale-key family
  (parent task-46872cadcfc50c5f) and explicitly as an INTEGRITY finding, not
  confidentiality — `Schema.public_schema?/1` already narrows the response and
  a header-less caller receives byte-identical output. The legacy door is NOT
  removed and NOT clamped this shift: `deploy.sh`, the docker-compose
  healthcheck and `cloud/support.go` probe `/api/schemas` as a liveness path, so
  a strict clamp on the shared pipeline would change what a stale-keyed prober
  sees on a liveness endpoint (blast radius also noted at the
  `:strict_bearer_media_read` pipeline in `router.ex`). Anyone widening
  `strict_on_presented` onto this route owns that blast radius.
  """
  import Plug.Conn

  def init(_), do: []

  def call(conn, _) do
    conn
    |> put_resp_header("deprecation", "true")
    |> put_resp_header("sunset", "Wed, 31 Dec 2026 23:59:59 GMT")
    |> put_resp_header("link", "</v1/data/query>; rel=\"successor-version\"")
  end
end
