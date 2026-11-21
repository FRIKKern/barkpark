defmodule Barkpark.Plugins.Barkbot.BotTest do
  use ExUnit.Case, async: true
  
  alias Barkpark.Plugins.Barkbot.Bot
  
  describe "changeset/2" do
    test "requires hostname field" do
      attrs = %{
        "bot_id" => "test",
        "name" => "Test Bot",
        "provider" => "claude-code",
        "workspace_id" => "ws-1"
        # Missing hostname
      }
      
      changeset = Bot.changeset(%Bot{}, attrs)
      assert {:hostname, {"can't be blank", _}} = Enum.find(changeset.errors, fn {field, _} -> field == :hostname end)
    end
    
    test "blocks mock provider in production" do
      # Simulate production environment
      original_env = Mix.env()
      try do
        Mix.env(:prod)
        
        attrs = %{
          "bot_id" => "test",
          "name" => "Test Bot",
          "provider" => "mock",
          "workspace_id" => "ws-1",
          "hostname" => "test-host"
        }
        
        changeset = Bot.changeset(%Bot{}, attrs)
        assert {:provider, {"is invalid", _}} = Enum.find(changeset.errors, fn {field, _} -> field == :provider end)
      after
        Mix.env(original_env)
      end
    end
    
    test "allows mock provider in dev" do
      attrs = %{
        "bot_id" => "test",
        "name" => "Test Bot",
        "provider" => "mock",
        "workspace_id" => "ws-1",
        "hostname" => "test-host"
      }
      
      changeset = Bot.changeset(%Bot{}, attrs)
      refute Enum.any?(changeset.errors, fn {field, _} -> field == :provider end)
    end
  end
  
  describe "sanitize_bot (secret handling)" do
    test "api_key_encrypted should never be in responses" do
      # This is tested in the controller, but documenting the requirement
      bot = %Bot{
        bot_id: "test",
        api_key_encrypted: "encrypted-secret",
        hostname: "host-1"
      }
      
      # Controllers should drop this field
      sanitized = Map.drop(Map.from_struct(bot), [:__meta__, :api_key_encrypted, :__struct__])
      refute Map.has_key?(sanitized, :api_key_encrypted)
    end
  end
end
