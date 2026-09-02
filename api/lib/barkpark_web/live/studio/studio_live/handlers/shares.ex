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
  # RETRACTED — DO NOT ACT ON THE NEXT PARAGRAPH. It is quoted, not asserted;
  # it was already false the day it was written and it kept the token arm open
  # for three more days. The retraction and its receipts are the block below
  # `declarable_scope?/2`; read that before touching either write half.
  #
  #   > The token arm needs no clamp and MUST NOT get one: `Caps.admin?/1`'s
  #   > token arm already requires `token_admin?/1` — the same `admin`
  #   > permission that `/v1/shares`'s `:require_admin` pipeline requires — so
  #   > a token principal holds instance-wide declare authority by design
  #   > there, and clamping here would make the LiveView panel refuse what its
  #   > own HTTP twin performs. The hole is the ACCOUNT arm, which
  #   > `/v1/shares` refuses outright.
  #
  # The account arm WAS a hole. It was not the only one.
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
  # THE COMMENT ABOVE IS RETRACTED AND IS KEPT ONLY AS THE RECORD OF WHY.
  #
  # THE DATES ARE THE WHOLE ARGUMENT. It never described a world that then
  # changed; the world had ALREADY changed when it was written:
  #
  #   2026-08-19  cef6ee8465  #12701  POST/DELETE /v1/shares confined to
  #                                   workspace_admin? of the SCOPE's workspace
  #   2026-08-19  2f2f7dffcb  #12695  caps.ex, verbatim: "arpss-w10 / D22
  #                                   OVERTURNS the former 'the token arm is
  #                                   deliberately membership-FREE'"
  #   2026-08-21  bb3b203f58  #12929  this clamp landed WITH the exemption —
  #                                   TWO DAYS AFTER both commits above
  #
  # So both halves of the retracted claim were false on arrival:
  #
  #   * "holds instance-wide declare authority by design there" — cef6ee8465
  #     had already taken that authority away at the HTTP edge. A global-`admin`
  #     token with a plain `member` row in workspace B gets 403 from
  #     `create/2`/`delete/2`.
  #   * "clamping here would make the LiveView panel refuse what its own HTTP
  #     twin performs" — the inequality ran the OTHER way. The panel PERFORMED
  #     what the twin REFUSES, and 2f2f7dffcb had already overturned the
  #     membership-free reading of the token arm that the sentence leaned on.
  #     (2f2f7dffcb's seat is read on the MOUNTED workspace, never on the
  #     SUBMITTED scope's — which is the gap, not its closure.)
  #
  # "a token principal holds instance-wide declare authority by design there,
  # and clamping here would make the LiveView panel refuse what its own HTTP
  # twin performs" was TRUE only while `/v1/shares` was gated by
  # `:require_admin` alone. cef6ee8465 (arpss-w8 slice 2, PR #12701) moved the
  # HTTP edge underneath it: `ShareController.create/2` and `delete/2` now run
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
  # THE GHOST SHARE IS FAIL-CLOSED (lead-security ruling, 2026-09-02).
  #
  # An earlier revision of this comment declared an ALLOW here as a "divergence
  # that survives": an unresolvable workspace kept the answer
  # `instance_declare_authority?` already gave, on the argument that closing it
  # exceeded the filing row's obligation. THAT ALLOW IS RETRACTED. The ruling:
  #
  #   A ghost share is an AUTHORISATION ATTACHED TO A NAME. Whoever later
  #   creates that slug inherits a public exposure they never made — the
  #   registry says the scope is shared before its owner exists to object.
  #   The legitimate pre-provisioning path is the OPERATOR ENV REGISTRY
  #   (`BARKPARK_SHARES` / `Sharing.shares_env/0`), which is not this handler.
  #
  # So an unresolvable slug is now a REFUSAL, and it is deliberately THE SAME
  # refusal a foreign workspace gets: `@not_workspace_admin_error`, from the
  # same `false`. NO EXISTENCE ORACLE — a caller cannot distinguish "workspace
  # B exists and you do not administer it" from "workspace B does not exist",
  # so this surface cannot be walked to enumerate which slugs are taken. That
  # is why the two cases collapse into one `false` arm below rather than into
  # two arms that happen to return the same value.
  #
  # NOT folded in: a scope that fails the GRAMMAR (wildcard, empty segment,
  # too many segments). `Sharing.add_share/1` keeps owning the "Invalid share"
  # sentence, exactly as `create/2` answers 422 `:invalid_scope` rather than
  # 403 there. A grammar refusal reveals nothing about which workspaces exist,
  # so it is not an existence oracle and does not need to be laundered through
  # the authorization message.
  #
  # THE COST, STATED: the panel is no longer a cleanup path for pre-existing
  # ghost rows. `ShareController.delete/2` still declines to confine an
  # unresolvable workspace precisely so that path stays open, and the env
  # registry is unaffected. The REMOVE half here is confined WITH the add half
  # — the ruling names declare AND remove — so the two are at parity again,
  # both refusing.
  defp target_workspace_admits?(socket, ws_slug) do
    if mounted_workspace?(socket, ws_slug) do
      true
    else
      case {socket.assigns[:api_token], workspace_by_slug(ws_slug)} do
        {%ApiToken{} = token, %Tenancy.Workspace{id: ws_id}} ->
          TenancyAuth.workspace_admin?(token, ws_id)

        # EVERYTHING ELSE IS ONE REFUSAL, ON PURPOSE — see the ghost-share note
        # above. This single arm covers BOTH an unresolvable workspace (the
        # ghost, fail-closed per the 2026-09-02 ruling) AND the defensive
        # no-token-principal default-deny. Keeping them as one clause is the
        # enforcement of "no existence oracle": there is no branch that could
        # drift into answering the two cases differently.
        _unresolvable_or_no_token_principal ->
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
        # scope's workspace. A workspace that does not exist is refused HERE
        # too, with this same sentence — the fail-closed ghost rule and its
        # no-existence-oracle requirement live in `target_workspace_admits?/2`.
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
            # An unresolvable workspace is REFUSED here as well (2026-09-02
            # ruling): the remove half is confined with the add half, and the
            # ghost-row cleanup path is `delete/2`, not this panel.
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
