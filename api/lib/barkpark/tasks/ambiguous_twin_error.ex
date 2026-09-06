defmodule Barkpark.Tasks.AmbiguousTwinError do
  @moduledoc """
  The task doors' ONE typed refusal: this doc_id names more than one row and the
  caller named no dataset, so no row is returned.

  It is the mechanical half of `Barkpark.Tasks.TwinResolver`'s rule 3 — read that
  moduledoc for the rule this refusal enforces and why picking would be worse.

  Raised at the resolver CHOKEPOINT rather than returned, for the same reason
  `Barkpark.Content.InvalidFilterError` is: `TasksController.find_task_by_doc_id/2`
  has 29 call sites and `Tasks.Claim` two more, each with its own `with`/`case`
  error vocabulary. A new `{:error, _}` shape would be swallowed by whichever of
  those arms matched loosest — the silent-wrong-row failure this refusal exists to
  end, re-introduced one level up. A raise reaches every door identically.

  `Plug.Exception` puts it at 409 (a resource-STATE collision, the `conflict`
  family — not a 500: the server is fine, the LEDGER is ambiguous), and
  `BarkparkWeb.ErrorJSON` carries the body through `Barkpark.Content.Errors` so
  the envelope names every dataset that holds the id instead of collapsing to
  `internal_error`.
  """

  defexception [:doc_id, :datasets, :message]

  @type t :: %__MODULE__{doc_id: String.t(), datasets: [String.t()], message: String.t()}

  @doc """
  Build the refusal for `doc_id` living in `datasets` (deduped and sorted here,
  so the message and `details.datasets` cannot disagree).
  """
  @spec new(String.t(), [String.t() | nil]) :: t()
  def new(doc_id, datasets) do
    named = datasets |> Enum.map(&to_string(&1 || "")) |> Enum.uniq() |> Enum.sort()

    %__MODULE__{
      doc_id: doc_id,
      datasets: named,
      message:
        "task #{doc_id} exists in more than one dataset in this workspace/project " <>
          "(#{Enum.join(named, ", ")}); name one with ?dataset= — this door will not pick for you"
    }
  end
end

defimpl Plug.Exception, for: Barkpark.Tasks.AmbiguousTwinError do
  def status(_e), do: 409
  def actions(_e), do: []
end
