defmodule BarkparkWeb.CycleFleetController do
  @moduledoc "Authenticated local/cloud HTTP authority for Epic and Legendary cycle ledgers."

  use BarkparkWeb, :controller

  alias Barkpark.CycleFleet
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.ErrorResponse

  def show(conn, params) do
    with_scope(conn, params, :read, fn scope ->
      case CycleFleet.projection(scope) do
        {:ok, projection} -> json(conn, decorate_authority(conn, projection))
        {:error, :wave_not_found} -> not_found(conn, "cycle wave not found")
        {:error, reason} -> unprocessable(conn, reason)
      end
    end)
  end

  def open(conn, params) do
    with_scope(conn, params, :write, fn scope ->
      attrs =
        scope
        |> Map.merge(
          select(
            params,
            ~w(profile inventory experiment_contract scale_contract correction_of correction_of_digest)
          )
        )
        |> maybe_decode_json(:inventory, params["inventory_json"])
        |> maybe_decode_json(:experiment_contract, params["experiment_contract_json"])
        |> maybe_decode_json(:scale_contract, params["scale_contract_json"])
        |> maybe_decode_json(:correction_of, params["correction_of_json"])

      case CycleFleet.open_wave(attrs) do
        {:ok, _wave} ->
          {:ok, projection} = CycleFleet.projection(scope)
          conn |> put_status(:created) |> json(decorate_authority(conn, projection))

        {:error, :wave_conflict} ->
          conflict(conn, :wave_conflict)

        {:error, reason} ->
          unprocessable(conn, reason)
      end
    end)
  end

  def seal(conn, params) do
    with_scope(conn, params, :write, fn scope ->
      attrs =
        params
        |> select(
          ~w(proven_batch_capacity chosen_format pilot_evidence pilot_evidence_revision failure_rate failure_threshold)
        )
        |> Map.merge(select(params, ~w(golden_fixtures)))
        |> maybe_decode_json(:golden_fixtures, params["golden_fixtures_json"])
        |> parse_integer("proven_batch_capacity")
        |> parse_float("failure_rate")
        |> parse_float("failure_threshold")

      case CycleFleet.seal_build_plan(scope, attrs) do
        {:ok, _plan} ->
          {:ok, projection} = CycleFleet.projection(scope)
          json(conn, decorate_authority(conn, projection))

        {:error, :wave_not_found} ->
          not_found(conn, "cycle wave not found")

        {:error, :build_plan_conflict} ->
          conflict(conn, :build_plan_conflict)

        {:error, reason} ->
          unprocessable(conn, reason)
      end
    end)
  end

  def create_assignment(conn, params) do
    with_scope(conn, params, :write, fn scope ->
      attrs =
        scope
        |> Map.merge(
          select(
            params,
            ~w(assignment_id phase agent_type effort snapshot task_id replaces_assignment_id)
          )
        )
        |> maybe_decode_json(:snapshot, params["snapshot_json"])

      case CycleFleet.create_assignment(attrs) do
        {:ok, assignment} ->
          conn |> put_status(:created) |> json(%{assignment: assignment_json(assignment)})

        {:error, reason}
        when reason in [
               :assignment_conflict,
               :assignment_task_conflict,
               :assignment_already_replaced,
               :replacement_scope_mismatch,
               :replacement_phase_mismatch,
               :replacement_agent_type_mismatch,
               :replacement_contract_mismatch
             ] ->
          conflict(conn, reason)

        {:error, reason} ->
          unprocessable(conn, reason)
      end
    end)
  end

  def create_result(conn, %{"assignment_id" => assignment_id} = params) do
    with_scope(conn, params, :write, fn scope ->
      case CycleFleet.get_assignment(scope, assignment_id) do
        nil ->
          not_found(conn, "cycle assignment not found")

        assignment ->
          attrs =
            params
            |> select(~w(idempotency_key status summary evidence evidence_revision payload))
            |> maybe_decode_json(:payload, params["payload_json"])

          case CycleFleet.record_result(assignment, attrs) do
            {:ok, result} ->
              conn |> put_status(:created) |> json(%{result: result_json(result)})

            {:error, reason}
            when reason in [
                   :result_conflict,
                   :idempotency_conflict,
                   :terminal_result_conflict
                 ] ->
              conflict(conn, reason)

            {:error, reason} ->
              unprocessable(conn, reason)
          end
      end
    end)
  end

  def quarantine(conn, params) do
    with_scope(conn, params, :write, fn scope ->
      with {:ok, correction_receipt} <-
             required_json_object(params, "correction_receipt", "correction_receipt_json") do
        attrs = %{
          idempotency_key: params["idempotency_key"],
          reason: params["reason"],
          correction_receipt: correction_receipt,
          actor: cycle_actor(conn),
          evidence: params["evidence"],
          evidence_revision: params["evidence_revision"]
        }

        respond_correction_mutation(conn, scope, CycleFleet.quarantine_correction(scope, attrs))
      else
        {:error, reason} -> unprocessable(conn, reason)
      end
    end)
  end

  def promote(conn, params) do
    with_scope(conn, params, :write, fn scope ->
      with {:ok, correction_receipt} <-
             required_json_object(params, "correction_receipt", "correction_receipt_json"),
           {:ok, gate_receipt} <-
             required_json_object(params, "gate_receipt", "gate_receipt_json") do
        attrs = %{
          idempotency_key: params["idempotency_key"],
          previous_event_id: blank_to_nil(params["previous_event_id"]),
          correction_receipt: correction_receipt,
          gate_receipt: gate_receipt,
          actor: cycle_actor(conn),
          evidence: params["evidence"],
          evidence_revision: params["evidence_revision"]
        }

        respond_correction_mutation(conn, scope, CycleFleet.promote_correction(scope, attrs))
      else
        {:error, reason} -> unprocessable(conn, reason)
      end
    end)
  end

  def rollback(conn, params) do
    with_scope(conn, params, :write, fn scope ->
      attrs = %{
        idempotency_key: params["idempotency_key"],
        previous_event_id: params["previous_event_id"],
        restore_event_id: params["restore_event_id"],
        actor: cycle_actor(conn),
        evidence: params["evidence"],
        evidence_revision: params["evidence_revision"]
      }

      respond_correction_mutation(conn, scope, CycleFleet.rollback_correction(scope, attrs))
    end)
  end

  defp with_scope(conn, %{"epic_id" => epic_id, "wave_id" => wave_id} = params, action, fun) do
    case conn.assigns[:current_workspace] do
      %{id: workspace_id} ->
        case authorize_cycle(conn.assigns[:api_token], workspace_id, action) do
          :ok ->
            project_id =
              case {params["project_slug"], conn.assigns[:current_project]} do
                {slug, %{id: id}} when is_binary(slug) -> id
                _ -> nil
              end

            fun.(%{
              workspace_id: workspace_id,
              project_id: project_id,
              epic_id: epic_id,
              wave_id: wave_id
            })

          {:error, :forbidden} ->
            forbidden(conn)
        end

      _ ->
        unprocessable(conn, :workspace_scope_required)
    end
  end

  defp authorize_cycle(%{permissions: ["public-read"]}, _workspace_id, :read),
    do: {:error, :forbidden}

  defp authorize_cycle(token, workspace_id, action),
    do: TenancyAuth.authorize(token, workspace_id, action)

  defp select(params, keys), do: Map.take(params, keys)

  defp maybe_decode_json(attrs, _key, nil), do: attrs

  defp maybe_decode_json(attrs, key, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> Map.put(attrs, Atom.to_string(key), decoded)
      {:error, _} -> Map.put(attrs, Atom.to_string(key), value)
    end
  end

  defp maybe_decode_json(attrs, _key, _value), do: attrs

  defp required_json_object(params, direct_key, encoded_key) do
    case {params[direct_key], params[encoded_key]} do
      {%{} = object, nil} ->
        {:ok, object}

      {nil, encoded} when is_binary(encoded) ->
        case Jason.decode(encoded) do
          {:ok, %{} = object} -> {:ok, object}
          _ -> {:error, receipt_error(direct_key, :invalid)}
        end

      {nil, nil} ->
        {:error, receipt_error(direct_key, :required)}

      _ ->
        {:error, receipt_error(direct_key, :ambiguous)}
    end
  end

  defp receipt_error("correction_receipt", :invalid), do: :invalid_correction_receipt
  defp receipt_error("correction_receipt", :required), do: :correction_receipt_required
  defp receipt_error("correction_receipt", :ambiguous), do: :ambiguous_correction_receipt
  defp receipt_error("gate_receipt", :invalid), do: :invalid_gate_receipt
  defp receipt_error("gate_receipt", :required), do: :gate_receipt_required
  defp receipt_error("gate_receipt", :ambiguous), do: :ambiguous_gate_receipt

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp cycle_actor(conn) do
    token = conn.assigns[:api_token]
    %{"type" => "api_token", "id" => token.id}
  end

  defp respond_correction_mutation(conn, scope, {:ok, _event}) do
    case CycleFleet.projection(scope) do
      {:ok, projection} -> json(conn, decorate_authority(conn, projection))
      {:error, :wave_not_found} -> not_found(conn, "cycle wave not found")
      {:error, reason} -> unprocessable(conn, reason)
    end
  end

  defp respond_correction_mutation(conn, _scope, {:error, :wave_not_found}),
    do: not_found(conn, "cycle wave not found")

  defp respond_correction_mutation(conn, _scope, {:error, reason})
       when reason in [
              :quarantine_conflict,
              :stale_promotion_head,
              :promotion_conflict,
              :already_current,
              :current_wave_requires_rollback,
              :idempotency_conflict
            ],
       do: conflict(conn, reason)

  defp respond_correction_mutation(conn, _scope, {:error, reason}),
    do: unprocessable(conn, reason)

  defp parse_integer(attrs, key) do
    case attrs[key] do
      value when is_integer(value) ->
        attrs

      value when is_binary(value) ->
        parse_integer_string(attrs, key, value)

      _ ->
        attrs
    end
  end

  defp parse_integer_string(attrs, key, value) do
    case Integer.parse(value) do
      {value, ""} -> Map.put(attrs, key, value)
      _ -> attrs
    end
  end

  defp parse_float(attrs, key) do
    case attrs[key] do
      value when is_number(value) ->
        attrs

      value when is_binary(value) ->
        parse_float_string(attrs, key, value)

      _ ->
        attrs
    end
  end

  defp parse_float_string(attrs, key, value) do
    case Float.parse(value) do
      {value, ""} -> Map.put(attrs, key, value)
      _ -> attrs
    end
  end

  defp assignment_json(assignment) do
    assignment
    |> Map.take([
      :id,
      :assignment_id,
      :epic_id,
      :wave_id,
      :phase,
      :agent_type,
      :effort,
      :snapshot,
      :snapshot_digest,
      :unit_ids,
      :inventory_digest,
      :cycle_wave_id,
      :replaces_assignment_id,
      :inserted_at
    ])
    |> Map.put(:cycle_assignment_id, assignment.id)
  end

  defp result_json(result) do
    Map.take(result, [
      :id,
      :assignment_id,
      :idempotency_key,
      :status,
      :summary,
      :evidence,
      :evidence_revision,
      :payload,
      :payload_digest,
      :inserted_at
    ])
  end

  defp decorate_authority(_conn, projection) do
    authority = projection.authority
    workspace = Tenancy.get_workspace_by_id(authority.workspace_id)
    project = Tenancy.get_project_by_id(authority.project_id)
    origin = Application.get_env(:barkpark, :capabilities_base_url, "http://localhost:4000")
    server_uri = URI.parse(origin)

    execution_location =
      Application.get_env(:barkpark, :cycle_fleet_execution_location) ||
        if(server_uri.host in ["localhost", "127.0.0.1", "::1"], do: "local", else: "remote")

    connection = %{
      execution_location: execution_location,
      server_origin: String.trim_trailing(origin, "/"),
      workspace: workspace && %{id: workspace.id, slug: workspace.slug},
      project: project && %{id: project.id, slug: project.slug},
      connected_cloud_url: Application.get_env(:barkpark, :cloud_login_url)
    }

    put_in(projection, [:authority, :connection], connection)
  end

  defp not_found(conn, message), do: ErrorResponse.emit(conn, {:error, :not_found}, message)

  defp forbidden(conn) do
    ErrorResponse.emit(conn, {:error, :forbidden}, "workspace access required")
  end

  defp conflict(conn, reason) do
    ErrorResponse.emit_custom(
      conn,
      :conflict,
      "conflict",
      "immutable cycle ledger conflict",
      %{reason: to_string(reason)}
    )
  end

  defp unprocessable(conn, %Ecto.Changeset{} = changeset),
    do: ErrorResponse.emit(conn, {:error, changeset})

  defp unprocessable(conn, reason) do
    ErrorResponse.emit_custom(
      conn,
      :unprocessable_entity,
      "validation_failed",
      "cycle request failed validation",
      %{reason: inspect(reason)}
    )
  end
end
