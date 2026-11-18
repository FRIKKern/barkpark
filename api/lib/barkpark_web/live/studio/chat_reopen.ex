defmodule BarkparkWeb.Studio.ChatReopen do
  @moduledoc """
  What a Studio reopen finds still able to answer a session's pending asks
  (charter D22/D28, D11; task-e281a8aab02a0aad). Consulted BEFORE any store
  write, through the same rule as the answer routes,
  `Barkpark.StudioChat.ApprovalAnswer.deliverer/2`:

    * `{:live, runtime_ref}`: a Recorder hands over a running runtime. The tab
      co-views it and the asks stay answerable through that pid.
    * `:held`: something can answer later, not now. A host holds the turn with
      no local Recorder (after a restart), the Recorder does not answer, or its
      runtime is gone. The asks stay pending in the store and on the cards; a
      send brings a Recorder back to deliver them.
    * `:none`: no Recorder and no held turn. Only then does the reopen cancel
      the pending asks (D11).

  Before, a reopen with no local Recorder took that for "no runtime" and
  canceled asks a registered host's run was still blocked on.
  """

  alias Barkpark.StudioChat.{ApprovalAnswer, Runtime}

  @spec runtime(String.t()) :: {:live, term()} | :held | :none
  def runtime(session_id) when is_binary(session_id) do
    case ApprovalAnswer.deliverer(session_id, &Function.identity/1) do
      nil ->
        :none

      {:error, _unavailable} ->
        :held

      deliver ->
        runtime_ref = deliver.()
        if Runtime.alive?(runtime_ref), do: {:live, runtime_ref}, else: :held
    end
  end

  @doc "What an answer on a held card says: nothing is sent, the ask stays pending."
  @spec unavailable_text() :: String.t()
  def unavailable_text,
    do:
      "This ask is still waiting on its run, but this server is not connected to that run yet. " <>
        "Send a message to reconnect, then answer it."
end
