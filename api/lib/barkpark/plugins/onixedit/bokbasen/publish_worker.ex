defmodule Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker do
  @moduledoc """
  Oban worker that drives a single-phase async-poll publication of one
  `book` document to Bokbasen's metadata-import API.

  ## State machine

      :pending → :staging → :staged → :polling → :accepted
                                              ↘ :rejected
                                              ↘ :failed
                                              ↘ :cannot_cancel
                                              ↘ :cancelled

  The worker re-enqueues itself via `{:snooze, secs}` between stage and
  poll steps. Each `perform/1` invocation is one transition.

  ## Persistence shape (Phase 8 WI1)

  State is stored in `document.content["bp_export_status"]` as a
  **native composite map** (Phase 8 WI1 promoted the field from a
  JSON-encoded string). Reads/writes go through
  `Barkpark.Plugins.OnixEdit.Bokbasen.Status` which preserves
  backwards-compat with the legacy string shape.

  Composite fields written by this worker:

      %{
        "state"          => "polling",
        "submission_id"  => "abc-123",
        "poll_url"       => "https://api.bokbasen.no/.../status/abc-123",
        "submitted_at"   => "2026-04-30T13:45:00Z",
        "staged_at"      => "2026-04-30T13:45:05Z",
        "polling_at"     => "2026-04-30T13:45:10Z",
        "accepted_at"    => nil,
        "rejected_at"    => nil,
        "retry_at"       => nil,
        "attempt_count"  => 2,
        "signed_off"     => false,
        "last_error"     => nil,
        "updated_at"     => "2026-04-30T13:45:10Z"
      }

  `Status.write/2` derives `signed_off: true` whenever the merged status
  has `accepted_at` set.

  ## Idempotency

  If `submission_id` is already present in `bp_export_status` on entry,
  the stage step is **skipped** and the worker resumes polling. Combined
  with the `unique:` clause on the Oban worker (60s window keyed on
  `document_id`), this dedups the **Oban** layer: re-enqueueing or
  retrying the same document does not re-run a stage POST that already
  recorded its `submission_id`.

  This guard is scoped to that layer and no further. It reads
  `bp_export_status`, so it can only see a stage POST that already
  RETURNED and was recorded. It says nothing about a duplicate minted
  INSIDE one `Client.stage/2` call — a POST the remote accepted whose
  response was lost, then replayed by the client's own retry loop. No
  `submission_id` exists at that moment, so this check cannot fire.
  That case is closed one layer down, by `Barkpark.Net.RetrySafety`,
  which refuses to replay a non-idempotent method on an ambiguous
  failure (`:timeout`, `502`, `504`).

  ## Retry policy

    * `AuthError`, `SchemaRejectionError`     → terminal `:failed`,
      `{:cancel, reason}` (no retry)
    * `NetworkError`                          → up to 3 effective
      attempts, then `{:cancel, :exhausted}` with `:failed`
    * `RateLimitError{retry_after_seconds}`   → `{:snooze, secs}`,
      capped at 3 effective attempts
    * Document missing                        → `{:cancel, :document_missing}`
    * XSD-invalid render                      → `{:cancel, :xsd_invalid}`,
      reasons captured in `last_error`

  Backoff for un-snoozed `{:error, _}` returns is overridden in
  `backoff/1` to `2^attempt * 15s`.

  ## Cancel

  `cancel/3` is a synchronous helper (not run in the queue). It calls
  `Client.cancel/2`. On 4xx HTTPError it logs a warning and persists
  `:cannot_cancel`, recommending the operator resubmit with
  `<NotificationType>05</NotificationType>` per the WI1 contract.
  """

  use Oban.Worker,
    queue: :bokbasen,
    max_attempts: 5,
    unique: [
      keys: [:document_id],
      states: [:available, :scheduled, :executing],
      period: 60
    ]

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.ExternalSync
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Client
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors.AuthError
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors.HTTPError
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors.NetworkError
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors.RateLimitError
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors.SchemaRejectionError
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Status
  alias Barkpark.Plugins.OnixEdit.Export

  @max_effective_attempts 3
  @poll_initial_delay_s 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    doc_id = args["document_id"]
    type = args["type"] || "book"
    dataset = args["dataset"] || "production"
    client_opts = client_opts(args)
    scope = scope_opts_from_args(args)

    case Content.get_document(doc_id, type, dataset, scope) do
      {:error, :not_found} ->
        Logger.warning(
          "PublishWorker: document not found doc_id=#{inspect(doc_id)} type=#{type} dataset=#{dataset}"
        )

        {:cancel, :document_missing}

      {:ok, %Document{} = doc} ->
        status = Status.read(doc)

        case submission_id_of(status) do
          sub_id when is_binary(sub_id) and sub_id != "" ->
            poll_step(doc, sub_id, status["poll_url"], attempt, client_opts)

          _ ->
            stage_step(doc, attempt, client_opts)
        end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(2, attempt) * 15)
  end

  # ---------------------------------------------------------------------------
  # Stage step
  # ---------------------------------------------------------------------------

  defp stage_step(%Document{} = doc, attempt, client_opts) do
    write_status(doc, %{
      "state" => "staging",
      "submitted_at" => DateTime.utc_now()
    })

    book_doc = book_doc_from(doc)

    case Export.to_iodata(book_doc) do
      {:ok, iodata} ->
        binary = IO.iodata_to_binary(iodata)
        do_stage(doc, binary, attempt, client_opts)

      {:error, {:xsd_invalid, reasons}} ->
        write_status(doc, %{
          "state" => "failed",
          "last_error" => %{
            "type" => "xsd_invalid",
            "message" => "ONIX failed XSD validation",
            "details" => Enum.join(reasons, "; "),
            "http_status" => nil
          }
        })

        {:cancel, :xsd_invalid}

      # A valid-but-unseeded (or non-string) ONIX codelist code. Previously the
      # resolver `raise` escaped `perform/1`, so Oban poison-retried up to
      # `max_attempts` while the doc sat stranded at "staging" (set above at
      # entry to this step). Re-rendering never fixes an unrecognized code, so
      # transition to a clean terminal "failed" with the diagnostic and
      # `{:cancel, …}` — the same non-retry contract the xsd_invalid path uses.
      {:error, {:invalid_code, detail}} ->
        write_status(doc, %{
          "state" => "failed",
          "last_error" => %{
            "type" => "invalid_code",
            "message" => "ONIX export used an unrecognized codelist code",
            "details" => detail["message"],
            "http_status" => nil
          }
        })

        {:cancel, :invalid_code}
    end
  end

  defp do_stage(doc, binary, attempt, client_opts) do
    case Client.stage(binary, client_opts) do
      {:ok, %{submission_id: sub_id, poll_url: poll_url}} when is_binary(sub_id) ->
        # Phase 8 WI2 — defensively re-sanitize the submission_id Client.stage
        # returned: Bokbasen Location headers can have trailing slashes or
        # query strings that the Client's split-and-take-last extractor does
        # not strip. We prefer the Client's value but fall back to extracting
        # from poll_url (which preserves the full Location URL on the
        # no-JSON-body path).
        effective_id = extract_submission_id(sub_id) || extract_submission_id(poll_url) || sub_id

        write_status(doc, %{
          "state" => "staged",
          "submission_id" => effective_id,
          "poll_url" => poll_url,
          "staged_at" => DateTime.utc_now(),
          "last_error" => nil
        })

        {:snooze, @poll_initial_delay_s}

      {:error, %AuthError{} = err} ->
        terminal_failure(doc, err, "auth")
        {:cancel, :auth_failed}

      {:error, %SchemaRejectionError{} = err} ->
        terminal_failure(doc, err, "schema_rejection")
        {:cancel, :schema_rejected}

      {:error, %RateLimitError{retry_after_seconds: secs} = err} ->
        if attempt >= @max_effective_attempts do
          terminal_failure(doc, err, "rate_limited_exhausted")
          {:cancel, :exhausted}
        else
          write_status(doc, %{
            "state" => "staging",
            "retry_at" => DateTime.utc_now() |> DateTime.add(secs, :second),
            "last_error" => %{
              "type" => "rate_limited",
              "message" => "Bokbasen rate-limited; retrying after #{secs}s",
              "details" => nil,
              "http_status" => 429
            }
          })

          {:snooze, max(secs, 1)}
        end

      {:error, %NetworkError{} = err} ->
        if attempt >= @max_effective_attempts do
          terminal_failure(doc, err, "network_exhausted")
          {:cancel, :exhausted}
        else
          write_status(doc, %{
            "state" => "staging",
            "last_error" => %{
              "type" => "network",
              "message" => inspect(err.reason),
              "details" => nil,
              "http_status" => nil
            }
          })

          {:error, err}
        end

      {:error, %HTTPError{} = err} ->
        if attempt >= @max_effective_attempts do
          terminal_failure(doc, err, "http_exhausted")
          {:cancel, :exhausted}
        else
          write_status(doc, %{
            "state" => "staging",
            "last_error" => %{
              "type" => "http",
              "message" => "Bokbasen HTTP #{err.status}",
              "details" => safe_truncate(err.body),
              "http_status" => err.status
            }
          })

          {:error, err}
        end

      {:error, other} ->
        terminal_failure(doc, other, "unknown")
        {:cancel, :unknown_error}
    end
  end

  # ---------------------------------------------------------------------------
  # Poll step
  # ---------------------------------------------------------------------------

  defp poll_step(%Document{} = doc, sub_id, poll_url, attempt, client_opts) do
    opts =
      if is_binary(poll_url) and poll_url != "",
        do: Keyword.put(client_opts, :poll_url, poll_url),
        else: client_opts

    case Client.poll(sub_id, opts) do
      {:ok, %{status: :pending}} ->
        current = Status.read(doc)
        next_count = (current["attempt_count"] || 0) + 1

        write_status(doc, %{
          "state" => "polling",
          "submission_id" => sub_id,
          "poll_url" => poll_url,
          "polling_at" => DateTime.utc_now(),
          "attempt_count" => next_count,
          "last_error" => nil
        })

        {:snooze, poll_backoff(attempt)}

      {:ok, %{status: :accepted, details: details}} ->
        write_status(doc, %{
          "state" => "accepted",
          "submission_id" => sub_id,
          "poll_url" => poll_url,
          "accepted_at" => DateTime.utc_now(),
          "details" => details,
          "last_error" => nil
        })

        :ok

      {:ok, %{status: :rejected, details: details}} ->
        write_status(doc, %{
          "state" => "rejected",
          "submission_id" => sub_id,
          "poll_url" => poll_url,
          "rejected_at" => DateTime.utc_now(),
          "last_error" => build_rejected_envelope(details, 200)
        })

        {:cancel, :rejected}

      {:error, %AuthError{} = err} ->
        terminal_failure(doc, err, "auth")
        {:cancel, :auth_failed}

      {:error, %SchemaRejectionError{} = err} ->
        terminal_failure(doc, err, "schema_rejection")
        {:cancel, :schema_rejected}

      {:error, %RateLimitError{retry_after_seconds: secs} = err} ->
        if attempt >= @max_effective_attempts do
          terminal_failure(doc, err, "rate_limited_exhausted")
          {:cancel, :exhausted}
        else
          retry_at =
            case parse_retry_after(secs) do
              {:ok, dt} -> dt
              :error -> nil
            end

          write_status(doc, %{
            "state" => "polling",
            "submission_id" => sub_id,
            "poll_url" => poll_url,
            "retry_at" => retry_at,
            "last_error" => %{
              "type" => "rate_limited",
              "message" => "Bokbasen rate-limited; retrying after #{secs}s",
              "details" => nil,
              "http_status" => 429
            }
          })

          {:snooze, max(secs, 1)}
        end

      {:error, %NetworkError{} = err} ->
        if attempt >= @max_effective_attempts do
          terminal_failure(doc, err, "network_exhausted")
          {:cancel, :exhausted}
        else
          {:error, err}
        end

      {:error, %HTTPError{status: status, body: body} = err} ->
        # XML/JSON parse failure surfaces here from Client.parse_poll_body.
        # Treat as terminal :rejected with parse-error context — we already
        # have a submission, but the response payload is unintelligible and
        # retrying the same poll won't change that.
        write_status(doc, %{
          "state" => "rejected",
          "submission_id" => sub_id,
          "poll_url" => poll_url,
          "rejected_at" => DateTime.utc_now(),
          "last_error" => %{
            "type" => "poll_parse_error",
            "message" => "Could not parse Bokbasen poll response",
            "details" => safe_truncate(body),
            "http_status" => status
          }
        })

        _ = err
        {:cancel, :poll_parse_error}

      {:error, other} ->
        terminal_failure(doc, other, "unknown")
        {:cancel, :unknown_error}
    end
  end

  defp poll_backoff(attempt) do
    trunc(:math.pow(2, attempt) * @poll_initial_delay_s)
  end

  # ---------------------------------------------------------------------------
  # Cancel (synchronous public helper)
  # ---------------------------------------------------------------------------

  @doc """
  Cancel a pending Bokbasen submission for a document.

  Returns `:ok` on a successful 200/204 from Bokbasen, `{:error, :no_submission}`
  if the document has no recorded submission_id, or `{:error, :cannot_cancel}`
  on a 4xx response (the worker logs a warning recommending the operator
  resubmit with `<NotificationType>05</NotificationType>`).
  """
  @spec cancel(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, :no_submission | :cannot_cancel | :not_found | term()}
  def cancel(document_id, type, dataset, opts \\ []) do
    # `opts` may carry both `Client.cancel` opts AND the tenancy scope
    # (`:workspace_id` / `:project_id`). The read is scoped to the same
    # tenant the caller resolved; `Client.cancel` reads only its own keys,
    # so the two co-exist in one keyword list. Nil/absent scope keys fall
    # back to Default resolution (back-compat).
    scope = scope_opts_from_keyword(opts)

    case Content.get_document(document_id, type, dataset, scope) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, %Document{} = doc} ->
        status = Status.read(doc)

        case submission_id_of(status) do
          sub_id when is_binary(sub_id) and sub_id != "" ->
            do_cancel(doc, sub_id, opts)

          _ ->
            {:error, :no_submission}
        end
    end
  end

  defp do_cancel(doc, sub_id, opts) do
    case Client.cancel(sub_id, opts) do
      :ok ->
        # Phase 8 WI2 — Bokbasen returns 204 No Content with no body, so we
        # have no server-side cancellation timestamp to record. Per the WI2
        # contract `cancelled_at` remains nil; only `state` and the merged
        # `updated_at` (auto-stamped by Status.write/2) change.
        write_status(doc, %{
          "state" => "cancelled",
          "submission_id" => sub_id,
          "last_error" => nil
        })

        :ok

      {:error, %HTTPError{status: status} = err} when status >= 400 and status < 500 ->
        Logger.warning(
          "PublishWorker.cancel returned HTTP #{status} for submission_id=#{sub_id} — " <>
            "Bokbasen cannot abort this submission; operator should resubmit with " <>
            "<NotificationType>05</NotificationType> to mark the record as withdrawn."
        )

        write_status(doc, %{
          "state" => "cannot_cancel",
          "submission_id" => sub_id,
          "last_error" => %{
            "type" => "cannot_cancel",
            "message" => "operator must resubmit with NotificationType=05",
            "details" => nil,
            "http_status" => status
          }
        })

        _ = err
        {:error, :cannot_cancel}

      {:error, other} ->
        {:error, other}
    end
  end

  # ---------------------------------------------------------------------------
  # Persistence helpers (Phase 8 WI1: thin wrappers over Status)
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # write_status/2 — persist + broadcast on the generic external-sync topic
  # ---------------------------------------------------------------------------
  #
  # Every Bokbasen state transition flows through here. `Status.write/2`
  # persists the composite and emits the legacy `{:bokbasen_status_update, …}`
  # broadcast on `bokbasen:document:<doc_id>` (historically consumed by
  # the now-removed BookEditor LV, and still by AdminLive). We then emit
  # the plugin-agnostic `{:external_sync_status, …}` broadcast on
  # `external_sync:bokbasen:<doc_id>` so any consumer that uses the
  # `ExternalSync` contract (e.g. the `ExternalSyncPill` mounted by
  # StudioLive) refreshes without knowing about Bokbasen specifically.
  #
  # Both topics co-exist for the remaining AdminLive consumer. Once
  # AdminLive migrates to the `ExternalSync` contract, `Status.write/2`
  # can stop emitting the legacy topic. (BookEditor was already deleted
  # in Goal `barkpark-zdy`.)
  defp write_status(%Document{doc_id: doc_id} = doc, %{} = patch) do
    updated = Status.write(doc, patch)
    new_state = Map.get(patch, "state") || Map.get(patch, :state)
    ExternalSync.broadcast("bokbasen", doc_id, new_state, patch)
    updated
  end

  @doc """
  Phase 7 compat shim — `Status.read/1` is the canonical path. Kept so any
  out-of-tree caller continues to compile; new code should call
  `Barkpark.Plugins.OnixEdit.Bokbasen.Status.read/1` directly.
  """
  @spec read_status(Document.t() | any()) :: map()
  def read_status(arg), do: Status.read(arg)

  @doc """
  Phase 7 compat shim — delegates to `Status.write/2`.
  """
  @spec persist_status(Document.t(), map()) :: Document.t()
  def persist_status(%Document{} = doc, patch) when is_map(patch),
    do: Status.write(doc, patch)

  defp terminal_failure(doc, err, kind) do
    write_status(doc, %{
      "state" => "failed",
      "last_error" => %{
        "type" => kind,
        "message" => format_error(err),
        "details" => nil,
        "http_status" => http_status_of(err)
      }
    })
  end

  defp format_error(err) do
    inspect(err, limit: 500, printable_limit: 1000)
  end

  defp http_status_of(%HTTPError{status: status}), do: status
  defp http_status_of(%RateLimitError{}), do: 429
  defp http_status_of(%AuthError{}), do: 401
  defp http_status_of(%SchemaRejectionError{}), do: 422
  defp http_status_of(_), do: nil

  defp submission_id_of(%{} = status) do
    Map.get(status, "submission_id") || Map.get(status, "bokbasen_submission_id")
  end

  defp submission_id_of(_), do: nil

  defp book_doc_from(%Document{} = doc) do
    pub_id = Content.published_id(doc.doc_id)

    (doc.content || %{})
    |> Map.delete("bp_export_status")
    |> Map.put("_id", doc.doc_id)
    |> Map.put("_publishedId", pub_id)
    |> Map.put("_type", doc.type)
  end

  defp client_opts(args) do
    args
    |> Map.take(["base_url", "timeout"])
    |> Enum.flat_map(fn
      {"base_url", v} when is_binary(v) and v != "" -> [base_url: v]
      {"timeout", v} when is_integer(v) -> [timeout: v]
      _ -> []
    end)
  end

  # ---------------------------------------------------------------------------
  # Tenancy scope (barkpark-zdvi) — canonical write/read of workspace_id /
  # project_id into & out of the Oban job args.
  #
  # The worker re-reads the document it was enqueued for, so the ENQUEUE
  # must capture the dispatching scope into the string-keyed args and the
  # worker must read it back as `Content.get_document/4` opts. Without this
  # the read is global + Default-project — two workspaces sharing the
  # "production" dataset string could act on the WRONG tenant's book.
  #
  # `put_scope_args/2` is the single write seam shared by every enqueue site
  # (Actions.enqueue_publish, Lifecycle.enqueue, BokbasenLive retry). It is
  # nil-safe: an empty scope (or nil-valued keys) adds nothing, so a caller
  # that lacks scope simply enqueues the legacy arg shape.
  #
  # Back-compat: old jobs already in the queue lack these keys, so
  # `scope_opts_from_args/1` yields `[]` → nil workspace → Default
  # resolution (the pre-fix behaviour), never a crash.
  # ---------------------------------------------------------------------------

  @doc false
  @spec put_scope_args(map(), keyword()) :: map()
  def put_scope_args(args, scope) when is_map(args) and is_list(scope) do
    args
    |> maybe_put_arg("workspace_id", Keyword.get(scope, :workspace_id))
    |> maybe_put_arg("project_id", Keyword.get(scope, :project_id))
  end

  def put_scope_args(args, _scope) when is_map(args), do: args

  defp maybe_put_arg(args, _key, nil), do: args
  defp maybe_put_arg(args, key, value), do: Map.put(args, key, value)

  # Read the scope back out of the string-keyed Oban args into the keyword
  # opts `Content.get_document/4` expects. Absent keys drop entirely.
  defp scope_opts_from_args(args) when is_map(args) do
    []
    |> maybe_put_scope(:project_id, args["project_id"])
    |> maybe_put_scope(:workspace_id, args["workspace_id"])
  end

  defp scope_opts_from_args(_), do: []

  # Pull only the scope keys out of a mixed keyword (client opts + scope),
  # as passed to `cancel/4`.
  defp scope_opts_from_keyword(opts) when is_list(opts) do
    []
    |> maybe_put_scope(:project_id, Keyword.get(opts, :project_id))
    |> maybe_put_scope(:workspace_id, Keyword.get(opts, :workspace_id))
  end

  defp scope_opts_from_keyword(_), do: []

  defp maybe_put_scope(opts, _key, nil), do: opts
  defp maybe_put_scope(opts, key, value), do: Keyword.put(opts, key, value)

  defp safe_truncate(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp safe_truncate(body), do: inspect(body, limit: 200)

  # ---------------------------------------------------------------------------
  # Phase 8 WI2 — submission_id sanitization
  # ---------------------------------------------------------------------------

  @doc false
  # Strip query-string + trailing slash, take last path segment. Idempotent
  # for already-clean IDs ("abc-123" → "abc-123").
  @spec extract_submission_id(String.t() | any()) :: String.t() | nil
  def extract_submission_id(value) when is_binary(value) and value != "" do
    cleaned =
      value
      |> String.split("?", parts: 2)
      |> hd()
      |> String.trim_trailing("/")
      |> String.split("/")
      |> List.last()

    case cleaned do
      "" -> nil
      v -> v
    end
  end

  def extract_submission_id(_), do: nil

  # ---------------------------------------------------------------------------
  # Phase 8 WI2 — Retry-After parsing (integer seconds OR HTTP-date)
  # ---------------------------------------------------------------------------

  @month_map %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @doc """
  Parse a Retry-After header value into an absolute `DateTime` in UTC.

  Accepts either:

    * an integer (seconds, relative to `now`)
    * an integer-seconds string (`"60"`)
    * an RFC 7231 IMF-fixdate (`"Wed, 21 Oct 2025 07:28:00 GMT"`)

  Returns `{:ok, dt}` on success or `:error` on parse failure.

  The optional `now` is used as the base when the value is integer
  seconds (defaults to `DateTime.utc_now/0`). Useful for deterministic
  tests.
  """
  @spec parse_retry_after(term(), DateTime.t()) :: {:ok, DateTime.t()} | :error
  def parse_retry_after(value), do: parse_retry_after(value, DateTime.utc_now())

  def parse_retry_after(nil, _now), do: :error

  def parse_retry_after(value, now) when is_integer(value) and value >= 0 do
    {:ok, DateTime.add(now, value, :second)}
  end

  def parse_retry_after(value, now) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> {:ok, DateTime.add(now, n, :second)}
      _ -> parse_http_date(value)
    end
  end

  def parse_retry_after(_, _), do: :error

  defp parse_http_date(s) do
    case Regex.run(
           ~r/^[A-Za-z]+,\s+(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})\s+GMT$/,
           String.trim(s)
         ) do
      [_, d, mon, y, h, mi, sec] ->
        with {:ok, mn} <- Map.fetch(@month_map, mon),
             {:ok, ndt} <-
               NaiveDateTime.new(
                 String.to_integer(y),
                 mn,
                 String.to_integer(d),
                 String.to_integer(h),
                 String.to_integer(mi),
                 String.to_integer(sec)
               ),
             {:ok, dt} <- DateTime.from_naive(ndt, "Etc/UTC") do
          {:ok, dt}
        else
          _ ->
            Logger.debug("PublishWorker.parse_http_date: bad date #{inspect(s)}")
            :error
        end

      _ ->
        Logger.debug("PublishWorker.parse_http_date: bad date #{inspect(s)}")
        :error
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 8 WI2 — :rejected last_error envelope
  # ---------------------------------------------------------------------------

  defp build_rejected_envelope(details, http_status) do
    raw =
      case details do
        %{"raw" => r} when is_binary(r) -> r
        m when is_map(m) -> Jason.encode!(m)
        b when is_binary(b) -> b
        other -> inspect(other)
      end

    truncated_raw = String.slice(raw, 0, 4096)
    {error_text, error_attrs} = extract_error_xml(raw)

    message =
      case error_text do
        nil -> "Bokbasen rejected the submission"
        text -> "Bokbasen rejected the submission: " <> truncate_message(text, 200)
      end

    %{
      "type" => "schema_rejection",
      "message" => message,
      "details" => %{
        "raw_xml" => truncated_raw,
        "error_text" => error_text,
        "error_attrs" => error_attrs
      },
      "http_status" => http_status
    }
  end

  defp extract_error_xml(body) when is_binary(body) do
    case Regex.run(~r/<error([^>]*)>([^<]*)<\/error>/s, body) do
      [_, attrs_str, text] ->
        {String.trim(text), parse_xml_attrs(attrs_str)}

      _ ->
        {nil, %{}}
    end
  end

  defp extract_error_xml(_), do: {nil, %{}}

  defp parse_xml_attrs(attrs_str) when is_binary(attrs_str) do
    Regex.scan(~r/(\w+)="([^"]*)"/, attrs_str)
    |> Enum.into(%{}, fn [_, k, v] -> {k, v} end)
  end

  defp truncate_message(text, max) when is_binary(text) and is_integer(max) do
    if String.length(text) > max, do: String.slice(text, 0, max), else: text
  end
end
