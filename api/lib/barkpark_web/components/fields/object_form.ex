defmodule BarkparkWeb.Components.Fields.ObjectForm do
  @moduledoc """
  One object's fields in a form, by the schema of its type. Two places use it:

    * a row of an `arrayOf` with several named member types (Sanity's
      page-builder array, such as `frontPage.frontpageSections`), inside the
      document form (task-e24e33a2a1a4fe10);
    * a custom block of a Portable Text body (a `mediaModule`, a `quote`),
      in the block dialog the Classic rich-text editor opens
      (task-19392d1e6fc661e6).

  The object keeps Sanity's stored shape: `_type` and `_key` ride as hidden
  inputs next to the fields, so a post carries them, and `Content.Forms`
  keeps every stored key the form does not render.

  ## Assigns

    * `:member` (required) — the type's `%Field{type: "composite"}`, with the
      subfields its schema declares
    * `:value` — the object as stored (a map)
    * `:path` — the input name prefix (`doc[frontpageSections][0]`, `obj`)
    * `:on_reorder` — the `phx-click` event of nested array buttons
    * the picker context and finding maps `CompositeField` takes
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Components.Fields.CompositeField

  attr :member, :map, required: true
  attr :value, :map, default: %{}
  attr :path, :string, required: true
  attr :errors, :map, default: %{}
  attr :warnings, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :on_reorder, :string, default: "array_op"
  attr :plugin_name, :string, default: "core"
  attr :readonly, :boolean, default: false
  attr :dataset, :string, default: "production"
  attr :scope_prefix, :string, default: ""
  attr :api_token_raw, :string, default: ""
  attr :root, :map, default: nil
  attr :target, :any, default: nil

  def object_form(assigns) do
    value = if is_map(assigns[:value]), do: assigns.value, else: %{}

    assigns =
      assigns
      |> Map.put(:value, value)
      |> Map.put(:type, string_or_nil(value["_type"]))
      |> Map.put(:key, string_or_nil(value["_key"]))
      |> Map.put(:editable?, editable?(assigns.member))
      |> Map.put_new(:errors, %{})
      |> Map.put_new(:warnings, %{})
      |> Map.put_new(:on_change, nil)
      |> Map.put_new(:on_reorder, "array_op")
      |> Map.put_new(:target, nil)
      |> Map.put_new(:plugin_name, "core")
      |> Map.put_new(:readonly, false)
      |> Map.put_new(:dataset, "production")
      |> Map.put_new(:scope_prefix, "")
      |> Map.put_new(:api_token_raw, "")
      |> Map.put_new(:root, nil)

    ~H"""
    <div class="bp-object-form" data-object-type={@type} data-object-key={@key}>
      <input :if={@type} type="hidden" name={@path <> "._type"} value={@type} />
      <input :if={@key} type="hidden" name={@path <> "._key"} value={@key} />
      <%= if @editable? do %>
        <CompositeField.composite_field
          field={@member}
          value={@value}
          errors={@errors}
          warnings={@warnings}
          on_change={@on_change}
          on_reorder={@on_reorder}
          target={@target}
          plugin_name={@plugin_name}
          path={@path}
          readonly={@readonly}
          bare={true}
          dataset={@dataset}
          scope_prefix={@scope_prefix}
          api_token_raw={@api_token_raw}
          root={@root}
        />
      <% else %>
        <pre class="bp-input" data-structured-value style="margin:0;white-space:pre-wrap;word-break:break-word;opacity:0.75;"><%= Jason.encode!(@value, pretty: true) %></pre>
        <span style="display:block;margin-top:4px;font-size:11px;opacity:0.55;"><%= gettext("read-only — no schema declares this item type; saved unchanged") %></span>
      <% end %>
    </div>
    """
  end

  @doc """
  The dialog the Classic rich-text editor opens for a custom Portable Text
  block (task-19392d1e6fc661e6), an annotation or an inline object: the
  object's fields in `object_form/1`, in a form of its own, so its inputs
  never post with the document form. Save writes the object back into the
  body by its `_key`; Cancel discards the dialog's edits. An annotation's
  dialog also has Remove, which takes the annotation off its text.
  """
  attr :dialog, :map, default: nil
  attr :dataset, :string, default: "production"
  attr :scope_prefix, :string, default: ""
  attr :api_token_raw, :string, default: ""

  def block_dialog(assigns) do
    ~H"""
    <%= if @dialog do %>
      <div class="modal-backdrop" data-test-id="object-dialog">
        <%!-- No backdrop `phx-click` and no stopPropagation on the card: see
              `secondary_picker_modal/1` for why. --%>
        <div
          class="modal-card bp-object-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="bp-object-dialog-title"
          id="bp-object-dialog"
          phx-hook="ModalFocus"
          phx-window-keydown="object-dialog-close"
          phx-key="escape"
          data-object-type={@dialog.type}
          data-object-key={@dialog.key}
        >
          <div class="modal-header">
            <h3 id="bp-object-dialog-title"><%= @dialog.title %></h3>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="object-dialog-close" aria-label={gettext("Close")}>×</button>
          </div>
          <form id={"bp-object-dialog-form-" <> @dialog.key} phx-change="object-dialog-change" phx-submit="object-dialog-save">
            <div class="modal-body bp-object-dialog-body">
              <.object_form
                member={@dialog.member}
                value={@dialog.value}
                path={BarkparkWeb.Studio.StudioLive.Handlers.ObjectBlocks.prefix()}
                on_reorder="object-dialog-array-op"
                dataset={@dataset}
                scope_prefix={@scope_prefix}
                api_token_raw={@api_token_raw}
              />
            </div>
            <div class="modal-footer bp-object-dialog-actions">
              <button
                :if={Map.get(@dialog, :kind) == :annotation}
                type="button"
                class="btn btn-ghost"
                phx-click="object-dialog-remove"
                data-object-dialog-remove
              ><%= gettext("Remove") %></button>
              <button type="button" class="btn btn-ghost" phx-click="object-dialog-close"><%= gettext("Cancel") %></button>
              <button type="submit" class="btn btn-primary" data-object-dialog-save><%= save_label(@dialog) %></button>
            </div>
          </form>
        </div>
      </div>
    <% end %>
    """
  end

  defp save_label(%{kind: :annotation}), do: gettext("Save annotation")
  defp save_label(%{kind: :inline}), do: gettext("Save item")
  defp save_label(_dialog), do: gettext("Save block")

  @doc "True when the member declares fields the form can render."
  def editable?(%{type: "composite", fields: [_ | _]}), do: true
  def editable?(_), do: false

  defp string_or_nil(v) when is_binary(v) and v != "", do: v
  defp string_or_nil(_), do: nil
end
