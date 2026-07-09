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
  Self-update bar for the Studio chrome — a slim strip pinned above the
  topbar. Renders ONLY when the caller is an admin (`@admin?`, threaded
  from the `shares_admin?` chrome flag) AND the running instance is behind
  the latest published release (`Barkpark.SelfUpdate.status/0` reports
  `state: :behind`). Any other state — `:disabled` (Checker not running,
  e.g. test env), `:unknown`, `:current` — emits no update markup, so
  surfaces without the feature stay byte-identical (the `:current`-but-
  fork-behind advice line is the one exception).

  The bar carries the raw session token (`@api_token_raw`, same value
  Studio already hands its Web Components) and whether one-click apply is
  enabled (`Barkpark.SelfUpdate.Runner.enabled?/0`) as data attributes;
  the vanilla `bp-update-bar` initialiser in `root.html.heex` reads them
  to drive "Update now" (POST `/v1/admin/self-update`, then poll to
  completion) and the per-release localStorage dismiss. It is deliberately
  NOT a `phx-hook`: this bar lives in the layout, OUTSIDE the LiveView
  diff, so a delegated DOM listener is what actually reaches it.

  Both status and apply-enabled are computed ONCE per render (cheap calls)
  and wrapped fail-closed: a crashed/missing SelfUpdate process must never
  take the chrome down.
  """
  attr :admin?, :boolean, default: false
  attr :api_token_raw, :string, default: nil

  def studio_update_banner(assigns) do
    status = if assigns.admin?, do: self_update_status(), else: nil

    assigns =
      assigns
      |> assign(:update_status, status)
      |> assign(:apply_enabled?, assigns.admin? and self_update_apply_enabled?())

    ~H"""
    <%= if match?(%{state: :behind}, @update_status) do %>
      <div
        id="bp-update-bar"
        class="bp-update-bar"
        data-release={@update_status.latest_release}
        data-apply={to_string(@apply_enabled?)}
        data-token={@api_token_raw}
      >
        <div class="bp-update-bar-main">
          <span class="bp-update-dot" aria-hidden="true"></span>
          <span class="bp-update-msg">
            New update available — Barkpark <strong><%= @update_status.latest_release %></strong>
            <span class="bp-update-run">· you run <%= @update_status.running_release %></span>
          </span>
          <span class="bp-update-status" data-bp-update-status role="status" aria-live="polite"></span>
          <div class="bp-update-actions">
            <%= if changelog_present?(@update_status) do %>
              <button
                type="button"
                class="bp-update-link"
                data-bp-update-action="toggle"
                data-bp-update-target="bp-update-changelog"
                aria-expanded="false"
                aria-controls="bp-update-changelog"
              >What's changed</button>
            <% end %>
            <%= if @apply_enabled? do %>
              <button type="button" class="bp-update-btn" data-bp-update-action="apply">Update now</button>
            <% else %>
              <button
                type="button"
                class="bp-update-link"
                data-bp-update-action="toggle"
                data-bp-update-target="bp-update-howto"
                aria-expanded="false"
                aria-controls="bp-update-howto"
              >How to update</button>
            <% end %>
            <button
              type="button"
              class="bp-update-dismiss"
              data-bp-update-action="dismiss"
              aria-label="Dismiss update notice"
              title="Dismiss"
            >×</button>
          </div>
        </div>
        <%= if changelog_present?(@update_status) do %>
          <div id="bp-update-changelog" class="bp-update-changelog" hidden>
            <%= if notes_present?(@update_status) do %>
              <%!-- Curated release notes (isu-w2): human-authored body, kept
                    as plain text (pre-wrapped) — safe and auto-escaped. Full
                    formatted notes are one click away via the link below. --%>
              <div class="bp-update-notes"><%= @update_status.notes_body %></div>
            <% else %>
              <ul>
                <%= for line <- @update_status.digest do %>
                  <li><%= line %></li>
                <% end %>
              </ul>
            <% end %>
            <%= if @update_status.notes_url do %>
              <a
                class="bp-update-notes-link"
                href={@update_status.notes_url}
                target="_blank"
                rel="noopener noreferrer"
              >Full release notes ↗</a>
            <% end %>
          </div>
        <% end %>
        <%= unless @apply_enabled? do %>
          <div id="bp-update-howto" class="bp-update-changelog" hidden>
            One-click update isn't enabled on this instance. Deploy it with <code>git pull</code>
            on the server (the post-merge hook rebuilds &amp; restarts), or set
            <code>BARKPARK_SELF_UPDATE_APPLY=1</code> to turn on the button here.
          </div>
        <% end %>
        <%= if @update_status.canonical_release do %>
          <div class="bp-update-fork">
            Your fork's upstream, open-source Barkpark, is further ahead at
            <%= @update_status.canonical_release %> — consider syncing the fork.
          </div>
        <% end %>
      </div>
    <% end %>
    <%= if match?(%{state: :current}, @update_status) and @update_status.canonical_release do %>
      <div id="bp-update-fork-only" class="bp-update-bar bp-update-bar--muted">
        <div class="bp-update-bar-main">
          <span class="bp-update-msg bp-update-run">
            Current with your fork — but open-source Barkpark is ahead at
            <%= @update_status.canonical_release %>; consider syncing the fork.
          </span>
        </div>
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

  # Curated notes (isu-w2) win over the raw commit digest in the changelog
  # panel; the "What's changed" toggle shows when EITHER is present.
  defp changelog_present?(%{} = s), do: notes_present?(s) or digest_present?(s)
  defp changelog_present?(_), do: false

  defp notes_present?(%{notes_body: body}) when is_binary(body), do: String.trim(body) != ""
  defp notes_present?(_), do: false

  defp digest_present?(%{digest: digest}) when is_list(digest), do: digest != []
  defp digest_present?(_), do: false

  # Whether one-click apply is armed on this box (BARKPARK_SELF_UPDATE_APPLY=1
  # → Runner.enabled?). Same belt-and-braces fail-closed as the status call:
  # a missing/renamed Runner must degrade to "no button", never crash chrome.
  defp self_update_apply_enabled? do
    Barkpark.SelfUpdate.Runner.enabled?()
  rescue
    _ -> false
  catch
    _, _ -> false
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
  with the host's built-in tabs — the canonical nav model
  `default_top_menu_entries/3` (the single source of truth for the
  built-in Structure / Media / API tabs plus the admin-gated
  tmux / chat / Style extras) — as `:baseline` and
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
  but no longer drives active-state — `default_top_menu_entries/3`'s
  `:active_when` rules cover the same routes.

  Caller wraps with `:if={assigns[:dataset]}` — the component itself
  does NOT guard, so an empty `<div class="studio-bar-tabs">` does not
  leak into the topbar when no dataset is set.
  """
  attr :dataset, :string, required: true
  attr :scope_prefix, :string, default: ""
  attr :nav_section, :atom, default: nil
  attr :current_path, :string, default: nil
  attr :admin?, :boolean, default: false
  attr :workspace_id, :string, default: nil

  def studio_tabs(assigns) do
    # `:workspace_id` threads the current workspace into the resolver ctx so
    # the top-menu surfacing collector can skip per-workspace-disabled plugins
    # (ssp-w1-plugin-enablement). Nil on an unscoped surface → no filtering.
    ctx = %{
      dataset: assigns.dataset,
      current_path: assigns[:current_path],
      scope_prefix: assigns[:scope_prefix] || "",
      workspace_id: assigns[:workspace_id]
    }

    baseline =
      default_top_menu_entries(
        assigns.dataset,
        assigns[:scope_prefix] || "",
        assigns[:admin?] == true
      )

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

  @doc """
  The canonical Studio nav model: the host's built-in top-menu tabs in
  the resolver-compatible shape. Returns the ordered `Structure` (10) /
  `Media` (20) / `API` (30) built-ins plus the admin-gated `tmux` (40),
  `chat` (45), and `Style` (50) extras. Threaded as `:baseline` through
  `Registry.collect_top_menu_entries/1` so plugins can see, reorder, or
  drop host tabs (Q4 in the plan). This is the ONE place built-in tab
  identity, order, path, and highlight rules are defined — there is no
  separate tab source.

  `:active_when` is set explicitly per tab so the post-resolution render
  loop can highlight the active tab uniformly via `plugin_tab_active?/2`:

    * Structure: regex matching the Studio base path and any sub-route
      *except* `/media` and `/api-tester` (those are owned by the other
      two built-ins).
    * Media / API / extras: exact path prefix, boundary-matched.

  Orders 10 / 20 / 30 keep built-ins sorted ahead of plugin tabs (which
  default to 100 via `normalize_top_menu_entry/1`).
  """
  # @canonical capability:studio-nav-model aka:nav-tabs,top-menu,studio-tabs doc:docs/cards/studio.md
  def default_top_menu_entries(dataset, scope_prefix, admin?) when is_binary(dataset) do
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
    ] ++ tmux_console_entry(admin?) ++ claude_chat_entry(admin?) ++ styleguide_entry(admin?)
  end

  # The living token style guide tab (unified-aesthetic W2, /studio/styleguide).
  # Admin-only — mirrors the tmux-console gating precedent (the route itself is
  # admin-gated in the router; this just keeps the tab out of non-admin chrome).
  # Flat singleton path (not dataset-scoped): the token spec is per-host, not
  # per-dataset. NOTE: /studio/styleguide is the STUDIO node of the future
  # cross-surface design index (W3.9/W5.D) — not built here.
  defp styleguide_entry(true) do
    [
      %{
        label: "Style",
        path: "/studio/styleguide",
        icon: nil,
        order: 50,
        active_when: "/studio/styleguide"
      }
    ]
  end

  defp styleguide_entry(_), do: []

  # The tmux console tab. Shown ONLY to admins (`admin?`, from the
  # `shares_admin?` chrome flag) AND only where `TmuxConsole.enabled?/0` holds
  # (on by default; hard-refused on public-demo hosts). The route is
  # admin-gated regardless — this just keeps the tab out of non-admin chrome.
  # Flat singleton path (not dataset-scoped): one shared session per host.
  # The Claude chat tab. Shown ONLY to admins AND only where
  # ClaudeChat.enabled?/0 holds (on by default when the `claude` binary is
  # installed; hard-refused on public-demo hosts). The route is admin-gated
  # regardless — this just keeps the tab out of non-admin chrome. Flat
  # singleton path: one chat surface per host, like the tmux console.
  defp claude_chat_entry(admin?) do
    if admin? and BarkparkWeb.Studio.ClaudeChat.enabled?() do
      [%{label: "chat", path: "/studio/chat", icon: nil, order: 45, active_when: "/studio/chat"}]
    else
      []
    end
  rescue
    _ -> []
  end

  defp tmux_console_entry(admin?) do
    if admin? and BarkparkWeb.Studio.TmuxConsole.enabled?() do
      [%{label: "tmux", path: "/studio/tmux", icon: nil, order: 40, active_when: "/studio/tmux"}]
    else
      []
    end
  rescue
    _ -> []
  end

  @doc false
  # Decide whether a plugin tab is active. Rule:
  #
  #   * explicit `:active_when` always wins
  #     - string  → boundary match: active iff `current_path == prefix`
  #       OR `current_path` starts with `prefix <> "/"`. This keeps deep
  #       links live (e.g. `/studio/chat/:session_id` highlights `chat`)
  #       while refusing sibling over-match (`/studio/media-library` must
  #       NOT light up the `/studio/media` tab, which a bare
  #       `String.starts_with?` would have wrongly done).
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
      do: current_path == prefix or String.starts_with?(current_path, prefix <> "/")

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
