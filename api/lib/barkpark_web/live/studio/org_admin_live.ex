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

  import BarkparkWeb.Studio.PageScroll
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

    # NAMED COST (doctrine lever #2): the disconnected mount render is DISCARDED
    # the moment the WebSocket connects and mount re-runs. `load/1` fans out to
    # `list_organizations` + per-org status (SSO/SAML/SCIM/member-count) +
    # `Audit.recent(20)` — a heavy read. This portal is admin-gated (no crawler
    # consumes the dead HTML), so run `load/1` ONLY on the live mount; the dead
    # render carries empty placeholders (there is no handle_params here).
    socket =
      if connected?(socket) do
        load(socket)
      else
        assign(socket, page_title: "Organization Admin", orgs: [], recent_audit: [], minted: %{})
      end

    {:ok, socket}
  end

  # `Scim.mint_token/2` has NO server-side debounce (every call unconditionally
  # inserts a new `Scim.Token` row) — a double-click with no guard here mints
  # TWO live tokens while the UI only ever shows the LAST plaintext (the prior
  # `assign(minted: %{org_id => plaintext})` REPLACED the map wholesale, so a
  # second in-flight click silently orphaned the first token). Guarded here:
  # once a plaintext is minted+shown for an org THIS session, a repeat click
  # no-ops instead of minting another — Elixir's serial per-process message
  # handling guarantees the first click's `assign(minted: ...)` is fully
  # applied before a second, even-near-simultaneous click is handled, so this
  # is airtight without needing an async round trip. A genuine re-mint (e.g.
  # provisioning a second IdP) needs a fresh page load, same as the existing
  # "shown once" plaintext banner already requires.
  @impl true
  def handle_event("mint_scim", %{"org" => org_id}, socket) do
    if Map.has_key?(socket.assigns.minted, org_id) do
      {:noreply, socket}
    else
      case Scim.mint_token(org_id, "admin-portal") do
        {:ok, {plaintext, _tok}} ->
          {:noreply,
           socket |> assign(minted: Map.put(socket.assigns.minted, org_id, plaintext)) |> load()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "could not mint SCIM token")}
      end
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

  # era-w8-org-session-policy: set the org-wide idle timeout + absolute lifetime
  # (seconds). Blank clears an axis (no limit → zero-tax). A non-positive /
  # non-numeric entry is rejected with a flash, not persisted.
  @impl true
  def handle_event("set_session_policy", %{"org" => org_id} = params, socket) do
    with {:ok, idle} <- parse_policy_seconds(params["idle"]),
         {:ok, absolute} <- parse_policy_seconds(params["absolute"]) do
      policy = %{idle_timeout_seconds: idle, absolute_lifetime_seconds: absolute}

      case Tenancy.set_organization_session_policy(org_id, policy) do
        {:ok, _org} ->
          {:noreply, socket |> put_flash(:info, "Session policy updated.") |> load()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "could not update the session policy")}
      end
    else
      :error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Enter a positive whole number of seconds, or leave blank for no limit."
         )}
    end
  end

  # "" / nil → nil (clear the bound). A positive integer string → {:ok, n}.
  # Anything else (0, negative, non-numeric) → :error, surfaced as a flash.
  defp parse_policy_seconds(nil), do: {:ok, nil}

  defp parse_policy_seconds(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      trimmed ->
        case Integer.parse(trimmed) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> :error
        end
    end
  end

  defp policy_label(nil), do: "no limit"
  defp policy_label(seconds) when is_integer(seconds), do: "#{seconds}s"

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
    <%!-- studio-shell child contract (BarkparkWeb.Studio.PageScroll): the
          shell is height:100vh + overflow:hidden, so a bare centred column
          here is CLIPPED and its tail is unreachable by any input. This
          wrapper fills the shell and owns the scroll; the centred column
          below is unchanged, so the reading measure is too. --%>
    <.studio_page_scroll>
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

          <div class="org-admin-status-group" data-panel="session-policy">
            <span class="org-admin-status-label">Session policy</span>
            <span
              class={"badge #{if o.org.session_idle_timeout_seconds, do: "badge-active", else: "badge-muted"}"}
              data-idle-timeout={to_string(o.org.session_idle_timeout_seconds)}
            >
              idle {policy_label(o.org.session_idle_timeout_seconds)}
            </span>
            <span
              class={"badge #{if o.org.session_absolute_lifetime_seconds, do: "badge-active", else: "badge-muted"}"}
              data-absolute-lifetime={to_string(o.org.session_absolute_lifetime_seconds)}
            >
              max {policy_label(o.org.session_absolute_lifetime_seconds)}
            </span>
          </div>
        </div>

        <div class="org-admin-actions">
          <button
            type="button"
            class="btn btn-sm"
            phx-click="mint_scim"
            phx-value-org={o.org.id}
            phx-disable-with="Minting..."
            disabled={Map.has_key?(@minted, o.org.id)}
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

        <form
          phx-submit="set_session_policy"
          data-session-policy-form={o.org.slug}
          class="org-admin-policy-form"
          style="display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end; margin-top: 12px;"
        >
          <input type="hidden" name="org" value={o.org.id} />
          <label class="text-sm" style="display: flex; flex-direction: column; gap: 4px;">
            Idle timeout (seconds)
            <input
              type="number"
              name="idle"
              min="1"
              step="1"
              inputmode="numeric"
              placeholder="no limit"
              value={o.org.session_idle_timeout_seconds}
              data-idle-input
            />
          </label>
          <label class="text-sm" style="display: flex; flex-direction: column; gap: 4px;">
            Absolute lifetime (seconds)
            <input
              type="number"
              name="absolute"
              min="1"
              step="1"
              inputmode="numeric"
              placeholder="no limit"
              value={o.org.session_absolute_lifetime_seconds}
              data-absolute-input
            />
          </label>
          <button type="submit" class="btn btn-sm" data-save-session-policy={o.org.slug}>
            Save session policy
          </button>
          <p class="text-sm" style="width: 100%; margin: 0; color: var(--fg-muted);">
            Blank = no limit. Governed users are logged out once a session sits idle past the
            idle timeout, or reaches the absolute lifetime — strictest across a user's orgs wins.
          </p>
        </form>

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

      <.bp_card aria-labelledby="trust-heading">
        <.bp_section_header id="trust-heading" title="Trust and legal">
          The security, compliance, and legal documents behind this deployment — each one click away.
        </.bp_section_header>
        <ul data-trust-panel class="org-admin-trust" style="list-style: none; margin: 0; padding: 0; display: grid; gap: 8px;">
          <li>
            <a href="/papers/soc2-controls-mapping" data-trust-link="soc2">
              SOC 2 controls mapping
            </a>
          </li>
          <li>
            <a href="/papers/vulnerability-disclosure-policy" data-trust-link="vdp">
              Vulnerability disclosure policy
            </a>
          </li>
          <li>
            <a href="/papers/dpa-template" data-trust-link="dpa">
              Data Processing Agreement (DPA) template
            </a>
          </li>
          <li>
            <a href="/papers/support-tiers" data-trust-link="support">
              Support tiers and SLA targets
            </a>
          </li>
          <li>
            <a href="/status" data-trust-link="status">
              Service status page
            </a>
          </li>
        </ul>
      </.bp_card>
    </div>
    </.studio_page_scroll>
    """
  end
end
