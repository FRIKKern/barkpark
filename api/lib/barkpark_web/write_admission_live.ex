defmodule BarkparkWeb.WriteAdmissionLive do
  @moduledoc """
  The LiveView half of managed-mode refusal (Barkdown D-managed-writers, C083).

  `RefuseWhileHeld` answers mutating HTTP requests on the refused route groups,
  but a LiveView mounted before a hold keeps receiving events over its socket,
  where no plug runs. This `on_mount` hook attaches a `handle_event` hook to the
  admin, ops and scoped-admin live sessions: every event first takes a
  zero-width admission from the coordinator, and while the instance is held the
  event is halted with a flash instead of reaching the view. Mount itself is a
  read and passes. A passthrough unless write admission is enabled.
  """

  import Phoenix.LiveView

  alias Barkpark.ManagedRuntime.WriteAdmission.Door

  @message "This instance is being switched; changes are not accepted until the switch completes."

  def on_mount(:refuse_while_held, _params, _session, socket) do
    if Door.enabled?(),
      do: {:cont, attach_hook(socket, :write_admission, :handle_event, &refuse_while_held/3)},
      else: {:cont, socket}
  end

  defp refuse_while_held(_event, _params, socket) do
    case Door.admit(fn -> :ok end) do
      :ok -> {:cont, socket}
      {:error, {:write_admission, _}} -> {:halt, put_flash(socket, :error, @message)}
    end
  end

  @doc false
  def message, do: @message
end
