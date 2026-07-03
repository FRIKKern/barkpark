defmodule Barkpark.Plugins.Tickets.Handoff do
  @moduledoc """
  The forwardable HANDOFF CARD (Barkpark Tickets, charter Decision 6).

  `card/2` is a PURE builder: given the host base URL and a freshly-minted raw
  ticket key, it returns the 2-minute onboarding artifact an operator forwards
  verbatim — the key shown ONCE, three copy-pasteable `curl` commands (file a
  ticket, list mine, read a thread), and a one-line etiquette note. It is the
  product artifact behind the "mint-to-first-ticket in 2 curl-able minutes" bar,
  and it is golden-tested (`handoff_test.exs`) so the text — and the curls it
  promises — can never silently rot.

  Pure by construction: no DB, no config, no clock. The exact same string comes
  back for the same `(host, raw_key)`, which is what makes the golden test a
  meaningful tripwire.
  """

  @doc """
  Build the handoff card for `raw_key` against the host base URL `host` (e.g.
  `"https://guerrilla.barkpark.cloud"` — no trailing slash). Returns the card as
  a single string ending in a newline.
  """
  @spec card(binary(), binary()) :: binary()
  def card(host, raw_key) when is_binary(host) and is_binary(raw_key) do
    host = String.trim_trailing(host, "/")

    """
    Barkpark ticket key — this key is your identity. Keep it secret.

      #{raw_key}

    1) File a ticket:
       curl -X POST #{host}/v1/tickets \\
         -H 'Authorization: Bearer #{raw_key}' \\
         -H 'Content-Type: application/json' \\
         -d '{"subject":"Short summary","body":"What you need"}'

    2) List your tickets:
       curl #{host}/v1/tickets \\
         -H 'Authorization: Bearer #{raw_key}'

    3) Read a ticket thread:
       curl #{host}/v1/tickets/TICKET_ID \\
         -H 'Authorization: Bearer #{raw_key}'

    Replying to an answered ticket reopens it.
    """
  end
end
