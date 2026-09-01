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

  alias BarkparkWeb.Studio.StudioLive.Paths

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
      <div class="flash flash-info" role="status" aria-live="polite" style="margin: 8px 16px 0;"><%= Phoenix.Flash.get(@flash, :info) %></div>
    <% end %>
    <%= if Phoenix.Flash.get(@flash, :error) do %>
      <div class="flash flash-error" role="alert" aria-live="assertive" style="margin: 8px 16px 0;"><%= Phoenix.Flash.get(@flash, :error) %></div>
    <% end %>
    """
  end

  @doc """
  Self-update bar for the Studio chrome — a slim strip pinned above the
  topbar. Renders ONLY when the caller is an INSTANCE admin (`@admin?`,
  threaded from the HOST-level `instance_admin?` chrome flag, NOT the
  workspace-scoped `shares_admin?`) AND the running instance is behind
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

  @doc """
  Environment-identity strip (staging-barkpark). A slim, high-contrast,
  full-width band pinned above the topbar so a human can never mistake a
  non-production Studio for prod. Reads the instance-identity tag straight
  from `Application.get_env(:barkpark, :instance_env)` — set from
  `BARKPARK_ENV` in `runtime.exs`, an IDENTITY label (which box am I?), NOT
  `MIX_ENV` — so there is no assign to plumb through every LiveView.

  Rendering contract:

    * `nil`, `"prod"`, `"production"` (and empty) → nothing at all, so
      production and dev Studios stay byte-identical to before.
    * `"staging"` → the canary strip with fixed copy.
    * any other non-empty tag → a generic strip carrying the uppercased tag,
      so a future `"preview"`/`"qa"` box self-labels without a code change.

  Colors are theme tokens only (`--warn` / `--warn-fg` / `--warn-strong`) —
  no hex literals, so `studio-literal-check` stays green — which also means
  the strip retints correctly in every Studio theme. Like the update bar it
  lives in the layout OUTSIDE the LiveView diff; it takes no attrs.
  """
  def studio_env_banner(assigns) do
    assigns = assign(assigns, :env, env_banner_content())

    ~H"""
    <%= if @env do %>
      <div
        class="bp-env-banner"
        data-env={@env.tag}
        role="status"
        aria-label={@env.aria_label}
        style="flex: none; padding: 3px 16px; text-align: center; font-size: 11px; font-weight: 600; letter-spacing: 0.03em; line-height: 1.4; background: var(--warn); color: var(--warn-fg); border-bottom: 1px solid var(--warn-strong);"
      >
        <%= @env.message %>
      </div>
    <% end %>
    """
  end

  # Normalize the raw identity tag into either nil (render nothing) or a small
  # map the strip renders. Trims + downcases defensively so the component is
  # robust to whatever landed in config, independent of runtime.exs.
  defp env_banner_content do
    case Application.get_env(:barkpark, :instance_env) do
      tag when is_binary(tag) ->
        case tag |> String.trim() |> String.downcase() do
          env when env in ["", "prod", "production"] ->
            nil

          "staging" ->
            %{
              tag: "staging",
              message: "STAGING — canary for Barkpark builds; data is disposable",
              aria_label: "Staging environment — data is disposable"
            }

          other ->
            label = String.upcase(other)
            %{tag: other, message: label, aria_label: "#{label} environment"}
        end

      _ ->
        nil
    end
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

  The optional `:vitals` slot renders after the version span — the caller
  passes either the live `BarkparkWeb.ServerVitalsLive` (live context) or a
  static host-vitals snapshot (dead views). The `#bp-build-version` span is
  left byte-identical so smoke tests still read the running build.
  """
  slot :vitals

  def studio_footer(assigns) do
    ~H"""
    <div
      class="studio-footer"
      style="flex: none; padding: 4px 16px; font-size: 11px; color: var(--fg-dim); border-top: 1px solid var(--border);"
    >
      <span id="bp-build-version">Barkpark v<%= Barkpark.BuildInfo.version() %> · <%= Barkpark.BuildInfo.commit() %></span><%= render_slot(@vitals) %>
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
  `default_top_menu_entries/4` (the single source of truth for the
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
  but no longer drives active-state — `default_top_menu_entries/4`'s
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
        assigns[:admin?] == true,
        assigns[:current_path]
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
        <%!-- Icons-only top bar (sup-w1): the glyph carries the meaning, the
              label rides the native tooltip (title) and the accessible name
              (aria-label). A tab with a nil/unknown icon degrades to the
              generic "file" glyph — its label tooltip keeps it legible
              (charter D2).

              THE DEGRADE IS `drawable_name/2`, NOT `||` (icons-tab-icon-tenant-guard).
              A tab is PLUGIN data — `collect_top_menu_entries/1` above hands the
              registry's entries straight through — so `tab[:icon]` is an
              unbounded, out-of-tree value. `|| "file"` only answers nil/false:
              an unknown STRING reached `icon/1` and painted a document in
              dev/prod while RAISING in :test, and a truthy non-binary
              (`:folder || "file"` is `:folder`) did the same. Both shapes
              collapse here, at the call site, where "file" is a decision. --%>
        <a
          href={tab.path}
          class={"studio-tab #{if active, do: "active"}"}
          aria-current={if active, do: "page"}
          title={tab.label}
          aria-label={tab.label}
          data-test-id="top-menu-tab"
        ><span class="studio-tab-icon" aria-hidden="true"><.icon name={BarkparkWeb.Icons.drawable_name(tab[:icon], "file")} size={16} /></span></a>
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

  `current_path` is the canonical path the viewer is on; on a SCOPED
  surface it seeds the `?return_to=` the flat chat/tmux/styleguide tabs
  carry so leaving one lands back in the same scope (charter D5).
  """
  # @canonical capability:studio-nav-model aka:nav-tabs,top-menu,studio-tabs doc:docs/cards/studio.md
  def default_top_menu_entries(dataset, scope_prefix, admin?, current_path)
      when is_binary(dataset) do
    ds = URI.encode(dataset)

    # Scoped surface (tsk-url-p2): tabs address the SAME workspace/project
    # the page is on via the /d/ canonical. The plugins-admin LV lives at
    # `/w/:ws/p/:proj/d/:dataset/studio/_plugins` with a non-empty prefix;
    # `/studio/:dataset/_plugins` is only its 302 compatibility entry. A truly
    # flat surface (scope_prefix "") keeps the legacy flat paths, which ride
    # the flat→scoped 302 funnel.
    base =
      case scope_prefix || "" do
        "" -> Paths.flat_root(ds)
        prefix -> Paths.studio_path(prefix, [], ds)
      end

    base_re = Regex.escape(base)

    structure_active =
      Regex.compile!("^#{base_re}(?:$|/(?!media(?:/|$)|api-tester(?:/|$)).*)")

    media_path = "#{base}/media"
    api_path = "#{base}/api-tester"

    # Truthful return path for the flat, scope-free tabs (chat/tmux/styleguide,
    # charter D5): the canonical path the viewer is currently ON, so leaving one
    # of those surfaces lands back in the SAME workspace/project/dataset instead
    # of the `/studio` session funnel (which re-resolves scope and can teleport
    # a multi-workspace admin). Only a SCOPED surface (non-empty `scope_prefix`)
    # can build one — a flat surface passes `nil` and the tabs stay bare.
    return_path =
      case scope_prefix || "" do
        "" -> nil
        _ -> BarkparkWeb.Studio.ReturnTo.sanitize(current_path) || base
      end

    [
      %{
        label: "Structure",
        path: base,
        # folder-tree glyph ships with sup-w1-icon-authority; until it merges
        # the icon component falls back to the generic "file" glyph (graceful).
        icon: "folder-tree",
        order: 10,
        active_when: structure_active
      },
      %{
        label: "Media",
        path: media_path,
        icon: "image",
        order: 20,
        active_when: media_path
      },
      %{
        label: "API",
        path: api_path,
        icon: "zap",
        order: 30,
        active_when: api_path
      }
    ] ++
      tmux_console_entry(admin?, return_path) ++
      claude_chat_entry(scope_prefix, admin?, return_path) ++
      styleguide_entry(admin?, return_path) ++
      connectors_entry(scope_prefix, admin?) ++ settings_entry(base, scope_prefix, admin?)
  end

  # The Connectors tab (connectors D49). Admin-only. Scope-prefixed EXACTLY like
  # Settings, and for the same reason: the catalog is scoped-in-substance (an
  # install belongs to ONE workspace), so its canonical home is
  # `/w/:ws/p/:proj/studio/connectors`. On a flat surface (`scope_prefix ""`) the
  # tab points at the flat `/studio/connectors` spelling, which 302s to the scoped
  # canonical via `AdminStudioRedirectController` — never a direct flat mount,
  # which would have no `current_workspace` and pin every install to the seeded
  # Default. The tab must exist on EVERY surface: the nav-parity contract
  # (nav_parity_sweep_test) requires an identical tab-label set on every
  # studio-layout route, and a tab that appears and vanishes as you navigate is
  # exactly the bug that suite exists to prevent.
  defp connectors_entry(scope_prefix, true) do
    path =
      case scope_prefix || "" do
        "" -> "/studio/connectors"
        prefix -> "#{prefix}/studio/connectors"
      end

    [%{label: "Connectors", path: path, icon: "zap", order: 55, active_when: path}]
  end

  defp connectors_entry(_scope_prefix, _admin?), do: []

  # The living token style guide tab (unified-aesthetic W2, /studio/styleguide).
  # Admin-only — mirrors the tmux-console gating precedent (the route itself is
  # admin-gated in the router; this just keeps the tab out of non-admin chrome).
  # Flat singleton path (not dataset-scoped): the token spec is per-host, not
  # per-dataset. NOTE: /studio/styleguide is the STUDIO node of the future
  # cross-surface design index (W3.9/W5.D) — not built here.
  defp styleguide_entry(true, return_path) do
    [
      %{
        label: "Style",
        path: BarkparkWeb.Studio.ReturnTo.with_return_to("/studio/styleguide", return_path),
        icon: "palette",
        order: 50,
        active_when: "/studio/styleguide"
      }
    ]
  end

  defp styleguide_entry(_admin?, _return_path), do: []

  # The tmux console tab. Shown ONLY to admins (`admin?`, from the
  # `shares_admin?` chrome flag) AND only where `TmuxConsole.enabled?/0` holds
  # (on by default; hard-refused on public-demo hosts). The route is
  # admin-gated regardless — this just keeps the tab out of non-admin chrome.
  # Flat singleton path (not dataset-scoped): one shared session per host.
  # The Claude chat tab. Shown ONLY to admins AND only where
  # ClaudeChat.enabled?/0 holds (flag on by default; hard-refused on
  # public-demo hosts). Binary presence deliberately does NOT gate the tab
  # (chat-task-hands gate inversion): a host without `claude` still shows it,
  # and the chat surface renders the onboarding card with the next step —
  # the tab never silently vanishes. The route is admin-gated regardless —
  # this just keeps the tab out of non-admin chrome. Flat singleton path:
  # one chat surface per host, like the tmux console.
  # The Workspace Settings tab (ssp-w3, charter D15). Admin-only — mirrors the
  # Style/tmux/chat gating (the route itself is admin-gated). Scope-prefixed:
  # on a scoped surface it addresses the SAME workspace/project the page
  # is on (the canonical dataset-less `/w/:ws/p/:proj/studio/settings` route); on a
  # flat surface (scope_prefix "") it points at the flat `/studio/settings`
  # compat entry, which resolves the Default scope and redirects to the scoped URL.
  defp settings_entry(_base, scope_prefix, true) do
    # Main's canonical Settings route is PROJECT-level (/w/:ws/p/:proj/studio/
    # settings — no dataset segment; SettingsLive binds the workspace, #1936),
    # so the tab derives from scope_prefix, not the dataset-ful desk base.
    path =
      case scope_prefix || "" do
        "" -> "/studio/settings"
        prefix -> "#{prefix}/studio/settings"
      end

    [%{label: "Settings", path: path, icon: "settings", order: 60, active_when: path}]
  end

  defp settings_entry(_base, _scope_prefix, _), do: []

  # SCOPE-PREFIXED, exactly like `settings_entry/3` and `connectors_entry/2`
  # above (task-58b55b015f222b51). ChatLive is dual-mounted — flat
  # `/studio/chat` and scoped `/w/:ws/p/:proj/studio/chat` (router.ex, the
  # `:scoped_admin_studio` session) — and this tab hardcoded the FLAT spelling,
  # so the Chat tab on a SCOPED Studio page navigated the operator OUT of the
  # workspace they were browsing and onto the flat surface. That surface then
  # binds via `StudioChrome`, not the URL, so the tab silently changed which
  # tenant the next chat session would be written into.
  #
  # Unlike Settings/Connectors, the flat arm here is a REAL mount, not a 302:
  # both routes exist, so prefixing makes the link scope-truthful with no
  # redirect involved. Whether the flat spelling should keep mounting at all —
  # nav.ex above calls it a "flat singleton path … like the tmux console",
  # while its substance is workspace-scoped — is the separate adjudication this
  # row deferred, and is NOT settled by this tab fix.
  #
  # `active_when` stays the BARE path: `path` carries a `?return_to=` query, and
  # the active-tab match is on the path alone (it must also match the
  # `/chat/:session_id` sibling, which shares this prefix).
  defp claude_chat_entry(scope_prefix, admin?, return_path) do
    if admin? and BarkparkWeb.Studio.ClaudeChat.enabled?() do
      chat_path =
        case scope_prefix || "" do
          "" -> "/studio/chat"
          prefix -> "#{prefix}/studio/chat"
        end

      [
        %{
          label: "chat",
          path: BarkparkWeb.Studio.ReturnTo.with_return_to(chat_path, return_path),
          # messages-square glyph ships with sup-w1-icon-authority; falls back
          # to "file" until it merges.
          icon: "messages-square",
          order: 45,
          active_when: chat_path
        }
      ]
    else
      []
    end
  rescue
    _ -> []
  end

  defp tmux_console_entry(admin?, return_path) do
    if admin? and BarkparkWeb.Studio.TmuxConsole.enabled?() do
      [
        %{
          label: "tmux",
          path: BarkparkWeb.Studio.ReturnTo.with_return_to("/studio/tmux", return_path),
          icon: "terminal",
          order: 40,
          active_when: "/studio/tmux"
        }
      ]
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
  #       `String.starts_with?` would have wrongly done). A declared
  #       trailing slash is trimmed first ("/admin/onixedit/" ≡
  #       "/admin/onixedit") — `current_path` is slash-normalized by
  #       StudioChrome, so an untrimmed prefix could never match.
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
      when is_binary(prefix) and is_binary(current_path) do
    prefix = String.trim_trailing(prefix, "/")
    current_path == prefix or String.starts_with?(current_path, prefix <> "/")
  end

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
