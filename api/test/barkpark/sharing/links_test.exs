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

    {:ok, {_raw, link}} = Links.create(Map.put(base, :ttl, 1_000_000_000_000_000_000_000_000_000_000))

    assert DateTime.compare(link.expires_at, ceiling) in [:lt, :eq]
    # Clamp lands it right at ~now + 1y, not decades out.
    assert DateTime.compare(link.expires_at, DateTime.add(DateTime.utc_now(), @one_year - 60)) == :gt
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
end
