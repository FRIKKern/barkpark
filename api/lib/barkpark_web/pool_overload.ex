defmodule BarkparkWeb.PoolOverload do
  @moduledoc """
  The HTTP status for a request that NEVER RAN because the Repo pool was full.

  ## What this is for (`mob-lm-guerrilla-pool-storm`)

  Observed on guerrilla 2026-07-28 23:00-23:45Z: 110 `DBConnection.ConnectionError`
  entries in two minutes ("connection not available and request was dropped from
  queue"), with three concurrent SSR `next build` processes and a
  `Barkpark.Plugins.Github.MirrorJob` on the box. Externally that surfaced as
  intermittent **500s** on `PATCH /v1/chat/sessions/:id` and
  `GET /v1/chat/sessions?archived=true`, and as a `bp` CLI failure fetching
  `/v1/capabilities`. The cost was not the failure — it was the SHAPE of the
  failure: a drive's own cleanup archive call read the 500 as terminal, gave up,
  and the live session had to be archived by hand.

  `DBConnection.ConnectionError` carries no `Plug.Exception` implementation of its
  own (neither db_connection, postgrex, ecto_sql nor phoenix_ecto ships one), so
  Phoenix's RenderErrors layer fell back to **500 Internal Server Error** for it.
  That is the wrong word for this event in the one way that matters to a caller:
  500 says *the server tried and something is broken*, and a well-behaved client
  does not retry it.

  ## The distinction this module draws

  `DBConnection.ConnectionError` has a `:reason` field (db_connection >= 2.7):

    * `:queue_timeout` — raised by `DBConnection.ConnectionPool`'s `drop/2`. The
      caller sat in the checkout queue past `:queue_target`/`:queue_interval` and
      was dropped. **No connection was ever handed over, so NO statement reached
      Postgres.** The request is side-effect-free by construction, which is what
      makes it safe to retry — this is true of `/v1/data/mutate` exactly as much
      as of a `/v1/chat` read, because the mutation never began. That is
      `503 Service Unavailable`: transient, the server's fault, come back.

    * `:error` (the default) — every other connection fault: a socket that closed
      mid-statement, a killed backend, a client-side `:timeout` on a statement
      that DID run. Those may well have touched the database, and this module
      does NOT relabel them. They stay **500**.

  ## What deliberately does NOT change

  The response BODY. `BarkparkWeb.ErrorJSON` keeps emitting the canonical
  envelope under `code: "internal_error"` with the fault family
  (`DBConnection.ConnectionError`) in the message. The cloud deploy poller
  (`BarkparkCloud.Sites.Deploy.transient_refusal?/1`) grants its retry grace by
  matching that CODE; moving it — even to a "better" one — would turn that grace
  terminal. Only the status moves.

  ## What this is NOT

  It is not capacity. It does not add a connection, shorten a job, or stop the
  pool from being outrun — on a 2-vCPU box with 29 declared Oban queue slots
  sharing `POOL_SIZE` (default 10) with all HTTP traffic, the pool WILL be
  outrun again. Sizing that pool is walled on live measurement
  (`jpf-bl-guerrilla-db-probe-arm` -> `jpf-bl-oban-pool-partition`; charter D75
  / D11). This module makes the shedding HONEST so the next storm costs a retry
  instead of a stranded session.
  """

  @doc """
  The status a `DBConnection.ConnectionError` should render as.

  Split out from the `Plug.Exception` implementation below so it can be asserted
  directly, and so the `:queue_timeout` -> 503 rule has one named home.
  """
  @spec status(DBConnection.ConnectionError.t()) :: 500 | 503
  def status(%DBConnection.ConnectionError{reason: :queue_timeout}), do: 503
  def status(%DBConnection.ConnectionError{}), do: 500
end

defimpl Plug.Exception, for: DBConnection.ConnectionError do
  def status(error), do: BarkparkWeb.PoolOverload.status(error)
  def actions(_error), do: []
end
