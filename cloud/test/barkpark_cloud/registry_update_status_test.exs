defmodule BarkparkCloud.RegistryUpdateStatusTest do
  @moduledoc """
  isu-6 — `Registry.refresh_update_status/1`: mirror the instance's OWN
  self-update verdict (`GET /v1/admin/self-update` → the `"check"` block) onto
  the barkparks row, server-side with the stored admin token. Proves:

    * happy path: a 200 with `check.state == "behind"` persists the state, the
      running/latest releases, and a fresh `update_checked_at`; the instance
      was called with the DECRYPTED admin bearer on the right endpoint
    * pre-feature instance (404) → `{:error, :no_self_update_route}` AND the row
      is best-effort landed on `update_state: "unknown"` (releases cleared,
      checked_at stamped) — never a stale lie
    * no stored admin token → `{:error, :no_admin_token}`, same "unknown"
      landing, and the instance is never called

  cch-w58 adds the WHY: `update_state: "unknown"` collapses five worlds, so the
  verdict now lands in `update_unavailable_reason`. Proved here as a
  DISTINCTNESS property over four programmed upstream shapes (401 / 404 /
  transport failure / decodable 200) — four shapes must produce four different
  persisted verdicts — rather than as four literal equalities copied out of the
  implementation, which would pass just as happily against a table of constants.
  Plus: 404 (a pre-feature box that refused nothing) is NOT the 401 verdict, and
  a clean 200 CLEARS a previously-persisted refusal.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob, Vault}
  alias BarkparkCloud.StudioLinkFakeHttpClient

  @instance_admin_token "instance-admin-token-plaintext"
  @instance_url "https://prod.barkpark.cloud"

  ## Fixtures (mirror RouterStudioLinkTest's)

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  # A LIVE instance: url + host set, encrypted admin token stored (what the
  # provision-succeed path writes).
  defp live_barkpark(team) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
  end

  defp check_body(state) do
    Jason.encode!(%{
      state: "idle",
      exit_code: nil,
      log: [],
      check: %{
        state: state,
        running_version: "0.9.0",
        running_release: "v0.9.0",
        latest_release: "v1.2.0",
        canonical_release: "v1.2.0",
        digest: [],
        checked_at: "2026-07-02T12:00:00Z"
      }
    })
  end

  # cch-w58: drive ONE programmed upstream shape through the real transport seam
  # and return what the ROW ends up saying. Deliberately reads the persisted
  # column, not the returned atom: the point of that slice is that the verdict
  # outlives the call.
  defp persisted_reason(response) do
    # A FRESH box per shape (`barkparks.url` is uniquely indexed, so the four
    # shapes cannot share the fixture's one url) — and each verdict is therefore
    # written by its own row, not overwritten on a shared one.
    bp =
      live_barkpark(team_fixture())
      |> Ecto.Changeset.change(url: "#{@instance_url}/#{System.unique_integer([:positive])}")
      |> Repo.update!()

    StudioLinkFakeHttpClient.program([response])
    _ = Registry.refresh_update_status(bp)
    Repo.get!(Barkpark, bp.id).update_unavailable_reason
  end

  describe "refresh_update_status/1" do
    test "200 with check.state=behind → {:ok, bp} with state + releases + checked_at persisted" do
      bp = live_barkpark(team_fixture())

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("behind")}}])

      assert {:ok, %Barkpark{} = refreshed} = Registry.refresh_update_status(bp)
      assert refreshed.update_state == "behind"
      assert refreshed.update_running_release == "v0.9.0"
      assert refreshed.update_latest_release == "v1.2.0"
      assert %DateTime{} = refreshed.update_checked_at

      # Persisted, not just returned.
      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "behind"
      assert reloaded.update_latest_release == "v1.2.0"

      # The instance-side check was called correctly: GET on the admin
      # endpoint, the DECRYPTED admin token as bearer.
      assert [req] = StudioLinkFakeHttpClient.requests()
      assert req.method == :get
      assert req.url == @instance_url <> "/v1/admin/self-update"

      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(req.headers, "Authorization", 0)
    end

    test "pre-feature instance (404) → {:error, :no_self_update_route} and the row lands on unknown" do
      bp = live_barkpark(team_fixture())

      # Seed a previous verdict so the failure landing provably CLEARS it.
      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("behind")}}])
      {:ok, bp} = Registry.refresh_update_status(bp)
      assert bp.update_state == "behind"

      StudioLinkFakeHttpClient.program([{:ok, %{status: 404, body: ~s({"error":"not_found"})}}])
      assert {:error, :no_self_update_route} = Registry.refresh_update_status(bp)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "unknown"
      assert reloaded.update_running_release == nil
      assert reloaded.update_latest_release == nil
      assert %DateTime{} = reloaded.update_checked_at
    end

    test "live instance without a stored admin token → {:error, :no_admin_token}, unknown landed, instance never called" do
      bp =
        team_fixture()
        |> barkpark_fixture()
        |> Ecto.Changeset.change(url: @instance_url, host: "203.0.113.10")
        |> Repo.update!()

      StudioLinkFakeHttpClient.program([])

      assert {:error, :no_admin_token} = Registry.refresh_update_status(bp)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "unknown"

      # cch-w65 — this assertion used to read `assert %DateTime{} =
      # reloaded.update_checked_at`, two lines above the assertion that the
      # instance was never called: the suite pinned, in one breath, both that no
      # bytes left and that a check time was recorded. The clock now records a
      # check that was actually made, so there is none here.
      assert is_nil(reloaded.update_checked_at)

      assert StudioLinkFakeHttpClient.requests() == []
    end
  end

  describe "refresh_update_status/1 persists WHY the state is unknown (cch-w58)" do
    test "a 401 and a 404 are NOT the same verdict — a pre-feature box refused nothing" do
      refused = persisted_reason({:ok, %{status: 401, body: ~s({"error":"unauthorized"})}})
      pre_feature = persisted_reason({:ok, %{status: 404, body: ~s({"error":"not_found"})}})

      # Both must actually be on file...
      refute is_nil(refused)
      refute is_nil(pre_feature)

      # ...and they must be DIFFERENT. A box that never heard of the route has
      # not refused our credential, and a later slice refusing on the 401 verdict
      # must not also cut off every merely-old box (charter D684).
      refute refused == pre_feature
    end

    test "four upstream shapes produce four distinct persisted verdicts" do
      reasons = [
        # the box refuses OUR credential
        persisted_reason({:ok, %{status: 401, body: ~s({"error":"unauthorized"})}}),
        # a pre-feature box: no such route
        persisted_reason({:ok, %{status: 404, body: ~s({"error":"not_found"})}}),
        # nothing answered at all
        persisted_reason({:error, :econnrefused}),
        # a healthy box with a readable verdict
        persisted_reason({:ok, %{status: 200, body: check_body("current")}})
      ]

      # A DISTINCTNESS property, not four equalities copied from the
      # implementation: four different worlds upstream must not read as the same
      # thing downstream. Four literal assertions would pass just as happily
      # against a lookup table of constants; this cannot.
      assert length(Enum.uniq(reasons)) == 4
    end

    test "a decodable 200 CLEARS a previously persisted refusal" do
      bp = live_barkpark(team_fixture())

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 401, body: ~s({"error":"unauthorized"})}}
      ])

      assert {:error, :identity_refused} = Registry.refresh_update_status(bp)
      assert Repo.get!(Barkpark, bp.id).update_unavailable_reason == "identity_refused"

      # The box recovers — the credential works again.
      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("current")}}])
      assert {:ok, _} = Registry.refresh_update_status(bp)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "current"
      # A stale accusation must not outlive the recovery.
      assert is_nil(reloaded.update_unavailable_reason)
    end

    test "every reason the refresh can persist is inside the changeset whitelist" do
      # If a future arm hands persist_update_unknown/2 an atom outside
      # update_unavailable_reasons/0, validate_inclusion rejects it and the
      # best-effort write silently drops the verdict — leaving the row's OLD
      # reason on file, which is worse than none. This pins the vocabulary.
      for reason <- ~w(identity_refused forbidden no_self_update_route unreachable bad_shape
                       instance_error no_admin_token decrypt_failed not_live) do
        assert reason in Barkpark.update_unavailable_reasons()
      end
    end

    test "the vocabulary has no word nothing can write — every rung has a producer" do
      # The mirror of the test above. A whitelist entry with no writer reads as
      # a state the plane can reach and cannot, which is the same class of lie
      # this slice exists to remove (cch-w58 review).
      producers =
        ~w(identity_refused forbidden no_self_update_route unreachable bad_shape
           instance_error no_admin_token decrypt_failed not_live)

      assert Enum.sort(Barkpark.update_unavailable_reasons()) == Enum.sort(producers)
    end

    test "a 200 we cannot read is a DIFFERENT verdict from a box that errored" do
      unreadable = persisted_reason({:ok, %{status: 200, body: ~s({"nope":true})}})
      errored = persisted_reason({:ok, %{status: 500, body: "boom"}})

      refute is_nil(unreadable)
      refute is_nil(errored)
      refute unreadable == errored
    end
  end

  describe "the clock records a check that was actually MADE (cch-w65)" do
    # Three of the nine unknown rungs return BEFORE a request is ever built —
    # no bytes leave the control plane, so there is no check whose time could be
    # recorded. Stamping one is the plane inventing evidence about a box it
    # never spoke to, and the console shipped a client-side apology
    # (`UPDATE_REFUSAL_UNCLOCKED`) to teach the browser which three server rungs
    # to disbelieve. A compensating reader is a patch; a column that stops lying
    # is the fix.

    test "no stored admin token → the row carries NO check time, because no check was made" do
      bp =
        team_fixture()
        |> barkpark_fixture()
        |> Ecto.Changeset.change(url: @instance_url, host: "203.0.113.10")
        |> Repo.update!()

      StudioLinkFakeHttpClient.program([])

      assert {:error, :no_admin_token} = Registry.refresh_update_status(bp)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "unknown"
      assert reloaded.update_unavailable_reason == "no_admin_token"
      assert is_nil(reloaded.update_checked_at)
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "a tampered admin token → the row carries NO check time, because no check was made" do
      bp =
        team_fixture()
        |> barkpark_fixture()
        |> Ecto.Changeset.change(
          url: @instance_url,
          host: "203.0.113.10",
          admin_token_encrypted: "not-a-ciphertext"
        )
        |> Repo.update!()

      StudioLinkFakeHttpClient.program([])

      assert {:error, :decrypt_failed} = Registry.refresh_update_status(bp)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "unknown"
      assert reloaded.update_unavailable_reason == "decrypt_failed"
      assert is_nil(reloaded.update_checked_at)
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "a box that is not live → the row carries NO check time, because no check was made" do
      bp = barkpark_fixture(team_fixture())

      StudioLinkFakeHttpClient.program([])

      assert {:error, :not_live} = Registry.refresh_update_status(bp)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "unknown"
      assert reloaded.update_unavailable_reason == "not_live"
      assert is_nil(reloaded.update_checked_at)
      assert StudioLinkFakeHttpClient.requests() == []
    end

    # The two MIRRORS. The fix is "do not record a check that never happened",
    # NOT "never record a check on unknown" — every rung reached THROUGH the
    # transport asked a real question and got a real (useless) answer, and the
    # hour at which we asked is true. Without these two, the fix degenerates.
    test "MIRROR — a 401 asked a real question, so the clock IS stamped" do
      bp = live_barkpark(team_fixture())

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 401, body: ~s({"error":"unauthorized"})}}
      ])

      assert {:error, :identity_refused} = Registry.refresh_update_status(bp)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "unknown"
      assert %DateTime{} = reloaded.update_checked_at
      assert [_req] = StudioLinkFakeHttpClient.requests()
    end

    test "MIRROR — a transport failure asked a real question, so the clock IS stamped" do
      bp = live_barkpark(team_fixture())

      StudioLinkFakeHttpClient.program([{:error, :econnrefused}])

      assert {:error, :unreachable} = Registry.refresh_update_status(bp)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "unknown"
      assert %DateTime{} = reloaded.update_checked_at
      assert [_req] = StudioLinkFakeHttpClient.requests()
    end

    # OMIT, not an explicit NULL (charter D789). A box that answered honestly an
    # hour ago and has since lost its `url` still has a true last-checked time;
    # writing `nil` would erase it and trade one lie for another. Only this test
    # discriminates the two shapes — the three rung tests above pass under both,
    # because a fresh row's clock is NULL to begin with.
    test "a box that answered honestly and later goes dark KEEPS its historical clock" do
      bp = live_barkpark(team_fixture())

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("behind")}}])
      assert {:ok, checked} = Registry.refresh_update_status(bp)
      assert %DateTime{} = honest_clock = checked.update_checked_at

      # The box loses its url — the plane can no longer ask.
      dark = checked |> Ecto.Changeset.change(url: nil) |> Repo.update!()
      assert {:error, :not_live} = Registry.refresh_update_status(dark)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "unknown"
      assert reloaded.update_checked_at == honest_clock
    end
  end

  describe "the ARMING probe rides the same 200 (apply_enabled, #12995)" do
    # `apply_enabled` is a SIBLING of `"check"` at the top level of the body, and
    # the old match named only `"check"`, so the bytes arrived every hour and
    # were discarded AT THE MATCH.
    #
    # THE WHOLE POINT IS THAT ABSENT IS NOT FALSE. A pre-#12995 box sends no such
    # key and may well be armed; mapping absence to "unarmed" would render it
    # identical to a MEASURED unarmed box and put correctly-armed boxes on the
    # retro-arm worklist — which is worse than having no worklist. Every test
    # below is written so that collapse REDS it.

    # The same envelope `check_body/1` builds, plus the sibling key. Passing
    # `:absent` returns a body WITHOUT it — a pre-#12995 box, byte for byte.
    defp arming_body(:absent), do: check_body("current")

    defp arming_body(apply_enabled) do
      check_body("current")
      |> Jason.decode!()
      |> Map.put("apply_enabled", apply_enabled)
      |> Jason.encode!()
    end

    # Drive ONE programmed 200 through the real transport seam and return what
    # the ROW ends up saying — the persisted column, never the returned struct,
    # because the roster is read back out of the table hours later.
    defp persisted_arming(body) do
      bp =
        live_barkpark(team_fixture())
        |> Ecto.Changeset.change(url: "#{@instance_url}/#{System.unique_integer([:positive])}")
        |> Repo.update!()

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: body}}])
      _ = Registry.refresh_update_status(bp)
      Repo.get!(Barkpark, bp.id).apply_arming
    end

    test "a body WITHOUT the key and a body with `false` are TWO DIFFERENT stored values" do
      # Both arms in ONE test on purpose. Two assertions that both pass on the
      # same fixture prove nothing; the claim is a DISCRIMINATION, so both
      # fixtures have to be present for either assertion to mean anything.
      armed = persisted_arming(arming_body(true))
      unarmed = persisted_arming(arming_body(false))
      unmeasured = persisted_arming(arming_body(:absent))

      assert armed == "armed"

      assert unarmed == "unarmed",
             "a MEASURED false is the retro-arm worklist — the box will 503 the " <>
               "moment the rollout reaches it. Got: #{inspect(unarmed)}"

      assert is_nil(unmeasured),
             "a pre-#12995 box sends no apply_enabled key and may be perfectly " <>
               "armed; NULL is the third state. Got: #{inspect(unmeasured)}"

      refute unmeasured == unarmed,
             "THE COLLAPSE THIS COLUMN EXISTS TO PREVENT: an unmeasured box and a " <>
               "measured-unarmed box now read the same, so every pre-#12995 box " <>
               "lands on the retro-arm worklist and the roster is worthless."

      # Three upstream worlds, three persisted values — a property, not three
      # equalities copied out of the implementation.
      assert length(Enum.uniq([armed, unarmed, unmeasured])) == 3
    end

    test "a non-boolean apply_enabled fails CLOSED to unmeasured, never into a verdict" do
      # Same posture as `check["state"]`, which is whitelisted down to "unknown"
      # rather than trusting a weird instance into a rendering state. An operator
      # acts on this column, so a shape we cannot read must not become a word.
      for junk <- [nil, "true", "false", 1, 0, %{"enabled" => true}, []] do
        assert is_nil(persisted_arming(arming_body(junk))),
               "apply_enabled=#{inspect(junk)} is not a boolean and must land unmeasured"
      end
    end

    test "every word the refresh can persist is inside the changeset whitelist" do
      # The mirror of the reason-vocabulary pins above: a value outside
      # `apply_armings/0` would be rejected by validate_inclusion and the
      # best-effort write would silently drop it, leaving the row's OLD arming on
      # file — a stale roster, which is worse than an empty one.
      for word <- ~w(armed unarmed), do: assert(word in Barkpark.apply_armings())
      assert Enum.sort(Barkpark.apply_armings()) == Enum.sort(~w(armed unarmed))

      # And "unknown" is NOT a word here. It is the ABSENCE of one — a
      # `validate_inclusion` that admitted it would invite a writer to store it,
      # and a column with three words has no NULL left to mean "never asked".
      refute "unknown" in Barkpark.apply_armings()
    end

    test "the arming clock is stamped ONLY when a body was actually decoded" do
      # `update_checked_at` is stamped on six rungs that never read a body, so it
      # cannot say when the ARMING question was last answered. This column can,
      # and only because nothing but the 200 path writes it.
      bp = live_barkpark(team_fixture())

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 401, body: ~s({"error":"unauthorized"})}}
      ])

      assert {:error, :identity_refused} = Registry.refresh_update_status(bp)
      refused = Repo.get!(Barkpark, bp.id)
      assert %DateTime{} = refused.update_checked_at, "the 401 asked a real question"

      assert is_nil(refused.apply_arming_checked_at),
             "a 401 carries no body to read an arming out of — stamping it would " <>
               "be the plane inventing evidence about a question it never got an answer to"

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: arming_body(false)}}])
      assert {:ok, _} = Registry.refresh_update_status(bp)

      measured = Repo.get!(Barkpark, bp.id)
      assert measured.apply_arming == "unarmed"
      assert %DateTime{} = measured.apply_arming_checked_at
    end

    test "a box that goes dark KEEPS its measured arming — an outage must not empty the roster" do
      bp = live_barkpark(team_fixture())

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: arming_body(false)}}])
      assert {:ok, _} = Registry.refresh_update_status(bp)
      measured_at = Repo.get!(Barkpark, bp.id).apply_arming_checked_at

      # Now every failure rung in turn — none of them may touch the two columns.
      for response <- [
            {:ok, %{status: 401, body: ~s({"e":1})}},
            {:ok, %{status: 403, body: ~s({"e":1})}},
            {:ok, %{status: 404, body: ""}},
            {:ok, %{status: 500, body: "boom"}},
            {:ok, %{status: 200, body: ~s({"nope":true})}},
            {:error, :econnrefused}
          ] do
        StudioLinkFakeHttpClient.program([response])
        _ = Registry.refresh_update_status(Repo.get!(Barkpark, bp.id))

        reloaded = Repo.get!(Barkpark, bp.id)

        assert reloaded.apply_arming == "unarmed",
               "#{inspect(response)} erased a real measurement — a box that stops " <>
                 "answering has not become unmeasured, and an operator reaching for " <>
                 "the roster mid-outage would find it empty"

        assert reloaded.apply_arming_checked_at == measured_at
      end
    end

    test "a box ROLLED BACK below the feature loses its stale arming, not the other way round" do
      # The direction the `force_change` exists for: the box stops sending the
      # key, so the honest write is "unarmed" -> NULL (unmeasured). A cast that
      # skipped the no-op would leave the stale word standing on the roster, and
      # this is the only test that discriminates the two shapes.
      bp = live_barkpark(team_fixture())

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: arming_body(false)}}])
      assert {:ok, measured} = Registry.refresh_update_status(bp)
      assert measured.apply_arming == "unarmed"

      # Same struct, now handed back to the refresh (the router's fire-and-forget
      # kick and the workers both re-read, but a carried struct is the shape this
      # guards).
      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: arming_body(:absent)}}])
      assert {:ok, _} = Registry.refresh_update_status(measured)

      assert is_nil(Repo.get!(Barkpark, bp.id).apply_arming),
             "the box no longer reports arming, so the row must stop claiming to know it"
    end

    test "a STALE carried struct cannot strand a word on the roster (the force_change insurance)" do
      # HONEST SCOPE, stated the way charter D717 stated it for the sibling
      # column: no production caller produces this shape today — the router's
      # kick re-reads via `get_barkpark/1` and both workers hand over a freshly
      # read row — so this pins the INSURANCE, not a live path. It is the only
      # test that discriminates `force_change` from a plain `cast`, and without
      # it that line would be unfalsifiable decoration.
      bp = live_barkpark(team_fixture())

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: arming_body(false)}}])
      assert {:ok, measured} = Registry.refresh_update_status(bp)
      assert Repo.get!(Barkpark, bp.id).apply_arming == "unarmed"

      # A struct read BEFORE that write landed: in-memory nil, row "unarmed".
      # `cast(nil)` emits no change against it, so only a forced change can
      # reach the column.
      stale = %{measured | apply_arming: nil}

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: arming_body(:absent)}}])
      assert {:ok, _} = Registry.refresh_update_status(stale)

      assert is_nil(Repo.get!(Barkpark, bp.id).apply_arming),
             "the row still claims an arming the box has stopped reporting — a stale " <>
               "word on the retro-arm roster is worse than an empty one"
    end

    test "the arming write stays inside the narrow changeset — it cannot rename a box" do
      cs =
        Barkpark.update_status_changeset(%Barkpark{}, %{
          apply_arming: "unarmed",
          apply_arming_checked_at: DateTime.utc_now(),
          name: "renamed",
          team_id: Ecto.UUID.generate(),
          commit_distance: 0
        })

      assert cs.changes.apply_arming == "unarmed"
      refute Map.has_key?(cs.changes, :name)
      refute Map.has_key?(cs.changes, :team_id)
      refute Map.has_key?(cs.changes, :commit_distance)

      # And a word outside the vocabulary is a changeset ERROR, not a silent
      # write — the roster never carries an invented state.
      refute Barkpark.update_status_changeset(%Barkpark{}, %{apply_arming: "maybe"}).valid?
    end
  end

  describe "the hourly sweep FILES the repair, it does not merely RECORD it (isu-w5)" do
    # THE GAP THIS CLOSES. `record_apply_unarmed/1` — the rollout worker's 503
    # branch — had its auto-enqueue pinned by enable_apply_jobs_test.exs. The
    # OTHER writer of the same measurement, `refresh_update_status/1`'s hourly
    # `UpdateStatusWorker` sweep, did not: deleting `|> auto_enqueue_on_unarmed(arming)`
    # from the end of `persist_update_check/3` left the whole suite GREEN. That
    # is the site that matters most, because the sweep is the ONLY writer that
    # reaches a box the rollout never picks — the retro-arm cohort's boxes are
    # measured unarmed and then DISQUALIFIED from `next_autoupdate_candidate/1`,
    # so the 503 branch can never fire on them again. Without the sweep's
    # enqueue, an unarmed box is recorded forever and repaired never.
    #
    # Asserted on the JOB ROW, not on a returned value: the rail is a queue the
    # provisioner drains minutes later, so the only thing that matters is what
    # is in the table when the sweep returns.

    defp swept(body, overrides) do
      bp =
        live_barkpark(team_fixture())
        |> Ecto.Changeset.change(
          Map.merge(%{url: "#{@instance_url}/#{System.unique_integer([:positive])}"}, overrides)
        )
        |> Repo.update!()

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: body}}])
      _ = Registry.refresh_update_status(bp)
      bp
    end

    test "a consented box the sweep reads UNARMED gets its enable_apply job FILED" do
      bp = swept(arming_body(false), %{autoupdate_enabled: true, suspended: false})

      assert Repo.get!(Barkpark, bp.id).apply_arming == "unarmed",
             "precondition: the sweep must have measured the box unarmed"

      assert [%ProvisionJob{kind: "enable_apply", status: "pending", barkpark_id: filed_for}] =
               Repo.all(ProvisionJob),
             "the hourly sweep is the only writer that reaches a DISQUALIFIED box — " <>
               "recording unarmed without filing the repair strands it forever"

      assert filed_for == bp.id
    end

    test "an ARMED sweep files nothing — only an unarmed measurement is a repair" do
      bp = swept(arming_body(true), %{autoupdate_enabled: true, suspended: false})

      assert Repo.get!(Barkpark, bp.id).apply_arming == "armed"
      assert Repo.aggregate(ProvisionJob, :count) == 0
    end

    test "an UNMEASURED (pre-#12995) sweep files nothing — absent is not false" do
      bp = swept(arming_body(:absent), %{autoupdate_enabled: true, suspended: false})

      assert is_nil(Repo.get!(Barkpark, bp.id).apply_arming)

      assert Repo.aggregate(ProvisionJob, :count) == 0,
             "a box that sent no apply_enabled key may be perfectly armed; SSHing " <>
               "into it on an absent key is the collapse the third state prevents"
    end

    test "an opted-OUT box is still RECORDED unarmed but never enqueued (the consent gate)" do
      bp = swept(arming_body(false), %{autoupdate_enabled: false, suspended: false})

      assert Repo.get!(Barkpark, bp.id).apply_arming == "unarmed",
             "the measurement is a fact and is written regardless of consent"

      assert Repo.aggregate(ProvisionJob, :count) == 0
    end

    test "two consecutive unarmed sweeps stay ONE job — the hourly re-report does not pile up" do
      bp =
        live_barkpark(team_fixture())
        |> Ecto.Changeset.change(
          url: "#{@instance_url}/#{System.unique_integer([:positive])}",
          autoupdate_enabled: true
        )
        |> Repo.update!()

      for _ <- 1..2 do
        StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: arming_body(false)}}])
        _ = Registry.refresh_update_status(bp)
      end

      assert Repo.aggregate(ProvisionJob, :count) == 1
    end

    test "an enqueue failure NEVER masks the measurement the sweep persisted" do
      # The job insert is refused by the one-active-per-kind guard (a job is
      # already in flight), and the sweep must still return {:ok, _} with the
      # arming written — a control-plane queue fault cannot cost us the reading.
      bp =
        live_barkpark(team_fixture())
        |> Ecto.Changeset.change(
          url: "#{@instance_url}/#{System.unique_integer([:positive])}",
          autoupdate_enabled: true
        )
        |> Repo.update!()

      {:ok, _} = Registry.enqueue_enable_apply_job(bp)

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: arming_body(false)}}])
      assert {:ok, %Barkpark{apply_arming: "unarmed"}} = Registry.refresh_update_status(bp)
      assert Repo.aggregate(ProvisionJob, :count) == 1
    end
  end
end
