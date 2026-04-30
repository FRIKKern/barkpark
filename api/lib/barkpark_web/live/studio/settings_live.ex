defmodule BarkparkWeb.Studio.SettingsLive do
  @moduledoc """
  Generic encrypted-JSON editor for plugin settings.

  Phase 1 has no plugin enumeration — admin types a `plugin_name`,
  loads the (masked) JSON, edits it, saves it back. A reveal-on-click
  control re-fetches the unmasked value and records a `reveal` audit row.

  Phase 7 / WI2: when `plugin_name == "bokbasen"`, the form switches to a
  typed view with 5 named inputs and password-typed secret fields backed
  by `Barkpark.Plugins.OnixEdit.Bokbasen.Settings`. The generic
  raw-JSON path is kept for every other plugin.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Plugins.Settings
  alias Barkpark.Plugins.Settings.Masking
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Settings, as: BokbasenSettings

  @bokbasen "bokbasen"
  @bokbasen_secret_keys ~w(client_id client_secret)
  @bokbasen_keys ~w(api_base oauth_token_url client_id client_secret client_role)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Plugin Settings",
       plugin_name: "",
       settings_json: "",
       bokbasen_form: empty_bokbasen_form(),
       bokbasen_revealed: %{"client_id" => false, "client_secret" => false},
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
    if name == @bokbasen do
      load_bokbasen(socket, name)
    else
      load_generic(socket, name)
    end
  end

  def handle_event("reveal", %{"plugin_name" => name}, socket) do
    case Settings.reveal(name, user_id: user_id(socket)) do
      {:ok, map} ->
        {:noreply,
         socket
         |> assign(
           settings_json: pretty(map),
           masked: false,
           loaded?: true,
           error: nil
         )
         |> put_flash(:info, "Revealed (audited).")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No settings to reveal.")}
    end
  end

  def handle_event("reveal_field", %{"field" => field}, socket)
      when field in @bokbasen_secret_keys do
    case Settings.reveal(@bokbasen, user_id: user_id(socket)) do
      {:ok, map} ->
        form =
          socket.assigns.bokbasen_form
          |> Map.put(field, Map.get(map, field, ""))

        revealed = Map.put(socket.assigns.bokbasen_revealed, field, true)

        {:noreply,
         socket
         |> assign(
           bokbasen_form: form,
           bokbasen_revealed: revealed,
           masked: not all_revealed?(revealed),
           error: nil
         )
         |> put_flash(:info, "Revealed #{field} (audited).")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No settings to reveal.")}
    end
  end

  def handle_event("save", %{"plugin_name" => @bokbasen} = params, socket) do
    form = bokbasen_params_to_form(params)

    case BokbasenSettings.put_credentials(form, user_id: user_id(socket)) do
      {:ok, _record} ->
        masked = mask_bokbasen(form)

        {:noreply,
         socket
         |> assign(
           plugin_name: @bokbasen,
           bokbasen_form: masked,
           bokbasen_revealed: %{"client_id" => false, "client_secret" => false},
           masked: true,
           loaded?: true,
           error: nil
         )
         |> put_flash(:info, "Saved Bokbasen credentials.")}

      {:error, {:invalid, missing}} ->
        {:noreply,
         socket
         |> assign(bokbasen_form: form, error: format_invalid(missing))}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, bokbasen_form: form, error: format_changeset(cs))}
    end
  end

  def handle_event("save", %{"plugin_name" => name, "settings_json" => json}, socket) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        case Settings.put(name, map, user_id: user_id(socket)) do
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

  def handle_event("delete", %{"plugin_name" => name}, socket) do
    case Settings.delete(name, user_id: user_id(socket)) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           plugin_name: name,
           settings_json: "",
           bokbasen_form: empty_bokbasen_form(),
           bokbasen_revealed: %{"client_id" => false, "client_secret" => false},
           masked: true,
           loaded?: false,
           error: nil
         )
         |> put_flash(:info, "Deleted #{name}.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Nothing to delete.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="settings-live" style="max-width: 720px; margin: 2rem auto; font-family: ui-sans-serif, system-ui;">
      <h1>Plugin Settings</h1>

      <p style="color: #555;">
        Encrypted JSON store. Values are masked on load — click <em>Reveal</em>
        to fetch unmasked (audited).
      </p>

      <%= if msg = Phoenix.Flash.get(@flash, :info) do %>
        <div role="status" style="background:#e7f7ec; padding:.5rem; margin:.5rem 0;">{msg}</div>
      <% end %>
      <%= if msg = Phoenix.Flash.get(@flash, :error) do %>
        <div role="alert" style="background:#fdecea; padding:.5rem; margin:.5rem 0;">{msg}</div>
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

      <%= if @plugin_name == "bokbasen" do %>
        {render_bokbasen_form(assigns)}
      <% else %>
        {render_generic_form(assigns)}
      <% end %>

      <%= if @error do %>
        <p role="alert" style="color:#a00;">{@error}</p>
      <% end %>

      <p style="margin-top:1rem; color:#888; font-size:.9em;">
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

  defp render_bokbasen_form(assigns) do
    ~H"""
    <form phx-submit="save" data-preset="bokbasen">
      <input type="hidden" name="plugin_name" value="bokbasen" />

      <fieldset style="border:1px solid #ddd; padding:.75rem; margin-bottom:.5rem;">
        <legend>Bokbasen credentials</legend>

        <p>
          <label>
            API base URL
            <input
              type="url"
              name="api_base"
              value={Map.get(@bokbasen_form, "api_base", "")}
              placeholder="https://api.bokbasen.io"
              style="width:100%;"
              required
            />
          </label>
        </p>

        <p>
          <label>
            OAuth2 token URL
            <input
              type="url"
              name="oauth_token_url"
              value={Map.get(@bokbasen_form, "oauth_token_url", "")}
              placeholder="https://login.bokbasen.io/oauth2/token"
              style="width:100%;"
              required
            />
          </label>
        </p>

        <p>
          <label>
            Client ID
            <input
              type={input_type_for("client_id", @bokbasen_revealed)}
              name="client_id"
              value={Map.get(@bokbasen_form, "client_id", "")}
              autocomplete="off"
              style="width:100%;"
              required
            />
          </label>
          <button
            type="button"
            phx-click="reveal_field"
            phx-value-field="client_id"
            disabled={not @loaded?}
          >
            Reveal
          </button>
        </p>

        <p>
          <label>
            Client secret
            <input
              type={input_type_for("client_secret", @bokbasen_revealed)}
              name="client_secret"
              value={Map.get(@bokbasen_form, "client_secret", "")}
              autocomplete="off"
              style="width:100%;"
              required
            />
          </label>
          <button
            type="button"
            phx-click="reveal_field"
            phx-value-field="client_secret"
            disabled={not @loaded?}
          >
            Reveal
          </button>
        </p>

        <p>
          <label>
            Client role
            <select name="client_role" style="width:100%;">
              <option
                value="publisher"
                selected={Map.get(@bokbasen_form, "client_role", "publisher") == "publisher"}
              >
                publisher (default)
              </option>
              <option
                value="distributor"
                selected={Map.get(@bokbasen_form, "client_role", "publisher") == "distributor"}
              >
                distributor
              </option>
            </select>
          </label>
        </p>
      </fieldset>

      <div style="display:flex; gap:.5rem; margin-top:.5rem;">
        <button type="submit">Save</button>
        <button
          type="button"
          phx-click="delete"
          phx-value-plugin_name="bokbasen"
          data-confirm="Delete Bokbasen credentials?"
          disabled={not @loaded?}
        >
          Delete
        </button>
      </div>
    </form>
    """
  end

  defp load_bokbasen(socket, name) do
    case Settings.get(name, user_id: user_id(socket)) do
      {:ok, map} ->
        {:noreply,
         socket
         |> assign(
           plugin_name: name,
           bokbasen_form: mask_bokbasen(map),
           bokbasen_revealed: %{"client_id" => false, "client_secret" => false},
           masked: true,
           loaded?: true,
           error: nil
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(
           plugin_name: name,
           bokbasen_form: empty_bokbasen_form(),
           bokbasen_revealed: %{"client_id" => false, "client_secret" => false},
           masked: false,
           loaded?: false,
           error: nil
         )
         |> put_flash(:info, "No Bokbasen credentials yet — fill in and Save.")}
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
           settings_json: "{}",
           masked: false,
           loaded?: false,
           error: nil
         )
         |> put_flash(:info, "No settings yet for #{name} — start with {} and Save.")}
    end
  end

  defp bokbasen_params_to_form(params) do
    Map.new(@bokbasen_keys, fn key -> {key, Map.get(params, key, "") |> to_string()} end)
  end

  defp mask_bokbasen(map) do
    role = Map.get(map, "client_role") || Map.get(map, :client_role) || "publisher"

    %{
      "api_base" => to_string(Map.get(map, "api_base") || Map.get(map, :api_base) || ""),
      "oauth_token_url" =>
        to_string(Map.get(map, "oauth_token_url") || Map.get(map, :oauth_token_url) || ""),
      "client_id" =>
        Masking.mask(to_string(Map.get(map, "client_id") || Map.get(map, :client_id) || "")),
      "client_secret" =>
        Masking.mask(
          to_string(Map.get(map, "client_secret") || Map.get(map, :client_secret) || "")
        ),
      "client_role" => to_string(role)
    }
  end

  defp empty_bokbasen_form do
    %{
      "api_base" => "",
      "oauth_token_url" => "",
      "client_id" => "",
      "client_secret" => "",
      "client_role" => "publisher"
    }
  end

  defp input_type_for(field, revealed) do
    if Map.get(revealed, field, false), do: "text", else: "password"
  end

  defp all_revealed?(revealed) do
    Enum.all?(@bokbasen_secret_keys, &Map.get(revealed, &1, false))
  end

  defp format_invalid(missing) do
    "Missing or invalid: " <> Enum.map_join(missing, ", ", &Atom.to_string/1)
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
