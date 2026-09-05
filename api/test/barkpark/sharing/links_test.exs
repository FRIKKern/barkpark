defmodule Barkpark.Sharing.LinksTest do
  @moduledoc """
  `Barkpark.Sharing.Links.create/1` TTL handling — the expires_at derivation
  must clamp an attacker-supplied ttl at one year (mirroring
  `Barkpark.Auth` @share_token_max_ttl), so a JSON bignum ttl can neither hang
  the request (runaway bignum date math) nor mint a never-expiring link.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Sharing.Links

  import Barkpark.TenancyFixtures

  @one_year 365 * 24 * 3600

  setup do
    ws = create_workspace!("links-ws")
    proj = create_project!(ws, "links-proj")

    base = %{
      workspace_id: ws.id,
      project_id: proj.id,
      dataset: "production",
      kind: "doc",
      ref_type: "post",
      ref_id: "post1",
      access: "read"
    }

    {:ok, base: base}
  end

  test "clamps a huge JSON ttl at one year and completes fast", %{base: base} do
    # 10^30 — a bignum that unclamped would push expires_at ~3e22 years out and
    # (at more digits) hang DateTime.add. Clamped, it is small-int math.
    ceiling = DateTime.add(DateTime.utc_now(), 366 * 24 * 3600, :second)

    {:ok, {_raw, link}} =
      Links.create(Map.put(base, :ttl, 1_000_000_000_000_000_000_000_000_000_000))

    assert DateTime.compare(link.expires_at, ceiling) in [:lt, :eq]
    # Clamp lands it right at ~now + 1y, not decades out.
    assert DateTime.compare(link.expires_at, DateTime.add(DateTime.utc_now(), @one_year - 60)) ==
             :gt
  end

  test "honors a normal ttl un-clamped", %{base: base} do
    before = DateTime.utc_now()
    {:ok, {_raw, link}} = Links.create(Map.put(base, :ttl, 3600))

    expected = DateTime.add(before, 3600, :second)
    # Within a few seconds of now + 3600 — nowhere near the 1y clamp.
    assert abs(DateTime.diff(link.expires_at, expected)) <= 5
  end

  test "nil ttl yields no expiry", %{base: base} do
    {:ok, {_raw, link}} = Links.create(Map.put(base, :ttl, nil))
    assert link.expires_at == nil
  end

  describe "workspace_admin?/2 — the workspace-id totality is the chokepoint's (task-83ceffc9e7e32174)" do
    # The wrapper used to run `Repo.uuid_or_nil(workspace_id)` itself. It no
    # longer does: `Tenancy.Auth.membership/3` casts both ids and denies on a
    # failure, so a malformed workspace id must DENY here without raising —
    # and, mutation-proved, it is the chokepoint doing it: with
    # `Repo.uuid_or_nil/1` disarmed by hand these arms red with
    # `Ecto.Query.CastError` from tenancy/auth.ex, not from this file.
    test "a non-UUID / blank / nil workspace id denies and does not raise" do
      user = %Barkpark.Accounts.User{id: Ecto.UUID.generate()}
      token = %Barkpark.Auth.ApiToken{id: Ecto.UUID.generate(), permissions: ["admin"]}

      for bad <- ["", "not-a-uuid", "  ", "0", "11111111-1111-1111-1111-11111111111", nil],
          principal <- [user, token, [user, token]] do
        refute Links.workspace_admin?(principal, bad),
               "expected a DENIAL for workspace_id #{inspect(bad)} and principal #{inspect(principal, limit: 3)}"
      end
    end

    test "a principal shape the chokepoint would raise on is still narrowed here" do
      ws = create_workspace!("links-ws-shape")
      refute Links.workspace_admin?(nil, ws.id)
      refute Links.workspace_admin?(%Barkpark.Auth.ApiToken{id: nil}, ws.id)
      refute Links.workspace_admin?([], ws.id)
      refute Links.workspace_admin?(:not_a_principal, ws.id)
    end
  end
end
