defmodule BarkparkWeb.Studio.SettingsLive do
  @moduledoc """
  **Workspace Settings** — the admin control panel for one workspace.

  Three stacked sections, most-reached first:

    1. **Workspace theme** — the persisted theme identity (`render_theme_section/1`).
    2. **Plugins** — per-workspace enable/disable + Desk-Structure placement for
       every installed plugin (`render_plugins_section/1`). Reads effective state
       via `Barkpark.Plugins.Enablement.effective/1`; persists into
       `workspaces.settings["plugins"]` via `Tenancy.set_workspace_plugin_settings/2`
       (charter studio-structure-polish, Decisions 2/4/10). Disabling is
       non-destructive — the plugin's doc types move to the `…Rest` folder, never
       deleted.
    3. **Plugin credentials** — the encrypted-JSON credential editor (below).

  ## Plugin credentials (encrypted-JSON editor)

  Admin types a `plugin_name`, loads the (masked) values, edits them, saves
  them back. A reveal-on-click control re-fetches the unmasked value and
  records a `reveal` audit row.

  EVERY handler in this sub-panel — `load` included — re-gates on
  INSTALLATION-admin authority (`guard_installation_admin/2`). The mount only
  proves the actor administers the URL workspace, while `plugin_settings` is
  installation-GLOBAL, and even the masked read projection is partial rather
  than anonymous. The rest of the page (theme, plugin surfacing, execution
  profile) stays workspace-admin business.

  ## Typed-form vs raw-JSON path

  When the named plugin contributes a `settings_schema/0` (via the resolver
  chain in `Barkpark.Plugins.Registry`), the form switches to a typed view
  rendered generically by spec — labels, input types, `:masked` flags for
  per-field reveal buttons, `:options` for `:select`, `:placeholder`,
  `:hint`, and host-side `:required` enforcement on save. When no spec is
  available, the legacy raw-JSON textarea is used.

  The host knows NOTHING about specific plugins. The bokbasen Settings
  panel is rendered exactly like any other plugin's panel — by reading
  the spec OnixEdit returns from `Plugins.Registry.collect_settings_schema/1`.
  """

  use BarkparkWeb, :live_view

  import BarkparkWeb.StudioComponents.Controls

  require Logger

  alias Barkpark.Accounts.User
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Content.Analytics
  alias Barkpark.Plugins.Enablement
  alias Barkpark.Plugins.Registry, as: PluginsRegistry
  alias Barkpark.Plugins.Settings
  alias Barkpark.Plugins.Settings.Masking
  alias Barkpark.Structure
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @placement_labels [
    {"main", "Main structure"},
    {"plugins", "Plugins folder"},
    {"top_menu", "Top menu only"}
  ]

  # Scoped mount (ssp-w3, charter D15). On `/w/:ws/p/:proj/d/:dataset/studio/
  # settings` LiveScope has already bound `current_workspace` from the URL — the
  # panel is URL-scoped, so the switcher RE-BINDS it and every write targets the
  # workspace the admin is looking at (the mount-pinned-Default hazard is gone).
  # SettingsLive mounts ONLY via the scoped-admin canonical
  # `/w/:ws/p/:proj/studio/settings` — the flat `/studio/settings` spelling
  # 302s there via AdminStudioRedirectController, so no flat-compat mount
  # branch exists here (a hand-built dataset-full redirect target would land
  # in the StudioLive catch-all and trips studio-link-lint).
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_page(socket)}
  end

  # Re-derive the URL-bound view on every scoped patch. A scope switch fired
  # from here is a `push_navigate` remount (mount re-runs), but LiveScope also
  # re-binds `current_workspace` on a same-session `handle_params`, so refresh
  # the theme + plugin rows here too — they must never lag the bound scope.
  @impl true
  def handle_params(_params, _uri, socket) do
    # NAMED COST (doctrine lever #2): `handle_params` runs on the DISCARDED
    # disconnected render AND again on connect. `assign_plugin_rows/1` fans out
    # to several DB reads (Enablement.effective, Structure schema scan,
    # list_schemas, type_census) and `workspace_theme/1` is another. This page
    # is admin-gated (no crawler consumes the dead HTML), so load the settings
    # projection ONLY on the live mount; the dead render keeps the empty
    # defaults `assign_page/1` seeded.
    socket =
      if connected?(socket) do
        socket
        |> assign(:bp_theme, Tenancy.workspace_theme(socket.assigns[:current_workspace]))
        |> assign(
          :execution_profile,
          workspace_execution_profile(socket.assigns[:current_workspace])
        )
        |> assign_plugin_rows()
      else
        socket
      end

    {:noreply, socket}
  end

  defp assign_page(socket) do
    socket
    |> assign(
      page_title: "Workspace Settings",
      plugin_name: "",
      settings_json: "",
      settings_fields: [],
      typed_form: %{},
      revealed: %{},
      masked: true,
      loaded?: false,
      error: nil,
      placement_labels: @placement_labels,
      # Workspace theme picker (ts-w4e). `current_workspace` + `bp_theme` are
      # resolved by LiveScope + StudioChrome (nil on an unseeded tenancy).
      known_themes: Tenancy.known_themes(),
      # A scope switch fired from Settings re-opens Settings under the NEW
      # scope, not the desk (chrome D16 seam) — StudioChrome appends this to
      # the target's studio_root.
      scope_subpath: "/settings",
      # Empty defaults for the dead render — the connected `handle_params`
      # loads the real theme + plugin rows once, on connect (see there).
      bp_theme: nil,
      # Per-workspace chat execution profile (connectors W23-2/D207). Seeded
      # `nil` for the dead render; `handle_params` projects the persisted
      # `settings["chat"]["execution_profile"]` once on connect. `nil`/anything
      # other than `"cloud"` reads as the self-hosted default in the switch.
      execution_profile: nil,
      plugin_rows: []
    )
  end

  @impl true
  def handle_event("update_name", %{"plugin_name" => name}, socket) do
    {:noreply, assign(socket, plugin_name: name)}
  end

  # `load` is a READ of the installation-global credential store, so it carries
  # the same authority requirement as its four siblings (D274 follow-up). The
  # masked projection is NOT anonymous: `Masking.mask/1` emits the last FOUR
  # characters of every secret verbatim, the typed projection renders every
  # non-`:masked` field (api_base, oauth_token_url, client_role) in FULL
  # plaintext, and the found/not-found split ("No settings yet for …") is a
  # presence oracle over the whole installation's plugin inventory. Fail-closed
  # with ZERO `Settings.*` calls — a refused load must not even prove whether
  # the named plugin has a row.
  def handle_event("load", %{"plugin_name" => name}, socket) do
    guard_installation_admin(socket, fn ->
      fields = fields_for(name)

      if fields == [] do
        load_generic(socket, name)
      else
        load_typed(socket, name, fields)
      end
    end)
  end

  def handle_event("reveal", %{"plugin_name" => name}, socket) do
    guard_installation_admin(socket, fn ->
      do_reveal(socket, name)
    end)
  end

  def handle_event("reveal_field", %{"field" => field}, socket) do
    guard_installation_admin(socket, fn ->
      do_reveal_field(socket, field)
    end)
  end

  def handle_event("save", %{"plugin_name" => name} = params, socket) do
    guard_installation_admin(socket, fn ->
      fields = fields_for(name)

      if fields == [] do
        save_generic(socket, name, params)
      else
        save_typed(socket, name, fields, params)
      end
    end)
  end

  def handle_event("delete", %{"plugin_name" => name}, socket) do
    guard_installation_admin(socket, fn ->
      do_delete(socket, name)
    end)
  end

  # Workspace theme picker (ts-w4e). Persists `settings["theme"]` on the current
  # workspace and re-assigns `:bp_theme` so the hidden `#bp-theme-mirror` element
  # re-renders → the `BpThemeMirror` hook stamps `document.documentElement`
  # instantly (preview with no reload). The server-side stamp on the next full
  # load comes from StudioChrome resolving the persisted value.
  def handle_event("set_workspace_theme", %{"theme" => theme} = params, socket) do
    guard_bound_ws(socket, params, fn ->
      guard_ws_admin(socket, "theme", fn ->
        do_set_workspace_theme(socket, theme)
      end)
    end)
  end

  # ── Per-workspace plugin surfacing (studio-structure-polish D2/D4/D10) ──
  #
  # An admin flips an installed plugin on/off for THIS workspace, or moves it
  # between the MAIN Desk Structure / the Plugins folder / the top menu. State
  # persists into `workspaces.settings["plugins"]` (merged, so the theme key is
  # preserved) and is re-read through `Enablement.effective/1` so the row always
  # reflects the merged declaration-default + override truth. Disabling never
  # deletes: the doc types move to the …Rest folder.
  def handle_event("toggle_plugin", %{"plugin" => name} = params, socket) do
    guard_bound_ws(socket, params, fn ->
      guard_ws_admin(socket, "plugins", fn ->
        case current_row(socket, name) do
          %{enabled: enabled} ->
            put_plugin_override(socket, name, %{"enabled" => not enabled},
              flash:
                if(enabled,
                  do: "Disabled #{display_name(name)} for this workspace.",
                  else: "Enabled #{display_name(name)} for this workspace."
                )
            )

          nil ->
            {:noreply, put_flash(socket, :error, "Unknown plugin #{inspect(name)}.")}
        end
      end)
    end)
  end

  def handle_event(
        "set_plugin_placement",
        %{"plugin" => name, "placement" => placement} = params,
        socket
      )
      when placement in ["main", "plugins", "top_menu"] do
    guard_bound_ws(socket, params, fn ->
      guard_ws_admin(socket, "plugin placement", fn ->
        # Same unknown-plugin guard as toggle_plugin: a forged plugin name must
        # not persist a junk override entry into the workspace settings.
        case current_row(socket, name) do
          %{} ->
            put_plugin_override(socket, name, %{"placement" => placement},
              flash: "Moved #{display_name(name)} to #{placement_label(placement)}."
            )

          nil ->
            {:noreply, put_flash(socket, :error, "Unknown plugin #{inspect(name)}.")}
        end
      end)
    end)
  end

  # ── Per-workspace chat execution profile (connectors W23-2, D207/D211) ──
  #
  # Flip THIS workspace's chat turns between the self-hosted runner (default)
  # and the cloud sandbox. State persists into `workspaces.settings["chat"]
  # ["execution_profile"]` via the D205 Tenancy pair (merged, so the theme and
  # plugin keys are preserved); `ClaudeChat.Session.init/1` resolves it once per
  # spawn, fail-safe to `:self_hosted`.
  #
  # SECURITY (D211): the execution profile is routing-security-relevant — it
  # routes a tenant's turns into a sandbox that shares ONE flat instance key —
  # so the coarse mount gate (a GLOBAL-permission admin check that does NOT
  # enforce admin OF THE TARGET workspace; see live_auth.ex) is NOT sufficient.
  # This handler RE-GATES per write on `TenancyAuth.workspace_admin?/2` (the
  # ConnectorsLive precedent), fail-closed: a principal who merely passes the
  # mount gate but is not an owner/admin of the bound workspace is REFUSED with
  # NOTHING written. `guard_bound_ws/3` still runs first (the stale-scope belt);
  # the re-gate is the per-target-workspace authority check it does not do.
  def handle_event("toggle_execution_profile", %{"ws" => _} = params, socket) do
    guard_bound_ws(socket, params, fn ->
      do_toggle_execution_profile(socket)
    end)
  end

  # ── Fail-closed scope-write guard (ssp-w3, charter D17) ─────────────────
  #
  # Every workspace-scoped WRITE (theme / plugin toggle / placement) stamps the
  # RENDERED workspace id into its control (`phx-value-ws` / a hidden `ws`
  # field). Here we compare that snapshot against the LIVE URL-bound
  # `current_workspace.id` — LiveScope's independent truth, re-bound from the
  # URL on every scoped navigation. A mismatch means the DOM the admin acted on
  # is stale relative to the bound scope (a scope switch raced the click): we
  # REFUSE, flash, and re-bind the rows — NEVER silently retarget another
  # workspace's settings. `credentials` are installation-global (settings.ex),
  # so they are out of this guard's scope by design.
  #
  # A control that omits `ws` (a legacy/forged event) falls through to the write,
  # which still targets the URL-bound `current_workspace` — the scoping itself,
  # not this stamp, is what kills the wrong-workspace hazard; the stamp is the
  # belt-and-suspenders that refuses a visibly-stale action.

  # Fall-through: a stale/unknown phx event must not FunctionClauseError-crash
  # the session. Keep LAST among handle_event/3 clauses.
  def handle_event(event, _params, socket) do
    Logger.warning("studio: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # ── Credential handler bodies (reveal / reveal_field / delete) ───────────
  #
  # Invoked ONLY inside `guard_installation_admin/2` (see the handlers above);
  # hoisted out of the handle_event/3 clause group so the clauses stay grouped.
  defp do_reveal(socket, name) do
    case Settings.reveal(name, user_id: user_id(socket)) do
      {:ok, map} ->
        fields = socket.assigns.settings_fields

        socket =
          if fields == [] do
            assign(socket,
              settings_json: pretty(map),
              masked: false,
              loaded?: true,
              error: nil
            )
          else
            typed_form =
              Enum.reduce(fields, socket.assigns.typed_form, fn field, acc ->
                key = flat_key(field)
                Map.put(acc, key, to_string(Map.get(map, key, "")))
              end)

            revealed = Enum.into(masked_keys(fields), %{}, fn k -> {k, true} end)

            assign(socket,
              typed_form: typed_form,
              revealed: revealed,
              masked: false,
              loaded?: true,
              error: nil
            )
          end

        {:noreply, put_flash(socket, :info, "Revealed (audited).")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No settings to reveal.")}
    end
  end

  defp do_reveal_field(socket, field) do
    fields = socket.assigns.settings_fields
    plugin_name = socket.assigns.plugin_name

    if field in masked_keys(fields) do
      case Settings.reveal(plugin_name, user_id: user_id(socket)) do
        {:ok, map} ->
          typed_form =
            Map.put(socket.assigns.typed_form, field, to_string(Map.get(map, field, "")))

          revealed = Map.put(socket.assigns.revealed, field, true)

          {:noreply,
           socket
           |> assign(
             typed_form: typed_form,
             revealed: revealed,
             masked: not all_masked_revealed?(fields, revealed),
             error: nil
           )
           |> put_flash(:info, "Revealed #{field} (audited).")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "No settings to reveal.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp do_delete(socket, name) do
    case Settings.delete(name, user_id: user_id(socket)) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           plugin_name: name,
           settings_json: "",
           settings_fields: [],
           typed_form: %{},
           revealed: %{},
           masked: true,
           loaded?: false,
           error: nil
         )
         |> put_flash(:info, "Deleted #{name}.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Nothing to delete.")}
    end
  end

  defp guard_bound_ws(socket, params, fun) do
    bound =
      case socket.assigns[:current_workspace] do
        %{id: id} -> id
        _ -> nil
      end

    rendered = params["ws"]

    cond do
      is_nil(bound) ->
        {:noreply, put_flash(socket, :error, "No workspace in scope to configure.")}

      is_binary(rendered) and rendered != bound ->
        {:noreply,
         socket
         |> assign_plugin_rows()
         |> put_flash(
           :error,
           "Scope changed — nothing was saved. Reloaded this workspace's settings."
         )}

      true ->
        fun.()
    end
  end

  # ── Per-write workspace-admin authority re-gate (connectors W34, D268) ──
  #
  # The scoped-admin mount gate (W26 `LiveAuth.:scoped_admin`) authorizes the
  # actor against the TARGET workspace AT MOUNT — but a LiveView outlives that
  # single check. A role downgrade (admin → member, or the actor removed from
  # the workspace) AFTER mount leaves a still-mounted socket able to fire these
  # theme / plugin writes under authority that is no longer true. So every
  # state-changing workspace mutation re-reads the actor's LIVE membership role
  # at the write boundary, exactly as `do_toggle_execution_profile/1` does
  # (D211): `workspace_admin?/2` runs a FRESH `Repo.one` per call
  # (auth.ex membership/2 — zero socket cache), so a mid-socket downgrade IS
  # seen here. Fail-closed, negated-cond-first: a principal who is not an
  # owner/admin of the bound workspace is REFUSED with ZERO writes. This is the
  # per-target-workspace authority check `guard_bound_ws/3` (the stale-scope
  # belt) does not perform; the two compose, guard_bound_ws first.
  defp guard_ws_admin(socket, thing, fun) do
    ws = socket.assigns[:current_workspace]
    principal = socket.assigns[:api_token] || socket.assigns[:current_user]

    cond do
      not (is_map(ws) and not is_nil(principal) and
               TenancyAuth.workspace_admin?(principal, ws.id)) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You need to be an owner or admin of this workspace to change its #{thing}."
         )}

      true ->
        fun.()
    end
  end

  # ── Installation-admin re-gate on the credential handlers (connectors W35, D274) ──
  #
  # Plugin credentials live in the installation-GLOBAL `plugin_settings` store
  # (PK `plugin_name`, NO tenant column — `SettingsRecord`): ONE
  # bokbasen/indx account per deployment, shared by EVERY tenant. The W26
  # `:scoped_admin` mount gate only proves the actor administers the URL
  # workspace — an admin of workspace B and ONLY B cleared it and could
  # reveal / overwrite / delete every tenant's credentials (#5972 explicitly
  # scoped credentials OUT of its per-write belt; this guard supplies the
  # missing authority check). So each credential handler (load / reveal /
  # reveal_field / save / delete) re-gates on INSTALLATION-level admin
  # authority: a token principal must hold the global "admin" permission
  # (`Auth.has_permission?/2` — the pre-W26 flat-:admin invariant restored for
  # this subset); a user principal must be an owner/admin of the seeded
  # Default (installation) workspace, via the `TenancyAuth.authorize/3`
  # chokepoint. Fail-closed, negated-cond-first: a missing/unknown principal,
  # an unseeded Default workspace, or insufficient authority is REFUSED with
  # ZERO `Settings.*` calls — nothing read, revealed, written, or deleted.
  #
  # `load` joined this set in the D274 follow-up: it is the READ half of the
  # same authority, and the mask it renders is partial, not anonymous (see the
  # handler's own comment). The guard is deliberately the WHOLE handler set, not
  # a mask-strength tweak — the leak is a SCOPE MISMATCH (mount authorizes
  # workspace-admin-of-the-URL, the store is installation-global), and only an
  # authority check closes a scope mismatch.
  defp guard_installation_admin(socket, fun) do
    principal = socket.assigns[:api_token] || socket.assigns[:current_user]

    cond do
      not installation_admin?(principal) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Plugin credentials are installation-wide — viewing or managing them requires installation-admin authority."
         )}

      true ->
        fun.()
    end
  end

  defp installation_admin?(%ApiToken{} = token), do: Auth.has_permission?(token, "admin")

  defp installation_admin?(%User{} = user) do
    case Tenancy.get_default_workspace() do
      %{id: ws_id} -> TenancyAuth.authorize(user, ws_id, :admin) == :ok
      _ -> false
    end
  end

  defp installation_admin?(_), do: false

  # Workspace theme write, invoked by `set_workspace_theme` inside the
  # fail-closed scope guard. Persists `settings["theme"]` on the URL-bound
  # workspace and re-assigns `:bp_theme` so the `#bp-theme-mirror` hook stamps
  # `document.documentElement` instantly (preview with no reload).
  defp do_set_workspace_theme(socket, theme) do
    case socket.assigns[:current_workspace] do
      %{id: _} = ws ->
        case Tenancy.set_workspace_theme(ws.id, theme) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:current_workspace, updated)
             |> assign(:bp_theme, Tenancy.workspace_theme(updated))
             |> put_flash(:info, "Workspace theme set to #{theme}.")}

          {:error, :unknown_theme} ->
            {:noreply, put_flash(socket, :error, "Unknown theme #{inspect(theme)}.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save the workspace theme.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No workspace in scope to theme.")}
    end
  end

  # Execution-profile write, invoked inside `guard_bound_ws/3`. Composes the
  # per-write `workspace_admin?/2` re-gate (D211) with a server-derived next
  # value: the toggle NEVER trusts a client-supplied profile string — it reads
  # the current persisted value and flips it (cloud → self_hosted, anything else
  # → cloud), then guards the derived value against the known set before writing
  # BY ID through `set_workspace_chat_settings/2` (never the struct, D210).
  defp do_toggle_execution_profile(socket) do
    ws = socket.assigns[:current_workspace]
    principal = socket.assigns[:api_token] || socket.assigns[:current_user]

    cond do
      not (is_map(ws) and not is_nil(principal) and
               TenancyAuth.workspace_admin?(principal, ws.id)) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You need to be an owner or admin of this workspace to change its execution profile."
         )}

      true ->
        chat = Tenancy.workspace_chat_settings(ws)
        next = if chat["execution_profile"] == "cloud", do: "self_hosted", else: "cloud"

        if next in ~w(cloud self_hosted) do
          merged = Map.put(chat, "execution_profile", next)

          case Tenancy.set_workspace_chat_settings(ws.id, merged) do
            {:ok, updated} ->
              {:noreply,
               socket
               |> assign(:current_workspace, updated)
               |> assign(:execution_profile, next)
               |> put_flash(:info, execution_profile_flash(next))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Could not save the execution profile.")}
          end
        else
          {:noreply, put_flash(socket, :error, "Unknown execution profile.")}
        end
    end
  end

  # Raw persisted profile string for a workspace (`"cloud" | "self_hosted" |
  # nil`). Reused by the connected `handle_params` projection and the switch's
  # `checked` test; guards a nil workspace to `nil` (self-hosted default).
  defp workspace_execution_profile(ws) do
    Tenancy.workspace_chat_settings(ws)["execution_profile"]
  end

  defp execution_profile_flash("cloud"),
    do: "Chat turns for this workspace now run in the cloud sandbox."

  defp execution_profile_flash("self_hosted"),
    do: "Chat turns for this workspace now run on the self-hosted runner."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="settings-live" style="max-width: 720px; margin: 32px auto; padding: 0 24px; font-family: var(--font);">
      <h1 class="h1" style="margin-bottom: 4px;">Workspace Settings</h1>
      <%= if @current_workspace do %>
        <p style="color: var(--fg-muted); margin-top:0; display:flex; align-items:center; gap:.5rem; flex-wrap:wrap;">
          <span>Theme, plugins and credentials for</span>
          <span
            data-test-id="settings-bound-workspace"
            data-workspace-id={@current_workspace.id}
            style="display:inline-flex; align-items:center; gap:.35rem; font-weight:600; color:var(--fg); border:1px solid var(--border); border-radius:999px; padding:.1rem .6rem;"
          >
            {@current_workspace.name}
          </span>
        </p>
        <p style="color: var(--fg-muted); margin-top:0; font-size:.9em;">
          Everything here writes to <strong>{@current_workspace.name}</strong>.
          Switch workspace from the top bar to configure another.
        </p>
      <% else %>
        <p style="color: var(--fg-muted); margin-top:0;">
          Theme, plugins and credentials for this workspace.
        </p>
      <% end %>

      <%!-- No flash markup here ON PURPOSE (sup-w5bk). The `:studio` live
            layout this route mounts under renders `<.studio_flash flash={@flash} />`
            (nav.ex) with role=status/aria-live=polite for :info and
            role=alert/aria-live=assertive for :error. This page used to render
            its OWN copy as well, so one `put_flash/3` painted TWO banners and
            announced TWICE to assistive tech. The layout is the single sink;
            do not re-add a page-local one. --%>

      {render_theme_section(assigns)}

      {render_execution_profile_section(assigns)}

      {render_plugins_section(assigns)}

      <.bp_card aria-labelledby="credentials-heading">
        <.bp_section_header id="credentials-heading" title="Plugin credentials">
          Encrypted JSON store. Values are masked on load — click <em>Reveal</em>
          to fetch unmasked (audited). Credentials are global to the installation,
          not per-workspace.
        </.bp_section_header>

        <form phx-change="update_name" phx-submit="load" style="margin-bottom: 16px;">
          <.bp_field_row label="Plugin name" for="plugin_name" required>
            <div style="display: flex; gap: 8px;">
              <.bp_input
                id="plugin_name"
                name="plugin_name"
                value={@plugin_name}
                placeholder="e.g. onixedit, bokbasen"
                autocomplete="off"
                required
              />
              <button type="submit" class="btn btn-primary">Load</button>
            </div>
          </.bp_field_row>
        </form>

        <%= if @settings_fields == [] do %>
          {render_generic_form(assigns)}
        <% else %>
          {render_typed_form(assigns)}
        <% end %>

        <%= if @error do %>
          <p role="alert" style="color: var(--destructive); margin-top: 12px;">{@error}</p>
        <% end %>

        <p style="margin-top: 16px; color: var(--fg-muted); font-size: 13px;">
          Status: {if @loaded?, do: "loaded", else: "empty"} · {if @masked, do: "masked", else: "revealed"}
        </p>
      </.bp_card>
    </div>
    """
  end

  # ── Workspace theme picker (ts-w4e) ────────────────────────────────────
  #
  # One persisted, server-resolved theme identity per workspace. The hidden
  # `#bp-theme-mirror` element carries the live `data-bp-theme`; the root
  # layout's `BpThemeMirror` hook mirrors it onto `document.documentElement`
  # on mount AND on every update, so a pick previews instantly with no reload.
  # Theme identity is orthogonal to the light/dark toggle (which stays entirely
  # client-side); this control never touches `data-theme`.
  defp render_theme_section(assigns) do
    ~H"""
    <.bp_card aria-labelledby="theme-heading">
      <.bp_section_header id="theme-heading" title="Workspace theme" />

      <div
        id="bp-theme-mirror"
        phx-hook="BpThemeMirror"
        data-bp-theme={@bp_theme}
        hidden
      >
      </div>

      <%= if @current_workspace do %>
        <form phx-change="set_workspace_theme">
          <input type="hidden" name="ws" value={@current_workspace.id} />
          <.bp_field_row label="Theme" for="workspace-theme">
            <.bp_select
              id="workspace-theme"
              name="theme"
              value={to_string(@bp_theme)}
              options={@known_themes}
            />
            <:hint>
              The theme identity for <strong>{@current_workspace.name}</strong>.
              Applies to the reader, Studio and emailed papers — light/dark mode
              stays a separate switch.
              <%= if length(@known_themes) == 1 do %>
                One theme ships today; more land as the compiler emits them.
              <% else %>
                Saved server-side and stamped on the first byte — no flash.
              <% end %>
            </:hint>
          </.bp_field_row>
        </form>
      <% else %>
        <p role="status" style="color: var(--fg-muted); margin-bottom: 0;">
          No workspace in scope to theme.
        </p>
      <% end %>
    </.bp_card>
    """
  end

  # ── Chat execution profile (connectors W23-2, D207/D209) ────────────────
  #
  # One `.bp_switch` clone of the plugin-enablement toggle: OFF = self-hosted
  # runner (the fail-safe default), ON = cloud sandbox. It rides the plugin
  # toggle's `phx-click` idiom (a discrete event carrying `phx-value-ws`), NOT
  # the theme `phx-change` form — the handler derives the next value server-side
  # and re-gates the write on `workspace_admin?/2`. `checked` is true ONLY for a
  # persisted `"cloud"`, so a nil / unset / malformed value renders as
  # self-hosted, mirroring the resolver's fail-safe.
  defp render_execution_profile_section(assigns) do
    ~H"""
    <.bp_card aria-labelledby="execution-profile-heading">
      <.bp_section_header id="execution-profile-heading" title="Chat execution profile" />

      <%= if @current_workspace do %>
        <div
          data-test-id="execution-profile-control"
          data-execution-profile={@execution_profile || "self_hosted"}
          style="display:flex; flex-wrap:wrap; align-items:center; gap:.75rem;"
        >
          <div style="flex:1 1 16rem; min-width:14rem;">
            <p style="margin:0; color:var(--fg-muted);">
              Where <strong>{@current_workspace.name}</strong>'s Studio chat turns run.
              <strong>Self-hosted</strong> uses this instance's runner;
              <strong>Cloud</strong> routes each turn into an isolated cloud sandbox.
              Only an owner or admin of this workspace can change it, and a flip
              takes effect on the workspace's next chat turn.
            </p>
          </div>

          <.bp_switch
            checked={@execution_profile == "cloud"}
            on_label="Cloud"
            off_label="Self-hosted"
            phx-click="toggle_execution_profile"
            phx-value-ws={@current_workspace.id}
            aria-label="Run this workspace's chat turns in the cloud sandbox"
          />
        </div>
      <% else %>
        <p role="status" style="color: var(--fg-muted); margin-bottom: 0;">
          No workspace in scope to configure.
        </p>
      <% end %>
    </.bp_card>
    """
  end

  # ── Plugins section (studio-structure-polish D2/D4/D10) ─────────────────
  #
  # Every INSTALLED plugin (the boot registry set) with a per-workspace enabled
  # toggle, a Desk-Structure placement select, and a "default" badge when the
  # workspace holds no override for it (surfacing the declaration default). All
  # state flows through `Enablement.effective/1` + `Tenancy.set_workspace_plugin_settings/2`.
  defp render_plugins_section(assigns) do
    ~H"""
    <.bp_card aria-labelledby="plugins-heading">
      <.bp_section_header id="plugins-heading" title="Plugins" />

      <%= cond do %>
        <% is_nil(@current_workspace) -> %>
          <p role="status" style="color: var(--fg-muted); margin-bottom:0;">
            No workspace in scope to configure.
          </p>
        <% @plugin_rows == [] -> %>
          <p role="status" style="color: var(--fg-muted); margin-bottom:0;">
            No plugins are installed on this server.
          </p>
        <% true -> %>
          <p style="color: var(--fg-muted);">
            Turn a plugin off to keep this workspace clean, or move where it lands
            in the Desk Structure. Disabling never deletes content — its document
            types move to the <strong>…Rest</strong> folder, still fully readable.
          </p>

          <ul style="list-style:none; padding:0; margin:0; display:flex; flex-direction:column; gap:.5rem;">
            <%= for row <- @plugin_rows do %>
              <li
                data-plugin={row.name}
                data-enabled={to_string(row.enabled)}
                data-placement={to_string(row.placement)}
                data-has-override={to_string(row.has_override)}
                style="border:1px solid var(--border); border-radius:6px; padding:.75rem 1rem; display:flex; flex-wrap:wrap; align-items:center; gap:.75rem;"
              >
                <div style="flex:1 1 12rem; min-width:12rem;">
                  <div style="display:flex; align-items:center; gap:.5rem;">
                    <strong>{row.display}</strong>
                    <%= unless row.has_override do %>
                      <span
                        title={default_badge_title(row)}
                        style="font-size:.72em; text-transform:uppercase; letter-spacing:.04em; border:1px solid var(--border); color:var(--fg-muted); border-radius:999px; padding:.05rem .5rem;"
                      >
                        default
                      </span>
                    <% end %>
                  </div>
                  <small style="color:var(--fg-muted);">
                    {row.name} · {default_badge_title(row)}
                  </small>
                </div>

                <.bp_switch
                  checked={row.enabled}
                  on_label="Enabled"
                  off_label="Disabled"
                  phx-click="toggle_plugin"
                  phx-value-plugin={row.name}
                  phx-value-ws={@current_workspace.id}
                  aria-label={"Enable #{row.display} for this workspace"}
                />

                <form phx-change="set_plugin_placement" style="margin: 0;">
                  <input type="hidden" name="plugin" value={row.name} />
                  <input type="hidden" name="ws" value={@current_workspace.id} />
                  <label style="display: inline-flex; align-items: center; gap: 8px; color: var(--fg-muted); font-size: 13px;">
                    Placement
                    <.bp_select
                      name="placement"
                      value={to_string(row.placement)}
                      options={@placement_labels}
                      disabled={not row.enabled}
                    />
                  </label>
                </form>

                <%= if row[:hint] do %>
                  <p
                    data-plugin-hint={row.name}
                    role="note"
                    style="flex-basis:100%; margin:.15rem 0 0; color:var(--fg-muted); font-size:.82em; display:flex; align-items:center; gap:.4rem;"
                  >
                    <span aria-hidden="true">ⓘ</span>
                    {row.hint}
                  </p>
                <% end %>
              </li>
            <% end %>
          </ul>

          <p style="color: var(--fg-muted); font-size: 13px; margin-bottom: 0;">
            Installed plugins always keep their schemas, routes and background jobs
            registered — these controls decide only what THIS workspace surfaces.
          </p>
      <% end %>
    </.bp_card>
    """
  end

  defp render_generic_form(assigns) do
    ~H"""
    <form phx-submit="save">
      <input type="hidden" name="plugin_name" value={@plugin_name} />
      <.bp_textarea id="settings_json" name="settings_json" rows={14} value={@settings_json} mono />

      <div style="display: flex; gap: 8px; margin-top: 12px;">
        <button
          type="submit"
          class="btn btn-primary"
          phx-disable-with="Saving..."
          disabled={@plugin_name == ""}
        >
          Save
        </button>
        <button
          type="button"
          class="btn"
          phx-click="reveal"
          phx-value-plugin_name={@plugin_name}
          disabled={not @loaded? or not @masked}
        >
          Reveal
        </button>
        <button
          type="button"
          class="btn btn-destructive"
          phx-click="delete"
          phx-value-plugin_name={@plugin_name}
          phx-disable-with="Deleting..."
          data-confirm="Delete settings for this plugin?"
          disabled={not @loaded?}
        >
          Delete
        </button>
      </div>
    </form>
    """
  end

  defp render_typed_form(assigns) do
    ~H"""
    <form phx-submit="save" data-preset={@plugin_name}>
      <input type="hidden" name="plugin_name" value={@plugin_name} />

      <fieldset style="border: 1px solid var(--border-muted); border-radius: var(--radius); padding: 16px 20px; margin-bottom: 12px;">
        <legend style="padding: 0 8px; font-size: 13px; font-weight: 600; color: var(--fg);">{@plugin_name} settings</legend>

        <%= for field <- @settings_fields do %>
          {render_field(Map.merge(assigns, %{field: field, key: flat_key(field)}))}
        <% end %>
      </fieldset>

      <div style="display: flex; gap: 8px; margin-top: 12px;">
        <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">Save</button>
        <button
          type="button"
          class="btn btn-destructive"
          phx-click="delete"
          phx-value-plugin_name={@plugin_name}
          phx-disable-with="Deleting..."
          data-confirm={"Delete settings for #{@plugin_name}?"}
          disabled={not @loaded?}
        >
          Delete
        </button>
      </div>
    </form>
    """
  end

  defp render_field(assigns) do
    assigns =
      assign(
        assigns,
        :value,
        Map.get(assigns.typed_form, assigns.key, default_for(assigns.field))
      )

    ~H"""
    <.bp_field_row label={@field.label} for={@key} required={!!@field[:required]}>
      <div style="display: flex; gap: 8px; align-items: center;">
        {render_input(assigns)}
        <%= if @field[:masked] do %>
          <button
            type="button"
            class="btn btn-sm"
            phx-click="reveal_field"
            phx-value-field={@key}
            disabled={not @loaded?}
          >
            Reveal
          </button>
        <% end %>
      </div>
      <:hint :if={@field[:hint]}>{@field[:hint]}</:hint>
    </.bp_field_row>
    """
  end

  defp render_input(assigns) do
    case assigns.field.type do
      :select -> render_select(assigns)
      :boolean -> render_boolean(assigns)
      :password -> render_secret(assigns)
      :url -> render_text(assigns, "url")
      :string -> render_string(assigns)
      _ -> render_text(assigns, "text")
    end
  end

  defp render_select(assigns) do
    ~H"""
    <.bp_select id={@key} name={@key} value={@value} options={@field[:options] || []} />
    """
  end

  defp render_boolean(assigns) do
    ~H"""
    <.bp_switch id={@key} name={@key} value="true" checked={truthy?(@value)} />
    """
  end

  defp render_secret(assigns) do
    ~H"""
    <.bp_input
      id={@key}
      type={if Map.get(@revealed, @key, false), do: "text", else: "password"}
      name={@key}
      value={@value}
      placeholder={@field[:placeholder]}
      autocomplete="off"
      required={!!@field[:required]}
    />
    """
  end

  defp render_string(assigns) do
    ~H"""
    <.bp_input
      id={@key}
      type={if @field[:masked] == true and not Map.get(@revealed, @key, false), do: "password", else: "text"}
      name={@key}
      value={@value}
      placeholder={@field[:placeholder]}
      autocomplete="off"
      required={!!@field[:required]}
    />
    """
  end

  defp render_text(assigns, html_type) do
    assigns = Map.put(assigns, :html_type, html_type)

    ~H"""
    <.bp_input
      id={@key}
      type={@html_type}
      name={@key}
      value={@value}
      placeholder={@field[:placeholder]}
      autocomplete="off"
      required={!!@field[:required]}
    />
    """
  end

  # ── Plugin surfacing helpers (D2/D4/D10) ───────────────────────────────

  # Recompute the rendered plugin rows from the current workspace's effective
  # enablement. Called on mount and after every persist so the UI reflects the
  # merged declaration-default + override truth (never a stale optimistic view).
  defp assign_plugin_rows(socket) do
    assign(
      socket,
      :plugin_rows,
      load_plugin_rows(socket.assigns[:dataset], socket.assigns[:current_workspace])
    )
  end

  defp load_plugin_rows(_dataset, nil), do: []

  defp load_plugin_rows(dataset, %{id: ws_id} = workspace) do
    effective = Enablement.effective(ws_id)
    # Per the Decision-4 contract, `effective(nil)` resolves to the pure
    # declaration defaults (no workspace override) — that is the "default badge"
    # source, read through the contract interface only.
    defaults = Enablement.effective(nil)
    overrides = Tenancy.workspace_plugin_settings(workspace)

    # Inputs for the honest typeless-enable hint (charter Decision 19), read
    # ONCE per rebuild so a per-row helper stays a pure lookup:
    #   * the harvested plugin ownership map (one source of truth — Structure);
    #   * the schema names registered in THIS workspace's scope — the EXACT
    #     `Structure.build` scope (`include_global: true` + `workspace_id`);
    #   * a `type => total docs` census in the same tree-mirroring scope
    #     (drafts included), so "no documents yet" is honest about the database.
    owned_map = Structure.owned_schema_types_map()
    registered = registered_type_set(dataset, ws_id)
    census = type_doc_totals(dataset, ws_id)

    PluginsRegistry.all()
    |> Enum.map(fn %{name: name} ->
      eff = Map.get(effective, name, %{enabled: true, placement: :plugins})
      default = Map.get(defaults, name, %{enabled: true, placement: :plugins})

      %{
        name: name,
        display: display_name(name),
        enabled: eff.enabled,
        placement: eff.placement,
        has_override: Map.has_key?(overrides, name),
        default_enabled: default.enabled,
        default_placement: default.placement,
        hint: plugin_enable_hint(eff.enabled, Map.get(owned_map, name, []), registered, census)
      }
    end)
    |> Enum.sort_by(& &1.display)
  end

  defp load_plugin_rows(_dataset, _), do: []

  # Schema names registered in this workspace's desk scope — the EXACT scope
  # `Structure.build/2` uses (structure.ex:83-85): shared nil-workspace globals
  # PLUS the workspace's own, NOT narrowed by project.
  defp registered_type_set(dataset, ws_id) do
    dataset
    |> Content.list_schemas(include_global: true, workspace_id: ws_id)
    |> MapSet.new(& &1.name)
  end

  # `type => total document count` in the same tree-mirroring scope as the …Rest
  # census (`Analytics.type_census/2`): workspace + globals, project NOT narrowed,
  # drafts counted. A missing key means zero docs of that type.
  defp type_doc_totals(dataset, ws_id) do
    dataset
    |> Analytics.type_census(workspace_id: ws_id)
    |> Map.new(&{&1.type, &1.total})
  end

  # Honest inline feedback for an ENABLED plugin whose enablement may have
  # changed nothing visible in THIS workspace (charter Decision 19). Two distinct
  # truths; `nil` for every other case (disabled, owns no schema types, or
  # content already present — where enabling genuinely surfaced something):
  #
  #   1. plugin owns schema types but NONE are registered in this workspace's
  #      scope — the common case, its schemas are Default-stamped at boot;
  #   2. its owned types ARE registered here but every one is document-less.
  #
  # A plugin owning no schema types (pure desk-item/top-menu) gets NO hint —
  # enabling it can still surface desk items or a top-menu tab.
  defp plugin_enable_hint(false, _owned, _registered, _census), do: nil
  defp plugin_enable_hint(true, [], _registered, _census), do: nil

  defp plugin_enable_hint(true, owned, registered, census) do
    registered_owned = Enum.filter(owned, &MapSet.member?(registered, &1))

    cond do
      registered_owned == [] ->
        "Enabled — no content types in this workspace yet"

      Enum.all?(registered_owned, &(Map.get(census, &1, 0) == 0)) ->
        "Enabled — types registered, no documents yet"

      true ->
        nil
    end
  end

  defp current_row(socket, name) do
    Enum.find(socket.assigns[:plugin_rows] || [], &(&1.name == name))
  end

  # Merge a partial override (`%{"enabled" => bool}` or `%{"placement" => str}`)
  # into `settings["plugins"][name]`, preserving any dimension the admin has not
  # touched — the rest of the entry (and the theme key) resolves from declaration
  # defaults on read. Follows the set_workspace_theme persist/re-assign pattern.
  defp put_plugin_override(socket, name, changes, opts) do
    case socket.assigns[:current_workspace] do
      %{id: ws_id} = ws ->
        plugins = Tenancy.workspace_plugin_settings(ws)

        # Guard a hand-edited/malformed existing entry (a non-map value would
        # crash Map.merge): fall back to a fresh override for this plugin.
        base =
          case Map.get(plugins, name) do
            %{} = existing -> existing
            _ -> %{}
          end

        entry = Map.merge(base, changes)
        updated = Map.put(plugins, name, entry)

        case Tenancy.set_workspace_plugin_settings(ws_id, updated) do
          {:ok, workspace} ->
            {:noreply,
             socket
             |> assign(:current_workspace, workspace)
             |> assign_plugin_rows()
             |> put_flash(:info, Keyword.fetch!(opts, :flash))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save plugin settings.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No workspace in scope to configure.")}
    end
  end

  # Human labels for the plugin rows — the SAME vocabulary the tiered Desk
  # Structure uses for its Plugins-tier group headers
  # (Barkpark.Structure.plugin_display_name/1), so the Settings UI and the
  # tree never disagree about a plugin's name. Falls back to a humanized
  # registry key for any plugin not explicitly mapped.
  defp display_name("onixedit"), do: "Onix"
  defp display_name("tickets"), do: "Tickets"
  defp display_name("pulse"), do: "Lightning Storm"
  defp display_name("frt"), do: "Frame & Time"
  defp display_name("github"), do: "GitHub"

  defp display_name(name) when is_binary(name) do
    name
    |> String.split(~r/[_\-]/, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp display_name(name), do: to_string(name)

  defp placement_label(value) do
    case List.keyfind(@placement_labels, value, 0) do
      {_, label} -> label
      _ -> value
    end
  end

  # The "default" badge microcopy — what the plugin's own declaration says when
  # the workspace holds no override.
  defp default_badge_title(%{default_enabled: enabled, default_placement: placement}) do
    on_off = if enabled, do: "on", else: "off"
    "#{on_off} by default · #{placement_label(to_string(placement))}"
  end

  # ── Load paths ─────────────────────────────────────────────────────────

  defp load_typed(socket, name, fields) do
    case Settings.get(name, user_id: user_id(socket)) do
      {:ok, map} ->
        typed = typed_form_from(fields, map, mask_secrets: true)

        {:noreply,
         socket
         |> assign(
           plugin_name: name,
           settings_fields: fields,
           typed_form: typed,
           revealed: empty_revealed(fields),
           masked: true,
           loaded?: true,
           error: nil
         )}

      {:error, :not_found} ->
        defaults = typed_form_defaults(fields)

        {:noreply,
         socket
         |> assign(
           plugin_name: name,
           settings_fields: fields,
           typed_form: defaults,
           revealed: empty_revealed(fields),
           masked: false,
           loaded?: false,
           error: nil
         )
         |> put_flash(:info, "No settings yet for #{name} — fill in and Save.")}
    end
  end

  defp load_generic(socket, name) do
    case Settings.get(name, user_id: user_id(socket)) do
      {:ok, map} ->
        masked = Masking.mask(map)

        {:noreply,
         socket
         |> assign(
           plugin_name: name,
           settings_fields: [],
           settings_json: pretty(masked),
           masked: true,
           loaded?: true,
           error: nil
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(
           plugin_name: name,
           settings_fields: [],
           settings_json: "{}",
           masked: false,
           loaded?: false,
           error: nil
         )
         |> put_flash(:info, "No settings yet for #{name} — start with {} and Save.")}
    end
  end

  # ── Save paths ─────────────────────────────────────────────────────────

  defp save_typed(socket, name, fields, params) do
    stored = stored_settings(socket, name)

    form =
      fields
      |> params_to_form(params)
      |> restore_masked_typed(fields, stored)

    case validate_required(fields, form) do
      :ok ->
        case Settings.put(name, form, user_id: user_id(socket)) do
          {:ok, _record} ->
            masked = typed_form_from(fields, form, mask_secrets: true)

            {:noreply,
             socket
             |> assign(
               plugin_name: name,
               settings_fields: fields,
               typed_form: masked,
               revealed: empty_revealed(fields),
               masked: true,
               loaded?: true,
               error: nil
             )
             |> put_flash(:info, "Saved #{name}.")}

          {:error, %Ecto.Changeset{} = cs} ->
            {:noreply, assign(socket, typed_form: form, error: format_changeset(cs))}
        end

      {:error, missing} ->
        {:noreply,
         socket
         |> assign(typed_form: form, error: format_missing(missing))}
    end
  end

  defp save_generic(socket, name, %{"settings_json" => json}) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        restored = Masking.restore(map, stored_settings(socket, name))

        case Settings.put(name, restored, user_id: user_id(socket)) do
          {:ok, _record} ->
            {:noreply,
             socket
             |> assign(
               plugin_name: name,
               settings_json: pretty(Masking.mask(map)),
               masked: true,
               loaded?: true,
               error: nil
             )
             |> put_flash(:info, "Saved #{name}.")}

          {:error, %Ecto.Changeset{} = cs} ->
            {:noreply, assign(socket, error: format_changeset(cs))}
        end

      {:ok, _other} ->
        {:noreply, assign(socket, error: "JSON must be an object at the top level.")}

      {:error, %Jason.DecodeError{} = err} ->
        {:noreply, assign(socket, error: "Invalid JSON: #{Exception.message(err)}")}
    end
  end

  defp save_generic(socket, _name, _params) do
    {:noreply, assign(socket, error: "Missing settings_json.")}
  end

  # Secrets render masked (see `typed_form_from`/`Masking.mask`), so a routine
  # "edit one field, Save" round-trips the mask literal back in the untouched
  # inputs. Substituting the stored raw value wherever the submitted value still
  # equals the mask keeps unrevealed credentials intact; a freshly TYPED secret
  # (which won't equal the mask) is preserved as-is.
  defp stored_settings(socket, name) do
    case Settings.get(name, user_id: user_id(socket)) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp restore_masked_typed(form, fields, stored) do
    Enum.reduce(masked_keys(fields), form, fn key, acc ->
      case Map.get(stored, key) do
        nil ->
          acc

        raw ->
          if Map.get(acc, key) == Masking.mask(to_string(raw)) do
            Map.put(acc, key, to_string(raw))
          else
            acc
          end
      end
    end)
  end

  # ── Spec helpers ───────────────────────────────────────────────────────

  # Pulls the settings spec via the resolver chain and filters to fields
  # whose dot-namespaced `:name` leads with the requested plugin_name.
  # This matches the convention plugin_settings_live.ex uses and what
  # OnixEdit's spec actually declares (e.g. "bokbasen.api_base").
  defp fields_for(""), do: []

  defp fields_for(plugin_name) when is_binary(plugin_name) do
    PluginsRegistry.collect_settings_schema(ctx: %{plugin_name: plugin_name})
    |> Enum.filter(&field_belongs_to?(&1, plugin_name))
  end

  defp field_belongs_to?(%{name: name}, plugin_name) when is_binary(name) do
    case String.split(name, ".", parts: 2) do
      [^plugin_name, _rest] -> true
      _ -> false
    end
  end

  defp field_belongs_to?(_, _), do: false

  defp flat_key(%{name: name}) do
    case String.split(name, ".", parts: 2) do
      [_prefix, key] -> key
      [key] -> key
    end
  end

  defp masked_keys(fields) do
    fields
    |> Enum.filter(fn f -> f[:masked] == true or f.type == :password end)
    |> Enum.map(&flat_key/1)
  end

  defp empty_revealed(fields) do
    Enum.into(masked_keys(fields), %{}, fn k -> {k, false} end)
  end

  defp all_masked_revealed?(fields, revealed) do
    keys = masked_keys(fields)
    keys != [] and Enum.all?(keys, &Map.get(revealed, &1, false))
  end

  # Build the form map from a stored settings row. Masked fields are
  # masked through `Masking.mask/1`; unmasked fields keep their raw value.
  defp typed_form_from(fields, map, opts) do
    mask_secrets = Keyword.get(opts, :mask_secrets, true)
    masked_set = MapSet.new(masked_keys(fields))

    Enum.into(fields, %{}, fn field ->
      key = flat_key(field)
      raw = to_string(Map.get(map, key, default_for(field)))

      value =
        if mask_secrets and MapSet.member?(masked_set, key) do
          Masking.mask(raw)
        else
          raw
        end

      {key, value}
    end)
  end

  defp typed_form_defaults(fields) do
    Enum.into(fields, %{}, fn field -> {flat_key(field), default_for(field)} end)
  end

  defp default_for(%{default: default}) when not is_nil(default), do: to_string(default)
  defp default_for(_), do: ""

  defp params_to_form(fields, params) do
    Enum.into(fields, %{}, fn field ->
      key = flat_key(field)
      raw = Map.get(params, key, "")
      {key, to_string(raw)}
    end)
  end

  defp validate_required(fields, form) do
    missing =
      fields
      |> Enum.filter(fn f ->
        f[:required] and blank?(Map.get(form, flat_key(f), ""))
      end)
      |> Enum.map(& &1.label)

    if missing == [], do: :ok, else: {:error, missing}
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  defp truthy?(_), do: false

  defp format_missing(missing) do
    "Missing or invalid: " <> Enum.join(missing, ", ")
  end

  defp pretty(map), do: Jason.encode!(map, pretty: true)

  defp user_id(socket) do
    case socket.assigns[:api_token] do
      %{id: id} -> to_string(id)
      _ -> nil
    end
  end

  defp format_changeset(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join("; ")
  end
end
