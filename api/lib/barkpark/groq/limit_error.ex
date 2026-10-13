defmodule Barkpark.Groq.LimitError do
  @moduledoc "A query that exceeds one of the GROQ endpoint's documented limits."
  defexception [:message]
end
