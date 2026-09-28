defmodule BarkparkWeb.WriteAdmissionController do
  @moduledoc """
  The trusted hold endpoint for a managed instance (Barkdown C083):
  `POST /v1/admin/write-admission/hold` begins or reconciles a hold for an
  operation, `GET .../hold/:capability` reports it, `DELETE .../hold/:capability`
  aborts it (reopen admission, resume queues). Operator-gated like the other
  instance primitives; 503 `feature_not_configured` unless write admission is
  enabled. The hold is owned by `WriteAdmission.Holder`, never by the request.
  """

  use BarkparkWeb, :controller

  alias Barkpark.ManagedRuntime.WriteAdmission.Holder
  alias BarkparkWeb.ErrorResponse

  def hold(conn, %{"operation" => operation}) when is_binary(operation) do
    case Holder.hold(operation) do
      {:ok, %{phase: :held} = view} -> json(conn, view)
      {:ok, view} -> conn |> put_status(:accepted) |> json(view)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def hold(conn, _params) do
    ErrorResponse.emit_fields(conn, :bad_request, %{
      code: "invalid_operation",
      message: "operation is required: a unique identity for the switch this hold serves"
    })
  end

  def instance(conn, _params) do
    case Holder.instance() do
      {:ok, view} -> json(conn, view)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def recover(conn, %{"generation" => generation, "pending" => pending})
      when is_integer(generation) and is_integer(pending) do
    case Holder.recover(generation, pending) do
      {:ok, view} -> json(conn, view)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def recover(conn, _params) do
    ErrorResponse.emit_fields(conn, :bad_request, %{
      code: "invalid_recovery",
      message:
        "recovery names the generation and the pending count it reconciled, both integers read from the instance view"
    })
  end

  def show(conn, %{"capability" => capability}) do
    case Holder.status(capability) do
      {:ok, view} -> json(conn, view)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def reopen(conn, %{"capability" => capability}) do
    case Holder.reopen(capability) do
      {:ok, view} -> json(conn, view)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp refuse(conn, reason)
       when reason in [:write_admission_disabled, :unconfigured, :unavailable] do
    ErrorResponse.emit_fields(conn, :service_unavailable, %{
      code: "feature_not_configured",
      message: "write admission is not enabled on this instance"
    })
  end

  defp refuse(conn, :oban_unavailable) do
    ErrorResponse.emit_fields(conn, :service_unavailable, %{
      code: "storage_unavailable",
      message: "the job queues could not be paused; nothing was held"
    })
  end

  defp refuse(conn, reason)
       when reason in [:admission_closed, :stale_generation, :caller_has_write] do
    ErrorResponse.emit_fields(conn, :conflict, %{
      code: "admission_closed",
      message: "another operation holds this instance, or its generation moved",
      reason: "write_admission_#{reason}"
    })
  end

  defp refuse(conn, reason) when reason in [:not_in_recovery, :unreconciled, :writers_present] do
    ErrorResponse.emit_fields(conn, :conflict, %{
      code: "recovery_refused",
      message:
        "the instance is not in recovery, its pending count moved, or writers are still admitted; read the instance view and retry",
      reason: "write_admission_#{reason}"
    })
  end

  defp refuse(conn, :invalid_operation) do
    ErrorResponse.emit_fields(conn, :bad_request, %{
      code: "invalid_operation",
      message: "operation must be a short identifier"
    })
  end

  defp refuse(conn, :invalid_hold) do
    ErrorResponse.emit_fields(conn, :not_found, %{
      code: "not_found",
      message: "no current hold answers to that capability"
    })
  end
end
