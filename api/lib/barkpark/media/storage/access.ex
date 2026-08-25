defmodule Barkpark.Media.Storage.Access do
  @moduledoc """
  Per-asset delivery and edit permissions (WoodWing-style governance plane).
  """

  alias Barkpark.Accounts.User
  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.SignedUrl
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @type level :: :view | :preview | :original | :edit_metadata

  @doc "Visibility from asset content — `public`, `token`, or `private`."
  @spec visibility(Document.t() | nil) :: String.t()
  def visibility(nil), do: "public"

  def visibility(%Document{content: content}) when is_map(content) do
    Map.get(content, "bp_visibility") || "public"
  end

  def visibility(_), do: "public"

  @doc "Watermark profile from rights composite: `none`, `draft`, `editorial`."
  @spec watermark_profile(Document.t() | nil) :: String.t()
  def watermark_profile(nil), do: "none"

  def watermark_profile(%Document{content: content}) when is_map(content) do
    content
    |> Map.get("rights", %{})
    |> Map.get("watermarkProfile", "none")
    |> case do
      "" -> "none"
      v -> v
    end
  end

  def watermark_profile(_), do: "none"

  @doc "Whether the request may access media at the given level."
  @spec allowed?(Plug.Conn.t(), %MediaFile{}, Document.t() | nil, level()) :: boolean()
  def allowed?(conn, file, doc, level) do
    vis = visibility(doc)
    auth = authenticated?(conn)
    signed = signed_for?(conn, file)
    perms = permission_set(conn, doc)

    cond do
      level == :edit_metadata ->
        "edit_metadata" in perms

      level == :original ->
        "use_original" in perms and delivery_ok?(vis, auth, signed)

      level in [:view, :preview] ->
        "view" in perms and delivery_ok?(vis, auth, signed)

      true ->
        false
    end
  end

  @doc "WoodWing-style permission list for API responses."
  @spec permissions(Plug.Conn.t(), %MediaFile{}, Document.t() | nil) :: [String.t()]
  def permissions(conn, file, doc) do
    permission_set(conn, doc)
    |> Enum.filter(fn perm ->
      case perm do
        "edit_metadata" -> allowed?(conn, file, doc, :edit_metadata)
        "use_original" -> allowed?(conn, file, doc, :original)
        "view" -> allowed?(conn, file, doc, :view)
        "preview" -> allowed?(conn, file, doc, :preview)
        _ -> true
      end
    end)
  end

  defp permission_set(conn, doc) do
    auth = authenticated?(conn)
    admin = auth && admin?(conn)
    checked_out_by = checked_out_by(doc)
    actor = actor_label(conn)

    base =
      case visibility(doc) do
        "private" when not auth -> []
        _ -> ["view", "preview"]
      end

    base =
      if visibility(doc) in ["public", "token"] or auth do
        base ++ ["use_original"]
      else
        base
      end

    base =
      if auth and (admin or checked_out_by in [nil, ""] or checked_out_by == actor) do
        base ++ ["edit_metadata"]
      else
        base
      end

    if checked_out_by not in [nil, ""] and checked_out_by != actor and not admin do
      base -- ["edit_metadata", "use_original"]
    else
      base
    end
    |> Enum.uniq()
  end

  defp delivery_ok?("public", _auth, _signed), do: true
  defp delivery_ok?("token", auth, signed) when auth or signed, do: true
  defp delivery_ok?("token", _, _), do: false
  defp delivery_ok?("private", auth, _) when auth, do: true
  defp delivery_ok?("private", _, _), do: false
  defp delivery_ok?(_, auth, _) when auth, do: true
  defp delivery_ok?(_, _, _), do: false

  defp signed_for?(conn, %MediaFile{id: id}) do
    path = conn.request_path

    SignedUrl.verify?(id, path, SignedUrl.params_from_conn(conn))
  end

  # ONE PRINCIPAL MODEL, matching the write gate's (task-a32e13e37527d261).
  #
  # This used to be api_token PRESENCE alone. The media write gate
  # (`V1.MediaController.require_write/1` + `Plugs.RequireWritePermission`)
  # admits THREE principal kinds — a `share_writer`, an `%ApiToken{}`, and an
  # `%Accounts.User{}` authorised by its workspace membership role — while this
  # module recognised ONE. So the platform said yes and this layer, asking the
  # same question with a narrower principal model, said no: an account-session
  # workspace MEMBER could upload an asset and then collect a 403 PATCHing its
  # metadata, with an error message naming a token they never held. MEASURED at
  # 403 before this change (account_session_media_write_test.exs).
  #
  # A share-edit token needs no arm here: `Auth.create_share_token/5` inserts a
  # real `api_tokens` row, so `:api_token` IS assigned for it.
  #
  # WHY THE ACCOUNT ARM ASKS THE WORKSPACE QUESTION AND NOT MERELY "is a user
  # signed in" (LOAD-BEARING). `:current_user` is set by `OptionalSessionToken`,
  # which on `:shared_media_api` runs BEFORE `RequireShareScope`/
  # `ResolveWorkspace` — and `ResolveWorkspace` returns the conn UNTOUCHED when
  # `share_public` is true (resolve_workspace.ex), with two further non-member
  # admit arms (the Default-workspace public allowance and the grant path). So a
  # signed-in NON-MEMBER can reach this module carrying a `%User{}`. Treating
  # bare presence as authentication would hand that non-member `view` /
  # `use_original` on a `private` asset through a public share link — turning a
  # denial defect into a cross-tenant read. Routing through
  # `Tenancy.Auth.authorize(user, ws_id, :read)` keeps every non-member on
  # exactly today's answer and moves only the genuine member.
  #
  # `:read`, not `:write`, is the parity choice: for a token this predicate is
  # satisfied by ANY token, read-only included, and write authority is enforced
  # upstream by `require_write/1` — never here. Asking `:write` of a user would
  # make the account arm stricter than the token arm it exists to match.
  #
  # PUBLIC (task-f71cab067a90a89d): the Studio LiveView image-picker handler
  # (`StudioLive.Handlers.Media.open_image_picker/2`) needs the SAME principal
  # question to clamp its listing for an anonymous demo visitor, and must not
  # grow a second, narrower answer to it — a local re-derivation is exactly the
  # "one rule, several private copies" defect class this module's own history
  # (the comment above) already warns about. Works unmodified on a
  # `Phoenix.LiveView.Socket` too: both arms below read only `.assigns`, which
  # a socket carries the same shape as a conn.
  @doc """
  Whether the request/socket carries a PRINCIPAL — an API token (any
  permission) or an account session whose user is a member of the RESOLVED
  workspace. Authentication, not authorization: `allowed?/4` decides what
  that someone may do.
  """
  @spec authenticated?(Plug.Conn.t() | Phoenix.LiveView.Socket.t() | map()) :: boolean()
  def authenticated?(conn) do
    match?(%{assigns: %{api_token: %_{} = _}}, conn) or account_member?(conn)
  end

  defp account_member?(%{assigns: assigns}) do
    case {assigns[:current_user], assigns[:current_workspace]} do
      {%User{} = user, %{id: ws_id}} when is_binary(ws_id) ->
        TenancyAuth.authorize(user, ws_id, :read) == :ok

      _ ->
        false
    end
  end

  defp account_member?(_conn), do: false

  # MATCH THE TOKEN FIRST — the tripwire `authenticated?/1` just armed.
  # `Auth.has_permission?/2` is `permission in (token.permissions || [])`, so a
  # nil token RAISES BadMapError instead of answering false: a 500 where a
  # boolean belongs. That was unreachable only because `permission_set/2` guards
  # this call with `auth && admin?(conn)` and `auth` WAS token presence. Now that
  # a token-less account member can make `auth` true, this call is live, and it
  # is paid in the same change (the identical defect was fixed in the
  # controller's `admin?/1` twin).
  #
  # The account analogue of a token's global "admin" permission is per-workspace
  # admin authority, so ask `workspace_admin?/2` — the NARROWER question, which a
  # non-member and an ordinary member both fail. `admin` here confers the right to
  # edit metadata through, and force-release, ANOTHER actor's checkout lock; a
  # privilege grant fails CLOSED.
  defp admin?(conn) do
    case conn.assigns[:api_token] do
      %_{} = token ->
        Auth.has_permission?(token, "admin")

      _ ->
        case {conn.assigns[:current_user], conn.assigns[:current_workspace]} do
          {%User{} = user, %{id: ws_id}} when is_binary(ws_id) ->
            TenancyAuth.workspace_admin?(user, ws_id)

          _ ->
            false
        end
    end
  end

  # DELIBERATELY NOT GIVEN AN ACCOUNT ARM — see the pin in
  # account_session_media_write_test.exs ("actor_label attribution").
  #
  # `actor_label/1` names the actor in `checkedOutBy`, which is USER-VISIBLE and
  # compared for equality by `permission_set/2`. What a human principal should be
  # stamped as (email? display name? user id?) is a product decision nobody has
  # made, and guessing it writes user-visible data and silently re-keys existing
  # lock comparisons. So this stays token-only on purpose.
  #
  # It is not biting today: the only callers of the sibling
  # `V1.MediaController.actor_label/1` are `checkout`/`undo_checkout`, routed on
  # `:media_mutate` / `[:scoped_api, :media_mutate]`, NEITHER of which carries
  # `OptionalSessionToken` — so `:current_user` is never set there. Adding that
  # plug to either pipeline would look like a harmless improvement and would
  # start stamping a token's label on a user's checkout. The test pins the
  # pipelines so that change cannot land silently.
  defp actor_label(conn) do
    case conn.assigns[:api_token] do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> "api"
    end
  end

  defp checked_out_by(nil), do: nil

  defp checked_out_by(%Document{content: content}) when is_map(content) do
    Map.get(content, "checkedOutBy")
  end

  defp checked_out_by(_), do: nil
end
