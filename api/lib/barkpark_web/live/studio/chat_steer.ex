defmodule BarkparkWeb.Studio.ChatSteer do
  @moduledoc """
  The Studio chat tab's live permission-mode and model switches
  (task-9ae8a0c89d9209b5, task-5c21baa4f63db9ac).

  `Runtime.steer/3` does not always answer `{:ok, request_id}`. A live managed
  Codex session answers a mode or model steer `{:error, {:unsupported_steer, _}}`:
  its app-server has no request that changes a running thread's approval policy
  or model (PR #26293). A session on a registered host can answer an error of
  its own. The tab matched `{:ok, _}` on a mode steer, so /plan, /autopilot or
  the mode toggle crashed the chat page; it ignored the answer on a model steer,
  so /model saved the choice and said "Model → X." while nothing changed.

  `steer/2` turns any answer that is not `{:ok, request_id}` into the line the
  tab shows, and the caller leaves the selector and the saved row as they were.
  """

  alias Barkpark.StudioChat.Runtime

  @doc """
  Steer the tab's live session (`assigns.session`) with `command`, a
  `%{mode: _}` or `%{model: _}`. `{:ok, request_id}` when the runtime took the
  switch, `{:ok, nil}` when the tab has no live session (nothing to steer),
  else `{:error, line}` with the sentence to show the person.
  """
  @spec steer(map(), %{optional(:mode | :model) => String.t()}) ::
          {:ok, term()} | {:error, String.t()}
  def steer(assigns, command) do
    if assigns[:session], do: steer(assigns.provider, assigns.session, command), else: {:ok, nil}
  end

  defp steer(provider, session, command) do
    what = if Map.has_key?(command, :mode), do: "permission mode", else: "model"

    case Runtime.steer(provider, session, command) do
      {:ok, request_id} ->
        {:ok, request_id}

      {:error, {:unsupported_steer, _}} ->
        {:error,
         "This #{provider_name(provider)} session can't change its #{what} while it runs."}

      _ ->
        {:error, "The #{what} did not change: the session did not take the switch."}
    end
  end

  defp provider_name(provider) when provider in ["codex", :codex], do: "Codex"
  defp provider_name(_provider), do: "Claude"
end
