defmodule Barkpark.Plugins.Github.Acknowledgement do
  @moduledoc """
  THE REPORTER LOOP — the one obligation an outsider's `gh-<num>` row owes back
  to the person who filed it, made structural instead of remembered.

  An outsider who cannot see this ledger opens an issue in the mirror repo.
  `Intake` births it as `gh-<num>` and posts ONE comment — *"This issue is now
  tracked internally in Barkpark. Updates will be posted here."* From that moment
  the only thing that ever speaks to the reporter again is a human: `bp github
  adopt` posts a backlink, and a maintainer posts the outcome. Nothing else does,
  by design (`Adopt`: adoption "sits until a maintainer decides it is real work").

  ## What was measured, 2026-08-24

  ELEVEN rows satisfied `intake_born?/2` against the live ledger. Cross-checked
  against the GitHub REST API the same day:

    * **8 of 11** source issues carried NO non-bot comment at all. The only thing
      ever said to those reporters is the bridge's own birth backlink, *"Updates
      will be posted here"* — the oldest posted 2026-07-26, 29 days earlier.
    * **5 issues were still OPEN**, every one of them bot-comment-only, while the
      defects they reported had been fixed in this repo.
    * **10 of 11** never received a maintainer reply. `gh-6681` is the single
      closed loop in the bridge's history: one hand-written *"Fixed in #6702"*.
    * **9 of 11** rows carried **zero `acceptance_criteria`**, `gh-11555` among
      them — it closed `done` with a `close_reason` naming its merged PR and an
      empty criteria list, which reads to every audit as fully proven.

  That zero is not a filing lapse. `Intake.build_attrs/4` wrote no
  `acceptance_criteria` key at all, so **every** intake birth landed in that blind
  spot, and the platform's only response — `Plugins.Tasks.warn_if_create_zero/1`
  — is a `Logger.warning` whose sole reader is the server journal. It fired on
  every one of those births and changed nothing.

  ## The three parts, and the one line none of them cross

  This module owns the shared vocabulary for all three:

    1. `criterion/2` — the criterion `Intake` BIRTHS onto every `gh-<num>` row, so
       the obligation is written into the row rather than remembered.
    2. `acknowledged?/1` + `intake_born?/2` — the predicate the close gate in
       `Barkpark.Tasks.Close` uses to REFUSE a `done`/`cancelled` close that
       leaves the reporter with nothing.
    3. `census/2` — the detector `Github.Health` folds into its snapshot, so
       `bp github status` and the `/admin/github` console name the overdue rows.

  **Nothing here posts to GitHub, and nothing here adopts.** The holding pen is
  the feature; a human deciding what is real work is the feature. The only thing
  that changes is that the human is now TOLD the decision is overdue, and cannot
  close the row while pretending it was made.

  ## The flag is the machine signal, never the wording

  The acknowledgement criterion is recognised by `"ack_gate" => true` and by
  nothing else. This is the `merge_gate` lesson taken as law rather than
  rediscovered: `Plugins.Tasks.warn_unflagged_merge_gates/1` records 2870 criteria
  WORDED as merge-gated against 35 carrying the flag, because a text convention
  and a machine flag are two vocabularies that drift the moment both exist. Here
  the flag is minted by `criterion/2` itself on the write path, so wording is free
  to be re-authored, translated or reordered without ever changing what the gate
  reads.

  ## What a ledger-only detector CANNOT see

  `census/2` reads Postgres and NOTHING ELSE — no `Auth`, no `Client`, no
  network, matching the ZERO-GitHub-calls rule `Github.Health` already holds. So
  it can say the criterion is unmet; it CANNOT say whether a comment was posted
  upstream. Those differ exactly when a maintainer posts to the issue and never
  stamps the criterion — the census then over-reports. That direction is the safe
  one (a nag for work already done, versus silence over a reporter still waiting)
  and it is stated here rather than papered over: the stamp IS the record, and a
  comment nobody recorded is, to this ledger, a comment that did not happen.
  """

  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @typedoc "One census row — a `gh-<num>` task whose reporter has not been answered."
  @type census_row :: %{
          doc_id: String.t(),
          issue: integer() | nil,
          repo: String.t() | nil,
          dataset: String.t(),
          state: String.t() | nil,
          lifecycle_status: String.t() | nil,
          criteria_total: non_neg_integer(),
          has_criterion: boolean(),
          created_at: NaiveDateTime.t() | nil
        }

  @typedoc "The unacknowledged census; every field is always present."
  @type census :: %{
          total: non_neg_integer(),
          closed: non_neg_integer(),
          open: non_neg_integer(),
          no_criterion: non_neg_integer(),
          rows: [census_row()]
        }

  # The ONE machine signal. Everything else about the criterion — its wording,
  # its position, its evidence — is human-facing and freely re-authorable.
  @flag "ack_gate"

  # Terminal lifecycle states. A row in one of these has stopped moving, so a
  # reporter still waiting on it is waiting forever — this is the URGENT bucket.
  @closed_lifecycle_statuses ~w(done cancelled blocked)

  # How many census rows to hand a console/CLI caller. The COUNTS are exact
  # (computed over every matched row); only the row list is capped.
  @rows_cap 50

  # ── the criterion Intake births ────────────────────────────────────────────

  @doc """
  The acknowledgement criterion, born unmet onto every `gh-<num>` intake row.

  Every clause names something the reader can go and check — the repo, the issue
  number, and a comment URL they must paste — deliberately NOT a prose judgement,
  which is the class of criterion nothing can ever verify. Same discipline as
  `Intake`'s birth disposition reason, which is built only from facts carried on
  the delivery.

  `repo` may be `nil` (a dark plugin with no configured repo); the wording then
  names the issue number alone rather than fabricating a repo it does not know.
  """
  # @canonical capability:github-reporter-acknowledgement aka:ack_gate,reporter-loop,backlink-obligation,unacknowledged doc:docs/cards/plugins.md
  @spec criterion(String.t() | nil, integer() | String.t()) :: map()
  def criterion(repo, number) do
    where = if is_binary(repo) and repo != "", do: "#{repo}##{number}", else: "issue ##{number}"

    %{
      "criterion" =>
        "ACKNOWLEDGED UPSTREAM: the outcome is posted as a comment on #{where} — the fix " <>
          "with its PR or commit, or the reason this will not be done. Paste the comment URL " <>
          "as evidence. The reporter is OUTSIDE this ledger: the issue is the only surface " <>
          "they can see, and the bridge's birth backlink promised them updates there.",
      "met" => false,
      "evidence" => "",
      @flag => true
    }
  end

  @doc """
  `true` when `content` already carries an acknowledgement criterion (met or not).

  Used by `Intake` so a re-authored row is never handed a second copy, and by the
  census to separate "born before this existed" from "born with it, still unmet".
  """
  @spec has_criterion?(map() | nil) :: boolean()
  def has_criterion?(content), do: content |> criteria_list() |> Enum.any?(&flagged?/1)

  @doc """
  `true` when the reporter has been answered: some acknowledgement criterion on
  the row is stamped `met: true`.

  A row carrying NO acknowledgement criterion is NOT acknowledged — that is the
  whole point. Nine of the eleven rows measured on 2026-08-24 carried zero
  criteria, and an empty list is exactly what let them read as proven.
  """
  @spec acknowledged?(map() | nil) :: boolean()
  def acknowledged?(content) do
    content
    |> criteria_list()
    |> Enum.any?(fn row -> flagged?(row) and Map.get(row, "met") == true end)
  end

  @doc """
  The 0-based indices of every acknowledgement criterion on `content`.

  `Tasks.Close` needs these to DEDUCT the criterion an `ack_override` has already
  answered from the D289 unmet count — `Internal.unmet_criteria/1` returns
  `{index, criterion}` and drops the flag, so the deduction has to be addressed
  by index, from the raw list, here where the flag is defined.
  """
  @spec criterion_indices(map() | nil) :: [non_neg_integer()]
  def criterion_indices(content) do
    content
    |> criteria_list_indexed()
    |> Enum.filter(fn {row, _i} -> flagged?(row) end)
    |> Enum.map(fn {_row, i} -> i end)
  end

  # ── the predicate ──────────────────────────────────────────────────────────

  @doc """
  `true` when this row was BORN from an outsider's GitHub issue.

  The predicate is the birth invariant itself, not a guess about it. `Intake`
  derives BOTH `doc_id = "gh-" <> number` and `content.github.issue = number`
  from the SAME `number` off the webhook, so
  `doc_id == "gh-" <> to_string(content.github.issue)` holds for every intake
  birth and for nothing that arrives any other way. Checking the PAIR rather than
  the id prefix alone is what makes it sound as well as complete:

    * an OUTBOUND mirror keeps its real task slug (`task-<hash>`) and can never
      match — `InboundEvents` states the same structural fact for the inbound
      side ("its doc_id is never `gh-<num>`");
    * the six PRE-BRIDGE rows `gh-1`..`gh-6`, hand-authored 2026-07-11 and later
      mirrored outbound, carry issue numbers 1580 and 2526-2530 against ids 1-6.
      The id prefix alone would sweep all six in; the pair excludes them, because
      no intake ever produced that mismatch.

  Accepts the draft form (`drafts.gh-<num>`) too — an unadopted intake row lives
  as a draft, which is precisely the population this exists to find.
  """
  @spec intake_born?(String.t() | nil, map() | nil) :: boolean()
  def intake_born?(doc_id, content) when is_binary(doc_id) do
    case issue_number(content) do
      nil -> false
      number -> published_id(doc_id) == "gh-" <> to_string(number)
    end
  end

  def intake_born?(_doc_id, _content), do: false

  @doc """
  The GitHub issue number on a task's content, or `nil`.

  String- and atom-key safe, and integer-or-string safe: `Intake` writes the raw
  JSON number, but a hand-repaired row can carry it as a string, and a predicate
  that silently stopped matching on such a row would reopen the exact hole.
  """
  @spec issue_number(map() | nil) :: integer() | nil
  def issue_number(content) when is_map(content) do
    case Map.get(content, "github") || Map.get(content, :github) do
      github when is_map(github) ->
        normalize_number(Map.get(github, "issue") || Map.get(github, :issue))

      _ ->
        nil
    end
  end

  def issue_number(_content), do: nil

  defp normalize_number(n) when is_integer(n), do: n

  defp normalize_number(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_number(_), do: nil

  # ── the detector ───────────────────────────────────────────────────────────

  @doc """
  The unacknowledged census: every intake-born row whose reporter has not been
  answered, bucketed by whether the row has stopped moving.

    * `total` — intake-born rows with no `met` acknowledgement criterion
    * `closed` — of those, rows in a terminal `lifecycle_status` (`done` /
      `cancelled` / `blocked`). A terminal row will never move again on its own,
      so its reporter waits forever: this is the bucket to act on FIRST.
    * `open` — still live; the acknowledgement is pending, not overdue-forever
    * `no_criterion` — born before the criterion existed, so the row carries NO
      record of the obligation at all. These are the audit blind spot in its pure
      form and each one needs the criterion added by hand.
    * `rows` — the oldest-first row list (the longest-waiting reporter leads),
      capped. The COUNTS above are exact over the whole population; only this
      list is capped.

  `dataset` narrows to one dataset (the D18 per-token narrowing `Health` already
  applies); `nil` or blank is the whole fleet.

  Reads Postgres ONLY — no GitHub call, so it is safe from a LiveView `mount/3`
  and works with the plugin dark. See the moduledoc for what that costs.
  """
  @spec census(String.t() | nil, keyword()) :: census()
  def census(dataset \\ nil, opts \\ []) do
    cap = Keyword.get(opts, :cap, @rows_cap)

    rows =
      Document
      |> where([d], d.type == "task")
      |> where([d], like(d.doc_id, "gh-%") or like(d.doc_id, "drafts.gh-%"))
      |> maybe_dataset(dataset)
      |> select([d], %{
        doc_id: d.doc_id,
        dataset: d.dataset,
        content: d.content,
        created_at: d.inserted_at
      })
      |> Repo.all()
      |> dedupe_by_published_id()
      |> Enum.filter(&unacknowledged_intake?/1)
      |> Enum.map(&to_census_row/1)

    %{
      total: length(rows),
      closed: Enum.count(rows, &(&1.lifecycle_status in @closed_lifecycle_statuses)),
      open: Enum.count(rows, &(&1.lifecycle_status not in @closed_lifecycle_statuses)),
      no_criterion: Enum.count(rows, &(not &1.has_criterion)),
      rows: Enum.take(rows, cap)
    }
  end

  # The `LIKE` prefixes narrow the scan to `gh-`/`drafts.gh-` ids in the DATABASE
  # so the census never loads the whole task corpus. They are deliberately LOOSER
  # than the real predicate — `gh-nonsense` survives the prefix — because the
  # decision is made by `intake_born?/2` in Elixir, which is the SINGLE
  # definition both this and the close gate read. Encoding the exact rule in SQL
  # too would give the gate and the census two predicates free to drift, and a
  # prefilter that is looser than the predicate can only ever cost a discarded
  # row, never hide one.
  defp unacknowledged_intake?(%{doc_id: doc_id, content: content}) do
    intake_born?(doc_id, content) and not acknowledged?(content)
  end

  # A task exists as up to TWO physical rows — `gh-9531` and `drafts.gh-9531` —
  # and an unadopted intake typically has both. One waiting reporter must count
  # ONCE. The draft is the write target for an unpublished intake and therefore
  # carries the fresher content, so it wins; the sort then puts the
  # longest-waiting reporter first.
  #
  # THIS RUNS BEFORE THE UNACKNOWLEDGED FILTER, and the order is load-bearing —
  # it was the other way round and a test caught it. Filtering first drops an
  # ACKNOWLEDGED draft out of its own group, leaving its stale published twin to
  # be picked as the group's only survivor: the census would then nag about a
  # reporter who had already been answered. Choose the authoritative row for the
  # task, THEN ask whether that row's reporter is still waiting.
  defp dedupe_by_published_id(rows) do
    rows
    |> Enum.group_by(&published_id(&1.doc_id))
    |> Enum.map(fn {_pid, group} ->
      Enum.max_by(group, fn %{doc_id: id} -> if draft?(id), do: 1, else: 0 end)
    end)
    |> Enum.sort_by(& &1.created_at, NaiveDateTime)
  end

  defp to_census_row(%{doc_id: doc_id, dataset: dataset, content: content, created_at: created}) do
    github = Map.get(content || %{}, "github") || %{}

    %{
      doc_id: published_id(doc_id),
      issue: issue_number(content),
      repo: Map.get(github, "repo"),
      dataset: dataset,
      state: Map.get(github, "state"),
      lifecycle_status: Map.get(content || %{}, "lifecycle_status"),
      criteria_total: length(criteria_list(content)),
      has_criterion: has_criterion?(content),
      created_at: created
    }
  end

  defp maybe_dataset(query, dataset) when is_binary(dataset) do
    case String.trim(dataset) do
      "" -> query
      trimmed -> where(query, [d], d.dataset == ^trimmed)
    end
  end

  defp maybe_dataset(query, _dataset), do: query

  # ── shared shape helpers ───────────────────────────────────────────────────

  defp criteria_list(content) when is_map(content) do
    case Map.get(content, "acceptance_criteria") || Map.get(content, :acceptance_criteria) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  defp criteria_list(_content), do: []

  # Indices must be counted over the STORED list, including any non-map junk a
  # hand-repaired row carries — `unmet_criteria/1` indexes the same way, and an
  # index computed over a filtered list would silently address a different row.
  defp criteria_list_indexed(content) when is_map(content) do
    case Map.get(content, "acceptance_criteria") || Map.get(content, :acceptance_criteria) do
      list when is_list(list) -> list |> Enum.with_index() |> Enum.filter(&is_map(elem(&1, 0)))
      _ -> []
    end
  end

  defp criteria_list_indexed(_content), do: []

  # Atom-key tolerant WITHOUT `String.to_atom/1` on a runtime value: the atom is
  # written literally so it is interned at compile time and no user-supplied
  # string can ever mint a new one.
  defp flagged?(row), do: Map.get(row, @flag) == true or Map.get(row, :ack_gate) == true

  defp draft?("drafts." <> _), do: true
  defp draft?(_), do: false

  defp published_id("drafts." <> rest), do: rest
  defp published_id(doc_id), do: doc_id
end
