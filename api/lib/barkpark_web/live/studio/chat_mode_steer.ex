defmodule BarkparkWeb.Studio.ChatModeSteer do
  @moduledoc """
  The Studio chat tab's live permission-mode switch (task-9ae8a0c89d9209b5).

  `Runtime.steer/3` does not always answer `{:ok, request_id}`. A live managed
  Codex session answers a mode steer `{:error, {:unsupported_steer, _}}`: its
  app-server has no request that changes a running thread's approval policy
  (PR #26293). A session on a registered host can answer an error of its own.
  The tab matched `{:ok, _}` on every answer, so /plan, /autopilot or the mode
  toggle on such a session raised and the chat page crashed.

  `steer/3` turns any answer that is not `{:ok, request_id}` into the line the
  tab shows, and the caller leaves the mode, the pending switch and the saved
  row as they were.
  """

  alias Barkpark.StudioChat.Runtime

  @doc """
  Steer `session` to `mode`. `{:ok, request_id}` when the runtime took the
  switch, else `{:error, line}` with the sentence to show the person.
  """
  @spec steer(String.t(), term(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def steer(provider, session, mode) do
    case Runtime.steer(provider, session, %{mode: mode}) do
      {:ok, request_id} -> {:ok, request_id}
      {:error, {:unsupported_steer, _}} -> {:error, unsupported_line(provider)}
      _ -> {:error, "The permission mode did not change: the session did not take the switch."}
    end
  end

  defp unsupported_line(provider),
    do: "This #{provider_name(provider)} session can't change its permission mode while it runs."

  defp provider_name(provider) when provider in ["codex", :codex], do: "Codex"
  defp provider_name(_provider), do: "Claude"
end
