defmodule BarkparkWeb.Studio.StudioLive.Handlers.Shares do
  @moduledoc """
  Network shares panel (scoped-sharing P6). Every mutate re-checks admin
  server-side. Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.Shared

  def shares_open(params, socket) do
    if Caps.admin?(socket) do
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
    if Caps.admin?(socket) do
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

  @doc """
  Stop sharing a scope — and report what the STORE now says, not what the
  request asked for.

  `Barkpark.Sharing.remove_share/3` deletes STORED rows only: a scope also
  declared in the `BARKPARK_SHARES` env baseline stays live afterwards, and a
  scope that was never stored deletes nothing. Both used to receive the same
  "Stopped sharing …" sentence, built entirely from the request-parsed slugs —
  a receipt that could tell an operator a dataset was private while it was
  still publicly readable.

  So the receipt is a POST-READ: `remove_share/3` already calls `refresh/0`, so
  `shared?/4` immediately after is the live truth. The post-read decides
  whether the scope is shared; the delete count only decides whether anything
  was actually removed. Surfacing the count ALONE would not have been enough —
  even at `count == 1` an env-baseline share can survive the delete.
  """
  def shares_remove(%{"scope" => scope}, socket) do
    if Caps.admin?(socket) do
      case Barkpark.Sharing.scope_triple(scope) do
        {:ok, {ws, proj, dataset}} ->
          {:ok, count} = Barkpark.Sharing.remove_share(ws, proj, dataset)

          socket =
            socket
            |> assign(shares_rows: Shared.load_share_rows(), shares_error: nil)
            |> put_share_removal_flash(ws, proj, dataset, count)

          {:noreply, socket}

        {:error, _} ->
          {:noreply, assign(socket, shares_error: "Could not parse that scope.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required to manage shares.")}
    end
  end

  # The post-read. Asked AFTER remove_share/3's refresh/0, so it reads the live
  # merged list (env baseline ++ stored rows) — the same list `shared?/4` serves
  # to RequireShareScope on every public read.
  defp put_share_removal_flash(socket, ws, proj, dataset, count) do
    scope = "#{ws}/#{proj}/#{dataset}"

    cond do
      still_shared?(ws, proj, dataset) ->
        put_flash(
          socket,
          :error,
          "#{scope} is STILL shared — the stored share is gone, but this scope is also " <>
            "declared in the BARKPARK_SHARES environment baseline, which the Studio cannot " <>
            "remove. Change BARKPARK_SHARES and restart to make it private."
        )

      count == 0 ->
        put_flash(socket, :info, "#{scope} was not shared — nothing to remove.")

      true ->
        put_flash(socket, :info, "Stopped sharing #{scope} — it is no longer shared.")
    end
  end

  # Shared on ANY surface counts as shared: the scope is only private when no
  # surface is exposed.
  defp still_shared?(ws, proj, dataset) do
    Enum.any?(Barkpark.Sharing.surfaces(), &Barkpark.Sharing.shared?(ws, proj, dataset, &1))
  end
end
