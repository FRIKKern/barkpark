defmodule Barkpark.Tasks.Transitions do
  @moduledoc """
  The ONE task lifecycle-status transition-legality table (charter D7).

  Pure — no DB, no aliases, no side effects. A single `legal?/2` predicate
  answers "may a task move from `from` to `to`?" for the seven lifecycle
  statuses. Two enforcement points read it (charter D8/D7): the sanctioned
  `Barkpark.Tasks.Stage` verb (this wave) and, later, the `Content.Writer`
  seam for raw `type=task` lifecycle patches (deferred to the Writer-seam
  slice). One table, no drift.

  ## The graph (charter D7)

      considering ⇄ researching
           │  │          │
           │  └─→ open ←─┘         open → considering | blocked | cancelled
           ↓       ↓               blocked → open | cancelled
       cancelled (discard)         in_progress → blocked | open
                                   done → open        (the false-done reopen
                                   cancelled → open    recipe DEPENDS on done→open)

  ## What is REFUSED (and why)

    * `any → done` — a forged `done` has real teeth: `cascade_unblock_dependents`
      fires on `done` (close.ex). `done` is reached ONLY through the `close`
      primitive, never a user-forgeable patch/stage. (`done → done` is the
      harmless same→same no-op, so it stays legal.)
    * `any → in_progress` — a live claim is minted ONLY by the `claim` primitive
      (epoch fence, durable mutation_event). A patch/stage may never fabricate
      one. (`in_progress → in_progress` is the same→same no-op.)
    * `done | cancelled → considering | researching` — a terminal/discarded task
      does not re-enter thought; it reopens (`→ open`) or stays put.
    * every pair not in the legal set below.

  ## same → same

  A no-op (`from == to`) is always legal for every status — re-stating a state
  is never illegal. This is the one clause that keeps `done → done` /
  `in_progress → in_progress` out of the refused sets above.
  """

  @statuses ~w(considering researching open in_progress blocked done cancelled)

  # The legal `{from, to}` pairs where `from != to`, transcribed verbatim from
  # charter D7. Everything NOT in this set (and not a same→same no-op) is illegal.
  @legal_pairs MapSet.new([
                 # thought ⇄ thought
                 {"considering", "researching"},
                 {"researching", "considering"},
                 # thought → promote / discard
                 {"considering", "open"},
                 {"considering", "cancelled"},
                 {"researching", "open"},
                 {"researching", "cancelled"},
                 # open re-weigh / block / discard
                 {"open", "considering"},
                 {"open", "blocked"},
                 {"open", "cancelled"},
                 # blocked → unblock / discard
                 {"blocked", "open"},
                 {"blocked", "cancelled"},
                 # in_progress → block / release
                 {"in_progress", "blocked"},
                 {"in_progress", "open"},
                 # terminal → reopen (false-done reopen recipe depends on done→open)
                 {"done", "open"},
                 {"cancelled", "open"}
               ])

  @doc "The seven lifecycle-status values this table governs."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Is the transition `from → to` legal?

  `true` for every pair in the charter D7 legal set and for every same→same
  no-op; `false` for every other pair (including any non-status string on
  either side — an unknown value has no legal outbound or inbound edge).

      iex> Barkpark.Tasks.Transitions.legal?("considering", "researching")
      true
      iex> Barkpark.Tasks.Transitions.legal?("open", "done")
      false
      iex> Barkpark.Tasks.Transitions.legal?("done", "done")
      true
  """
  @spec legal?(String.t(), String.t()) :: boolean()
  def legal?(from, to) when is_binary(from) and is_binary(to) do
    cond do
      # A no-op is never illegal — this is what keeps done→done / in_progress→
      # in_progress legal while `any → done` / `any → in_progress` are refused.
      from == to -> from in @statuses
      true -> MapSet.member?(@legal_pairs, {from, to})
    end
  end

  def legal?(_from, _to), do: false
end
