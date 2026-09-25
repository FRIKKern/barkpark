defmodule Barkpark.Content.ErrorEnvelope do
  @moduledoc """
  An exception that renders as its own error envelope
  (task-c10be8a9ad8f0145).

  `Barkpark.Content.Errors.to_envelope/2` renders a `{:error, exception}` whose
  module implements this behaviour through `error_envelope/1`, so the error
  vocabulary stays in content while a plugin owns the exception it raises. The
  Tasks plugin's twin refusal (409 `ambiguous_dataset`, raised by a
  `Barkpark.Content.ResolveDocGuards` guard) is the first implementer.

  The returned map is an envelope before stamping: `code` (a member of
  `Errors.known_codes/0`, so its hint resolves), `message`, `status`, and
  optional `details`. `Errors.stamp/2` adds the hint and request id.
  """

  @callback error_envelope(exception :: Exception.t()) :: %{
              required(:code) => String.t(),
              required(:message) => String.t(),
              required(:status) => pos_integer(),
              optional(:details) => map()
            }

  @doc "Whether `exception`'s module implements this behaviour."
  @spec implemented_by?(Exception.t()) :: boolean()
  def implemented_by?(%mod{}) do
    behaviours =
      mod.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    __MODULE__ in behaviours and function_exported?(mod, :error_envelope, 1)
  end
end
