defmodule BarkparkWeb.LiveAuthMfaReturnToTest do
  @moduledoc """
  era-bl-mfa-returnto-parity — the `:require_org_mfa` halt keeps the D69
  deep-link promise.

  `LiveAuth`'s `:require_org_mfa` hook halted with a bare `redirect(to:
  "/login")`, so an MFA-required-but-unenrolled administrator following the
  notifier email's `/studio/chat/:id` link lost the destination: after
  enrolling they landed on `/studio`, not their session. The anonymous arm
  (`denial_target/2`) had preserved `return_to` since D69; this is the parity
  fix.

  ## What this suite pins

    * the destination survives as a validated `?return_to=` on the halt, for
      a flat chat deep link AND a scoped Studio URL (two grammar arms of
      `ReturnTo.sanitize_dest/1`, the ONE validator — no second one was
      written);
    * hostile / unsupported values never ride: external, protocol-relative,
      encoded-hostile and dot-segment paths, and an unsupported non-Studio
      path, all leave the halt at bare `/login`, whose `@default_return_to`
      is `/studio`;
    * **the refusal population is unchanged.** `refusal_population/1` below
      drives the SAME matrix of principals over the SAME URL and records
      only halt-vs-mount — never the redirect string. That census is what
      would red if the fix had bought its `return_to` by letting anybody
      through. The destination assertions are a separate, additive layer.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TotpTestHelper
  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  defp register!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp workspace!(slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "main", name: "main"})
    ws
  end

  defp member!(ws, user, role \\ "member") do
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    :ok
  end

  defp default_owner!(user) do
    %{id: ws_id} = Tenancy.get_default_workspace()
    {:ok, _} = TenancyAuth.create_membership(ws_id, user.id, "owner", "user")
    :ok
  end

  defp enroll_totp!(user) do
    secret = NimbleTOTP.secret()
    {:ok, user, _codes} = Accounts.enable_totp(user, secret, totp_code_stable!(secret))
    user
  end

  # Governance: member of a workspace owned by a `require_mfa` organization.
  defp govern_mfa!(user, slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, _org} = Tenancy.set_organization_require_mfa(org.id, true)
    {:ok, gws} = Tenancy.create_workspace(%{slug: slug <> "-gov", name: slug <> "-gov"})
    {:ok, gws} = Tenancy.assign_workspace_to_organization(gws, org.id)
    member!(gws, user)
    :ok
  end

  # The cookie-REUSE simulation: a session minted before the org flipped
  # `require_mfa` on. This is the ONLY door into the hook's halt arm.
  defp cookie_conn(conn, user) do
    {:ok, token} = Accounts.create_user_session_token(user, [])
    init_test_session(conn, %{"user_session" => token})
  end

  # The halt target for a governed, factor-less Default-workspace owner who
  # requests `path`. Raises if the mount is NOT refused — a silent pass would
  # otherwise read as "no return_to" rather than "the gate opened".
  defp halt_target(conn, email, path) do
    user = register!(email)
    default_owner!(user)
    govern_mfa!(user, email |> String.replace(~r/[^a-z0-9]/, "-"))

    case live(cookie_conn(conn, user), path) do
      {:error, {:redirect, %{to: to}}} -> to
      other -> flunk("expected a halt for #{path}, got: #{inspect(other)}")
    end
  end

  defp return_to_of(target) do
    case URI.parse(target) do
      %URI{query: nil} -> nil
      %URI{query: q} -> URI.decode_query(q)["return_to"]
    end
  end

  # The census records HALT vs MOUNT only. It is deliberately blind to the
  # redirect string: that is the thing the fix is allowed to change, and
  # everything else must be identical to the pre-fix gate.
  defp refusal_population(conn, tag) do
    # `/studio/org-admin`, NOT a chat deep link: a random `/studio/chat/:id`
    # halts for EVERY principal because ChatLive's own mount cannot find the
    # session, which collapses the census to a uniform :halt and measures
    # nothing. (Measured, not assumed — the first run of this census returned
    # five :halts on unmodified main.) `/studio/org-admin` rides the same
    # `[:admin, :require_org_mfa, …]` chain and mounts cleanly for a permitted
    # principal, so each row's verdict is the GATE's verdict.
    path = "/studio/org-admin"

    [
      # 1. governed + factor-less + Default owner → HALT (the fix's subject)
      {:governed_unenrolled_admin,
       fn ->
         u = register!("pop1-#{tag}@example.com")
         default_owner!(u)
         govern_mfa!(u, "pop1-#{tag}")
         cookie_conn(conn, u)
       end},
      # 2. governed + ENROLLED + Default owner → MOUNT (zero-tax)
      {:governed_enrolled_admin,
       fn ->
         u = register!("pop2-#{tag}@example.com")
         default_owner!(u)
         govern_mfa!(u, "pop2-#{tag}")
         enroll_totp!(u)
         cookie_conn(conn, u)
       end},
      # 3. UNgoverned + factor-less + Default owner → MOUNT
      {:ungoverned_admin,
       fn ->
         u = register!("pop3-#{tag}@example.com")
         default_owner!(u)
         cookie_conn(conn, u)
       end},
      # 4. governed + factor-less but NOT a Default owner → HALT (the
      #    :admin hook refuses first; the MFA hook never decides)
      {:governed_unenrolled_nonadmin,
       fn ->
         u = register!("pop4-#{tag}@example.com")
         govern_mfa!(u, "pop4-#{tag}")
         cookie_conn(conn, u)
       end},
      # 5. anonymous → HALT (the D69 arm, untouched by this change)
      {:anonymous, fn -> init_test_session(conn, %{}) end}
    ]
    |> Enum.map(fn {name, build} ->
      verdict =
        case live(build.(), path) do
          {:error, {:redirect, _}} -> :halt
          {:ok, _view, _html} -> :mount
        end

      {name, verdict}
    end)
  end

  describe "criterion 1 — a supported deep link survives the MFA halt" do
    test "the flat chat deep link rides along as a validated return_to", %{conn: conn} do
      sid = Ecto.UUID.generate()
      target = halt_target(conn, "chatdeep@example.com", "/studio/chat/#{sid}")

      assert %URI{path: "/login"} = URI.parse(target)
      assert return_to_of(target) == "/studio/chat/#{sid}"
    end

    test "the original query string survives into the return_to", %{conn: conn} do
      sid = Ecto.UUID.generate()
      target = halt_target(conn, "chatquery@example.com", "/studio/chat/#{sid}?panel=diff")

      assert return_to_of(target) == "/studio/chat/#{sid}?panel=diff"
    end

    test "a second supported destination — the scoped Studio URL — also survives",
         %{conn: conn} do
      ws = workspace!("mfa-rt-scope")
      user = register!("scopedeep@example.com")
      default_owner!(user)
      member!(ws, user)
      govern_mfa!(user, "scopedeep-org")

      path = "/w/mfa-rt-scope/p/main/d/production/studio"

      assert {:error, {:redirect, %{to: to}}} = live(cookie_conn(conn, user), path)
      assert %URI{path: "/login"} = URI.parse(to)
      assert return_to_of(to) == path
    end
  end

  describe "criterion 2 — hostile and unsupported destinations fall back to /studio" do
    # Each of these must leave the halt at BARE `/login`. `/login` with no
    # `return_to` renders with SessionController's `@default_return_to`, i.e.
    # sign-in lands on `/studio` — the documented fallback.

    test "an unsupported (non-Studio) admin path carries no return_to", %{conn: conn} do
      target = halt_target(conn, "unsupported@example.com", "/admin/onixedit/bokbasen")

      assert target == "/login"
      assert return_to_of(target) == nil
    end

    test "a dot-segment traversal in the QUERY never rides", %{conn: conn} do
      # A routable request whose PATH is a supported destination but whose
      # query smuggles a `..` segment: `sanitize_dest/1` splits on `/`, `?`
      # and `#`, so the whole path+query is rejected and the halt stays bare.
      #
      # Deliberately not a path-side `/studio/chat/%2e%2e/…` probe: measured
      # under mutation A (guard deleted), that spelling produced a bare
      # `/login` either way — the router never delivers it to this function,
      # so it discriminates nothing. This one reds under mutation A.
      target = halt_target(conn, "dotseg@example.com", "/studio/org-admin?next=/../logout")

      assert target == "/login"
    end

    test "sanitize_dest is the ONE validator and rejects the hostile shapes" do
      alias BarkparkWeb.Studio.ReturnTo

      # missing
      assert ReturnTo.sanitize_dest(nil) == nil
      assert ReturnTo.sanitize_dest("") == nil
      # external
      assert ReturnTo.sanitize_dest("https://evil.example/studio/chat/1") == nil
      # protocol-relative
      assert ReturnTo.sanitize_dest("//evil.example/studio") == nil
      # encoded-hostile / traversal
      assert ReturnTo.sanitize_dest("/studio/%2e%2e/%2e%2e/logout") == nil
      assert ReturnTo.sanitize_dest("/studio/../../logout") == nil
      # unsupported local path
      assert ReturnTo.sanitize_dest("/admin/onixedit/bokbasen") == nil
      assert ReturnTo.sanitize_dest("/studioevil") == nil
      # the supported arms
      assert ReturnTo.sanitize_dest("/studio/chat/abc") == "/studio/chat/abc"

      assert ReturnTo.sanitize_dest("/w/a/p/b/d/production/studio") ==
               "/w/a/p/b/d/production/studio"
    end
  end

  describe "criterion 3 — the refusal population is byte-compatible" do
    test "every principal's halt-vs-mount verdict is the pre-fix verdict", %{conn: conn} do
      assert refusal_population(conn, "census") == [
               governed_unenrolled_admin: :halt,
               governed_enrolled_admin: :mount,
               ungoverned_admin: :mount,
               governed_unenrolled_nonadmin: :halt,
               anonymous: :halt
             ]
    end

    test "the halt's path component is still exactly /login for every refused principal",
         %{conn: conn} do
      sid = Ecto.UUID.generate()
      path = "/studio/chat/#{sid}"

      user = register!("bytecompat@example.com")
      default_owner!(user)
      govern_mfa!(user, "bytecompat-org")

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(cookie_conn(conn, user), path)

      # Byte-compatible except for the ADDED query parameter: same scheme
      # (none), same host (none), same path, and nothing in the query but
      # `return_to`.
      uri = URI.parse(to)
      assert uri.scheme == nil
      assert uri.host == nil
      assert uri.path == "/login"
      assert Map.keys(URI.decode_query(uri.query || "")) == ["return_to"]

      # The enrolment guidance flash is unchanged.
      assert flash["error"] == BarkparkWeb.SessionIssuer.org_mfa_enrolment_message()
    end
  end
end
