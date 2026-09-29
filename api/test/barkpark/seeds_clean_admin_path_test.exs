defmodule Barkpark.SeedsCleanAdminPathTest do
  @moduledoc """
  The owner walk, end to end, with NO direct SQL anywhere in it:
  an empty box -> `Barkpark.Seeds.run(:clean)` (what `bin/barkpark token` shells
  out to) -> the raw token off the banner -> an admin-gated `/v1` route answers
  200.

  This is the claim `scripts/pds-scratch-target.sh` TRAP 6 used to deny by
  implication ("there is NO mix task that mints a token", which read as "no path
  exists"). The mint is first-party; only a mix TASK is absent. Nothing here
  touches `api_tokens` through Ecto or psql — the credential is minted by the
  seed and spent over HTTP, which is exactly the owner's path.

  async: false — the seed reads BARKPARK_SEED_PROFILE / BARKPARK_SEED_ADMIN_TOKEN
  from the process env and the plugin Registry is a shared singleton.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Barkpark.Repo

  # An admin-gated read: `scope "/v1/data"` rides `:flat_admin_api`
  # (RequireToken -> DeriveWorkspaceFromToken -> AssignDefaultScope ->
  # RequireAdmin), so a 200 here is a positive verdict from RequireAdmin, not
  # merely an unauthenticated route that lets anyone in. The control test below
  # proves the door is shut without the credential.
  @admin_route "/v1/data/search/production/settings"

  # Simulate a genuinely FRESH box inside the sandbox transaction: a developer's
  # `MIX_ENV=test mix ecto.reset` seeds the demo profile and commits it, and a
  # leftover admin token would make the seed SKIP the mint and this test measure
  # nothing. Memberships referencing tokens go first.
  setup do
    Repo.delete_all(
      from(m in Barkpark.Tenancy.Membership, where: m.principal_type == "api_token")
    )

    Repo.delete_all(Barkpark.Auth.ApiToken)
    :ok
  end

  defp mint! do
    output = capture_io(fn -> Barkpark.Seeds.run(:clean) end)
    assert [_pre, raw] = Regex.run(~r/(bp_admin_[A-Za-z0-9_-]{32})/, output)
    {raw, output}
  end

  test "a fresh box -> bootstrap token -> an admin-gated route returns 200", %{conn: conn} do
    {raw, _output} = mint!()

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> get(@admin_route)

    refute_rate_limited!(conn)

    assert conn.status == 200,
           "the bootstrap credential did not open #{@admin_route} — got #{conn.status}"
  end

  test "the same route refuses the same request WITHOUT the credential", %{conn: conn} do
    {_raw, _output} = mint!()

    conn = get(conn, @admin_route)

    refute_rate_limited!(conn)

    assert conn.status in [401, 403],
           "CONTROL FAILED: #{@admin_route} answered #{conn.status} with no bearer, so the " <>
             "200 above proves nothing about the credential"
  end

  # AC#8: the bootstrap credential is permission-scoped and cannot mint another
  # admin token once it has minted one. The second run below is the bootstrap
  # gate closing, observed through the seed's own output rather than a row count.
  test "the bootstrap cannot mint a second admin key beside a live one" do
    {raw, first} = mint!()

    second = capture_io(fn -> Barkpark.Seeds.run(:clean) end)

    assert second =~ "Admin token already present — skipping token bootstrap."
    refute second =~ "bp_admin_"

    # Printed ONCE, in the first run only, and never stored in the clear.
    assert first =~ raw
    assert {:ok, token} = Barkpark.Auth.verify_token(raw)
    assert Enum.sort(token.permissions) == ["admin", "read", "write"]
  end
end
