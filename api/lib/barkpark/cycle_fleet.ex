defmodule Barkpark.CycleFleet do
  @moduledoc """
  Profile-driven durable ledger for Codex Epic and Legendary cycles.

  A wave freezes inventory and experiment intent before fan-out. Legendary's
  capacity and build count are sealed later in an immutable post-pilot build
  plan. Assignments and terminal results reuse the append-only Epic ledger.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.{Document, Revision, Scope}

  alias Barkpark.CycleFleet.{
    AssignmentTask,
    BuildPlan,
    Profile,
    Promotion,
    Quarantine,
    RuntimeAttempt,
    ReleaseGate,
    Wave
  }

  alias Barkpark.CycleFleet.Promotion.{Admission, Event, PublicSmoke, Root, Target}
  alias Barkpark.CycleFleet.ReleaseGate.{Capture, Challenge, Consumption, PaperCandidate}
  alias Barkpark.CycleFleet.ReleaseCaptureAdapter
  alias Barkpark.EpicFleet
  alias Barkpark.EpicFleet.{Assignment, Experiment, Result}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Recorder, Runtime}
  alias Barkpark.Tasks
  alias Barkpark.Tasks.{Queue, QueueGate, Rail}
  alias Barkpark.Tenancy.{Dataset, Project, Workspace}

  @scope_fields [:workspace_id, :project_id, :epic_id, :wave_id]
  @experiment_rounds ~w(baseline diverge attack converge pilot)
  @outcome_keys %{
    shipped: :completed_unit_ids,
    stalled: :stalled_unit_ids,
    excluded: :excluded_unit_ids
  }
  @correction_receipt_keys ~w(version successor_wave_revision parent_wave_revision correction_of_digest targets)
  @gate_receipt_keys ~w(format wave_revision inventory_digest plan_digest reconciliation_digest correction_receipt_digest semantic_digest b1_scope_receipt_digest b1_experiment_id b1_ledger_digest b1_bytes_digest paper_document_id paper_revision_id paper_doc_id paper_content_digest receipt_digest)

  @doc "Create or replay the immutable pre-open release admission for one correction."
  def admit_open_release_gate(scope, attrs) when is_map(scope) and is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, normalized} <-
             normalize_scope(
               Map.merge(scope, %{"wave_id" => value(attrs, :target_wave_id, scope[:wave_id])})
             ),
           correction when is_map(correction) <- value(attrs, :correction_of),
           submitted_digest when is_binary(submitted_digest) <-
             value(attrs, :correction_of_digest),
           true <-
             submitted_digest == digest(stringify_keys(correction)) ||
               {:error, :correction_digest_mismatch},
           {:ok, parent, canonical} <- validate_correction(normalized, correction, %{}, true),
           %Wave{} = root <- ancestry_root_wave(parent),
           key when is_binary(key) <- value(attrs, :idempotency_key),
           true <- nonempty?(key) || {:error, :invalid_idempotency_key} do
        existing =
          Repo.one(
            from gate in ReleaseGate,
              where:
                gate.root_wave_id == ^root.id and gate.stage == "open" and
                  gate.idempotency_key == ^key,
              lock: "FOR UPDATE"
          )

        reserved = if existing, do: existing.reserved_target_revision, else: Ecto.UUID.generate()
        task_authority = release_task_authority(root)

        proposed = %{
          "correction_of" => canonical,
          "correction_of_digest" => digest(canonical),
          "launch_contract" => %{
            "profile" => parent.profile,
            "inventory_digest" => parent.inventory_digest,
            "plan_digest" => effective_plan_digest(parent),
            "experiment_contract" => parent.experiment_contract,
            "scale_contract" => parent.scale_contract
          }
        }

        proposed =
          Map.put(
            proposed,
            "launch_contract_digest",
            EpicFleet.canonical_digest(proposed["launch_contract"])
          )

        unsigned = %{
          "format" => "cycle-release-gate-v1",
          "stage" => "open",
          "authority" => %{
            "workspace_id" => root.workspace_id,
            "project_id" => root.project_id,
            "epic_id" => root.epic_id,
            "root_wave_revision" => root.id,
            "parent_wave_revision" => parent.id,
            "target_wave_id" => normalized.wave_id,
            "reserved_target_revision" => reserved
          },
          "proposed" => proposed,
          "authorities" => task_authority
        }

        receipt = Map.put(unsigned, "receipt_digest", EpicFleet.canonical_digest(unsigned))

        attrs = %{
          stage: "open",
          root_wave_id: root.id,
          parent_wave_id: parent.id,
          reserved_target_revision: reserved,
          workspace_id: root.workspace_id,
          project_id: root.project_id,
          epic_id: root.epic_id,
          target_wave_key: normalized.wave_id,
          idempotency_key: key,
          evidence_bundle: %{},
          receipt: receipt,
          bundle_digest: EpicFleet.canonical_digest(%{}),
          receipt_digest: receipt["receipt_digest"]
        }

        case existing do
          %ReleaseGate{receipt: ^receipt} = replay ->
            replay

          %ReleaseGate{} ->
            Repo.rollback(:release_gate_conflict)

          nil ->
            case Repo.insert(ReleaseGate.changeset(attrs)) do
              {:ok, gate} -> gate
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_release_gate)
      end
    end)
  end

  def admit_open_release_gate(_, _), do: {:error, :invalid_release_gate}

  @doc "Stage one immutable Paper candidate without advancing mutable document pointers."
  def stage_release_paper_candidate(scope, gate_id, role, attrs)
      when is_map(scope) and role in ["campaign", "successor"] and is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, gate_id} <- Ecto.UUID.cast(gate_id),
           %ReleaseGate{stage: "open"} = gate <- Repo.get(ReleaseGate, gate_id),
           true <- release_gate_scope?(gate, scope),
           %Wave{} = target <- Repo.get(Wave, gate.reserved_target_revision),
           {:ok, summary} <- reconcile(Map.take(target, @scope_fields)),
           document_id when is_binary(document_id) <- value(attrs, :document_id),
           {:ok, document_id} <- Ecto.UUID.cast(document_id),
           %Document{} = document <- locked_release_document(document_id, gate),
           content when is_map(content) <- value(attrs, :content),
           :ok <- validate_candidate_paper(role, content, summary) do
        source = %{"kind" => "blocks", "blocks" => content["blocks"] || content[:blocks]}

        candidate_attrs = %{
          target_wave_id: target.id,
          role: role,
          document_id: document.id,
          doc_id: document.doc_id,
          base_document_rev: document.rev,
          base_current_revision_id: document.current_revision_id,
          base_released_revision_id: document.released_revision_id,
          title: value(attrs, :title, document.title),
          status: "published",
          content: stringify_keys(content),
          content_digest: EpicFleet.canonical_digest(stringify_keys(content)),
          source_digest: EpicFleet.canonical_digest(source)
        }

        case Repo.get_by(PaperCandidate, target_wave_id: target.id, role: role) do
          %PaperCandidate{} = existing ->
            if Map.take(existing, Map.keys(candidate_attrs)) == candidate_attrs,
              do: existing,
              else: Repo.rollback(:paper_candidate_conflict)

          nil ->
            case Repo.insert(PaperCandidate.changeset(candidate_attrs)) do
              {:ok, candidate} -> candidate
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_paper_candidate)
      end
    end)
  end

  def release_paper_candidate(scope, gate_id, role, wave_revision, candidate_id)
      when is_map(scope) and role in ["campaign", "successor"] do
    with {:ok, gate_id} <- Ecto.UUID.cast(gate_id),
         {:ok, wave_revision} <- Ecto.UUID.cast(wave_revision),
         {:ok, candidate_id} <- Ecto.UUID.cast(candidate_id),
         %ReleaseGate{stage: "open"} = gate <- Repo.get(ReleaseGate, gate_id),
         true <- release_gate_scope?(gate, scope),
         true <- gate.reserved_target_revision == wave_revision,
         %PaperCandidate{} = candidate <-
           Repo.get_by(PaperCandidate, target_wave_id: wave_revision, role: role),
         true <- candidate.id == candidate_id,
         true <- candidate.content_digest == EpicFleet.canonical_digest(candidate.content) do
      {:ok, gate, candidate}
    else
      nil -> {:error, :paper_candidate_not_found}
      false -> {:error, :release_gate_target_mismatch}
      _ -> {:error, :invalid_release_gate_pin}
    end
  end

  @release_capture_names for role <- ~w(campaign successor),
                             surface <- ~w(source_json public_html cli task_board tui),
                             do: "#{role}.#{surface}"

  @doc "Run the configured server-owned readers and admit one exact activation gate."
  def activate_release_gate(scope, gate_id, attrs) when is_map(scope) and is_map(attrs) do
    with {:ok, prepared} <- prepare_activate_release_gate(scope, gate_id, attrs) do
      case prepared do
        {:replay, gate} ->
          {:ok, gate}

        %{request: request, challenge: challenge} = context ->
          case ReleaseCaptureAdapter.capture(Map.put(request, "challenge_id", challenge.id)) do
            {:ok, captures} ->
              case finalize_activate_release_gate(context, captures) do
                {:ok, _gate} = success ->
                  success

                {:error, _reason} = failure ->
                  fail_release_challenge(challenge.id, "finalize_failed", failure)
              end

            {:error, _reason} = failure ->
              fail_release_challenge(challenge.id, "capture_failed", failure)
          end
      end
    end
  end

  defp prepare_activate_release_gate(scope, gate_id, attrs) do
    Repo.transaction(fn ->
      with {:ok, gate_id} <- Ecto.UUID.cast(gate_id),
           %ReleaseGate{stage: "open"} = open_gate <- Repo.get(ReleaseGate, gate_id),
           true <- release_gate_scope?(open_gate, scope),
           %Wave{} = target <- Repo.get(Wave, open_gate.reserved_target_revision),
           {:ok, summary} <- reconcile(Map.take(target, @scope_fields)),
           :ok <- exact_release_projection(summary),
           [campaign, successor] <- release_candidates(target.id),
           true <- campaign.role == "campaign" and successor.role == "successor",
           key when is_binary(key) <- value(attrs, :idempotency_key),
           true <- nonempty?(key),
           {:ok, b1_experiment_id} <- Ecto.UUID.cast(value(attrs, :b1_experiment_id)),
           %Experiment{} <- release_b1_experiment(target, b1_experiment_id),
           replay <-
             activate_gate_replay(
               open_gate,
               target,
               key,
               campaign,
               successor,
               b1_experiment_id
             ) do
        case replay do
          {:replay, gate} ->
            {:replay, gate}

          :new ->
            request =
              release_capture_request(
                open_gate,
                target,
                campaign,
                successor,
                b1_experiment_id
              )

            case insert_release_challenge(open_gate, target, request) do
              {:ok, challenge} ->
                %{
                  scope: scope,
                  key: key,
                  open_gate_id: open_gate.id,
                  target_id: target.id,
                  b1_experiment_id: b1_experiment_id,
                  request: request,
                  challenge: challenge
                }

              {:error, reason} ->
                Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_activate_release_gate)
      end
    end)
  end

  defp finalize_activate_release_gate(context, captures) do
    Repo.transaction(fn ->
      with :ok <- put_release_capture_hmac_secret(),
           %ReleaseGate{stage: "open"} = open_gate <-
             Repo.one(
               from gate in ReleaseGate,
                 where: gate.id == ^context.open_gate_id,
                 lock: "FOR SHARE"
             ),
           true <- release_gate_scope?(open_gate, context.scope),
           %Wave{} = target <- Repo.get(Wave, context.target_id),
           {:ok, summary} <- reconcile(Map.take(target, @scope_fields)),
           :ok <- exact_release_projection(summary),
           [campaign, successor] <- release_candidates(target.id),
           true <- campaign.role == "campaign" and successor.role == "successor",
           true <-
             context.request ==
               release_capture_request(
                 open_gate,
                 target,
                 campaign,
                 successor,
                 context.b1_experiment_id
               ),
           %Challenge{} = challenge <-
             Repo.one(
               from row in Challenge,
                 where:
                   row.id == ^context.challenge.id and row.target_wave_id == ^target.id and
                     row.request_digest == ^EpicFleet.canonical_digest(context.request),
                 lock: "FOR UPDATE"
             ),
           true <- is_nil(challenge.completed_at),
           {:ok, capture_rows} <- persist_release_captures(challenge, captures, target),
           :ok <- complete_release_challenge(challenge),
           {:ok, lifecycle} <- projection(Map.take(ancestry_root_wave(target), @scope_fields)) do
        evidence = %{
          "challenge_id" => challenge.id,
          "papers" => Enum.map([campaign, successor], &paper_candidate_receipt/1),
          "captures" =>
            Map.new(
              capture_rows,
              &{&1.name,
               %{
                 "content_digest" => &1.content_digest,
                 "provenance_digest" => &1.provenance_digest,
                 "verdict_digest" => &1.verdict_digest
               }}
            )
        }

        unsigned = %{
          "format" => "cycle-release-gate-v1",
          "stage" => "activate",
          "authority" => %{
            "workspace_id" => target.workspace_id,
            "project_id" => target.project_id,
            "epic_id" => target.epic_id,
            "root_wave_revision" => open_gate.root_wave_id,
            "target_wave_revision" => target.id,
            "open_gate_id" => open_gate.id
          },
          "projection" => %{
            "inventory_count" => 503,
            "assigned_count" => 503,
            "shipped_count" => 42,
            "stalled_count" => 291,
            "excluded_count" => 170,
            "exact" => true,
            "fleet_complete" => true
          },
          "authorities" => release_task_authority(ancestry_root_wave(target)),
          "b1_experiment_id" => context.b1_experiment_id,
          "papers" => evidence["papers"],
          "captures" => evidence["captures"],
          "correction_lifecycle_digest" =>
            EpicFleet.canonical_digest(lifecycle.correction_lifecycle),
          "bundle_digest" => EpicFleet.canonical_digest(evidence)
        }

        receipt = Map.put(unsigned, "receipt_digest", EpicFleet.canonical_digest(unsigned))

        activation_attrs = %{
          stage: "activate",
          root_wave_id: open_gate.root_wave_id,
          parent_wave_id: open_gate.parent_wave_id,
          target_wave_id: target.id,
          reserved_target_revision: target.id,
          workspace_id: target.workspace_id,
          project_id: target.project_id,
          epic_id: target.epic_id,
          target_wave_key: target.wave_id,
          idempotency_key: context.key,
          challenge_id: challenge.id,
          evidence_bundle: evidence,
          receipt: receipt,
          bundle_digest: unsigned["bundle_digest"],
          receipt_digest: receipt["receipt_digest"]
        }

        case Repo.get_by(ReleaseGate,
               root_wave_id: open_gate.root_wave_id,
               stage: "activate",
               idempotency_key: context.key
             ) do
          %ReleaseGate{receipt: ^receipt} = replay ->
            replay

          %ReleaseGate{} ->
            Repo.rollback(:release_gate_conflict)

          nil ->
            with {:ok, admission} <- Repo.insert(ReleaseGate.changeset(activation_attrs)),
                 :ok <- consume_release_gate(admission, target, "activate") do
              admission
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_activate_release_gate)
      end
    end)
  end

  defp exact_release_projection(summary) do
    defects =
      ~w(duplicate_assignment_unit_ids unknown_assignment_unit_ids unknown_outcome_unit_ids outcome_overlap_unit_ids outcome_ownership_violation_unit_ids invalid_build_assignment_ids invalid_build_result_assignment_ids unassigned_unit_ids unaccounted_unit_ids)a

    if summary.inventory_count == 503 and summary.assigned_count == 503 and
         summary.shipped_count == 42 and
         summary.stalled_count == 291 and summary.excluded_count == 170 and summary.exact and
         summary.fleet_complete and
         Enum.all?(defects, &(Map.get(summary, &1) == [])),
       do: :ok,
       else: {:error, :release_projection_incomplete}
  end

  defp release_candidates(target_id),
    do:
      Repo.all(
        from c in PaperCandidate,
          join: d in Document,
          on:
            d.id == c.document_id and d.rev == c.base_document_rev and
              fragment(
                "? IS NOT DISTINCT FROM ?",
                d.current_revision_id,
                c.base_current_revision_id
              ) and
              fragment(
                "? IS NOT DISTINCT FROM ?",
                d.released_revision_id,
                c.base_released_revision_id
              ),
          where: c.target_wave_id == ^target_id,
          order_by: c.role,
          select: c,
          lock: "FOR SHARE"
      )

  defp release_capture_request(gate, target, campaign, successor, b1_experiment_id) do
    workspace = Repo.get!(Workspace, target.workspace_id)
    project = Repo.get!(Project, target.project_id)
    origin = BarkparkWeb.Endpoint.url()

    deployment_digest = release_deployment_digest!()

    candidates = %{
      "campaign" => paper_candidate_receipt(campaign),
      "successor" => paper_candidate_receipt(successor)
    }

    %{
      "format" => "cycle-release-capture-request-v1",
      "release_gate_id" => gate.id,
      "wave_revision" => target.id,
      "workspace_id" => target.workspace_id,
      "workspace_slug" => workspace.slug,
      "project_id" => target.project_id,
      "project_slug" => project.slug,
      "epic_id" => target.epic_id,
      "wave_id" => target.wave_id,
      "b1_experiment_id" => b1_experiment_id,
      "canonical_origin" => origin,
      "deployment_digest" => deployment_digest,
      "candidates" => candidates,
      "readers" =>
        Map.new(candidates, fn {role, candidate} ->
          {role,
           release_reader_requests(
             origin,
             workspace.slug,
             project.slug,
             gate.id,
             target,
             role,
             candidate,
             deployment_digest
           )}
        end)
    }
  end

  defp release_reader_requests(
         origin,
         workspace_slug,
         project_slug,
         gate_id,
         target,
         role,
         candidate,
         deployment_digest
       ) do
    workspace_slug = encode_route_segment(workspace_slug)
    project_slug = encode_route_segment(project_slug)
    epic_id = encode_route_segment(target.epic_id)
    wave_id = encode_route_segment(target.wave_id)
    gate_id = encode_route_segment(gate_id)
    role = encode_route_segment(role)

    base =
      "/w/#{workspace_slug}/p/#{project_slug}/v1/cycles/#{epic_id}/#{wave_id}" <>
        "/release-gates/#{gate_id}/papers/#{role}"

    query =
      "wave_revision=#{target.id}&candidate_id=#{candidate["candidate_id"]}"

    source_url = origin <> base <> "/source?" <> query
    render_url = origin <> base <> "/render?" <> query

    argv = [
      "bp",
      "paper",
      "capture",
      source_url,
      "--release-gate",
      gate_id,
      "--wave-revision",
      target.id,
      "--candidate-id",
      candidate["candidate_id"],
      "--role",
      role,
      "--deployment-digest",
      deployment_digest,
      "--width",
      "120",
      "-o",
      "json"
    ]

    %{
      "source_json" => %{"method" => "GET", "url" => source_url},
      "public_html" => %{"method" => "GET", "url" => render_url},
      "cli" => %{"argv" => argv},
      "task_board" => %{"argv" => argv},
      "tui" => %{"argv" => argv}
    }
  end

  defp encode_route_segment(value),
    do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  defp release_b1_experiment(target, id) do
    Repo.one(
      from experiment in Experiment,
        where:
          experiment.id == ^id and experiment.workspace_id == ^target.workspace_id and
            experiment.epic_id == ^target.epic_id and experiment.wave_id == ^target.wave_id and
            experiment.artifact_format == "barkpark-epic-benchmark-v1",
        lock: "FOR SHARE"
    )
  end

  defp activate_gate_replay(
         open_gate,
         target,
         key,
         campaign,
         successor,
         b1_experiment_id
       ) do
    case Repo.get_by(ReleaseGate,
           root_wave_id: open_gate.root_wave_id,
           stage: "activate",
           idempotency_key: key
         ) do
      nil ->
        :new

      %ReleaseGate{} = gate ->
        papers = [paper_candidate_receipt(campaign), paper_candidate_receipt(successor)]

        if gate.target_wave_id == target.id and gate.receipt["papers"] == papers and
             get_in(gate.receipt, ["authority", "open_gate_id"]) == open_gate.id and
             gate.receipt["b1_experiment_id"] == b1_experiment_id,
           do: {:replay, gate},
           else: {:error, :release_gate_conflict}
    end
  end

  defp insert_release_challenge(_gate, target, request) do
    request_digest = EpicFleet.canonical_digest(request)

    existing =
      Repo.one(
        from challenge in Challenge,
          where:
            challenge.target_wave_id == ^target.id and is_nil(challenge.completed_at) and
              is_nil(challenge.failed_at),
          lock: "FOR UPDATE"
      )

    attrs = %{
      target_wave_id: target.id,
      workspace_id: target.workspace_id,
      project_id: target.project_id,
      epic_id: target.epic_id,
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      request: request,
      request_digest: request_digest
    }

    case existing do
      %Challenge{request_digest: ^request_digest, request: ^request} = challenge ->
        {:ok, challenge}

      %Challenge{} ->
        {:error, :release_challenge_conflict}

      nil ->
        with {:ok, challenge} <- Repo.insert(Challenge.changeset(attrs)),
             {1, _} <-
               Repo.update_all(
                 from(c in Challenge, where: c.id == ^challenge.id and is_nil(c.claimed_at)),
                 set: [claimed_at: DateTime.utc_now()]
               ) do
          {:ok, Repo.get!(Challenge, challenge.id)}
        else
          _ -> {:error, :release_challenge_conflict}
        end
    end
  end

  defp fail_release_challenge(challenge_id, code, result) do
    Repo.update_all(
      from(challenge in Challenge,
        where:
          challenge.id == ^challenge_id and is_nil(challenge.completed_at) and
            is_nil(challenge.failed_at)
      ),
      set: [failed_at: DateTime.utc_now(), failure: code]
    )

    result
  end

  defp persist_release_captures(challenge, captures, target) when is_map(captures) do
    if Map.keys(captures) |> Enum.sort() == Enum.sort(@release_capture_names) do
      rows =
        Enum.map(@release_capture_names, fn name ->
          persist_release_capture!(challenge, name, captures[name], target)
        end)

      {:ok, rows}
    else
      {:error, :incomplete_server_capture}
    end
  rescue
    _ -> {:error, :invalid_server_capture}
  end

  defp persist_release_capture!(challenge, name, capture, target) do
    raw = capture[:raw_bytes] || capture["raw_bytes"]
    producer = capture[:producer] || capture["producer"]
    provenance = stringify_keys(capture[:provenance] || capture["provenance"] || %{})
    [role, surface] = String.split(name, ".", parts: 2)
    candidate = challenge.request["candidates"][role]
    pass = valid_release_capture?(raw, producer, provenance, role, surface, candidate, challenge)

    unless pass do
      Repo.rollback(:invalid_server_capture)
    end

    verdict = %{"status" => "pass", "wave_revision" => target.id}

    attrs = %{
      challenge_id: challenge.id,
      name: name,
      producer: producer,
      raw_bytes: raw,
      byte_count: byte_size(raw || ""),
      content_digest: sha256_bytes(raw || ""),
      provenance: provenance,
      provenance_digest: EpicFleet.canonical_digest(provenance),
      verdict: verdict,
      verdict_digest: EpicFleet.canonical_digest(verdict)
    }

    attrs = Map.put(attrs, :server_signature, release_capture_signature(attrs))

    case Repo.insert(Capture.changeset(attrs)) do
      {:ok, row} -> row
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp put_release_capture_hmac_secret do
    case Application.get_env(:barkpark, :cycle_release_capture_hmac_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        case Repo.query(
               "SELECT set_config('barkpark.release_capture_hmac_secret', $1, true)",
               [secret],
               log: false
             ) do
          {:ok, _} -> :ok
          _ -> {:error, :release_capture_signing_unavailable}
        end

      _ ->
        {:error, :release_capture_signing_unavailable}
    end
  end

  defp release_capture_signature(attrs) do
    payload =
      Enum.join(
        [
          attrs.challenge_id,
          attrs.name,
          attrs.producer,
          Integer.to_string(attrs.byte_count),
          attrs.content_digest,
          attrs.provenance_digest,
          attrs.verdict_digest
        ],
        "\n"
      )

    release_hmac(payload)
  end

  defp release_hmac(payload) do
    secret = Application.fetch_env!(:barkpark, :cycle_release_capture_hmac_secret)

    :hmac
    |> :crypto.mac(:sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  defp valid_release_capture?(raw, producer, provenance, role, surface, candidate, challenge) do
    expected_producer =
      case surface do
        value when value in ["source_json", "public_html"] -> "server_http"
        value when value in ["cli", "task_board"] -> "server_cli"
        "tui" -> "server_tui"
      end

    base =
      is_binary(raw) and String.valid?(raw) and byte_size(raw) > 31 and
        producer == expected_producer and
        provenance["release_gate_id"] == challenge.request["release_gate_id"] and
        provenance["wave_revision"] == challenge.target_wave_id and
        provenance["candidate_id"] == candidate["candidate_id"] and
        provenance["role"] == role and provenance["surface"] == surface and
        provenance["redirect_count"] == 0 and
        provenance["request"] == challenge.request["readers"][role][surface] and
        provenance["deployment_digest"] == challenge.request["deployment_digest"] and
        digest_string?(provenance["binary_digest"]) and
        digest_string?(provenance["parser_digest"]) and
        valid_headless_provenance?(
          surface,
          provenance,
          challenge.request["readers"][role][surface]
        )

    base and valid_release_capture_body?(raw, provenance, role, surface, candidate, challenge)
  rescue
    _ -> false
  end

  defp valid_headless_provenance?(surface, _provenance, _request)
       when surface in ["source_json", "public_html"],
       do: true

  defp valid_headless_provenance?("cli", provenance, request),
    do:
      provenance["argv"] == request["argv"] and provenance["geometry"] == "120xunbounded" and
        provenance["theme"] == "evergreen-dark" and provenance["profile"] == "none"

  defp valid_headless_provenance?("task_board", provenance, request),
    do:
      provenance["argv"] == request["argv"] and provenance["geometry"] == "120xunbounded" and
        provenance["theme"] == "task-board-dark" and provenance["profile"] == "ansi256"

  defp valid_headless_provenance?("tui", provenance, request),
    do:
      provenance["argv"] == request["argv"] and
        provenance["geometry"] == "120xunbounded;measure=100" and
        provenance["theme"] == "evergreen-dark" and provenance["profile"] == "ansi256"

  defp valid_release_capture_body?(raw, provenance, role, "source_json", candidate, challenge) do
    headers = provenance["response_headers"] || %{}

    with {:ok, decoded} <- Jason.decode(raw) do
      decoded["release_gate_id"] == challenge.request["release_gate_id"] and
        decoded["wave_revision"] == challenge.target_wave_id and
        decoded["candidate_id"] == candidate["candidate_id"] and decoded["role"] == role and
        decoded["document_id"] == candidate["document_id"] and
        decoded["doc_id"] == candidate["doc_id"] and
        decoded["title"] == candidate["title"] and
        decoded["content_digest"] == candidate["content_digest"] and
        EpicFleet.canonical_digest(decoded["source"]) == candidate["source_digest"] and
        provenance["status"] == 200 and
        release_headers_match?(headers, candidate, role, challenge)
    else
      _ -> false
    end
  end

  defp valid_release_capture_body?(raw, provenance, role, "public_html", candidate, challenge) do
    headers = provenance["response_headers"] || %{}
    text = String.downcase(raw)

    provenance["status"] == 200 and release_headers_match?(headers, candidate, role, challenge) and
      String.contains?(text, "<") and not String.contains?(text, "data-release-debug") and
      String.contains?(text, String.downcase(candidate["title"])) and release_markers?(text)
  end

  defp valid_release_capture_body?(raw, provenance, _role, surface, candidate, challenge)
       when surface in ["cli", "task_board", "tui"] do
    text = String.downcase(raw)

    provenance["status"] == 0 and
      provenance["wave_revision"] == challenge.target_wave_id and
      String.contains?(text, String.downcase(candidate["title"])) and release_markers?(text)
  end

  defp release_markers?(text),
    do: Enum.all?(~w(503 42 291 170 current superseded -11 +11), &String.contains?(text, &1))

  defp release_headers_match?(headers, candidate, role, challenge) do
    headers["etag"] == ~s("sha256:#{candidate["content_digest"]}") and
      headers["x_barkpark_release_gate"] == challenge.request["release_gate_id"] and
      headers["x_barkpark_wave_revision"] == challenge.target_wave_id and
      headers["x_barkpark_paper_candidate"] == candidate["candidate_id"] and
      headers["x_barkpark_paper_role"] == role
  end

  defp complete_release_challenge(challenge) do
    case Repo.update_all(
           from(c in Challenge,
             where: c.id == ^challenge.id and not is_nil(c.claimed_at) and is_nil(c.completed_at)
           ),
           set: [completed_at: DateTime.utc_now()]
         ) do
      {1, _} -> :ok
      _ -> {:error, :challenge_conflict}
    end
  end

  defp paper_candidate_receipt(candidate),
    do: %{
      "candidate_id" => candidate.id,
      "role" => candidate.role,
      "document_id" => candidate.document_id,
      "doc_id" => candidate.doc_id,
      "title" => candidate.title,
      "base_document_rev" => candidate.base_document_rev,
      "base_current_revision_id" => candidate.base_current_revision_id,
      "base_released_revision_id" => candidate.base_released_revision_id,
      "content_digest" => candidate.content_digest,
      "source_digest" => candidate.source_digest
    }

  defp release_gate_scope?(gate, scope) do
    gate.workspace_id == scope.workspace_id and gate.project_id == scope.project_id and
      gate.epic_id == scope.epic_id and gate.target_wave_key == scope.wave_id
  end

  defp locked_release_document(id, gate) do
    Repo.one(
      from d in Document,
        where:
          d.id == ^id and d.workspace_id == ^gate.workspace_id and
            d.project_id == ^gate.project_id and
            d.type == "paper" and d.dataset == "production",
        lock: "FOR SHARE"
    )
  end

  defp validate_candidate_paper(_role, content, summary) do
    blocks = content["blocks"] || content[:blocks]

    authority =
      is_list(blocks) &&
        Enum.filter(
          blocks,
          &(is_map(&1) and (Map.has_key?(&1, "cycle_ledger") or Map.has_key?(&1, :cycle_ledger)))
        )

    case authority do
      [block] ->
        block = stringify_keys(block)
        ledger = block["cycle_ledger"] || %{}
        lifecycle = block["correction_lifecycle"] || %{}
        expected_lifecycle = prospective_correction_lifecycle!(summary.wave_revision)

        if ledger == stringify_keys(summary) and
             block["fleet"] == stringify_keys(summary.canonical_fleet) and
             lifecycle == stringify_keys(expected_lifecycle),
           do: :ok,
           else: {:error, :paper_candidate_authority_mismatch}

      _ ->
        {:error, :paper_candidate_authority_mismatch}
    end
  end

  @doc "Project the stable correction lifecycle that will hold after this linked Wave is promoted."
  def prospective_correction_lifecycle(scope) when is_map(scope) do
    case get_wave(scope) do
      %Wave{} = target -> {:ok, prospective_correction_lifecycle!(target.id)}
      nil -> {:error, :wave_not_found}
    end
  end

  defp prospective_correction_lifecycle!(target_id) do
    target = Repo.get!(Wave, target_id)
    root = ancestry_root_wave(target)

    ancestry = [root | correction_successors_to(root, target)]

    promoted =
      case Promotion.chain(root.id) do
        {:ok, events} ->
          events
          |> Enum.filter(&(&1.action == "promote"))
          |> Enum.map(& &1.target_wave_id)

        _ ->
          []
      end

    superseded_ids =
      [root.id | promoted]
      |> Enum.reject(&(&1 == target.id))
      |> Enum.uniq()

    superseded = Enum.map(superseded_ids, &(Repo.get!(Wave, &1) |> lifecycle_wave("superseded")))

    %{
      format: "cycle-correction-lifecycle-v1",
      ancestry_root:
        lifecycle_wave(root, if(root.id == target.id, do: "current", else: "superseded")),
      current: lifecycle_wave(target, "current"),
      superseded: superseded,
      historical_ancestry:
        ancestry
        |> tl()
        |> Enum.map(fn wave ->
          status =
            cond do
              wave.id == target.id -> "current"
              wave.id in superseded_ids -> "superseded"
              true -> "historical"
            end

          lifecycle_wave(wave, status)
        end)
    }
  end

  @spec open_wave(map()) :: {:ok, Wave.t()} | {:error, Ecto.Changeset.t() | atom()}
  def open_wave(attrs) when is_map(attrs) do
    if is_nil(value(attrs, :correction_of)) do
      open_standard_wave(attrs)
    else
      open_correction_wave(attrs)
    end
  end

  defp open_standard_wave(attrs) do
    with {:ok, scope} <- normalize_scope(attrs),
         {:ok, profile} <- Profile.normalize(value(attrs, :profile, "epic")),
         {:ok, inventory} <- normalize_inventory(value(attrs, :inventory, [])),
         {:ok, plan} <- Profile.opening_plan(profile),
         {:ok, scale_contract} <-
           normalize_scale_contract(profile, value(attrs, :scale_contract), inventory),
         {:ok, experiment_contract} <-
           normalize_experiment_contract(profile, value(attrs, :experiment_contract)) do
      wave_attrs =
        Map.merge(scope, %{
          profile: profile,
          inventory: inventory,
          inventory_digest: digest(inventory),
          plan: stringify_keys(plan),
          plan_digest: digest(plan),
          experiment_contract: experiment_contract,
          scale_contract: scale_contract
        })

      wave_attrs
      |> Wave.insert_changeset()
      |> Repo.insert()
      |> reconcile_wave_insert(wave_attrs)
    end
  end

  defp open_correction_wave(attrs) do
    Repo.transaction(fn ->
      with :ok <- reject_ambiguous_correction_attrs(attrs),
           {:ok, scope} <- normalize_scope(attrs),
           correction when is_map(correction) <- value(attrs, :correction_of),
           correction_digest when is_binary(correction_digest) <-
             value(attrs, :correction_of_digest),
           true <-
             correction_digest == digest(stringify_keys(correction)) ||
               {:error, :correction_digest_mismatch},
           {:ok, prior, canonical} <- validate_correction(scope, correction, attrs, true),
           {:ok, gate} <-
             locked_open_release_gate(
               scope,
               prior,
               canonical,
               value(attrs, :release_gate_receipt)
             ) do
        wave_attrs =
          Map.merge(scope, %{
            profile: prior.profile,
            inventory: prior.inventory,
            inventory_digest: prior.inventory_digest,
            plan: effective_plan(prior),
            plan_digest: effective_plan_digest(prior),
            experiment_contract: prior.experiment_contract,
            scale_contract: prior.scale_contract,
            correction_of_wave_id: prior.id,
            correction_of: canonical,
            correction_of_digest: digest(canonical)
          })

        changeset =
          Wave.insert_changeset(wave_attrs)
          |> Ecto.Changeset.put_change(:id, gate.reserved_target_revision)

        case Repo.insert(changeset, on_conflict: :nothing) do
          {:ok, _candidate} ->
            case get_wave_by_scope(scope) do
              %Wave{} = wave ->
                if wave_replay?(wave, wave_attrs) do
                  with true <- wave.id == gate.reserved_target_revision,
                       :ok <- consume_release_gate(gate, wave, "open") do
                    wave
                  else
                    _ -> Repo.rollback(:release_gate_conflict)
                  end
                else
                  Repo.rollback(:wave_conflict)
                end

              nil ->
                Repo.rollback(:wave_conflict)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_correction_of)
      end
    end)
  end

  defp locked_open_release_gate(scope, prior, canonical, receipt) when is_map(receipt) do
    receipt = stringify_keys(receipt)
    digest = receipt["receipt_digest"]
    root = ancestry_root_wave(prior)

    gate =
      Repo.one(
        from g in ReleaseGate,
          where: g.stage == "open" and g.receipt_digest == ^digest,
          lock: "FOR UPDATE"
      )

    with %ReleaseGate{} = gate <- gate,
         true <- gate.receipt == receipt,
         true <- gate.parent_wave_id == prior.id,
         true <- gate.workspace_id == scope.workspace_id and gate.project_id == scope.project_id,
         true <- gate.epic_id == scope.epic_id and gate.target_wave_key == scope.wave_id,
         true <- receipt["authorities"] == release_task_authority(root),
         true <-
           get_in(receipt, ["proposed", "correction_of_digest"]) ==
             digest(canonical) do
      {:ok, gate}
    else
      _ -> {:error, :invalid_open_release_gate}
    end
  end

  defp locked_open_release_gate(_, _, _, _), do: {:error, :invalid_open_release_gate}

  defp consume_release_gate(gate, wave, kind) do
    case Repo.get(Consumption, gate.id) do
      %Consumption{wave_id: wave_id, kind: ^kind} when wave_id == wave.id ->
        :ok

      %Consumption{} ->
        {:error, :release_gate_conflict}

      nil ->
        %{admission_id: gate.id, wave_id: wave.id, kind: kind}
        |> Consumption.changeset()
        |> Repo.insert()
        |> case do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :release_gate_conflict}
        end
    end
  end

  defp release_task_authority(root) do
    opts = [workspace_id: root.workspace_id, project_id: root.project_id, dataset: "production"]

    task_root =
      Repo.one(
        from d in Document,
          where:
            d.workspace_id == ^root.workspace_id and d.project_id == ^root.project_id and
              d.dataset == "production" and d.type == "task" and d.doc_id == ^root.epic_id,
          order_by: [desc: d.status == "published", desc: d.inserted_at],
          limit: 1,
          lock: "FOR SHARE"
      )

    ready = Queue.ready(opts ++ [phase_id: root.epic_id, order: :closure_nearest, limit: 10_000])

    queue =
      Enum.map([task_root | ready] |> Enum.reject(&is_nil/1), fn row ->
        gate =
          case QueueGate.sanitize(row.content["queue_gate"]) do
            {:ok, value} -> value
            _ -> "invalid"
          end

        %{"id" => row.id, "doc_id" => row.doc_id, "rev" => row.rev, "queue_gate" => gate}
      end)

    order = Enum.map(ready, &%{"id" => &1.id, "doc_id" => &1.doc_id, "rev" => &1.rev})

    %{
      "queue_gate_digest" => EpicFleet.canonical_digest(queue),
      "order_digest" => EpicFleet.canonical_digest(order),
      "rail_digest" => Rail.rev(root.epic_id, opts),
      "semantic_digest" => EpicFleet.canonical_digest((task_root && task_root.content) || %{}),
      "correction_digest" => root.correction_of_digest || EpicFleet.canonical_digest(%{})
    }
  end

  defp validate_correction(scope, submitted, launch_attrs, lock?) do
    submitted = stringify_keys(submitted)
    prior_pin = value(submitted, :prior, %{})

    with true <-
           value(submitted, :version) == "correction_of-v1" || {:error, :invalid_correction_of},
         prior_revision when is_binary(prior_revision) <- value(prior_pin, :wave_revision),
         %Wave{} = prior <- correction_parent(prior_revision, lock?),
         :ok <- validate_correction_scope(scope, prior, prior_pin),
         :ok <- validate_supplied_successor_attrs(prior, launch_attrs),
         {:ok, ancestry} <- correction_ancestry(prior),
         {:ok, prior_summary} <- reconcile(Map.take(prior, @scope_fields)),
         :ok <- validate_prior_repairability(prior_summary),
         :ok <- validate_prior_pins(prior, prior_summary, prior_pin),
         {:ok, targets, outcomes} <- correction_targets(prior, prior_summary),
         true <- value(submitted, :targets) == targets || {:error, :stale_correction_targets},
         {:ok, changes} <- correction_changes(value(submitted, :changes), targets, outcomes),
         {:ok, arithmetic} <- correction_arithmetic(prior, outcomes, changes) do
      canonical = %{
        "version" => "correction_of-v1",
        "prior" => %{
          "workspace_id" => prior.workspace_id,
          "project_id" => prior.project_id,
          "epic_id" => prior.epic_id,
          "wave_id" => prior.wave_id,
          "wave_revision" => prior.id,
          "inventory_digest" => prior.inventory_digest,
          "effective_plan_digest" => effective_plan_digest(prior),
          "reconciliation_digest" => prior_summary.reconciliation_digest
        },
        "ancestry" => ancestry,
        "targets" => targets,
        "changes" => changes,
        "inventory_count" => arithmetic.inventory_count,
        "before_counts" => arithmetic.before_counts,
        "delta" => arithmetic.delta,
        "after_counts" => arithmetic.after_counts
      }

      if submitted == canonical,
        do: {:ok, prior, canonical},
        else: {:error, :correction_digest_mismatch}
    else
      nil -> {:error, :correction_prior_not_found}
      false -> {:error, :invalid_correction_of}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_correction_of}
    end
  end

  defp correction_parent(id, true), do: locked_wave(id)
  defp correction_parent(id, false), do: Repo.get(Wave, id)

  defp validate_persisted_correction(%Wave{correction_of_wave_id: nil}), do: :ok

  defp validate_persisted_correction(%Wave{} = wave) do
    scope = Map.take(wave, @scope_fields)

    with true <- wave.correction_of_digest == digest(wave.correction_of),
         {:ok, %Wave{id: parent_id}, canonical} <-
           validate_correction(scope, wave.correction_of, %{}, false),
         true <- parent_id == wave.correction_of_wave_id,
         true <- canonical == wave.correction_of do
      :ok
    else
      _ -> {:error, :invalid_persisted_correction}
    end
  end

  defp locked_wave(id) do
    Repo.one(from(w in Wave, where: w.id == ^id, lock: "FOR UPDATE"))
  end

  defp reject_ambiguous_correction_attrs(attrs) do
    correction = value(attrs, :correction_of)

    if Enum.any?([:correction_of, :correction_of_digest], fn key ->
         Map.has_key?(attrs, key) and Map.has_key?(attrs, to_string(key))
       end) or ambiguous_normalized_keys?(correction) do
      {:error, :ambiguous_correction_attrs}
    else
      :ok
    end
  end

  defp ambiguous_normalized_keys?(map) when is_map(map) do
    normalized = Enum.map(Map.keys(map), &to_string/1)

    length(normalized) != MapSet.size(MapSet.new(normalized)) or
      Enum.any?(Map.values(map), &ambiguous_normalized_keys?/1)
  end

  defp ambiguous_normalized_keys?(list) when is_list(list),
    do: Enum.any?(list, &ambiguous_normalized_keys?/1)

  defp ambiguous_normalized_keys?(_value), do: false

  defp validate_supplied_successor_attrs(prior, attrs) do
    checks = [
      {:profile, prior.profile, & &1},
      {:inventory, prior.inventory,
       fn inventory ->
         case normalize_inventory(inventory) do
           {:ok, normalized} -> normalized
           _ -> :invalid
         end
       end},
      {:experiment_contract, prior.experiment_contract, &stringify_keys/1},
      {:scale_contract, prior.scale_contract, &stringify_keys/1}
    ]

    if Enum.all?(checks, fn {key, expected, normalize} ->
         not correction_attr_present?(attrs, key) or normalize.(value(attrs, key)) == expected
       end) do
      :ok
    else
      {:error, :conflicting_correction_contract}
    end
  end

  defp correction_attr_present?(attrs, key),
    do: Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key))

  defp validate_prior_repairability(summary) do
    empty_fields = [
      :duplicate_assignment_unit_ids,
      :unknown_assignment_unit_ids,
      :unknown_outcome_unit_ids,
      :outcome_overlap_unit_ids,
      :outcome_ownership_violation_unit_ids,
      :invalid_build_assignment_ids,
      :unassigned_unit_ids,
      :unaccounted_unit_ids
    ]

    structurally_clean? =
      Enum.all?(empty_fields, &(Map.fetch!(summary, &1) == [])) and summary.experiment.complete? and
        summary.fleet_complete

    repair_target? =
      summary.invalid_build_result_assignment_ids != [] or
        (not is_nil(summary.correction_of) and summary.exact)

    if structurally_clean? and repair_target? do
      :ok
    else
      {:error, :correction_prior_not_repairable}
    end
  end

  defp validate_correction_scope(scope, prior, prior_pin) do
    cond do
      prior.workspace_id != scope.workspace_id or prior.project_id != scope.project_id or
          prior.epic_id != scope.epic_id ->
        {:error, :foreign_correction_prior}

      prior.wave_id == scope.wave_id ->
        {:error, :same_wave_correction}

      value(prior_pin, :workspace_id) != prior.workspace_id or
        value(prior_pin, :project_id) != prior.project_id or
        value(prior_pin, :epic_id) != prior.epic_id or
          value(prior_pin, :wave_id) != prior.wave_id ->
        {:error, :stale_correction_prior}

      true ->
        :ok
    end
  end

  defp validate_prior_pins(prior, summary, prior_pin) do
    if value(prior_pin, :inventory_digest) == prior.inventory_digest and
         value(prior_pin, :effective_plan_digest) == effective_plan_digest(prior) and
         value(prior_pin, :reconciliation_digest) == summary.reconciliation_digest do
      :ok
    else
      {:error, :stale_correction_prior}
    end
  end

  defp correction_ancestry(prior), do: correction_ancestry(prior, MapSet.new(), [])

  defp correction_ancestry(%Wave{} = wave, seen, ancestry) do
    if MapSet.member?(seen, wave.id) do
      {:error, :circular_correction_ancestry}
    else
      entry = %{"wave_id" => wave.wave_id, "wave_revision" => wave.id}
      seen = MapSet.put(seen, wave.id)

      case wave.correction_of_wave_id do
        nil ->
          {:ok, [entry | ancestry]}

        prior_id ->
          case Repo.get(Wave, prior_id) do
            %Wave{} = parent ->
              if parent.workspace_id == wave.workspace_id and parent.project_id == wave.project_id and
                   parent.epic_id == wave.epic_id do
                correction_ancestry(parent, seen, [entry | ancestry])
              else
                {:error, :foreign_correction_ancestry}
              end

            nil ->
              {:error, :correction_prior_not_found}
          end
      end
    end
  end

  defp correction_targets(prior, prior_summary) do
    invalid_ids = MapSet.new(prior_summary.invalid_build_result_assignment_ids)

    if MapSet.size(invalid_ids) == 0 and not is_nil(prior.correction_of) do
      targets = Map.fetch!(prior.correction_of, "targets")
      {:ok, outcomes} = effective_outcomes(prior)
      target_revisions = MapSet.new(targets, & &1["assignment_revision"])

      target_outcomes =
        Map.new(outcomes, fn {unit_id, outcome} -> {unit_id, outcome} end)
        |> Map.filter(fn {_unit_id, outcome} ->
          MapSet.member?(target_revisions, outcome.assignment.id)
        end)

      {:ok, targets, target_outcomes}
    else
      correction_targets_from_invalid(prior, invalid_ids)
    end
  end

  defp correction_targets_from_invalid(prior, invalid_ids) do
    rows =
      prior
      |> Map.take(@scope_fields)
      |> list_assignments()
      |> Enum.map(&{&1, EpicFleet.get_result(&1)})
      |> exclude_replaced_rows()
      |> Enum.filter(fn {assignment, _result} ->
        assignment.phase == "build" and MapSet.member?(invalid_ids, assignment.assignment_id)
      end)

    raw_targets =
      rows
      |> Enum.map(fn {assignment, result} -> correction_target(assignment, result) end)

    targets =
      raw_targets
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{&1["assignment_id"], &1["assignment_revision"]})

    target_ids = MapSet.new(targets, & &1["assignment_id"])

    cond do
      MapSet.size(invalid_ids) == 0 ->
        {:error, :correction_targets_required}

      target_ids != invalid_ids ->
        {:error, :partial_correction_targets}

      length(raw_targets) != length(targets) ->
        {:error, :stale_correction_targets}

      true ->
        outcomes =
          Enum.reduce(rows, %{}, fn {assignment, %Result{payload: payload}}, acc ->
            {:ok, row_outcomes} = build_outcomes(payload)

            Map.merge(
              acc,
              Map.new(row_outcomes, fn {unit_id, disposition} ->
                {unit_id, %{assignment: assignment, disposition: disposition}}
              end)
            )
          end)

        {:ok, targets, outcomes}
    end
  end

  defp effective_outcomes(%Wave{} = wave) do
    base_wave =
      case wave.correction_of_wave_id do
        nil -> wave
        parent_id -> Repo.get!(Wave, parent_id)
      end

    base =
      if is_nil(wave.correction_of_wave_id) do
        wave
        |> Map.take(@scope_fields)
        |> list_assignments()
        |> Enum.map(&{&1, EpicFleet.get_result(&1)})
        |> exclude_replaced_rows()
        |> Enum.reduce(%{}, fn
          {%Assignment{phase: "build"} = assignment,
           %Result{status: "completed", payload: payload}},
          acc ->
            case build_outcomes(payload) do
              {:ok, outcomes} ->
                Map.merge(
                  acc,
                  Map.new(outcomes, fn {unit_id, disposition} ->
                    {unit_id, %{assignment: assignment, disposition: disposition}}
                  end)
                )

              _ ->
                acc
            end

          _, acc ->
            acc
        end)
      else
        {:ok, outcomes} = effective_outcomes(base_wave)
        outcomes
      end

    corrected =
      Enum.reduce((wave.correction_of || %{})["changes"] || [], base, fn change, acc ->
        update_in(acc, [change["unit_id"], :disposition], fn _ -> change["after"] end)
      end)

    {:ok, corrected}
  end

  defp correction_target(%Assignment{} = assignment, %Result{} = result) do
    %{
      "assignment_id" => assignment.assignment_id,
      "assignment_revision" => assignment.id,
      "snapshot_digest" => assignment.snapshot_digest,
      "result_revision" => result.id,
      "payload_digest" => result.payload_digest,
      "evidence_revision" => result.evidence_revision,
      "semantic_status" => "invalid",
      "semantic_receipt_index_hash" => value(result.payload, :semantic_receipt_index_hash)
    }
  end

  defp correction_target(_assignment, _result), do: nil

  defp correction_changes(changes, targets, outcomes) when is_list(changes) do
    target_revisions = MapSet.new(targets, & &1["assignment_revision"])
    normalized = changes |> Enum.map(&stringify_keys/1) |> Enum.sort_by(& &1["unit_id"])
    unit_ids = Enum.map(normalized, & &1["unit_id"])

    valid? =
      normalized != [] and length(unit_ids) == MapSet.size(MapSet.new(unit_ids)) and
        Enum.all?(normalized, fn change ->
          case Map.get(outcomes, change["unit_id"]) do
            %{assignment: assignment, disposition: before} ->
              change["assignment_id"] == assignment.assignment_id and
                change["assignment_revision"] == assignment.id and
                MapSet.member?(target_revisions, assignment.id) and
                change["before"] == before and change["after"] in ~w(shipped stalled excluded) and
                change["after"] != before and
                Enum.sort(Map.keys(change)) ==
                  ~w(after assignment_id assignment_revision before unit_id)

            nil ->
              false
          end
        end)

    if valid?, do: {:ok, normalized}, else: {:error, :invalid_correction_changes}
  end

  defp correction_changes(_changes, _targets, _outcomes),
    do: {:error, :invalid_correction_changes}

  defp correction_arithmetic(prior, target_outcomes, changes) do
    {:ok, effective} = effective_outcomes(prior)
    all_outcomes = Map.new(effective, fn {unit_id, row} -> {unit_id, row.disposition} end)

    after_outcomes =
      Enum.reduce(changes, all_outcomes, fn change, acc ->
        Map.put(acc, change["unit_id"], change["after"])
      end)

    before_counts = disposition_counts(all_outcomes)
    after_counts = disposition_counts(after_outcomes)
    inventory_count = length(prior.inventory)

    delta =
      Map.new(~w(shipped stalled excluded), fn key ->
        {key, Map.fetch!(after_counts, key) - Map.fetch!(before_counts, key)}
      end)

    changed_units = MapSet.new(changes, & &1["unit_id"])

    if map_size(all_outcomes) == inventory_count and map_size(after_outcomes) == inventory_count and
         MapSet.subset?(changed_units, MapSet.new(Map.keys(target_outcomes))) and
         Enum.sum(Map.values(before_counts)) == inventory_count and
         Enum.sum(Map.values(after_counts)) == inventory_count and
         Enum.sum(Map.values(delta)) == 0 do
      {:ok,
       %{
         inventory_count: inventory_count,
         before_counts: before_counts,
         delta: delta,
         after_counts: after_counts
       }}
    else
      {:error, :correction_inventory_invariant}
    end
  end

  defp disposition_counts(outcomes) do
    frequencies = outcomes |> Map.values() |> Enum.frequencies()
    Map.new(~w(shipped stalled excluded), &{&1, Map.get(frequencies, &1, 0)})
  end

  @spec get_wave(map()) :: Wave.t() | nil
  def get_wave(scope) when is_map(scope) do
    case normalize_scope(scope) do
      {:ok, scope} -> get_wave_by_scope(scope)
      _ -> nil
    end
  end

  @spec seal_build_plan(map(), map()) ::
          {:ok, BuildPlan.t()} | {:error, Ecto.Changeset.t() | atom()}
  def seal_build_plan(scope, attrs) when is_map(scope) and is_map(attrs) do
    with %Wave{} = wave <- get_wave(scope),
         :ok <- validate_seal_ready(wave),
         capacity when is_integer(capacity) and capacity > 0 <-
           value(attrs, :proven_batch_capacity),
         failure_threshold when is_number(failure_threshold) <-
           value(attrs, :failure_threshold),
         true <- failure_threshold == value(wave.scale_contract, :failure_threshold),
         {:ok, golden_fixtures} <-
           normalize_golden_fixtures(value(attrs, :golden_fixtures)),
         {:ok, plan} <-
           Profile.plan(wave.profile, %{
             unit_count: length(wave.inventory),
             proven_batch_capacity: capacity
           }) do
      plan_attrs = %{
        wave_id: wave.id,
        proven_batch_capacity: capacity,
        plan: stringify_keys(plan),
        plan_digest: digest(plan),
        inventory_digest: wave.inventory_digest,
        chosen_format: value(attrs, :chosen_format),
        pilot_evidence: value(attrs, :pilot_evidence),
        pilot_evidence_revision: value(attrs, :pilot_evidence_revision),
        failure_rate: value(attrs, :failure_rate),
        failure_threshold: failure_threshold,
        golden_fixtures: golden_fixtures,
        quality_rubric: value(wave.scale_contract, :quality_rubric)
      }

      plan_attrs
      |> BuildPlan.insert_changeset()
      |> Repo.insert()
      |> reconcile_build_plan_insert(plan_attrs)
    else
      nil -> {:error, :wave_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_build_plan}
    end
  end

  @spec get_build_plan(Wave.t() | map()) :: BuildPlan.t() | nil
  def get_build_plan(%Wave{id: wave_id}), do: Repo.get_by(BuildPlan, wave_id: wave_id)

  def get_build_plan(scope) when is_map(scope) do
    case get_wave(scope) do
      %Wave{} = wave -> get_build_plan(wave)
      nil -> nil
    end
  end

  @spec create_assignment(map()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_assignment(attrs) when is_map(attrs) do
    case get_wave(attrs) do
      nil ->
        {:error, :wave_not_found}

      %Wave{} = wave ->
        with {:ok, attrs} <- normalize_assignment_task_id(attrs),
             {:ok, attrs} <- resolve_replacement(attrs, wave),
             {:ok, plan} <- assignment_plan(attrs, wave),
             :ok <- validate_assignment_against_plan(attrs, plan, wave) do
          Repo.transaction(fn ->
            with {:ok, assignment, status} <-
                   attrs
                   |> put_attr(:cycle_wave_id, wave.id)
                   |> EpicFleet.create_assignment_with_status(),
                 {:ok, _binding} <-
                   preserve_assignment_task_binding(assignment, attrs, status) do
              assignment
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
          |> unwrap_assignment()
        end
    end
  end

  @doc "Freeze the server-owned Task bound to an existing CycleFleet assignment."
  @spec bind_assignment_task(Assignment.t() | Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, AssignmentTask.t()} | {:error, atom()}
  def bind_assignment_task(%Assignment{id: assignment_id}, task_id),
    do: bind_assignment_task(assignment_id, task_id)

  def bind_assignment_task(assignment_id, task_id)
      when is_binary(assignment_id) and is_binary(task_id) do
    with {:ok, task_id} <- cast_assignment_task_id(task_id) do
      Repo.transaction(fn ->
        authority =
          Repo.one(
            from(a in Assignment,
              join: w in Wave,
              on: w.id == a.cycle_wave_id and w.workspace_id == a.workspace_id,
              join: t in Document,
              on:
                t.id == ^task_id and t.type == "task" and
                  t.workspace_id == a.workspace_id and t.project_id == w.project_id,
              join: d in Dataset,
              on: d.id == t.dataset_id and d.project_id == w.project_id,
              where: a.id == ^assignment_id,
              lock: "FOR SHARE",
              select: %{assignment_id: a.id, task_id: t.id}
            )
          )

        case authority do
          nil ->
            Repo.rollback(:assignment_task_authority_not_found)

          attrs ->
            {inserted, _} =
              Repo.insert_all(AssignmentTask, [Map.put(attrs, :inserted_at, DateTime.utc_now())],
                on_conflict: :nothing
              )

            binding = Repo.get(AssignmentTask, assignment_id)

            cond do
              inserted == 1 -> binding
              binding && binding.task_id == task_id -> binding
              true -> Repo.rollback(:assignment_task_conflict)
            end
        end
      end)
    end
  end

  def bind_assignment_task(_assignment_id, _task_id),
    do: {:error, :assignment_task_authority_not_found}

  @doc """
  Authorize and start the one managed-Codex runtime attempt for a Task-bound
  assignment. Database authority is committed before Recorder opens a provider
  process, so a failed open is safely retryable against the same session.
  """
  @spec start_runtime_attempt(Assignment.t() | Ecto.UUID.t(), map(), map()) ::
          {:ok, %{attempt: RuntimeAttempt.t(), session: StudioChat.Session.t(), recorder: pid()}}
          | {:error, term()}
  def start_runtime_attempt(assignment, claim, opts \\ %{})

  def start_runtime_attempt(%Assignment{id: assignment_id}, claim, opts),
    do: start_runtime_attempt(assignment_id, claim, opts)

  def start_runtime_attempt(assignment_id, claim, opts)
      when is_binary(assignment_id) and is_map(claim) and is_map(opts) do
    recorder = value(opts, :recorder, Recorder)

    with {:ok, attempt} <- prepare_runtime_attempt(assignment_id, claim, opts),
         %StudioChat.Session{} = session <- StudioChat.get_session(attempt.session_id),
         {:ok, recorder_pid} <- recorder.ensure(recorder_opts(session, opts)) do
      {:ok, %{attempt: attempt, session: session, recorder: recorder_pid}}
    else
      nil -> {:error, :runtime_attempt_session_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def start_runtime_attempt(_assignment_id, _claim, _opts),
    do: {:error, :invalid_runtime_attempt}

  @doc """
  Freeze one assignment/session attempt after exact current-claim verification.
  Exact replays return the existing attempt without minting another session.
  """
  @spec prepare_runtime_attempt(Assignment.t() | Ecto.UUID.t(), map(), map()) ::
          {:ok, RuntimeAttempt.t()} | {:error, term()}
  def prepare_runtime_attempt(assignment, claim, opts \\ %{})

  def prepare_runtime_attempt(%Assignment{id: assignment_id}, claim, opts),
    do: prepare_runtime_attempt(assignment_id, claim, opts)

  def prepare_runtime_attempt(assignment_id, claim, opts)
      when is_binary(assignment_id) and is_map(claim) and is_map(opts) do
    with :ok <- managed_codex_attempt?(opts),
         {:ok, claim} <- normalize_attempt_claim(claim) do
      Repo.transaction(fn -> authorize_runtime_attempt(assignment_id, claim, opts) end)
      |> case do
        {:ok, %RuntimeAttempt{} = attempt} -> {:ok, attempt}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def prepare_runtime_attempt(_assignment_id, _claim, _opts),
    do: {:error, :invalid_runtime_attempt}

  @doc "Load the immutable runtime attempt bound to a Barkpark Studio session."
  @spec get_runtime_attempt_by_session(Ecto.UUID.t()) :: RuntimeAttempt.t() | nil
  def get_runtime_attempt_by_session(session_id) when is_binary(session_id),
    do: Repo.get_by(RuntimeAttempt, session_id: session_id)

  def get_runtime_attempt_by_session(_session_id), do: nil

  @doc "Derive the live Task claim authorized by an immutable runtime attempt."
  @spec current_runtime_attempt_attribution(RuntimeAttempt.t()) ::
          {:ok, map()} | {:error, term()}
  def current_runtime_attempt_attribution(%RuntimeAttempt{} = attempt) do
    with authority when not is_nil(authority) <-
           runtime_attempt_authority(attempt.assignment_id),
         true <- authority.task_id == attempt.task_id,
         claim when is_map(claim) <- get_in(authority.task_content || %{}, ["claim"]),
         epoch when is_integer(epoch) <- claim["epoch"],
         {:ok, fence} <-
           verify_runtime_attempt_claim(
             attempt,
             %{
               task_id: attempt.task_id,
               worker_id: attempt.task_worker_id,
               epoch: epoch,
               work_digest: attempt.task_work_digest
             },
             authority
           ) do
      {:ok,
       %{
         assignment_id: attempt.assignment_id,
         task: %{
           id: attempt.task_id,
           worker_id: fence.task_worker_id,
           epoch: fence.task_epoch,
           work_digest: fence.task_work_digest
         }
       }}
    else
      nil -> {:error, :runtime_attempt_authority_not_found}
      false -> {:error, :runtime_attempt_authority_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :task_not_claimed}
    end
  end

  def current_runtime_attempt_attribution(_attempt),
    do: {:error, :runtime_attempt_authority_not_found}

  @spec record_result(Assignment.t(), String.t(), map()) ::
          {:ok, Result.t()} | {:error, Ecto.Changeset.t() | atom()}
  def record_result(%Assignment{} = assignment, idempotency_key, attrs)
      when is_binary(idempotency_key) and is_map(attrs) do
    EpicFleet.record_result(assignment, idempotency_key, attrs)
  end

  @doc false
  @spec prepare_result_for_insert(Assignment.t(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare_result_for_insert(%Assignment{} = assignment, attrs) when is_map(attrs) do
    case completed_build?(assignment, attrs) do
      true ->
        with :ok <- validate_completed_build_result(assignment, value(attrs, :payload)),
             {:ok, task} <- locked_semantic_task(assignment),
             {:ok, payload} <- semantic_build_payload(assignment, value(attrs, :payload), task) do
          {:ok, put_attr(attrs, :payload, payload)}
        end

      false ->
        with :ok <- validate_cycle_result(assignment, attrs), do: {:ok, attrs}
    end
  end

  @spec record_result(Assignment.t(), map()) ::
          {:ok, Result.t()} | {:error, Ecto.Changeset.t() | atom()}
  def record_result(%Assignment{} = assignment, attrs) when is_map(attrs) do
    case value(attrs, :idempotency_key) do
      key when is_binary(key) -> record_result(assignment, key, attrs)
      _ -> {:error, :idempotency_key_required}
    end
  end

  defdelegate get_assignment(id), to: EpicFleet
  defdelegate get_result(assignment), to: EpicFleet
  @spec list_assignments(map()) :: [Assignment.t()]
  def list_assignments(scope) when is_map(scope) do
    case get_wave(scope) do
      %Wave{id: wave_id} -> EpicFleet.list_cycle_assignments(wave_id)
      nil -> []
    end
  end

  @doc "Fetch one logical assignment id inside an exact cycle scope."
  @spec get_assignment(map(), String.t()) :: Assignment.t() | nil
  def get_assignment(scope, assignment_id) when is_map(scope) and is_binary(assignment_id) do
    Enum.find(list_assignments(scope), &(&1.assignment_id == assignment_id))
  end

  @spec reduce(map()) :: {:ok, map()} | {:error, atom()}
  def reduce(scope) when is_map(scope) do
    case get_wave(scope) do
      %Wave{} = wave -> EpicFleet.reduce_cycle(wave.id, effective_plan(wave))
      nil -> {:error, :wave_not_found}
    end
  end

  @doc "Reduce exact unit, experiment, shard, capacity, and retry accounting."
  @spec reconcile(map()) :: {:ok, map()} | {:error, atom()}
  def reconcile(scope) when is_map(scope) do
    with %Wave{} = wave <- get_wave(scope),
         :ok <- validate_persisted_correction(wave) do
      rows = scope |> list_assignments() |> Enum.map(&{&1, EpicFleet.get_result(&1)})
      live_rows = exclude_replaced_rows(rows)
      inventory_ids = wave.inventory |> Enum.map(&unit_id/1) |> MapSet.new()
      build_rows = Enum.filter(live_rows, fn {assignment, _} -> assignment.phase == "build" end)

      experiment_rows =
        Enum.filter(live_rows, fn {assignment, _} -> assignment.phase == "experiment" end)

      assigned_ids =
        Enum.flat_map(build_rows, fn {assignment, _} -> snapshot_units(assignment) end)

      assigned_set = MapSet.new(assigned_ids)
      duplicate_ids = duplicates(assigned_ids)
      unknown_assignments = MapSet.difference(assigned_set, inventory_ids)
      outcomes = outcome_sets(build_rows)
      accounted = outcomes |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)
      unknown_outcomes = MapSet.difference(accounted, inventory_ids)
      outcome_overlap = overlaps(outcomes)
      ownership_violations = outcome_ownership_violations(build_rows)
      build_plan = get_build_plan(wave)

      invalid_build_assignments =
        invalid_build_assignment_ids(build_rows, inventory_ids, build_plan)

      invalid_build_results = invalid_build_result_ids(build_rows)
      unassigned = MapSet.difference(inventory_ids, assigned_set)
      unaccounted = MapSet.difference(inventory_ids, accounted)
      experiment = experiment_reconciliation(experiment_rows, wave)
      {:ok, reduced} = EpicFleet.reduce_cycle(wave.id, effective_plan(wave))
      fleet_complete? = fleet_complete?(reduced.fleet)

      exact? =
        Enum.all?(
          [
            duplicate_ids,
            unknown_assignments,
            unknown_outcomes,
            outcome_overlap,
            ownership_violations,
            invalid_build_assignments,
            invalid_build_results,
            unassigned,
            unaccounted
          ],
          &MapSet.equal?(&1, MapSet.new())
        ) and experiment.complete? and fleet_complete? and
          (wave.profile == "epic" or not is_nil(build_plan))

      correction_receipt = correction_receipt(wave)

      summary = %{
        profile: wave.profile,
        scope: Map.take(wave, @scope_fields),
        wave_revision: wave.id,
        inventory_digest: wave.inventory_digest,
        plan_digest: effective_plan_digest(wave),
        scale_contract: wave.scale_contract,
        inventory_count: MapSet.size(inventory_ids),
        planned_builders: get_in(effective_plan(wave), ["build", "planned"]),
        assigned_count: MapSet.size(MapSet.intersection(assigned_set, inventory_ids)),
        assigned_occurrences: length(assigned_ids),
        shipped_count: MapSet.size(outcomes.shipped),
        stalled_count: MapSet.size(outcomes.stalled),
        excluded_count: MapSet.size(outcomes.excluded),
        duplicate_assignment_unit_ids: sorted(duplicate_ids),
        unknown_assignment_unit_ids: sorted(unknown_assignments),
        unknown_outcome_unit_ids: sorted(unknown_outcomes),
        outcome_overlap_unit_ids: sorted(outcome_overlap),
        outcome_ownership_violation_unit_ids: sorted(ownership_violations),
        invalid_build_assignment_ids: sorted(invalid_build_assignments),
        invalid_build_result_assignment_ids: sorted(invalid_build_results),
        unassigned_unit_ids: sorted(unassigned),
        unaccounted_unit_ids: sorted(unaccounted),
        experiment: experiment,
        fleet_complete: fleet_complete?,
        fleet_counts: fleet_counts(reduced.fleet),
        capacity: %{
          sealed: not is_nil(build_plan),
          proven_batch_capacity: build_plan && build_plan.proven_batch_capacity,
          chosen_format: build_plan && build_plan.chosen_format,
          failure_rate: build_plan && build_plan.failure_rate,
          failure_threshold: build_plan && build_plan.failure_threshold,
          golden_fixtures: build_plan && build_plan.golden_fixtures,
          quality_rubric: build_plan && build_plan.quality_rubric
        },
        correction_of_wave_revision: wave.correction_of_wave_id,
        correction_of: wave.correction_of,
        correction_of_digest: wave.correction_of_digest,
        correction_ancestry: reconciliation_ancestry(wave),
        correction_receipt: correction_receipt,
        correction_receipt_digest:
          correction_receipt && EpicFleet.canonical_digest(correction_receipt),
        exact: exact?
      }

      summary = correction_summary(wave, rows, summary)

      {:ok,
       summary
       |> Map.put(:live_authority_digest, EpicFleet.canonical_digest(summary))
       |> Map.put(:reconciliation_digest, digest(summary))}
    else
      nil -> {:error, :wave_not_found}
      {:error, :invalid_persisted_correction} -> {:error, :invalid_persisted_correction}
    end
  end

  defp correction_summary(%Wave{correction_of_wave_id: nil}, _rows, summary), do: summary

  defp correction_summary(%Wave{} = wave, _rows, summary) do
    correction = wave.correction_of
    prior = Repo.get!(Wave, wave.correction_of_wave_id)
    {:ok, inherited} = reconcile(Map.take(prior, @scope_fields))
    after_counts = Map.fetch!(correction, "after_counts")
    inventory_count = Map.fetch!(correction, "inventory_count")

    {:ok, inherited_fleet} = canonical_fleet(prior)

    own_fleet = %{
      assigned_count: summary.assigned_count,
      assigned_occurrences: summary.assigned_occurrences,
      shipped_count: summary.shipped_count,
      stalled_count: summary.stalled_count,
      excluded_count: summary.excluded_count,
      fleet_complete: summary.fleet_complete,
      fleet_counts: summary.fleet_counts,
      exact: summary.exact
    }

    summary
    |> Map.merge(%{
      assigned_count: inventory_count,
      assigned_occurrences: inventory_count,
      shipped_count: Map.fetch!(after_counts, "shipped"),
      stalled_count: Map.fetch!(after_counts, "stalled"),
      excluded_count: Map.fetch!(after_counts, "excluded"),
      duplicate_assignment_unit_ids: [],
      unknown_assignment_unit_ids: [],
      unknown_outcome_unit_ids: [],
      outcome_overlap_unit_ids: [],
      outcome_ownership_violation_unit_ids: [],
      invalid_build_assignment_ids: [],
      invalid_build_result_assignment_ids: [],
      unassigned_unit_ids: [],
      unaccounted_unit_ids: [],
      experiment: inherited.experiment,
      fleet_complete: inherited.fleet_complete,
      fleet_counts: inherited.fleet_counts,
      capacity: inherited.capacity,
      exact: inherited.fleet_complete and inherited.experiment.complete?,
      canonical_fleet: inherited_fleet,
      own_fleet: own_fleet
    })
  end

  defp canonical_fleet(%Wave{correction_of_wave_id: nil} = wave) do
    with {:ok, reduced} <- reduce(Map.take(wave, @scope_fields)), do: {:ok, reduced.fleet}
  end

  defp canonical_fleet(%Wave{} = wave) do
    with {:ok, reconciliation} <- reconcile(Map.take(wave, @scope_fields)),
         fleet when is_map(fleet) <- reconciliation.canonical_fleet do
      {:ok, fleet}
    end
  end

  defp correction_receipt(%Wave{correction_of_wave_id: nil}), do: nil

  defp correction_receipt(%Wave{} = wave) do
    %{
      "version" => "correction_receipt-v1",
      "successor_wave_revision" => wave.id,
      "parent_wave_revision" => wave.correction_of_wave_id,
      "correction_of_digest" => wave.correction_of_digest,
      "targets" => Map.fetch!(wave.correction_of, "targets")
    }
  end

  @doc "Append immutable evidence that a registered correction must never be promoted."
  @spec quarantine_correction(map(), map()) ::
          {:ok, Quarantine.t()} | {:error, Ecto.Changeset.t() | atom()}
  def quarantine_correction(scope, attrs) when is_map(scope) and is_map(attrs) do
    with {:ok, common} <- normalize_transition_attrs(attrs),
         {:ok, receipt} <- normalize_correction_receipt(value(attrs, :correction_receipt)) do
      correction_transition(scope, receipt, fn root, target, receipt_digest ->
        payload = %{
          "action" => "quarantine",
          "root_wave_revision" => root.id,
          "target_wave_revision" => target.id,
          "idempotency_key" => common.idempotency_key,
          "reason" => value(attrs, :reason),
          "actor" => common.actor,
          "evidence" => common.evidence,
          "evidence_revision" => common.evidence_revision,
          "correction_receipt_digest" => receipt_digest
        }

        if nonempty?(payload["reason"]) do
          event_digest = jsonb_digest(payload)

          case Repo.get_by(Quarantine,
                 root_wave_id: root.id,
                 idempotency_key: common.idempotency_key
               ) do
            %Quarantine{event_digest: ^event_digest} = replay ->
              replay

            %Quarantine{} ->
              Repo.rollback(:quarantine_conflict)

            nil ->
              current = Promotion.head(root.id)

              if current && current.target_wave_id == target.id && current.action != "rollback" do
                Repo.rollback(:current_wave_requires_rollback)
              end

              %{
                root_wave_id: root.id,
                correction_wave_id: target.id,
                workspace_id: root.workspace_id,
                project_id: root.project_id,
                epic_id: root.epic_id,
                idempotency_key: common.idempotency_key,
                reason: payload["reason"],
                actor: common.actor,
                evidence: common.evidence,
                evidence_revision: common.evidence_revision,
                correction_receipt: receipt,
                correction_receipt_digest: receipt_digest,
                event_payload: payload,
                event_digest: event_digest
              }
              |> Quarantine.insert_changeset()
              |> Repo.insert()
              |> case do
                {:ok, quarantine} -> quarantine
                {:error, changeset} -> Repo.rollback(changeset)
              end
          end
        else
          Repo.rollback(:invalid_quarantine_reason)
        end
      end)
    end
  end

  def quarantine_correction(_scope, _attrs), do: {:error, :invalid_correction_receipt}

  @doc "Promote one exact, complete correction behind a fully pinned immutable gate receipt."
  @spec promote_correction(map(), map()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t() | atom()}
  def promote_correction(scope, attrs) when is_map(scope) and is_map(attrs) do
    with {:ok, common} <- normalize_transition_attrs(attrs),
         {:ok, receipt} <- normalize_correction_receipt(value(attrs, :correction_receipt)),
         {:ok, gate} <- normalize_gate_receipt(value(attrs, :gate_receipt)) do
      result =
        correction_transition(scope, receipt, fn root, target, receipt_digest ->
          previous_event_id = nullable_uuid(value(attrs, :previous_event_id))

          payload = %{
            "action" => "promote",
            "admission_id" => nil,
            "root_wave_revision" => root.id,
            "target_wave_revision" => target.id,
            "previous_event_id" => previous_event_id,
            "restore_event_id" => nil,
            "idempotency_key" => common.idempotency_key,
            "actor" => common.actor,
            "evidence" => common.evidence,
            "evidence_revision" => common.evidence_revision,
            "gate_receipt" => gate
          }

          insert_promotion_event(root, target, common, payload, gate, receipt_digest)
        end)

      case result do
        {:ok, %Event{} = event} ->
          verify_promoted_public_papers(scope, attrs, receipt, event)

        other ->
          other
      end
    end
  end

  def promote_correction(_scope, _attrs), do: {:error, :invalid_correction_receipt}

  defp verify_promoted_public_papers(scope, attrs, receipt, event) do
    case Repo.get_by(PublicSmoke, promotion_event_id: event.id) do
      %PublicSmoke{state: "pass"} ->
        {:ok, event}

      %PublicSmoke{state: "compensated"} ->
        {:error, :public_release_smoke_failed}

      %PublicSmoke{state: "failed"} = smoke ->
        compensate_failed_public_smoke(scope, attrs, receipt, event, smoke)

      %PublicSmoke{state: "pending"} = smoke ->
        smoke_result =
          if promoted_lifecycle_postcondition?(event),
            do: ReleaseCaptureAdapter.public_smoke(smoke.request),
            else: {:error, :promoted_lifecycle_postcondition_failed}

        case smoke_result do
          {:ok, proof} ->
            with {:ok, _smoke} <- pass_public_smoke(smoke, proof) do
              {:ok, event}
            end

          {:error, reason} ->
            with {:ok, failed} <- fail_public_smoke(smoke, reason) do
              compensate_failed_public_smoke(scope, attrs, receipt, event, failed)
            end
        end

      nil ->
        {:error, :missing_public_release_smoke_fence}
    end
  end

  defp promoted_lifecycle_postcondition?(event) do
    target = Repo.get!(Wave, event.target_wave_id)

    with {:ok, chain} <- Promotion.chain(event.root_wave_id),
         %Event{id: head_id} <- List.last(chain),
         true <- head_id == event.id,
         %Wave{id: target_id} <- current_promoted_wave(List.last(chain)),
         true <- target_id == target.id do
      actual = prospective_correction_lifecycle!(target.id) |> stringify_keys()

      candidates =
        Repo.all(
          from candidate in PaperCandidate,
            where: candidate.target_wave_id == ^target.id,
            order_by: candidate.role
        )

      Enum.map(candidates, &candidate_lifecycle/1) == [actual, actual] and
        get_in(actual, ["current", "wave_revision"]) == target.id and
        Enum.any?(actual["superseded"], &(&1["status"] == "superseded"))
    else
      _ -> false
    end
  end

  defp candidate_lifecycle(candidate) do
    candidate.content["blocks"]
    |> Enum.find_value(fn block -> block["correction_lifecycle"] end)
  end

  defp public_smoke_request(event) do
    origin = BarkparkWeb.Endpoint.url()
    target = Repo.get!(Wave, event.target_wave_id)
    workspace = Repo.get!(Workspace, target.workspace_id)
    project = Repo.get!(Project, target.project_id)

    documents =
      event.release_materialization["documents"]
      |> Enum.sort_by(& &1["role"])
      |> Enum.map(fn row ->
        %{
          "role" => row["role"],
          "document_id" => row["document_id"],
          "doc_id" => row["doc_id"],
          "title" => row["title"],
          "content_digest" => row["content_digest"],
          "revision_id" => row["after"]["released_revision_id"],
          "url" =>
            origin <>
              "/w/#{URI.encode(workspace.slug, &URI.char_unreserved?/1)}/p/#{URI.encode(project.slug, &URI.char_unreserved?/1)}/papers/" <>
              URI.encode(row["doc_id"], &URI.char_unreserved?/1)
        }
      end)

    %{
      "format" => "cycle-release-public-smoke-request-v1",
      "promotion_event_id" => event.id,
      "root_wave_revision" => event.root_wave_id,
      "target_wave_revision" => event.target_wave_id,
      "canonical_origin" => origin,
      "workspace_slug" => workspace.slug,
      "project_slug" => project.slug,
      "deployment_digest" => release_deployment_digest!(),
      "documents" => documents
    }
  end

  defp release_deployment_digest! do
    case Application.get_env(:barkpark, :release_deployment_digest) do
      digest when is_binary(digest) ->
        if digest_string?(digest),
          do: digest,
          else: raise("release_deployment_digest must be a lowercase SHA-256 digest")

      _ ->
        raise "release_deployment_digest must be configured as a 64-byte hex digest"
    end
  end

  defp insert_pending_public_smoke(event) do
    attrs = %{
      promotion_event_id: event.id,
      root_wave_id: event.root_wave_id,
      target_wave_id: event.target_wave_id,
      state: "pending",
      request: public_smoke_request(event)
    }

    case Repo.insert(PublicSmoke.insert_changeset(attrs)) do
      {:ok, smoke} -> smoke
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp pass_public_smoke(smoke, proof) do
    unsigned = %{"request" => smoke.request, "proof" => proof}
    digest = EpicFleet.canonical_digest(unsigned)
    attestation = release_hmac(digest)

    Repo.transaction(fn ->
      unless put_release_capture_hmac_secret() == :ok do
        Repo.rollback(:release_capture_signing_unavailable)
      end

      root = Promotion.lock_root(smoke.root_wave_id)
      event = Repo.get!(Event, smoke.promotion_event_id)
      head = root && Promotion.head(smoke.root_wave_id)

      pointers_exact? =
        Enum.all?(event.release_materialization["documents"], fn row ->
          document =
            from(document in Document, where: document.id == ^row["document_id"])
            |> Scope.scope_to_workspace(event.workspace_id, event.project_id)
            |> Repo.one()

          case document do
            %Document{} = document ->
              document.current_revision_id == row["after"]["current_revision_id"] and
                document.released_revision_id == row["after"]["released_revision_id"] and
                document.rev == row["after"]["rev"]

            nil ->
              false
          end
        end)

      with %Root{} <- root,
           %Event{id: head_id} when head_id == event.id <- head,
           true <- pointers_exact?,
           {1, _} <-
             Repo.update_all(
               from(row in PublicSmoke, where: row.id == ^smoke.id and row.state == "pending"),
               set: [
                 state: "pass",
                 proof:
                   unsigned
                   |> Map.put("digest", digest)
                   |> Map.put("attestation", attestation),
                 proof_digest: digest,
                 updated_at: DateTime.utc_now()
               ]
             ) do
        Repo.get!(PublicSmoke, smoke.id)
      else
        _ -> Repo.rollback(:public_release_smoke_conflict)
      end
    end)
    |> unwrap_transaction()
  end

  defp fail_public_smoke(smoke, reason) do
    failure = %{
      "format" => "cycle-release-public-smoke-failure-v1",
      "reason" => inspect(reason),
      "evidence" => if(is_map(reason), do: reason, else: %{"error" => inspect(reason)}),
      "failed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Repo.update_all(
           from(row in PublicSmoke, where: row.id == ^smoke.id and row.state == "pending"),
           set: [state: "failed", failure: failure, updated_at: DateTime.utc_now()]
         ) do
      {1, _} -> {:ok, Repo.get!(PublicSmoke, smoke.id)}
      _ -> {:error, :public_release_smoke_conflict}
    end
  end

  defp compensate_failed_public_smoke(scope, attrs, receipt, event, smoke) do
    evidence_revision = EpicFleet.canonical_digest(smoke.failure)

    rollback_attrs = %{
      idempotency_key: "#{value(attrs, :idempotency_key)}:public-smoke-rollback",
      previous_event_id: event.id,
      restore_event_id: pre_promotion_restore_target(event),
      actor: value(attrs, :actor),
      evidence: "public-reader-smoke://#{event.id}/failed",
      evidence_revision: evidence_revision
    }

    target = Repo.get!(Wave, event.target_wave_id)
    target_scope = Map.take(target, @scope_fields)

    result =
      Repo.transaction(fn ->
        with {:ok, rollback} <- rollback_correction(scope, rollback_attrs),
             {:ok, _quarantine} <-
               quarantine_correction(target_scope, %{
                 idempotency_key: "#{value(attrs, :idempotency_key)}:public-smoke-quarantine",
                 actor: value(attrs, :actor),
                 evidence: "public-reader-smoke://#{event.id}/failed",
                 evidence_revision: evidence_revision,
                 reason:
                   "post-promotion anonymous public Paper smoke failed: #{smoke.failure["reason"]}",
                 correction_receipt: receipt
               }),
             {1, _} <-
               Repo.update_all(
                 from(row in PublicSmoke,
                   where: row.id == ^smoke.id and row.state == "failed"
                 ),
                 set: [
                   state: "compensated",
                   compensation_event_id: rollback.id,
                   updated_at: DateTime.utc_now()
                 ]
               ) do
          :compensated
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:public_release_smoke_compensation_conflict)
        end
      end)

    case result do
      {:ok, :compensated} -> {:error, :public_release_smoke_failed}
      {:error, reason} -> {:error, {:public_release_smoke_compensation_failed, reason}}
    end
  end

  defp pre_promotion_restore_target(%Event{previous_event_id: nil}), do: "genesis"

  defp pre_promotion_restore_target(%Event{previous_event_id: previous_id}) do
    case Repo.get!(Event, previous_id) do
      %Event{action: "promote", id: id} -> id
      %Event{action: "rollback", restore_event_id: nil} -> "genesis"
      %Event{action: "rollback", restore_event_id: id} -> id
    end
  end

  @doc "Append a rollback that restores an earlier promote in the same linked chain or genesis."
  @spec rollback_correction(map(), map()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t() | atom()}
  def rollback_correction(scope, attrs) when is_map(scope) and is_map(attrs) do
    with {:ok, common} <- normalize_transition_attrs(attrs),
         %Wave{} = queried <- get_wave(scope),
         %Wave{} = root <- ancestry_root_wave(queried),
         true <- not is_nil(root.project_id) || {:error, :project_scope_required} do
      Repo.transaction(fn ->
        with %Root{} <- ensure_locked_promotion_root(root),
             {:ok, chain} <- Promotion.chain(root.id),
             %Event{} = head <- List.last(chain),
             previous when is_binary(previous) <- nullable_uuid(value(attrs, :previous_event_id)),
             {:ok, restore_event_id, target} <-
               rollback_target(root, chain, value(attrs, :restore_event_id)) do
          payload = %{
            "action" => "rollback",
            "admission_id" => nil,
            "root_wave_revision" => root.id,
            "target_wave_revision" => target.id,
            "previous_event_id" => previous,
            "restore_event_id" => restore_event_id,
            "idempotency_key" => common.idempotency_key,
            "actor" => common.actor,
            "evidence" => common.evidence,
            "evidence_revision" => common.evidence_revision,
            "gate_receipt" => nil
          }

          event_digest = jsonb_digest(payload)

          case Promotion.event_by_key(root.id, common.idempotency_key) do
            %Event{event_digest: ^event_digest} = replay ->
              replay

            %Event{} ->
              Repo.rollback(:promotion_conflict)

            nil ->
              with true <- previous == head.id || {:error, :stale_promotion_head},
                   false <-
                     target.id != root.id and
                       Repo.exists?(
                         from q in Quarantine,
                           where: q.correction_wave_id == ^target.id
                       ),
                   {:ok, restoration} <-
                     restore_release_materializations(chain, restore_event_id) do
                persist_promotion_event(
                  root,
                  target,
                  common,
                  payload,
                  nil,
                  restore_event_id,
                  nil,
                  restoration
                )
              else
                true -> Repo.rollback(:correction_quarantined)
                {:error, reason} -> Repo.rollback(reason)
              end
          end
        else
          nil -> Repo.rollback(:invalid_rollback_target)
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_rollback_target)
        end
      end)
      |> unwrap_transaction()
    else
      nil -> {:error, :wave_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_rollback_target}
    end
  end

  def rollback_correction(_scope, _attrs), do: {:error, :invalid_rollback_target}

  @doc "Return the linked correction state for either an ancestry root or any successor wave."
  @spec current_correction(map()) :: {:ok, map()} | {:error, atom()}
  def current_correction(scope) when is_map(scope) do
    with %Wave{} = queried <- get_wave(scope),
         %Wave{} = root <- ancestry_root_wave(queried),
         {:ok, events} <- Promotion.chain(root.id) do
      targets = Repo.all(from target in Target, where: target.root_wave_id == ^root.id)
      quarantines = Repo.all(from row in Quarantine, where: row.root_wave_id == ^root.id)
      ancestry = linked_wave_ancestry(root, targets)
      head = List.last(events)

      current_wave = current_promoted_wave(head)
      current_admission = effective_admission(head, events)
      quarantined_wave_ids = MapSet.new(quarantines, & &1.correction_wave_id)

      promoted_wave_ids =
        events
        |> Enum.filter(&(&1.action == "promote"))
        |> Enum.map(& &1.target_wave_id)
        |> Enum.uniq()

      superseded =
        promoted_wave_ids
        |> Enum.reject(&(current_wave && &1 == current_wave.id))
        |> Enum.map(&Repo.get!(Wave, &1))

      lifecycle_status = fn wave ->
        cond do
          current_wave && wave.id == current_wave.id -> "current"
          MapSet.member?(quarantined_wave_ids, wave.id) -> "quarantined"
          wave.id == root.id && current_wave -> "superseded"
          wave.id == root.id -> "current"
          wave.id in promoted_wave_ids -> "superseded"
          true -> "historical"
        end
      end

      {:ok,
       %{
         format: "quarantine-promotion-v1",
         ancestry_root: lifecycle_wave(root, lifecycle_status.(root)),
         current: current_wave && lifecycle_wave(current_wave, "current"),
         promotion: head && lifecycle_event(head),
         authority_evidence: current_admission && lifecycle_admission(current_admission),
         quarantines:
           quarantines
           |> Enum.sort_by(&{&1.inserted_at, &1.id})
           |> Enum.map(&lifecycle_quarantine/1),
         superseded: Enum.map(superseded, &lifecycle_wave(&1, lifecycle_status.(&1))),
         historical_ancestry:
           ancestry |> tl() |> Enum.map(&lifecycle_wave(&1, lifecycle_status.(&1)))
       }}
    else
      nil -> {:error, :wave_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Return the canonical reader/validator projection for one cycle wave."
  @spec projection(map()) :: {:ok, map()} | {:error, atom()}
  def projection(scope) when is_map(scope) do
    with {:ok, reconciliation} <- reconcile(scope),
         {:ok, fleet} <- reduce(scope),
         {:ok, correction_lifecycle} <- current_correction(scope) do
      workspace = repo_get_if_present(Workspace, reconciliation.scope.workspace_id)
      project = repo_get_if_present(Project, reconciliation.scope.project_id)

      {:ok,
       %{
         cycle_ledger: reconciliation,
         fleet: Map.get(reconciliation, :canonical_fleet, fleet.fleet),
         own_fleet: fleet.fleet,
         correction_lifecycle: correction_lifecycle,
         assignment_attributions: assignment_attributions(scope),
         authority:
           %{
             kind: "barkpark_cycle_fleet",
             workspace_id: reconciliation.scope.workspace_id,
             project_id: reconciliation.scope.project_id,
             epic_id: reconciliation.scope.epic_id,
             wave_id: reconciliation.scope.wave_id,
             wave_revision: reconciliation.wave_revision,
             correction_of_wave_revision: reconciliation.correction_of_wave_revision,
             correction_of_digest: reconciliation.correction_of_digest
           }
           |> maybe_put_authority_slug(:workspace_slug, workspace)
           |> maybe_put_authority_slug(:project_slug, project)
           |> maybe_put_canonical_origin(workspace, project)
       }}
    end
  end

  defp repo_get_if_present(_schema, nil), do: nil
  defp repo_get_if_present(schema, id), do: Repo.get(schema, id)

  defp maybe_put_authority_slug(authority, _key, nil), do: authority

  defp maybe_put_authority_slug(authority, key, %{slug: slug}) when is_binary(slug),
    do: Map.put(authority, key, slug)

  defp maybe_put_canonical_origin(authority, %Workspace{}, %Project{}),
    do: Map.put(authority, :canonical_origin, BarkparkWeb.Endpoint.url())

  defp maybe_put_canonical_origin(authority, _workspace, _project), do: authority

  @doc "Project the immutable retrieval attribution seed for every assignment in one cycle wave."
  @spec assignment_attributions(map()) :: [map()]
  def assignment_attributions(scope) when is_map(scope) do
    scope
    |> list_assignments()
    |> Enum.sort_by(&{&1.inserted_at, &1.id})
    |> Enum.map(&assignment_attribution/1)
  end

  @doc "Project one cycle assignment's immutable retrieval attribution seed."
  @spec assignment_attribution(Assignment.t()) :: map()
  def assignment_attribution(%Assignment{} = assignment) do
    %{
      cycle_assignment_id: assignment.id,
      cycle_wave_id: assignment.cycle_wave_id,
      assignment_id: assignment.assignment_id,
      unit_ids: assignment.unit_ids,
      inventory_digest: assignment.inventory_digest,
      snapshot_digest: assignment.snapshot_digest
    }
  end

  @spec profile_plan(String.t() | atom(), map()) :: {:ok, map()} | {:error, atom()}
  def profile_plan(profile, inputs \\ %{}), do: Profile.plan(profile, inputs)

  @spec digest(term()) :: String.t()
  def digest(term), do: EpicFleet.digest(term)

  defp correction_transition(scope, receipt, operation) do
    with %Wave{} = target <- Repo.get(Wave, receipt["successor_wave_revision"]),
         %Wave{} = root <- ancestry_root_wave(target),
         true <- not is_nil(root.project_id) || {:error, :project_scope_required},
         %Wave{} = queried <- get_wave(scope),
         true <-
           ancestry_root_wave(queried).id == root.id || {:error, :foreign_correction_ancestry} do
      receipt_digest = EpicFleet.canonical_digest(receipt)

      Repo.transaction(fn ->
        with %Root{} <- ensure_locked_promotion_root(root),
             {:ok, ^receipt_digest} <- validate_target_receipt(target, receipt),
             %Target{} <- ensure_promotion_ancestry(root, target) do
          operation.(root, target, receipt_digest)
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_correction_receipt)
        end
      end)
      |> unwrap_transaction()
    else
      nil -> {:error, :wave_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_correction_receipt}
    end
  end

  defp ensure_promotion_ancestry(root, target) do
    root
    |> correction_successors_to(target)
    |> Enum.reduce(nil, fn wave, _registered ->
      receipt = correction_receipt(wave)

      ensure_promotion_target(
        root,
        wave,
        receipt,
        EpicFleet.canonical_digest(receipt)
      )
    end)
  end

  defp correction_successors_to(root, target), do: correction_successors_to(root.id, target, [])

  defp correction_successors_to(root_id, %Wave{correction_of_wave_id: root_id} = wave, acc),
    do: [wave | acc]

  defp correction_successors_to(root_id, %Wave{correction_of_wave_id: parent_id} = wave, acc) do
    correction_successors_to(root_id, Repo.get!(Wave, parent_id), [wave | acc])
  end

  defp ensure_locked_promotion_root(%Wave{} = root) do
    attrs = %{
      root_wave_id: root.id,
      workspace_id: root.workspace_id,
      project_id: root.project_id,
      epic_id: root.epic_id
    }

    case Repo.insert(Root.insert_changeset(attrs),
           on_conflict: :nothing,
           conflict_target: [:root_wave_id]
         ) do
      {:ok, _} -> Promotion.lock_root(root.id)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp ensure_promotion_target(root, target, receipt, receipt_digest) do
    attrs = %{
      wave_id: target.id,
      root_wave_id: root.id,
      previous_wave_id: target.correction_of_wave_id,
      workspace_id: root.workspace_id,
      project_id: root.project_id,
      epic_id: root.epic_id,
      correction_receipt: receipt,
      correction_receipt_digest: receipt_digest,
      semantic_digest: EpicFleet.canonical_digest(receipt["targets"])
    }

    case Repo.insert(Target.insert_changeset(attrs),
           on_conflict: :nothing,
           conflict_target: [:wave_id]
         ) do
      {:ok, _} ->
        case Repo.get(Target, target.id) do
          %Target{} = row ->
            if Map.take(row, Map.keys(attrs)) == attrs,
              do: row,
              else: Repo.rollback(:correction_target_conflict)

          nil ->
            Repo.rollback(:correction_target_conflict)
        end

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp insert_promotion_event(root, target, common, payload, gate, receipt_digest) do
    case Promotion.event_by_key(root.id, common.idempotency_key) do
      %Event{} = replay ->
        release_gate =
          replay.release_gate_admission_id &&
            Repo.get(ReleaseGate, replay.release_gate_admission_id)

        replay_payload =
          payload
          |> Map.put("admission_id", replay.admission_id)
          |> Map.put("gate_receipt", replay.gate_receipt)

        if (release_gate && release_gate.receipt == gate) and
             replay.event_digest == jsonb_digest(replay_payload),
           do: replay,
           else: Repo.rollback(:promotion_conflict)

      nil ->
        prior_head = Promotion.head(root.id)
        current = current_promoted_wave(prior_head)

        with true <- (is_nil(current) or current.id != target.id) || {:error, :already_current},
             :ok <- public_smoke_allows_successor?(root.id),
             :ok <- correction_ready?(target),
             {:ok, release_admission} <- locked_activate_admission(root, target, gate),
             {:ok, materialization, successor_revision} <-
               materialize_release_papers(release_admission, target),
             {:ok, legacy_gate} <-
               legacy_promotion_gate(
                 target,
                 receipt_digest,
                 release_admission,
                 successor_revision
               ),
             {:ok, authority} <- validate_gate_receipt(target, legacy_gate, receipt_digest),
             head <- Promotion.head(root.id),
             :ok <- promotion_quarantine_gate(target, head),
             true <-
               nullable_uuid(payload["previous_event_id"]) == (head && head.id) ||
                 {:error, :stale_promotion_head},
             %Admission{} = admission <-
               persist_admission(root, target, common, legacy_gate, authority) do
          event_payload =
            payload
            |> Map.put("admission_id", admission.id)
            |> Map.put("gate_receipt", legacy_gate)

          persist_promotion_event(
            root,
            target,
            common,
            event_payload,
            legacy_gate,
            nil,
            release_admission,
            materialization
          )
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp promotion_quarantine_gate(target, head) do
    quarantines =
      Repo.all(from quarantine in Quarantine, where: quarantine.correction_wave_id == ^target.id)

    cond do
      quarantines == [] ->
        :ok

      compensated_unavailable_head?(target, head) and
          Enum.all?(quarantines, &unavailable_smoke_quarantine?(target, &1)) ->
        :ok

      true ->
        {:error, :correction_quarantined}
    end
  end

  defp compensated_unavailable_head?(target, %Event{action: "rollback"} = head) do
    case Repo.get_by(PublicSmoke,
           target_wave_id: target.id,
           compensation_event_id: head.id,
           state: "compensated"
         ) do
      %PublicSmoke{promotion_event_id: promotion_id, failure: failure} ->
        promotion_id == head.previous_event_id and unavailable_smoke_failure?(failure)

      nil ->
        false
    end
  end

  defp compensated_unavailable_head?(_target, _head), do: false

  defp unavailable_smoke_quarantine?(target, quarantine) do
    with [promotion_id] <-
           Regex.run(
             ~r/^public-reader-smoke:\/\/([0-9a-f-]{36})\/failed$/,
             quarantine.evidence,
             capture: :all_but_first
           ),
         %Event{target_wave_id: target_id, idempotency_key: promotion_key} <-
           Repo.get(Event, promotion_id),
         true <- target_id == target.id,
         %PublicSmoke{state: "compensated", failure: failure} <-
           Repo.get_by(PublicSmoke, promotion_event_id: promotion_id),
         true <- unavailable_smoke_failure?(failure),
         true <- quarantine.idempotency_key == "#{promotion_key}:public-smoke-quarantine",
         true <- quarantine.evidence_revision == EpicFleet.canonical_digest(failure),
         true <-
           quarantine.reason ==
             "post-promotion anonymous public Paper smoke failed: :public_release_smoke_unavailable" do
      true
    else
      _ -> false
    end
  end

  defp unavailable_smoke_failure?(%{"reason" => ":public_release_smoke_unavailable"}), do: true
  defp unavailable_smoke_failure?(_failure), do: false

  defp persist_promotion_event(
         root,
         target,
         common,
         payload,
         gate,
         restore_event_id,
         release_admission,
         materialization
       ) do
    event_digest = jsonb_digest(payload)

    case Promotion.event_by_key(root.id, common.idempotency_key) do
      %Event{event_digest: ^event_digest} = replay ->
        replay

      %Event{} ->
        Repo.rollback(:promotion_conflict)

      nil ->
        %{
          admission_id: payload["admission_id"],
          release_gate_admission_id: release_admission && release_admission.id,
          release_materialization: materialization,
          root_wave_id: root.id,
          target_wave_id: target.id,
          previous_event_id: payload["previous_event_id"],
          restore_event_id: restore_event_id,
          workspace_id: root.workspace_id,
          project_id: root.project_id,
          epic_id: root.epic_id,
          action: payload["action"],
          idempotency_key: common.idempotency_key,
          actor: common.actor,
          evidence: common.evidence,
          evidence_revision: common.evidence_revision,
          gate_receipt: gate,
          event_payload: payload,
          event_digest: event_digest
        }
        |> Event.insert_changeset()
        |> Repo.insert()
        |> case do
          {:ok, %Event{action: "promote"} = event} ->
            _smoke = insert_pending_public_smoke(event)
            event

          {:ok, event} ->
            event

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  defp public_smoke_allows_successor?(root_id) do
    unresolved? =
      Repo.exists?(
        from smoke in PublicSmoke,
          where: smoke.root_wave_id == ^root_id and smoke.state in ["pending", "failed"]
      )

    if unresolved?, do: {:error, :public_release_smoke_pending}, else: :ok
  end

  defp locked_activate_admission(root, target, receipt) do
    digest = receipt["receipt_digest"]

    gate =
      Repo.one(
        from admission in ReleaseGate,
          where:
            admission.stage == "activate" and admission.root_wave_id == ^root.id and
              admission.target_wave_id == ^target.id and admission.receipt_digest == ^digest,
          lock: "FOR UPDATE"
      )

    with %ReleaseGate{} = gate <- gate,
         true <- gate.receipt == receipt,
         %Consumption{kind: "activate", wave_id: wave_id} <- Repo.get(Consumption, gate.id),
         true <- wave_id == target.id do
      {:ok, gate}
    else
      _ -> {:error, :invalid_activate_release_gate}
    end
  end

  defp materialize_release_papers(release_admission, target) do
    candidates =
      Repo.all(
        from candidate in PaperCandidate,
          where: candidate.target_wave_id == ^target.id,
          order_by: candidate.role,
          lock: "FOR UPDATE"
      )

    with [
           %PaperCandidate{role: "campaign"} = campaign,
           %PaperCandidate{role: "successor"} = successor
         ] <-
           candidates,
         true <-
           release_admission.receipt["papers"] == Enum.map(candidates, &paper_candidate_receipt/1),
         {:ok, _campaign_revision, campaign_receipt} <- materialize_release_paper(campaign),
         {:ok, successor_revision, successor_receipt} <- materialize_release_paper(successor) do
      unsigned = %{
        "format" => "cycle-release-materialization-v1",
        "release_gate_admission_id" => release_admission.id,
        "documents" => [campaign_receipt, successor_receipt]
      }

      {:ok, Map.put(unsigned, "digest", EpicFleet.canonical_digest(unsigned)), successor_revision}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :paper_candidate_conflict}
    end
  end

  defp materialize_release_paper(candidate) do
    document =
      Repo.one(from d in Document, where: d.id == ^candidate.document_id, lock: "FOR UPDATE")

    with %Document{} = document <- document,
         true <-
           document.rev == candidate.base_document_rev and
             document.current_revision_id == candidate.base_current_revision_id and
             document.released_revision_id == candidate.base_released_revision_id,
         {1, _} <-
           Repo.update_all(
             from(d in Document,
               where:
                 d.id == ^document.id and d.rev == ^candidate.base_document_rev and
                   d.current_revision_id == ^candidate.base_current_revision_id and
                   d.released_revision_id == ^candidate.base_released_revision_id
             ),
             set: [
               title: candidate.title,
               status: candidate.status,
               content: candidate.content,
               rev: candidate.id,
               updated_at: DateTime.utc_now()
             ]
           ),
         {:ok, revision} <- insert_candidate_revision(candidate, document) do
      receipt = %{
        "role" => candidate.role,
        "candidate_id" => candidate.id,
        "document_id" => document.id,
        "doc_id" => candidate.doc_id,
        "title" => candidate.title,
        "status" => candidate.status,
        "content_digest" => candidate.content_digest,
        "source_digest" => candidate.source_digest,
        "before" => %{
          "rev" => candidate.base_document_rev,
          "current_revision_id" => candidate.base_current_revision_id,
          "released_revision_id" => candidate.base_released_revision_id
        },
        "after" => %{
          "rev" => candidate.id,
          "current_revision_id" => candidate.id,
          "released_revision_id" => candidate.id
        }
      }

      {:ok, revision, receipt}
    else
      false -> {:error, :paper_candidate_stale}
      {0, _} -> {:error, :paper_candidate_stale}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :paper_candidate_stale}
    end
  end

  defp insert_candidate_revision(candidate, document) do
    attrs = %{
      document_id: document.id,
      doc_id: candidate.doc_id,
      type: "paper",
      dataset: document.dataset,
      dataset_id: document.dataset_id,
      title: candidate.title,
      status: candidate.status,
      content: candidate.content,
      action: "publish",
      workspace_id: document.workspace_id,
      project_id: document.project_id
    }

    case Repo.one(
           from revision in Revision, where: revision.id == ^candidate.id, lock: "FOR SHARE"
         ) do
      nil ->
        %Revision{}
        |> Revision.changeset(attrs)
        |> Ecto.Changeset.put_change(:id, candidate.id)
        |> Repo.insert()

      %Revision{} = revision ->
        if exact_candidate_revision?(revision, attrs) do
          {count, _} =
            Repo.update_all(
              from(row in Document, where: row.id == ^document.id and row.rev == ^candidate.id),
              set: [
                current_revision_id: candidate.id,
                released_revision_id: candidate.id,
                updated_at: DateTime.utc_now()
              ]
            )

          if count == 1, do: {:ok, revision}, else: {:error, :paper_candidate_stale}
        else
          {:error, :paper_candidate_conflict}
        end
    end
  end

  defp exact_candidate_revision?(revision, attrs) do
    Enum.all?(attrs, fn {field, value} -> Map.get(revision, field) == value end)
  end

  defp legacy_promotion_gate(target, receipt_digest, release_admission, successor_revision) do
    b1_experiment_id = release_admission.receipt["b1_experiment_id"]

    with {:ok, summary} <- reconcile(Map.take(target, @scope_fields)),
         %Experiment{} = experiment <- release_b1_experiment(target, b1_experiment_id),
         {:ok, b1_document} <- EpicFleet.export_benchmark(experiment),
         {:ok, b1_bytes} <- EpicFleet.export_benchmark_json(experiment) do
      fleet_digest = EpicFleet.canonical_digest(summary.canonical_fleet)

      scope_receipt = %{
        "version" => "b1-scope-fence-v1",
        "workspace_id" => target.workspace_id,
        "project_id" => target.project_id,
        "epic_id" => target.epic_id,
        "wave_id" => target.wave_id,
        "wave_revision" => target.id,
        "inventory_digest" => target.inventory_digest,
        "plan_digest" => effective_plan_digest(target),
        "reconciliation_digest" => summary.reconciliation_digest,
        "fleet_digest" => fleet_digest
      }

      scope_receipt =
        Map.put(scope_receipt, "receipt_digest", EpicFleet.canonical_digest(scope_receipt))

      unsigned = %{
        "format" => "cycle-promotion-gate-v1",
        "wave_revision" => target.id,
        "inventory_digest" => target.inventory_digest,
        "plan_digest" => effective_plan_digest(target),
        "reconciliation_digest" => summary.reconciliation_digest,
        "correction_receipt_digest" => receipt_digest,
        "semantic_digest" => EpicFleet.canonical_digest(summary.correction_receipt["targets"]),
        "b1_scope_receipt_digest" => scope_receipt["receipt_digest"],
        "b1_experiment_id" => experiment.id,
        "b1_ledger_digest" => b1_document["ledger_digest"],
        "b1_bytes_digest" => sha256_bytes(b1_bytes),
        "paper_document_id" => successor_revision.document_id,
        "paper_revision_id" => successor_revision.id,
        "paper_doc_id" => successor_revision.doc_id,
        "paper_content_digest" => EpicFleet.canonical_digest(successor_revision.content)
      }

      {:ok, Map.put(unsigned, "receipt_digest", EpicFleet.canonical_digest(unsigned))}
    else
      _ -> {:error, :invalid_activate_release_gate}
    end
  end

  defp restore_release_materializations(chain, restore_event_id) do
    promotions =
      Enum.filter(chain, &(&1.action == "promote" and is_map(&1.release_materialization)))

    baseline =
      Enum.reduce(promotions, %{}, fn event, acc ->
        Enum.reduce(event.release_materialization["documents"], acc, fn row, states ->
          Map.put_new(states, row["document_id"], row["before"])
        end)
      end)

    {current, snapshots} = release_materialization_snapshots(chain, baseline)
    desired = if restore_event_id, do: Map.fetch!(snapshots, restore_event_id), else: baseline

    with :ok <-
           Enum.reduce_while(desired, :ok, fn {document_id, state}, :ok ->
             restore_release_document(
               {document_id, Map.fetch!(current, document_id), state},
               :ok
             )
           end) do
      unsigned = %{
        "format" => "cycle-release-restoration-v1",
        "restore_event_id" => restore_event_id,
        "documents" => Enum.map(desired, fn {id, state} -> Map.put(state, "document_id", id) end)
      }

      {:ok, Map.put(unsigned, "digest", EpicFleet.canonical_digest(unsigned))}
    end
  end

  defp release_materialization_snapshots(chain, baseline) do
    Enum.reduce(chain, {baseline, %{}}, fn event, {current, snapshots} ->
      next =
        cond do
          event.action == "promote" and is_map(event.release_materialization) ->
            Enum.reduce(event.release_materialization["documents"], current, fn row, states ->
              Map.put(states, row["document_id"], row["after"])
            end)

          event.action == "rollback" and is_nil(event.restore_event_id) ->
            baseline

          event.action == "rollback" ->
            Map.fetch!(snapshots, event.restore_event_id)

          true ->
            current
        end

      {next, Map.put(snapshots, event.id, next)}
    end)
  end

  defp restore_release_document({document_id, expected, state}, :ok) do
    document = Repo.one(from d in Document, where: d.id == ^document_id, lock: "FOR UPDATE")
    revision = Repo.get(Revision, state["current_revision_id"])

    if (document && revision && revision.document_id == document.id) and
         document.rev == expected["rev"] and
         document.current_revision_id == expected["current_revision_id"] and
         document.released_revision_id == expected["released_revision_id"] do
      {count, _} =
        Repo.update_all(from(d in Document, where: d.id == ^document.id),
          set: [
            rev: state["rev"],
            current_revision_id: state["current_revision_id"],
            released_revision_id: state["released_revision_id"],
            title: revision.title,
            status: revision.status,
            content: revision.content,
            updated_at: DateTime.utc_now()
          ]
        )

      if count == 1, do: {:cont, :ok}, else: {:halt, {:error, :paper_restore_conflict}}
    else
      {:halt, {:error, :paper_restore_conflict}}
    end
  end

  defp correction_ready?(target) do
    case reconcile(Map.take(target, @scope_fields)) do
      {:ok, summary} ->
        with true <- summary.exact || {:error, :correction_not_ready},
             true <- summary.fleet_complete || {:error, :correction_not_ready},
             true <-
               get_in(summary, [:experiment, :complete?]) || {:error, :correction_not_ready},
             true <- correction_violation_lists_empty?(summary) || {:error, :correction_not_ready} do
          :ok
        end

      _ ->
        {:error, :correction_not_ready}
    end
  end

  defp correction_violation_lists_empty?(summary) do
    Enum.all?(
      ~w(duplicate_assignment_unit_ids unknown_assignment_unit_ids unknown_outcome_unit_ids outcome_overlap_unit_ids outcome_ownership_violation_unit_ids invalid_build_assignment_ids invalid_build_result_assignment_ids unassigned_unit_ids unaccounted_unit_ids)a,
      &(Map.get(summary, &1) == [])
    )
  end

  defp validate_gate_receipt(target, gate, receipt_digest) do
    with {:ok, summary} <- reconcile(Map.take(target, @scope_fields)),
         %Revision{} = paper <- authoritative_gate_paper(target, gate),
         true <-
           contains_cycle_authority?(
             paper.content,
             stringify_keys(summary),
             stringify_keys(summary.canonical_fleet)
           ) do
      fleet_digest = EpicFleet.canonical_digest(summary.canonical_fleet)
      paper_content_digest = EpicFleet.canonical_digest(paper.content)

      b1_scope_receipt = %{
        "version" => "b1-scope-fence-v1",
        "workspace_id" => target.workspace_id,
        "project_id" => target.project_id,
        "epic_id" => target.epic_id,
        "wave_id" => target.wave_id,
        "wave_revision" => target.id,
        "inventory_digest" => target.inventory_digest,
        "plan_digest" => effective_plan_digest(target),
        "reconciliation_digest" => summary.reconciliation_digest,
        "fleet_digest" => fleet_digest
      }

      b1_scope_receipt =
        Map.put(
          b1_scope_receipt,
          "receipt_digest",
          EpicFleet.canonical_digest(b1_scope_receipt)
        )

      with %Experiment{} = experiment <- authoritative_b1_experiment(target, gate),
           {:ok, b1_document} <- EpicFleet.export_benchmark(experiment),
           {:ok, b1_bytes} <- EpicFleet.export_benchmark_json(experiment),
           true <-
             valid_b1_document?(
               b1_document,
               b1_scope_receipt,
               fleet_digest,
               target,
               summary.canonical_fleet
             ) do
        b1_ledger_digest = b1_document["ledger_digest"]
        b1_bytes_digest = sha256_bytes(b1_bytes)

        expected = %{
          "format" => "cycle-promotion-gate-v1",
          "wave_revision" => target.id,
          "inventory_digest" => target.inventory_digest,
          "plan_digest" => effective_plan_digest(target),
          "reconciliation_digest" => summary.reconciliation_digest,
          "correction_receipt_digest" => receipt_digest,
          "semantic_digest" => EpicFleet.canonical_digest(summary.correction_receipt["targets"]),
          "b1_scope_receipt_digest" => b1_scope_receipt["receipt_digest"],
          "b1_experiment_id" => experiment.id,
          "b1_ledger_digest" => b1_ledger_digest,
          "b1_bytes_digest" => b1_bytes_digest,
          "paper_document_id" => paper.document_id,
          "paper_revision_id" => paper.id,
          "paper_doc_id" => paper.doc_id,
          "paper_content_digest" => paper_content_digest
        }

        if gate == Map.put(expected, "receipt_digest", EpicFleet.canonical_digest(expected)) do
          {:ok,
           %{
             reconciliation_digest: summary.reconciliation_digest,
             fleet_digest: fleet_digest,
             b1_scope_receipt: b1_scope_receipt,
             b1_scope_receipt_digest: b1_scope_receipt["receipt_digest"],
             b1_experiment_id: experiment.id,
             b1_ledger_digest: b1_ledger_digest,
             b1_bytes_digest: b1_bytes_digest,
             paper_document_id: paper.document_id,
             paper_revision_id: paper.id,
             paper_doc_id: paper.doc_id,
             paper_content_digest: paper_content_digest
           }}
        else
          {:error, :invalid_gate_receipt}
        end
      else
        _ -> {:error, :invalid_gate_receipt}
      end
    else
      _ -> {:error, :invalid_gate_receipt}
    end
  end

  defp authoritative_b1_experiment(target, gate) do
    with {:ok, id} <- Ecto.UUID.cast(gate["b1_experiment_id"]) do
      Repo.one(
        from experiment in Experiment,
          where:
            experiment.id == ^id and experiment.workspace_id == ^target.workspace_id and
              experiment.epic_id == ^target.epic_id and experiment.wave_id == ^target.wave_id and
              experiment.artifact_format == "barkpark-epic-benchmark-v1",
          lock: "FOR SHARE"
      )
    else
      _ -> nil
    end
  end

  defp valid_b1_document?(document, scope_receipt, fleet_digest, target, fleet) do
    expected_attempts =
      for phase <- ~w(survey verify experiment build review),
          assignment <-
            fleet
            |> stringify_keys()
            |> get_in([phase, "assignments"])
            |> Kernel.||([])
            |> Enum.sort_by(& &1["id"]) do
        {phase, assignment}
      end

    attempts = document["attempts"]

    document["format"] == "barkpark-epic-benchmark-v1" and
      document["experiment"]["workspace_id"] == target.workspace_id and
      document["experiment"]["epic_id"] == target.epic_id and
      document["experiment"]["wave_id"] == target.wave_id and
      document["manifest"]["cycle_scope_fence"] == scope_receipt and
      document["manifest"]["fleet_contract"] == %{
        "version" => 1,
        "paper_fleet_digest" => fleet_digest
      } and length(attempts) == length(expected_attempts) and attempts != [] and
      Enum.zip(attempts, expected_attempts)
      |> Enum.with_index(1)
      |> Enum.all?(fn {{attempt, {phase, assignment}}, ordinal} ->
        attempt["attempt_id"] == "cycle-#{phase}-#{assignment["id"]}" and
          attempt["ordinal"] == ordinal and attempt["status"] == "completed" and
          attempt["treatment"] == "cyclefleet-reconciliation" and
          attempt["provenance"]["wave_revision"] == target.id and
          attempt["provenance"]["scope_receipt_digest"] == scope_receipt["receipt_digest"] and
          attempt["payload"]["fleet_assignment"] == %{
            "phase" => phase,
            "assignment_id" => assignment["id"],
            "agent_type" => assignment["agent_type"],
            "evidence" => assignment["evidence"],
            "model_reasoning_effort" =>
              if(phase in ["build", "review"], do: "high", else: "medium")
          }
      end)
  rescue
    _ -> false
  end

  defp sha256_bytes(bytes),
    do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp authoritative_gate_paper(target, gate) do
    with {:ok, id} <- Ecto.UUID.cast(gate["paper_revision_id"]),
         {:ok, document_id} <- Ecto.UUID.cast(gate["paper_document_id"]),
         doc_id when is_binary(doc_id) <- gate["paper_doc_id"] do
      Repo.one(
        from paper in Revision,
          join: document in Document,
          on:
            document.id == paper.document_id and document.current_revision_id == paper.id and
              document.released_revision_id == paper.id,
          join: dataset in Dataset,
          on: dataset.id == document.dataset_id and dataset.slug == "production",
          where:
            paper.id == ^id and document.id == ^document_id and
              paper.workspace_id == ^target.workspace_id and
              paper.project_id == ^target.project_id and paper.type == "paper" and
              paper.dataset == "production" and paper.status == "published" and
              paper.doc_id == ^doc_id and document.dataset == "production" and
              document.status == "published" and document.content == paper.content and
              document.title == paper.title,
          lock: "FOR SHARE"
      )
    else
      _ -> nil
    end
  end

  defp contains_cycle_authority?(%{"blocks" => blocks}, ledger, fleet) when is_list(blocks) do
    authority_blocks =
      Enum.filter(blocks, &(Map.has_key?(&1, "cycle_ledger") or Map.has_key?(&1, "fleet")))

    case authority_blocks do
      [block] -> block["cycle_ledger"] == ledger and block["fleet"] == fleet
      _ -> false
    end
  end

  defp contains_cycle_authority?(_value, _ledger, _fleet), do: false

  defp persist_admission(root, target, common, gate, authority) do
    attrs =
      authority
      |> Map.merge(%{
        root_wave_id: root.id,
        target_wave_id: target.id,
        workspace_id: root.workspace_id,
        project_id: root.project_id,
        epic_id: root.epic_id,
        idempotency_key: common.idempotency_key,
        gate_receipt: gate,
        gate_receipt_digest: EpicFleet.canonical_digest(gate)
      })

    case Repo.insert(Admission.insert_changeset(attrs)) do
      {:ok, admission} -> admission
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp normalize_transition_attrs(attrs) do
    with {:ok, actor} <- normalize_actor(value(attrs, :actor)),
         key when is_binary(key) <- value(attrs, :idempotency_key),
         evidence when is_binary(evidence) <- value(attrs, :evidence),
         revision when is_binary(revision) <- value(attrs, :evidence_revision),
         true <- Enum.all?([key, evidence], &nonempty?/1),
         true <- digest_string?(revision) do
      {:ok,
       %{
         actor: actor,
         idempotency_key: key,
         evidence: evidence,
         evidence_revision: revision
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_transition_evidence}
    end
  end

  defp normalize_actor(actor) when is_map(actor) do
    actor = stringify_keys(actor)

    if Map.keys(actor) |> Enum.sort() == ["id", "type"] and nonempty?(actor["id"]) and
         nonempty?(actor["type"]),
       do: {:ok, actor},
       else: {:error, :invalid_actor}
  end

  defp normalize_actor(_), do: {:error, :invalid_actor}

  defp normalize_correction_receipt(receipt) when is_map(receipt) do
    receipt = stringify_keys(receipt)

    if Map.keys(receipt) |> Enum.sort() == Enum.sort(@correction_receipt_keys),
      do: {:ok, receipt},
      else: {:error, :invalid_correction_receipt}
  rescue
    _ -> {:error, :invalid_correction_receipt}
  end

  defp normalize_correction_receipt(_), do: {:error, :invalid_correction_receipt}

  defp normalize_gate_receipt(receipt) when is_map(receipt) do
    receipt = stringify_keys(receipt)

    release_keys =
      ~w(format stage authority projection authorities b1_experiment_id papers captures correction_lifecycle_digest bundle_digest receipt_digest)

    if (Map.keys(receipt) |> Enum.sort()) in [
         Enum.sort(@gate_receipt_keys),
         Enum.sort(release_keys)
       ] and
         (receipt["format"] == "cycle-promotion-gate-v1" or
            (receipt["format"] == "cycle-release-gate-v1" and receipt["stage"] == "activate")),
       do: {:ok, receipt},
       else: {:error, :invalid_gate_receipt}
  rescue
    _ -> {:error, :invalid_gate_receipt}
  end

  defp normalize_gate_receipt(_), do: {:error, :invalid_gate_receipt}

  defp validate_target_receipt(target, receipt) do
    with true <- not is_nil(target.correction_of_wave_id),
         true <- correction_receipt(target) == receipt do
      {:ok, EpicFleet.canonical_digest(receipt)}
    else
      _ -> {:error, :invalid_correction_receipt}
    end
  end

  defp ancestry_root_wave(%Wave{correction_of_wave_id: nil} = wave), do: wave

  defp ancestry_root_wave(%Wave{correction_of_wave_id: parent}),
    do: Wave |> Repo.get!(parent) |> ancestry_root_wave()

  defp rollback_target(root, _chain, "genesis"), do: {:ok, nil, root}

  defp rollback_target(_root, chain, restore_id) when is_binary(restore_id) do
    head = List.last(chain)

    with {:ok, restore_id} <- Ecto.UUID.cast(restore_id),
         %Event{action: "promote"} = event <- Enum.find(chain, &(&1.id == restore_id)),
         true <- event.id != head.id,
         %Wave{} = target <- Repo.get(Wave, event.target_wave_id) do
      {:ok, restore_id, target}
    else
      _ -> {:error, :invalid_rollback_target}
    end
  end

  defp rollback_target(_root, _chain, _restore), do: {:error, :invalid_rollback_target}

  defp linked_wave_ancestry(root, targets) do
    children = Map.new(targets, &{&1.previous_wave_id, &1.wave_id})
    follow_wave_ancestry(root, children, [root], MapSet.new([root.id]))
  end

  defp follow_wave_ancestry(wave, children, acc, seen) do
    case Map.get(children, wave.id) do
      nil ->
        Enum.reverse(acc)

      id when is_binary(id) ->
        if MapSet.member?(seen, id) do
          Enum.reverse(acc)
        else
          child = Repo.get!(Wave, id)
          follow_wave_ancestry(child, children, [child | acc], MapSet.put(seen, id))
        end
    end
  end

  defp lifecycle_wave(wave, status) do
    correction = wave.correction_of || %{}

    semantic =
      case reconcile(Map.take(wave, @scope_fields)) do
        {:ok, summary} ->
          %{
            reconciliation_digest: summary.reconciliation_digest,
            inventory_count: summary.inventory_count,
            shipped_count: summary.shipped_count,
            stalled_count: summary.stalled_count,
            excluded_count: summary.excluded_count,
            exact: summary.exact,
            fleet_complete: summary.fleet_complete
          }

        _ ->
          nil
      end

    %{
      status: status,
      wave_id: wave.wave_id,
      wave_revision: wave.id,
      correction_of_digest: wave.correction_of_digest,
      before_counts: correction["before_counts"],
      delta: correction["delta"],
      after_counts: correction["after_counts"],
      semantic_snapshot: semantic
    }
  end

  defp current_promoted_wave(nil), do: nil
  defp current_promoted_wave(%Event{action: "rollback", restore_event_id: nil}), do: nil
  defp current_promoted_wave(%Event{target_wave_id: id}), do: Repo.get!(Wave, id)

  defp effective_admission(nil, _events), do: nil

  defp effective_admission(%Event{action: "promote", admission_id: admission_id}, _events),
    do: Repo.get!(Admission, admission_id)

  defp effective_admission(%Event{action: "rollback", restore_event_id: nil}, _events), do: nil

  defp effective_admission(%Event{action: "rollback", restore_event_id: restore_id}, events) do
    with %Event{admission_id: admission_id} <- Enum.find(events, &(&1.id == restore_id)) do
      Repo.get!(Admission, admission_id)
    end
  end

  defp lifecycle_event(event) do
    admission = event.admission_id && Repo.get(Admission, event.admission_id)

    %{
      event_id: event.id,
      action: event.action,
      target_wave_revision: event.target_wave_id,
      previous_event_id: event.previous_event_id,
      restore_event_id: event.restore_event_id,
      actor: event.actor,
      evidence: event.evidence,
      evidence_revision: event.evidence_revision,
      event_digest: event.event_digest,
      admission: admission && lifecycle_admission(admission)
    }
  end

  defp lifecycle_admission(admission) do
    %{
      admission_id: admission.id,
      target_wave_revision: admission.target_wave_id,
      b1_scope_receipt: admission.b1_scope_receipt,
      b1_scope_receipt_digest: admission.b1_scope_receipt_digest,
      b1_experiment_id: admission.b1_experiment_id,
      b1_ledger_digest: admission.b1_ledger_digest,
      b1_bytes_digest: admission.b1_bytes_digest,
      paper_revision_id: admission.paper_revision_id,
      paper_document_id: admission.paper_document_id,
      paper_doc_id: admission.paper_doc_id,
      paper_content_digest: admission.paper_content_digest,
      fleet_digest: admission.fleet_digest,
      reconciliation_digest: admission.reconciliation_digest
    }
  end

  defp lifecycle_quarantine(row) do
    %{
      quarantine_id: row.id,
      correction_wave_revision: row.correction_wave_id,
      reason: row.reason,
      actor: row.actor,
      evidence: row.evidence,
      evidence_revision: row.evidence_revision,
      event_digest: row.event_digest
    }
  end

  defp nullable_uuid(nil), do: nil

  defp nullable_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      _ -> :invalid
    end
  end

  defp nullable_uuid(_), do: :invalid

  defp digest_string?(value),
    do: is_binary(value) and String.match?(value, ~r/^[0-9a-f]{64}$/)

  defp jsonb_digest(payload) do
    EpicFleet.canonical_digest(payload)
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp reconcile_wave_insert({:ok, wave}, _attrs), do: {:ok, wave}

  defp reconcile_wave_insert({:error, changeset}, attrs) do
    existing = get_wave_by_scope(Map.take(attrs, @scope_fields))

    cond do
      is_nil(existing) -> {:error, changeset}
      wave_replay?(existing, attrs) -> {:ok, existing}
      true -> {:error, :wave_conflict}
    end
  end

  defp get_wave_by_scope(%{project_id: project_id} = scope) when is_binary(project_id) do
    Repo.one(
      from w in Wave,
        where:
          w.workspace_id == ^scope.workspace_id and w.project_id == ^project_id and
            w.epic_id == ^scope.epic_id and w.wave_id == ^scope.wave_id
    )
  end

  defp get_wave_by_scope(%{project_id: nil} = scope) do
    Repo.one(
      from w in Wave,
        where:
          w.workspace_id == ^scope.workspace_id and is_nil(w.project_id) and
            w.epic_id == ^scope.epic_id and w.wave_id == ^scope.wave_id
    )
  end

  defp reconcile_build_plan_insert({:ok, plan}, _attrs), do: {:ok, plan}

  defp reconcile_build_plan_insert({:error, changeset}, attrs) do
    existing = Repo.get_by(BuildPlan, wave_id: attrs.wave_id)

    cond do
      is_nil(existing) -> {:error, changeset}
      build_plan_replay?(existing, attrs) -> {:ok, existing}
      true -> {:error, :build_plan_conflict}
    end
  end

  defp wave_replay?(wave, attrs) do
    wave.profile == attrs.profile and wave.inventory_digest == attrs.inventory_digest and
      wave.plan_digest == attrs.plan_digest and
      wave.experiment_contract == attrs.experiment_contract and
      wave.scale_contract == attrs.scale_contract and
      wave.correction_of_wave_id == Map.get(attrs, :correction_of_wave_id) and
      wave.correction_of == Map.get(attrs, :correction_of) and
      wave.correction_of_digest == Map.get(attrs, :correction_of_digest)
  end

  defp reconciliation_ancestry(%Wave{correction_of_wave_id: nil}), do: []

  defp reconciliation_ancestry(%Wave{} = wave) do
    case correction_ancestry(wave) do
      {:ok, ancestry} -> ancestry
      {:error, _} -> [%{"wave_id" => wave.wave_id, "wave_revision" => wave.id}]
    end
  end

  defp build_plan_replay?(plan, attrs) do
    Enum.all?(
      ~w(proven_batch_capacity plan_digest inventory_digest chosen_format pilot_evidence pilot_evidence_revision failure_rate failure_threshold golden_fixtures quality_rubric)a,
      &(Map.get(plan, &1) == Map.get(attrs, &1))
    )
  end

  defp assignment_plan(attrs, wave) do
    if value(attrs, :phase) == "build" and wave.profile == "legendary" do
      case get_build_plan(wave) do
        %BuildPlan{plan: plan} -> {:ok, plan}
        nil -> {:error, :build_plan_not_sealed}
      end
    else
      {:ok, effective_plan(wave)}
    end
  end

  defp validate_assignment_against_plan(attrs, plan, wave) do
    config = Map.get(plan, value(attrs, :phase))
    phase = value(attrs, :phase)
    build_plan = get_build_plan(wave)

    cond do
      not is_map(config) ->
        {:error, :phase_not_in_profile}

      value(attrs, :agent_type) != Map.get(config, "agent_type") ->
        {:error, :agent_type_not_in_profile}

      value(attrs, :effort) != Map.get(config, "effort") ->
        {:error, :effort_not_in_profile}

      phase == "experiment" and not is_nil(build_plan) ->
        {:error, :experiment_phase_sealed}

      is_nil(value(attrs, :replaces_assignment_id)) and
        not existing_logical_assignment?(wave, attrs) and
          live_phase_count(wave, phase) >= Map.fetch!(config, "planned") ->
        {:error, :phase_assignment_capacity_exhausted}

      phase == "build" and not is_nil(build_plan) ->
        validate_build_assignment(attrs, wave, build_plan.proven_batch_capacity)

      phase == "build" ->
        validate_build_assignment(attrs, wave, nil)

      true ->
        :ok
    end
  end

  defp validate_build_assignment(attrs, wave, capacity) do
    inventory_ids = wave.inventory |> Enum.map(&unit_id/1) |> MapSet.new()

    with {:ok, unit_ids} <- strict_string_list(value(value(attrs, :snapshot, %{}), :unit_ids)),
         true <- unit_ids != [] || {:error, :invalid_build_unit_ids},
         true <-
           length(unit_ids) == MapSet.size(MapSet.new(unit_ids)) ||
             {:error, :duplicate_build_unit_ids},
         true <-
           (is_nil(capacity) or length(unit_ids) <= capacity) ||
             {:error, :proven_batch_capacity_exceeded},
         true <-
           MapSet.subset?(MapSet.new(unit_ids), inventory_ids) ||
             {:error, :build_unit_not_in_inventory} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_build_unit_ids}
    end
  end

  defp live_phase_count(wave, phase) do
    assignments = EpicFleet.list_cycle_assignments(wave.id)

    replaced_ids =
      assignments
      |> Enum.map(& &1.replaces_assignment_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.count(assignments, fn assignment ->
      assignment.phase == phase and not MapSet.member?(replaced_ids, assignment.id)
    end)
  end

  defp existing_logical_assignment?(wave, attrs) do
    assignment_id = value(attrs, :assignment_id)

    is_binary(assignment_id) and
      Repo.exists?(
        from assignment in Assignment,
          where:
            assignment.cycle_wave_id == ^wave.id and
              assignment.assignment_id == ^assignment_id
      )
  end

  defp normalize_scope(attrs) do
    scope = Map.new(@scope_fields, &{&1, value(attrs, &1)})

    required = Map.take(scope, [:workspace_id, :epic_id, :wave_id])
    project_id = scope.project_id

    cond do
      not Enum.all?(required, fn {_key, item} -> is_binary(item) and item != "" end) ->
        {:error, :invalid_scope}

      is_nil(project_id) ->
        {:ok, scope}

      not is_binary(project_id) or project_id == "" ->
        {:error, :invalid_scope}

      Repo.exists?(
        from p in Project, where: p.id == ^project_id and p.workspace_id == ^scope.workspace_id
      ) ->
        {:ok, scope}

      true ->
        {:error, :project_scope_mismatch}
    end
  end

  defp normalize_scale_contract("epic", nil, _inventory), do: {:ok, %{}}

  defp normalize_scale_contract("epic", contract, _inventory) when contract in [%{}, nil],
    do: {:ok, %{}}

  defp normalize_scale_contract("legendary", contract, inventory) when is_map(contract) do
    contract = stringify_keys(contract)
    target_surfaces = contract["target_surfaces"]
    exclusions = contract["excluded_inventory"]
    rubric = contract["quality_rubric"]
    threshold = contract["failure_threshold"]

    valid? =
      length(inventory) >= 15 and
        nonempty?(contract["unit_definition"]) and
        contract["unit_count"] == length(inventory) and
        nonempty?(contract["inventory_evidence"]) and
        is_list(target_surfaces) and target_surfaces != [] and
        Enum.all?(target_surfaces, &nonempty?/1) and
        is_integer(contract["concurrency_width"]) and contract["concurrency_width"] > 0 and
        contract["minimum_multiplier"] == 5 and
        contract["build_formula"] ==
          "max(15, ceil(unit_count / proven_batch_capacity))" and
        is_list(exclusions) and Enum.all?(exclusions, &valid_exclusion?/1) and
        is_map(rubric) and map_size(rubric) > 0 and
        is_number(threshold) and threshold >= 0

    if valid?, do: {:ok, contract}, else: {:error, :invalid_scale_contract}
  end

  defp normalize_scale_contract(_profile, _contract, _inventory),
    do: {:error, :invalid_scale_contract}

  defp normalize_golden_fixtures(fixtures) when is_list(fixtures) do
    if fixtures != [] and Enum.all?(fixtures, &nonempty?/1) do
      {:ok, fixtures |> Enum.uniq() |> Enum.sort()}
    else
      {:error, :invalid_golden_fixtures}
    end
  end

  defp normalize_golden_fixtures(_fixtures), do: {:error, :invalid_golden_fixtures}

  defp normalize_inventory(inventory) when is_list(inventory) do
    normalized =
      Enum.map(inventory, fn
        id when is_binary(id) -> %{"unit_id" => id}
        unit when is_map(unit) -> stringify_keys(unit)
        other -> other
      end)

    ids = Enum.map(normalized, &unit_id/1)

    cond do
      Enum.any?(ids, &(not strict_id?(&1))) -> {:error, :invalid_inventory}
      length(ids) != MapSet.size(MapSet.new(ids)) -> {:error, :duplicate_inventory_unit}
      true -> {:ok, Enum.sort_by(normalized, &unit_id/1)}
    end
  end

  defp normalize_inventory(_inventory), do: {:error, :invalid_inventory}

  defp default_experiment_contract("legendary") do
    %{
      "rounds" => @experiment_rounds,
      "required_results_per_round" => 3,
      "selection_required" => true
    }
  end

  defp default_experiment_contract(_profile), do: %{}

  defp normalize_experiment_contract(profile, nil),
    do: {:ok, default_experiment_contract(profile)}

  defp normalize_experiment_contract(profile, contract) do
    canonical = default_experiment_contract(profile)

    if stringify_keys(contract) == canonical,
      do: {:ok, canonical},
      else: {:error, :invalid_experiment_contract}
  end

  defp snapshot_units(assignment) do
    case strict_string_list(value(assignment.snapshot, :unit_ids)) do
      {:ok, unit_ids} -> unit_ids
      {:error, _} -> []
    end
  end

  defp outcome_sets(rows) do
    Enum.reduce(rows, %{shipped: MapSet.new(), stalled: MapSet.new(), excluded: MapSet.new()}, fn
      {_assignment, %Result{status: "completed", payload: payload}}, acc ->
        Enum.reduce(@outcome_keys, acc, fn {outcome, payload_key}, current ->
          ids =
            case strict_string_list(value(payload, payload_key)) do
              {:ok, unit_ids} -> MapSet.new(unit_ids)
              {:error, _} -> MapSet.new()
            end

          Map.update!(current, outcome, &MapSet.union(&1, ids))
        end)

      _, acc ->
        acc
    end)
  end

  defp experiment_reconciliation(_rows, %Wave{profile: "epic"}),
    do: %{required?: false, complete?: true, round_counts: %{}, missing_rounds: []}

  defp experiment_reconciliation(rows, %Wave{experiment_contract: contract}) do
    rounds = Map.fetch!(contract, "rounds")
    required = Map.fetch!(contract, "required_results_per_round")

    completed =
      Enum.flat_map(rows, fn
        {_assignment, %Result{status: "completed", payload: payload}} ->
          round = canonical_experiment_round(payload, rounds)
          if round in rounds, do: [round], else: []

        _ ->
          []
      end)

    counts = Enum.frequencies(completed)
    missing = Enum.filter(rounds, &(Map.get(counts, &1, 0) != required))

    %{
      required?: true,
      complete?: missing == [],
      round_counts: Map.new(rounds, &{&1, Map.get(counts, &1, 0)}),
      missing_rounds: missing
    }
  end

  defp canonical_experiment_round(payload, rounds) do
    round = value(payload, :round)

    cond do
      round in rounds ->
        round

      is_integer(round) and round >= 1 and round <= length(rounds) ->
        round_name = value(payload, :round_name)
        if Enum.at(rounds, round - 1) == round_name, do: round_name

      true ->
        nil
    end
  end

  defp outcome_ownership_violations(rows) do
    Enum.reduce(rows, MapSet.new(), fn
      {assignment, %Result{status: "completed", payload: payload}}, violations ->
        owned = MapSet.new(snapshot_units(assignment))

        reported =
          @outcome_keys
          |> Map.values()
          |> Enum.flat_map(fn key ->
            case strict_string_list(value(payload, key)) do
              {:ok, unit_ids} -> unit_ids
              {:error, _} -> []
            end
          end)
          |> MapSet.new()

        MapSet.union(violations, MapSet.difference(reported, owned))

      _, violations ->
        violations
    end)
  end

  defp overlaps(outcomes) do
    MapSet.union(
      MapSet.intersection(outcomes.shipped, outcomes.stalled),
      MapSet.union(
        MapSet.intersection(outcomes.shipped, outcomes.excluded),
        MapSet.intersection(outcomes.stalled, outcomes.excluded)
      )
    )
  end

  defp exclude_replaced_rows(rows) do
    replaced_ids =
      rows
      |> Enum.map(fn {assignment, _result} -> assignment.replaces_assignment_id end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reject(rows, fn {assignment, _result} -> MapSet.member?(replaced_ids, assignment.id) end)
  end

  defp validate_seal_ready(%Wave{profile: "legendary"} = wave) do
    rows = Enum.map(list_assignments(wave), &{&1, EpicFleet.get_result(&1)})
    experiment = experiment_reconciliation(exclude_replaced_rows(rows), wave)

    with {:ok, %{fleet: %{experiment: fleet}}} <-
           EpicFleet.reduce_cycle(wave.id, effective_plan(wave)) do
      if experiment.complete? and fleet.completed == fleet.planned and fleet.missing == 0 and
           fleet.invalid_assignments == 0 and fleet.terminal_counts.invalid == 0 and
           fleet.unresolved_failures == 0 and fleet.unresolved_missing == 0 do
        :ok
      else
        {:error, :experiment_assignments_incomplete}
      end
    end
  end

  defp validate_seal_ready(%Wave{}), do: {:error, :seal_not_supported}

  defp resolve_replacement(attrs, wave) do
    case value(attrs, :replaces_assignment_id) do
      nil ->
        {:ok, attrs}

      assignment_id when is_binary(assignment_id) ->
        case replacement_predecessor(wave, assignment_id) do
          %Assignment{} = predecessor ->
            with :ok <- validate_immutable_replacement(attrs, wave, predecessor) do
              {:ok, put_attr(attrs, :replaces_assignment_id, predecessor.id)}
            end

          nil ->
            {:error, :replacement_not_found}
        end

      _ ->
        {:error, :replacement_not_found}
    end
  end

  defp replacement_predecessor(wave, assignment_id) do
    Repo.get_by(Assignment, cycle_wave_id: wave.id, assignment_id: assignment_id) ||
      legacy_flat_predecessor(wave, assignment_id)
  end

  # A project-scoped request never searches outside its exact wave. The only
  # deliberate fallback is a projectless wave resolving a same-workspace legacy
  # predecessor, which makes the immutable contract mismatch observable without
  # leaking a predecessor from another project.
  defp legacy_flat_predecessor(%Wave{project_id: nil} = wave, assignment_id) do
    Repo.one(
      from assignment in Assignment,
        where:
          assignment.workspace_id == ^wave.workspace_id and
            assignment.epic_id == ^wave.epic_id and assignment.wave_id == ^wave.wave_id and
            assignment.assignment_id == ^assignment_id and is_nil(assignment.cycle_wave_id)
    )
  end

  defp legacy_flat_predecessor(_wave, _assignment_id), do: nil

  defp validate_immutable_replacement(attrs, wave, predecessor) do
    cond do
      value(attrs, :phase) != predecessor.phase ->
        {:error, :replacement_phase_mismatch}

      value(attrs, :agent_type) != predecessor.agent_type ->
        {:error, :replacement_agent_type_mismatch}

      predecessor.cycle_wave_id != wave.id ->
        {:error, :replacement_contract_mismatch}

      true ->
        :ok
    end
  end

  defp validate_cycle_result(%Assignment{phase: "build"} = assignment, attrs) do
    if value(attrs, :status) == "completed" do
      validate_completed_build_result(assignment, value(attrs, :payload))
    else
      :ok
    end
  end

  defp validate_cycle_result(%Assignment{}, _attrs), do: :ok

  defp completed_build?(%Assignment{phase: "build"}, attrs),
    do: value(attrs, :status) == "completed"

  defp completed_build?(%Assignment{}, _attrs), do: false

  defp locked_semantic_task(%Assignment{id: assignment_id}) do
    case Repo.get(AssignmentTask, assignment_id) do
      nil ->
        {:error, :semantic_receipt_task_not_bound}

      %AssignmentTask{task_id: task_id} ->
        case Repo.one(
               from(t in Document,
                 where: t.id == ^task_id and t.type == "task",
                 lock: "FOR UPDATE"
               )
             ) do
          nil -> {:error, :semantic_receipt_task_not_found}
          %Document{} = task -> {:ok, task}
        end
    end
  end

  defp semantic_task(%Assignment{id: assignment_id}) do
    with %AssignmentTask{task_id: task_id} <- Repo.get(AssignmentTask, assignment_id),
         %Document{} = task <- Repo.get_by(Document, id: task_id, type: "task") do
      {:ok, task}
    else
      nil -> {:error, :semantic_receipt_task_not_bound}
    end
  end

  defp semantic_build_payload(assignment, payload, task) when is_map(payload) do
    with :ok <- validate_completed_build_result(assignment, payload),
         {:ok, task_truth} <- semantic_task_truth(assignment, task),
         {:ok, outcomes} <- build_outcomes(payload) do
      receipts =
        assignment
        |> snapshot_units()
        |> Enum.sort()
        |> Enum.map(fn unit_id ->
          disposition = Map.fetch!(outcomes, unit_id)

          receipt =
            task_truth
            |> Map.merge(%{
              "unit_id" => unit_id,
              "disposition" => disposition
            })

          Map.put(receipt, "receipt_hash", EpicFleet.canonical_digest(receipt))
        end)

      with :ok <- validate_submitted_receipts(value(payload, :semantic_receipts), receipts) do
        canonical_payload =
          payload
          |> stringify_keys()
          |> Map.drop([
            "semantic_receipts",
            "semantic_receipt_version",
            "semantic_receipt_index_hash",
            "terminal_payload_digest"
          ])

        terminal_payload_digest = EpicFleet.canonical_digest(canonical_payload)
        receipt_hashes = Enum.map(receipts, &Map.fetch!(&1, "receipt_hash"))

        receipt_index_hash =
          EpicFleet.canonical_digest(%{
            "version" => "semantic_receipt-index-v1",
            "terminal_payload_digest" => terminal_payload_digest,
            "receipt_hashes" => receipt_hashes
          })

        {:ok,
         canonical_payload
         |> Map.merge(%{
           "semantic_receipt_version" => "semantic_receipt-v1",
           "semantic_receipts" => receipts,
           "semantic_receipt_index_hash" => receipt_index_hash,
           "terminal_payload_digest" => terminal_payload_digest
         })}
      end
    end
  end

  defp semantic_build_payload(_assignment, _payload, _task),
    do: {:error, :invalid_build_outcome_unit_ids}

  defp semantic_task_truth(assignment, %Document{} = task) do
    content = task.content || %{}
    criteria = Map.get(content, "acceptance_criteria")
    claim = Map.get(content, "claim") || %{}
    wave = Repo.get(Wave, assignment.cycle_wave_id)

    cond do
      is_nil(wave) or task.workspace_id != assignment.workspace_id or
          task.project_id != wave.project_id ->
        {:error, :semantic_receipt_foreign_task}

      Map.get(content, "lifecycle_status") != "done" ->
        {:error, :semantic_receipt_task_not_done}

      not (is_binary(task.rev) and String.trim(task.rev) != "") ->
        {:error, :semantic_receipt_task_revision_required}

      not (is_list(criteria) and criteria != []) ->
        {:error, :semantic_receipt_criteria_required}

      not Enum.all?(criteria, &valid_semantic_criterion?/1) ->
        {:error, :semantic_receipt_criteria_unmet}

      not (is_binary(Map.get(claim, "worker")) and
             String.trim(Map.get(claim, "worker")) != "" and
             is_integer(Map.get(claim, "epoch")) and Map.get(claim, "epoch") > 0) ->
        {:error, :semantic_receipt_claim_required}

      true ->
        {:ok,
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
           "criteria" => Enum.map(criteria, &semantic_criterion/1),
           "claim" => %{
             "worker" => Map.fetch!(claim, "worker"),
             "epoch" => Map.fetch!(claim, "epoch")
           }
         }}
    end
  end

  defp valid_semantic_criterion?(criterion) when is_map(criterion) do
    nonempty?(value(criterion, :criterion)) and value(criterion, :met) == true and
      nonempty?(value(criterion, :evidence))
  end

  defp valid_semantic_criterion?(_criterion), do: false

  defp semantic_criterion(criterion) do
    %{
      "criterion" => value(criterion, :criterion),
      "met" => true,
      "evidence" => value(criterion, :evidence)
    }
  end

  defp validate_submitted_receipts(receipts, expected) when is_list(receipts) do
    normalized = Enum.map(receipts, &stringify_keys/1)
    unit_ids = Enum.map(normalized, &value(&1, :unit_id))

    cond do
      length(unit_ids) != MapSet.size(MapSet.new(unit_ids)) ->
        {:error, :semantic_receipt_duplicate_unit}

      length(normalized) != length(expected) ->
        {:error, :semantic_receipt_count_mismatch}

      true ->
        expected_by_unit = Map.new(expected, &{Map.fetch!(&1, "unit_id"), &1})

        Enum.reduce_while(normalized, :ok, fn submitted, :ok ->
          submitted_claim = value(submitted, :claim, %{})

          case Map.fetch(expected_by_unit, value(submitted, :unit_id)) do
            :error ->
              {:halt, {:error, :semantic_receipt_foreign_unit}}

            {:ok, canonical} ->
              without_hash = Map.delete(canonical, "receipt_hash")
              submitted_hash = Map.get(submitted, "receipt_hash")

              cond do
                not is_map(submitted_claim) ->
                  {:halt, {:error, :semantic_receipt_invalid_claim}}

                value(submitted, :task_id) != Map.fetch!(canonical, "task_id") or
                  value(submitted, :task_doc_id) != Map.fetch!(canonical, "task_doc_id") or
                    value(submitted_claim, :worker) !=
                      get_in(canonical, ["claim", "worker"]) ->
                  {:halt, {:error, :semantic_receipt_foreign_task}}

                value(submitted, :task_rev) != Map.fetch!(canonical, "task_rev") or
                    value(submitted_claim, :epoch) !=
                      get_in(canonical, ["claim", "epoch"]) ->
                  {:halt, {:error, :semantic_receipt_stale_task}}

                Map.drop(submitted, ["receipt_hash"]) != without_hash ->
                  {:halt, {:error, :semantic_receipt_contradiction}}

                not is_nil(submitted_hash) and
                    submitted_hash != Map.fetch!(canonical, "receipt_hash") ->
                  {:halt, {:error, :semantic_receipt_hash_mismatch}}

                true ->
                  {:cont, :ok}
              end
          end
        end)
    end
  end

  defp validate_submitted_receipts(_receipts, _expected),
    do: {:error, :semantic_receipts_required}

  defp build_outcomes(payload) do
    with {:ok, shipped} <- strict_string_list(value(payload, :completed_unit_ids)),
         {:ok, stalled} <- strict_string_list(value(payload, :stalled_unit_ids)),
         {:ok, excluded} <- strict_string_list(value(payload, :excluded_unit_ids)) do
      {:ok,
       Enum.reduce(
         [shipped: shipped, stalled: stalled, excluded: excluded],
         %{},
         fn {disposition, ids}, acc ->
           Enum.reduce(ids, acc, &Map.put(&2, &1, Atom.to_string(disposition)))
         end
       )}
    end
  end

  defp validate_completed_build_result(assignment, payload) when is_map(payload) do
    owned = snapshot_units(assignment)

    with {:ok, shipped} <- strict_string_list(value(payload, :completed_unit_ids)),
         {:ok, stalled} <- strict_string_list(value(payload, :stalled_unit_ids)),
         {:ok, excluded} <- strict_string_list(value(payload, :excluded_unit_ids)),
         outcomes = shipped ++ stalled ++ excluded,
         true <-
           length(outcomes) == MapSet.size(MapSet.new(outcomes)) ||
             {:error, :build_outcome_overlap},
         true <-
           MapSet.new(outcomes) == MapSet.new(owned) ||
             {:error, :build_outcomes_do_not_partition_assignment} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_build_outcome_unit_ids}
    end
  end

  defp validate_completed_build_result(_assignment, _payload),
    do: {:error, :invalid_build_outcome_unit_ids}

  defp invalid_build_assignment_ids(rows, inventory_ids, build_plan) do
    capacity = build_plan && build_plan.proven_batch_capacity

    Enum.reduce(rows, MapSet.new(), fn {assignment, _result}, invalid ->
      case strict_string_list(value(assignment.snapshot, :unit_ids)) do
        {:ok, unit_ids} ->
          valid? =
            unit_ids != [] and length(unit_ids) == MapSet.size(MapSet.new(unit_ids)) and
              (is_nil(capacity) or length(unit_ids) <= capacity) and
              MapSet.subset?(MapSet.new(unit_ids), inventory_ids)

          if valid?, do: invalid, else: MapSet.put(invalid, assignment.assignment_id)

        {:error, _} ->
          MapSet.put(invalid, assignment.assignment_id)
      end
    end)
  end

  defp invalid_build_result_ids(rows) do
    Enum.reduce(rows, MapSet.new(), fn
      {assignment, %Result{status: "completed", payload: payload}}, invalid ->
        with {:ok, task} <- semantic_task(assignment),
             {:ok, expected} <- semantic_build_payload(assignment, payload, task),
             true <- expected == stringify_keys(payload) do
          invalid
        else
          _ -> MapSet.put(invalid, assignment.assignment_id)
        end

      _, invalid ->
        invalid
    end)
  end

  defp fleet_complete?(fleet) when is_map(fleet) and map_size(fleet) > 0 do
    Enum.all?(fleet, fn {_phase, phase} ->
      phase.completed == phase.planned and phase.missing == 0 and
        phase.invalid_assignments == 0 and phase.terminal_counts.invalid == 0 and
        phase.unresolved_failures == 0 and phase.unresolved_missing == 0
    end)
  end

  defp fleet_complete?(_fleet), do: false

  defp fleet_counts(fleet) when is_map(fleet) do
    Enum.reduce(
      fleet,
      %{
        planned: 0,
        started: 0,
        completed: 0,
        failed: 0,
        missing: 0,
        invalid_assignments: 0,
        invalid_results: 0
      },
      fn {_phase, phase}, counts ->
        %{
          planned: counts.planned + phase.planned,
          started: counts.started + phase.started,
          completed: counts.completed + phase.completed,
          failed: counts.failed + phase.failed,
          missing: counts.missing + phase.missing,
          invalid_assignments: counts.invalid_assignments + phase.invalid_assignments,
          invalid_results: counts.invalid_results + phase.terminal_counts.invalid
        }
      end
    )
  end

  defp valid_exclusion?(exclusion) when is_map(exclusion) do
    nonempty?(value(exclusion, :unit_id)) and nonempty?(value(exclusion, :reason))
  end

  defp valid_exclusion?(_exclusion), do: false

  defp nonempty?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty?(_value), do: false

  defp duplicates(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.reduce(MapSet.new(), fn
      {id, count}, acc when count > 1 -> MapSet.put(acc, id)
      _, acc -> acc
    end)
  end

  defp effective_plan(wave), do: (get_build_plan(wave) || wave).plan
  defp effective_plan_digest(wave), do: (get_build_plan(wave) || wave).plan_digest

  defp managed_codex_attempt?(opts) do
    case {value(opts, :provider, "codex"), value(opts, :execution_target, "managed"),
          value(opts, :runtime_surface, "studio_chat")} do
      {"codex", "managed", "studio_chat"} -> :ok
      _ -> {:error, :provider_capability_absent}
    end
  end

  defp normalize_attempt_claim(claim) do
    task_id = value(claim, :task_id, value(claim, :id))
    worker_id = value(claim, :worker_id)
    epoch = value(claim, :epoch)
    work_digest = value(claim, :work_digest)

    with {:ok, task_id} <- cast_assignment_task_id(task_id),
         true <- nonempty?(worker_id),
         true <- is_integer(epoch) and epoch > 0,
         true <- is_binary(work_digest) and Regex.match?(~r/^[0-9a-f]{16}$/, work_digest) do
      {:ok, %{task_id: task_id, worker_id: worker_id, epoch: epoch, work_digest: work_digest}}
    else
      _ -> {:error, :invalid_runtime_attempt_claim}
    end
  end

  defp authorize_runtime_attempt(assignment_id, claim, opts) do
    case runtime_attempt_authority(assignment_id) do
      nil ->
        Repo.rollback(:runtime_attempt_authority_not_found)

      authority ->
        case Repo.get(RuntimeAttempt, assignment_id) do
          %RuntimeAttempt{} = attempt ->
            reconcile_runtime_attempt(attempt, claim, authority)

          nil ->
            create_runtime_attempt(authority, claim, opts)
        end
    end
  end

  defp runtime_attempt_authority(assignment_id) do
    Repo.one(
      from(a in Assignment,
        join: w in Wave,
        on: w.id == a.cycle_wave_id and w.workspace_id == a.workspace_id,
        join: b in AssignmentTask,
        on: b.assignment_id == a.id,
        join: t in Document,
        on:
          t.id == b.task_id and t.type == "task" and t.workspace_id == a.workspace_id and
            t.project_id == w.project_id,
        join: d in Dataset,
        on: d.id == t.dataset_id and d.project_id == w.project_id,
        where: a.id == ^assignment_id,
        lock: "FOR UPDATE",
        select: %{
          assignment_id: a.id,
          task_id: t.id,
          task_doc_id: t.doc_id,
          workspace_id: a.workspace_id,
          project_id: w.project_id,
          dataset_id: d.id,
          task_content: t.content
        }
      )
    )
  end

  defp create_runtime_attempt(authority, claim, opts) do
    if claim.task_id != authority.task_id do
      Repo.rollback(:runtime_attempt_task_mismatch)
    end

    expected =
      claim
      |> Map.merge(Map.take(authority, [:workspace_id, :project_id, :dataset_id]))
      |> Map.put(:doc_id, authority.task_doc_id)

    with {:ok, fence} <- Tasks.verify_claim_fence(authority.task_id, expected),
         {:ok, session} <- create_attempt_session(authority, opts) do
      now = DateTime.utc_now()

      attrs = %{
        assignment_id: authority.assignment_id,
        task_id: authority.task_id,
        session_id: session.id,
        task_worker_id: fence.task_worker_id,
        task_epoch: fence.task_epoch,
        task_work_digest: fence.task_work_digest,
        provider: "codex",
        execution_target: "managed",
        inserted_at: now
      }

      {inserted, _} = Repo.insert_all(RuntimeAttempt, [attrs], on_conflict: :nothing)
      attempt = Repo.get(RuntimeAttempt, authority.assignment_id)

      cond do
        inserted == 1 -> attempt
        is_nil(attempt) -> Repo.rollback(:runtime_attempt_conflict)
        true -> reconcile_runtime_attempt(attempt, claim, authority)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reconcile_runtime_attempt(%RuntimeAttempt{} = attempt, claim, authority) do
    case verify_runtime_attempt_claim(attempt, claim, authority) do
      {:ok, _fence} -> attempt
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp verify_runtime_attempt_claim(attempt, claim, authority) do
    cond do
      attempt.task_id != claim.task_id ->
        {:error, :runtime_attempt_conflict}

      attempt.task_worker_id != claim.worker_id ->
        {:error, :foreign_claim}

      attempt.task_work_digest != claim.work_digest ->
        {:error, :work_digest_mismatch}

      true ->
        Tasks.verify_claim_fence(
          attempt.task_id,
          claim
          |> Map.merge(Map.take(authority, [:workspace_id, :project_id, :dataset_id]))
          |> Map.put(:doc_id, authority.task_doc_id)
        )
    end
  end

  defp create_attempt_session(authority, opts) do
    attrs = %{
      id: Ecto.UUID.generate(),
      provider: "codex",
      execution_target: "managed",
      cwd: value(opts, :cwd, Runtime.cwd("codex")),
      mode: value(opts, :mode, "plan"),
      model: value(opts, :model)
    }

    StudioChat.create_session(attrs, {:workspace, authority.workspace_id})
  end

  defp recorder_opts(session, opts) do
    %{
      session_id: session.id,
      provider: session.provider,
      provider_session_id: session.provider_session_id,
      execution_target: session.execution_target,
      execution_host_id: session.execution_host_id,
      workspace_id: session.owner_workspace_id,
      cwd: session.cwd,
      mode: session.mode || "plan",
      resume: (session.message_count || 0) > 0,
      model: value(opts, :model),
      effort: value(opts, :effort),
      bypass_armed: false
    }
  end

  defp normalize_assignment_task_id(attrs) do
    case value(attrs, :task_id) do
      nil ->
        {:ok, attrs}

      task_id ->
        case cast_assignment_task_id(task_id) do
          {:ok, task_id} -> {:ok, put_attr(attrs, :task_id, task_id)}
          error -> error
        end
    end
  end

  defp cast_assignment_task_id(task_id) do
    case Ecto.UUID.cast(task_id) do
      {:ok, task_id} -> {:ok, task_id}
      :error -> {:error, :assignment_task_authority_not_found}
    end
  end

  defp preserve_assignment_task_binding(assignment, attrs, :created) do
    case value(attrs, :task_id) do
      nil -> {:ok, nil}
      task_id -> bind_assignment_task(assignment, task_id)
    end
  end

  defp preserve_assignment_task_binding(assignment, attrs, :replayed) do
    binding = Repo.get(AssignmentTask, assignment.id)

    case {binding, value(attrs, :task_id)} do
      {nil, nil} -> {:ok, nil}
      {%AssignmentTask{} = binding, nil} -> {:ok, binding}
      {%AssignmentTask{task_id: task_id} = binding, task_id} -> {:ok, binding}
      {_binding, _task_id} -> {:error, :assignment_task_conflict}
    end
  end

  defp unwrap_assignment({:ok, %Assignment{} = assignment}), do: {:ok, assignment}
  defp unwrap_assignment({:error, reason}), do: {:error, reason}

  defp unit_id(unit), do: value(unit, :unit_id)

  defp strict_string_list(value) when is_list(value) do
    if Enum.all?(value, &strict_id?/1),
      do: {:ok, value},
      else: {:error, :invalid_build_unit_ids}
  end

  defp strict_string_list(_value), do: {:error, :invalid_build_unit_ids}
  defp strict_id?(value) when is_binary(value), do: value != "" and value == String.trim(value)
  defp strict_id?(_value), do: false
  defp sorted(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.sort()

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_map, _key, default), do: default

  defp put_attr(map, key, value) do
    map
    |> Map.delete(key)
    |> Map.delete(to_string(key))
    |> Map.put(key, value)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
