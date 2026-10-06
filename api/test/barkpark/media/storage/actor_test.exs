defmodule Barkpark.Media.Storage.ActorTest do
  @moduledoc """
  The one checkout-lock stamp (task-36a302b2e981d5e1): an account is
  "user:<id>" (a legacy email stamp still matches it), a token is its label,
  and what a viewer is shown is never an email or a raw "user:" id.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.Storage.Actor

  @user %{id: "u-1", email: "ed@example.com"}

  test "an account session is user:<id>, with its email as a legacy alias" do
    actor = Actor.of(%{assigns: %{current_user: @user}})
    assert actor.label == "user:u-1"
    assert Actor.holds?(actor, "user:u-1")
    assert Actor.holds?(actor, "ed@example.com")
    refute Actor.holds?(actor, "user:u-2")
    refute Actor.holds?(actor, nil)
  end

  test "a token is its label and wins over an account on the same conn; nothing else is api" do
    assert Actor.of(%{assigns: %{api_token: %{label: "studio-parity"}, current_user: @user}}).label ==
             "studio-parity"

    assert Actor.of(%{assigns: %{}}).label == "api"
  end

  test "display: you, a token label, another editor; never an email or user: id" do
    me = Actor.of(%{assigns: %{current_user: @user}})
    assert Actor.display(nil, me) == nil
    assert Actor.display("", me) == nil
    assert Actor.display("user:u-1", me) == "you"
    assert Actor.display("ed@example.com", me) == "you"
    assert Actor.display("user:u-2", me) == "another editor"
    assert Actor.display("someone@example.com", me) == "another editor"
    assert Actor.display("studio-parity", me) == "studio-parity"
    assert Actor.display("user:u-2", nil) == "another editor"
  end
end
