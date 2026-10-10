defmodule Barkpark.Content.LiveWriteGate do
  @moduledoc """
  A draft-only seat (`contributor`) may not change what readers see
  (task-348a4fbe24feede6, owner decision 2026-10-10; lead ruling B).

  Most types keep a draft layer: an edit lands on `drafts.<id>` and a publish
  moves it to `<id>`, and `Content.Lifecycle` guards that move. Some kinds have
  NO draft layer at all: a paper's block ops and ingest write the published row
  in place, and a reference disconnect rewrites other documents' rows directly.
  For those kinds every write IS a publish.

  The predicate is on the ROW, not on a list of types: a write whose target id
  is not a `drafts.` id changes the live document (`live_row?/1`). So any kind
  without a draft model is covered by the shape of its own writes, and a new
  plugin's in-place writer is covered the moment it calls `check/2`.
  `test/barkpark/content/live_write_gate_census_test.exs` makes every direct
  `Document.changeset` writer in `api/lib` either call this gate or say why it
  is not a caller-driven write, so a new one cannot land unclassified.

  Callers with no caller context (internal jobs, migrations, seeds) and
  callers without a draft-only seat pass unchanged; see
  `Barkpark.Tenancy.Auth.publish_refused?/2`.
  """

  alias Barkpark.Content.DraftId
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @doc "True when a write to `doc_id` changes the live (published) row."
  @spec live_row?(term()) :: boolean()
  def live_row?(doc_id) when is_binary(doc_id) and doc_id != "", do: not DraftId.draft?(doc_id)
  def live_row?(_doc_id), do: false

  @doc """
  `:ok`, or `{:error, :publish_not_permitted}` when the write to `doc_id`
  lands on a live row and the caller in `opts` sits in a draft-only seat.
  """
  @spec check(term(), keyword()) :: :ok | {:error, :publish_not_permitted}
  def check(doc_id, opts) when is_list(opts) do
    if live_row?(doc_id), do: check_seat(opts), else: :ok
  end

  @doc """
  The seat half alone, for a door whose every write is live by definition
  (publish, unpublish, delete of a published document).
  """
  @spec check_seat(keyword()) :: :ok | {:error, :publish_not_permitted}
  def check_seat(opts) when is_list(opts) do
    if TenancyAuth.publish_refused?(
         Keyword.get(opts, :caller_context),
         Keyword.get(opts, :workspace_id)
       ),
       do: {:error, :publish_not_permitted},
       else: :ok
  end
end
