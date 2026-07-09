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

  require Logger

  alias Barkpark.Plugins.Enablement
  alias Barkpark.Plugins.Registry, as: PluginsRegistry
  alias Barkpark.Plugins.Settings
  alias Barkpark.Plugins.Settings.Masking
  alias Barkpark.Tenancy

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
    {:noreply,
     socket
     |> assign(:bp_theme, Tenancy.workspace_theme(socket.assigns[:current_workspace]))
     |> assign_plugin_rows()}
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
      scope_subpath: "/settings"
    )
    |> assign_plugin_rows()
  end


  @impl true
  def handle_event("update_name", %{"plugin_name" => name}, socket) do
    {:noreply, assign(socket, plugin_name: name)}
  end

  def handle_event("load", %{"plugin_name" => name}, socket) do
    fields = fields_for(name)

    if fields == [] do
      load_generic(socket, name)
    else
      load_typed(socket, name, fields)
    end
  end

  def handle_event("reveal", %{"plugin_name" => name}, socket) do
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

  def handle_event("reveal_field", %{"field" => field}, socket) do
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

  def handle_event("save", %{"plugin_name" => name} = params, socket) do
    fields = fields_for(name)

    if fields == [] do
      save_generic(socket, name, params)
    else
      save_typed(socket, name, fields, params)
    end
  end

  def handle_event("delete", %{"plugin_name" => name}, socket) do
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

  # Workspace theme picker (ts-w4e). Persists `settings["theme"]` on the current
  # workspace and re-assigns `:bp_theme` so the hidden `#bp-theme-mirror` element
  # re-renders → the `BpThemeMirror` hook stamps `document.documentElement`
  # instantly (preview with no reload). The server-side stamp on the next full
  # load comes from StudioChrome resolving the persisted value.
  def handle_event("set_workspace_theme", %{"theme" => theme} = params, socket) do
    guard_bound_ws(socket, params, fn ->
      do_set_workspace_theme(socket, theme)
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
  end

  def handle_event(
        "set_plugin_placement",
        %{"plugin" => name, "placement" => placement} = params,
        socket
      )
      when placement in ["main", "plugins", "top_menu"] do
    guard_bound_ws(socket, params, fn ->
      # Same unknown-plugin guard as toggle_plugin: a forged plugin name must not
      # persist a junk override entry into the workspace settings.
      case current_row(socket, name) do
        %{} ->
          put_plugin_override(socket, name, %{"placement" => placement},
            flash: "Moved #{display_name(name)} to #{placement_label(placement)}."
          )

        nil ->
          {:noreply, put_flash(socket, :error, "Unknown plugin #{inspect(name)}.")}
      end
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="settings-live" style="max-width: 720px; margin: 2rem auto; font-family: ui-sans-serif, system-ui;">
      <h1 style="margin-bottom:.25rem;">Workspace Settings</h1>
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

      <%= if msg = Phoenix.Flash.get(@flash, :info) do %>
        <div role="status" style="background:var(--success-bg); color:var(--success); padding:.5rem; margin:.5rem 0;">{msg}</div>
      <% end %>
      <%= if msg = Phoenix.Flash.get(@flash, :error) do %>
        <div role="alert" style="background:var(--destructive-bg); color:var(--destructive); padding:.5rem; margin:.5rem 0;">{msg}</div>
      <% end %>

      {render_theme_section(assigns)}

      {render_plugins_section(assigns)}

      <section
        aria-labelledby="credentials-heading"
        style="border:1px solid var(--border); border-radius:8px; padding:1rem 1.25rem; margin-bottom:2rem;"
      >
        <h2 id="credentials-heading" style="margin-top:0;">Plugin credentials</h2>

        <p style="color: var(--fg-muted);">
          Encrypted JSON store. Values are masked on load — click <em>Reveal</em>
          to fetch unmasked (audited). Credentials are global to the installation,
          not per-workspace.
        </p>

        <form phx-change="update_name" phx-submit="load" style="margin-bottom:1rem;">
          <label>
            Plugin name
            <input
              type="text"
              name="plugin_name"
              value={@plugin_name}
              placeholder="e.g. onixedit, bokbasen"
              autocomplete="off"
              required
            />
          </label>
          <button type="submit">Load</button>
        </form>

        <%= if @settings_fields == [] do %>
          {render_generic_form(assigns)}
        <% else %>
          {render_typed_form(assigns)}
        <% end %>

        <%= if @error do %>
          <p role="alert" style="color:var(--destructive);">{@error}</p>
        <% end %>

        <p style="margin-top:1rem; color:var(--fg-muted); font-size:.9em;">
          Status: {if @loaded?, do: "loaded", else: "empty"} · {if @masked, do: "masked", else: "revealed"}
        </p>
      </section>
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
    <section
      aria-labelledby="theme-heading"
      style="border:1px solid var(--border); border-radius:8px; padding:1rem 1.25rem; margin-bottom:2rem;"
    >
      <h2 id="theme-heading" style="margin-top:0;">Workspace theme</h2>

      <div
        id="bp-theme-mirror"
        phx-hook="BpThemeMirror"
        data-bp-theme={@bp_theme}
        hidden
      >
      </div>

      <%= if @current_workspace do %>
        <p style="color: var(--fg-muted);">
          The theme identity for
          <strong>{@current_workspace.name}</strong>. Applies to the reader,
          Studio and emailed papers — light/dark mode stays a separate switch.
        </p>

        <form phx-change="set_workspace_theme">
          <input type="hidden" name="ws" value={@current_workspace.id} />
          <label>
            Theme
            <select name="theme" style="margin-left:.5rem;">
              <%= for id <- @known_themes do %>
                <option value={id} selected={to_string(@bp_theme) == id}>{id}</option>
              <% end %>
            </select>
          </label>
        </form>

        <p style="color: var(--fg-muted); font-size:.9em; margin-bottom:0;">
          <%= if length(@known_themes) == 1 do %>
            One theme ships today; more land as the compiler emits them.
          <% else %>
            Saved server-side and stamped on the first byte — no flash.
          <% end %>
        </p>
      <% else %>
        <p role="status" style="color: var(--fg-muted); margin-bottom:0;">
          No workspace in scope to theme.
        </p>
      <% end %>
    </section>
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
    <section
      aria-labelledby="plugins-heading"
      style="border:1px solid var(--border); border-radius:8px; padding:1rem 1.25rem; margin-bottom:2rem;"
    >
      <h2 id="plugins-heading" style="margin-top:0;">Plugins</h2>

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

                <label style="display:inline-flex; align-items:center; gap:.4rem;">
                  <input
                    type="checkbox"
                    checked={row.enabled}
                    phx-click="toggle_plugin"
                    phx-value-plugin={row.name}
                    phx-value-ws={@current_workspace.id}
                  />
                  <span style={enabled_span_style(row.enabled)}>
                    {if row.enabled, do: "Enabled", else: "Disabled"}
                  </span>
                </label>

                <form phx-change="set_plugin_placement" style="margin:0;">
                  <input type="hidden" name="plugin" value={row.name} />
                  <input type="hidden" name="ws" value={@current_workspace.id} />
                  <label style="display:inline-flex; align-items:center; gap:.4rem; color:var(--fg-muted); font-size:.9em;">
                    Placement
                    <select name="placement" disabled={not row.enabled}>
                      <%= for {value, label} <- @placement_labels do %>
                        <option value={value} selected={to_string(row.placement) == value}>{label}</option>
                      <% end %>
                    </select>
                  </label>
                </form>
              </li>
            <% end %>
          </ul>

          <p style="color: var(--fg-muted); font-size:.9em; margin-bottom:0;">
            Installed plugins always keep their schemas, routes and background jobs
            registered — these controls decide only what THIS workspace surfaces.
          </p>
      <% end %>
    </section>
    """
  end

  defp render_generic_form(assigns) do
    ~H"""
    <form phx-submit="save">
      <input type="hidden" name="plugin_name" value={@plugin_name} />
      <textarea
        id="settings_json"
        name="settings_json"
        rows="14"
        style="width:100%; font-family: ui-monospace, monospace;"
      >{@settings_json}</textarea>

      <div style="display:flex; gap:.5rem; margin-top:.5rem;">
        <button type="submit" disabled={@plugin_name == ""}>Save</button>
        <button
          type="button"
          phx-click="reveal"
          phx-value-plugin_name={@plugin_name}
          disabled={not @loaded? or not @masked}
        >
          Reveal
        </button>
        <button
          type="button"
          phx-click="delete"
          phx-value-plugin_name={@plugin_name}
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

      <fieldset style="border:1px solid var(--border); padding:.75rem; margin-bottom:.5rem;">
        <legend>{@plugin_name} settings</legend>

        <%= for field <- @settings_fields do %>
          {render_field(Map.merge(assigns, %{field: field, key: flat_key(field)}))}
        <% end %>
      </fieldset>

      <div style="display:flex; gap:.5rem; margin-top:.5rem;">
        <button type="submit">Save</button>
        <button
          type="button"
          phx-click="delete"
          phx-value-plugin_name={@plugin_name}
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
    ~H"""
    <p>
      <label>
        {@field.label}<%= if @field[:required] do %> <span style="color:var(--destructive);">*</span><% end %>
        {render_input(Map.merge(assigns, %{value: Map.get(@typed_form, @key, default_for(@field))}))}
      </label>
      <%= if @field[:masked] do %>
        <button
          type="button"
          phx-click="reveal_field"
          phx-value-field={@key}
          disabled={not @loaded?}
        >
          Reveal
        </button>
      <% end %>
      <%= if hint = @field[:hint] do %>
        <br /><small style="color:var(--fg-muted);">{hint}</small>
      <% end %>
    </p>
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
    <select name={@key} style="width:100%;">
      <%= for opt <- (@field[:options] || []) do %>
        <option value={opt} selected={to_string(@value) == to_string(opt)}>{opt}</option>
      <% end %>
    </select>
    """
  end

  defp render_boolean(assigns) do
    ~H"""
    <input type="checkbox" name={@key} value="true" checked={truthy?(@value)} />
    """
  end

  defp render_secret(assigns) do
    ~H"""
    <input
      type={if Map.get(@revealed, @key, false), do: "text", else: "password"}
      name={@key}
      value={@value}
      placeholder={@field[:placeholder]}
      autocomplete="off"
      style="width:100%;"
      required={!!@field[:required]}
    />
    """
  end

  defp render_string(assigns) do
    ~H"""
    <input
      type={if @field[:masked] == true and not Map.get(@revealed, @key, false), do: "password", else: "text"}
      name={@key}
      value={@value}
      placeholder={@field[:placeholder]}
      autocomplete="off"
      style="width:100%;"
      required={!!@field[:required]}
    />
    """
  end

  defp render_text(assigns, html_type) do
    assigns = Map.put(assigns, :html_type, html_type)

    ~H"""
    <input
      type={@html_type}
      name={@key}
      value={@value}
      placeholder={@field[:placeholder]}
      autocomplete="off"
      style="width:100%;"
      required={!!@field[:required]}
    />
    """
  end

  # ── Plugin surfacing helpers (D2/D4/D10) ───────────────────────────────

  # Recompute the rendered plugin rows from the current workspace's effective
  # enablement. Called on mount and after every persist so the UI reflects the
  # merged declaration-default + override truth (never a stale optimistic view).
  defp assign_plugin_rows(socket) do
    assign(socket, :plugin_rows, load_plugin_rows(socket.assigns[:current_workspace]))
  end

  defp load_plugin_rows(nil), do: []

  defp load_plugin_rows(%{id: ws_id} = workspace) do
    effective = Enablement.effective(ws_id)
    # Per the Decision-4 contract, `effective(nil)` resolves to the pure
    # declaration defaults (no workspace override) — that is the "default badge"
    # source, read through the contract interface only.
    defaults = Enablement.effective(nil)
    overrides = Tenancy.workspace_plugin_settings(workspace)

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
        default_placement: default.placement
      }
    end)
    |> Enum.sort_by(& &1.display)
  end

  defp load_plugin_rows(_), do: []

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

  defp enabled_span_style(true), do: "color:var(--success); font-size:.9em;"
  defp enabled_span_style(false), do: "color:var(--fg-muted); font-size:.9em;"

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
