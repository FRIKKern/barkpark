defmodule Barkpark.Tenancy.AuthPrincipalKindTest do
  @moduledoc """
  THE AMBIGUOUS ARGUMENT. `Barkpark.Tenancy.Auth`'s read predicates accept a
  raw principal id binary, and a raw id carries NO `principal_type`
  discriminator. The 2-arity raw-binary path reads it as an **api_token** id,
  so the SAME user membership answers `"admin"` through the `%User{}` struct
  and `nil` through the bare id — and `workspace_admin?/2`, the canonical
  workspace-admin-authority predicate five surfaces now gate on, answers FALSE
  for a user holding a genuine admin seat. A silent FALSE on an admin gate is a
  lockout that nobody reports as a security bug. (The capability marker itself
  is deliberately NOT spelled out here: `scripts/docs-anchors-check.sh` greps
  for that literal and a second copy of the slug FAILS the gate — correctly.)

  The fix does NOT make the bare id resolve "whichever row exists" — that would
  silently WIDEN a user id into a token's grant. It makes the kind SAYABLE
  (`membership/3`, `member?/3`, `membership_role/3`, `workspace_admin?/3`) and
  makes the wrong guess AUDIBLE: the bare-id arm still denies, but logs the
  mis-typed call. Denial, not a raise — #12616 made this module fail CLOSED
  rather than crash, and this file would be a bad reason to reintroduce a raise
  on an authorization path.

  Layout, so each claim reds on its OWN row under mutation:

    * "the trap" — the struct/bare divergence, pinned in both directions.
    * "the explicit-kind forms" — what a caller holding a raw id should call.
    * "SEMANTICS PRESERVED" — controls that must be green BEFORE and AFTER.
    * "write-side twin" — `create_membership/4`'s implicit `"api_token"`
      default, pinned as the vacuous-green generator it is.

  Semantics-preserved for the shipped call sites lives in
  `test/barkpark/tenancy_auth_test.exs`, which this task leaves BYTE-UNTOUCHED.

  WHY THIS MODULE IS SYNCHRONOUS (task-4f7caaab44c132c1). Three rows in
  "SEMANTICS PRESERVED" claim the mis-typed signal stays SILENT — they refute a
  match on the captured log rather than assert one. `capture_log/2` mutes the
  default handler and captures the whole Logger device, and its own docs say so:
  "when `async` is set to `true` ... messages from other tests might be captured
  ... typically by using the `=~/2` operator to perform PARTIAL matches." A
  presence assert survives foreign lines; an absence claim is exactly the case
  that doc sentence excludes, because a concurrent module can only ADD text, and
  text it adds can only make an absence claim red. Narrowing the needle to a
  fresh UUID makes that unlikely, not sound. Synchronous modules run alone, after
  every concurrent one, so the capture here holds this test's output and nothing
  else. Do NOT restore concurrency here while those rows refute the log — see
  `scripts/refute-on-absence-capture-log-check.sh`, which pins the combination.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth

  @password "correct-horse-battery"

  defp workspace!(slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    ws
  end

  defp user!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp token!(permissions) do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("t-" <> Ecto.UUID.generate()),
        label: "l",
        dataset: "test",
        permissions: permissions
      })
      |> Repo.insert()

    token
  end

  # A user holding a GENUINE admin seat: a `principal_type: "user"` row, written
  # the way every user-granting caller in api/lib writes it.
  defp admin_user!(ws, email) do
    user = user!(email)
    {:ok, _} = Auth.create_membership(ws.id, user.id, "admin", "user")
    user
  end

  describe "the trap — the same membership answered by struct vs by bare id" do
    test "struct says admin; the bare id denies, but no longer in silence" do
      ws = workspace!("pk-trap")
      user = admin_user!(ws, "pk-trap@example.com")

      # The struct is unambiguous and correct.
      assert Auth.membership_role(user, ws.id) == "admin"
      assert Auth.workspace_admin?(user, ws.id)

      # The bare id is AMBIGUOUS. It is read as an api_token id, so it still
      # denies — the value is unchanged, and deliberately so: making it resolve
      # would widen a user id into the token row space.
      log =
        capture_log(fn ->
          refute Auth.workspace_admin?(user.id, ws.id)
          assert Auth.membership_role(user.id, ws.id) == nil
          refute Auth.member?(user.id, ws.id)
          assert Auth.membership(user.id, ws.id) == nil
        end)

      # THE FIX: the wrong guess is audible. Without it this log is empty and
      # a legitimate admin is denied with no trace anywhere.
      assert log =~ "BARE principal id was read as an api_token id but names a USER"
      assert log =~ user.id
      assert log =~ ws.id
    end

    test "the signal names the mis-typed call once per predicate, not once per process" do
      ws = workspace!("pk-signal")
      user = admin_user!(ws, "pk-signal@example.com")

      first = capture_log(fn -> refute Auth.workspace_admin?(user.id, ws.id) end)
      second = capture_log(fn -> refute Auth.workspace_admin?(user.id, ws.id) end)

      assert first =~ "BARE principal id"
      assert second =~ "BARE principal id"
    end
  end

  describe "the explicit-kind forms — what a caller holding a raw id should call" do
    test "workspace_admin?/3 with :user answers TRUE for the admin seat the bare id missed" do
      ws = workspace!("pk-explicit")
      user = admin_user!(ws, "pk-explicit@example.com")

      assert Auth.workspace_admin?(user.id, ws.id, :user)
      assert Auth.membership_role(user.id, ws.id, :user) == "admin"
      assert Auth.member?(user.id, ws.id, :user)
      assert %Tenancy.Membership{role: "admin"} = Auth.membership(user.id, ws.id, :user)
    end

    test ":api_token asked about a USER id resolves NOTHING — the kinds stay disjoint" do
      ws = workspace!("pk-disjoint-user")
      user = admin_user!(ws, "pk-disjoint-user@example.com")

      assert Auth.membership(user.id, ws.id, :api_token) == nil
      refute Auth.workspace_admin?(user.id, ws.id, :api_token)
    end

    test ":user asked about a TOKEN id resolves NOTHING — the kinds stay disjoint" do
      ws = workspace!("pk-disjoint-token")
      token = token!(["admin"])
      {:ok, _} = Auth.create_membership(ws.id, token.id, "admin", "api_token")

      assert Auth.membership(token.id, ws.id, :user) == nil
      refute Auth.workspace_admin?(token.id, ws.id, :user)

      # …and the token still resolves under its OWN kind.
      assert Auth.workspace_admin?(token.id, ws.id, :api_token)
    end

    test "the explicit-kind forms are TOTAL — malformed input denies, never raises" do
      ws = workspace!("pk-total")

      for bad <- [nil, 42, "", "zzz", %{}] do
        assert Auth.membership(bad, ws.id, :user) == nil
        assert Auth.membership(bad, ws.id, :api_token) == nil
        refute Auth.workspace_admin?(bad, ws.id, :user)
        assert Auth.membership_role(bad, ws.id, :user) == nil
        refute Auth.member?(bad, ws.id, :user)
      end

      valid = Ecto.UUID.generate()

      # A malformed WORKSPACE id, and an unrecognised KIND, deny the same way.
      assert Auth.membership(valid, nil, :user) == nil
      assert Auth.membership(valid, "zzz", :user) == nil
      assert Auth.membership(valid, ws.id, :wombat) == nil
      refute Auth.workspace_admin?(valid, ws.id, :wombat)
    end
  end

  describe "SEMANTICS PRESERVED — these rows are green BEFORE and AFTER the fix" do
    test "a real api_token member still resolves through EVERY 2-arity shape" do
      ws = workspace!("pk-token-member")
      token = token!(["read", "write", "admin"])
      {:ok, _} = Auth.create_membership(ws.id, token.id, "admin", "api_token")

      assert Auth.workspace_admin?(token, ws.id)
      assert Auth.workspace_admin?(token.id, ws.id)
      assert Auth.membership_role(token, ws.id) == "admin"
      assert Auth.membership_role(token.id, ws.id) == "admin"
      assert Auth.member?(token.id, ws.id)
      assert Auth.authorize(token, ws.id, :admin) == :ok
    end

    test "a real api_token member's bare id logs NOTHING — the signal is not a blanket warning" do
      ws = workspace!("pk-token-quiet")
      token = token!(["admin"])
      {:ok, _} = Auth.create_membership(ws.id, token.id, "admin", "api_token")

      log = capture_log(fn -> assert Auth.workspace_admin?(token.id, ws.id) end)
      # Refuted on THIS workspace's id: `capture_log` is process-global, so a
      # bare `=~ "BARE principal id"` refute could be tripped by a sibling
      # async module and would be vacuous the other way round.
      refute log =~ ws.id
    end

    test "a genuine NON-member denies quietly — no row of either kind, no signal" do
      ws = workspace!("pk-nonmember")
      outsider = token!(["admin"])
      stranger = user!("pk-stranger@example.com")

      log =
        capture_log(fn ->
          refute Auth.workspace_admin?(outsider, ws.id)
          refute Auth.workspace_admin?(outsider.id, ws.id)
          refute Auth.workspace_admin?(stranger, ws.id)
          refute Auth.workspace_admin?(stranger.id, ws.id)
          assert Auth.authorize(outsider, ws.id, :read) == {:error, :forbidden}
        end)

      refute log =~ ws.id
      refute log =~ stranger.id
    end

    test "a USER member still resolves through the struct, and authorize/3 is unchanged" do
      ws = workspace!("pk-user-member")
      user = admin_user!(ws, "pk-user-member@example.com")
      plain = user!("pk-plain@example.com")
      {:ok, _} = Auth.create_membership(ws.id, plain.id, "member", "user")

      assert Auth.authorize(user, ws.id, :admin) == :ok
      assert Auth.authorize(plain, ws.id, :write) == :ok
      assert Auth.authorize(plain, ws.id, :admin) == {:error, :forbidden}
      refute Auth.workspace_admin?(plain, ws.id)
      refute Auth.workspace_admin?(plain.id, ws.id, :user)
    end

    test "a malformed bare id denies without raising and without the mis-typed signal" do
      ws = workspace!("pk-malformed")

      log =
        capture_log(fn ->
          for bad <- [nil, 42, "", "zzz"] do
            assert Auth.membership(bad, ws.id) == nil
            refute Auth.workspace_admin?(bad, ws.id)
          end

          assert Auth.membership(%ApiToken{id: nil}, ws.id) == nil
          assert Auth.membership(%Accounts.User{id: nil}, ws.id) == nil
        end)

      refute log =~ ws.id
    end

    test "the global-admin-token divergence is untouched (barkpark-23yi / fsko)" do
      ws_b = workspace!("pk-ws-b")
      token = token!(["read", "write", "admin"])
      {:ok, _} = Auth.create_membership(ws_b.id, token.id, "member", "api_token")

      assert Auth.authorize(token, ws_b.id, :admin) == :ok
      refute Auth.workspace_admin?(token, ws_b.id)
      refute Auth.workspace_admin?(token.id, ws_b.id)
      refute Auth.workspace_admin?(token.id, ws_b.id, :api_token)
    end
  end

  describe "write-side twin — create_membership/4's implicit api_token default" do
    test "omitting principal_type stamps api_token even for a USER id (the vacuous-green generator)" do
      ws = workspace!("pk-write-default")
      user = user!("pk-write-default@example.com")

      # The default. This is the shape a test writes when it means "grant this
      # user an admin seat" — and it does NOT do that.
      {:ok, membership} = Auth.create_membership(ws.id, user.id, "admin")
      assert membership.principal_type == "api_token"

      # The worst combination available: the struct sees NO seat (authorize
      # denies) while the bare id reads TRUE off the mis-typed row. A user axis
      # built on this row goes green while proving nothing.
      assert Auth.membership(user, ws.id) == nil
      assert Auth.authorize(user, ws.id, :admin) == {:error, :forbidden}
      assert Auth.workspace_admin?(user.id, ws.id)
      refute Auth.workspace_admin?(user.id, ws.id, :user)
    end

    test "passing \"user\" explicitly writes the row the caller meant" do
      ws = workspace!("pk-write-explicit")
      user = user!("pk-write-explicit@example.com")

      {:ok, membership} = Auth.create_membership(ws.id, user.id, "admin", "user")
      assert membership.principal_type == "user"

      assert Auth.authorize(user, ws.id, :admin) == :ok
      assert Auth.workspace_admin?(user, ws.id)
      assert Auth.workspace_admin?(user.id, ws.id, :user)
    end
  end
end
