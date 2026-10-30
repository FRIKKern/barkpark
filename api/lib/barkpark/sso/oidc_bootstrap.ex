defmodule Barkpark.Sso.OidcBootstrap do
  @moduledoc """
  Connects an organization to its Entra app at boot, from settings, so a
  Container Apps deployment with the Entra option needs no `bp org` commands
  (milestone 4). deploy/azure/main.bicep sets the `BARKPARK_OIDC_BOOTSTRAP_*`
  settings and reads the client secret from its Key Vault.

  When the organization has no OIDC connection, this creates the organization
  if it is missing, moves the default workspace into it when the workspace is
  in no organization or in the default one, and creates the connection: scopes
  `openid profile email`, strict validation, the tenant id, the owners group
  mapped to `owner`, and `trust_idp_mfa` as set. Each step writes an `auth`
  audit event.

  A connection that exists is never changed, so a later `bp org oidc-update`
  or `bp org oidc-rotate-secret` stays in force. It does nothing when the
  settings are unset.
  """
  require Logger

  alias Barkpark.{Audit, Repo, Tenancy}
  alias Barkpark.Sso.{Oidc, OidcConnection}
  alias Barkpark.Tenancy.Organization

  @required [:org, :issuer, :client_id, :client_secret, :tenant_id, :owner_group]

  @spec run(map() | nil) :: {:ok, OidcConnection.t()} | :skipped | {:error, term()}
  def run(settings \\ Application.get_env(:barkpark, :oidc_bootstrap))

  def run(%{} = s) do
    case Enum.filter(@required, &blank?(s[&1])) do
      [] -> bootstrap(s)
      missing -> {:error, {:missing_settings, missing}}
    end
  end

  def run(_settings), do: :skipped

  @doc """
  `run/0` at boot. It tries again for about five minutes, because the
  discovery document or the database may not answer yet, and logs the result.
  """
  @spec run_with_retries(non_neg_integer(), non_neg_integer()) :: term()
  def run_with_retries(tries \\ 10, wait_ms \\ 30_000) do
    case safe_run() do
      {:ok, c} ->
        {:ok, c}

      :skipped ->
        :skipped

      {:error, {:missing_settings, missing}} = error ->
        Logger.error("[OidcBootstrap] settings missing: #{Enum.join(missing, ", ")}")
        error

      {:error, reason} = error when tries <= 1 ->
        Logger.error("[OidcBootstrap] gave up: #{inspect(reason)}")
        error

      {:error, reason} ->
        Logger.warning("[OidcBootstrap] trying again: #{inspect(reason)}")
        Process.sleep(wait_ms)
        run_with_retries(tries - 1, wait_ms)
    end
  end

  defp safe_run do
    run()
  rescue
    error -> {:error, error}
  end

  defp bootstrap(s) do
    with {:ok, org} <- ensure_org(s),
         nil <- Repo.get_by(OidcConnection, organization_id: org.id),
         :ok <- attach_default_workspace(org),
         {:ok, endpoints} <- Oidc.discover(s.issuer),
         {:ok, c} <- Oidc.create_connection(attrs(s, org, endpoints)) do
      audit(org, "oidc_connection_created", %{
        "issuer" => c.issuer,
        "client_id" => c.client_id,
        "source" => "oidc_bootstrap"
      })

      Logger.info("[OidcBootstrap] organization #{org.slug} signs in through #{c.issuer}")
      {:ok, c}
    else
      %OidcConnection{} -> :skipped
      {:error, _} = error -> error
    end
  end

  defp ensure_org(s) do
    case Tenancy.get_organization_by_slug(s.org) do
      %Organization{} = org ->
        {:ok, org}

      nil ->
        with {:ok, org} <-
               Tenancy.create_organization(%{slug: s.org, name: present(s[:org_name]) || s.org}) do
          audit(org, "organization_created", %{"source" => "oidc_bootstrap"})
          {:ok, org}
        end
    end
  end

  # The default workspace joins the organization unless another organization
  # already holds it. Its owners then sign in through the new connection.
  defp attach_default_workspace(org) do
    default_org_id =
      case Tenancy.get_default_organization() do
        %Organization{id: id} -> id
        nil -> nil
      end

    case Tenancy.get_default_workspace() do
      %{organization_id: id} = ws when is_nil(id) or id == default_org_id ->
        with {:ok, ws} <- Tenancy.assign_workspace_to_organization(ws, org.id) do
          audit(org, "workspace_organization_changed", %{
            "workspace_slug" => ws.slug,
            "source" => "oidc_bootstrap"
          })

          :ok
        end

      _ ->
        :ok
    end
  end

  defp attrs(s, org, endpoints) do
    endpoints
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.merge(%{
      "organization_id" => org.id,
      "client_id" => s.client_id,
      "client_secret" => s.client_secret,
      "tenant_id" => s.tenant_id,
      "scopes" => "openid profile email",
      "strict_validation" => true,
      "trust_idp_mfa" => s[:trust_idp_mfa] == true,
      "group_role_mappings" => %{s.owner_group => "owner"},
      "client_secret_expires_at" => present(s[:client_secret_expires_at])
    })
  end

  defp audit(org, action, metadata) do
    Audit.emit(%{
      category: "auth",
      action: action,
      subject: org.id,
      actor_type: "system",
      metadata: Map.merge(%{"organization_id" => org.id, "org_slug" => org.slug}, metadata)
    })
  end

  defp present(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp present(_), do: nil

  defp blank?(v), do: present(v) == nil
end
