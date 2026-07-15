defmodule Barkpark.CycleFleet.Profile do
  @moduledoc """
  Executable phase contracts for Codex cycle profiles.

  Epic is the compact evidence-gated cycle. Legendary keeps the same durable
  assignment/result protocol, adds an experiment phase, and derives its build
  fleet from the frozen inventory and proven batch capacity.
  """

  @epic %{
    survey: %{agent_type: "epic-surveyor", effort: "medium", planned: 12},
    verify: %{agent_type: "epic-verifier", effort: "medium", planned: 6},
    build: %{agent_type: "epic-builder", effort: "high", planned: 3},
    review: %{agent_type: "code-reviewer", effort: "high", planned: 3}
  }

  @legendary_fixed %{
    survey: %{agent_type: "epic-surveyor", effort: "medium", planned: 60},
    verify: %{agent_type: "epic-verifier", effort: "medium", planned: 30},
    experiment: %{agent_type: "legendary-experimenter", effort: "medium", planned: 15},
    review: %{agent_type: "code-reviewer", effort: "high", planned: 15}
  }

  @profiles ~w(epic legendary)

  @spec names() :: [String.t()]
  def names, do: @profiles

  @spec phases(String.t() | atom()) :: [atom()]
  def phases(profile) do
    case normalize(profile) do
      {:ok, "epic"} -> [:survey, :verify, :build, :review]
      {:ok, "legendary"} -> [:survey, :verify, :experiment, :build, :review]
      _ -> []
    end
  end

  @spec plan(String.t() | atom(), map()) :: {:ok, map()} | {:error, atom()}
  def plan(profile, inputs \\ %{})

  def plan(profile, _inputs) when profile in [:epic, "epic"], do: {:ok, @epic}

  def plan(profile, inputs) when profile in [:legendary, "legendary"] and is_map(inputs) do
    with {:ok, unit_count} <- positive_integer(inputs, :unit_count),
         {:ok, capacity} <- positive_integer(inputs, :proven_batch_capacity) do
      build_count = max(15, ceil_div(unit_count, capacity))

      {:ok,
       Map.put(@legendary_fixed, :build, %{
         agent_type: "legendary-builder",
         effort: "medium",
         planned: build_count
       })}
    end
  end

  def plan(_profile, _inputs), do: {:error, :invalid_profile}

  @spec opening_plan(String.t() | atom()) :: {:ok, map()} | {:error, :invalid_profile}
  def opening_plan(profile) when profile in [:epic, "epic"], do: {:ok, @epic}

  def opening_plan(profile) when profile in [:legendary, "legendary"] do
    {:ok,
     Map.put(@legendary_fixed, :build, %{
       agent_type: "legendary-builder",
       effort: "medium",
       planned: 15,
       provisional: true
     })}
  end

  def opening_plan(_profile), do: {:error, :invalid_profile}

  @spec normalize(String.t() | atom()) :: {:ok, String.t()} | {:error, :invalid_profile}
  def normalize(profile) when profile in [:epic, "epic"], do: {:ok, "epic"}
  def normalize(profile) when profile in [:legendary, "legendary"], do: {:ok, "legendary"}
  def normalize(_profile), do: {:error, :invalid_profile}

  defp positive_integer(inputs, :unit_count = key) do
    value = Map.get(inputs, key, Map.get(inputs, Atom.to_string(key)))
    if is_integer(value) and value >= 0, do: {:ok, value}, else: {:error, key}
  end

  defp positive_integer(inputs, key) do
    value = Map.get(inputs, key, Map.get(inputs, Atom.to_string(key)))
    if is_integer(value) and value > 0, do: {:ok, value}, else: {:error, key}
  end

  defp ceil_div(left, right), do: div(left + right - 1, right)
end
