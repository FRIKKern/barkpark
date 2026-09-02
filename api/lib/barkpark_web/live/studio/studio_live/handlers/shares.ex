defmodule BarkparkWeb.Studio.StudioLive.Handlers.Shares do
  @moduledoc """
  Network shares panel (scoped-sharing P6). Every mutate re-checks admin
  server-side. Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.Shared

  @not_workspace_admin_error "You are not an admin of that scope's workspace. " <>
                               "POST/DELETE /v1/shares refuses the same request."

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

  # ── HTTP-EDGE PARITY on the FOREIGN arm (task-14dce90fc23a4fdc) ───────────
  #
  # THE COMMENT ABOVE IS NOW HALF-STALE AND IS KEPT AS THE RECORD OF WHY.
  # "a token principal holds instance-wide declare authority by design there,
  # and clamping here would make the LiveView panel refuse what its own HTTP
  # twin performs" was TRUE when `/v1/shares` was gated by `:require_admin`
  # alone. arpss-w8 slice 2 (PR #12701) moved the HTTP edge underneath it:
  # `ShareController.create/2` and `delete/2` now run
  # `Tenancy.Auth.workspace_admin?/2` against the workspace the SCOPE NAMES,
  # in the order grammar -> resolve -> AUTHORIZE -> write, BEFORE
  # `Sharing.add_share/1` / `remove_share/3` touch the store. A token holding
  # the global `admin` permission but only a plain `member` row in workspace B
  # gets 403 there — that controller's moduledoc names the two holes it closed,
  # THE FORGE (a ws-A admin POSTs a ws-B `:edit` share) and THE DoS (the same
  # actor DELETEs ws-B's share, hard-revoking every live ws-B edit token).
  #
  # So `Shared.declarable_scope?/2`'s foreign arm — `instance_declare_authority?`,
  # i.e. the global `admin` PERMISSION and nothing else — is now WIDER than its
  # HTTP twin, and the panel performed exactly what `/v1/shares` refuses. This
  # narrows the foreign arm by the controller's own predicate, at the same point
  # in the same order. `declarable_scope?/2` stays the first gate, unedited: the
  # MOUNTED arm is untouched (there `Caps.admin?/1` has already proved an admin
  # SEAT in that workspace, for BOTH principal kinds, which is what
  # `workspace_admin?(actor, ws_id)` proves at the edge), and this only removes
  # the free pass on scopes naming a workspace the caller does not administer.
  #
  # DELIBERATELY `workspace_admin?/2`, NEVER `authorize/3` — the same ruling
  # `ShareController` records and `Handlers.ItemShare`'s revoke confinement in
  # this same panel already follows: `authorize/3`'s api_token arm ORs the
  # token's GLOBAL permissions[] with membership, so the attacker shape (a
  # global-admin token holding a plain `member` row in B) PASSES it. Swapping
  # this call for `authorize/3` turns the leak tests green on a leaking handler.
  #
  # ONE DIVERGENCE SURVIVES AND IS DECLARED, NOT HIDDEN — THE GHOST SHARE.
  # `create/2` answers 422 for a scope naming a workspace that does not exist,
  # so no foreign `:edit` share can be pre-planted for whoever registers that
  # slug later. This handler still ALLOWS it: an unresolvable workspace keeps
  # the answer `instance_declare_authority?` already gave. That is not a
  # judgement that the controller is wrong — it is that closing it here is a
  # BEHAVIOUR CHANGE beyond this row's proof obligation ("a workspace-A admin
  # ... against workspace B", a workspace that exists), and it reds two
  # `studio_live_shares_test.exs` cases that declare and revoke
  # `gyldendal/default/production` — a slug with no workspace row — as the
  # panel's own happy path. Filed rather than smuggled in.
  #
  # `delete/2` does NOT confine an unresolvable workspace either, deliberately:
  # it is the only cleanup path for ghost rows. So the REMOVE half is at exact
  # parity; only the ADD half carries the divergence.
  defp target_workspace_admits?(socket, ws_slug) do
    if mounted_workspace?(socket, ws_slug) do
      true
    else
      case {socket.assigns[:api_token], workspace_by_slug(ws_slug)} do
        {%ApiToken{} = token, %Tenancy.Workspace{id: ws_id}} ->
          TenancyAuth.workspace_admin?(token, ws_id)

        # No tenant to authorize against — see the ghost-share note above. Only
        # a principal that reached here through `instance_declare_authority?`
        # (an %ApiToken{} carrying global `admin`, the LiveView analogue of
        # `:require_admin`) is here at all.
        {%ApiToken{}, _unresolvable} ->
          true

        # Defensive default-deny. Unreachable today: `declarable_scope?/2` runs
        # first at both callsites and its foreign arm demands an %ApiToken{}.
        _no_token_principal ->
          false
      end
    end
  end

  defp workspace_by_slug(slug) when is_binary(slug), do: Tenancy.get_workspace_by_slug(slug)
  defp workspace_by_slug(_other), do: nil

  # The MOUNTED arm of `Shared.declarable_scope?/2`, asked on the workspace slug
  # alone. Spelled with the same `Shared.scope_slug/2` default so the two cannot
  # disagree about what "the workspace you are in" means.
  defp mounted_workspace?(socket, ws_slug) do
    Shared.scope_slug(socket.assigns[:current_workspace], "default") ==
      ws_slug |> to_string() |> String.trim()
  end

  # `create/2`'s ordering, verbatim: GRAMMAR first, then resolve+authorize. A
  # scope that does not parse names no tenant, so it falls through here exactly
  # as the controller falls through to `do_create/4` on `:invalid_scope` — and
  # `Sharing.add_share/1` keeps owning the "Invalid share" sentence.
  defp add_scope_admitted?(socket, scope) do
    case Barkpark.Sharing.scope_triple(scope) do
      {:ok, {ws, _proj, _dataset}} -> target_workspace_admits?(socket, ws)
      _malformed -> true
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

        not declarable_scope?(socket, scope) ->
          {:noreply,
           assign(socket,
             shares_error:
               "That scope belongs to another workspace. You can only share the workspace you are in."
           )}

        # THE HTTP-EDGE MIRROR. Reached only on the foreign arm, which
        # `declarable_scope?/2` just admitted on the global `admin` permission
        # alone. `create/2` additionally demands an admin MEMBERSHIP in the
        # scope's workspace. (Its 422 for a workspace that does not exist is
        # the one divergence left standing — see `target_workspace_admits?/2`.)
        not add_scope_admitted?(socket, scope) ->
          {:noreply, assign(socket, shares_error: @not_workspace_admin_error)}

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

  # The cascade clause both info receipts carry. `remove_share/3` revokes every
  # live item link under the scope on EVERY call, so this is a statement of what
  # just happened, not a hedge.
  @item_links_revoked "Every item /s/ link under it was revoked too."

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

  BOTH INFO BRANCHES ALSO NAME THE ITEM-LINK CASCADE (arpss-w8, RULED CASCADE).
  `remove_share/3` revokes every live `/s/<token>` item link under the scope
  UNCONDITIONALLY — including on the `count == 0` branch, which is exactly the
  path that reads like a no-op. Saying it in the receipt is the whole point: the
  operator could not otherwise tell whether the links they had handed out are
  dead, and before the cascade landed they were not.
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
          cond do
            not declarable_scope?(socket, ws) ->
              {:noreply,
               assign(socket,
                 shares_error:
                   "That scope belongs to another workspace. You can only manage the workspace you are in."
               )}

            # THE HTTP-EDGE MIRROR, availability half. `delete/2` demands an
            # admin MEMBERSHIP in the scope's workspace before `remove_share/3`
            # runs — the verb is destructive beyond the row (it also stamps
            # `revoked_at` on every live edit token under the scope), which is
            # the cross-tenant DoS #12701 closed at the HTTP door only.
            # An unresolvable workspace stays allowed: that is the ghost-row
            # cleanup path `delete/2` deliberately leaves open.
            not target_workspace_admits?(socket, ws) ->
              {:noreply, assign(socket, shares_error: @not_workspace_admin_error)}

            true ->
              {:ok, count} = Barkpark.Sharing.remove_share(ws, proj, dataset)

              socket =
                socket
                |> assign(shares_rows: Shared.load_share_rows(socket), shares_error: nil)
                |> put_share_removal_flash(ws, proj, dataset, count)

              {:noreply, socket}
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
        put_flash(
          socket,
          :info,
          "#{scope} was not shared — nothing to remove. " <> @item_links_revoked
        )

      true ->
        put_flash(
          socket,
          :info,
          "Stopped sharing #{scope} — it is no longer shared. " <> @item_links_revoked
        )
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
