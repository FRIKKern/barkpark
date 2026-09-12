defmodule BarkparkWeb.ErrorResponse do
  @moduledoc """
  The ONE error-envelope emitter shared by PRE-ROUTER auth plugs AND controllers.

  Every path builds the canonical v1 body

      %{error: %{code, message, hint?, request_id?, details?}}

  through `Barkpark.Content.Errors` — the single owner of the error vocabulary,
  the code-keyed `hint`, and (critically) the `request_id` resolution — then sets
  the HTTP status and `halt/1`s. Halting is a no-op for a controller (its response
  is already sent) but is REQUIRED for a pre-router plug, so ONE call site serves
  both layers.

  Why this exists: the auth/pre-router plugs (`RequireIngestToken`,
  `RequireUserSession`, …) had no `action_fallback`, so each hand-built
  `%{error: %{code, message}}` and DROPPED `request_id` — even though
  `Plug.RequestId` had already stamped it on the conn/Logger metadata. A 401/403
  was therefore impossible to correlate to the logs, at exactly the boundary
  where correlation matters. Routing every emitter through here fixes that and
  retires the ~forked private `error_json`/`enveloped`/`custom`/`parse_error_json`
  copies of the envelope-wrapping + request_id logic.
  """

  import Plug.Conn, only: [put_status: 2, halt: 1]

  alias Barkpark.Content.Errors

  @doc """
  Emit from a `Barkpark.Content.Errors` reason tuple (e.g. `{:error, :not_found}`),
  which supplies the canonical code/message/status. `message_override` swaps the
  human message while keeping the canonical code/status (resource-specific text).
  """
  # @canonical capability:error-response-emit aka:error_json,enveloped,halt_json,parse_error_json doc:docs/api-v1.md
  @spec emit(Plug.Conn.t(), term(), String.t() | nil, String.t() | nil) :: Plug.Conn.t()
  def emit(conn, reason, message_override \\ nil, hint_override \\ nil) do
    reason
    |> Errors.to_envelope(conn)
    |> maybe_override_message(message_override)
    |> maybe_override_hint(hint_override)
    |> write(conn)
  end

  @doc """
  Emit an explicit envelope — the caller owns `code`/`message`/`status` (e.g. an
  auth plug's bespoke "invalid ingest token" message). Still routed through
  `Content.Errors.stamp/2`, so the additive `hint` and the `request_id` are put
  on by the one owner. `status` may be an atom (`:unauthorized`) or integer.

  The optional 6th argument is a ROUTE-DERIVED hint (task-57081836b628df35).
  Without it this function built `%{code, message, status}` (+ `:details`) and
  NEVER a `:hint`, so `Errors.put_hint/1`'s "an arm that spoke for itself wins"
  clause could not match for ANY external emitter — the code-keyed default
  always applied. For a code whose remedy depends on the ROUTE rather than the
  code (`"unauthorized"`: eleven emitters, each wanting a different credential)
  that default can only ever be right for one of them. A plug that knows which
  credential its own route accepts passes it here; everything else keeps the
  (now credential-agnostic) table default. This mirrors `emit/4`'s existing
  `hint_override`, which the reason-tuple path has always had.
  """
  @spec emit_custom(
          Plug.Conn.t(),
          atom() | integer(),
          String.t(),
          String.t(),
          map(),
          String.t() | nil
        ) :: Plug.Conn.t()
  def emit_custom(conn, status, code, message, details \\ %{}, hint \\ nil)
      when is_binary(code) and is_binary(message) and is_map(details) and
             (is_nil(hint) or is_binary(hint)) do
    %{code: code, message: message, status: status}
    |> maybe_put_details(details)
    |> maybe_override_hint(hint)
    |> Errors.stamp(conn)
    |> write(conn)
  end

  defp write(env, conn) do
    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end

  defp maybe_override_message(env, nil), do: env
  defp maybe_override_message(env, message), do: Map.put(env, :message, message)

  # The code-keyed default hint is put on by `Errors.stamp/2`; a caller that
  # knows the SPECIFIC remedy (which tier to mint, which flag to pass) replaces
  # it here so the envelope never names the wrong tier for a denial it did not
  # make (the public-read perspective clamp used to hint "write/admin" while a
  # read-tier token was the actual answer — gyldendal friction 68).
  defp maybe_override_hint(env, nil), do: env
  defp maybe_override_hint(env, hint), do: Map.put(env, :hint, hint)

  defp maybe_put_details(env, details) when details == %{}, do: env
  defp maybe_put_details(env, details), do: Map.put(env, :details, details)
end
