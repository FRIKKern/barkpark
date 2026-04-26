defmodule BarkparkWeb.Studio.SettingsLive do
  @moduledoc """
  Generic encrypted-JSON editor for plugin settings.

  Phase 1 has no plugin enumeration — admin types a `plugin_name`,
  loads the (masked) JSON, edits it, saves it back. A reveal-on-click
  control re-fetches the unmasked value and records a `reveal` audit row.
  """

  use BarkparkWeb, :live_view

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
            placeholder="e.g. onixedit"
            autocomplete="off"
            required
          />
        </label>
        <button type="submit">Load</button>
      </form>

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

      <%= if @error do %>
        <p role="alert" style="color:#a00;">{@error}</p>
      <% end %>

      <p style="margin-top:1rem; color:#888; font-size:.9em;">
        Status: {if @loaded?, do: "loaded", else: "empty"} · {if @masked, do: "masked", else: "revealed"}
      </p>
    </div>
    """
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
