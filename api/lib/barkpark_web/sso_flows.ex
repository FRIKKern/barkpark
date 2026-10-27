defmodule BarkparkWeb.SsoFlows do
  @moduledoc """
  Ties a started sign-in (`Barkpark.Sso.Flow`) to the browser that started it.

  A start stores the flow on the server under its `state` and adds the state to
  the session's `sso_states` list, which keeps the five newest. A callback
  accepts a state only when this browser's session lists it, then takes the
  flow once. So two starts in one browser both work, and a state works once.
  """
  import Plug.Conn

  alias Barkpark.Sso.Flow

  @max_states 5

  @doc "Store the flow and remember its state in this browser's session."
  @spec start(Plug.Conn.t(), String.t(), String.t(), map()) :: Plug.Conn.t()
  def start(conn, provider, state, attrs \\ %{}) do
    :ok = Flow.put(provider, state, attrs)
    states = [state | List.delete(states(conn), state)] |> Enum.take(@max_states)
    put_session(conn, :sso_states, states)
  end

  @doc """
  Take the flow for a callback's `state`. `legacy` reads a flow a start before
  this change put in the session's single slot; it returns a flow map or nil.
  Errors: `:no_session_state` (the session cookie holds no started sign-in),
  `:state_mismatch` (this browser did not start that state), `:unknown_state`
  (used or unknown) and `:state_expired`.
  """
  @spec take(Plug.Conn.t(), String.t(), term(), (Plug.Conn.t() -> map() | nil)) ::
          {:ok, Plug.Conn.t(), map()} | {:error, atom()}
  def take(conn, provider, state, legacy \\ fn _ -> nil end)

  def take(conn, provider, state, legacy) when is_binary(state) do
    cond do
      state in states(conn) ->
        conn = put_session(conn, :sso_states, List.delete(states(conn), state))

        case Flow.take(provider, state) do
          {:ok, flow} ->
            {:ok, conn,
             %{nonce: flow.nonce, code_verifier: flow.code_verifier, studio: flow.studio}}

          {:error, _} = err ->
            err
        end

      (flow = legacy.(conn)) != nil and flow[:state] == state ->
        {:ok, conn, flow}

      states(conn) == [] and legacy.(conn) == nil ->
        {:error, :no_session_state}

      true ->
        {:error, :state_mismatch}
    end
  end

  def take(_conn, _provider, _state, _legacy), do: {:error, :state_mismatch}

  defp states(conn) do
    case get_session(conn, :sso_states) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
