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
  import BarkparkWeb.StudioComponents.Controls

  alias Barkpark.{Audit, Repo, Scim, Tenancy}
  alias Barkpark.Sso.{Oidc, Saml}
  alias Barkpark.Tenancy.Membership

  @impl true
  def mount(params, _session, socket) do
    # Truthful return path (charter D5): held so a scoped surface's link here
    # (?return_to=<canonical path>) survives for a back affordance. Sanitized
    # against open-redirect; nil when arrived at flat/directly.
    socket = assign(socket, return_to: BarkparkWeb.Studio.ReturnTo.sanitize(params["return_to"]))
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
    <div class="org-admin" style="max-width: 920px; margin: 0 auto; padding: 24px; font-family: var(--font);">
      <h1 class="h1" style="margin-bottom: 4px;">Organization Admin</h1>
      <p class="text-sm" style="color: var(--fg-muted); margin-top: 0;">
        Configure enterprise SSO and directory sync, and review activity — per organization.
      </p>

      <.bp_card :if={@orgs == []}>
        <p style="margin: 0; color: var(--fg-muted);">No organizations yet.</p>
      </.bp_card>

      <.bp_card :for={o <- @orgs} data-org={o.org.slug}>
        <.bp_section_header title={o.org.name}>/{o.org.slug}</.bp_section_header>

        <div class="org-admin-status">
          <div class="org-admin-status-group" data-panel="sso">
            <span class="org-admin-status-label">SSO</span>
            <span
              class={"badge #{if o.oidc?, do: "badge-active", else: "badge-muted"}"}
              data-oidc={to_string(o.oidc?)}
            >
              OIDC {if o.oidc?, do: "on", else: "off"}
            </span>
            <span
              class={"badge #{if o.saml?, do: "badge-active", else: "badge-muted"}"}
              data-saml={to_string(o.saml?)}
            >
              SAML {if o.saml?, do: "on", else: "off"}
            </span>
          </div>

          <div class="org-admin-status-group" data-panel="members">
            <span class="org-admin-status-label">Members</span>
            <span class="badge badge-muted">{o.members}</span>
          </div>

          <div class="org-admin-status-group" data-panel="scim">
            <span class="org-admin-status-label">SCIM tokens</span>
            <span class="badge badge-muted">{length(o.scim_tokens)}</span>
          </div>

          <div class="org-admin-status-group" data-panel="mfa">
            <span class="org-admin-status-label">Require MFA</span>
            <span
              class={"badge #{if o.org.require_mfa, do: "badge-active", else: "badge-muted"}"}
              data-require-mfa={to_string(o.org.require_mfa)}
            >
              {if o.org.require_mfa, do: "on", else: "off"}
            </span>
          </div>
        </div>

        <div class="org-admin-actions">
          <button
            type="button"
            class="btn btn-sm"
            phx-click="mint_scim"
            phx-value-org={o.org.id}
            data-mint-scim={o.org.slug}
          >
            Mint SCIM token
          </button>
          <button
            type="button"
            class="btn btn-sm"
            phx-click="toggle_require_mfa"
            phx-value-org={o.org.id}
            phx-value-to={to_string(not o.org.require_mfa)}
            data-toggle-require-mfa={o.org.slug}
          >
            {if o.org.require_mfa, do: "Stop requiring MFA", else: "Require MFA org-wide"}
          </button>
        </div>

        <p :if={@minted[o.org.id]} data-minted-token class="org-admin-token">
          Copy this token now — it won't be shown again:<br />{@minted[o.org.id]}
        </p>
      </.bp_card>

      <.bp_card aria-labelledby="audit-heading">
        <.bp_section_header id="audit-heading" title="Recent activity" />
        <p :if={@recent_audit == []} style="margin: 0; color: var(--fg-muted);">No activity yet.</p>
        <ul :if={@recent_audit != []} data-audit-log class="org-admin-audit">
          <li :for={e <- @recent_audit}>
            <span class="org-admin-audit-action">{e.action}</span>
            <span class="badge badge-muted">{e.category}</span>
            <span class="org-admin-audit-actor">{e.actor_id}</span>
          </li>
        </ul>
      </.bp_card>
    </div>
    """
  end
end
