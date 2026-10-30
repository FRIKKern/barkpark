defmodule Barkpark.Sso.OidcBootstrapTest do
  @moduledoc "BARKPARK_OIDC_BOOTSTRAP_* connects the org to Entra at boot (milestone 4)."
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Repo, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Sso.{OidcBootstrap, OidcConnection}

  @tenant "11111111-2222-3333-4444-555555555555"
  @issuer "https://login.microsoftonline.com/#{@tenant}/v2.0"
  @group "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  defmodule Discovery do
    @behaviour Barkpark.Sso.Oidc.HTTP
    @impl true
    def post_form(_url, _params, _headers), do: {:error, :unused}

    @impl true
    def get_json(url) do
      issuer = String.replace_suffix(url, "/.well-known/openid-configuration", "")

      {:ok,
       %{
         "issuer" => issuer,
         "authorization_endpoint" => issuer <> "/authorize",
         "token_endpoint" => issuer <> "/token",
         "jwks_uri" => issuer <> "/keys"
       }}
    end
  end

  setup do
    prev = Application.get_env(:barkpark, :oidc_http)
    Application.put_env(:barkpark, :oidc_http, Discovery)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :oidc_http, prev),
        else: Application.delete_env(:barkpark, :oidc_http)
    end)

    %{ws: Tenancy.establish_default_workspace!()}
  end

  defp settings(extra \\ %{}) do
    Map.merge(
      %{
        org: "pensum",
        org_name: "Pensum",
        issuer: @issuer,
        client_id: "client-id",
        client_secret: "from-key-vault",
        client_secret_expires_at: "2027-10-30T12:00:00Z",
        tenant_id: @tenant,
        owner_group: @group,
        trust_idp_mfa: true
      },
      extra
    )
  end

  test "unset does nothing" do
    assert OidcBootstrap.run(nil) == :skipped
    assert Tenancy.get_organization_by_slug("pensum") == nil
  end

  test "a missing setting is an error and changes nothing" do
    assert {:error, {:missing_settings, [:client_secret]}} =
             OidcBootstrap.run(settings(%{client_secret: ""}))

    assert Tenancy.get_organization_by_slug("pensum") == nil
  end

  test "creates the org, attaches the default workspace and connects it once", %{ws: ws} do
    assert {:ok, %OidcConnection{} = c} = OidcBootstrap.run(settings())

    org = Tenancy.get_organization_by_slug("pensum")
    assert org.name == "Pensum"
    assert c.organization_id == org.id
    assert c.issuer == @issuer
    assert c.token_endpoint == @issuer <> "/token"
    assert c.client_secret == "from-key-vault"
    assert c.tenant_id == @tenant
    assert c.scopes == "openid profile email"
    assert c.strict_validation
    assert c.trust_idp_mfa
    assert c.group_role_mappings == %{@group => "owner"}
    assert DateTime.to_iso8601(c.client_secret_expires_at) =~ "2027-10-30T12:00:00"
    assert Repo.get!(Tenancy.Workspace, ws.id).organization_id == org.id

    actions = Repo.all(from e in Event, where: e.category == "auth", select: e.action)
    assert "organization_created" in actions
    assert "oidc_connection_created" in actions

    # A second boot, even with other settings, leaves the connection as it is.
    assert OidcBootstrap.run(settings(%{client_secret: "other", trust_idp_mfa: false})) ==
             :skipped

    c2 = Repo.get_by!(OidcConnection, organization_id: org.id)
    assert c2.client_secret == "from-key-vault"
    assert c2.trust_idp_mfa
  end

  test "leaves a default workspace that another organization holds", %{ws: ws} do
    {:ok, other} = Tenancy.create_organization(%{slug: "other", name: "Other"})
    {:ok, _} = Tenancy.assign_workspace_to_organization(ws, other.id)

    assert {:ok, _} = OidcBootstrap.run(settings())
    assert Repo.get!(Tenancy.Workspace, ws.id).organization_id == other.id
  end
end
