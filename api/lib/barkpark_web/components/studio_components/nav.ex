defmodule BarkparkWeb.StudioComponents.Nav do
  @moduledoc """
  Studio chrome + navigation components — flash banners, sign-out and
  theme-toggle buttons, the top-level tab bar, the topbar wrapper, and the
  outermost shell. Extracted from the former monolithic
  `BarkparkWeb.StudioComponents`; re-exported there as a thin facade so
  every call site keeps working unchanged.
  """
  use Phoenix.Component

  import BarkparkWeb.Icons

  @doc """
  Renders Studio flash banners (info + error) using the canonical
  `style="margin: 8px 16px 0;"` margin. Both `studio.html.heex` and
  `app.html.heex` call this — the markup is byte-identical between
  layouts, so consolidating eliminates duplication.

  When neither flash key is set, emits no markup (no leaked wrapper).
  """
  attr :flash, :map, required: true

  def studio_flash(assigns) do
    ~H"""
    <%= if Phoenix.Flash.get(@flash, :info) do %>
      <div class="flash flash-info" style="margin: 8px 16px 0;"><%= Phoenix.Flash.get(@flash, :info) %></div>
    <% end %>
    <%= if Phoenix.Flash.get(@flash, :error) do %>
      <div class="flash flash-error" style="margin: 8px 16px 0;"><%= Phoenix.Flash.get(@flash, :error) %></div>
    <% end %>
    """
  end

  @doc """
  Self-update banner for the Studio chrome. Renders ONLY when the caller
  is an admin (`@admin?`, threaded from the `shares_admin?` chrome flag)
  AND the running instance is behind the latest published release
  (`Barkpark.SelfUpdate.status/0` reports `state: :behind`). Any other
  state — `:disabled` (Checker not running, e.g. test env), `:unknown`,
  `:current` — emits no markup, so surfaces without the feature stay
  byte-identical.

  The status is computed ONCE per render (a cheap GenServer call) and,
  like `studio_tabs/1`'s registry lookup, is wrapped fail-closed: a
  crashed/missing SelfUpdate process must never take the chrome down.
  """
  attr :admin?, :boolean, default: false

  def studio_update_banner(assigns) do
    status = if assigns.admin?, do: self_update_status(), else: nil
    assigns = assign(assigns, :update_status, status)

    ~H"""
    <%= if match?(%{state: :behind}, @update_status) do %>
      <div
        id="bp-update-banner"
        style="margin: 8px 16px 0; padding: 8px 12px; font-size: 13px; border-radius: 6px; border-left: 3px solid var(--warning); background: hsl(38 92% 50% / 0.12); color: var(--warning);"
      >
        Update available — Barkpark <%= @update_status.latest_release %> (you run <%= @update_status.running_release %>)
        <%= if @update_status.canonical_release do %>
          <div id="bp-fork-advice" style="margin-top: 2px; font-size: 12px; opacity: 0.85;">
            Your fork's upstream, open-source Barkpark, is further ahead at <%= @update_status.canonical_release %> — consider syncing the fork.
          </div>
        <% end %>
        <%= if is_list(@update_status.digest) and @update_status.digest != [] do %>
          <details style="margin-top: 4px;">
            <summary style="cursor: pointer;">what changed</summary>
            <ul style="margin: 4px 0 0 18px; padding: 0;">
              <%= for line <- @update_status.digest do %>
                <li><%= line %></li>
              <% end %>
            </ul>
          </details>
        <% end %>
      </div>
    <% end %>
    <%= if match?(%{state: :current}, @update_status) and @update_status.canonical_release do %>
      <div
        id="bp-fork-advice"
        style="margin: 8px 16px 0; padding: 6px 12px; font-size: 12px; border-radius: 6px; border-left: 3px solid var(--fg-dim); background: hsl(0 0% 50% / 0.08); color: var(--fg-dim);"
      >
        Current with your fork — but open-source Barkpark is ahead at <%= @update_status.canonical_release %>; consider syncing the fork.
      </div>
    <% end %>
    """
  end

  # `SelfUpdate.status/0` is contract-bound to never raise, but the banner
  # is chrome on EVERY Studio surface — belt-and-braces fail-closed here
  # mirrors the `studio_tabs/1` registry guard.
  defp self_update_status do
    Barkpark.SelfUpdate.status()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc """
  Build-version footer for the Studio shell. A single muted line pinned
  to the bottom of the `studio-shell` flex column (placed last in the
  layout). The `#bp-build-version` span carries the full string so both
  humans and smoke tests can read the running build at a glance.
  Version/commit come from `Barkpark.BuildInfo` (compile-time git data;
  "unknown" outside a git checkout — never raises).
  """
  def studio_footer(assigns) do
    ~H"""
    <div
      class="studio-footer"
      style="flex: none; padding: 4px 16px; font-size: 11px; color: var(--fg-dim); border-top: 1px solid var(--border);"
    >
      <span id="bp-build-version">Barkpark v<%= Barkpark.BuildInfo.version() %> · <%= Barkpark.BuildInfo.commit() %></span>
    </div>
    """
  end

  @doc """
  Sign-out form for the Studio topbar. POSTs to `logout_path` (default
  `/logout`). Renders byte-identical to the legacy inline form in
  `studio.html.heex`. Caller wraps with `:if={assigns[:api_token]}` —
  the component itself does NOT guard, so an empty `<div class="studio-bar-actions">`
  wrapper does not leak into the topbar when no api_token is set.

  Uses a hardcoded path string rather than the `~p` sigil because
  `BarkparkWeb.StudioComponents` does not import `:verified_routes`.
  """
  attr :logout_path, :string, default: "/logout"

  def studio_signout_button(assigns) do
    ~H"""
    <div class="studio-bar-actions">
      <.form :let={_f} for={%{}} as={:session} action={@logout_path} method="post">
        <%!-- Icon-only (Sanity-style right rail); the accessible name and
              tooltip both say "Sign out". --%>
        <button type="submit" class="btn btn-ghost btn-sm" aria-label="Sign out" title="Sign out">
          <.icon name="log-out" size={15} />
        </button>
      </.form>
    </div>
    """
  end

  @doc """
  Dark/light theme toggle for the Studio topbar. Client-only — the
  `ThemeToggle` JS hook (root.html.heex) flips
  `document.documentElement.dataset.theme`, persists the choice to
  `localStorage`, and mirrors the live theme onto this button's own
  `data-theme` attribute. Sun vs moon icon visibility is driven purely
  by CSS off that mirror (`.theme-toggle-sun` / `.theme-toggle-moon`),
  so no server round-trip is needed to reflect the current theme.
  `phx-update="ignore"` keeps LiveView patches from clobbering the
  hook-set attribute.
  """
  def studio_theme_toggle(assigns) do
    ~H"""
    <div class="studio-bar-actions">
      <button
        id="studio-theme-toggle"
        type="button"
        class="btn btn-ghost btn-sm theme-toggle"
        phx-hook="ThemeToggle"
        phx-update="ignore"
        aria-label="Toggle dark / light theme"
        title="Toggle dark / light theme"
      >
        <span class="theme-toggle-sun"><.icon name="sun" size={16} /></span>
        <span class="theme-toggle-moon"><.icon name="moon" size={16} /></span>
      </button>
    </div>
    """
  end

  @doc """
  Studio top-level tab navigation. Seeds the registry resolver chain
  with the host's built-in tabs (`default_top_menu_entries/1`,
  derived from `BarkparkWeb.Studio.Nav.tabs/1`) as `:baseline` and
  passes `%{dataset, current_path}` as `:ctx`. Plugins that override
  `resolve_top_menu_entries/2` see the host tabs in `prev` and may
  drop, reorder, or amend them symmetric with how they treat
  sibling-plugin entries. Renders the canonical
  `<div class="studio-bar-tabs">` wrapper with one anchor per tab.
  The active tab is determined uniformly by `plugin_tab_active?/2` —
  built-ins carry an explicit `:active_when` rule so the existing
  highlight behaviour for `…/d/:ds/studio`, `…/d/:ds/studio/media`, and
  `…/d/:ds/studio/api-tester` is preserved.

  The "API" tab points at the legacy `BarkparkWeb.Studio.ApiTesterLive`
  (`…/d/:ds/studio/api-tester`) — restored in task barkpark-7xne after
  the misjudged route-removal in commit f1e5a21. Plugin api_tests/0
  specs ride this same UI under a "Plugins" sidebar category seeded by
  `Barkpark.ApiTester.Endpoints.all/1`.

  The `:nav_section` assign is preserved for backwards compatibility
  but no longer drives active-state — `default_top_menu_entries/1`'s
  `:active_when` rules cover the same routes.

  Caller wraps with `:if={assigns[:dataset]}` — the component itself
  does NOT guard, so an empty `<div class="studio-bar-tabs">` does not
  leak into the topbar when no dataset is set.
  """
  attr :dataset, :string, required: true
  attr :scope_prefix, :string, default: ""
  attr :nav_section, :atom, default: nil
  attr :current_path, :string, default: nil

  def studio_tabs(assigns) do
    ctx = %{
      dataset: assigns.dataset,
      current_path: assigns[:current_path],
      scope_prefix: assigns[:scope_prefix] || ""
    }

    baseline = default_top_menu_entries(assigns.dataset, assigns[:scope_prefix] || "")

    tabs =
      try do
        Barkpark.Plugins.Registry.collect_top_menu_entries(baseline: baseline, ctx: ctx)
      rescue
        _ -> baseline
      catch
        _, _ -> baseline
      end

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <div class="studio-bar-tabs">
      <%= for tab <- @tabs do %>
        <% active = plugin_tab_active?(tab, @current_path) %>
        <a
          href={tab.path}
          class={"studio-tab #{if active, do: "active"}"}
          aria-current={if active, do: "page"}
          data-test-id="top-menu-tab"
        ><%= tab.label %></a>
      <% end %>
    </div>
    """
  end

  # Host's built-in top-menu tabs in the resolver-compatible shape.
  # Threaded as `:baseline` through `Registry.collect_top_menu_entries/1`
  # so plugins can see, reorder, or drop host tabs (Q4 in the plan).
  #
  # `:active_when` is set explicitly per tab so the post-resolution
  # render loop can highlight the active tab uniformly via
  # `plugin_tab_active?/2`:
  #
  #   * Structure: regex matching the Studio base path and any sub-route
  #     *except* `/media` and `/api-tester` (those are owned by the
  #     other two built-ins).
  #   * Media / API: exact path prefix.
  #
  # Orders 10 / 20 / 30 keep built-ins sorted ahead of plugin tabs
  # (which default to 100 via `normalize_top_menu_entry/1`).
  defp default_top_menu_entries(dataset, scope_prefix) when is_binary(dataset) do
    ds = URI.encode(dataset)

    # Scoped surface (tsk-url-p2): tabs address the SAME workspace/project
    # the page is on via the /d/ canonical. "" on a flat surface (e.g. the
    # /studio/:dataset/_plugins admin LV) keeps the legacy flat paths —
    # those ride the flat→scoped 302 funnel.
    base =
      case scope_prefix || "" do
        "" -> "/studio/#{ds}"
        prefix -> "#{prefix}/d/#{ds}/studio"
      end

    base_re = Regex.escape(base)

    structure_active =
      Regex.compile!("^#{base_re}(?:$|/(?!media(?:/|$)|api-tester(?:/|$)).*)")

    media_path = "#{base}/media"
    api_path = "#{base}/api-tester"

    [
      %{
        label: "Structure",
        path: base,
        icon: nil,
        order: 10,
        active_when: structure_active
      },
      %{
        label: "Media",
        path: media_path,
        icon: nil,
        order: 20,
        active_when: media_path
      },
      %{
        label: "API",
        path: api_path,
        icon: nil,
        order: 30,
        active_when: api_path
      }
    ]
  end

  @doc false
  # Decide whether a plugin tab is active. Rule:
  #
  #   * explicit `:active_when` always wins
  #     - string  → `String.starts_with?(current_path, active_when)`
  #     - regex   → `Regex.match?(active_when, current_path)`
  #   * absent → exact match on `tab.path`
  #
  # `current_path` may be nil in contexts that don't track it (back-compat;
  # the assign isn't required on every LV). In that case nothing is active.
  def plugin_tab_active?(_tab, nil), do: false
  def plugin_tab_active?(_tab, ""), do: false

  def plugin_tab_active?(%{active_when: %Regex{} = re}, current_path)
      when is_binary(current_path),
      do: Regex.match?(re, current_path)

  def plugin_tab_active?(%{active_when: prefix}, current_path)
      when is_binary(prefix) and is_binary(current_path),
      do: String.starts_with?(current_path, prefix)

  def plugin_tab_active?(%{path: path}, current_path)
      when is_binary(path) and is_binary(current_path),
      do: current_path == path

  def plugin_tab_active?(_tab, _current_path), do: false

  @doc """
  Studio topbar wrapper. Emits the canonical `<div class="studio-bar">`
  shell and renders three slots in order: `:brand` (single, optional),
  `:tabs` (single, optional), `:actions` (multi, optional).

  Each slot is rendered verbatim — slot content is responsible for its
  own inner wrapper (e.g. `<div class="studio-bar-brand">`,
  `<div class="studio-bar-actions">`). Self-contained sub-components
  like `<.studio_signout_button />` already include their own wrapper.

  Callers use `:if=` on each slot invocation to gate rendering — e.g.
  `<:actions :if={assigns[:api_token]}>…</:actions>`. This avoids
  empty-wrapper leak when the gate is false.
  """
  slot :brand
  slot :tabs
  slot :actions

  def studio_topbar(assigns) do
    ~H"""
    <div class="studio-bar">
      <%= render_slot(@brand) %>
      <%= render_slot(@tabs) %>
      <%= for a <- @actions do %><%= render_slot(a) %><% end %>
    </div>
    """
  end

  @doc """
  Outermost Studio chrome wrapper. Emits `<div class={@class}>` with
  the inner block rendered inside. Default class is `studio-shell`,
  the canonical full-viewport flex column. Override `:class` if a
  caller needs a different shell (rare — kept as an escape hatch).
  """
  attr :class, :string, default: "studio-shell"
  slot :inner_block, required: true

  def studio_shell(assigns) do
    ~H"""
    <div class={@class}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end
end
