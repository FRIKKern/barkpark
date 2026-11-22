defmodule Barkpark.Content.Forms.ObjectRebaseTest do
  @moduledoc """
  task-04e50efa8405b956: an object field's edit is written subfield by
  subfield onto what the store holds now.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Forms.ObjectRebase

  @schema %{
    fields: [
      %{"name" => "notes", "type" => "string"},
      %{
        "name" => "meta",
        "type" => "composite",
        "fields" => [
          %{"name" => "code", "type" => "string"},
          %{"name" => "label", "type" => "string"},
          %{
            "name" => "inner",
            "type" => "composite",
            "fields" => [
              %{"name" => "a", "type" => "string"},
              %{"name" => "b", "type" => "string"}
            ]
          }
        ]
      }
    ]
  }

  defp rebase(mine, base, theirs),
    do:
      ObjectRebase.onto(%{"meta" => mine}, %{"meta" => base}, %{"meta" => theirs}, @schema)[
        "meta"
      ]

  test "a changed subfield is written; an untouched one keeps theirs" do
    assert rebase(%{"code" => "cA", "label" => "l0"}, %{"code" => "c0", "label" => "l0"}, %{
             "code" => "c0",
             "label" => "lB"
           }) == %{"code" => "cA", "label" => "lB"}
  end

  test "a nested object is rebased subfield by subfield" do
    base = %{"inner" => %{"a" => "a0", "b" => "b0"}}
    mine = %{"inner" => %{"a" => "aA", "b" => "b0"}}
    theirs = %{"inner" => %{"a" => "a0", "b" => "bB"}}

    assert rebase(mine, base, theirs) == %{"inner" => %{"a" => "aA", "b" => "bB"}}
  end

  test "a subfield another editor added stays; one the post took off goes" do
    base = %{"code" => "c0", "label" => "l0"}
    mine = %{"label" => "l0"}
    theirs = %{"code" => "c0", "label" => "l0", "extra" => "x"}

    assert rebase(mine, base, theirs) == %{"label" => "l0", "extra" => "x"}
  end

  test "a subfield the post took off that another editor changed stays theirs" do
    assert rebase(%{"label" => "l0"}, %{"code" => "c0", "label" => "l0"}, %{
             "code" => "cB",
             "label" => "l0"
           }) == %{"code" => "cB", "label" => "l0"}
  end

  test "an untouched subfield another editor removed stays removed" do
    assert rebase(%{"code" => "cA", "label" => "l0"}, %{"code" => "c0", "label" => "l0"}, %{
             "code" => "c0"
           }) == %{"code" => "cA"}
  end

  test "not an object in all three, or not a composite field: written as posted" do
    assert ObjectRebase.onto(
             %{"meta" => %{"code" => "cA"}},
             %{},
             %{"meta" => %{"x" => 1}},
             @schema
           ) ==
             %{"meta" => %{"code" => "cA"}}

    assert ObjectRebase.onto(%{"notes" => "nA"}, %{"notes" => "n0"}, %{"notes" => "nB"}, @schema) ==
             %{"notes" => "nA"}
  end
end
