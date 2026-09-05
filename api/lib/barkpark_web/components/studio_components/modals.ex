defmodule BarkparkWeb.StudioComponents.Modals do
  @moduledoc """
  Studio modal + popover components — image picker, network shares, item
  share popover, reference picker, history, delete/discard confirmation,
  profile edit, and the `studio_modals` umbrella that composes them.
  Extracted from the former monolithic `BarkparkWeb.StudioComponents`;
  re-exported there as a thin facade so every call site keeps working
  unchanged.
  """
  use Phoenix.Component

  import BarkparkWeb.Icons
  import BarkparkWeb.StudioComponents.Controls, only: [bp_radio: 1, bp_checkbox: 1]

  @doc """
  Image-picker modal, formerly a legacy inline block in StudioLive, now
  aggregated by `studio_modals/1`. Renders the overlay + media-grid card when
  `image_picker_field` is non-nil. All `phx-*` events bubble to the
  parent LV's `handle_event/3` (StudioLive owns: close-image-picker,
  validate-upload, upload-image, select-media).

  The `uploads` attr is the LV's full uploads struct; function
  components render in the parent process so the upload config scopes
  correctly. Do NOT promote this to a LiveComponent — `@uploads.image`
  scoping does not carry across LiveComponent boundaries.
  """
  attr :image_picker_field, :string, default: nil
  attr :uploads, :map, required: true
  attr :media_files, :list, default: []

  def image_picker_modal(assigns) do
    ~H"""
    <%= if @image_picker_field do %>
      <div class="image-picker-overlay" phx-click="close-image-picker"></div>
      <div
        class="image-picker"
        role="dialog"
        aria-modal="true"
        aria-labelledby="image-picker-title"
        phx-window-keydown="close-image-picker"
        phx-key="escape"
      >
        <div class="image-picker-header">
          <span id="image-picker-title" style="font-weight: 600; font-size: 14px;">Select Image</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-image-picker" aria-label="Close">×</button>
        </div>
        <div class="image-picker-upload">
          <form phx-change="validate-upload" phx-submit="upload-image" phx-value-field={@image_picker_field} id="upload-form">
            <.live_file_input upload={@uploads.image} class="image-file-input" />
            <%= for err <- upload_errors(@uploads.image) do %>
              <p class="text-sm image-upload-error" role="alert"><%= upload_error_to_string(err) %></p>
            <% end %>
            <%= for entry <- @uploads.image.entries do %>
              <div class="image-upload-entry">
                <.live_img_preview entry={entry} width="60" height="60" />
                <span class="text-sm"><%= entry.client_name %></span>
                <button type="submit" class="btn btn-primary btn-sm">Upload</button>
              </div>
              <%= for err <- upload_errors(@uploads.image, entry) do %>
                <p class="text-sm image-upload-error" role="alert"><%= upload_error_to_string(err) %></p>
              <% end %>
            <% end %>
          </form>
        </div>
        <div class="image-picker-grid">
          <%= if @media_files == [] do %>
            <div class="text-sm text-muted" style="padding: 16px; text-align: center;">No images yet. Upload one above.</div>
          <% end %>
          <%= for file <- @media_files do %>
            <div class="image-picker-item" phx-click="select-media" phx-value-url={"/media/files/#{file.path}"} phx-value-field={@image_picker_field}>
              <img
                src={"/media/files/#{file.path}"}
                alt={file.original_name}
                onerror="this.onerror=null;this.classList.add('image-picker-thumb-broken');this.removeAttribute('src');"
              />
              <div class="image-picker-name"><%= file.original_name %></div>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Network shares panel (scoped-sharing P6).

  Lists the live shares (env baseline + persisted) and, for an admin caller,
  offers an add form pre-filled with the current scope plus a remove button per
  STORED share. Follows the image-picker overlay idiom. The whole feature is
  admin-only: `@admin?` gates the mutate UI here, and the StudioLive handlers
  re-check admin server-side (the button being hidden is UX, not the security
  boundary).

  `@rows` is a pre-flattened list of maps (`:scope`, `:surfaces`, `:access`,
  `:source`, `:url`) so this component stays presentation-only.
  """
  attr :show, :boolean, default: false
  attr :admin?, :boolean, default: false
  attr :scope_prefill, :string, default: ""
  attr :prefill_surfaces, :list, default: []
  attr :rows, :list, default: []
  attr :error, :string, default: nil

  def shares_modal(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="image-picker-overlay" phx-click="shares-close"></div>
      <div
        class="image-picker shares-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="shares-modal-title"
        phx-window-keydown="shares-close"
        phx-key="escape"
      >
        <div class="image-picker-header">
          <span id="shares-modal-title" style="font-weight: 600; font-size: 14px;">Network shares</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="shares-close" aria-label="Close">×</button>
        </div>

        <%= if @admin? do %>
          <form phx-submit="shares-add" class="shares-add-form">
            <label class="shares-field">
              <span class="shares-field-label">Scope</span>
              <input
                type="text"
                name="scope"
                value={@scope_prefill}
                placeholder="workspace/project/dataset"
                class="form-input"
                autocomplete="off"
                required
              />
            </label>
            <div class="shares-field">
              <span class="shares-field-label">Surfaces</span>
              <div class="shares-surfaces">
                <.bp_checkbox
                  :for={surface <- ~w(papers docs media)}
                  name="surfaces[]"
                  value={surface}
                  label={String.capitalize(surface)}
                  checked={surface in @prefill_surfaces}
                />
              </div>
            </div>
            <p class="shares-note">
              Read-only — anyone on the local network can view this scope, not edit it.
            </p>
            <p :if={@error} class="shares-error"><%= @error %></p>
            <div class="shares-add-actions">
              <button type="submit" class="btn btn-primary btn-sm">Share</button>
            </div>
          </form>
        <% else %>
          <p class="shares-note" style="padding: 16px;">
            An admin token is required to manage network shares.
          </p>
        <% end %>

        <div class="shares-list">
          <div class="shares-list-title">Active shares</div>
          <%= if @rows == [] do %>
            <div class="shares-empty">Nothing is shared — this scope is private.</div>
          <% else %>
            <div :for={row <- @rows} class="share-row">
              <div class="share-row-main">
                <div class="share-row-scope"><%= row.scope %></div>
                <div class="share-row-meta">
                  <%= row.surfaces %> · <%= row.access %> · <span class="share-row-source"><%= row.source %></span>
                </div>
                <div :if={row.url} class="share-row-url"><%= row.url %></div>
              </div>
              <button
                :if={@admin? and row.source == "stored"}
                type="button"
                class="btn btn-ghost btn-sm share-row-remove"
                phx-click="shares-remove"
                phx-value-scope={row.scope}
                title="Stop sharing this scope"
              >
                Remove
              </button>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  ITEM share popover (P7) — Google-Docs-style "share THIS one item" for a paper
  or document. Distinct from `shares_modal` (which shares a whole workspace
  SECTION): this mints a direct, stable `/s/<token>` link to the single open
  item, with Copy + Revoke. Admin-only (the handlers re-check server-side).

  Two mint buttons, one per access level (`phx-value-access` "read" / "edit").
  Both land on the SAME `item-share-create` handler and the same
  `Barkpark.Sharing.Links.create/1`; nothing about the edit level is decided
  here. An edit link opens the paper reader's own block editor for that ONE
  slug (`BarkparkWeb.PaperViewer.can_edit?/3`) and carries no write permission
  anywhere else.

  `@links` is a pre-flattened list of `%{id, access, url}`, where `url` is nil
  for every link this socket did not JUST mint: the raw token is no longer
  stored (`arpss-w8-bl-share-link-raw-token-at-rest`, RULED 2026-09-02), so a
  listed link cannot be re-copied. Those rows render the sentence in place of
  the input + Copy button and keep their Revoke affordance — the honest read is
  "the link works, we cannot show it to you again; revoke and mint a new one".
  """
  attr :show, :boolean, default: false
  attr :admin?, :boolean, default: false
  attr :title, :string, default: "this item"
  attr :links, :list, default: []
  attr :error, :string, default: nil

  def item_share_popover(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="image-picker-overlay" phx-click="item-share-close"></div>
      <div
        class="image-picker item-share-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="item-share-title"
        phx-window-keydown="item-share-close"
        phx-key="escape"
      >
        <div class="image-picker-header">
          <span id="item-share-title" style="font-weight: 600; font-size: 14px;">Share &ldquo;<%= @title %>&rdquo;</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="item-share-close" aria-label="Close">×</button>
        </div>

        <%= if @admin? do %>
          <div class="item-share-body">
            <div class="item-share-lead">
              <span class="item-share-lead-icon"><.icon name="share-2" size={18} /></span>
              <div>
                <div class="item-share-lead-title">Anyone with the link</div>
                <div class="item-share-lead-sub">can open just this item — no account needed.</div>
              </div>
            </div>

            <%= if @links == [] do %>
              <div class="item-share-empty">No link yet.</div>
            <% else %>
              <div :for={link <- @links} class="item-share-link-row">
                <span class={"item-share-access item-share-access-#{link.access}"}>
                  <%= String.capitalize(link.access) %>
                </span>
                <%= if link.url do %>
                  <input
                    type="text"
                    readonly
                    value={link.url}
                    class="form-input item-share-url"
                    onclick="this.select()"
                  />
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm"
                    data-url={link.url}
                    onclick={BarkparkWeb.CSP.copy_data_url_onclick()}
                    title="Copy link"
                  >
                    Copy
                  </button>
                <% else %>
                  <span class="item-share-url item-share-url-hidden">
                    Link is active. Regenerate to copy a new URL.
                  </span>
                <% end %>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm item-share-revoke"
                  phx-click="item-share-revoke"
                  phx-value-id={link.id}
                  title="Revoke this link"
                >
                  Revoke
                </button>
              </div>
            <% end %>

            <p :if={@error} class="shares-error"><%= @error %></p>

            <div class="item-share-footer">
              <span class="shares-note">An edit link opens this one paper in the reader's editor.</span>
              <button
                type="button"
                class="btn btn-ghost btn-sm"
                phx-click="item-share-create"
                phx-value-access="read"
              >
                Create view link
              </button>
              <button
                type="button"
                class="btn btn-primary btn-sm"
                phx-click="item-share-create"
                phx-value-access="edit"
              >
                Create edit link
              </button>
            </div>
          </div>
        <% else %>
          <p class="shares-note" style="padding: 16px;">An admin token is required to share items.</p>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  SHARE-ACCESS sheet (airdrop-grants capstone) — mint + deliver a scoped,
  time-boxed, account-bound grant link. Distinct from `item_share_popover`
  (anonymous public read of ONE item): this grants an authenticated grantee a
  capability the GRANTOR HOLDS, delivered by email + a live toast.

    * `@caps` — the capabilities the grantor holds (`["read"]`, `["read",
      "write"]`, or `[]`). The picker offers ONLY these (View=read, Edit=write);
      an empty list disables submit. mint re-checks server-side.
    * `@type` — the post-type in scope (post-type surface) or nil (workspace).
    * `@link` — the `/grant/<token>` claim URL, surfaced ONCE after a successful
      mint (copy-to-clipboard). Dropped on close; the token hash is never shown.

  Events bubble to StudioLive: airdrop-close, airdrop-create.
  """
  attr :show, :boolean, default: false
  attr :type, :string, default: nil
  attr :caps, :list, default: []
  attr :link, :string, default: nil
  attr :error, :string, default: nil
  attr :suggestions, :list, default: []

  def airdrop_sheet(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="image-picker-overlay" phx-click="airdrop-close"></div>
      <div
        class="image-picker airdrop-sheet"
        role="dialog"
        aria-modal="true"
        aria-labelledby="airdrop-sheet-title"
        phx-window-keydown="airdrop-close"
        phx-key="escape"
      >
        <div class="image-picker-header">
          <span id="airdrop-sheet-title" style="font-weight: 600; font-size: 14px;">
            Share access<%= if @type, do: " · #{@type}", else: "" %>
          </span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="airdrop-close" aria-label="Close">×</button>
        </div>

        <%= if @link do %>
          <%!-- Post-mint: surface the claim link ONCE. --%>
          <div class="airdrop-body" data-test-id="airdrop-minted">
            <div class="item-share-lead">
              <span class="item-share-lead-icon"><.icon name="check-circle" size={18} /></span>
              <div>
                <div class="item-share-lead-title">Access shared</div>
                <div class="item-share-lead-sub">Emailed to the recipient. Copy the link if you want to hand it over directly.</div>
              </div>
            </div>
            <div class="item-share-link-row">
              <input
                type="text"
                readonly
                value={@link}
                class="form-input item-share-url"
                data-test-id="airdrop-link"
                onclick="this.select()"
              />
              <button
                type="button"
                class="btn btn-primary btn-sm"
                onclick="var u=this.previousElementSibling.value; if(navigator.clipboard){navigator.clipboard.writeText(/^https?:/.test(u)?u:location.origin+u);this.textContent='Copied'}"
                title="Copy link"
              >
                Copy
              </button>
            </div>
            <div class="item-share-footer">
              <button type="button" class="btn btn-sm" phx-click="airdrop-close">Done</button>
            </div>
          </div>
        <% else %>
          <form phx-submit="airdrop-create" class="airdrop-body">
            <label class="shares-field">
              <span class="shares-field-label">Recipient email</span>
              <%!-- Free-text recipient. The <datalist> is ADVISORY typeahead of
                    workspace members (phx-change → airdrop-suggest); emailing a
                    stranger with no account is still valid, and mint validates. --%>
              <input
                type="email"
                name="grantee_email"
                placeholder="person@example.com"
                class="form-input"
                autocomplete="off"
                list="airdrop-email-options"
                phx-change="airdrop-suggest"
                phx-debounce="150"
                data-test-id="airdrop-email"
                required
              />
              <datalist id="airdrop-email-options">
                <option :for={e <- @suggestions} value={e} />
              </datalist>
            </label>

            <div class="shares-field">
              <span class="shares-field-label">Access lasts</span>
              <div class="airdrop-duration" role="radiogroup" aria-label="Duration">
                <.bp_radio name="duration" value="30m">30 min</.bp_radio>
                <.bp_radio name="duration" value="5h">5 hours</.bp_radio>
                <.bp_radio name="duration" value="1d" checked>1 day</.bp_radio>
                <.bp_radio name="duration" value="custom">Custom…</.bp_radio>
              </div>
              <input
                type="datetime-local"
                name="expires_at"
                class="form-input airdrop-custom-expiry"
                data-test-id="airdrop-custom-expiry"
                aria-label="Custom expiry"
              />
            </div>

            <div class="shares-field">
              <span class="shares-field-label">Capabilities</span>
              <%= if @caps == [] do %>
                <p class="shares-note" data-test-id="airdrop-no-caps">
                  You hold no shareable access in this workspace.
                </p>
              <% else %>
                <div class="airdrop-caps">
                  <.bp_checkbox
                    :if={"read" in @caps}
                    name="capabilities[]"
                    value="read"
                    label="View"
                    checked
                  />
                  <.bp_checkbox
                    :if={"write" in @caps}
                    name="capabilities[]"
                    value="write"
                    label="Edit"
                  />
                </div>
              <% end %>
            </div>

            <.bp_checkbox
              name="single_use"
              value="true"
              label="Single use (link is spent on first claim)"
            />

            <p :if={@error} class="shares-error" data-test-id="airdrop-error"><%= @error %></p>

            <div class="item-share-footer">
              <button type="button" class="btn btn-sm" phx-click="airdrop-close">Cancel</button>
              <button
                type="submit"
                class="btn btn-primary btn-sm"
                data-test-id="airdrop-submit"
                disabled={@caps == []}
              >
                Share access
              </button>
            </div>
          </form>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  ACCESS panel (airdrop-grants slice 3 UI) — the read/revoke sibling of
  `airdrop_sheet`. An HONEST, live-active view of scoped access, in two sections:

    * **Your access** (`@own_grants`, from the `:access_grants` assign) — the
      caller's own inbound grants: scope + capability chips + a live expiry
      countdown chip (client-side `ExpiryCountdown` hook on `data-expires-at`).
    * **Active grants in this workspace** (`@workspace_grants`) — rendered ONLY
      when `@workspace_view` (the caller is a workspace member, membership-gated
      exactly like `AccessController.index`): each row carries grantee, scope,
      an expiry chip, and a one-click **Revoke** (`access-revoke` → server-
      authorized `Access.revoke/2`).

  A revoked/expired row VANISHES on the next re-list (the active predicate lives
  in-query): this is a live-active view, not a history log. Distinct from
  `shares_modal` (P6 network shares) and `item_share_popover` (`/s/` links) —
  those are different features and are NOT touched here.

  Events bubble to StudioLive: access-close, access-revoke.
  """
  attr :show, :boolean, default: false
  attr :own_grants, :list, default: []
  attr :workspace_view, :boolean, default: false
  attr :workspace_grants, :list, default: []
  attr :error, :string, default: nil

  def access_panel(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="image-picker-overlay" phx-click="access-close"></div>
      <div
        class="image-picker access-panel"
        role="dialog"
        aria-modal="true"
        aria-labelledby="access-panel-title"
        phx-window-keydown="access-close"
        phx-key="escape"
      >
        <div class="image-picker-header">
          <span id="access-panel-title" style="font-weight: 600; font-size: 14px;">Access</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="access-close" aria-label="Close">×</button>
        </div>

        <div class="access-panel-body" data-test-id="access-panel">
          <p :if={@error} class="shares-error" data-test-id="access-error"><%= @error %></p>

          <%!-- ── Your access — the caller's own inbound grants ── --%>
          <section class="access-section" data-test-id="access-your">
            <h3 class="access-section-title">Your access</h3>
            <%= if @own_grants == [] do %>
              <p class="shares-note" data-test-id="access-your-empty">
                You have no scoped access grants right now.
              </p>
            <% else %>
              <ul class="access-list">
                <li :for={g <- @own_grants} class="access-row" data-test-id="access-your-row">
                  <div class="access-row-main">
                    <span class="access-scope"><%= grant_scope_label(g) %></span>
                    <span class="access-caps"><%= grant_caps_label(g) %></span>
                  </div>
                  <.expiry_chip grant={g} />
                </li>
              </ul>
            <% end %>
          </section>

          <%!-- ── Active grants in this workspace — members only ── --%>
          <section :if={@workspace_view} class="access-section" data-test-id="access-workspace">
            <h3 class="access-section-title">Active grants in this workspace</h3>
            <%= if @workspace_grants == [] do %>
              <p class="shares-note" data-test-id="access-workspace-empty">
                No active grants in this workspace.
              </p>
            <% else %>
              <ul class="access-list">
                <li :for={g <- @workspace_grants} class="access-row" data-test-id="access-workspace-row">
                  <div class="access-row-main">
                    <span class="access-grantee"><%= g.grantee_email %></span>
                    <span class="access-scope"><%= grant_scope_label(g) %></span>
                    <span class="access-caps"><%= grant_caps_label(g) %></span>
                  </div>
                  <.expiry_chip grant={g} />
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm"
                    phx-click="access-revoke"
                    phx-value-id={g.id}
                    data-test-id="access-revoke"
                    aria-label={"Revoke access for #{g.grantee_email}"}
                  >
                    <.icon name="trash-2" size={14} /> Revoke
                  </button>
                </li>
              </ul>
            <% end %>
          </section>
        </div>
      </div>
    <% end %>
    """
  end

  # Live expiry countdown chip. A grant WITH an expiry mounts the client-side
  # `ExpiryCountdown` hook on `data-expires-at` (per-second visual only — the
  # server tick already DROPS access at expiry, so this is presentation, not
  # enforcement). A no-expiry grant renders a static "No expiry" chip.
  attr :grant, :map, required: true

  defp expiry_chip(assigns) do
    ~H"""
    <%= if @grant.expires_at do %>
      <span
        id={"access-exp-#{@grant.id}"}
        class="access-chip access-chip-expiry"
        phx-hook="ExpiryCountdown"
        phx-update="ignore"
        data-expires-at={DateTime.to_iso8601(@grant.expires_at)}
        data-test-id="access-countdown"
      >
        expiring…
      </span>
    <% else %>
      <span class="access-chip" data-test-id="access-no-expiry">No expiry</span>
    <% end %>
    """
  end

  # A readable scope label down the grant ladder. `workspace_id`/`project_id`
  # are opaque UUIDs (not shown); `dataset`/`type`/`doc_id` are author-readable.
  # A workspace-only grant (all narrows NULL) reads "Workspace".
  defp grant_scope_label(grant) do
    narrows =
      [
        grant.dataset && "dataset: #{grant.dataset}",
        grant.type && "type: #{grant.type}",
        grant.doc_id && "doc: #{grant.doc_id}"
      ]
      |> Enum.reject(&is_nil/1)

    project = if grant.project_id, do: "project", else: nil

    case Enum.reject([project | narrows], &is_nil/1) do
      [] -> "Workspace"
      parts -> "Workspace · " <> Enum.join(parts, " · ")
    end
  end

  # Human capability chips: read → View, write → Edit, admin → Admin.
  defp grant_caps_label(%{capabilities: caps}) when is_list(caps) do
    caps
    |> Enum.map(fn
      "read" -> "View"
      "write" -> "Edit"
      "admin" -> "Admin"
      other -> other
    end)
    |> Enum.join(", ")
  end

  defp grant_caps_label(_), do: ""

  @doc """
  Reference-picker modal, formerly a legacy inline block in StudioLive, now
  aggregated by `studio_modals/1`. Shares the `.image-picker` overlay styling
  (deliberate — same modal chrome). Caller pre-filters candidates via
  `ref_search` so this component is data-only.

  Events bubble to StudioLive: close-ref-picker, ref-search, select-ref.
  """
  attr :ref_picker_field, :string, default: nil
  attr :ref_search, :string, default: ""
  attr :ref_candidates, :list, default: []

  def ref_picker_modal(assigns) do
    ~H"""
    <%= if @ref_picker_field do %>
      <div class="image-picker-overlay" phx-click="close-ref-picker"></div>
      <div
        class="image-picker"
        role="dialog"
        aria-modal="true"
        aria-labelledby="ref-picker-title"
        phx-window-keydown="close-ref-picker"
        phx-key="escape"
      >
        <div class="image-picker-header">
          <span id="ref-picker-title" style="font-weight: 600; font-size: 14px;">Select reference</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-ref-picker" aria-label="Close">×</button>
        </div>
        <div style="padding: 10px 16px; border-bottom: 1px solid var(--border-muted);">
          <input type="text" placeholder="Search..." class="form-input" phx-keyup="ref-search" phx-debounce="200" value={@ref_search} />
        </div>
        <div style="max-height: 400px; overflow-y: auto;">
          <% filtered = filter_ref_candidates(@ref_candidates, @ref_search) %>
          <%= for candidate <- filtered do %>
            <div class="ref-candidate" phx-click="select-ref" phx-value-id={candidate.id} phx-value-field={@ref_picker_field}>
              <span class="ref-candidate-title"><%= candidate.title %></span>
              <span class="ref-candidate-id"><%= candidate.id %></span>
            </div>
          <% end %>
          <%= if filtered == [] do %>
            <div class="text-sm text-muted" style="padding: 20px; text-align: center;">No documents found</div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp filter_ref_candidates(candidates, ""), do: candidates
  defp filter_ref_candidates(candidates, nil), do: candidates

  defp filter_ref_candidates(candidates, query) do
    q = String.downcase(query)

    Enum.filter(candidates, fn c ->
      String.contains?(String.downcase(c.title), q) or String.contains?(String.downcase(c.id), q)
    end)
  end

  @doc """
  History modal, formerly inline in StudioLive, now aggregated by
  `studio_modals/1`. Renders the
  list of past revisions with restore buttons. The `format_history_time/1`
  helper migrates from StudioLive into this module (private).

  Events bubble to StudioLive: close-history, restore-revision.
  """
  attr :show_history, :boolean, default: false
  attr :revisions, :list, default: []

  def history_modal(assigns) do
    ~H"""
    <%= if @show_history do %>
      <div class="image-picker-overlay" phx-click="close-history"></div>
      <div
        class="history-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="history-modal-title"
        phx-window-keydown="close-history"
        phx-key="escape"
      >
        <div class="image-picker-header">
          <span id="history-modal-title" style="font-weight: 600; font-size: 14px;">Document history</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-history" aria-label="Close">×</button>
        </div>
        <div class="history-list">
          <%= if @revisions == [] do %>
            <div class="text-sm text-muted" style="padding: 24px; text-align: center;">No history yet</div>
          <% end %>
          <%= for rev <- @revisions do %>
            <div class="history-item">
              <div class="history-item-info">
                <div class="history-item-action">
                  <span class={"history-action-badge history-action-#{rev.action}"}><%= rev.action %></span>
                  <span class="history-item-title"><%= rev.title || "Untitled" %></span>
                </div>
                <div class="history-item-time"><%= format_history_time(rev.inserted_at) %></div>
              </div>
              <button class="btn btn-sm" phx-click="restore-revision" phx-value-id={rev.id} data-confirm="Restore this version? Current changes will be overwritten.">Restore</button>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp format_history_time(dt) do
    Calendar.strftime(dt, "%b %d, %Y at %H:%M:%S")
  end

  @doc """
  Delete-confirmation modal, formerly inline in StudioLive, now aggregated
  by `studio_modals/1`.
  Two visual states: clean delete (no incoming references) and
  disconnect+delete (refs exist; lists each one).

  Events bubble to StudioLive: close-delete, confirm-delete (with or
  without `phx-value-disconnect="true"`).
  """
  attr :show_delete, :boolean, default: false
  attr :delete_refs, :list, default: []
  attr :editor_doc, :map, default: nil

  def delete_modal(assigns) do
    ~H"""
    <%= if @show_delete do %>
      <div class="image-picker-overlay" phx-click="close-delete"></div>
      <div
        class="delete-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="delete-modal-title"
        phx-window-keydown="close-delete"
        phx-key="escape"
      >
        <div class="delete-modal-header">
          <span id="delete-modal-title" style="font-weight: 600; font-size: 16px;">Delete document</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-delete" aria-label="Close">×</button>
        </div>
        <div class="delete-modal-body">
          <%= if @delete_refs == [] do %>
            <p class="text-sm">Are you sure you want to delete <strong><%= @editor_doc && @editor_doc.title %></strong>? This action cannot be undone.</p>
            <div class="delete-modal-actions">
              <button class="btn btn-sm" phx-click="close-delete">Cancel</button>
              <button class="btn btn-destructive btn-sm" phx-click="confirm-delete">Delete</button>
            </div>
          <% else %>
            <div class="delete-warning">
              <p class="text-sm" style="margin-bottom: 12px;">
                <strong><%= @editor_doc && @editor_doc.title %></strong> is referenced by
                <strong><%= length(@delete_refs) %></strong> document<%= if length(@delete_refs) != 1, do: "s" %>:
              </p>
              <div class="delete-ref-list">
                <%= for ref <- @delete_refs do %>
                  <div class="delete-ref-item">
                    <span class="delete-ref-title"><%= ref.title || "Untitled" %></span>
                    <span class="delete-ref-meta"><%= ref.type %> / <%= ref.field %></span>
                  </div>
                <% end %>
              </div>
            </div>
            <div class="delete-modal-actions">
              <button class="btn btn-sm" phx-click="close-delete">Cancel</button>
              <button class="btn btn-destructive btn-sm" phx-click="confirm-delete" phx-value-disconnect="true">Disconnect references and delete</button>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Confirmation modal for "Discard draft". Shown only when the editor is on
  a draft that has a published twin. Two-step: user clicks the overflow-menu
  action → this modal appears; clicking Discard fires `confirm-discard`.

  Guard semantics: the button that opens this modal is already gated on
  `has_published_twin` in `default_doc_actions/2`, so the modal itself is
  always reached with a valid published twin in scope. The handler adds a
  second server-side guard via `editor_has_published`.

  Events bubble to StudioLive: close-discard, confirm-discard.
  """
  attr :show_discard, :boolean, default: false
  attr :editor_doc, :map, default: nil

  def discard_modal(assigns) do
    ~H"""
    <%= if @show_discard do %>
      <div class="image-picker-overlay" phx-click="close-discard"></div>
      <div
        class="delete-modal"
        data-test-id="discard-draft-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="discard-modal-title"
        phx-window-keydown="close-discard"
        phx-key="escape"
      >
        <div class="delete-modal-header">
          <span id="discard-modal-title" style="font-weight: 600; font-size: 16px;">Discard draft</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-discard" aria-label="Close">×</button>
        </div>
        <div class="delete-modal-body">
          <p class="text-sm">
            Discard all unsaved changes to <strong><%= @editor_doc && @editor_doc.title %></strong>?
            The published version will remain untouched.
          </p>
          <div class="delete-modal-actions">
            <button class="btn btn-sm" phx-click="close-discard">Cancel</button>
            <button
              class="btn btn-destructive btn-sm"
              phx-click="confirm-discard"
              data-test-id="confirm-discard"
            >
              Discard draft
            </button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Profile-edit modal, formerly inline in StudioLive, now aggregated by
  `studio_modals/1`. Shown
  when `show_profile` is true. Form `phx-change="preview-profile"` lets
  StudioLive preview the new color/name before commit; `phx-submit="save-profile"`
  persists.

  Events bubble to StudioLive: close-profile, save-profile, preview-profile.
  """
  attr :show_profile, :boolean, default: false
  attr :user_name, :string, required: true
  attr :user_color, :string, required: true

  def profile_modal(assigns) do
    ~H"""
    <%= if @show_profile do %>
      <div class="image-picker-overlay" phx-click="close-profile"></div>
      <div
        class="profile-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="profile-modal-title"
        phx-window-keydown="close-profile"
        phx-key="escape"
      >
        <div class="image-picker-header">
          <span id="profile-modal-title" style="font-weight: 600; font-size: 14px;">Your profile</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-profile" aria-label="Close">×</button>
        </div>
        <form phx-submit="save-profile" phx-change="preview-profile" style="padding: 20px;">
          <div style="display: flex; align-items: center; gap: 12px; margin-bottom: 20px;">
            <div class="presence-me" style={"background: #{@user_color}; width: 40px; height: 40px; font-size: 16px;"}>
              <%= String.first(@user_name) %>
            </div>
            <div>
              <div style="font-weight: 600;"><%= @user_name %></div>
              <div class="text-xs text-muted">This is how others see you</div>
            </div>
          </div>
          <div class="form-group">
            <label class="form-label">Name</label>
            <input type="text" name="name" value={@user_name} class="form-input" autofocus phx-debounce="200" />
          </div>
          <div class="form-group">
            <label class="form-label">Color</label>
            <div class="profile-colors">
              <%= for c <- ~w(#3b82f6 #ef4444 #10b981 #f59e0b #8b5cf6 #ec4899 #06b6d4 #f97316) do %>
                <%!-- D14 exempt: this radio is display:none behind the custom
                      color-swatch UI — the browser never paints the control, so
                      it stays a raw <input> (bp_radio would render a visible
                      circle). The approved swatch hex literals are D10-exempt. --%>
                <label class={"profile-color-option #{if c == @user_color, do: "selected"}"}>
                  <input type="radio" name="color" value={c} checked={c == @user_color} style="display:none" />
                  <span class="profile-color-swatch" style={"background: #{c}"}></span>
                </label>
              <% end %>
            </div>
          </div>
          <div style="display: flex; justify-content: flex-end; gap: 8px; margin-top: 8px;">
            <button type="button" class="btn btn-sm" phx-click="close-profile">Cancel</button>
            <button type="submit" class="btn btn-primary btn-sm">Save</button>
          </div>
        </form>
      </div>
    <% end %>
    """
  end

  @doc """
  Umbrella that composes the five Studio modal components into a single
  call site. Each child renders only when its gate assign is set, so the
  umbrella's emitted DOM is byte-identical to the legacy five top-level
  `<%= if … %>` blocks formerly inline in StudioLive.

  Per-modal components remain individually exported for testability and
  for any future LV that wants only one modal in isolation.

  Order matches the legacy render order: profile, image_picker,
  ref_picker, history, delete. (Profile sits OUTSIDE pane_layout in the
  legacy markup; the other four sit INSIDE. Caller chooses placement.)
  """
  attr :show_profile, :boolean, default: false
  attr :user_name, :string, default: ""
  attr :user_color, :string, default: ""

  attr :image_picker_field, :string, default: nil
  attr :uploads, :map, required: true
  attr :media_files, :list, default: []

  attr :ref_picker_field, :string, default: nil
  attr :ref_search, :string, default: ""
  attr :ref_candidates, :list, default: []

  attr :show_history, :boolean, default: false
  attr :revisions, :list, default: []

  attr :show_delete, :boolean, default: false
  attr :delete_refs, :list, default: []
  attr :editor_doc, :map, default: nil
  attr :show_discard, :boolean, default: false

  def studio_modals(assigns) do
    ~H"""
    <.profile_modal
      show_profile={@show_profile}
      user_name={@user_name}
      user_color={@user_color}
    />
    <.image_picker_modal
      image_picker_field={@image_picker_field}
      uploads={@uploads}
      media_files={@media_files}
    />
    <.ref_picker_modal
      ref_picker_field={@ref_picker_field}
      ref_search={@ref_search}
      ref_candidates={@ref_candidates}
    />
    <.history_modal show_history={@show_history} revisions={@revisions} />
    <.delete_modal
      show_delete={@show_delete}
      delete_refs={@delete_refs}
      editor_doc={@editor_doc}
    />
    <.discard_modal show_discard={@show_discard} editor_doc={@editor_doc} />
    """
  end

  # Human-readable copy for the client-side `allow_upload` validation errors
  # (see StudioLive.mount: accept ~w(.jpg .jpeg .png .gif .webp .svg),
  # max_entries: 1, max_file_size: 10 MB).
  defp upload_error_to_string(:too_large), do: "That image is too large — the limit is 10 MB."
  defp upload_error_to_string(:too_many_files), do: "You can only upload one image at a time."

  defp upload_error_to_string(:not_accepted),
    do: "That file type isn't supported — use a JPG, PNG, GIF, WEBP, or SVG."

  defp upload_error_to_string(_), do: "That image couldn't be uploaded."
end
