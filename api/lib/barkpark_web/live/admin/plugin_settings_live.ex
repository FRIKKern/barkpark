defmodule BarkparkWeb.Admin.PluginSettingsLive do
  @moduledoc """
  Admin LiveView at `/studio/:dataset/_plugins/:plugin/settings` — the
  browser-side form that replaces SSH + `mix run` for managing a
  plugin's encrypted settings row.

  ## Auth

  Mounted inside the `live_session :admin_studio_dataset` block in
  `BarkparkWeb.Router`, same gate as `PluginsLive` — non-admins are
  redirected to `/studio` by `BarkparkWeb.LiveAuth.:admin`.

  ## Field-name → settings-row mapping

  `Barkpark.Plugin.settings_schema/0` returns field names like
  `"<row>.<key>"`. The leading dot-segment is the `plugin_settings` row
  name; the trailing remainder is the flat key inside that row. This is
  the exact shape the runtime client reads back via
  `Plugins.Settings.get/1`. Fields with no dot in their name fall back
  to the URL plugin name as the row, with the field name as the flat
  key.

  Storing means grouping by row, building one map per row, and calling
  `Plugins.Settings.put/3` once per row — that keeps the audit log
  granular (one `"write"` per row, not one per field).

  ## Secret handling

  `:password` fields — and string-ish fields the plugin flagged
  `masked: true` (e.g. OnixEdit's `bokbasen.client_id`) — render
  `<input type="password">` with empty value; see `secret?/1`.
  When a secret already exists in the DB, an additional masked badge
  (`••••••`) plus Reveal / Clear buttons appear below the input. The
  raw secret is NEVER serialised into the rendered DOM unless the admin
  clicks Reveal — that flips a per-field flag in socket assigns and
  echoes the value inside a `<details>` block. Submitting an empty
  password field leaves the existing value untouched (so the admin
  doesn't accidentally wipe a working credential by saving the form).

  Empty `:password` form values are dropped before the merge, so saving
  with the secret box blank preserves the existing encrypted value.

  ## Test connection

  When the plugin module exports `test_connection/1` (every plugin built
  with `use Barkpark.Plugin` does — the default returns `{:error,
  :not_implemented}`), the form renders a single "Test connection"
  button. Clicking it calls `Plugins.Registry.collect_test_connection/2`
  which first-wins-resolves the plugin by name and invokes its callback
  with the live form's settings. The result is surfaced as an `:info` or
  `:error` flash. The host stays plugin-agnostic — there is no
  per-plugin branching in this module.
  """

  use BarkparkWeb, :live_view

  require Logger

  alias Barkpark.Plugins.Registry
  alias Barkpark.Plugins.Settings

  @impl true
  def mount(%{"dataset" => dataset, "plugin" => plugin_name}, _session, socket) do
    case Registry.lookup(plugin_name) do
      {:ok, entry} ->
        fields = resolve_schema(entry.module)

        if fields == [] do
          {:ok,
           socket
           |> put_flash(:error, "Plugin #{plugin_name} declares no settings.")
           |> redirect(to: ~p"/studio/#{dataset}/_plugins")}
        else
          stored = load_all_rows(fields)

          {:ok,
           socket
           |> assign(
             page_title: "Plugin settings: #{plugin_name}",
             dataset: dataset,
             plugin_name: plugin_name,
             plugin_module: entry.module,
             plugin_manifest: entry.manifest,
             fields: fields,
             groups: group_fields(fields),
             stored: stored,
             form_values: initial_form_values(fields, stored),
             revealed: %{},
             errors: %{}
           )}
        end

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Plugin #{plugin_name} is not registered.")
         |> redirect(to: ~p"/studio/#{dataset}/_plugins")}
    end
  end

  # ── events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("save", params, socket) do
    submitted = Map.get(params, "settings", %{})

    merged =
      socket.assigns.fields
      |> Enum.reduce(%{}, fn field, acc ->
        submitted_value = Map.get(submitted, field.name)
        keep_existing? = secret?(field) and blank?(submitted_value)

        cond do
          keep_existing? ->
            case stored_value(socket.assigns.stored, field) do
              {:ok, existing} when not is_nil(existing) -> Map.put(acc, field.name, existing)
              _ -> acc
            end

          is_nil(submitted_value) ->
            acc

          true ->
            Map.put(acc, field.name, submitted_value)
        end
      end)

    case validate(socket.assigns.fields, merged) do
      {:ok, validated} ->
        case run_plugin_validation(socket.assigns.plugin_module, validated) do
          :ok ->
            case persist_rows(validated, socket) do
              :ok ->
                {:noreply,
                 socket
                 |> assign(
                   stored: load_all_rows(socket.assigns.fields),
                   form_values: initial_form_values(socket.assigns.fields, %{}),
                   errors: %{},
                   revealed: %{}
                 )
                 |> reload_with_stored()
                 |> put_flash(:info, "Settings saved.")}

              # A write can fail (Cloak/DB/changeset) — surface it instead of
              # flashing "saved" over a credential that never persisted. Keep
              # the form as typed so the admin can retry without re-entering.
              {:error, row, _changeset} ->
                {:noreply,
                 socket
                 |> assign(form_values: stringify_form(merged))
                 |> put_flash(:error, "Failed to save settings for " <> row <> ".")}
            end

          {:error, plugin_errors} ->
            {:noreply,
             socket
             |> assign(form_values: stringify_form(merged), errors: Map.new(plugin_errors))
             |> put_flash(:error, "Validation failed.")}
        end

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(form_values: stringify_form(merged), errors: errors)
         |> put_flash(:error, "Please fix the highlighted fields.")}
    end
  end

  def handle_event("reveal", %{"name" => field_name}, socket) do
    user_id = current_user_id(socket)
    field = Enum.find(socket.assigns.fields, &(&1.name == field_name))

    case field && reveal_value(field, user_id) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:noreply, assign(socket, revealed: Map.put(socket.assigns.revealed, field_name, value))}

      _ ->
        {:noreply, put_flash(socket, :error, "Nothing stored for #{field_name}.")}
    end
  end

  def handle_event("hide", %{"name" => field_name}, socket) do
    {:noreply, assign(socket, revealed: Map.delete(socket.assigns.revealed, field_name))}
  end

  def handle_event("clear", %{"name" => field_name}, socket) do
    user_id = current_user_id(socket)
    field = Enum.find(socket.assigns.fields, &(&1.name == field_name))

    if field do
      {row, key} = split_field_name(field.name)
      current = load_row(row)

      cleared = Map.delete(current, key)

      result =
        if map_size(cleared) == 0 do
          settings_impl().delete(row, user_id: user_id)
        else
          settings_impl().put(row, cleared, user_id: user_id)
        end

      # `Settings.delete/2` returns `:ok`, `Settings.put/3` returns `{:ok, _}` —
      # anything else is a failed write. Don't flash "cleared" over a value that
      # is still stored.
      case result do
        ok when ok == :ok or (is_tuple(ok) and elem(ok, 0) == :ok) ->
          {:noreply,
           socket
           |> assign(
             stored: load_all_rows(socket.assigns.fields),
             revealed: Map.delete(socket.assigns.revealed, field_name)
           )
           |> reload_with_stored()
           |> put_flash(:info, "#{field.label} cleared.")}

        _ ->
          {:noreply, put_flash(socket, :error, "Failed to clear #{field.label}.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("test-connection", _params, socket) do
    result =
      Registry.collect_test_connection(
        socket.assigns.plugin_name,
        current_settings(socket)
      )

    {kind, msg} = flash_for_test_connection(result)
    {:noreply, put_flash(socket, kind, msg)}
  end

  # Fall-through: a stale/unknown phx event must not FunctionClauseError-crash
  # the session. Keep LAST among handle_event/3 clauses.
  def handle_event(event, _params, socket) do
    Logger.warning("admin/plugin_settings: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # Fall-through: an unexpected message (e.g. a late PubSub delivery) must not
  # FunctionClauseError-crash the LiveView. Keep LAST among handle_info/2.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("admin/plugin_settings: unhandled info #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bp-settings-form" data-test-id="plugin-settings">
      <div class="bp-settings-header">
        <div>
          <h1 class="h1">{@plugin_name} settings</h1>
          <p class="bp-settings-meta text-muted">
            Encrypted at rest via <code>BARKPARK_CLOAK_KEY</code>. Every read, write,
            reveal, and delete is recorded in <code>plugin_settings_audits</code>.
          </p>
        </div>
        <.link navigate={~p"/studio/#{@dataset}/_plugins"} class="btn btn-sm">
          ← Back to plugins
        </.link>
      </div>

      <form
        phx-submit="save"
        autocomplete="off"
        data-test-id="plugin-settings-form"
      >
        <%= for {group, group_fields} <- @groups do %>
          <section class="bp-settings-group" data-test-group={group}>
            <h2 class="bp-settings-group-title">{group}</h2>

            <%= for field <- group_fields do %>
              <div class="bp-settings-field" data-test-field={field.name}>
                <label
                  for={field_id(field)}
                  class={if Map.get(field, :required), do: "bp-settings-field-required", else: ""}
                >
                  {field.label}
                </label>
                {render_field(assigns, field)}
                <%= if hint = Map.get(field, :hint) do %>
                  <span class="bp-settings-field-hint">{hint}</span>
                <% end %>
                <%= if err = Map.get(@errors, field.name) do %>
                  <span class="bp-settings-field-error" data-test-id={"error-#{field.name}"}>{err}</span>
                <% end %>
                <%= if secret?(field) do %>
                  {render_secret_actions(assigns, field)}
                <% end %>
              </div>
            <% end %>

          </section>
        <% end %>

        <%= if test_connection_available?(@plugin_module) do %>
          <div class="bp-settings-test-connection">
            <button
              type="button"
              class="btn btn-sm"
              phx-click="test-connection"
              data-test-action="test-connection"
            >
              Test connection
            </button>
          </div>
        <% end %>

        <div class="bp-settings-actions">
          <.link navigate={~p"/studio/#{@dataset}/_plugins"} class="btn btn-sm">
            Cancel
          </.link>
          <button type="submit" class="btn btn-sm btn-primary" data-test-action="save">
            Save
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp render_field(assigns, %{type: :select} = field) do
    options = Map.get(field, :options, [])
    current = Map.get(assigns.form_values, field.name, "")

    assigns =
      assign(assigns,
        field: field,
        options: options,
        current: current
      )

    ~H"""
    <select
      id={field_id(@field)}
      name={"settings[#{@field.name}]"}
      data-test-input={@field.name}
    >
      <%= for opt <- @options do %>
        <option value={opt} selected={to_string(@current) == opt}>{opt}</option>
      <% end %>
    </select>
    """
  end

  defp render_field(assigns, %{type: :boolean} = field) do
    current = Map.get(assigns.form_values, field.name, "false")
    truthy? = current in [true, "true", "on", "1"]

    assigns = assign(assigns, field: field, truthy: truthy?)

    ~H"""
    <input type="hidden" name={"settings[#{@field.name}]"} value="false" />
    <input
      type="checkbox"
      id={field_id(@field)}
      name={"settings[#{@field.name}]"}
      value="true"
      checked={@truthy}
      data-test-input={@field.name}
    />
    """
  end

  defp render_field(assigns, %{type: :password} = field) do
    render_secret_input(assigns, field)
  end

  # A `:string`/`:url` field flagged `masked: true` is a secret too — route it
  # through the same password-style input (empty value + `••••••` placeholder)
  # so the stored value is never echoed into the DOM. Must precede the generic
  # `[:string, :url]` clause below.
  defp render_field(assigns, %{type: type, masked: true} = field)
       when type in [:string, :url] do
    render_secret_input(assigns, field)
  end

  defp render_field(assigns, %{type: type} = field) when type in [:string, :url] do
    html_type = if type == :url, do: "url", else: "text"
    current = Map.get(assigns.form_values, field.name, "")
    assigns = assign(assigns, field: field, html_type: html_type, current: current)

    ~H"""
    <input
      type={@html_type}
      id={field_id(@field)}
      name={"settings[#{@field.name}]"}
      value={@current}
      data-test-input={@field.name}
    />
    """
  end

  defp render_secret_input(assigns, field) do
    assigns = assign(assigns, field: field, has_stored: stored?(assigns.stored, field))

    ~H"""
    <input
      type="password"
      id={field_id(@field)}
      name={"settings[#{@field.name}]"}
      value=""
      placeholder={if @has_stored, do: "••••••", else: ""}
      autocomplete="new-password"
      data-test-input={@field.name}
    />
    """
  end

  defp render_secret_actions(assigns, field) do
    assigns = assign(assigns, field: field, has_stored: stored?(assigns.stored, field))

    ~H"""
    <%= if @has_stored do %>
      <div class="bp-settings-secret-actions">
        <%= if Map.has_key?(@revealed, @field.name) do %>
          <button
            type="button"
            class="btn btn-xs"
            phx-click="hide"
            phx-value-name={@field.name}
            data-test-action={"hide-#{@field.name}"}
          >
            Hide
          </button>
        <% else %>
          <button
            type="button"
            class="btn btn-xs"
            phx-click="reveal"
            phx-value-name={@field.name}
            data-test-action={"reveal-#{@field.name}"}
          >
            Reveal
          </button>
        <% end %>
        <button
          type="button"
          class="btn btn-xs btn-danger"
          phx-click="clear"
          phx-value-name={@field.name}
          data-confirm={"Clear stored value for #{@field.label}?"}
          data-test-action={"clear-#{@field.name}"}
        >
          Clear
        </button>
      </div>
      <%= if revealed = Map.get(@revealed, @field.name) do %>
        <details open class="bp-settings-secret-reveal" data-test-id={"revealed-#{@field.name}"}>
          <summary>Revealed</summary>
          <span>{revealed}</span>
        </details>
      <% end %>
    <% end %>
    """
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp resolve_schema(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        []

      function_exported?(module, :settings_schema, 0) ->
        try do
          module.settings_schema()
          |> List.wrap()
          |> Enum.filter(&valid_field?/1)
        rescue
          _ -> []
        end

      true ->
        []
    end
  end

  defp valid_field?(%{name: name, type: type, label: label})
       when is_binary(name) and is_atom(type) and is_binary(label),
       do: true

  defp valid_field?(_), do: false

  defp group_fields(fields) do
    fields
    |> Enum.with_index()
    |> Enum.group_by(fn {f, _i} -> Map.get(f, :group, "General") end, fn {f, _i} -> f end)
    # Stable sort by first-appearance index of each group.
    |> Enum.sort_by(fn {group, _} ->
      Enum.find_index(fields, &(Map.get(&1, :group, "General") == group))
    end)
  end

  defp initial_form_values(fields, stored) do
    Enum.reduce(fields, %{}, fn field, acc ->
      cond do
        secret?(field) ->
          # Never echo a stored secret into the form input.
          Map.put(acc, field.name, "")

        true ->
          stored_v = stored_value_or_default(stored, field)
          Map.put(acc, field.name, stored_v)
      end
    end)
  end

  defp stored_value_or_default(stored, field) do
    case Map.fetch(stored, field.name) do
      {:ok, v} when not is_nil(v) -> to_string(v)
      _ -> field |> Map.get(:default, "") |> to_string()
    end
  end

  defp stringify_form(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v || "")} end)
  end

  defp stored?(stored, field) do
    case Map.fetch(stored, field.name) do
      {:ok, v} when is_binary(v) and byte_size(v) > 0 -> true
      _ -> false
    end
  end

  defp stored_value(stored, field) do
    case Map.fetch(stored, field.name) do
      {:ok, v} -> {:ok, v}
      :error -> :error
    end
  end

  defp load_all_rows(fields) do
    fields
    |> Enum.map(&split_field_name(&1.name))
    |> Enum.map(fn {row, _} -> row end)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn row, acc ->
      row_map = load_row(row)

      Enum.reduce(row_map, acc, fn {k, v}, inner_acc ->
        Map.put(inner_acc, "#{row}.#{k}", v)
      end)
    end)
    |> then(fn loaded ->
      # Keep only keys that correspond to declared fields so a stray DB key
      # from an older schema version doesn't leak into the form.
      declared = MapSet.new(Enum.map(fields, & &1.name))

      loaded
      |> Enum.filter(fn {k, _} -> MapSet.member?(declared, k) end)
      |> Map.new()
    end)
  end

  defp load_row(row) do
    try do
      case Settings.get(row) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    rescue
      # The DB sandbox / pool may transiently be unavailable during
      # boot-time plugin seeding in tests, and an admin should never see
      # a 500 just because a settings row read raised — surface an empty
      # map and let them re-save.
      _ -> %{}
    end
  end

  defp split_field_name(name) do
    case String.split(name, ".", parts: 2) do
      [row, key] -> {row, key}
      [bare] -> {default_row(), bare}
    end
  end

  defp default_row, do: "default"

  defp field_id(field), do: "field-" <> String.replace(field.name, ".", "-")

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false

  # A field is a secret when it's a `:password` OR a string-ish field the plugin
  # flagged `masked: true` (e.g. OnixEdit's `bokbasen.client_id`). Both get the
  # empty-means-keep round-trip, blank-seeded form value, and Reveal/Clear
  # affordances. The `masked` flag is only honoured on string-ish types so a
  # stray flag on `:select`/`:boolean` is ignored.
  defp secret?(%{type: :password}), do: true
  defp secret?(%{type: type, masked: true}) when type in [:string, :url], do: true
  defp secret?(_), do: false

  defp validate(fields, values) do
    errors =
      Enum.reduce(fields, %{}, fn field, acc ->
        v = Map.get(values, field.name)
        required? = Map.get(field, :required, false)

        cond do
          required? and blank?(v) ->
            Map.put(acc, field.name, "is required")

          field.type == :url and not blank?(v) and not url_like?(v) ->
            Map.put(acc, field.name, "must be a URL (http:// or https://)")

          field.type == :select and not blank?(v) and v not in Map.get(field, :options, []) ->
            Map.put(acc, field.name, "must be one of: " <> Enum.join(field.options, ", "))

          true ->
            acc
        end
      end)

    if map_size(errors) == 0, do: {:ok, values}, else: {:error, errors}
  end

  defp url_like?(v) when is_binary(v) do
    String.starts_with?(v, "http://") or String.starts_with?(v, "https://")
  end

  defp url_like?(_), do: false

  # Persist each settings row in one Settings.put/3 call so the audit log
  # carries one "write" per row and not one per form field. Returns `:ok`, or
  # `{:error, row, changeset}` on the first row that fails to persist — the
  # caller must NOT flash "saved" when an encrypted write silently dropped a
  # credential.
  defp persist_rows(validated, socket) do
    user_id = current_user_id(socket)

    validated
    |> Enum.reduce(%{}, fn {field_name, value}, acc ->
      {row, key} = split_field_name(field_name)
      row_map = Map.get(acc, row, load_row(row))
      Map.put(acc, row, Map.put(row_map, key, to_string(value)))
    end)
    |> Enum.reduce_while(:ok, fn {row, row_map}, _acc ->
      case settings_impl().put(row, row_map, user_id: user_id) do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, row, changeset}}
      end
    end)
  end

  # Settings mutations route through this indirection so a persistence failure
  # (Cloak/DB/changeset) is injectable in tests — the point of checking the
  # write result is that the admin must never be told a credential was stored
  # when it wasn't. Reads (`get`/`reveal`) hit `Settings` directly.
  defp settings_impl, do: Application.get_env(:barkpark, :plugin_settings_impl, Settings)

  # Hand the typed map to the plugin's validate_settings/1 if it defines
  # one. The plugin sees the same shape it would receive from any other
  # caller — flat keys for the rows it cares about — so existing
  # validators keep working.
  defp run_plugin_validation(module, validated) do
    if function_exported?(module, :validate_settings, 1) do
      try do
        shaped =
          Enum.reduce(validated, %{}, fn {field_name, value}, acc ->
            {row, key} = split_field_name(field_name)
            sub = Map.get(acc, row, %{})
            Map.put(acc, row, Map.put(sub, key, value))
          end)

        case module.validate_settings(shaped) do
          :ok -> :ok
          {:error, errs} when is_list(errs) -> {:error, errs}
          _ -> :ok
        end
      rescue
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp reveal_value(field, user_id) do
    {row, key} = split_field_name(field.name)

    case Settings.reveal(row, user_id: user_id) do
      {:ok, map} when is_map(map) -> {:ok, Map.get(map, key)}
      _ -> :error
    end
  end

  # The "Test connection" button renders when the plugin module exports
  # `test_connection/1`. Every `use Barkpark.Plugin` module exports it
  # because of the `defoverridable` default — plugins that have nothing
  # to test inherit the default which returns `{:error, :not_implemented}`,
  # and the host surfaces that as a flash. No per-plugin branching here.
  defp test_connection_available?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :test_connection, 1)
  end

  defp test_connection_available?(_), do: false

  # Build the settings map the plugin's `test_connection/1` callback
  # expects from the row-grouped form values. Mirrors `persist_rows/2`'s
  # row-grouping but reads from the latest stored values plus any
  # non-blank in-flight form input — so the admin can click "Test
  # connection" before pressing Save and see the new credentials
  # validated against the live endpoint.
  defp current_settings(socket) do
    fields = socket.assigns.fields
    stored = socket.assigns.stored
    form_values = socket.assigns.form_values

    Enum.reduce(fields, %{}, fn field, acc ->
      {row, key} = split_field_name(field.name)
      submitted = Map.get(form_values, field.name)

      value =
        cond do
          not blank?(submitted) ->
            submitted

          true ->
            case Map.fetch(stored, field.name) do
              {:ok, v} when not is_nil(v) -> v
              _ -> nil
            end
        end

      sub = Map.get(acc, row, %{})
      sub = if is_nil(value), do: sub, else: Map.put(sub, key, to_string(value))
      Map.put(acc, row, sub)
    end)
  end

  # Map the plugin's `{:ok, payload} | {:error, reason}` test_connection
  # contract onto the LV's `{flash_kind, flash_message}` shape.
  defp flash_for_test_connection({:ok, %{message: msg}}) when is_binary(msg),
    do: {:info, msg}

  defp flash_for_test_connection({:ok, _payload}),
    do: {:info, "Connection OK."}

  defp flash_for_test_connection({:error, :not_implemented}),
    do: {:error, "This plugin does not implement a connection test."}

  defp flash_for_test_connection({:error, :plugin_not_found}),
    do: {:error, "Plugin is not registered."}

  defp flash_for_test_connection({:error, %{message: msg}}) when is_binary(msg),
    do: {:error, msg}

  defp flash_for_test_connection({:error, msg}) when is_binary(msg),
    do: {:error, msg}

  defp flash_for_test_connection({:error, reason}),
    do: {:error, inspect(reason)}

  defp flash_for_test_connection(_other),
    do: {:error, "Connection test returned an unexpected result."}

  defp current_user_id(socket) do
    case socket.assigns[:api_token] do
      %{id: id} -> to_string(id)
      _ -> nil
    end
  end

  # After a successful save, refresh form_values so non-secret fields show
  # the freshly-stored values, and secret fields stay blank with the
  # `••••••` indicator now lit up.
  defp reload_with_stored(socket) do
    assign(socket,
      form_values: initial_form_values(socket.assigns.fields, socket.assigns.stored)
    )
  end
end
