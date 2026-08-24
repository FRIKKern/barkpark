defmodule Barkpark.Content.DocumentVarcharLengthTest do
  @moduledoc """
  varchar(255) columns need a changeset length gate, or Postgres answers 500.

  `documents.doc_id`, `.type`, `.dataset` and `.title` are all Ecto `:string` in
  migration 20260412090737_create_initial_tables — `character varying(255)`. With
  no `validate_length/3` a longer value reached the insert and Postgres raised
  `Postgrex.Error ERROR 22001 (string_data_right_truncation)`, which the API
  returned as HTTP 500.

  The write itself was always handled correctly — the transaction rolls back and
  nothing persists. The CLASSIFICATION was the defect: a 500 tells the caller to
  retry, which fails identically forever, and it books a client mistake against
  the server's error rate.

  The reported instance was `title`. It is not the only one: all four columns are
  caller-supplied on the public write path (`_id` → `doc_id`, `_type` → `type`,
  the `:dataset` path segment, and `title`), so this pins the whole class. Each
  over-long insert is exercised through the NON-BANG `Repo.insert/1` that
  `Content.Writer` actually calls, so the test proves the real write path returns
  `{:error, %Ecto.Changeset{}}` (→ `validation_failed` 422) rather than raising.

  `status` is deliberately absent: `validate_inclusion` already bounds it to six
  words. `rev` is server-generated (32 hex chars).
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @over String.duplicate("X", 256)
  @at String.duplicate("X", 255)

  defp attrs(overrides) do
    suffix = System.unique_integer([:positive])

    Map.merge(
      %{doc_id: "len-#{suffix}", type: "post", dataset: "production", rev: "rev-#{suffix}"},
      overrides
    )
  end

  describe "the guard is measuring the right boundary" do
    test "256 characters is one over the column's limit" do
      assert String.length(@over) == 256
      assert String.length(@at) == 255
    end
  end

  describe "an over-long value is a changeset error, never a raise" do
    for column <- [:doc_id, :type, :dataset, :title] do
      test "#{column} at 256 characters returns {:error, changeset}, not Postgrex 22001" do
        column = unquote(column)
        changeset = Document.changeset(%Document{}, attrs(%{column => @over}))

        refute changeset.valid?,
               "#{column} at 256 chars must fail the changeset — without a length gate it " <>
                 "reaches Postgres and 22001 becomes an HTTP 500"

        assert {_msg, opts} = changeset.errors[column]
        assert opts[:validation] == :length
        assert opts[:count] == 255

        # The real write path: Content.Writer calls the NON-BANG Repo.insert/1,
        # so an unguarded over-long value RAISES out of it. This proves the
        # writer now gets a changeset back instead.
        assert {:error, %Ecto.Changeset{valid?: false}} = Repo.insert(changeset)
      end
    end
  end

  describe "the column limit this gate exists for is real" do
    # PROOF, not assertion: bypass the changeset entirely and hand Postgres the
    # over-long value. It raises 22001 — which is the HTTP 500 the row reported.
    # A Postgres error aborts the sandbox transaction, so this is its own test and
    # nothing may follow it here.
    test "a raw over-long insert raises Postgrex 22001, which is where the 500 came from" do
      doc = %Document{
        doc_id: "raw-len-#{System.unique_integer([:positive])}",
        type: "post",
        dataset: "production",
        title: @over,
        content: %{}
      }

      assert_raise Postgrex.Error, fn -> Repo.insert(doc) end
    end
  end

  describe "the limit is not moved" do
    for column <- [:doc_id, :type, :dataset, :title] do
      test "#{column} at exactly 255 characters is still accepted" do
        column = unquote(column)
        changeset = Document.changeset(%Document{}, attrs(%{column => @at}))

        assert changeset.valid?,
               "#{column} at exactly 255 chars must stay valid — the gate must not narrow the " <>
                 "column, only stop overflowing it"
      end
    end

    test "status keeps its inclusion gate and needs no length gate" do
      changeset = Document.changeset(%Document{}, attrs(%{status: @over}))
      refute changeset.valid?
      assert {_msg, opts} = changeset.errors[:status]
      assert opts[:validation] == :inclusion
    end
  end
end
