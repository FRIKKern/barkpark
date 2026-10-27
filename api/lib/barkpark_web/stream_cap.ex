defmodule BarkparkWeb.StreamCap do
  @moduledoc """
  The cap on long-lived streams of one kind (live.events, listen;
  task-7a9e8f31be8b7580), counted in `Barkpark.Realtime.LiveStreams`:

    * at most `per_address` open streams per credential from one client
      address (`Barkpark.RateLimiter.client_ip/1`, which reads our own proxy's
      `x-forwarded-for`), default 20;
    * at most `per_credential` per credential from all addresses together,
      default 100.

  A credential is a token, or a user for a member session. One credential is
  often shared: a studio's server opens one stream per dataset for all its
  editors, seven CI shards on seven runners share one token, and a preview
  site's browser token is in every editor's tab. Counting per address keeps
  those under the cap while one host still cannot open more than
  `per_address`; the per-credential backstop bounds the total.

  The stream registers first and counts second, so two racing opens can never
  both slip under a cap. The registration ends with the stream, which frees
  the slot: it belongs to the connection's process, which outlives the stream
  when the connection stays open for another request. A caller with no
  credential is not counted.
  """

  @streams Barkpark.Realtime.LiveStreams

  @doc """
  Runs `open` (the stream) in a slot of `kind`, or `refuse.(reason)` when the
  credential is at a cap. `caps` is `{per_address, per_credential}`. Both
  functions return the conn.
  """
  @spec run(
          Plug.Conn.t(),
          :live_events | :listen,
          {pos_integer(), pos_integer()},
          (String.t() -> Plug.Conn.t()),
          (-> Plug.Conn.t())
        ) :: Plug.Conn.t()
  def run(conn, kind, {per_address, per_credential}, refuse, open) do
    case principal(conn) do
      nil ->
        open.()

      principal ->
        credential = credential_key(kind, principal)
        address = {kind, principal, Barkpark.RateLimiter.client_ip(conn)}
        keys = [credential, address]
        Enum.each(keys, &Registry.register(@streams, &1, nil))

        over =
          cond do
            open_streams(address) > per_address ->
              "from this address (#{per_address})"

            open_streams(credential) > per_credential ->
              "(#{per_credential})"

            true ->
              nil
          end

        try do
          if over,
            do: refuse.("too many open #{label(kind)} streams for this credential #{over}"),
            else: open.()
        after
          Enum.each(keys, &Registry.unregister(@streams, &1))
        end
    end
  end

  defp open_streams(key), do: length(Registry.lookup(@streams, key))

  defp principal(conn) do
    case conn.assigns do
      %{api_token: %{id: id}} when not is_nil(id) -> {:token, id}
      %{current_user: %{id: id}} when not is_nil(id) -> {:user, id}
      _ -> nil
    end
  end

  # live.events' per-credential key is the bare principal, as before kinds existed.
  defp credential_key(:live_events, principal), do: principal
  defp credential_key(kind, principal), do: {kind, principal}

  defp label(:live_events), do: "live"
  defp label(:listen), do: "listen"
end
