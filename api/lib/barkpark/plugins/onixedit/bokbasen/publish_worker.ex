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
  `document_id`), this means re-enqueueing or retrying the same document
  never causes a duplicate stage POST.

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

    case Content.get_document(doc_id, type, dataset) do
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
    Status.write(doc, %{
      "state" => "staging",
      "submitted_at" => DateTime.utc_now()
    })

    book_doc = book_doc_from(doc)

    case Export.to_iodata(book_doc) do
      {:ok, iodata} ->
        binary = IO.iodata_to_binary(iodata)
        do_stage(doc, binary, attempt, client_opts)

      {:error, {:xsd_invalid, reasons}} ->
        Status.write(doc, %{
          "state" => "failed",
          "last_error" => %{
            "type" => "xsd_invalid",
            "message" => "ONIX failed XSD validation",
            "details" => Enum.join(reasons, "; "),
            "http_status" => nil
          }
        })

        {:cancel, :xsd_invalid}
    end
  end

  defp do_stage(doc, binary, attempt, client_opts) do
    case Client.stage(binary, client_opts) do
      {:ok, %{submission_id: sub_id, poll_url: poll_url}} when is_binary(sub_id) ->
        Status.write(doc, %{
          "state" => "staged",
          "submission_id" => sub_id,
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
          Status.write(doc, %{
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
          Status.write(doc, %{
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
          Status.write(doc, %{
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

        Status.write(doc, %{
          "state" => "polling",
          "submission_id" => sub_id,
          "poll_url" => poll_url,
          "polling_at" => DateTime.utc_now(),
          "attempt_count" => next_count,
          "last_error" => nil
        })

        {:snooze, poll_backoff(attempt)}

      {:ok, %{status: :accepted, details: details}} ->
        Status.write(doc, %{
          "state" => "accepted",
          "submission_id" => sub_id,
          "poll_url" => poll_url,
          "accepted_at" => DateTime.utc_now(),
          "details" => details,
          "last_error" => nil
        })

        :ok

      {:ok, %{status: :rejected, details: details}} ->
        Status.write(doc, %{
          "state" => "rejected",
          "submission_id" => sub_id,
          "poll_url" => poll_url,
          "rejected_at" => DateTime.utc_now(),
          "last_error" => %{
            "type" => "rejected",
            "message" => "Bokbasen rejected submission",
            "details" => format_details(details),
            "http_status" => 200
          }
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
        Status.write(doc, %{
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
    case Content.get_document(document_id, type, dataset) do
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
        Status.write(doc, %{
          "state" => "cancelled",
          "submission_id" => sub_id,
          "cancelled_at" => DateTime.utc_now(),
          "last_error" => nil
        })

        :ok

      {:error, %HTTPError{status: status} = err} when status >= 400 and status < 500 ->
        Logger.warning(
          "PublishWorker.cancel returned HTTP #{status} for submission_id=#{sub_id} — " <>
            "Bokbasen cannot abort this submission; operator should resubmit with " <>
            "<NotificationType>05</NotificationType> to mark the record as withdrawn."
        )

        Status.write(doc, %{
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
    Status.write(doc, %{
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

  defp format_details(details) when is_binary(details), do: details
  defp format_details(details), do: inspect(details, limit: 500, printable_limit: 1000)

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

  defp safe_truncate(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp safe_truncate(body), do: inspect(body, limit: 200)
end
