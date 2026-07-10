defmodule Barkpark.AccessFixtures do
  @moduledoc """
  Shared airdrop-grants (`ag-enforcement`) test fixtures: a LIVE grantor and a
  CLAIMED grant bound to a grantee.

  Consolidated from the four enforcement suites that each redefined a
  byte-identical copy — `access_enforcement_test`, `flat_route_grant_enforcement_test`,
  `scoped_studio_mount_test`, `studio_live_caps_gate_test`. The shared copy keeps
  semantics IDENTICAL (the ag-1 live-grantor assumption: a grant only admits
  while its grantor still holds the capability), so every suite's `import`
  behaves exactly as its former local `defp` did.
  """

  alias Barkpark.Access.Grant
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo

  @doc """
  A LIVE grantor for enforcement-time re-validation (finding ag-1): an admin
  member of `ws` holding read+write+admin, so a grant it mints still confers
  (a grant only admits while its grantor still holds the capability).

  The grantor api_token's own `dataset` field is INERT to enforcement — authority
  is the admin MEMBERSHIP, re-validated per request — so it defaults to "test"
  and is overridable only for a caller that wants the field to match a pinned
  dataset string (no behavioural difference either way).
  """
  def grant_authority!(ws, grantor_dataset \\ "test") do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("ag-grantor-" <> Ecto.UUID.generate()),
        label: "ag-grantor",
        dataset: grantor_dataset,
        permissions: ["read", "write", "admin"]
      })
      |> Repo.insert()

    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, token.id, "admin")
    token
  end

  @doc """
  Insert a grant CLAIMED by `grantee` (so `Access.list_active_grants_for_grantee/1`,
  which `CallerContext.from_user/2` calls, loads it), scoped to `ws`.

  `overrides` set the scope ladder / capabilities / expiry / revocation — and,
  for the flat project-scoped callers, `project_id` / `dataset` / `type`. The
  grantor is a fresh live admin authority (see `grant_authority!/2`). Defaults:
  a `read` capability, workspace-only scope.
  """
  def bind_grant!(ws, grantee, overrides \\ %{}) do
    attrs =
      %{
        grantor_id: grant_authority!(ws).id,
        grantee_email: grantee.email,
        grantee_user_id: grantee.id,
        claimed_at: DateTime.utc_now(),
        workspace_id: ws.id,
        capabilities: ["read"],
        link_token_hash: "hash-" <> Ecto.UUID.generate()
      }
      |> Map.merge(overrides)

    {:ok, grant} = %Grant{} |> Grant.changeset(attrs) |> Repo.insert()
    grant
  end
end
