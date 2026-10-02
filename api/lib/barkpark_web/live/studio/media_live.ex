defmodule BarkparkWeb.Studio.MediaLive do
  @moduledoc """
  Studio Media tab — hosts the native `bp-asset-explorer` Web Component.

  Binary upload + `mediaAsset` document sync is handled client-side via
  `/media/upload` and the Media plugin upload hook. Metadata editing
  happens on `mediaAsset` documents in Structure → Media.

  ## The visibility affordance (task-cbb112a9b4c600cc)

  The library carries ONE banner and ONE action, both about the same door:

    * the banner states what an asset's `public` delivery visibility actually
      promises — readable WITHIN this scope's sharing, not world-readable —
      and reads the scope's live `:media` share state. The copy is
      `BarkparkWeb.MediaVisibilityCopy`'s, shared verbatim with `bp media get`
      so the two surfaces cannot drift.
    * `"publish_scope_media"` creates the scope's `:media` `:read` share
      through `Barkpark.Sharing.publish_media/1` — the stored-share path.

  THE REMEDY IS THE SHARE. `BarkparkWeb.Plugs.RequireShareScope` (RULED
  2026-09-06, task-8627e1a3f974693d) admits anonymous scoped-media reads ONLY
  on a `:media` share and never reads `bp_visibility`, so this LiveView must
  never offer to flip an asset's visibility as the fix — it would change a
  field no plug asks about and leave the 403 exactly where it was.

  The action re-checks admin server-side (`shares_admin?`, the same
  workspace-seat oracle the Shares panel uses) — the button's absence is not
  the gate.
  """

  use BarkparkWeb, :live_view

  require Logger

  alias Barkpark.Sharing
  alias BarkparkWeb.MediaVisibilityCopy

  @impl true
  def mount(%{"dataset" => dataset}, _session, socket) do
    # `current_path` is owned by BarkparkWeb.StudioChrome's :handle_params
    # hook (the ONE producer) — never hand-set here.
    {:ok,
     socket
     |> assign_new(:scope_prefix, fn -> "" end)
     |> assign(
       dataset: dataset,
       page_title: "Media Library"
     )
     |> assign_visibility_notice()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="flex: 1; display: flex; flex-direction: column; min-height: 0; overflow: hidden;">
      <div id="media-visibility-notice" style="padding: 0.75rem 1rem; font-size: 0.8125rem;">
        <strong>{@visibility_notice.label}</strong>
        <p style="margin: 0.25rem 0;">{@visibility_notice.copy}</p>
        <p style="margin: 0.25rem 0;">
          Scope {@visibility_notice.scope}: {@visibility_notice.media_share_state}
        </p>
        <button
          :if={!@visibility_notice.media_shared && @shares_admin?}
          type="button"
          phx-click="publish_scope_media"
        >
          Publish this scope's media
        </button>
      </div>
      <div
        id="media-explorer-host"
        phx-update="ignore"
        style="flex: 1; display: flex; min-height: 0; overflow: hidden;"
      >
        <bp-asset-explorer
          dataset={@dataset}
          scope-prefix={@scope_prefix}
          data-token={assigns[:api_token_raw] || ""}
        />
      </div>
    </div>
    """
  end

  # THE ONE STUDIO ACTION. It creates the `:media` `:read` share; it does not
  # write any asset document. Admin is re-checked here because a phx event can
  # arrive from a socket whose rendered button was never shown.
  @impl true
  def handle_event("publish_scope_media", _params, socket) do
    cond do
      not socket.assigns[:shares_admin?] ->
        {:noreply,
         put_flash(socket, :error, "Admin access required to publish this scope's media.")}

      is_nil(scope_string(socket)) ->
        {:noreply, put_flash(socket, :error, "No resolved scope to publish.")}

      true ->
        case Sharing.publish_media(scope_string(socket)) do
          {:ok, _share} ->
            {:noreply,
             socket
             |> assign_visibility_notice()
             |> put_flash(:info, "This scope's media is published — the :media share is live.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not publish this scope's media.")}
        end
    end
  end

  # Fall-through: a stale/forged phx event must not FunctionClauseError-crash
  # the session. Keep LAST among handle_event/3 clauses.
  @impl true
  def handle_event(event, _params, socket) do
    Logger.warning("studio/media: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # Fall-through: an unexpected message (e.g. a late PubSub delivery) must not
  # FunctionClauseError-crash the LiveView. Keep LAST among handle_info/2.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("studio/media: unhandled info #{inspect(msg)}")
    {:noreply, socket}
  end

  defp assign_visibility_notice(socket) do
    socket
    |> assign_new(:shares_admin?, fn -> false end)
    |> then(fn s ->
      assign(
        s,
        :visibility_notice,
        MediaVisibilityCopy.public_option(
          slug_of(s.assigns[:current_workspace]),
          slug_of(s.assigns[:current_project]),
          s.assigns[:dataset]
        )
      )
    end)
  end

  defp scope_string(socket) do
    with ws when is_binary(ws) <- slug_of(socket.assigns[:current_workspace]),
         proj when is_binary(proj) <- slug_of(socket.assigns[:current_project]),
         ds when is_binary(ds) <- socket.assigns[:dataset] do
      "#{ws}/#{proj}/#{ds}"
    else
      _ -> nil
    end
  end

  defp slug_of(%{slug: slug}) when is_binary(slug), do: slug
  defp slug_of(_other), do: nil
end
