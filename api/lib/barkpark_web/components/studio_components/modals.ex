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

  @doc """
  Image-picker modal extracted from the legacy inline block at
  `studio_live.ex:1184-1215`. Renders the overlay + media-grid card when
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
      <div class="image-picker">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Select Image</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-image-picker">x</button>
        </div>
        <div class="image-picker-upload">
          <form phx-change="validate-upload" phx-submit="upload-image" phx-value-field={@image_picker_field} id="upload-form">
            <.live_file_input upload={@uploads.image} class="image-file-input" />
            <%= for entry <- @uploads.image.entries do %>
              <div class="image-upload-entry">
                <.live_img_preview entry={entry} width="60" height="60" />
                <span class="text-sm"><%= entry.client_name %></span>
                <button type="submit" class="btn btn-primary btn-sm">Upload</button>
              </div>
            <% end %>
          </form>
        </div>
        <div class="image-picker-grid">
          <%= if @media_files == [] do %>
            <div class="text-sm text-muted" style="padding: 16px; text-align: center;">No images yet. Upload one above.</div>
          <% end %>
          <%= for file <- @media_files do %>
            <div class="image-picker-item" phx-click="select-media" phx-value-url={"/media/files/#{file.path}"} phx-value-field={@image_picker_field}>
              <img src={"/media/files/#{file.path}"} alt={file.original_name} />
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
      <div class="image-picker shares-modal">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Network shares</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="shares-close" aria-label="Close">x</button>
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
                <label :for={surface <- ~w(papers docs media)}>
                  <input
                    type="checkbox"
                    name="surfaces[]"
                    value={surface}
                    checked={surface in @prefill_surfaces}
                  />
                  <%= String.capitalize(surface) %>
                </label>
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

  `@links` is a pre-flattened list of `%{id, access, url}`.
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
      <div class="image-picker item-share-modal">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Share &ldquo;<%= @title %>&rdquo;</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="item-share-close" aria-label="Close">x</button>
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
                  onclick={"if(navigator.clipboard){var u='#{link.url}';navigator.clipboard.writeText(/^https?:/.test(u)?u:location.origin+u);this.textContent='Copied'}"}
                  title="Copy link"
                >
                  Copy
                </button>
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
              <span class="shares-note">Edit links are coming next.</span>
              <button
                type="button"
                class="btn btn-primary btn-sm"
                phx-click="item-share-create"
                phx-value-access="read"
              >
                Create view link
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
  Reference-picker modal extracted from the legacy inline block at
  `studio_live.ex:1218-1240`. Shares the `.image-picker` overlay styling
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
      <div class="image-picker">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Select reference</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-ref-picker">x</button>
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
  History modal extracted from `studio_live.ex:1243-1268`. Renders the
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
      <div class="history-modal">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Document history</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-history">x</button>
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
  Delete-confirmation modal extracted from `studio_live.ex:1271-1307`.
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
      <div class="delete-modal">
        <div class="delete-modal-header">
          <span style="font-weight: 600; font-size: 16px;">Delete document</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-delete">x</button>
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
      <div class="delete-modal" data-test-id="discard-draft-modal">
        <div class="delete-modal-header">
          <span style="font-weight: 600; font-size: 16px;">Discard draft</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-discard">x</button>
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
  Profile-edit modal extracted from `studio_live.ex:986-1025`. Shown
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
      <div class="profile-modal">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Your profile</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-profile">x</button>
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
end
