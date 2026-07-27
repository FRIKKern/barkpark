defmodule Barkpark.CycleReleaseGateHostileAdapter do
  @behaviour Barkpark.CycleFleet.ReleaseCaptureAdapter

  alias Barkpark.CycleFleet.ReleaseGate.PaperCandidate
  alias Barkpark.Repo

  @candidate_link_href "https://evidence.example/papers/candidate"
  @candidate_link_label "Open candidate evidence"
  @surfaces ~w(source_json public_html cli task_board tui)

  @impl true
  def capture(request) do
    captures =
      for role <- ~w(campaign successor), surface <- @surfaces, into: %{} do
        candidate_id = get_in(request, ["candidates", role, "candidate_id"])
        candidate = Repo.get!(PaperCandidate, candidate_id)
        name = "#{role}.#{surface}"
        {name, capture(request, candidate, role, surface)}
      end

    case Application.get_env(:barkpark, :cycle_release_capture_test_mode, :valid) do
      :valid ->
        {:ok, captures}

      :missing_capture ->
        {:ok, Map.delete(captures, "successor.tui")}

      :candidate_drift ->
        {:ok,
         put_in(captures, ["campaign.cli", :provenance, :candidate_id], Ecto.UUID.generate())}

      :header_drift ->
        {:ok,
         put_in(
           captures,
           ["successor.source_json", :provenance, :response_headers, :x_barkpark_wave_revision],
           Ecto.UUID.generate()
         )}

      :capture_failure ->
        {:error, {:credential_detail, "must-never-be-persisted"}}
    end
  end

  def public_smoke(request) do
    attempts =
      Enum.map(request["documents"], fn document ->
        %{
          "role" => document["role"],
          "document_id" => document["document_id"],
          "doc_id" => document["doc_id"],
          "url" => document["url"],
          "status" => 200,
          "redirect_count" => 0,
          "response_headers" => %{
            "content_type" => "text/html; charset=utf-8",
            "etag" => ~s("sha256:#{document["content_digest"]}"),
            "x_barkpark_paper_revision" => document["revision_id"]
          },
          "byte_count" => 256,
          "response_digest" => digest("#{document["role"]}-public-reader"),
          "deployment_digest" => request["deployment_digest"],
          "verdict" => "pass"
        }
      end)

    case Application.get_env(:barkpark, :cycle_release_capture_test_mode, :valid) do
      :public_smoke_fail ->
        {:error,
         %{
           "format" => "cycle-release-public-smoke-v1",
           "attempts" => put_in(attempts, [Access.at(1), "verdict"], "fail")
         }}

      :public_smoke_unavailable ->
        {:error, :public_release_smoke_unavailable}

      _ ->
        {:ok, %{"format" => "cycle-release-public-smoke-v1", "attempts" => attempts}}
    end
  end

  defp capture(request, candidate, role, surface) do
    raw = raw_bytes(request, candidate, role, surface)
    headless = headless_provenance(surface, request, role)

    %{
      producer: producer(surface),
      raw_bytes: raw,
      provenance:
        Map.merge(
          %{
            release_gate_id: request["release_gate_id"],
            wave_revision: request["wave_revision"],
            candidate_id: candidate.id,
            role: role,
            surface: surface,
            request: capture_request(request, role, surface),
            status: if(surface in ~w(source_json public_html), do: 200, else: 0),
            redirect_count: 0,
            deployment_digest: request["deployment_digest"],
            binary_digest: digest("#{surface}-binary-v1"),
            parser_digest: digest("portable-doc-parser-v1"),
            response_headers: %{
              etag: ~s("sha256:#{candidate.content_digest}"),
              x_barkpark_release_gate: request["release_gate_id"],
              x_barkpark_wave_revision: request["wave_revision"],
              x_barkpark_paper_candidate: candidate.id,
              x_barkpark_paper_role: role
            }
          },
          headless
        )
    }
  end

  defp headless_provenance(surface, request, role) when surface in ~w(cli task_board tui) do
    {geometry, theme, profile} =
      case surface do
        "cli" -> {"120xunbounded", "evergreen-dark", "none"}
        "task_board" -> {"120xunbounded", "task-board-dark", "ansi256"}
        "tui" -> {"120xunbounded;measure=100", "evergreen-dark", "ansi256"}
      end

    %{
      argv: get_in(request, ["readers", role, surface, "argv"]),
      geometry: geometry,
      theme: theme,
      profile: profile
    }
  end

  defp headless_provenance(_surface, _request, _role), do: %{}

  defp raw_bytes(request, candidate, role, "source_json") do
    Jason.encode!(%{
      release_gate_id: request["release_gate_id"],
      wave_revision: request["wave_revision"],
      candidate_id: candidate.id,
      role: role,
      document_id: candidate.document_id,
      doc_id: candidate.doc_id,
      title: candidate.title,
      content_digest: candidate.content_digest,
      source: %{"kind" => "blocks", "blocks" => candidate.content["blocks"]}
    })
  end

  defp raw_bytes(_request, candidate, _role, "public_html") do
    Barkpark.PortableDoc.Render.render_blocks(candidate.content["blocks"], %{})
  end

  defp raw_bytes(_request, candidate, role, surface) do
    "#{candidate.title} #{surface} release reader role=#{role} " <>
      "503 total 42 shipped 291 stalled 170 excluded current superseded -11 +11 " <>
      "#{@candidate_link_label} #{@candidate_link_href}"
  end

  defp capture_request(request, role, surface) do
    get_in(request, ["readers", role, surface])
  end

  defp producer(surface) when surface in ~w(source_json public_html), do: "server_http"
  defp producer(surface) when surface in ~w(cli task_board), do: "server_cli"
  defp producer("tui"), do: "server_tui"

  defp digest(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end

defmodule Barkpark.CycleReleaseGateHostileTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.{Document, Revision}
  alias Barkpark.CycleFleet
  alias Barkpark.CycleFleet.{AssignmentTask, Wave}
  alias Barkpark.CycleFleet.Promotion.{Event, PublicSmoke}
  alias Barkpark.CycleFleet.Quarantine
  alias Barkpark.CycleFleet.ReleaseGate.{Capture, Challenge, Consumption, PaperCandidate}
  alias Barkpark.EpicFleet.Result
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @candidate_link_href "https://evidence.example/papers/candidate"
  @candidate_link_label "Open candidate evidence"
  @capture_names for role <- ~w(campaign successor),
                     surface <- ~w(source_json public_html cli task_board tui),
                     do: "#{role}.#{surface}"

  setup do
    previous_adapter = Application.get_env(:barkpark, :cycle_release_capture_adapter)
    previous_mode = Application.get_env(:barkpark, :cycle_release_capture_test_mode)
    previous_deployment = Application.get_env(:barkpark, :release_deployment_digest)

    Application.put_env(
      :barkpark,
      :cycle_release_capture_adapter,
      Barkpark.CycleReleaseGateHostileAdapter
    )

    Application.put_env(:barkpark, :cycle_release_capture_test_mode, :valid)
    Application.put_env(:barkpark, :release_deployment_digest, String.duplicate("a", 64))

    on_exit(fn ->
      restore_env(:cycle_release_capture_adapter, previous_adapter)
      restore_env(:cycle_release_capture_test_mode, previous_mode)
      restore_env(:release_deployment_digest, previous_deployment)
    end)

    :ok
  end

  test "release candidate HTML escapes executable markup before the controller emits it" do
    html =
      Barkpark.PortableDoc.Render.render_blocks(
        [
          %{
            "type" => "paragraph",
            "text" => "<script>alert('release')</script><img src=x onerror=alert(1)>"
          }
        ],
        %{}
      )

    assert html =~ "&lt;script&gt;alert"
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute html =~ "<script>"
    refute html =~ "<img src=x"
  end

  test "open and activate are exact replays and ten captures bind both immutable candidates" do
    fixture = release_fixture!()

    assert {:ok, open_replay} = admit_open(fixture, fixture.open_key)
    assert open_replay.id == fixture.open_gate.id

    drift_scope = %{fixture.target_scope | wave_id: "foreign-successor"}

    assert {:error, :release_gate_conflict} =
             CycleFleet.admit_open_release_gate(drift_scope, %{
               target_wave_id: drift_scope.wave_id,
               idempotency_key: fixture.open_key,
               correction_of: fixture.correction,
               correction_of_digest: CycleFleet.digest(fixture.correction)
             })

    assert {:ok, campaign} = stage_candidate(fixture, "campaign", fixture.campaign_document)

    assert {:error, :invalid_activate_release_gate} = activate(fixture, "activate-one-role")

    assert {:ok, campaign_replay} =
             stage_candidate(fixture, "campaign", fixture.campaign_document)

    assert campaign_replay.id == campaign.id

    assert {:error, :paper_candidate_conflict} =
             stage_candidate(fixture, "campaign", fixture.successor_document)

    assert {:ok, successor} = stage_candidate(fixture, "successor", fixture.successor_document)
    refute campaign.id == successor.id
    refute campaign.document_id == successor.document_id

    base = Repo.get!(Document, fixture.campaign_document.id)

    Repo.update_all(from(d in Document, where: d.id == ^base.id),
      set: [rev: Ecto.UUID.generate()]
    )

    assert {:error, :invalid_activate_release_gate} = activate(fixture, "activate-pointer-drift")
    restore_document!(base)

    failed_challenge_ids =
      for mode <- [:missing_capture, :candidate_drift, :header_drift, :capture_failure] do
        Application.put_env(:barkpark, :cycle_release_capture_test_mode, mode)
        assert {:error, _reason} = activate(fixture, "activate-hostile-#{mode}")

        challenge =
          Repo.one!(
            from challenge in Challenge,
              where: challenge.target_wave_id == ^fixture.target.id,
              order_by: [desc: challenge.inserted_at],
              limit: 1
          )

        assert challenge.failed_at

        assert challenge.failure ==
                 if(mode == :capture_failure, do: "capture_failed", else: "finalize_failed")

        refute inspect(challenge) =~ "must-never-be-persisted"
        challenge.id
      end

    assert Enum.uniq(failed_challenge_ids) == failed_challenge_ids

    Application.put_env(:barkpark, :release_deployment_digest, String.duplicate("b", 64))

    Application.put_env(:barkpark, :cycle_release_capture_test_mode, :valid)
    assert {:ok, activation} = activate(fixture, fixture.activate_key)
    assert activation.stage == "activate"
    assert activation.target_wave_id == fixture.target.id

    assert Repo.get!(Challenge, activation.challenge_id).request["deployment_digest"] ==
             String.duplicate("b", 64)

    assert activation.receipt["papers"] |> Enum.map(& &1["role"]) == ~w(campaign successor)

    assert Enum.sort(Map.keys(activation.receipt["captures"])) == Enum.sort(@capture_names)
    challenge_id = activation.challenge_id
    captures = Repo.all(from c in Capture, where: c.challenge_id == ^challenge_id)
    assert Enum.sort(Enum.map(captures, & &1.name)) == Enum.sort(@capture_names)

    candidates = %{"campaign" => campaign, "successor" => successor}

    for capture <- captures do
      [role, surface] = String.split(capture.name, ".", parts: 2)
      candidate = candidates[role]
      provenance = capture.provenance
      assert provenance["release_gate_id"] == fixture.open_gate.id
      assert provenance["wave_revision"] == fixture.target.id
      assert provenance["candidate_id"] == candidate.id
      assert provenance["role"] == role
      assert provenance["surface"] == surface
      assert provenance["redirect_count"] == 0

      assert get_in(provenance, ["response_headers", "x_barkpark_release_gate"]) ==
               fixture.open_gate.id

      assert get_in(provenance, ["response_headers", "x_barkpark_wave_revision"]) ==
               fixture.target.id

      assert get_in(provenance, ["response_headers", "x_barkpark_paper_candidate"]) ==
               candidate.id

      assert get_in(provenance, ["response_headers", "x_barkpark_paper_role"]) == role
      assert capture.byte_count == byte_size(capture.raw_bytes)
      assert_candidate_link_parity(capture, surface)
    end

    assert %Consumption{kind: "activate", wave_id: wave_id} = Repo.get(Consumption, activation.id)
    assert wave_id == fixture.target.id

    assert {:ok, replay} = activate(fixture, fixture.activate_key)
    assert replay.id == activation.id

    alternate_b1 =
      promotion_b1!(
        fixture.target_scope,
        fixture.target,
        fixture.summary,
        "task07-b1-drift-#{System.unique_integer([:positive])}"
      )

    assert {:error, :release_gate_conflict} =
             activate(fixture, fixture.activate_key, alternate_b1.id)

    failed_challenge = Repo.get!(Challenge, hd(failed_challenge_ids))

    assert_sql_rejected(
      ~r/release gate challenge failure cannot change|terminal state is invalid/,
      sql_attack(
        "UPDATE cycle_release_gate_challenges SET failure = 'finalize_failed', completed_at = now() WHERE id = $1",
        [dump(failed_challenge.id)]
      )
    )
  end

  test "promotion requires activation, materializes exactly two Revisions atomically, and rollback restores both bases" do
    fixture = release_fixture!()
    {:ok, campaign} = stage_candidate(fixture, "campaign", fixture.campaign_document)
    {:ok, successor} = stage_candidate(fixture, "successor", fixture.successor_document)

    assert {:error, _} = promote(fixture, fixture.open_gate.receipt, "promote-with-open")

    {:ok, activation} = activate(fixture, fixture.activate_key)
    campaign_base = Repo.get!(Document, campaign.document_id)
    successor_base = Repo.get!(Document, successor.document_id)

    Repo.update_all(
      from(d in Document, where: d.id == ^successor_base.id),
      set: [current_revision_id: nil, released_revision_id: nil]
    )

    assert {:error, _} = promote(fixture, activation.receipt, "promote-pointer-drift")

    assert Repo.get!(Document, campaign_base.id).current_revision_id ==
             campaign_base.current_revision_id

    restore_document!(successor_base)

    assert {:ok, promoted} = promote(fixture, activation.receipt, fixture.promote_key)
    promoted_campaign = Repo.get!(Document, campaign.document_id)
    promoted_successor = Repo.get!(Document, successor.document_id)
    assert promoted_campaign.current_revision_id == campaign.id
    assert promoted_campaign.released_revision_id == campaign.id
    assert promoted_successor.current_revision_id == successor.id
    assert promoted_successor.released_revision_id == successor.id

    campaign_revision = Repo.get!(Revision, campaign.id)
    successor_revision = Repo.get!(Revision, successor.id)
    assert campaign_revision.document_id == campaign.document_id
    assert successor_revision.document_id == successor.document_id
    assert campaign_revision.doc_id == promoted_campaign.doc_id
    assert successor_revision.doc_id == promoted_successor.doc_id
    assert campaign_revision.content == campaign.content
    assert successor_revision.content == successor.content
    assert promoted.release_gate_admission_id == activation.id
    assert_public_candidate_link(fixture.campaign_document.doc_id, campaign)
    assert_public_candidate_link(fixture.successor_document.doc_id, successor)

    assert {:ok, promote_replay} = promote(fixture, activation.receipt, fixture.promote_key)
    assert promote_replay.id == promoted.id

    rollback_attrs = %{
      idempotency_key: fixture.rollback_key,
      previous_event_id: promoted.id,
      restore_event_id: "genesis",
      actor: actor(),
      evidence: "paper://task07/rollback",
      evidence_revision: String.duplicate("e", 64)
    }

    assert {:ok, rolled_back} = CycleFleet.rollback_correction(fixture.root_scope, rollback_attrs)
    rolled_campaign = Repo.get!(Document, campaign.document_id)
    rolled_successor = Repo.get!(Document, successor.document_id)
    assert rolled_campaign.current_revision_id == campaign.base_current_revision_id
    assert rolled_campaign.released_revision_id == campaign.base_released_revision_id
    assert rolled_successor.current_revision_id == successor.base_current_revision_id
    assert rolled_successor.released_revision_id == successor.base_released_revision_id
    refute public_paper_has_candidate_link?(fixture.campaign_document.doc_id)
    refute public_paper_has_candidate_link?(fixture.successor_document.doc_id)

    assert {:ok, rollback_replay} =
             CycleFleet.rollback_correction(fixture.target_scope, rollback_attrs)

    assert rollback_replay.id == rolled_back.id
  end

  test "a failed anonymous reader smoke restores both Papers, quarantines the target, and replays the failure" do
    fixture = release_fixture!()
    {:ok, campaign} = stage_candidate(fixture, "campaign", fixture.campaign_document)
    {:ok, successor} = stage_candidate(fixture, "successor", fixture.successor_document)
    {:ok, activation} = activate(fixture, fixture.activate_key)
    campaign_base = Repo.get!(Document, campaign.document_id)
    successor_base = Repo.get!(Document, successor.document_id)

    Application.put_env(:barkpark, :cycle_release_capture_test_mode, :public_smoke_fail)

    assert {:error, :public_release_smoke_failed} =
             promote(fixture, activation.receipt, fixture.promote_key)

    event =
      Repo.get_by!(Event,
        root_wave_id: fixture.root.id,
        idempotency_key: fixture.promote_key,
        action: "promote"
      )

    smoke = Repo.get_by!(PublicSmoke, promotion_event_id: event.id)
    assert smoke.state == "compensated"
    assert is_binary(smoke.compensation_event_id)
    assert get_in(smoke.failure, ["evidence", "format"]) == "cycle-release-public-smoke-v1"
    assert length(get_in(smoke.failure, ["evidence", "attempts"])) == 2
    assert Enum.any?(get_in(smoke.failure, ["evidence", "attempts"]), &(&1["verdict"] == "fail"))

    assert_document_pointers(Repo.get!(Document, campaign.document_id), campaign_base)
    assert_document_pointers(Repo.get!(Document, successor.document_id), successor_base)

    assert Repo.get_by!(Quarantine,
             root_wave_id: fixture.root.id,
             correction_wave_id: fixture.target.id
           )

    event_count = Repo.aggregate(Event, :count)
    quarantine_count = Repo.aggregate(Quarantine, :count)

    assert {:error, :public_release_smoke_failed} =
             promote(fixture, activation.receipt, fixture.promote_key)

    assert Repo.aggregate(Event, :count) == event_count
    assert Repo.aggregate(Quarantine, :count) == quarantine_count
    assert Repo.get!(PublicSmoke, smoke.id).state == "compensated"

    Application.put_env(:barkpark, :cycle_release_capture_test_mode, :valid)

    assert {:error, :correction_quarantined} =
             promote(
               fixture,
               activation.receipt,
               "#{fixture.promote_key}-content-retry",
               smoke.compensation_event_id
             )

    assert_sql_rejected(~r/invalid release public smoke state transition/, [
      sql_attack("SET session_replication_role = replica", []),
      sql_attack(
        "UPDATE cycle_release_public_smokes SET state = 'failed', compensation_event_id = NULL WHERE id = $1",
        [dump(smoke.id)]
      ),
      sql_attack("SET session_replication_role = origin", []),
      sql_attack(
        "UPDATE cycle_release_public_smokes SET state = 'compensated', compensation_event_id = $2 WHERE id = $1",
        [dump(smoke.id), dump(event.id)]
      )
    ])
  end

  test "an unavailable smoke adapter can retry only through its exact compensated rollback" do
    fixture = release_fixture!()
    {:ok, _campaign} = stage_candidate(fixture, "campaign", fixture.campaign_document)
    {:ok, _successor} = stage_candidate(fixture, "successor", fixture.successor_document)
    {:ok, activation} = activate(fixture, fixture.activate_key)

    Application.put_env(:barkpark, :cycle_release_capture_test_mode, :public_smoke_unavailable)

    assert {:error, :public_release_smoke_failed} =
             promote(fixture, activation.receipt, fixture.promote_key)

    failed_event = Repo.get_by!(Event, idempotency_key: fixture.promote_key)
    failed_smoke = Repo.get_by!(PublicSmoke, promotion_event_id: failed_event.id)
    rollback = Repo.get!(Event, failed_smoke.compensation_event_id)
    assert rollback.previous_event_id == failed_event.id

    Application.put_env(:barkpark, :cycle_release_capture_test_mode, :valid)

    assert {:error, :stale_promotion_head} =
             promote(fixture, activation.receipt, "#{fixture.promote_key}-stale")

    assert {:ok, promoted} =
             promote(
               fixture,
               activation.receipt,
               "#{fixture.promote_key}-retry",
               rollback.id
             )

    retry_smoke = Repo.get_by!(PublicSmoke, promotion_event_id: promoted.id)
    assert retry_smoke.state == "pass"

    expected_prefix =
      "#{BarkparkWeb.Endpoint.url()}/w/#{fixture.workspace.slug}/p/#{fixture.project.slug}/papers/"

    assert Enum.all?(retry_smoke.request["documents"], fn document ->
             String.starts_with?(document["url"], expected_prefix) and
               length(String.split(document["url"], BarkparkWeb.Endpoint.url())) == 2
           end)

    assert Repo.get_by!(Quarantine,
             root_wave_id: fixture.root.id,
             correction_wave_id: fixture.target.id
           )

    assert {:ok, lifecycle} = CycleFleet.current_correction(fixture.root_scope)
    assert lifecycle.current.wave_revision == fixture.target.id
    assert Enum.any?(lifecycle.quarantines, &(&1.correction_wave_revision == fixture.target.id))
  end

  test "raw SQL cannot mutate authority rows or bypass role, capture, consumption, and promotion constraints" do
    fixture = release_fixture!()
    {:ok, campaign} = stage_candidate(fixture, "campaign", fixture.campaign_document)
    {:ok, _successor} = stage_candidate(fixture, "successor", fixture.successor_document)
    {:ok, activation} = activate(fixture, fixture.activate_key)
    consumption = Repo.get!(Consumption, activation.id)

    capture =
      Repo.one!(from c in Capture, where: c.challenge_id == ^activation.challenge_id, limit: 1)

    assert_sql_rejected(
      ~r/release-gate-v1 rows are immutable/,
      sql_attack(
        "UPDATE cycle_release_gate_admissions SET receipt = '{}'::jsonb WHERE id = $1",
        [dump(activation.id)]
      )
    )

    assert_sql_rejected(
      ~r/release-gate-v1 rows are immutable/,
      sql_attack("DELETE FROM cycle_release_paper_candidates WHERE id = $1", [dump(campaign.id)])
    )

    assert_sql_rejected(
      ~r/release-gate-v1 rows are immutable/,
      sql_attack("UPDATE cycle_release_gate_captures SET raw_bytes = 'forged' WHERE id = $1", [
        dump(capture.id)
      ])
    )

    assert_sql_rejected(
      ~r/release-gate-v1 rows are immutable/,
      sql_attack("DELETE FROM cycle_release_gate_consumptions WHERE admission_id = $1", [
        dump(consumption.admission_id)
      ])
    )

    assert_sql_rejected(
      ~r/cycle_release_paper_candidate_role/,
      raw_candidate_insert(fixture, "third-role")
    )

    assert_sql_rejected(~r/duplicate key value|release gate consumption does not match/, [
      raw_consumption_insert(fixture.open_gate.id, fixture.target.id, "activate"),
      sql_attack("SET CONSTRAINTS cycle_release_gate_validate_consumption IMMEDIATE", [])
    ])

    assert_sql_rejected(
      ~r/correction ancestry root is missing|promotion requires an exact consumed activate release gate/,
      [
        raw_promotion_insert(fixture, fixture.open_gate.id),
        sql_attack("SET CONSTRAINTS cycle_release_gate_require_activate IMMEDIATE", [])
      ]
    )

    assert_sql_rejected(~r/ten exact server-owned captures/, [
      raw_extra_capture(capture),
      sql_attack("SET CONSTRAINTS ALL IMMEDIATE", [])
    ])

    assert_sql_rejected(
      ~r/ten exact server-owned captures/,
      forged_capture_replay(activation, capture, :unsigned)
    )

    assert_sql_rejected(
      ~r/ten exact server-owned captures/,
      forged_capture_replay(activation, capture, :wrong_secret_self_consistent)
    )

    assert_sql_rejected(
      ~r/ten exact server-owned captures/,
      forged_capture_replay(activation, capture, :self_consistent_forgery)
    )

    assert {:ok, promoted} = promote(fixture, activation.receipt, fixture.promote_key)
    smoke = Repo.get_by!(PublicSmoke, promotion_event_id: promoted.id)

    assert_sql_rejected(~r/invalid pending public smoke authority/, [
      raw_smoke_insert(smoke, "pass", smoke.request),
      sql_attack("SET CONSTRAINTS ALL IMMEDIATE", [])
    ])

    duplicate_role_request =
      put_in(smoke.request, ["documents", Access.at(1), "role"], "campaign")

    assert_sql_rejected(~r/invalid pending public smoke authority/, [
      raw_smoke_insert(smoke, "pending", duplicate_role_request),
      sql_attack("SET CONSTRAINTS ALL IMMEDIATE", [])
    ])

    assert_sql_rejected(
      ~r/release public smoke authority is immutable/,
      sql_attack(
        "UPDATE cycle_release_public_smokes SET request = jsonb_set(request, '{workspace_slug}', '\"forged\"') WHERE id = $1",
        [dump(smoke.id)]
      )
    )

    forged_unsigned =
      smoke.proof
      |> Map.delete("digest")
      |> Map.delete("attestation")
      |> put_in(["proof", "attempts", Access.at(0), "url"], "https://forged.invalid/paper")

    forged_digest = Barkpark.EpicFleet.canonical_digest(forged_unsigned)

    forged_proof =
      forged_unsigned
      |> Map.put("digest", forged_digest)
      |> Map.put("attestation", hmac(forged_digest, capture_hmac_secret()))

    assert_sql_rejected(~r/invalid release public smoke state transition/, [
      sql_attack("SET session_replication_role = replica", []),
      sql_attack(
        "UPDATE cycle_release_public_smokes SET state = 'pending', proof = NULL, proof_digest = NULL WHERE id = $1",
        [dump(smoke.id)]
      ),
      sql_attack("SET session_replication_role = origin", []),
      sql_attack("SELECT set_config('barkpark.release_capture_hmac_secret', $1, true)", [
        capture_hmac_secret()
      ]),
      sql_attack(
        "UPDATE cycle_release_public_smokes SET state = 'pass', proof = $2::jsonb, proof_digest = $3 WHERE id = $1",
        [dump(smoke.id), forged_proof, forged_proof["digest"]]
      )
    ])

    wrong_secret = String.duplicate("hostile-wrong-secret-", 2)
    exact_unsigned = smoke.proof |> Map.delete("digest") |> Map.delete("attestation")
    exact_digest = Barkpark.EpicFleet.canonical_digest(exact_unsigned)

    wrong_secret_proof =
      exact_unsigned
      |> Map.put("digest", exact_digest)
      |> Map.put("attestation", hmac(exact_digest, wrong_secret))

    assert_sql_rejected(~r/invalid release public smoke state transition/, [
      sql_attack("SET session_replication_role = replica", []),
      sql_attack(
        "UPDATE cycle_release_public_smokes SET state = 'pending', proof = NULL, proof_digest = NULL WHERE id = $1",
        [dump(smoke.id)]
      ),
      sql_attack("SET session_replication_role = origin", []),
      sql_attack("SELECT set_config('barkpark.release_capture_hmac_secret', $1, true)", [
        wrong_secret
      ]),
      sql_attack(
        "UPDATE cycle_release_public_smokes SET state = 'pass', proof = $2::jsonb, proof_digest = $3 WHERE id = $1",
        [dump(smoke.id), wrong_secret_proof, exact_digest]
      )
    ])
  end

  defp release_fixture! do
    {workspace, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    unique = System.unique_integer([:positive])

    root_scope = %{
      workspace_id: workspace.id,
      project_id: project.id,
      epic_id: "task07-hostile-#{unique}",
      wave_id: "wave-3"
    }

    inventory = Enum.map(1..503, &"unit-#{&1}")

    {:ok, root} =
      CycleFleet.open_wave(
        Map.merge(root_scope, %{profile: "epic", inventory: inventory, scale_contract: %{}})
      )

    stable_a =
      create_builder!(
        root_scope,
        "build-stable-a",
        Enum.map(1..242, &"unit-#{&1}"),
        typed_outcomes(Enum.map(1..42, &"unit-#{&1}"), Enum.map(43..242, &"unit-#{&1}"), [])
      )

    _stable_b =
      create_builder!(
        root_scope,
        "build-stable-b",
        Enum.map(243..485, &"unit-#{&1}"),
        typed_outcomes([], Enum.map(243..322, &"unit-#{&1}"), Enum.map(323..485, &"unit-#{&1}"))
      )

    build07 =
      create_builder!(
        root_scope,
        "build-07",
        Enum.map(486..503, &"unit-#{&1}"),
        typed_outcomes(Enum.map(486..496, &"unit-#{&1}"), [], Enum.map(497..503, &"unit-#{&1}"))
      )

    semantic_task = ensure_semantic_task!(build07)
    semantic_task |> Ecto.Changeset.change(rev: Ecto.UUID.generate()) |> Repo.update!()
    complete_phase!(root_scope, "survey", "epic-surveyor", 12)
    complete_phase!(root_scope, "verify", "epic-verifier", 6)
    complete_phase!(root_scope, "review", "code-reviewer", 3)

    {:ok, before} = CycleFleet.reconcile(root_scope)
    assert {before.shipped_count, before.stalled_count, before.excluded_count} == {53, 280, 170}
    result = Repo.get_by!(Result, assignment_id: build07.id)

    correction = correction(root, before, build07, result)
    target_scope = %{root_scope | wave_id: "wave-4"}
    open_key = "open-#{unique}"

    {:ok, open_gate} =
      CycleFleet.admit_open_release_gate(target_scope, %{
        target_wave_id: target_scope.wave_id,
        idempotency_key: open_key,
        correction_of: correction,
        correction_of_digest: CycleFleet.digest(correction)
      })

    {:ok, target} =
      CycleFleet.open_wave(
        Map.merge(target_scope, %{
          correction_of: correction,
          correction_of_digest: CycleFleet.digest(correction),
          release_gate_receipt: open_gate.receipt
        })
      )

    {:ok, summary} = CycleFleet.reconcile(target_scope)
    {:ok, projection} = CycleFleet.projection(target_scope)
    {:ok, prospective_lifecycle} = CycleFleet.prospective_correction_lifecycle(target_scope)

    assert {summary.shipped_count, summary.stalled_count, summary.excluded_count} ==
             {42, 291, 170}

    dataset =
      Repo.one!(
        from d in Barkpark.Tenancy.Dataset,
          where: d.project_id == ^project.id and d.slug == "production"
      )

    campaign_document = base_paper!(target_scope, dataset, "task07-campaign-#{unique}")
    successor_document = base_paper!(target_scope, dataset, "task07-successor-#{unique}")
    b1_experiment = promotion_b1!(target_scope, target, summary, "task07-b1-#{unique}")

    %{
      workspace: workspace,
      project: project,
      root_scope: root_scope,
      target_scope: target_scope,
      root: root,
      target: target,
      correction: correction,
      summary: summary,
      projection: projection,
      prospective_lifecycle: prospective_lifecycle,
      open_gate: open_gate,
      open_key: open_key,
      campaign_document: campaign_document,
      successor_document: successor_document,
      b1_experiment: b1_experiment,
      activate_key: "activate-#{unique}",
      promote_key: "promote-#{unique}",
      rollback_key: "rollback-#{unique}",
      stable_a: stable_a
    }
  end

  defp admit_open(fixture, key) do
    CycleFleet.admit_open_release_gate(fixture.target_scope, %{
      target_wave_id: fixture.target_scope.wave_id,
      idempotency_key: key,
      correction_of: fixture.correction,
      correction_of_digest: CycleFleet.digest(fixture.correction)
    })
  end

  defp stage_candidate(fixture, role, document) do
    CycleFleet.stage_release_paper_candidate(fixture.target_scope, fixture.open_gate.id, role, %{
      document_id: document.id,
      title: "Task07 #{role}",
      content: authority_content(fixture, role)
    })
  end

  defp activate(fixture, key, b1_id \\ nil) do
    CycleFleet.activate_release_gate(fixture.target_scope, fixture.open_gate.id, %{
      idempotency_key: key,
      b1_experiment_id: b1_id || fixture.b1_experiment.id
    })
  end

  defp promote(fixture, receipt, key, previous_event_id \\ nil) do
    CycleFleet.promote_correction(fixture.root_scope, %{
      idempotency_key: key,
      previous_event_id: previous_event_id,
      actor: actor(),
      evidence: "paper://task07/promotion",
      evidence_revision: String.duplicate("d", 64),
      correction_receipt: fixture.summary.correction_receipt,
      gate_receipt: receipt
    })
  end

  defp actor, do: %{"type" => "agent", "id" => "task07-hostile-test"}

  defp authority_content(fixture, role) do
    projection = fixture.projection

    %{
      "blocks" => [
        %{
          "type" => "paragraph",
          "text" =>
            "Task07 #{role}: 503 total 42 shipped 291 stalled 170 excluded " <>
              "current superseded -11 +11"
        },
        %{
          "type" => "paragraph",
          "content" => [
            %{
              "type" => "link",
              "href" => @candidate_link_href,
              "children" => [%{"type" => "text", "value" => @candidate_link_label}]
            }
          ]
        },
        %{
          "type" => "callout",
          "cycle_ledger" => stringify_keys(projection.cycle_ledger),
          "fleet" => stringify_keys(projection.fleet),
          "correction_lifecycle" => stringify_keys(fixture.prospective_lifecycle)
        }
      ]
    }
  end

  defp assert_candidate_link_parity(capture, "source_json") do
    decoded = Jason.decode!(capture.raw_bytes)

    assert get_in(decoded, ["source", "blocks", Access.at(1), "content", Access.at(0)]) == %{
             "type" => "link",
             "href" => @candidate_link_href,
             "children" => [%{"type" => "text", "value" => @candidate_link_label}]
           }
  end

  defp assert_candidate_link_parity(capture, "public_html") do
    assert capture.raw_bytes =~ ~s(href="#{@candidate_link_href}")
    assert capture.raw_bytes =~ @candidate_link_label
  end

  defp assert_candidate_link_parity(capture, surface)
       when surface in ~w(cli task_board tui) do
    assert capture.raw_bytes =~ @candidate_link_href
    assert Regex.replace(~r/\e\[[0-9;]*m/, capture.raw_bytes, "") =~ @candidate_link_label
  end

  defp assert_public_candidate_link(doc_id, candidate) do
    paper = Barkpark.Content.get_public_paper(doc_id)

    assert paper.current_revision_id == candidate.id
    assert paper.released_revision_id == candidate.id
    assert paper.content == candidate.content
    assert public_paper_has_candidate_link?(doc_id)
  end

  defp public_paper_has_candidate_link?(doc_id) do
    case Barkpark.Content.get_public_paper(doc_id) do
      nil ->
        false

      paper ->
        html = Barkpark.PortableDoc.Render.render_blocks(paper.content["blocks"], %{})
        html =~ ~s(href="#{@candidate_link_href}") and html =~ @candidate_link_label
    end
  end

  defp base_paper!(scope, dataset, doc_id) do
    document =
      %Document{}
      |> Document.changeset(%{
        doc_id: doc_id,
        type: "paper",
        dataset: "production",
        dataset_id: dataset.id,
        workspace_id: scope.workspace_id,
        project_id: scope.project_id,
        title: doc_id,
        status: "published",
        content: %{"blocks" => [%{"type" => "paragraph", "text" => "base"}]},
        rev: Ecto.UUID.generate()
      })
      |> Repo.insert!()

    %Revision{}
    |> Revision.changeset(%{
      document_id: document.id,
      doc_id: document.doc_id,
      type: document.type,
      dataset: document.dataset,
      dataset_id: document.dataset_id,
      workspace_id: document.workspace_id,
      project_id: document.project_id,
      title: document.title,
      status: document.status,
      action: "publish",
      content: document.content
    })
    |> Repo.insert!()

    Repo.get!(Document, document.id)
  end

  defp restore_document!(document) do
    Repo.update_all(
      from(d in Document, where: d.id == ^document.id),
      set: [
        rev: document.rev,
        current_revision_id: document.current_revision_id,
        released_revision_id: document.released_revision_id
      ]
    )

    Repo.get!(Document, document.id)
  end

  defp assert_document_pointers(actual, expected) do
    assert actual.rev == expected.rev
    assert actual.current_revision_id == expected.current_revision_id
    assert actual.released_revision_id == expected.released_revision_id
  end

  defp correction(root, before, assignment, result) do
    target = %{
      "assignment_id" => assignment.assignment_id,
      "assignment_revision" => assignment.id,
      "snapshot_digest" => assignment.snapshot_digest,
      "result_revision" => result.id,
      "payload_digest" => result.payload_digest,
      "evidence_revision" => result.evidence_revision,
      "semantic_status" => "invalid",
      "semantic_receipt_index_hash" => result.payload["semantic_receipt_index_hash"]
    }

    %{
      "version" => "correction_of-v1",
      "prior" => %{
        "workspace_id" => root.workspace_id,
        "project_id" => root.project_id,
        "epic_id" => root.epic_id,
        "wave_id" => root.wave_id,
        "wave_revision" => root.id,
        "inventory_digest" => root.inventory_digest,
        "effective_plan_digest" => before.plan_digest,
        "reconciliation_digest" => before.reconciliation_digest
      },
      "ancestry" => [%{"wave_id" => root.wave_id, "wave_revision" => root.id}],
      "targets" => [target],
      "changes" =>
        Enum.map(486..496, fn index ->
          %{
            "unit_id" => "unit-#{index}",
            "assignment_id" => assignment.assignment_id,
            "assignment_revision" => assignment.id,
            "before" => "shipped",
            "after" => "stalled"
          }
        end),
      "inventory_count" => 503,
      "before_counts" => %{"shipped" => 53, "stalled" => 280, "excluded" => 170},
      "delta" => %{"shipped" => -11, "stalled" => 11, "excluded" => 0},
      "after_counts" => %{"shipped" => 42, "stalled" => 291, "excluded" => 170}
    }
  end

  defp create_builder!(scope, id, units, outcomes) do
    {:ok, assignment} =
      CycleFleet.create_assignment(assignment_attrs(scope, id, "build", "epic-builder", units))

    {:ok, _result} = complete_result(assignment, "terminal-#{id}", "completed", outcomes)
    assignment
  end

  defp complete_phase!(scope, phase, agent_type, count) do
    for index <- 1..count do
      {:ok, assignment} =
        CycleFleet.create_assignment(
          assignment_attrs(scope, "#{phase}-#{index}", phase, agent_type, [])
        )

      {:ok, _result} = complete_result(assignment, "terminal-#{phase}-#{index}", "completed", %{})
    end
  end

  defp assignment_attrs(scope, id, phase, agent_type, units) do
    Map.merge(scope, %{
      assignment_id: id,
      phase: phase,
      agent_type: agent_type,
      effort: if(phase in ~w(build review), do: "high", else: "medium"),
      snapshot: %{unit_ids: units}
    })
  end

  defp complete_result(assignment, key, status, payload) do
    payload =
      if assignment.phase == "build" and status == "completed" do
        outcomes =
          Map.merge(
            %{completed_unit_ids: [], stalled_unit_ids: [], excluded_unit_ids: []},
            payload
          )

        task = ensure_semantic_task!(assignment)
        Map.put(outcomes, :semantic_receipts, semantic_receipts(assignment, task, outcomes))
      else
        payload
      end

    CycleFleet.record_result(assignment, key, %{
      status: status,
      evidence: "paper://#{key}",
      evidence_revision: "rev-1",
      payload: payload
    })
  end

  defp ensure_semantic_task!(assignment) do
    case Repo.get(AssignmentTask, assignment.id) do
      %AssignmentTask{task_id: task_id} ->
        Repo.get!(Document, task_id)

      nil ->
        wave = Repo.get!(Wave, assignment.cycle_wave_id)
        project = Repo.get!(Barkpark.Tenancy.Project, wave.project_id)
        {:ok, dataset} = Tenancy.get_or_create_dataset(project, "production")
        criteria = criteria(assignment.assignment_id)

        task =
          %Document{}
          |> Document.changeset(%{
            doc_id: "task.#{assignment.assignment_id}.#{System.unique_integer([:positive])}",
            type: "task",
            dataset: "production",
            dataset_id: dataset.id,
            workspace_id: assignment.workspace_id,
            project_id: wave.project_id,
            title: assignment.assignment_id,
            status: "draft",
            rev: Ecto.UUID.generate(),
            content: %{
              "kind" => "task",
              "lifecycle_status" => "done",
              "acceptance_criteria" => criteria,
              "claim" => %{"worker" => "builder-#{assignment.assignment_id}", "epoch" => 1}
            }
          })
          |> Repo.insert!()

        {:ok, _} = CycleFleet.bind_assignment_task(assignment, task.id)
        task
    end
  end

  defp semantic_receipts(assignment, task, outcomes) do
    wave = Repo.get!(Wave, assignment.cycle_wave_id)
    claim = task.content["claim"]

    dispositions =
      [
        {"shipped", outcomes.completed_unit_ids},
        {"stalled", outcomes.stalled_unit_ids},
        {"excluded", outcomes.excluded_unit_ids}
      ]
      |> Enum.reduce(%{}, fn {disposition, ids}, acc ->
        Enum.reduce(ids, acc, &Map.put(&2, &1, disposition))
      end)

    Enum.map(Enum.sort(assignment.unit_ids), fn unit_id ->
      %{
        "assignment_id" => assignment.id,
        "ownership" => %{
          "assignment_id" => assignment.id,
          "assignment_key" => assignment.assignment_id,
          "cycle_wave_id" => assignment.cycle_wave_id,
          "snapshot_digest" => assignment.snapshot_digest,
          "workspace_id" => assignment.workspace_id,
          "project_id" => wave.project_id,
          "dataset_id" => task.dataset_id
        },
        "task_id" => task.id,
        "task_doc_id" => task.doc_id,
        "task_rev" => task.rev,
        "lifecycle_status" => "done",
        "criteria" => criteria(assignment.assignment_id),
        "claim" => %{"worker" => claim["worker"], "epoch" => claim["epoch"]},
        "unit_id" => unit_id,
        "disposition" => dispositions[unit_id]
      }
    end)
  end

  defp criteria(id),
    do: [
      %{"criterion" => "#{id} verified", "met" => true, "evidence" => "paper://criteria/#{id}"}
    ]

  defp typed_outcomes(shipped, stalled, excluded),
    do: %{completed_unit_ids: shipped, stalled_unit_ids: stalled, excluded_unit_ids: excluded}

  defp promotion_b1!(scope, wave, summary, experiment_id) do
    fleet_digest = Barkpark.EpicFleet.canonical_digest(summary.canonical_fleet)

    unsigned_scope = %{
      "version" => "b1-scope-fence-v1",
      "workspace_id" => wave.workspace_id,
      "project_id" => wave.project_id,
      "epic_id" => wave.epic_id,
      "wave_id" => wave.wave_id,
      "wave_revision" => wave.id,
      "inventory_digest" => wave.inventory_digest,
      "plan_digest" => summary.plan_digest,
      "reconciliation_digest" => summary.reconciliation_digest,
      "fleet_digest" => fleet_digest
    }

    scope_receipt =
      Map.put(
        unsigned_scope,
        "receipt_digest",
        Barkpark.EpicFleet.canonical_digest(unsigned_scope)
      )

    {:ok, experiment} =
      Barkpark.EpicFleet.create_benchmark_experiment(%{
        workspace_id: scope.workspace_id,
        epic_id: scope.epic_id,
        wave_id: wave.wave_id,
        experiment_id: experiment_id,
        phase: "epic",
        protocol_version: 1,
        manifest: %{
          "cycle_scope_fence" => scope_receipt,
          "fleet_contract" => %{"version" => 1, "paper_fleet_digest" => fleet_digest}
        }
      })

    assignments =
      for phase <- ~w(survey verify experiment build review),
          assignment <-
            summary.canonical_fleet
            |> Map.get(String.to_existing_atom(phase), %{assignments: []})
            |> Map.get(:assignments, [])
            |> Enum.sort_by(& &1.id),
          do: {phase, assignment}

    for {{phase, assignment}, index} <- Enum.with_index(assignments, 1) do
      {:ok, _} =
        Barkpark.EpicFleet.record_benchmark_attempt(experiment, %{
          attempt_id: "cycle-#{phase}-#{assignment.id}",
          ordinal: index,
          treatment: "cyclefleet-reconciliation",
          status: "completed",
          costs: %{"wall_seconds" => %{"state" => "unsupported", "reason" => "not recorded"}},
          provenance: %{
            wave_revision: wave.id,
            scope_receipt_digest: scope_receipt["receipt_digest"]
          },
          payload: %{
            fleet_assignment: %{
              phase: phase,
              assignment_id: assignment.id,
              agent_type: assignment.agent_type,
              evidence: assignment.evidence,
              model_reasoning_effort: if(phase in ~w(build review), do: "high", else: "medium")
            }
          }
        })
    end

    experiment
  end

  defp assert_sql_rejected(pattern, attacks) do
    statements =
      attacks
      |> List.wrap()
      |> Enum.map_join("\n", fn %{sql: sql, params: params} ->
        statement = interpolate_sql(sql, params) |> String.replace("'", "''")
        "EXECUTE '#{statement}';"
      end)

    expected = pattern.source |> String.replace("'", "''")

    Repo.query!("""
    DO $hostile$
    DECLARE rejected boolean := false;
    DECLARE rejection_message text;
    BEGIN
      BEGIN
        #{statements}
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS rejection_message = MESSAGE_TEXT;
        IF NOT (rejection_message ~ '#{expected}') THEN
          RAISE EXCEPTION 'unexpected hostile SQL rejection: %', rejection_message;
        END IF;
        rejected := true;
      END;
      IF NOT rejected THEN
        RAISE EXCEPTION 'hostile SQL unexpectedly succeeded';
      END IF;
    END
    $hostile$
    """)
  end

  defp raw_candidate_insert(fixture, role) do
    document = fixture.campaign_document
    content = authority_content(fixture, role)
    source = %{"kind" => "blocks", "blocks" => content["blocks"]}

    sql_attack(
      """
      INSERT INTO cycle_release_paper_candidates
        (id,target_wave_id,role,document_id,doc_id,base_document_rev,base_current_revision_id,
         base_released_revision_id,title,status,content,content_digest,source_digest,inserted_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'hostile','published',$9::jsonb,$10,$11,now())
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(fixture.target.id),
        role,
        dump(document.id),
        document.doc_id,
        document.rev,
        dump(document.current_revision_id),
        dump(document.released_revision_id),
        content,
        Barkpark.EpicFleet.canonical_digest(content),
        Barkpark.EpicFleet.canonical_digest(source)
      ]
    )
  end

  defp raw_consumption_insert(admission_id, wave_id, kind) do
    sql_attack(
      "INSERT INTO cycle_release_gate_consumptions (admission_id,wave_id,kind,inserted_at) VALUES ($1,$2,$3,now())",
      [dump(admission_id), dump(wave_id), kind]
    )
  end

  defp raw_promotion_insert(fixture, admission_id) do
    sql_attack(
      """
      INSERT INTO cycle_correction_promotion_events
        (id,root_wave_id,target_wave_id,workspace_id,project_id,epic_id,action,idempotency_key,
         actor,evidence,evidence_revision,event_payload,event_digest,release_gate_admission_id,inserted_at)
      VALUES ($1,$2,$3,$4,$5,$6,'promote','raw-hostile',$7::jsonb,'paper://raw',$8,$9::jsonb,$10,$11,now())
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(fixture.root.id),
        dump(fixture.target.id),
        dump(fixture.root.workspace_id),
        dump(fixture.root.project_id),
        fixture.root.epic_id,
        actor(),
        String.duplicate("a", 64),
        %{},
        String.duplicate("b", 64),
        dump(admission_id)
      ]
    )
  end

  defp raw_extra_capture(capture) do
    sql_attack(
      """
      INSERT INTO cycle_release_gate_captures
        (id,challenge_id,name,producer,raw_bytes,byte_count,content_digest,provenance,
         provenance_digest,verdict,verdict_digest,inserted_at)
      VALUES ($1,$2,'campaign.extra','server_http',$3,$4,$5,$6::jsonb,$7,$8::jsonb,$9,now())
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(capture.challenge_id),
        capture.raw_bytes,
        capture.byte_count,
        capture.content_digest,
        capture.provenance,
        capture.provenance_digest,
        capture.verdict,
        capture.verdict_digest
      ]
    )
  end

  defp raw_smoke_insert(smoke, state, request) do
    sql_attack(
      """
      INSERT INTO cycle_release_public_smokes
        (id,promotion_event_id,root_wave_id,target_wave_id,state,request,inserted_at,updated_at)
      VALUES ($1,$2,$3,$4,$5,$6::jsonb,now(),now())
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(smoke.promotion_event_id),
        dump(smoke.root_wave_id),
        dump(smoke.target_wave_id),
        state,
        request
      ]
    )
  end

  defp forged_capture_replay(activation, capture, mode) do
    copy = "hostile_activation_#{mode}"

    mutation =
      case mode do
        :unsigned ->
          [
            sql_attack(
              "UPDATE cycle_release_gate_captures SET server_signature = NULL WHERE id = $1",
              [dump(capture.id)]
            )
          ]

        :self_consistent_forgery ->
          forged_candidate = Ecto.UUID.generate()
          secret = Application.fetch_env!(:barkpark, :cycle_release_capture_hmac_secret)

          [
            sql_attack(
              "UPDATE cycle_release_gate_captures SET provenance = jsonb_set(provenance, '{candidate_id}', to_jsonb($2::text)) WHERE id = $1",
              [dump(capture.id), forged_candidate]
            ),
            sql_attack(
              "UPDATE cycle_release_gate_captures SET provenance_digest = barkpark_jsonb_canonical_digest(provenance) WHERE id = $1",
              [dump(capture.id)]
            ),
            sql_attack("SELECT set_config('barkpark.release_capture_hmac_secret', $1, true)", [
              secret
            ]),
            sql_attack(
              """
              UPDATE cycle_release_gate_captures SET server_signature = encode(hmac(
                convert_to(concat_ws(E'\\n', challenge_id::text, name, producer, byte_count::text,
                  content_digest, provenance_digest, verdict_digest), 'UTF8'),
                convert_to(current_setting('barkpark.release_capture_hmac_secret', true), 'UTF8'),
                'sha256'), 'hex') WHERE id = $1
              """,
              [dump(capture.id)]
            )
          ]

        :wrong_secret_self_consistent ->
          wrong_secret = String.duplicate("hostile-wrong-secret-", 2)

          [
            sql_attack("SELECT set_config('barkpark.release_capture_hmac_secret', $1, true)", [
              wrong_secret
            ]),
            sql_attack(
              """
              UPDATE cycle_release_gate_captures SET server_signature = encode(hmac(
                convert_to(concat_ws(E'\\n', challenge_id::text, name, producer, byte_count::text,
                  content_digest, provenance_digest, verdict_digest), 'UTF8'),
                convert_to(current_setting('barkpark.release_capture_hmac_secret', true), 'UTF8'),
                'sha256'), 'hex') WHERE id = $1
              """,
              [dump(capture.id)]
            )
          ]
      end

    [
      sql_attack(
        "CREATE TEMP TABLE #{copy} ON COMMIT DROP AS SELECT * FROM cycle_release_gate_admissions WHERE id = $1",
        [
          dump(activation.id)
        ]
      ),
      sql_attack("SET session_replication_role = replica", []),
      sql_attack("DELETE FROM cycle_release_gate_consumptions WHERE admission_id = $1", [
        dump(activation.id)
      ]),
      sql_attack("DELETE FROM cycle_release_gate_admissions WHERE id = $1", [dump(activation.id)])
    ] ++
      mutation ++
      [
        sql_attack("SET session_replication_role = origin", []),
        sql_attack("INSERT INTO cycle_release_gate_admissions SELECT * FROM #{copy}", []),
        sql_attack("SET CONSTRAINTS cycle_release_gate_validate_admission IMMEDIATE", [])
      ]
  end

  defp sql_attack(sql, params), do: %{sql: sql, params: params}

  defp interpolate_sql(sql, params) do
    Regex.replace(~r/\$(\d+)/, sql, fn _, index ->
      params |> Enum.at(String.to_integer(index) - 1) |> sql_literal()
    end)
  end

  defp sql_literal(nil), do: "NULL"

  defp sql_literal(value) when is_binary(value) do
    value = if byte_size(value) == 16, do: Ecto.UUID.load!(value), else: value
    "'#{String.replace(value, "'", "''")}'"
  end

  defp sql_literal(value) when is_map(value) or is_list(value),
    do: value |> Jason.encode!() |> sql_literal()

  defp sql_literal(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp sql_literal(true), do: "TRUE"
  defp sql_literal(false), do: "FALSE"

  defp dump(nil), do: nil
  defp dump(uuid), do: Ecto.UUID.dump!(uuid)

  defp restore_env(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore_env(key, value), do: Application.put_env(:barkpark, key, value)

  defp capture_hmac_secret,
    do: Application.fetch_env!(:barkpark, :cycle_release_capture_hmac_secret)

  defp hmac(payload, secret) do
    :hmac
    |> :crypto.mac(:sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
