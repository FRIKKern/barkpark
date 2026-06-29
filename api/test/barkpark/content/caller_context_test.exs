defmodule Barkpark.Content.CallerContextTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.CallerContext

  describe "from_conn/1 resolution order" do
    test "uses a pre-assigned :caller_context verbatim" do
      ctx = %CallerContext{principal_type: :user, user_id: "u-1", is_admin: true}
      assert CallerContext.from_conn(%{assigns: %{caller_context: ctx}}) == ctx
    end

    test "derives from an :api_token assign — admin token yields is_admin: true" do
      token = %{id: "tok-1", permissions: ["read", "admin"]}
      ctx = CallerContext.from_conn(%{assigns: %{api_token: token}})

      assert ctx.principal_type == :api_token
      assert ctx.token_id == "tok-1"
      assert ctx.is_admin
    end

    test "non-admin :api_token yields a non-admin context" do
      token = %{id: "tok-2", permissions: ["read"]}
      ctx = CallerContext.from_conn(%{assigns: %{api_token: token}})

      assert ctx.principal_type == :api_token
      refute ctx.is_admin
    end

    test "a pre-assigned caller_context wins over an :api_token assign" do
      ctx = %CallerContext{principal_type: :user, user_id: "u-9"}
      token = %{id: "tok-3", permissions: ["admin"]}

      assert CallerContext.from_conn(%{assigns: %{caller_context: ctx, api_token: token}}) == ctx
    end

    test "no caller_context and no token yields anonymous" do
      ctx = CallerContext.from_conn(%{assigns: %{}})
      assert ctx == CallerContext.anonymous()
      assert ctx.principal_type == :anonymous
      refute ctx.is_admin
    end
  end
end
