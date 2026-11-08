defmodule Barkpark.Plugins.Barkbot.AuthorizationTest do
  use ExUnit.Case, async: true
  
  alias Barkpark.Plugins.Barkbot.{Bot, Job, Authorization}
  
  describe "authorize_bot_access/2" do
    test "allows access when workspace matches" do
      conn = %{assigns: %{current_workspace: %{id: "workspace-1"}}}
      bot = %Bot{workspace_id: "workspace-1"}
      
      assert :ok = Authorization.authorize_bot_access(conn, bot)
    end
    
    test "denies access when workspace doesn't match" do
      conn = %{assigns: %{current_workspace: %{id: "workspace-1"}}}
      bot = %Bot{workspace_id: "workspace-2"}
      
      assert {:error, :forbidden} = Authorization.authorize_bot_access(conn, bot)
    end
  end
  
  describe "authorize_job_access/2" do
    test "allows access when workspace matches" do
      conn = %{assigns: %{current_workspace: %{id: "workspace-1"}}}
      job = %Job{workspace_id: "workspace-1"}
      
      assert :ok = Authorization.authorize_job_access(conn, job)
    end
    
    test "denies access when workspace doesn't match" do
      conn = %{assigns: %{current_workspace: %{id: "workspace-1"}}}
      job = %Job{workspace_id: "workspace-2"}
      
      assert {:error, :forbidden} = Authorization.authorize_job_access(conn, job)
    end
  end
  
  describe "require_admin/1" do
    test "allows when current_user_admin is true" do
      conn = %{assigns: %{current_user_admin: true}}
      assert :ok = Authorization.require_admin(conn)
    end
    
    test "allows when is_admin is true" do
      conn = %{assigns: %{is_admin: true}}
      assert :ok = Authorization.require_admin(conn)
    end
    
    test "denies when no admin flag" do
      conn = %{assigns: %{}}
      assert {:error, :forbidden} = Authorization.require_admin(conn)
    end
  end
end
