defmodule BarkparkWeb.Studio.OrgAdminLive do
  @moduledoc """
  The organization admin portal (era-w1-org-admin-shell + era-w5-admin-portal).

  Admin-gated (`:admin_studio` live_session → `LiveAuth :admin`). Per organization
  it surfaces the enterprise-identity config and the self-serve actions:

    * **SSO** — whether an OIDC and/or SAML connection is configured.
    * **Directory Sync (SCIM)** — the active SCIM tokens, plus a one-click
      **mint** (the token plaintext is shown ONCE, right after minting).
    * **Members & Roles** — the user-member count.
    * **Audit Log** — the recent audit activity.

  Note: gating is the existing global `:admin` (API-token) hook; a fully
  org-scoped self-serve login is the follow-up that rides the user-principal
  request-pipeline threading. Visual polish is a browser-verification follow-up.
  """
  use BarkparkWeb, :live_view
  import Ecto.Query, warn: false

  alias Barkpark.{Audit, Repo, Scim, Tenancy}
  alias Barkpark.Sso.{Oidc, Saml}
  alias Barkpark.Tenancy.Membership

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  @impl true
  def handle_event("mint_scim", %{"org" => org_id}, socket) do
    case Scim.mint_token(org_id, "admin-portal") do
      {:ok, {plaintext, _tok}} ->
        {:noreply, socket |> assign(minted: %{org_id => plaintext}) |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "could not mint SCIM token")}
    end
  end

  # era-w2-org-require-mfa: flip the org-wide MFA requirement. `to` carries
  # the target state so the click is idempotent against a stale render.
  @impl true
  def handle_event("toggle_require_mfa", %{"org" => org_id, "to" => to}, socket) do
    case Tenancy.set_organization_require_mfa(org_id, to == "true") do
      {:ok, _org} ->
        {:noreply, load(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "could not update the MFA requirement")}
    end
  end

  defp load(socket) do
    orgs = Enum.map(Tenancy.list_organizations(), &org_status/1)

    assign(socket,
      page_title: "Organization Admin",
      orgs: orgs,
      recent_audit: Audit.recent(20),
      minted: socket.assigns[:minted] || %{}
    )
  end

  defp org_status(org) do
    %{
      org: org,
      workspaces: Tenancy.workspaces_for_organization(org.id),
      oidc?: not is_nil(Oidc.connection_for_org_slug(org.slug)),
      saml?: not is_nil(Saml.connection_for_org_slug(org.slug)),
      scim_tokens: Scim.list_tokens(org.id),
      members: member_count(org.id)
    }
  end

  defp member_count(org_id) do
    ws_ids = org_id |> Tenancy.workspaces_for_organization() |> Enum.map(& &1.id)

    Repo.one(
      from m in Membership,
        where: m.principal_type == "user" and m.workspace_id in ^ws_ids,
        select: count(m.principal_id, :distinct)
    ) || 0
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="org-admin" style="max-width: 920px; margin: 0 auto; padding: 24px;">
      <h1>Organization Admin</h1>
      <p style="color:#666;">
        Configure enterprise SSO and directory sync, and review activity — per organization.
      </p>

      <p :if={@orgs == []}>No organizations yet.</p>

      <section
        :for={o <- @orgs}
        data-org={o.org.slug}
        style="border:1px solid #e2e2e2; border-radius:10px; padding:16px; margin:16px 0;"
      >
        <h2 style="margin:0 0 8px;">
          {o.org.name} <span style="color:#999; font-size:14px;">/{o.org.slug}</span>
        </h2>

        <div style="display:flex; gap:24px; flex-wrap:wrap; font-size:14px;">
          <div data-panel="sso">
            <strong>SSO:</strong>
            <span data-oidc={to_string(o.oidc?)}>OIDC {if o.oidc?, do: "✓", else: "—"}</span>,
            <span data-saml={to_string(o.saml?)}>SAML {if o.saml?, do: "✓", else: "—"}</span>
          </div>
          <div data-panel="members"><strong>Members:</strong> {o.members}</div>
          <div data-panel="scim"><strong>SCIM tokens:</strong> {length(o.scim_tokens)}</div>
          <div data-panel="mfa">
            <strong>Require MFA:</strong>
            <span data-require-mfa={to_string(o.org.require_mfa)}>
              {if o.org.require_mfa, do: "on", else: "off"}
            </span>
          </div>
        </div>

        <div style="margin-top:12px;">
          <button
            type="button"
            phx-click="mint_scim"
            phx-value-org={o.org.id}
            data-mint-scim={o.org.slug}
            style="font-size:13px; padding:6px 12px; border:1px solid #ccc; border-radius:6px; cursor:pointer;"
          >
            Mint SCIM token
          </button>
          <button
            type="button"
            phx-click="toggle_require_mfa"
            phx-value-org={o.org.id}
            phx-value-to={to_string(not o.org.require_mfa)}
            data-toggle-require-mfa={o.org.slug}
            style="font-size:13px; padding:6px 12px; border:1px solid #ccc; border-radius:6px; cursor:pointer;"
          >
            {if o.org.require_mfa, do: "Stop requiring MFA", else: "Require MFA org-wide"}
          </button>
          <p
            :if={@minted[o.org.id]}
            data-minted-token
            style="margin-top:8px; font-family:monospace; font-size:12px; background:#f6f6f6; padding:8px; border-radius:6px;"
          >
            Copy this token now — it won't be shown again:<br />{@minted[o.org.id]}
          </p>
        </div>
      </section>

      <section aria-label="Audit Log" style="margin-top:24px;">
        <h2>Recent activity</h2>
        <p :if={@recent_audit == []}>No activity yet.</p>
        <ul data-audit-log style="font-family:monospace; font-size:12px;">
          <li :for={e <- @recent_audit}>
            {e.action} · {e.category} <span style="color:#aaa;">{e.actor_id}</span>
          </li>
        </ul>
      </section>
    </div>
    """
  end
end
