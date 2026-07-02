defmodule BarkparkWeb.Studio.SettingsLive do
  @moduledoc """
  Generic encrypted-JSON editor for plugin settings.

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

  alias Barkpark.Plugins.Registry, as: PluginsRegistry
  alias Barkpark.Plugins.Settings
  alias Barkpark.Plugins.Settings.Masking

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Plugin Settings",
       plugin_name: "",
       settings_json: "",
       settings_fields: [],
       typed_form: %{},
       revealed: %{},
       masked: true,
       loaded?: false,
       error: nil
     )}
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

  # Fall-through: a stale/unknown phx event must not FunctionClauseError-crash
  # the session. Keep LAST among handle_event/3 clauses.
  def handle_event(event, _params, socket) do
    Logger.warning("studio: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="settings-live" style="max-width: 720px; margin: 2rem auto; font-family: ui-sans-serif, system-ui;">
      <h1>Plugin Settings</h1>

      <p style="color: var(--fg-muted);">
        Encrypted JSON store. Values are masked on load — click <em>Reveal</em>
        to fetch unmasked (audited).
      </p>

      <%= if msg = Phoenix.Flash.get(@flash, :info) do %>
        <div role="status" style="background:var(--success-bg); color:var(--success); padding:.5rem; margin:.5rem 0;">{msg}</div>
      <% end %>
      <%= if msg = Phoenix.Flash.get(@flash, :error) do %>
        <div role="alert" style="background:var(--destructive-bg); color:var(--destructive); padding:.5rem; margin:.5rem 0;">{msg}</div>
      <% end %>

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
    </div>
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
        restored = restore_masked(map, stored_settings(socket, name))

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

  # Deep-restore for the raw-JSON path: walk `decoded` and `stored` in parallel
  # (maps by key, lists by index); any string leaf equal to `Masking.mask/1` of
  # the matching stored leaf is the untouched placeholder → keep the stored raw.
  defp restore_masked(decoded, stored) when is_map(decoded) and is_map(stored) do
    Map.new(decoded, fn {k, v} -> {k, restore_masked(v, Map.get(stored, k))} end)
  end

  defp restore_masked(decoded, stored) when is_list(decoded) and is_list(stored) do
    decoded
    |> Enum.with_index()
    |> Enum.map(fn {v, i} -> restore_masked(v, Enum.at(stored, i)) end)
  end

  defp restore_masked(decoded, stored) when is_binary(decoded) and is_binary(stored) do
    if decoded == Masking.mask(stored), do: stored, else: decoded
  end

  defp restore_masked(decoded, _stored), do: decoded

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
