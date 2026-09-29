defmodule Barkpark.Shape do
  @moduledoc """
  Which of the three shapes this node runs in: `cloud`, `solo` or `app`
  (docs/contracts/product-era.md, "Three shapes, one core").

  The shape is DECLARED by the door that installed the node, never guessed by
  core: `BARKPARK_SHAPE` in the node's env. The Cloud provisioner writes
  `cloud`, the Solo doors (`deploy.sh`, `bp setup`, docker compose) write
  `solo`, and the App host passes `app`. A node whose door declared nothing
  reports `nil`, which reads as "undeclared", not as any shape.

  Core code must not branch on this value. It is inventory for `status.json`,
  so an operator or the control plane can see what a box is. Shape-specific
  behaviour lives at the edges, behind its own switch.

  An unknown value refuses the boot, so a typo cannot pass as undeclared.
  """

  @shapes ~w(cloud solo app)

  @doc "The three shape names, as strings."
  @spec names() :: [String.t()]
  def names, do: @shapes

  @doc """
  Parse a `BARKPARK_SHAPE` value for `config/runtime.exs`. Surrounding
  whitespace and case are ignored; anything outside `names/0` raises.
  """
  @spec parse!(String.t()) :: String.t()
  def parse!(raw) when is_binary(raw) do
    shape = raw |> String.trim() |> String.downcase()

    if shape in @shapes do
      shape
    else
      raise ArgumentError,
            "BARKPARK_SHAPE=#{inspect(raw)} is not a shape; known: #{Enum.join(@shapes, ",")}"
    end
  end

  @doc "The declared shape of this node, or `nil` when no door declared one."
  @spec current() :: String.t() | nil
  def current, do: Application.get_env(:barkpark, :shape)
end
