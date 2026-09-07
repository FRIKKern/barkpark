defmodule BarkparkWeb.MutateCriterionWhitespaceTest do
  @moduledoc """
  pds-bl-stamp-trailing-newline-deadend, THE DOOR ARMS.

  `Barkpark.Tasks.ValidationTest` pins the rule as a pure function. This file
  pins it where authors actually meet it — `POST /v1/data/mutate/<ds>` — and,
  more importantly, pins the ONE consequence that made the placement a
  judgement call rather than an obvious win.

  ## The dead end

  A criterion's stored wording is the CAS key every met-flip is guarded by:
  `Tasks.Internal` compares it with `==`, and it must, because an unguarded
  index is the false-done vector D56 closed. But POSIX command substitution
  (`$(cat file)`) strips ALL trailing newlines, so a criterion authored with
  one can be REFUSED forever and stamped never.
  `scripts/pds-crown-stamp.sh`'s `criterion_to_file()` already detects the
  shape and honestly refuses; a refusal is not a way through. The fix is at the
  authoring door, and the matching code is untouched — relaxing `==` to a
  trimmed compare would buy a way through at the price of a SILENT neighbour
  match, which the row forbids in as many words.

  ## The consequence, pinned rather than discovered later

  `/v1/data/mutate`'s patch clauses MERGE before they validate, so the rule
  sees the whole merged document and not just the fields a caller sent. A row
  that already carried a bad criterion therefore 422s on a patch to an
  UNRELATED field — the rule is RETROACTIVE. Two things make that acceptable
  where it was not acceptable for the birth-side disposition fence
  (`Content.Writer`, PDS-D393):

    * the population is empty — 0 of 35,603 criteria strings across all 8,309
      live task rows carry leading or trailing whitespace (2026-09-07); and
    * the state is SELF-HEALING — the patch that fixes the wording carries the
      fixed wording, so it validates and lands.

  `retroactive` and `self-heal` below are the two halves of that claim, and
  `control` is what makes the first one mean anything: the same unrelated-field
  patch on a CLEAN row lands 200, so the refusal is attributable to the
  criterion and not to the patch shape.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2, select: 3]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-mutate-crit-ws"
  @dataset "production"
  @dirty "ships the thing\n"
  @clean "ships the thing"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-mutate-crit-ws", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp authed do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A create lands as `drafts.<id>` until it is published, and every arm here
  # works on unpublished rows. Matching the bare id alone silently found
  # NOTHING — which made the "persists nothing" assertion below pass for the
  # wrong reason. Both ids, one predicate, used by every reader in this file.
  defp either_id(query, id) do
    from(d in query, where: d.doc_id == ^id or d.doc_id == ^"drafts.#{id}")
  end

  defp criteria(text), do: [%{"criterion" => text, "met" => false}]

  defp mk_task!(scope, criterion_text) do
    id = uniq("mcws")

    content = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "note" => "before",
      "acceptance_criteria" => criteria(criterion_text)
    }

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => id, "title" => id, "content" => content},
        @dataset,
        scope
      )

    id
  end

  # Plant the shape the door now refuses. Deliberately a RAW `Repo.update_all`:
  # the point of the retroactive arm is a row that ALREADY carries the wording,
  # and every supported write path would (correctly) refuse to create one.
  defp plant_dirty_criterion!(id) do
    {1, _} =
      Document
      |> either_id(id)
      |> Repo.update_all(
        set: [
          content: %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "note" => "before",
            "acceptance_criteria" => criteria(@dirty)
          }
        ]
      )

    :ok
  end

  defp post_patch(id, set_fields) do
    post(
      authed(),
      "/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{
        "mutations" => [%{"patch" => %{"id" => id, "type" => "task", "set" => set_fields}}]
      })
    )
  end

  defp stored_criterion(id) do
    Document
    |> either_id(id)
    |> select([d], d.content)
    |> Repo.one()
    |> Map.fetch!("acceptance_criteria")
    |> hd()
    |> Map.fetch!("criterion")
  end

  describe "the authoring door" do
    test "a create carrying a trailing-newline criterion is refused and persists nothing" do
      id = uniq("mcws-create")

      resp =
        post(
          authed(),
          "/v1/data/mutate/#{@dataset}",
          Jason.encode!(%{
            "mutations" => [
              %{
                "create" => %{
                  "_id" => id,
                  "_type" => "task",
                  "title" => id,
                  "kind" => "task",
                  "lifecycle_status" => "open",
                  "acceptance_criteria" => criteria(@dirty)
                }
              }
            ]
          })
        )

      refute resp.status == 200,
             "an unstampable criterion must not be born: #{resp.resp_body}"

      assert resp.resp_body =~ "begins or ends with whitespace"

      refute Document |> either_id(id) |> Repo.exists?(),
             "the refusal must be side-effect-free"
    end

    test "a create carrying a clean criterion still lands (the control)", %{scope: _scope} do
      id = uniq("mcws-ok")

      resp =
        post(
          authed(),
          "/v1/data/mutate/#{@dataset}",
          Jason.encode!(%{
            "mutations" => [
              %{
                "create" => %{
                  "_id" => id,
                  "_type" => "task",
                  "title" => id,
                  "kind" => "task",
                  "lifecycle_status" => "open",
                  "acceptance_criteria" => criteria(@clean)
                }
              }
            ]
          })
        )

      assert resp.status == 200, resp.resp_body

      # NON-VACUITY for the arm above: the same predicate that reported "no row
      # persisted" for the refused create MUST be able to find a row that did
      # persist. Without this, that refute passes even if the predicate is
      # broken — which is exactly how it passed the first time this file ran.
      assert Document |> either_id(id) |> Repo.exists?(),
             "either_id/2 must actually find a persisted row"
    end
  end

  describe "retroactivity — stated, not discovered" do
    test "control: an unrelated-field patch on a CLEAN row lands", %{scope: scope} do
      id = mk_task!(scope, @clean)

      resp = post_patch(id, %{"note" => "after"})

      assert resp.status == 200,
             "the patch shape itself must be fine, or the refusal below proves nothing: " <>
               resp.resp_body
    end

    test "a row already carrying the wording 422s on an UNRELATED patch", %{scope: scope} do
      id = mk_task!(scope, @clean)
      :ok = plant_dirty_criterion!(id)

      resp = post_patch(id, %{"note" => "after"})

      refute resp.status == 200,
             "merge-before-validate means the stored criterion is in scope: #{resp.resp_body}"

      assert resp.resp_body =~ "begins or ends with whitespace"
    end

    test "SELF-HEAL: the patch that fixes the wording lands, and the row is free after",
         %{scope: scope} do
      id = mk_task!(scope, @clean)
      :ok = plant_dirty_criterion!(id)

      heal = post_patch(id, %{"acceptance_criteria" => criteria(@clean)})

      assert heal.status == 200,
             "a stuck row must have a way out that does not need a migration: #{heal.resp_body}"

      assert stored_criterion(id) == @clean

      # And the unrelated patch that was refused a moment ago now lands, which
      # is what makes this a delay rather than a brick.
      after_heal = post_patch(id, %{"note" => "after"})
      assert after_heal.status == 200, after_heal.resp_body
    end
  end
end
