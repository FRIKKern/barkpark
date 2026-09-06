defmodule Barkpark.SeedsCleanTest do
  @moduledoc """
  The clean seed profile (`Barkpark.Seeds.run(:clean)`) — what a fresh
  `bp setup` install gets. Pins: NO demo rows (8 schemas / 27 docs /
  barkpark-dev-token), an admin token minted with read/write/admin + a
  workspace membership, one welcome paper, and seed-level idempotence (a
  second run mints nothing and never clobbers the paper — entrypoint.sh
  re-seeds on every container start).

  async: false — the seed reads BARKPARK_SEED_ADMIN_TOKEN from the process
  env and the plugin Registry / Bootstrap tail is a shared singleton.
  """

  use Barkpark.DataCase, async: false

  import ExUnit.CaptureIO

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Seeds
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @demo_schema_names ~w(post page author category project siteSettings navigation colors)

  # Simulate a FRESH database inside the sandbox transaction: the host's test
  # DB may carry committed demo rows from a developer's
  # `MIX_ENV=test mix ecto.reset` (which seeds the demo profile). Deletions
  # roll back with the sandbox. Memberships referencing tokens go first.
  setup do
    Repo.delete_all(
      from(m in Barkpark.Tenancy.Membership, where: m.principal_type == "api_token")
    )

    Repo.delete_all(Barkpark.Auth.ApiToken)
    Repo.delete_all(Document)
    Repo.delete_all(SchemaDefinition)
    :ok
  end

  defp run_clean do
    capture_io(fn -> Seeds.run(:clean) end)
  end

  # Mirrors Seeds.Clean.admin_token_present?/1: the seed scope's workspace is
  # the fence, and list_tokens/2 hands back secret-free maps.
  defp admin_tokens do
    Barkpark.Tenancy.get_default_workspace().id
    |> Auth.list_tokens(@dataset)
    |> Enum.filter(fn t -> is_nil(t.revoked_at) and Auth.has_permission?(t, "admin") end)
  end

  test "seeds ONLY plugin schemas + welcome paper — no demo rows, no dev token" do
    output = run_clean()

    assert output =~ "Seed profile: clean (papers + media)"
    assert output =~ "Seeded welcome paper (/papers/welcome)"

    # None of the 8 demo schemas land; whatever schema rows exist came from
    # Plugins.Bootstrap (paper, mediaAsset, … per the registered plugin set).
    seeded_names =
      SchemaDefinition
      |> where([s], s.dataset == @dataset)
      |> select([s], s.name)
      |> Repo.all()

    assert seeded_names -- @demo_schema_names == seeded_names,
           "demo schemas leaked into the clean profile: #{inspect(seeded_names)}"

    assert "paper" in seeded_names

    # The welcome paper is the ONLY document.
    docs = Repo.all(Document)
    assert [%Document{doc_id: "welcome", type: "paper"} = paper] = docs
    assert is_list(get_in(paper.content, ["blocks"]))
    assert paper.title == "Welcome to Barkpark"
    # Article typography, so /papers/welcome shows off the article palette.
    assert get_in(paper.content, ["style"]) == "article"

    # No barkpark-dev-token.
    assert {:error, :unauthorized} = Auth.verify_token("barkpark-dev-token")
  end

  test "mints a generated admin token with read/write/admin + workspace membership, bannered once" do
    output = run_clean()

    assert [token] = admin_tokens()
    assert token.label == "admin (bp setup)"
    assert Enum.sort(token.permissions) == ["admin", "read", "write"]

    # Bound to the Default workspace WITH a membership row (without it,
    # ResolveWorkspace 403s every scoped route).
    refute is_nil(token.workspace_id)
    assert TenancyAuth.member?(token.id, token.workspace_id, :api_token)

    # SECRET-FREE listing: the door must never hand back token_hash (nor any
    # other secret-bearing key). Reds if list_tokens/2 goes back to Repo.all
    # over whole %ApiToken{} structs.
    refute Map.has_key?(token, :token_hash)

    assert Map.keys(token) |> Enum.sort() ==
             ~w(dataset expires_at id inserted_at kind label last_used_at name permissions revoked_at workspace_id)a

    # The generated raw token is printed ONCE in the store-it-now banner.
    assert [_pre, raw] = Regex.run(~r/(bp_admin_[A-Za-z0-9_-]{32})/, output)
    assert {:ok, verified} = Auth.verify_token(raw)
    assert verified.id == token.id
  end

  test "BARKPARK_SEED_ADMIN_TOKEN is minted as-received and never echoed" do
    raw = "bp_admin_test_from_env_abcdefghijklmnop"
    System.put_env("BARKPARK_SEED_ADMIN_TOKEN", raw)
    on_exit(fn -> System.delete_env("BARKPARK_SEED_ADMIN_TOKEN") end)

    output = run_clean()

    assert output =~ "Admin token installed from BARKPARK_SEED_ADMIN_TOKEN (not echoed)."
    refute output =~ raw

    assert {:ok, token} = Auth.verify_token(raw)
    assert Auth.has_permission?(token, "admin")
  end

  test "second run is a no-op: mints no second token, never clobbers the paper" do
    run_clean()

    assert [token] = admin_tokens()
    paper_before = Content.get_paper("welcome", @dataset)
    rev_before = get_in(paper_before.content, ["rev"])

    output = run_clean()

    assert output =~ "Welcome paper already present — skipping."
    assert output =~ "Admin token already present — skipping token bootstrap."
    refute output =~ "bp_admin_"

    assert [^token] = admin_tokens()

    paper_after = Content.get_paper("welcome", @dataset)
    assert get_in(paper_after.content, ["rev"]) == rev_before
    assert paper_after.rev == paper_before.rev
  end
end
