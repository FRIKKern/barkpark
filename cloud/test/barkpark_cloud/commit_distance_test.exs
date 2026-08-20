defmodule BarkparkCloud.CommitDistanceTest do
  @moduledoc """
  deploy-reliability W21 (S2) — the control plane's OWN freshness verdict.

  What these tests pin, in the order the slice can regress:

    1. the four compare statuses map to their own rungs, from ONE call;
    2. every failure — empty sha, 404, 403 rate limit, transport error,
       unconfigured client — lands `"unknown"` with distance **nil, never 0**
       (muscle-1, agent offline with `git_commit: ""`, is the row that would
       otherwise sort as the freshest box in the fleet);
    3. the columns exist and read back;
    4. the write is NARROW — `health_changeset/2` and `update_status_changeset/2`
       do not cast the three fields, so an agent beat or the self-update mirror
       cannot write a freshness verdict by accident;
    5. `@update_states` is UNCHANGED (no fifth rung — a fifth rung nils the
       rollout candidate and can freeze the staging gate);
    6. `UpdateStatusWorker`'s mirror still lands when the compare client
       raises or returns an error tuple.

  No network: the HTTP client is injected in every test.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.GitHub.CommitDistance
  alias BarkparkCloud.Registry.{Barkpark, Vault}
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Workers.UpdateStatusWorker

  @served "c80168100abcdef0000000000000000000000000"
  @admin_token "instance-admin-token-plaintext"

  # A compare client that always answers `body`, recording the URLs it saw.
  defp responder(status, body) do
    test = self()

    fn req ->
      send(test, {:compare_request, req})
      {:ok, %{status: status, body: body}}
    end
  end

  defp compare_body(status, ahead_by, behind_by) do
    Jason.encode!(%{"status" => status, "ahead_by" => ahead_by, "behind_by" => behind_by})
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          host: "203.0.113.#{rem(n, 250) + 1}",
          url: "https://bp-#{n}.barkpark.cloud",
          admin_token_encrypted: Vault.encrypt(@admin_token),
          git_commit: @served
        },
        attrs
      )
    )
    |> Repo.update!()
  end

  describe "verdict/2 — the four compare statuses, from ONE call" do
    test "identical → current, distance 0, and the HEAD is the BRANCH NAME" do
      client = responder(200, compare_body("identical", 0, 0))

      assert %{ancestry: "current", distance: 0} =
               CommitDistance.verdict(@served, http_client: client)

      assert_received {:compare_request, %{method: :get, url: url}}
      assert url == "https://api.github.com/repos/FRIKKern/barkpark/compare/#{@served}...main"
      # Exactly one call — the tip is resolved server-side, never pre-fetched.
      refute_received {:compare_request, _}
    end

    test "ahead → behind by ahead_by (the four-figure case this slice exists for)" do
      client = responder(200, compare_body("ahead", 2468, 0))

      assert %{ancestry: "behind", distance: 2468} =
               CommitDistance.verdict(@served, http_client: client)
    end

    test "behind → ahead_of_main: serves code that is NOT on main, missing none" do
      client = responder(200, compare_body("behind", 0, 7))

      assert %{ancestry: "ahead_of_main", distance: 0} =
               CommitDistance.verdict(@served, http_client: client)
    end

    test "diverged → its own rung, distance = commits of main it lacks" do
      client = responder(200, compare_body("diverged", 12, 3))

      assert %{ancestry: "diverged", distance: 12} =
               CommitDistance.verdict(@served, http_client: client)
    end
  end

  describe "the unknown rung is nil, NEVER 0" do
    test "empty git_commit (muscle-1: agent offline) never reaches the wire" do
      client = responder(200, compare_body("identical", 0, 0))

      for sha <- [nil, "", "   "] do
        assert %{ancestry: "unknown", distance: distance} =
                 CommitDistance.verdict(sha, http_client: client)

        assert distance == nil
        refute distance == 0
      end

      refute_received {:compare_request, _}
    end

    test "404 on an unknown sha → unknown/nil (a garbage sha cannot read as 0)" do
      assert %{ancestry: "unknown", distance: distance} =
               CommitDistance.verdict(@served,
                 http_client: responder(404, ~s({"message":"Not Found"}))
               )

      assert distance == nil
    end

    test "403 rate limit (the shared 60/h anonymous budget) → unknown/nil" do
      assert %{ancestry: "unknown", distance: distance} =
               CommitDistance.verdict(@served,
                 http_client: responder(403, ~s({"message":"API rate limit exceeded"}))
               )

      assert distance == nil
    end

    test "transport error, raising client, junk body, unknown status, no client → unknown/nil" do
      clients = [
        fn _ -> {:error, {:http_client, :timeout}} end,
        fn _ -> raise "boom" end,
        fn _ -> {:ok, %{status: 200, body: "<html>not json</html>"}} end,
        fn _ -> {:ok, %{status: 200, body: Jason.encode!(%{"status" => "wat"})}} end,
        nil
      ]

      for client <- clients do
        assert %{ancestry: "unknown", distance: distance} =
                 CommitDistance.verdict(@served, http_client: client)

        assert distance == nil
      end
    end

    test "every rung it can return is a member of ancestries/0" do
      assert "unknown" in CommitDistance.ancestries()
      # unknown sorts FIRST — an unmeasured row is loudest, not freshest.
      assert hd(CommitDistance.ancestries()) == "unknown"
    end
  end

  describe "the three columns" do
    test "migration columns exist and read back through refresh_commit_distance/2" do
      bp = barkpark()
      client = responder(200, compare_body("ahead", 886, 0))

      assert {:ok, _} = Registry.refresh_commit_distance(bp, http_client: client)

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.commit_distance == 886
      assert reloaded.commit_ancestry == "behind"
      assert %DateTime{} = reloaded.commit_distance_checked_at
    end

    test "an offline agent's empty git_commit persists unknown/NULL, never 0" do
      bp = barkpark(%{git_commit: ""})

      assert {:ok, _} =
               Registry.refresh_commit_distance(bp,
                 http_client: responder(200, compare_body("identical", 0, 0))
               )

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.commit_ancestry == "unknown"
      assert reloaded.commit_distance == nil
    end

    test "a later unknown CLEARS a previously measured distance (no stale green)" do
      bp = barkpark()

      {:ok, _} =
        Registry.refresh_commit_distance(bp,
          http_client: responder(200, compare_body("ahead", 4, 0))
        )

      assert Registry.get_barkpark(bp.id).commit_distance == 4

      {:ok, _} =
        Registry.refresh_commit_distance(Registry.get_barkpark(bp.id),
          http_client: responder(403, ~s({"message":"rate limited"}))
        )

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.commit_ancestry == "unknown"
      assert reloaded.commit_distance == nil
    end

    test "refresh_commit_distance/2 touches update_state and nothing else" do
      bp = barkpark(%{update_state: "current", update_running_release: "0.2.25"})

      {:ok, _} =
        Registry.refresh_commit_distance(bp,
          http_client: responder(200, compare_body("ahead", 2468, 0))
        )

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.update_state == "current"
      assert reloaded.update_running_release == "0.2.25"
      assert reloaded.commit_distance == 2468
    end
  end

  describe "the write is NARROW" do
    test "health_changeset/2 cannot write a freshness verdict" do
      attrs = %{
        commit_distance: 0,
        commit_ancestry: "current",
        commit_distance_checked_at: DateTime.utc_now()
      }

      changes = Barkpark.health_changeset(%Barkpark{}, attrs).changes

      refute Map.has_key?(changes, :commit_distance)
      refute Map.has_key?(changes, :commit_ancestry)
      refute Map.has_key?(changes, :commit_distance_checked_at)
    end

    test "update_status_changeset/2 cannot write a freshness verdict" do
      attrs = %{
        update_state: "current",
        commit_distance: 0,
        commit_ancestry: "current",
        commit_distance_checked_at: DateTime.utc_now()
      }

      changes = Barkpark.update_status_changeset(%Barkpark{}, attrs).changes

      assert changes.update_state == "current"
      refute Map.has_key?(changes, :commit_distance)
      refute Map.has_key?(changes, :commit_ancestry)
      refute Map.has_key?(changes, :commit_distance_checked_at)
    end

    test "commit_distance_changeset/2 casts exactly the three, and nothing else" do
      cs =
        Barkpark.commit_distance_changeset(%Barkpark{}, %{
          commit_distance: 227,
          commit_ancestry: "behind",
          commit_distance_checked_at: DateTime.utc_now(),
          update_state: "current",
          name: "renamed",
          team_id: Ecto.UUID.generate()
        })

      assert Map.keys(cs.changes) |> Enum.sort() ==
               [:commit_ancestry, :commit_distance, :commit_distance_checked_at]
    end

    test "an out-of-range verdict is an ERROR, not a silent 0" do
      refute Barkpark.commit_distance_changeset(%Barkpark{}, %{commit_ancestry: "stale_commit"}).valid?

      refute Barkpark.commit_distance_changeset(%Barkpark{}, %{commit_distance: -1}).valid?
    end
  end

  describe "no fifth update_state rung" do
    test "@update_states is unchanged — the gates keep their meaning" do
      assert Barkpark.update_states() == ~w(unknown current behind disabled)
    end
  end

  # The worker resolves its compare client from app env (it takes no opts seam),
  # so these program it and restore afterwards. Absent an override the DEFAULT is
  # the real verified-TLS transport — no test may leave one behind.
  defp restore_env(nil), do: Application.delete_env(:barkpark_cloud, CommitDistance)
  defp restore_env(value), do: Application.put_env(:barkpark_cloud, CommitDistance, value)

  defp put_compare_client(client) do
    Application.put_env(:barkpark_cloud, CommitDistance, http_client: client)
  end

  defp check_body(state) do
    Jason.encode!(%{
      state: "idle",
      check: %{state: state, running_release: "0.2.25", latest_release: "0.2.25"}
    })
  end

  describe "UpdateStatusWorker — the mirror is untouchable" do
    setup do
      original = Application.get_env(:barkpark_cloud, CommitDistance)
      on_exit(fn -> restore_env(original) end)
      :ok
    end

    test "sweep writes the mirror AND the distance, mirror first" do
      bp = barkpark()
      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("current")}}])
      put_compare_client(responder(200, compare_body("ahead", 2468, 0)))

      assert UpdateStatusWorker.perform(%Oban.Job{args: %{"barkpark_id" => bp.id}}) == :ok

      reloaded = Registry.get_barkpark(bp.id)
      # The box's own self-grade — untouched, still "current".
      assert reloaded.update_state == "current"
      assert %DateTime{} = reloaded.update_checked_at
      # …and now contradicted by the plane's own measurement.
      assert reloaded.commit_distance == 2468
      assert reloaded.commit_ancestry == "behind"
    end

    test "a RAISING compare client never fails, skips or reorders the mirror" do
      bp = barkpark()
      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("behind")}}])
      put_compare_client(fn _ -> raise "github is on fire" end)

      assert UpdateStatusWorker.perform(%Oban.Job{args: %{"barkpark_id" => bp.id}}) == :ok

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.update_state == "behind"
      assert %DateTime{} = reloaded.update_checked_at
      assert reloaded.commit_ancestry == "unknown"
      assert reloaded.commit_distance == nil
    end

    test "an ERROR-TUPLE compare client never fails, skips or reorders the mirror" do
      bp = barkpark()
      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("behind")}}])
      put_compare_client(fn _ -> {:error, {:http_client, :nxdomain}} end)

      assert UpdateStatusWorker.perform(%Oban.Job{args: %{"barkpark_id" => bp.id}}) == :ok

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.update_state == "behind"
      assert reloaded.commit_ancestry == "unknown"
      assert reloaded.commit_distance == nil
    end

    test "the hourly sweep grades every update-checkable box" do
      bp = barkpark()
      StudioLinkFakeHttpClient.program([])
      put_compare_client(responder(200, compare_body("ahead", 592, 0)))

      assert UpdateStatusWorker.perform(%Oban.Job{}) == :ok

      assert Registry.get_barkpark(bp.id).commit_distance == 592
    end
  end
end
