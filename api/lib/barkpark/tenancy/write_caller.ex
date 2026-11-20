defmodule Barkpark.Tenancy.WriteCaller do
  @moduledoc """
  What a request's caller may write, as plain facts the web layer hands to a
  feature's write gate, so the gate judges without naming an auth module.

    * `home` — the workspace the caller is pinned to, or nil;
    * `may_write?` — whether the caller's own permission includes writing at
      all, in any workspace;
    * `operator?` — whether the caller is an instance operator on an ARMED
      allowlist;
    * `may_write_in` — a function of a workspace id answering whether the
      caller may write there under the seat rule.

  Only the `:ingest` pipeline's `BarkparkWeb.Plugs.AssignWriteCaller` builds
  one, around the request's verified token. It lives for the request: it is
  never stored and never put in a job's args.
  """

  @enforce_keys [:home, :may_write?, :operator?, :may_write_in]
  defstruct [:home, :may_write?, :operator?, :may_write_in]

  @type t :: %__MODULE__{
          home: binary() | nil,
          may_write?: boolean(),
          operator?: boolean(),
          may_write_in: (binary() -> boolean())
        }
end
