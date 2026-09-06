defmodule BarkparkWeb.Studio.StudioLive.Handlers.Airdrop do
  @moduledoc """
  The **Share-access sheet** (airdrop-grants capstone) — the grantor-facing
  Studio flow to MINT + DELIVER a scoped, time-boxed, account-bound grant link.

  Reachable from two surfaces (a workspace surface + a post-type surface); the
  post-type surface narrows the grant scope with `type`. The sheet mints via
  `Barkpark.Access.mint/2` IN-PROCESS (no HTTP route) — the same no-escalation
  context the `bp` CLI and API use.

  ## Gating — held-capability, NOT admin-only

  The capability picker surfaces ONLY the capabilities the grantor itself holds
  in the workspace (`Tenancy.Auth.authorize/3` per action). A non-admin member
  can therefore share what it legitimately holds. This is a UX filter — the
  security boundary is `mint/2`'s no-escalation gate, which RE-CHECKS every
  requested capability against the grantor server-side and returns
  `{:error, :forbidden}` on any it does not hold (proven in
  `Barkpark.AccessTest`). The picker never OFFERS an unheld cap, and even a
  forged submit is refused by mint.

  ## Token hygiene

  The raw token exists only at mint. It is surfaced ONCE in the sheet (the
  `/grant/<token>` claim URL, copy-to-clipboard) + emailed to the grantee, then
  DROPPED from assigns on close. The persisted `link_token_hash` is never read
  back or rendered.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Access
  alias Barkpark.Accounts

  # Duration chip → seconds. "custom" reveals a datetime input instead.
  @durations %{"30m" => 1_800, "5h" => 18_000, "1d" => 86_400}

  # UI capability vocabulary — View=read, Edit=write. `admin` is deliberately
  # NOT surfaced (a grant should confer working access, not tenant control); the
  # picker is further narrowed to what the grantor actually holds.
  @surfaced_caps ~w(read write)

  @doc """
  Open the sheet. `params["type"]` (present on the post-type surface) narrows
  the grant scope; absent → a workspace-scoped grant. The capability picker is
  computed from what the grantor holds RIGHT NOW.
  """
  def airdrop_open(params, socket) do
    principal = principal(socket)
    ws = socket.assigns[:current_workspace]

    cond do
      is_nil(principal) ->
        {:noreply, put_flash(socket, :error, "Sign in to share access.")}

      is_nil(ws) ->
        {:noreply, put_flash(socket, :error, "No workspace in context.")}

      true ->
        type =
          case params["type"] do
            t when is_binary(t) and t != "" -> t
            _ -> nil
          end

        {:noreply,
         assign(socket,
           airdrop_open: true,
           airdrop_type: type,
           airdrop_caps: held_capabilities(principal, ws.id),
           airdrop_error: nil,
           airdrop_link: nil,
           airdrop_suggestions: []
         )}
    end
  end

  @doc "Close the sheet and DROP the raw link from assigns (never persisted)."
  def airdrop_close(socket) do
    {:noreply,
     assign(socket,
       airdrop_open: false,
       airdrop_error: nil,
       airdrop_link: nil,
       airdrop_suggestions: []
     )}
  end

  @doc """
  Recipient-email TYPEAHEAD (pure UX). On each change of the recipient field,
  suggest up to a handful of CURRENT-workspace member emails matching the typed
  prefix — surfaced to a native `<datalist>`. The field stays FREE-TEXT (airdrop
  deliberately supports emailing a stranger with no account yet); this is
  advisory only, and `mint/2` still validates the recipient server-side. Fails
  closed to `[]` with no workspace in context.
  """
  def airdrop_suggest(params, socket) do
    ws = socket.assigns[:current_workspace]
    prefix = params["grantee_email"] || ""

    suggestions =
      if is_nil(ws),
        do: [],
        else: Accounts.search_by_email_prefix(prefix, ws.id)

    {:noreply, assign(socket, airdrop_suggestions: suggestions)}
  end

  @doc """
  Mint the grant, deliver it (email + best-effort live toast), and surface the
  claim link once. Every failure path is inline (no crash): a bad duration /
  empty capability / missing email is a form error; a no-escalation refusal is
  `{:error, :forbidden}` → an inline "you can only share what you hold".
  """
  def airdrop_create(params, socket) do
    principal = principal(socket)
    ws = socket.assigns[:current_workspace]

    cond do
      is_nil(principal) or is_nil(ws) ->
        {:noreply, assign(socket, airdrop_error: "No workspace / principal in context.")}

      true ->
        with {:ok, email} <- pick_email(params),
             {:ok, caps} <- pick_caps(params),
             {:ok, expires_at} <- pick_expiry(params) do
          attrs = build_attrs(socket, email, caps, expires_at, params)

          case Access.mint(principal, attrs) do
            {:ok, %{token: raw, grant: grant}} ->
              deliver(grant, raw)

              {:noreply,
               assign(socket,
                 airdrop_link: link_url(raw),
                 airdrop_error: nil,
                 # Refresh the picker (held caps are stable, but keeps assigns coherent)
                 airdrop_caps: held_capabilities(principal, ws.id)
               )}

            {:error, :not_a_member} ->
              {:noreply, assign(socket, airdrop_error: "You are not a member of that workspace.")}

            {:error, :forbidden} ->
              {:noreply, assign(socket, airdrop_error: "You can only share access you hold.")}

            {:error, _changeset} ->
              {:noreply,
               assign(socket,
                 airdrop_error: "Could not mint the grant — check the recipient email."
               )}
          end
        else
          {:error, msg} -> {:noreply, assign(socket, airdrop_error: msg)}
        end
    end
  end

  # ── principal + capability gating ──────────────────────────────────────────

  # The grantor is whichever authenticated principal the Studio mount carries:
  # an account User (studio-user-login) or an admin ApiToken. Both are valid
  # `Access.mint/2` principals.
  defp principal(socket) do
    socket.assigns[:current_user] || socket.assigns[:api_token]
  end

  # Keep only the surfaced caps (read/write) the grantor is authorized for in
  # this workspace — the picker never offers an unheld capability. mint/2
  # re-checks, so this is UX, not the security boundary.
  defp held_capabilities(principal, ws_id) do
    Enum.filter(@surfaced_caps, fn cap ->
      Barkpark.Tenancy.Auth.authorize(principal, ws_id, cap_to_action(cap)) == :ok
    end)
  end

  defp cap_to_action("read"), do: :read
  defp cap_to_action("write"), do: :write

  # ── form parsing ────────────────────────────────────────────────────────────

  defp pick_email(params) do
    case params["grantee_email"] do
      e when is_binary(e) ->
        e = String.trim(e)

        if e =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
          do: {:ok, e},
          else: {:error, "Enter a valid recipient email."}

      _ ->
        {:error, "Enter a recipient email."}
    end
  end

  defp pick_caps(%{"capabilities" => caps}) when is_list(caps) do
    caps = Enum.filter(caps, &(&1 in @surfaced_caps))
    if caps == [], do: {:error, "Choose at least one capability."}, else: {:ok, caps}
  end

  defp pick_caps(_), do: {:error, "Choose at least one capability."}

  defp pick_expiry(%{"duration" => "custom"} = params) do
    case params["expires_at"] do
      dt when is_binary(dt) and dt != "" -> parse_local(dt)
      _ -> {:error, "Enter a custom expiry date/time."}
    end
  end

  defp pick_expiry(%{"duration" => d}) when is_map_key(@durations, d) do
    {:ok, DateTime.add(DateTime.utc_now(), @durations[d], :second)}
  end

  defp pick_expiry(_), do: {:error, "Choose how long the link lasts."}

  # datetime-local yields "YYYY-MM-DDTHH:MM" (no seconds/zone). Treat as UTC.
  defp parse_local(dt) do
    dt = if Regex.match?(~r/T\d{2}:\d{2}$/, dt), do: dt <> ":00", else: dt

    case NaiveDateTime.from_iso8601(dt) do
      {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
      _ -> {:error, "Enter a valid custom expiry date/time."}
    end
  end

  defp build_attrs(socket, email, caps, expires_at, params) do
    ws = socket.assigns.current_workspace
    proj = socket.assigns[:current_project]

    %{
      workspace_id: ws.id,
      project_id: proj && proj.id,
      dataset: socket.assigns[:dataset] || "production",
      type: socket.assigns[:airdrop_type],
      grantee_email: email,
      capabilities: caps,
      expires_at: expires_at,
      single_use: params["single_use"] in ["true", "on"]
    }
  end

  # ── link + delivery ─────────────────────────────────────────────────────────

  # The #1339 claim route is GET /grant/:token. Base host via the same helper
  # item-share links use (operator override → public base → LAN).
  defp link_url(raw) do
    case Barkpark.Sharing.share_link_base() do
      base when is_binary(base) and base != "" -> "#{base}/grant/#{raw}"
      _ -> "/grant/#{raw}"
    end
  end

  # Email is load-bearing delivery; the live toast is a best-effort online-only
  # enhancement. The toast payload is MINIMAL — no scope/capabilities/token — so
  # the grantee's authenticated LV fetches the details itself.
  defp deliver(grant, raw) do
    Barkpark.Access.GrantNotifier.deliver_grant(grant.grantee_email, link_url(raw))

    case Barkpark.Accounts.get_user_by_email(grant.grantee_email) do
      %{id: uid} ->
        Phoenix.PubSub.broadcast(Barkpark.PubSub, "user:#{uid}", {:airdrop_granted})

      _ ->
        :ok
    end
  end
end
