defmodule Barkpark.Tasks.DispositionOwnerRegistryLockTest do
  @moduledoc """
  THE LOCK between `tooling/pds/disposition-owner-registry.json` (PR #17836)
  and the role list `Barkpark.Tasks.Stage` screens a `disposition_owner` write
  against — the api half of pds-bl-disposition-owner-role-registry.

  A hand-copied Elixir list beside a JSON registry is an UNLOCKED MIRROR: the
  two drift the day a role is onboarded, and nothing reds. `Stage` therefore
  reads the JSON at COMPILE time (`@external_resource`), and this file decodes
  the same file INDEPENDENTLY and asserts term identity in BOTH directions —
  edit one side only and a test here fails.

  ## It asserts something in the fail-closed build too

  The registry is not on `main` until #17836 merges. A test that merely skipped
  itself when the file is absent would be a green with no subject, so the
  absent branch asserts the OTHER half of the contract instead: the role set is
  EMPTY and every owner write is refused. An absent registry must never read as
  "every owner is legal".
  """

  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Stage

  @registry_path Path.expand(
                   "../../../../tooling/pds/disposition-owner-registry.json",
                   __DIR__
                 )

  test "Stage compiled against the registry path this test reads" do
    # A path typo would make every identity assertion below vacuous — both
    # sides would agree on nothing, forever.
    assert Stage.owner_registry_path() == @registry_path
  end

  describe "with the registry present (PR #17836 landed or the file is local)" do
    @describetag :registry
    setup do
      if File.exists?(@registry_path) do
        %{registry: Jason.decode!(File.read!(@registry_path))}
      else
        {:ok, skip_absent: true}
      end
    end

    test "the durable-role slugs are term-identical, in both directions", ctx do
      unless ctx[:skip_absent] do
        from_json =
          ctx.registry
          |> Map.fetch!("roles")
          |> Enum.filter(&(&1["class"] == "durable-role"))
          |> Enum.map(& &1["slug"])
          |> Enum.sort()

        # A registry with no durable roles would make the identity below true
        # and meaningless — print the key set before trusting an empty read.
        refute from_json == [],
               "the registry decoded ZERO durable roles; this assertion would be vacuous"

        assert Stage.durable_owner_roles() == from_json,
               "Stage's role list and #{@registry_path} have DIVERGED.\n" <>
                 "only in Stage: #{inspect(Stage.durable_owner_roles() -- from_json)}\n" <>
                 "only in JSON:  #{inspect(from_json -- Stage.durable_owner_roles())}"

        assert Stage.owner_registry_loaded?()
      end
    end

    test "the expiring-owner pattern is the registry's, not a retyped one", ctx do
      unless ctx[:skip_absent] do
        assert Stage.expiring_owner_pattern() ==
                 get_in(ctx.registry, ["expiring_owner_ruling", "pattern"])
      end
    end

    test "every durable role passes the screen and every refused entry fails it", ctx do
      unless ctx[:skip_absent] do
        for slug <- Stage.durable_owner_roles() do
          assert Stage.owner_refusal_code(slug) == nil, "#{slug} is a registered role"
        end

        for entry <- Map.get(ctx.registry, "refused", []) do
          assert Stage.owner_refusal_code(entry["slug"]) != nil,
                 "#{entry["slug"]} is listed refused (#{entry["class"]}) but the screen accepts it"
        end
      end
    end

    test "a wave-N slug is refused BEFORE membership is consulted", ctx do
      unless ctx[:skip_absent] do
        # The registry's ruling: `is_expiring_owner()` is checked FIRST, so a
        # wave slug is refused even if someone adds it to roles[].
        assert Stage.owner_refusal_code("wave-24") == :expiring_owner
        assert Stage.owner_refusal_code("wave-9999") == :expiring_owner
      end
    end
  end

  describe "with the registry absent (the fail-closed build)" do
    test "the role set is empty and every owner is refused, never accepted" do
      if File.exists?(@registry_path) do
        assert Stage.owner_registry_loaded?()
      else
        refute Stage.owner_registry_loaded?()
        assert Stage.durable_owner_roles() == []

        # The property that matters: fail CLOSED. Even a slug that IS a role in
        # the registry is refused by a build that never read the registry.
        assert Stage.owner_refusal_code("pds-harness-maintainer") == :unregistered
        assert Stage.owner_refusal_code("anything-at-all") == :unregistered
      end
    end
  end

  describe "the screen's shape arms, which hold in either build" do
    test "the wave-N shape is refused" do
      assert Stage.owner_refusal_code("wave-24") == :expiring_owner
      assert Stage.owner_refusal_code("wave-0") == :expiring_owner
    end

    test "a near-miss of the wave shape is NOT caught by the expiring arm" do
      # `wave-two` is not the ruled shape; it is refused as unregistered, and
      # the refusal code is what the 422 copy branches on.
      assert Stage.owner_refusal_code("wave-two") == :unregistered
    end

    test "a ledger task id in the owner slot is refused as a task id" do
      assert Stage.owner_refusal_code("task-8ae44aede5a78260") == :task_id_shape
    end

    test "a non-string owner is refused rather than crashing the door" do
      assert Stage.owner_refusal_code(%{"slug" => "x"}) == :not_a_string
      assert Stage.owner_refusal_code(42) == :not_a_string
    end
  end
end
