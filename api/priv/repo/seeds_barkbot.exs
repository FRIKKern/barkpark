# BarkBot seed data for development
import Ecto.Query
alias Barkpark.Repo
alias Barkpark.Plugins.Barkbot.Bot

# Get existing workspace (assuming one exists from core seeds)
case Repo.all(from w in "workspaces", select: w.id, limit: 1) do
  [workspace_id | _] ->
    # Create a mock bot for testing
    %Bot{
      id: Ecto.UUID.generate(),
      bot_id: "mock-demo-bot",
      name: "Demo BarkBot",
      description: "A demonstration bot using the mock executor",
      provider: "mock",
      model: "demo-model",
      workspace_id: workspace_id,
      hostname: "demo.barkbot.local",
      cpu_cores: 4,
      memory_gb: 16,
      location: "Local Development",
      status: "active",
      enabled: true,
      max_concurrent_jobs: 2,
      timeout_seconds: 300,
      system_prompt: "You are a helpful AI assistant running on BarkBot."
    }
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:bot_id, :workspace_id])

    IO.puts("✓ Seeded BarkBot demo data")

  [] ->
    IO.puts("⚠ No workspaces found, skipping BarkBot seed")
end
