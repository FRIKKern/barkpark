defmodule Barkpark.Content.NulByteError do
  @moduledoc """
  A write that skips `Document.changeset/2` held a NUL (`Content.NulByte`,
  task-b456c48d916f7cbc).

  Raised, not returned, for the reason `Tasks.AmbiguousTwinError` is: the
  task write door `Tasks.Internal.fenced_content_write/4` has some twenty-five
  callers, each matching `{:ok, _} | :stale`, and a new `{:error, _}` there
  would fall into whichever arm matched loosest. `Plug.Exception` puts it at
  422, and `BarkparkWeb.ErrorJSON` passes it to `Barkpark.Content.Errors`, so
  the body is the changeset refusal's: `validation_failed` with
  `details: %{field => [message]}`. The message never carries the NUL.
  """

  defexception [:field, :message]

  @type t :: %__MODULE__{field: atom(), message: String.t()}
end

defimpl Plug.Exception, for: Barkpark.Content.NulByteError do
  def status(_e), do: 422
  def actions(_e), do: []
end
