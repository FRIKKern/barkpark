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

  ## Persistence shape

  State is stored in `document.content["bp_export_status"]` as a
  JSON-encoded string (the schema field is a plain `string`):

      {
        "state": "polling",
        "bokbasen_submission_id": "abc-123",
        "poll_url": "https://api.bokbasen.no/.../status/abc-123",
        "last_error": null,
        "updated_at": "2026-04-30T13:45:00Z"
      }

  Defensive fallback: legacy plain strings (`"draft"`, `"published"`,
  etc.) are coerced to `%{"state" => <legacy>}` on read.

  ## Idempotency

  If `bokbasen_submission_id` is already present in `bp_export_status`
  on entry, the stage step is **skipped** and the worker resumes
  polling. Combined with the `unique:` clause on the Oban worker
  (60s window keyed on `document_id`), this means re-enqueueing or
  retrying the same document never causes a duplicate stage POST.

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
  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Repo

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
        status = read_status(doc)

        case status["bokbasen_submission_id"] do
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
    persist_status(doc, %{"state" => "staging"})

    book_doc = book_doc_from(doc)

    case Export.to_iodata(book_doc) do
      {:ok, iodata} ->
        binary = IO.iodata_to_binary(iodata)
        do_stage(doc, binary, attempt, client_opts)

      {:error, {:xsd_invalid, reasons}} ->
        persist_status(doc, %{
          "state" => "failed",
          "last_error" => %{"type" => "xsd_invalid", "reasons" => reasons}
        })

        {:cancel, :xsd_invalid}
    end
  end

  defp do_stage(doc, binary, attempt, client_opts) do
    case Client.stage(binary, client_opts) do
      {:ok, %{submission_id: sub_id, poll_url: poll_url}} when is_binary(sub_id) ->
        persist_status(doc, %{
          "state" => "staged",
          "bokbasen_submission_id" => sub_id,
          "poll_url" => poll_url,
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
          persist_status(doc, %{
            "state" => "staging",
            "last_error" => %{"type" => "rate_limited", "retry_after_seconds" => secs}
          })

          {:snooze, max(secs, 1)}
        end

      {:error, %NetworkError{} = err} ->
        if attempt >= @max_effective_attempts do
          terminal_failure(doc, err, "network_exhausted")
          {:cancel, :exhausted}
        else
          persist_status(doc, %{
            "state" => "staging",
            "last_error" => %{"type" => "network", "reason" => inspect(err.reason)}
          })

          {:error, err}
        end

      {:error, %HTTPError{} = err} ->
        if attempt >= @max_effective_attempts do
          terminal_failure(doc, err, "http_exhausted")
          {:cancel, :exhausted}
        else
          persist_status(doc, %{
            "state" => "staging",
            "last_error" => %{"type" => "http", "status" => err.status}
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
        persist_status(doc, %{
          "state" => "polling",
          "bokbasen_submission_id" => sub_id,
          "poll_url" => poll_url,
          "last_error" => nil
        })

        {:snooze, poll_backoff(attempt)}

      {:ok, %{status: :accepted, details: details}} ->
        persist_status(doc, %{
          "state" => "accepted",
          "bokbasen_submission_id" => sub_id,
          "poll_url" => poll_url,
          "last_error" => nil,
          "details" => details
        })

        :ok

      {:ok, %{status: :rejected, details: details}} ->
        persist_status(doc, %{
          "state" => "rejected",
          "bokbasen_submission_id" => sub_id,
          "poll_url" => poll_url,
          "last_error" => %{"type" => "rejected", "details" => details}
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
        persist_status(doc, %{
          "state" => "rejected",
          "bokbasen_submission_id" => sub_id,
          "poll_url" => poll_url,
          "last_error" => %{
            "type" => "poll_parse_error",
            "http_status" => status,
            "raw_body" => safe_truncate(body)
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
        status = read_status(doc)

        case status["bokbasen_submission_id"] do
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
        persist_status(doc, %{
          "state" => "cancelled",
          "bokbasen_submission_id" => sub_id,
          "last_error" => nil
        })

        :ok

      {:error, %HTTPError{status: status} = err} when status >= 400 and status < 500 ->
        Logger.warning(
          "PublishWorker.cancel returned HTTP #{status} for submission_id=#{sub_id} — " <>
            "Bokbasen cannot abort this submission; operator should resubmit with " <>
            "<NotificationType>05</NotificationType> to mark the record as withdrawn."
        )

        persist_status(doc, %{
          "state" => "cannot_cancel",
          "bokbasen_submission_id" => sub_id,
          "last_error" => %{
            "type" => "cannot_cancel",
            "http_status" => status,
            "note" => "operator must resubmit with NotificationType=05"
          }
        })

        _ = err
        {:error, :cannot_cancel}

      {:error, other} ->
        {:error, other}
    end
  end

  # ---------------------------------------------------------------------------
  # Persistence
  # ---------------------------------------------------------------------------

  @doc false
  def read_status(%Document{content: content}) when is_map(content) do
    case Map.get(content, "bp_export_status") do
      nil ->
        %{}

      "" ->
        %{}

      str when is_binary(str) ->
        case Jason.decode(str) do
          {:ok, m} when is_map(m) -> m
          _ -> %{"state" => str}
        end

      m when is_map(m) ->
        m

      _ ->
        %{}
    end
  end

  def read_status(_), do: %{}

  defp persist_status(%Document{} = doc, patch) when is_map(patch) do
    current = read_status(doc)

    merged =
      current
      |> Map.merge(patch)
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

    encoded = Jason.encode!(merged)
    new_content = Map.put(doc.content || %{}, "bp_export_status", encoded)

    {:ok, updated} =
      doc
      |> Document.changeset(%{"content" => new_content})
      |> Repo.update()

    updated
  end

  defp terminal_failure(doc, err, kind) do
    persist_status(doc, %{
      "state" => "failed",
      "last_error" => %{"type" => kind, "summary" => format_error(err)}
    })
  end

  defp format_error(err) do
    inspect(err, limit: 500, printable_limit: 1000)
  end

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
