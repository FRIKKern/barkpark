defmodule Barkpark.Sso.LoginAuditTest do
  @moduledoc "Every SSO/social login emits an sso_login audit event (era-w3-sso-login-audit)."
  use Barkpark.DataCase, async: false

  alias Barkpark.{Accounts, Audit, Repo, Sso, Tenancy}
  alias Barkpark.Audit.Event
  import Ecto.Query

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "correct horse ok"})
    u
  end

  defp login_events, do: Repo.all(from e in Event, where: e.action == "sso_login")

  test "OIDC, social, and SAML logins each emit a distinct sso_login audit event" do
    {:ok, org} = Tenancy.create_organization(%{slug: "auditorg", name: "Audit Org"})
    u = user("u@auditorg.com")

    assert :ok = Sso.record_login(u, "oidc", org.id)
    assert :ok = Sso.record_login(u, "social:google", nil)
    assert :ok = Sso.record_login(u, "saml", org.id)

    events = login_events()
    assert length(events) == 3
    providers = Enum.map(events, & &1.metadata["provider"]) |> Enum.sort()
    assert providers == ["oidc", "saml", "social:google"]

    oidc = Enum.find(events, &(&1.metadata["provider"] == "oidc"))
    assert oidc.category == "auth"
    assert oidc.actor_type == "user"
    assert oidc.actor_id == u.id
    assert oidc.metadata["organization_id"] == org.id

    # the audit hash chain stays valid after the emits
    assert :ok == Audit.verify_chain(nil)
  end
end
