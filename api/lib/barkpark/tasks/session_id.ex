defmodule Barkpark.Tasks.SessionId do
  @moduledoc """
  The SESSION discriminator on a task claim — the field that tells two
  concurrent sessions of ONE lane apart (task-f79e39f4992749a5).

  ## The gap this closes

  A worker id is LANE-scoped. Every session of the cli lane writes as
  `lead-cli`, so a claim, a pulse, a stamp and a close made by a predecessor
  that woke on an inbox message are BYTE-INDISTINGUISHABLE from the live
  lead's. `Tasks.Internal.caller_stamp/1` does not help: every session on the
  box authenticates with the same admin token, so `caller_token_id` is
  constant across sessions, and on the claim path it was only ever event
  metadata — never reachable from `bp task get`.

  ## What is stored, and why it is not forgeable from the stored row

  The client presents a SECRET session key (`x-barkpark-session`, or the
  `session_key` param). The server never stores it. What lands on the row is

      claim.session         # HMAC-SHA256(secret_key_base, token_id <> 0 <> key), 16 hex chars, "s_"-prefixed
      claim.session_origin  # the same id, frozen at the ORIGINAL claim

  Three properties follow, and they are the three the criterion asks for:

    1. SERVER-STORED AND QUERYABLE. It is a field of `content.claim`, so it
       rides `bp task get` and the tasks query surface with no reader edit —
       not a naming convention, not a doc, not an agent instruction.
    2. STABLE PER SESSION. The same key always derives the same id, so one
       identity read twice returns the same set. Distinct keys derive distinct
       ids, so two sessions of one lane are separable by the row ALONE.
    3. NOT REPLAYABLE FROM THE ROW. `derive/2` is one-way and salted with a
       server secret. A second session that reads `claim.session` off a row
       and presents it as its own key derives `HMAC(stored)`, which is NOT
       `stored` — it lands under a DIFFERENT id and is reported as a
       different session. Forging a peer's id requires its secret key, i.e.
       exactly the trust boundary the bearer token already draws. The known
       limit, stated rather than assumed: two sessions that choose the SAME
       key collide, which is why the CLI's default key is per-session
       ENTROPY persisted on first use and never a label like `lead-cli-10`.

  ## It is attribution, NEVER a fence

  The CAS is unchanged, byte for byte. The epoch fence stays `worker + epoch`:
  `close/3`, `pulse/3` and `do_renew/3` compare exactly what they compared
  before, and a write presenting a different session (or none) is neither
  refused nor downgraded. The session only RECORDS who wrote. A reader
  (`scripts/ledger/claim-health.sh`) turns `session != session_origin` into a
  reported collision; the ledger itself never gates on it. Making it a fence
  would orphan every live claim taken before this shipped — see
  `session_stamp/1`, which emits NO key for a sessionless caller so those rows
  and every existing test stay byte-identical.
  """

  @prefix "s_"
  @hex_len 16

  @doc """
  Derive the stored session id from a client-presented secret key.

  Returns `nil` for an absent or blank key — a sessionless caller, which is
  every pre-existing client and stays fully supported.
  """
  @spec derive(term(), term()) :: String.t() | nil
  def derive(key, token_id) when is_binary(key) do
    case String.trim(key) do
      "" ->
        nil

      trimmed ->
        digest =
          :crypto.mac(:hmac, :sha256, secret(), [to_salt(token_id), <<0>>, trimmed])
          |> Base.encode16(case: :lower)
          |> binary_part(0, @hex_len)

        @prefix <> digest
    end
  end

  def derive(_key, _token_id), do: nil

  @doc """
  An `extra_document`-shaped fragment naming the session, or `%{}` when there
  is none. Merges into a claim map or a mutation event's `document` map.
  """
  @spec session_stamp(term()) :: map()
  def session_stamp(session) when is_binary(session), do: %{"session" => session}
  def session_stamp(_), do: %{}

  @doc "Put `session` on a claim map, leaving it byte-identical when there is none."
  @spec put_session(map(), term()) :: map()
  def put_session(claim, session) when is_map(claim) and is_binary(session),
    do: Map.put(claim, "session", session)

  def put_session(claim, _session) when is_map(claim), do: claim

  @doc """
  Put both `session` and `session_origin` — the ORIGINAL claim's writer.

  `session_origin` is written once, by the claim that created the lease, and
  is never rewritten by a renew, a pulse or a close. That is what lets a
  reader say "a different session of this lane touched a row this session
  claimed" from the stored row alone.
  """
  @spec put_session_origin(map(), term()) :: map()
  def put_session_origin(claim, session) when is_map(claim) and is_binary(session),
    do: claim |> Map.put("session", session) |> Map.put("session_origin", session)

  def put_session_origin(claim, _session) when is_map(claim), do: claim

  defp to_salt(token_id) when is_binary(token_id), do: token_id
  defp to_salt(_), do: ""

  defp secret do
    case Application.get_env(:barkpark, BarkparkWeb.Endpoint)[:secret_key_base] do
      s when is_binary(s) and byte_size(s) > 0 -> s
      _ -> "barkpark-tasks-session-id-fallback-salt"
    end
  end
end
