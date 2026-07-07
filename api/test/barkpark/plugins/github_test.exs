defmodule Barkpark.Plugins.GithubAdoptWiringTest do
  @moduledoc """
  Wave-4 wiring contract on `Barkpark.Plugins.Github`: the adopt route is
  registered on the `:token` bucket, `github adopt` falls out of the CLI
  manifest, the `github_adopt` action handler is present, and the Studio "Adopt
  from GitHub" doc action is surfaced ONLY for a `task` whose
  `content.github.state == "intake"` (string- and atom-key safe). Pure — no DB.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Github

  describe "register_routes/1" do
    test "mounts the adopt route on the :token bucket" do
      routes = Github.register_routes(%{})

      assert {:post, "/github/adopt/:id", BarkparkWeb.GithubAdoptController, :adopt, auth: :token} in routes
    end

    test "still mounts the webhook route (no regression)" do
      routes = Github.register_routes(%{})

      assert Enum.any?(routes, fn
               {:post, "/github/webhook", _, :receive, _} -> true
               _ -> false
             end)
    end
  end

  describe "cli_commands/0" do
    test "delegates the github adopt verb into the manifest" do
      cmd = Enum.find(Github.cli_commands(), &(&1.id == "github.adopt"))

      assert cmd
      assert cmd.noun == "github"
      assert cmd.verb == "adopt"
      assert cmd.http == %{method: "POST", path_template: "/v1/plugins/github/adopt/:id"}
      assert cmd.auth_tier == "read"
      assert cmd.writes == true
      assert [%{name: "id", required: true, type: "string"} | _] = cmd.args
      assert Enum.any?(cmd.flags, &(&1.name == "dataset" and &1.default == "production"))
    end

    test "delegates the read-only github status verb into the manifest (Wave 6)" do
      cmd = Enum.find(Github.cli_commands(), &(&1.id == "github.status"))

      assert cmd
      assert cmd.noun == "github"
      assert cmd.verb == "status"
      assert cmd.http == %{method: "GET", path_template: "/v1/plugins/github/status"}
      assert cmd.auth_tier == "read"
      # Read-only — the flagship D5 invariant on the observability surface.
      assert cmd.writes == false
      assert cmd.args == []
      assert Enum.any?(cmd.flags, &(&1.name == "dataset"))
    end
  end

  describe "action_handlers/0" do
    test "registers github_adopt" do
      handlers = Github.action_handlers()
      assert is_function(handlers["github_adopt"], 3)
    end
  end

  describe "resolve_doc_actions/2" do
    @adopt_action %{
      "name" => "github_adopt",
      "label" => "Adopt from GitHub",
      "kind" => "modal",
      "modal" => %{
        "title" => "Adopt from GitHub?",
        "body" =>
          "Adopting flips this GitHub intake task into Barkpark ownership: it drops the needs-human gate, keeps the src:github provenance, and posts a backlink on the source issue. It does NOT claim the task — a worker claims it afterward through the normal bp task path. Confirm to adopt (idempotent — repeating is a safe no-op)."
      },
      "icon" => "github"
    }

    defp intake_ctx(content) do
      %{doc_type: "task", doc: %{content: content}}
    end

    test "appends the adopt action for an intake task (string-keyed content)" do
      ctx = %{doc_type: "task", doc: %{"content" => %{"github" => %{"state" => "intake"}}}}
      assert Github.resolve_doc_actions([], ctx) == [@adopt_action]
    end

    test "appends the adopt action for an intake task (fully atom-keyed content)" do
      ctx = %{doc_type: "task", doc: %{content: %{github: %{state: "intake"}}}}
      assert Github.resolve_doc_actions([], ctx) == [@adopt_action]
    end

    test "appends after preserving existing actions" do
      ctx = intake_ctx(%{"github" => %{"state" => "intake"}})
      prev = [%{"name" => "delete-doc"}]
      assert Github.resolve_doc_actions(prev, ctx) == prev ++ [@adopt_action]
    end

    test "does NOT append for an already-adopted task" do
      ctx = intake_ctx(%{"github" => %{"state" => "adopted"}})
      assert Github.resolve_doc_actions([], ctx) == []
    end

    test "does NOT append for a plain task (no github map)" do
      ctx = intake_ctx(%{"lifecycle_status" => "open"})
      assert Github.resolve_doc_actions([], ctx) == []
    end

    test "does NOT append for a non-task doc even at intake state" do
      ctx = %{doc_type: "post", doc: %{"content" => %{"github" => %{"state" => "intake"}}}}
      assert Github.resolve_doc_actions([], ctx) == []
    end

    test "leaves the list untouched when ctx has no doc" do
      assert Github.resolve_doc_actions([%{"name" => "x"}], %{doc_type: "task"}) == [
               %{"name" => "x"}
             ]
    end
  end
end
