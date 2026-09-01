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
  #
  # SECOND, INDEPENDENT CALLER FAMILY (task-d55b02001cf589f0), arrived at from
  # the opposite direction and recorded here because the agreement is the
  # evidence: the versioned media READ path asks the same question in two
  # places — `V1.MediaController.render_opts/3` (and its fork in
  # `MediaCollectionsController`) gates URL SIGNING on it, and the anonymous
  # listing clamp gates on it too. Two unrelated changes independently
  # concluded that a local `conn.assigns[:api_token] != nil` would be the
  # divergence the comment above warns about; here it would have refused a
  # signature to the account-session workspace member this arm exists to admit.
  #
  # KEEP THE SOCKET IN THE SPEC. The media-side change originally wrote the
  # narrower `Plug.Conn.t() | map()`, which would have silently retracted the
  # contract the Studio picker relies on. Widen, never narrow, this signature.
  # THE PUBLIC-READ TIER IS NOT A MEDIA PRINCIPAL
  # (`dr-w2-s7-followup-scoped-media-public-read-audit`).
  #
  # This predicate is the ONE seat the whole media READ tier keys on:
  # `V1.MediaController.visibility_clamp_opts/1` and its
  # `MediaCollectionsController` fork decide the listing ceiling with it,
  # `render_opts/3` decides URL SIGNING with it, and `permission_set/2` /
  # `allowed?/4` below decide the single-asset answer with it. Until this
  # change it asked PRESENCE — any `%ApiToken{}` at all — so the `public-read`
  # tier, the browser-shipped site credential that `cloud/sites/deploy.ex`
  # bakes into a built site as `BARKPARK_TOKEN`, was a full media principal:
  #
  #   * `Tenancy.Auth`'s `@read_perms` maps `public-read -> :read`, so the token
  #     clears `ResolveWorkspace`'s membership gate on the scoped media routes;
  #   * `:scoped_api` in `router.ex` mounts no `Plugs.PublicRead` and MUST NOT
  #     (search-template D49 — deny-by-default would 403 the 21 routes riding
  #     it), so nothing upstream clamps the tier;
  #   * so `visibility_clamp_opts/1` returned `[]`, and a `bp_visibility:
  #     "private"` asset was served — rows, `count`, `filename`, `path`, `size`
  #     — to a credential shipped in public site JS. MEASURED before this
  #     change on the listing, search AND show doors:
  #     `test/barkpark/media/scoped_media_public_read_tier_audit_test.exs`.
  #
  # This is the media twin of the fix `DocumentsRetriever` landed for the
  # scoped DOCUMENT search door
  # (`DocumentsRetriever.restrict_anonymous_to_public_types/3`, "KEYED ON THE
  # PERMISSION, NOT ON `principal_type`"), and it is keyed the same way:
  # by MEMBERSHIP in the permission list, never list equality. `TokenController`
  # mints from the allowlist `~w(public-read read)` over a PUBLIC route, so
  # `["public-read", "read"]` is a shape anyone can ask for and a
  # `perms == ["public-read"]` pin would be escapable by construction.
  #
  # ONE OWNER, NOT A FOURTH COPY. The tier test itself is
  # `Content.Schema.bypasses_visibility_gate?/1` (canonical slug
  # `visibility-gate-tier`) — the same predicate behind the anonymous search
  # allowlist, the batch document read and the corpus-graph clamp. A
  # hand-rolled `"public-read" in token.permissions` here is exactly the
  # "one rule, several private copies" defect this module's own history warns
  # about two comments up.
  #
  # WHAT IS DELIBERATELY UNCHANGED:
  #
  #   * PUBLIC assets. `delivery_ok?("public", _, _)` is true regardless, and
  #     `visibility_clamp: :public` is precisely the tier this credential was
  #     minted for — a public-read caller still gets 200s, just the public tier.
  #   * The ACCOUNT arm. `account_member?/1` is untouched, so the
  #     account-session workspace member the arm exists to admit is
  #     byte-identical.
  #   * A token struct carrying no `permissions` LIST keeps today's answer.
  #     Absence of the key is not evidence of the tier (the same reading
  #     `Plugs.PublicRead.public_read_token?/1` takes), and a `nil` there must
  #     not become a `FunctionClauseError` on a delivery path — a crash where a
  #     boolean belongs is the defect the `admin?/1` comment below records.
  #   * `share_view/2`. A resolved SHARE token is its own credential and never
  #     routes through this predicate (see the `render_opts/4` comment in
  #     `MediaCollectionsController`); this change cannot reach it.
  #
  # SIGNING FOLLOWS, AND THAT IS THE POINT, NOT A SIDE EFFECT. With the tier no
  # longer a principal, `render_opts/3` stops honouring `appendRequestSecret`
  # for it, so a public-read caller can no longer mint a `SignedUrl` for a
  # `token`-visibility asset — the "I know an id" -> BYTES escalation
  # `v1_media_anon_read_clamp_test.exs` closed for the anonymous caller and
  # left open for this one.
  @doc """
  Whether the request/socket carries a media-delivery PRINCIPAL — an API token
  OUTSIDE the `public-read` tier (share tokens included:
  `Auth.create_share_token/5` inserts a real `api_tokens` row) or an account
  session whose user is a member of the RESOLVED workspace.

  Authentication, not authorization: `allowed?/4` decides what that someone may
  do. A `public-read` token is a valid token and a workspace member, and is
  still NOT a principal here — it is the public tier by construction, so it
  reads the public tier and nothing else.
  """
  @spec authenticated?(Plug.Conn.t() | Phoenix.LiveView.Socket.t() | map()) :: boolean()
  def authenticated?(conn) do
    token_principal?(conn) or account_member?(conn)
  end

  defp token_principal?(%{assigns: %{api_token: %_{id: _, permissions: perms} = token}})
       when is_list(perms) do
    Barkpark.Content.Schema.bypasses_visibility_gate?(
      Barkpark.Content.CallerContext.from_token(token)
    )
  end

  # A token struct with no `permissions` list (or no `id`) — absence of the key
  # is not evidence of the tier, so it keeps the historical PRESENCE answer.
  defp token_principal?(%{assigns: %{api_token: %_{}}}), do: true

  defp token_principal?(_), do: false

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
