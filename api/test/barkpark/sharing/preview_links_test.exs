defmodule Barkpark.Sharing.PreviewLinksTest do
  @moduledoc """
  `Barkpark.Sharing.PreviewLinks` — the context-level half of
  task-6812c3100d7aedbc. HTTP-level draft/wrong-doc/cross-workspace coverage
  lives in `BarkparkWeb.PreviewLinkTest`; this file pins the TTL defaulting +
  clamping and the expired/revoked resolve refusals, which are fastest to
  prove directly against the context (no sleeping on a real clock).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Repo
  alias Barkpark.Sharing.PreviewLinks

  import Barkpark.TenancyFixtures

  @one_day 24 * 3600
  @seven_days 7 * 24 * 3600

  setup do
    ws = create_workspace!("preview-links-ws")
    proj = create_project!(ws, "preview-links-proj")

    base = %{
      workspace_id: ws.id,
      project_id: proj.id,
      dataset: "production",
      doc_id: "drafts.plt-doc",
      ref_type: "post"
    }

    {:ok, base: base}
  end

  test "omitting ttl defaults to one day", %{base: base} do
    before = DateTime.utc_now()
    {:ok, {_raw, link}} = PreviewLinks.create(base)

    expected = DateTime.add(before, @one_day, :second)
    assert abs(DateTime.diff(link.expires_at, expected)) <= 5
  end

  test "a huge ttl clamps at seven days, never un-expiring", %{base: base} do
    ceiling = DateTime.add(DateTime.utc_now(), @seven_days + 5, :second)

    {:ok, {_raw, link}} =
      PreviewLinks.create(Map.put(base, :ttl, 1_000_000_000_000_000_000_000_000_000_000))

    assert DateTime.compare(link.expires_at, ceiling) in [:lt, :eq]

    assert DateTime.compare(
             link.expires_at,
             DateTime.add(DateTime.utc_now(), @seven_days - 60)
           ) == :gt
  end

  test "a normal ttl is honored un-clamped", %{base: base} do
    before = DateTime.utc_now()
    {:ok, {_raw, link}} = PreviewLinks.create(Map.put(base, :ttl, 3600))

    expected = DateTime.add(before, 3600, :second)
    assert abs(DateTime.diff(link.expires_at, expected)) <= 5
  end

  test "the raw doc_id survives unchanged — a drafts. prefix is NOT stripped", %{base: base} do
    {:ok, {_raw, link}} = PreviewLinks.create(base)
    assert link.doc_id == "drafts.plt-doc"
  end

  test "resolve/1 round-trips a live token", %{base: base} do
    {:ok, {raw, link}} = PreviewLinks.create(base)
    assert {:ok, resolved} = PreviewLinks.resolve(raw)
    assert resolved.id == link.id
  end

  test "resolve/1 refuses a garbage token" do
    assert {:error, :not_found} = PreviewLinks.resolve("not-a-real-token")
  end

  test "resolve/1 refuses an EXPIRED token — byte-identical to missing", %{base: base} do
    {:ok, {raw, link}} = PreviewLinks.create(Map.put(base, :ttl, 3600))

    link
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert {:error, :not_found} = PreviewLinks.resolve(raw)
  end

  test "resolve/1 refuses a REVOKED token — byte-identical to missing", %{base: base} do
    {:ok, {raw, link}} = PreviewLinks.create(base)
    {:ok, _} = PreviewLinks.revoke(link.id)

    assert {:error, :not_found} = PreviewLinks.resolve(raw)
  end

  test "revoke/1 is idempotent — a second revoke keeps the first timestamp", %{base: base} do
    {:ok, {_raw, link}} = PreviewLinks.create(base)
    {:ok, once} = PreviewLinks.revoke(link.id)
    {:ok, twice} = PreviewLinks.revoke(link.id)

    refute is_nil(once.revoked_at)
    refute DateTime.compare(once.revoked_at, twice.revoked_at) == :lt
  end

  test "revoke_scoped/2 denies a non-admin principal and leaves the row live", %{
    base: base
  } do
    {:ok, {_raw, link}} = PreviewLinks.create(base)
    stranger = %Barkpark.Auth.ApiToken{id: Ecto.UUID.generate(), permissions: ["admin"]}

    assert {:error, :not_found} = PreviewLinks.revoke_scoped(stranger, link.id)
    assert is_nil(Repo.get(Barkpark.Sharing.PreviewLink, link.id).revoked_at)
  end
end
