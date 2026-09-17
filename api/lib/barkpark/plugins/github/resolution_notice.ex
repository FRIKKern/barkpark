defmodule Barkpark.Plugins.Github.ResolutionNotice do
  @moduledoc """
  COMPOSE the answer an outside reporter is owed. Never post it.

  `Github.Acknowledgement` makes the obligation visible — it births the
  `ack_gate` criterion, refuses a `done` close while the reporter is unanswered,
  and censuses the rows still waiting. What it never had was the other half: a
  way to actually PRODUCE the comment the criterion demands. So the criterion
  fires, an operator reads "the outcome is posted as a comment ... and the
  comment URL is recorded here as evidence", and then writes the comment from
  scratch, by hand, from memory, in a text box on github.com. That is the step
  that did not happen eleven times.

  ## The concrete case this exists for

  Issue #8463 (an outside contributor, opened 2026-07-31) reported that Studio
  could not browse consumer-registered document types. PR #8471 merged
  2026-08-02 as `eb23ef9544` and auto-deployed. The issue was then CLOSED on
  2026-08-24 carrying exactly ONE comment: the bridge bot's 2026-07-31 promise
  that "Updates will be posted here." No update was ever posted. The reporter
  learned nothing — not that it was fixed, not what changed, not that a schema
  which really is a config singleton must now opt in with `singleton: true`.

  Closing the issue made it WORSE, not better: it removed the last visible sign
  that anything was owed.

  **The CODE half is built, live, and is not what is missing.** Re-verified on
  `origin/main` @ 6bf92d057: `Structure.build_generic_types_group/3` is composed into
  `host_main` (`structure.ex`, where it is both composed into the group list and
  defined) and
  `SchemaDefinition` carries `field :singleton, :boolean, default: false`
  (`schema_definition.ex:36`). The arities and line numbers have DRIFTED from the
  2026-08 report (`/2` at `:806`/`:747` then) while the behaviour has not — so a
  future lane that greps the old signature and finds nothing must not conclude the
  fix was reverted, and must not re-open it as unbuilt. What was never done is the
  sentence to the person who reported it.

  ## The line this module does not cross

  **Nothing here posts to GitHub.** `compose/2` returns a STRING. It takes no
  client, opens no connection, and there is no `post/1`. Writing to a named
  stranger's issue is an outward-facing, irreversible act performed by a human
  who has read the words first; this module exists so that human is reviewing a
  draft rather than facing a blank box, and for no other reason.

  ## Why the judgment half is a REQUIRED input, not a TODO placeholder

  A reporter-facing resolution has two halves. The FACTUAL half — which PR,
  which commit, what date — is on the ledger and is composed here. The JUDGMENT
  half — what the new behaviour actually is, and the one thing the reporter must
  now do differently — is not on the ledger and cannot be derived from it.

  An earlier shape emitted a `[TODO: behaviour]` placeholder for the human to
  fill. That is the wrong failure direction: a draft that is syntactically
  complete is a draft that can be pasted unread, and the thing pasted onto a
  stranger's issue would then be the word TODO. So `:behaviour` is a REQUIRED
  option and its absence is an ERROR (`:behaviour_required`). The composer
  refuses to produce a postable artifact until a human has supplied the half
  only a human can write. The output is never almost-right.

  ## Internal identifiers are REFUSED, never stripped

  `Acknowledgement`'s criterion wording carries a law learned the hard way: the
  text lands on the stranger's own issue, so it "must never contain an internal
  aside". Here that law is mechanical. Every composed notice is scanned for
  ledger vocabulary — `task-<hex>` slugs, `gh-<num>` doc ids, dataset names,
  worker handles — and a hit is an ERROR carrying the offending match, not a
  silent redaction.

  Refusing beats scrubbing because a scrubber that mangles a sentence produces a
  notice a human posts without re-reading, while a refusal produces one a human
  has to look at. The failure is loud, addressed to the right audience, and
  costs one retry.
  """

  alias Barkpark.Plugins.Github.Acknowledgement

  # Ledger vocabulary that must never reach a stranger's issue. Each pattern is
  # anchored on a shape the ledger actually mints, not on a word that merely
  # sounds internal — "task" and "dataset" are ordinary English and matching
  # them would refuse every honest notice.
  @internal_patterns [
    # a bp task slug: task-<hex>
    ~r/\btask-[0-9a-f]{8,}\b/,
    # an intake doc id: gh-<num>, optionally draft-prefixed
    ~r/\b(?:drafts\.)?gh-\d+\b/,
    # a lane/worker handle: api-r20c-w10, lead-gates-3, ...
    ~r/\b(?:api|cli|console|deploy|gates|studio|security)-r\d+[a-z]?-w\d+\b/,
    # the ledger host itself
    ~r/\bbarkpark\.cloud\b/i,
    # an internal close vocabulary leak
    ~r/\bacceptance_criteria\b|\back_gate\b|\bclose_reason\b|\blifecycle_status\b/
  ]

  # A shipped reference the reporter can go and read for themselves. A notice
  # naming neither a PR nor a commit is an assertion with nothing behind it,
  # which is the class of answer that reads as a brush-off.
  @pr_pattern ~r/#(\d+)/
  @sha_pattern ~r/\b([0-9a-f]{7,40})\b/

  @typedoc "Everything the composer needs beyond the row itself."
  @type opts :: [
          behaviour: String.t(),
          action_required: String.t() | nil,
          shipped_in: String.t() | nil,
          shipped_at: String.t() | nil
        ]

  @doc """
  Compose the reporter-facing resolution notice for one intake-born task.

  `doc_id` and `content` are the task's own — the SAME pair
  `Acknowledgement.intake_born?/2` checks, and it is checked here for the same
  reason: a notice that says "this is now fixed" is addressed to whoever opened
  the issue this row was born from, and a row that was not born from an issue
  has no such person.

  ## Options

    * `:behaviour` (REQUIRED) — one or more sentences stating what the software
      does now. Written by a human; see the moduledoc on why its absence is an
      error rather than a placeholder.
    * `:action_required` — the one thing the reporter must do differently, if
      anything. Omitted when nothing is required of them.
    * `:shipped_in` — free text naming the change, e.g.
      `"PR #8471, commit eb23ef9544"`. PR numbers and commit shas are extracted
      from it so the notice names at least one; a `:shipped_in` naming neither
      is refused as `:no_shipped_ref`.
    * `:shipped_at` — the merge/deploy date as the reporter should read it.

  ## Returns

    * `{:ok, text}` — a complete notice, safe to hand a human to review
    * `{:error, :not_intake_born}` — this row has no outside reporter
    * `{:error, :behaviour_required}` — the judgment half is missing
    * `{:error, :no_shipped_ref}` — nothing the reporter can go and read
    * `{:error, {:internal_identifier, match}}` — ledger vocabulary in the text

  It performs NO network call and returns a string. There is no `post/1`.
  """
  # @canonical capability:github-reporter-resolution-notice aka:resolution-comment,reporter-answer,ack-draft doc:docs/cards/plugins.md
  @spec compose(String.t() | nil, map() | nil, opts()) ::
          {:ok, String.t()} | {:error, atom() | {:internal_identifier, String.t()}}
  def compose(doc_id, content, opts \\ []) do
    with :ok <- check_intake_born(doc_id, content),
         {:ok, behaviour} <- required_text(opts, :behaviour, :behaviour_required),
         {:ok, shipped_in} <- shipped_reference(opts),
         text = render(content, behaviour, shipped_in, opts),
         :ok <- check_no_internal_identifier(text) do
      {:ok, text}
    end
  end

  defp check_intake_born(doc_id, content) do
    if Acknowledgement.intake_born?(doc_id, content),
      do: :ok,
      else: {:error, :not_intake_born}
  end

  defp required_text(opts, key, error) do
    case opts |> Keyword.get(key) |> normalize() do
      nil -> {:error, error}
      text -> {:ok, text}
    end
  end

  # A shipped reference must NAME something: a PR number or a commit sha. The
  # free text is kept verbatim (a human wrote it and it reads better than
  # anything reassembled from the captures); the extraction exists only to prove
  # that at least one checkable reference is in there.
  defp shipped_reference(opts) do
    case opts |> Keyword.get(:shipped_in) |> normalize() do
      nil ->
        {:error, :no_shipped_ref}

      text ->
        if Regex.match?(@pr_pattern, text) or Regex.match?(@sha_pattern, text),
          do: {:ok, text},
          else: {:error, :no_shipped_ref}
    end
  end

  defp render(content, behaviour, shipped_in, opts) do
    action = opts |> Keyword.get(:action_required) |> normalize()
    at = opts |> Keyword.get(:shipped_at) |> normalize()

    shipped_line =
      case at do
        nil -> "Shipped in #{shipped_in}."
        at -> "Shipped in #{shipped_in}, merged #{at}."
      end

    [
      "This is fixed, and it shipped some time ago — apologies that nobody said so here.",
      "",
      behaviour,
      action && "",
      action,
      "",
      shipped_line,
      "",
      "Issue ##{Acknowledgement.issue_number(content)}. Thank you for the report."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  # The scan runs over the FINAL rendered text, not over each option, because
  # the leak that matters is whatever a human would paste — and the renderer
  # itself is as capable of introducing ledger vocabulary as any caller is.
  defp check_no_internal_identifier(text) do
    Enum.reduce_while(@internal_patterns, :ok, fn pattern, :ok ->
      case Regex.run(pattern, text) do
        nil -> {:cont, :ok}
        [match | _] -> {:halt, {:error, {:internal_identifier, match}}}
      end
    end)
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil
end
