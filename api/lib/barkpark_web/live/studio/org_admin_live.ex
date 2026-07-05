defmodule BarkparkWeb.Studio.OrgAdminLive do
  @moduledoc """
  The organization admin shell (era-w1-org-admin-shell).

  Admin-gated (the `:admin_studio` live_session runs the `LiveAuth :admin`
  on_mount hook before this mounts). It renders the Organization → Workspaces
  overview and the labelled mount points that later enterprise waves fill in:
  SSO, Directory Sync (SCIM), Members & Roles, and the Audit Log. Each panel is
  a placeholder now; the waves that own them (`era-w3`, `era-w4`, `era-w1-rbac`,
  `era-w5`) replace the placeholder body without touching the shell.
  """
  use BarkparkWeb, :live_view

  alias Barkpark.Tenancy

  @panels [
    {"sso", "Single Sign-On (SSO)", "SAML / OIDC connection per organization", "era-w3"},
    {"scim", "Directory Sync (SCIM)", "Provision & deprovision users from your IdP", "era-w4"},
    {"members", "Members & Roles", "Manage members and custom roles", "era-w1-rbac"},
    {"audit", "Audit Log", "Tenant-wide, tamper-evident activity trail", "era-w5"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    orgs =
      Tenancy.list_organizations()
      |> Enum.map(fn org ->
        %{org: org, workspaces: Tenancy.workspaces_for_organization(org.id)}
      end)

    {:ok,
     assign(socket,
       page_title: "Organization Admin",
       orgs: orgs,
       panels: @panels
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="org-admin" style="max-width: 880px; margin: 0 auto; padding: 24px;">
      <h1>Organization Admin</h1>
      <p style="color: #666;">
        Manage your organizations and the enterprise identity settings that span their workspaces.
      </p>

      <section aria-label="Organizations" style="margin-top: 24px;">
        <h2>Organizations</h2>
        <%= if @orgs == [] do %>
          <p>No organizations yet.</p>
        <% else %>
          <ul>
            <li :for={entry <- @orgs}>
              <strong>{entry.org.name}</strong>
              <span style="color:#888;">({entry.org.slug})</span>
              — {length(entry.workspaces)} workspace(s)
              <ul>
                <li :for={ws <- entry.workspaces}>{ws.name} <span style="color:#aaa;">/{ws.slug}</span></li>
              </ul>
            </li>
          </ul>
        <% end %>
      </section>

      <section aria-label="Settings" style="margin-top: 32px;">
        <h2>Enterprise settings</h2>
        <div
          :for={{key, title, desc, wave} <- @panels}
          data-panel={key}
          style="border:1px solid #e2e2e2; border-radius:8px; padding:16px; margin-bottom:12px;"
        >
          <h3 style="margin:0;">{title}</h3>
          <p style="margin:4px 0 0; color:#666;">{desc}</p>
          <p style="margin:8px 0 0; font-size:12px; color:#aaa;">Coming in {wave}.</p>
        </div>
      </section>
    </div>
    """
  end
end
