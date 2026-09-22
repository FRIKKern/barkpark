defmodule BarkparkCloud.Web.PoolOverload do
  @moduledoc """
  The HTTP status the CONTROL PLANE answers with when a request never ran
  because its Repo pool was full.

  ## Why this exists on the cloud side too (`mob-lm-guerrilla-pool-storm`)

  The api/ half of this row shipped as `BarkparkWeb.PoolOverload` (PR #18610).
  It does not reach here. `cloud/` is a SEPARATE OTP application with its own
  `mix.exs`, its own `deps/`, its own release and its own
  `BarkparkCloud.Repo` — protocol implementations do not cross that line, so
  before this module `grep -rn "defimpl Plug.Exception" cloud/lib` answered
  with nothing while the same grep over `api/lib` answered with four.

  The control plane is exposed to the identical fault and by the identical
  arithmetic: `POOL_SIZE` defaults to 10 (`cloud/config/runtime.exs:23`) and is
  shared between every HTTP door and every Oban queue slot. When the pool is
  outrun, `DBConnection.ConnectionPool` drops queued callers with a
  `DBConnection.ConnectionError`, which ships no `Plug.Exception`
  implementation of its own in any of `db_connection`, `postgrex`, `ecto_sql`
  or `phoenix_ecto`. `Plug.ErrorHandler` therefore fell back to the `Any`
  implementation — **500** — for an event where the server never tried
  anything at all.

  ## The distinction this module draws

  `DBConnection.ConnectionError` carries a `:reason` (db_connection >= 2.7):

    * `:queue_timeout` — built by `DBConnection.ConnectionPool.drop/2`. The
      caller aged out of the CHECKOUT QUEUE, so no connection was ever handed
      over and **no statement reached Postgres**. The request is
      side-effect-free by construction, which is what makes it safe to retry —
      it is as true of a `POST /v1/sites` as of a read. That is
      **503 Service Unavailable**.

    * `:error` (the default) — every other connection fault: a socket closed
      mid-statement, a killed backend, a client-side timeout on a statement
      that DID run. Those may have touched the database. They stay **500**.

  ## What deliberately does NOT change

  The BODY. `BarkparkCloud.Web.Router.handle_errors/2` keeps emitting the flat
  `%{error: "server_error", request_id: …}` envelope for any status >= 500, and
  `server_error` is the slug the console SPA's `friendly()` map is written
  against. Introducing a new slug here would send the console down its
  caller-fallback copy — the exact defect cch-w30-s5 fixed. Only the STATUS
  moves; `cloud/priv/static/app.js` is untouched.

  ## What this is NOT

  It is not capacity. Sizing the pool is live-measurement work walled at
  `jpf-bl-guerrilla-db-probe-arm` -> `jpf-bl-oban-pool-partition`. This module
  only makes the shedding HONEST, so the next storm costs a caller one retry
  instead of an opaque "the server is broken".
  """

  @doc """
  The status a `DBConnection.ConnectionError` should render as.

  Split out from the `Plug.Exception` implementation so the rule can be
  asserted directly and has exactly one home.
  """
  @spec status(DBConnection.ConnectionError.t()) :: 500 | 503
  def status(%DBConnection.ConnectionError{reason: :queue_timeout}), do: 503
  def status(%DBConnection.ConnectionError{}), do: 500
end

defimpl Plug.Exception, for: DBConnection.ConnectionError do
  def status(error), do: BarkparkCloud.Web.PoolOverload.status(error)
  def actions(_error), do: []
end
