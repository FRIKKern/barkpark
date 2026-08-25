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
         shares_rows: Shared.load_share_rows(socket),
         shares_scope_prefill: Shared.shares_scope_prefill(socket),
         shares_prefill_surfaces: surfaces
       )}
    else
      {:noreply, put_flash(socket, :error, "Admin access required to manage shares.")}
    end
  end

  # ── scope tenancy (arpss-w10-bl-shares-add-instance-wide-scope-hole) ──────
  #
  # `Caps.admin?/1` proves admin of the MOUNTED workspace. The submitted scope
  # names a workspace of its own, and `Sharing.parse_scope/1` accepts ANY slug
  # (it rejects only empty segments and glob metacharacters), so without this
  # clause an account admin of workspace A could declare a public read share
  # over workspace B.
  #
  # The token arm needs no clamp and MUST NOT get one: `Caps.admin?/1`'s token
  # arm already requires `token_admin?/1` — the same `admin` permission that
  # `/v1/shares`'s `:require_admin` pipeline requires — so a token principal
  # holds instance-wide declare authority by design there, and clamping here
  # would make the LiveView panel refuse what its own HTTP twin performs. The
  # hole is the ACCOUNT arm, which `/v1/shares` refuses outright.
  #
  # Injection is NOT the mechanism and needs no guard: a `:` in the scope makes
  # `parse_entry/1` see 4+ segments and fall to its catch-all, and a `;` makes
  # `parse/1` return two shares where `add_share/1` matches only `[%Share{}]`.
  # Both already fail closed with `{:error, :invalid}`.
  # Moved to `Shared.declarable_scope?/2` (`@canonical
  # capability:share-scope-tenancy`) so the panel's READ half enforces the same
  # rule as these two write halves. It lived here as a private while
  # `load_share_rows/0` had no clamp at all — the split that let the disclosure
  # direction stay open after the availability direction was closed
  # (task-c91e5e19da811fe5).
  defp declarable_scope?(socket, scope), do: Shared.declarable_scope?(socket, scope)

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

        not declarable_scope?(socket, scope) ->
          {:noreply,
           assign(socket,
             shares_error:
               "That scope belongs to another workspace. You can only share the workspace you are in."
           )}

        true ->
          case Barkpark.Sharing.add_share("#{scope}:#{surfaces}:read") do
            {:ok, _share} ->
              {:noreply,
               socket
               |> assign(shares_rows: Shared.load_share_rows(socket), shares_error: nil)
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
          # Same tenancy clamp as shares_add/2: `Caps.admin?/1` proves admin of
          # the MOUNTED workspace, and the scope names a workspace of its own.
          # Unclamped, an account admin of workspace A could REVOKE workspace
          # B's share — the availability mirror of the disclosure hole.
          # `declarable_scope?/2` splits on "/", so a bare slug passes through
          # as its own first segment.
          if declarable_scope?(socket, ws) do
            {:ok, count} = Barkpark.Sharing.remove_share(ws, proj, dataset)

            socket =
              socket
              |> assign(shares_rows: Shared.load_share_rows(socket), shares_error: nil)
              |> put_share_removal_flash(ws, proj, dataset, count)

            {:noreply, socket}
          else
            {:noreply,
             assign(socket,
               shares_error:
                 "That scope belongs to another workspace. You can only manage the workspace you are in."
             )}
          end

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
          "#{scope} is STILL shared — " <> still_shared_reason(ws, proj, dataset)
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

  # THE REASON IS DERIVED, NOT ASSERTED. The env baseline is the only other
  # source of a live share today (`shares/0` is `shares_env() ++ list_stored()`
  # and the stored upsert is keyed on the triple, so a second stored row cannot
  # exist), but "today" is not a proof — so the baseline is only NAMED when
  # `shares_env/0` actually carries this triple. A receipt that blames a cause
  # it did not check is the same defect this handler was repaired for.
  defp still_shared_reason(ws, proj, dataset) do
    if in_env_baseline?(ws, proj, dataset) do
      "the stored share is gone, but this scope is also declared in the BARKPARK_SHARES " <>
        "environment baseline, which the Studio cannot remove. Change BARKPARK_SHARES and " <>
        "restart to make it private."
    else
      "the stored share is gone and it is NOT in the BARKPARK_SHARES baseline, so something " <>
        "else is still exposing it. The Studio cannot name the source — check the share " <>
        "configuration before treating this scope as private."
    end
  end

  defp in_env_baseline?(ws, proj, dataset) do
    Enum.any?(Barkpark.Sharing.shares_env(), fn s ->
      s.workspace_slug == ws and s.project_slug == proj and s.dataset == dataset
    end)
  end
end
