defmodule BarkparkWeb.Studio.StudioLive.Handlers.Shares do
  @moduledoc """
  Network shares panel (scoped-sharing P6). Every mutate re-checks admin
  server-side. Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias BarkparkWeb.Studio.StudioLive.Shared

  def shares_open(params, socket) do
    if socket.assigns[:shares_admin?] do
      surfaces = List.wrap(params["surface"]) |> Enum.filter(&(&1 in ~w(papers docs media)))

      {:noreply,
       socket
       |> assign(
         show_shares: true,
         shares_error: nil,
         shares_rows: Shared.load_share_rows(),
         shares_scope_prefill: Shared.shares_scope_prefill(socket),
         shares_prefill_surfaces: surfaces
       )}
    else
      {:noreply, put_flash(socket, :error, "Admin access required to manage shares.")}
    end
  end

  def shares_close(socket) do
    {:noreply, assign(socket, show_shares: false, shares_error: nil)}
  end

  def shares_add(params, socket) do
    if socket.assigns[:shares_admin?] do
      scope = params["scope"] |> to_string() |> String.trim()
      surfaces = params["surfaces"] |> List.wrap() |> Enum.join(",")

      cond do
        scope == "" ->
          {:noreply, assign(socket, shares_error: "Scope is required.")}

        surfaces == "" ->
          {:noreply, assign(socket, shares_error: "Pick at least one surface.")}

        true ->
          case Barkpark.Sharing.add_share("#{scope}:#{surfaces}:read") do
            {:ok, _share} ->
              {:noreply,
               socket
               |> assign(shares_rows: Shared.load_share_rows(), shares_error: nil)
               |> put_flash(:info, "Shared #{scope}.")}

            {:error, _reason} ->
              {:noreply,
               assign(socket,
                 shares_error: "Invalid share — check the scope and surfaces."
               )}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required to manage shares.")}
    end
  end

  def shares_remove(%{"scope" => scope}, socket) do
    if socket.assigns[:shares_admin?] do
      case Barkpark.Sharing.scope_triple(scope) do
        {:ok, {ws, proj, dataset}} ->
          {:ok, _count} = Barkpark.Sharing.remove_share(ws, proj, dataset)

          {:noreply,
           socket
           |> assign(shares_rows: Shared.load_share_rows(), shares_error: nil)
           |> put_flash(:info, "Stopped sharing #{ws}/#{proj}/#{dataset}.")}

        {:error, _} ->
          {:noreply, assign(socket, shares_error: "Could not parse that scope.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required to manage shares.")}
    end
  end
end
