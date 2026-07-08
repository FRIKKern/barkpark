defmodule BarkparkWeb.GrantController do
  @moduledoc """
  Airdrop-grant CLAIM flow — `GET /grant/:token`.

  A grantor mints a shareable, account-bound scoped grant (`Barkpark.Access`)
  for a grantee by email; the raw link token is handed over out-of-band. When
  the grantee opens `/grant/<token>` in a browser this controller binds the
  grant to their *authenticated account* and drops them into the scoped Studio.

  Runs on the `:soft_token` pipeline (`OptionalSessionToken`): the conn carries
  `:current_user` when a `user_session` cookie is present, or nothing when
  anonymous — never a hard 401.

  ## Two account-binding guards, and why the controller owns one

  `Access.claim/2` binds *whoever is authenticated* and is atomic on
  `claimed_at IS NULL`; it does NOT verify that the claimant is the intended
  grantee. The grantee-email match is therefore enforced HERE, before the claim
  runs — a grant is only ever claimed by the account whose email the grantor
  addressed it to.

  ## NO-ORACLE failure

  Exactly one non-success reveals anything: an *unauthenticated* request is
  bounced to `/login?return_to=/grant/<token>` so the claim resumes after
  sign-in (this leaks nothing about the token — it is the same for every
  string). EVERY other failure for an authenticated user — token unknown,
  addressed to a different account, expired, revoked, or already-spent — funnels
  through ONE byte-identical response (`invalid_grant/1`): same status, same
  flash, same redirect location. Token existence is unobservable: a wrong-grantee
  authenticated user and a nonexistent token get identical responses. Failures
  are never branched by reason, mirroring `SessionController.ticket/2`.

  The claim DECISION itself (grantee-email match + atomic claim, collapsed to
  one `:invalid`) lives in `Barkpark.Access.ClaimFlow` — the SAME module the
  JSON `BarkparkWeb.AccessController.claim/2` uses, so there is exactly one
  no-oracle contract. This controller only renders that outcome as a redirect.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Access
  alias Barkpark.Access.ClaimFlow

  @default_return_to "/studio"

  def claim(conn, %{"token" => token}) when is_binary(token) do
    # A claim is a one-time state change — never let a proxy or history cache it.
    conn = no_store(conn)

    case conn.assigns[:current_user] do
      %Barkpark.Accounts.User{} = user ->
        claim_for(conn, token, user)

      _ ->
        # Anonymous: resume the claim after sign-in. This is the ONLY
        # non-success with a distinct destination, and it reveals nothing about
        # the token (identical for any string).
        return_to = sanitize_return_to("/grant/" <> token)
        redirect(conn, to: "/login?" <> URI.encode_query(%{"return_to" => return_to}))
    end
  end

  def claim(conn, _params) do
    conn
    |> no_store()
    |> invalid_grant()
  end

  # Authenticated claim. The grantee-email match + atomic claim (collapsed to
  # one no-oracle outcome) live in the SHARED `Access.ClaimFlow.resolve/2` — the
  # same decision the JSON API runs. This controller only renders the outcome.
  defp claim_for(conn, token, user) do
    case ClaimFlow.resolve(token, user) do
      {:ok, claimed} ->
        conn
        |> put_flash(:info, "Access granted — you're all set.")
        |> redirect(to: scoped_studio_target(claimed))

      :invalid ->
        invalid_grant(conn)
    end
  end

  # The single no-oracle failure. Byte-identical for every authenticated failure
  # kind — unknown token, wrong grantee, expired, revoked, already-claimed — so
  # token existence is unobservable.
  defp invalid_grant(conn) do
    conn
    |> put_flash(:error, "This access link is invalid or has expired.")
    |> redirect(to: @default_return_to)
  end

  # The scoped-Studio landing for a claimed grant: workspace + project slugs
  # resolved from the grant's scope ladder (reusing the shared
  # `Tenancy.resolve_scope_slugs/2`), the grant's dataset when it pins one, else
  # the instance default. The canonical `/w/:ws/p/:proj/d/:ds/studio` form —
  # LiveScope re-authorizes on mount.
  defp scoped_studio_target(%Access.Grant{} = grant) do
    {ws_slug, project_slug} =
      Barkpark.Tenancy.resolve_scope_slugs(grant.workspace_id, grant.project_id)

    dataset = grant.dataset || Barkpark.Content.default_dataset()

    "/w/#{ws_slug}/p/#{project_slug}/d/#{dataset}/studio"
  end

  # Never cache/store a claim response, and don't leak the token URL onward as a
  # Referer — same hardening SessionController applies to its one-time links.
  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  # Only same-origin absolute paths survive; anything else falls back to the
  # Studio root (mirrors SessionController.sanitize_return_to/1).
  defp sanitize_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    else
      @default_return_to
    end
  end
end
