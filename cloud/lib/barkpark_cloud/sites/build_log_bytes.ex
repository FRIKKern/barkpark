defmodule BarkparkCloud.Sites.BuildLogBytes do
  @moduledoc """
  deploy-reliability `dr-bl-recorder-http-read-path` c1 — the operator read path
  for the recorded build log's BYTES, addressed by DEPLOYMENT ID.

  ## Why this is a SUB-ROUTE and not a field on the record route

  `Sites.BuildLog` (#16847) serves the STRUCTURED record at
  `GET /v1/sites/:id/deployments/:dep_id/build-log`, and its three answers — 404
  no-such-deployment / 410 evicted / 200 with an honest `log_state` — are a
  published contract with a test that asserts those three statuses are pairwise
  distinct. Serving bytes needs an answer that contract has no room for: a
  REFUSAL for a log that exists, is not evicted, and still may not be shown
  because its bytes were never folded through the secret scrubber.

  Bolting that onto the record route would mean an existing caller's 200 could
  become a 422 the day a record turns out to be unstamped. So the bytes get
  `…/build-log/bytes`, and the record route is untouched — byte-identical for
  every caller it already has. The sub-route INHERITS the shapes it shares (404
  and 410 mean exactly what they mean next door) and adds exactly one status of
  its own.

  ## The answers

    * **404 `not_found`** — no such deployment, or not this site's. Existence-leak
      parity with the record route and with `GET /v1/sites/:id/deployments/:dep_id`.
    * **410 `build_log_evicted`** — a tombstone says retention took the bytes.
      `evicted_at` names when. Retrying is pointless.
    * **422 `build_log_unscrubbed`** — THE REFUSAL, and the reason this row is a
      separate slice. The box's record carries `log_scrub`: the pattern-set
      version its bytes were folded with, or `nil` for NEVER FOLDED. Unfolded
      bytes may carry a plaintext `BARKPARK_TOKEN=` (the build env file has one),
      so they are withheld. This is a REFUSAL, not an absence: the operator is
      told the bytes exist and why they are not shown, which is a different fact
      from "there is no log" and must not collapse into it.
    * **200** — a definite answer about the bytes. `log_state` `available` with a
      bounded `tail`, or `missing` / `never_recorded` with a null one. Same
      doctrine as the record route: a complete answer is a 200 even when the
      content is "there are none".
    * **409 `box_unbound`** / **502 `box_unreachable`** — inherited verbatim from
      the record route. One is a control-plane fact, the other a network verdict,
      and neither is a claim about bytes.

  ## AN OLD BOX IS NOT AN EMPTY LOG

  A box that predates the `bytes=1` flag ignores it and answers the RECORD — a
  200 with `log_state: "available"` and no `tail` key at all. Read carelessly that
  is "available, zero bytes", which is a lie about a log that is sitting on the
  box. So an `available` answer with no binary `tail` is `502 box_unreachable`
  ("a shape this control plane does not understand"), the same fail-closed move
  `Sites.BuildLog.decide/2` makes for an unrecognised `log_state`.

  And the `log_scrub` check is made HERE TOO, not inherited: a 200 claiming
  `available` bytes with a null `log_scrub` is refused 422 on this end even
  though the box should already have refused it. An invariant held somewhere
  else is exactly what a byte door must not rely on.

  ## Not SSE-broadcast, and operator-gated

  Pull-only, one deployment per request, behind `Auth.require_platform_operator/2`
  — which is 403-dark in production today (`gr-ops-platform-admin-emails`). The
  audience of a fan-out channel is everyone subscribed to it, which is never the
  audience a build log is gated to.
  """

  require Logger

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Sites.BoxRelay

  @typedoc "The box's verdict, as `BoxRelay` hands it back."
  @type reply :: {:ok, non_neg_integer(), map()} | {:error, term()}

  @typedoc "`{http_status, json_body}` — what the router puts on the wire."
  @type wire :: {non_neg_integer(), map()}

  # THE EXPLICIT FIELD LIST. The box's answer is a decoded JSON map from a REMOTE
  # process and this route serves BYTES, so a pass-through here is the worst
  # possible place for one: the day the box grows a field, this must not start
  # relaying it. Everything not named is dropped.
  @bytes_keys ~w(
    slug build_id record log_state log_scrub log_path log_bytes
    tail_bytes truncated tail evicted_at
  )

  # Defence in depth, not inheritance: the box caps its own tail. A box running
  # older or newer code is precisely the case where this end's cap matters, and a
  # relay that will forward whatever arrives has no cap at all.
  @max_tail_bytes 262_144
  @truncation_marker "\n…[truncated by the control plane at #{@max_tail_bytes} bytes]"

  @doc """
  The field allowlist, exposed so `BuildLogBytesProducerLockTest` can compare it
  against the api's real emitter instead of against a second hand-typed copy.
  """
  @spec __bytes_keys__() :: [String.t()]
  def __bytes_keys__, do: Enum.sort(@bytes_keys)

  @doc """
  Resolve `{site_id, deployment_id}` to the wire answer.

  Site scoping is not decoration: `dep_id` alone would let an operator read any
  deployment through any site's URL, which makes an audit line about
  `/v1/sites/<a>/…` a lie about which site was read. A deployment that is not
  this site's is the same 404 as one that does not exist.
  """
  @spec for_deployment(String.t() | nil, String.t() | nil) :: wire()
  def for_deployment(site_id, deployment_id)
      when is_binary(site_id) and is_binary(deployment_id) do
    with %Registry.Site{} = site <- Registry.get_site(site_id),
         %Registry.Deployment{site_id: sid} = deployment when sid == site.id <-
           Registry.get_deployment(deployment_id) do
      read(site, deployment)
    else
      _ -> not_found()
    end
  end

  def for_deployment(_site_id, _deployment_id), do: not_found()

  defp not_found, do: {404, %{error: "not_found"}}

  defp read(site, %Registry.Deployment{build_id: build_id} = deployment)
       when is_binary(build_id) and build_id != "" do
    case Registry.get_barkpark(site.barkpark_id) do
      nil ->
        unbound(deployment.id, build_id)

      bp ->
        bp
        |> BoxRelay.build_log_bytes(site.slug, build_id)
        |> wire(deployment.id, build_id)
    end
  end

  defp read(_site, deployment), do: unkeyed(deployment.id)

  @doc """
  Map the box's reply onto `{status, body}`. `deployment_id` and `build_id` ride
  EVERY answer, refusals included, so a caller holding a pile of responses can
  always say which deployment each one is about.
  """
  @spec wire(reply(), String.t(), String.t() | nil) :: wire()
  def wire(reply, deployment_id, build_id) do
    base = %{deployment_id: deployment_id, build_id: build_id}

    case reply do
      {:ok, 200, body} when is_map(body) ->
        decide(body, base)

      # The box's OWN refusal, relayed with its own status rather than
      # reinterpreted. 422 out of the box means one thing and it is this.
      {:ok, 422, body} when is_map(body) ->
        {422,
         base
         |> Map.merge(%{error: "build_log_unscrubbed", available: false})
         |> Map.merge(record(body))}

      {:ok, 410, body} when is_map(body) ->
        {410,
         base
         |> Map.merge(%{error: "build_log_evicted", available: false})
         |> Map.merge(record(body))}

      {:ok, status, body} when is_integer(status) ->
        {502,
         Map.merge(base, %{
           error: "box_unreachable",
           detail: "the box refused the build-log bytes read",
           box_status: status,
           box_error: box_error(body)
         })}

      {:error, reason} ->
        # THE TERM IS LOGGED, NEVER ECHOED — the `transport_reason/1` law pinned
        # by `RouterTransportRedactionTest`. A transport struct can carry a token
        # in a nested field; the operator keeps the whole diagnostic in the log
        # and the wire gets a bounded phrase.
        Logger.error(
          "build log bytes read failed for deployment #{deployment_id}: #{inspect(reason)}"
        )

        {502,
         Map.merge(base, %{
           error: "box_unreachable",
           detail: "could not reach the box that recorded this build",
           reason: relay_reason(reason)
         })}
    end
  end

  @doc "The site has no instance row — there is no box to ask."
  @spec unbound(String.t(), String.t() | nil) :: wire()
  def unbound(deployment_id, build_id) do
    {409,
     %{
       deployment_id: deployment_id,
       build_id: build_id,
       error: "box_unbound",
       available: false,
       detail: "this site is not bound to a live instance, so no box can be asked"
     }}
  end

  @doc """
  A pre-recorder deployment: no `build_id`, so there was never a key to record
  under. Answered WITHOUT calling the box — a slug-only read would hand back some
  OTHER build's bytes, which is the wrong-key bug this row exists to remove.
  """
  @spec unkeyed(String.t()) :: wire()
  def unkeyed(deployment_id) do
    {200,
     %{
       deployment_id: deployment_id,
       build_id: nil,
       log_state: "never_recorded",
       available: false,
       tail: nil,
       truncated: false,
       detail:
         "this deployment carries no build_id (it predates build-keyed recording), so nothing was ever recorded under it"
     }}
  end

  ## ---------------------------------------------------------------------------

  # AN OLD BOX IS NOT AN EMPTY LOG, AND IT IS NOT AN UNSCRUBBED ONE EITHER. The
  # discriminator is the PRESENCE of the `tail` key, not its value: the byte door
  # emits `tail` on every shape it can answer in (null included), and the RECORD
  # door — which is what a box too old for `bytes=1` answers — emits no `tail` and
  # no `log_scrub` at all. Keying on `Map.get/2` would read that missing
  # `log_scrub` as an explicit null and refuse 422 "these bytes were never
  # scrubbed", which is a claim about bytes nobody looked at.
  defp decide(body, base) when is_map(body) do
    if Map.has_key?(body, "tail") do
      decide_bytes(body, base)
    else
      {502,
       Map.merge(base, %{
         error: "box_unreachable",
         detail:
           "the box answered the structured record, not the bytes — it is too old to serve them",
         box_log_state: Map.get(body, "log_state")
       })}
    end
  end

  defp decide_bytes(body, base) do
    case {Map.get(body, "log_state"), Map.get(body, "log_scrub"), Map.get(body, "tail")} do
      # NOT FOLDED — refused on this end too, even though the box should already
      # have refused it with a 422.
      {"available", nil, _tail} ->
        {422,
         base
         |> Map.merge(%{error: "build_log_unscrubbed", available: false})
         |> Map.merge(record(body))
         |> Map.put(:tail, nil)}

      {"available", _scrub, tail} when is_binary(tail) ->
        {200,
         base
         |> Map.put(:available, true)
         |> Map.merge(record(body))}

      # `available`, the `tail` key present and NULL, and a log_scrub. The bytes
      # are on the box and the box sent none: not an empty log, not a refusal —
      # an answer this end cannot report on. Fail closed.
      {"available", _scrub, _tail} ->
        {502,
         Map.merge(base, %{
           error: "box_unreachable",
           detail: "the box answered available but sent no bytes",
           box_log_state: "available"
         })}

      {"evicted", _scrub, _tail} ->
        {410,
         base
         |> Map.merge(%{error: "build_log_evicted", available: false})
         |> Map.merge(record(body))}

      {state, _scrub, _tail} when state in ["missing", "never_recorded"] ->
        {200,
         base
         |> Map.put(:available, false)
         |> Map.merge(record(body))}

      {other, _scrub, _tail} ->
        {502,
         Map.merge(base, %{
           error: "box_unreachable",
           detail: "the box answered with a log_state this control plane does not understand",
           box_log_state: other
         })}
    end
  end

  defp record(body) do
    @bytes_keys
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.fetch(body, key) do
        {:ok, value} -> Map.put(acc, String.to_atom(key), value)
        :error -> acc
      end
    end)
    |> cap_tail()
  end

  # Truncation is VISIBLE, never silent — a caller that sees the marker knows the
  # bytes were longer. `tail_bytes` is re-measured off what actually goes on the
  # wire, so it can never describe a longer binary than the one it ships with.
  defp cap_tail(%{tail: tail} = rendered) when is_binary(tail) do
    capped =
      if byte_size(tail) > @max_tail_bytes do
        binary_part(tail, 0, @max_tail_bytes) <> @truncation_marker
      else
        tail
      end

    rendered
    |> Map.put(:tail, capped)
    |> Map.put(:tail_bytes, byte_size(capped))
    |> Map.put(:truncated, Map.get(rendered, :truncated, false) or capped != tail)
  end

  defp cap_tail(rendered), do: rendered

  # A CLOSED vocabulary, fail-closed on the bare `_`.
  defp relay_reason(:not_live), do: "the box that recorded this build is not live"

  defp relay_reason(:no_admin_token),
    do: "this control plane holds no admin credential for that box"

  defp relay_reason(:identity_refused),
    do: "the box refused this control plane's stored admin credential"

  defp relay_reason(:decrypt_failed), do: "the stored admin credential could not be decrypted"
  defp relay_reason(_other), do: "the request could not be completed"

  defp box_error(body) when is_map(body), do: Map.get(body, "error") || Map.get(body, "code")
  defp box_error(_), do: nil
end
