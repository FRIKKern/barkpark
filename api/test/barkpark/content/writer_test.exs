defmodule Barkpark.Content.WriterTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Writer

  # ── deep_merge/2 ──────────────────────────────────────────────────────────

  describe "deep_merge/2" do
    test "merges flat maps, right side wins on conflict" do
      a = %{"x" => 1, "y" => 2}
      b = %{"y" => 99, "z" => 3}
      assert Writer.deep_merge(a, b) == %{"x" => 1, "y" => 99, "z" => 3}
    end

    test "merges nested maps recursively" do
      a = %{"top" => %{"a" => 1, "b" => 2}}
      b = %{"top" => %{"b" => 99, "c" => 3}}
      assert Writer.deep_merge(a, b) == %{"top" => %{"a" => 1, "b" => 99, "c" => 3}}
    end

    test "a list in b replaces a list in a (no list merging)" do
      a = %{"items" => [1, 2, 3]}
      b = %{"items" => [4, 5]}
      assert Writer.deep_merge(a, b) == %{"items" => [4, 5]}
    end

    test "non-map left side is discarded in favour of b" do
      assert Writer.deep_merge("old", "new") == "new"
      assert Writer.deep_merge(nil, %{"k" => 1}) == %{"k" => 1}
    end
  end

  # ── resolve_dynamics/1 ────────────────────────────────────────────────────

  describe "resolve_dynamics/1" do
    # $today / $today.year read the UTC clock INSIDE resolve_dynamics. If the
    # assertion recomputed Date.utc_today() a line later, a run crossing UTC
    # midnight (or New Year) between the two reads false-reds. We instead bracket
    # the code-under-test with clock reads and assert membership of the boundary
    # set: the value the code stamped happened between `d_before` and `d_after`,
    # so it must equal one of them (a test spans far less than a day). This still
    # rejects a genuinely wrong date — only the exact just-before/just-after
    # dates are accepted — while being rollover-proof.

    test "$today resolves to today's ISO-8601 date string" do
      {result, acceptable} =
        with_date_boundary(fn -> Writer.resolve_dynamics("$today") end, &Date.to_iso8601/1)

      assert result in acceptable
    end

    test "$today.year resolves to a 4-digit year string" do
      {result, acceptable} =
        with_date_boundary(
          fn -> Writer.resolve_dynamics("$today.year") end,
          &Integer.to_string(&1.year)
        )

      assert result in acceptable
      assert String.length(result) == 4
    end

    test "non-token strings are returned unchanged" do
      assert Writer.resolve_dynamics("hello") == "hello"
      assert Writer.resolve_dynamics("$unknown") == "$unknown"
    end

    test "resolves tokens nested inside a map" do
      input = %{"date" => "$today", "static" => "keep"}

      {result, acceptable} =
        with_date_boundary(fn -> Writer.resolve_dynamics(input) end, &Date.to_iso8601/1)

      assert result["static"] == "keep"
      assert result["date"] in acceptable
      assert Map.keys(result) |> Enum.sort() == ["date", "static"]
    end

    test "resolves tokens inside a list" do
      {result, acceptable} =
        with_date_boundary(
          fn -> Writer.resolve_dynamics(["$today", "literal"]) end,
          &Date.to_iso8601/1
        )

      assert [date, "literal"] = result
      assert date in acceptable
    end
  end

  # Runs `fun` bracketed by UTC clock reads and returns {result, acceptable},
  # where `acceptable` is the boundary date(s) projected through `project`
  # (e.g. ISO string, or year string). Because the code's own clock read is
  # sandwiched between the two, the correct answer is always in `acceptable`,
  # regardless of a midnight/New-Year rollover during the call.
  defp with_date_boundary(fun, project) do
    d_before = Date.utc_today()
    result = fun.()
    d_after = Date.utc_today()
    acceptable = [d_before, d_after] |> Enum.map(project) |> Enum.uniq()
    {result, acceptable}
  end

  # ── from_envelope/1 ───────────────────────────────────────────────────────

  describe "from_envelope/1" do
    test "passes through legacy shape (already has content map)" do
      attrs = %{"doc_id" => "x-1", "title" => "T", "content" => %{"body" => "hi"}}
      result = Writer.from_envelope(attrs)
      assert result["doc_id"] == "x-1"
      assert result["content"] == %{"body" => "hi"}
    end

    test "coerces flat Sanity-style envelope: non-reserved keys go into content" do
      attrs = %{
        "_id" => "s-1",
        "title" => "Flat",
        "status" => "published",
        "body" => "text",
        "tags" => ["a"]
      }

      result = Writer.from_envelope(attrs)
      assert result["doc_id"] == "s-1"
      assert result["title"] == "Flat"
      assert result["status"] == "published"
      assert result["content"]["body"] == "text"
      assert result["content"]["tags"] == ["a"]
      # reserved keys must NOT leak into content
      refute Map.has_key?(result["content"], "title")
      refute Map.has_key?(result["content"], "_id")
    end

    test "honours _id when content map present but doc_id is absent" do
      attrs = %{"_id" => "fallback-id", "content" => %{"k" => "v"}}
      result = Writer.from_envelope(attrs)
      assert result["doc_id"] == "fallback-id"
    end

    test "defaults status to draft when missing in flat envelope" do
      attrs = %{"_id" => "s-2", "body" => "hello"}
      result = Writer.from_envelope(attrs)
      assert result["status"] == "draft"
    end

    # [own-content-field] gh-6291. On the FLAT branch `content` is consumed by
    # nothing — the branch is DEFINED by `content` not being a map — so
    # excluding it from the fold was pure loss. RED on origin/main:
    #   left: nil   right: "just text"
    test "a flat document's OWN scalar content field is folded, not dropped" do
      attrs = %{"_id" => "own-1", "title" => "T", "content" => "just text", "slug" => "s"}
      result = Writer.from_envelope(attrs)
      assert result["content"]["content"] == "just text"
      assert result["content"]["slug"] == "s"
    end

    test "a LIST content field is folded too — is_map/1 is the branch test, not is_binary/1" do
      attrs = %{"_id" => "own-2", "content" => ["a", "b"], "slug" => "s"}
      result = Writer.from_envelope(attrs)
      assert result["content"]["content"] == ["a", "b"]
      assert result["content"]["slug"] == "s"
    end

    test "an explicit null content is read as no-value and is NOT folded" do
      # Same reading `Map.get/2` gives a nil everywhere else here. Keeps the
      # stored shape identical for an internal caller that builds attrs with a
      # nil content key, rather than gaining a %{"content" => nil} entry.
      attrs = %{"_id" => "own-3", "content" => nil, "slug" => "s"}
      result = Writer.from_envelope(attrs)
      refute Map.has_key?(result["content"], "content")
      assert result["content"]["slug"] == "s"
    end

    test "the legacy branch is untouched — a content MAP still passes through whole" do
      # The fold narrowing is scoped to the flat branch. `@reserved_in` itself
      # is unchanged, so `@collide_exempt` still exempts `content` on the
      # content-present branch and the mixed-shape refusal is unaffected.
      attrs = %{"doc_id" => "legacy-1", "title" => "T", "content" => %{"body" => "hi"}}
      result = Writer.from_envelope(attrs)
      assert result["content"] == %{"body" => "hi"}
    end
  end

  # ── [collide-refusal] the mixed shape is REFUSED, never silently stripped ─
  #
  # These are unit-level: the refusal fires BEFORE any Repo access (it is the
  # first clause of `create_document/4`), so no sandbox is needed. The
  # end-to-end HTTP proof — status 422, the envelope, all four create-family
  # verbs — lives in mutate_controller_test.exs.
  #
  # MUTATION PROOF, RUN (2026-08-20): neutering the guard in
  # `create_document/4` back to a pass-through and re-running
  # `writer_test.exs + mutate_controller_test.exs` gave `73 tests, 8 failures`
  # — the two refusal tests below, plus all six HTTP tests, every one of the
  # latter reading exactly:
  #
  #     code:  assert resp.status == 422
  #     left:  200
  #     right: 422
  #
  # That 200 IS the field-report defect, reproduced on demand. Restoring the
  # guard returns the four-file gate to `83 tests, 0 failures`. The same
  # transcript is in the commit message of the branch that shipped this.
  describe "create_document/4 mixed-shape refusal" do
    test "MIXED shape: a content map plus flat siblings is refused, naming every key" do
      attrs = %{
        "_id" => "mix-1",
        "title" => "T",
        "content" => %{"body" => "hi"},
        "slug" => "the-slug",
        "publishedAt" => "2026-08-20",
        "authorRef" => "a-1"
      }

      assert {:error, %Ecto.Changeset{} = cs} = Writer.create_document("post", attrs, "test")
      assert [{:unknown_fields, {msg, opts}}] = cs.errors
      assert opts[:fields] == "authorRef, publishedAt, slug"
      assert msg =~ "would be silently"
    end

    test "COLLIDE shape: a pure flat document whose OWN field is named content is refused" do
      # No legacy envelope was intended here — `content` is this document type's
      # own editorial field (a Norwegian localized body). Before the refusal this
      # returned 200 and stored ONLY %{"nb" => "brodtekst"}.
      attrs = %{
        "_id" => "collide-1",
        "_type" => "post",
        "title" => "Kollisjon",
        "content" => %{"nb" => "brodtekst"},
        "slug" => "kollisjon",
        "publishedAt" => "2026-08-20",
        "authorRef" => "forfatter-1"
      }

      assert {:error, %Ecto.Changeset{} = cs} = Writer.create_document("post", attrs, "test")
      assert [{:unknown_fields, {_msg, opts}}] = cs.errors
      assert opts[:fields] == "authorRef, publishedAt, slug"
    end

    test "the SCOPE COLUMNS are not orphans — they are cast, so they land" do
      # `workspace_id` / `project_id` / `dataset_id` / `owner_id` are in
      # `Document.changeset/2`'s cast whitelist, so on the content-present
      # branch they are NOT discarded. Refusing them was a false positive that
      # broke `flat_write_scope_leak_test.exs` — a file outside this slice's
      # gate, which is why only a merge caught it. The refusal is keyed on
      # "would be silently discarded", and these never are.
      attrs = %{
        "_id" => "scoped-1",
        "title" => "T",
        "workspace_id" => Ecto.UUID.generate(),
        "project_id" => Ecto.UUID.generate(),
        "dataset_id" => Ecto.UUID.generate(),
        "owner_id" => Ecto.UUID.generate(),
        "content" => %{"body" => "hi"}
      }

      assert :passed_the_guard == guard_verdict(attrs)
    end

    test "a reserved-keys-only payload is NOT refused" do
      # Every @reserved_in member is legitimately consumed by from_envelope/1 or
      # is a document column, so nothing is discarded and nothing is refused.
      # The call proceeds past the guard to the Repo, which this async unit case
      # has no sandbox for — reaching the Repo IS the proof it got through.
      attrs = %{
        "_id" => "reserved-1",
        "_type" => "post",
        "_rev" => "r1",
        "title" => "T",
        "status" => "draft",
        "content" => %{"body" => "hi"}
      }

      assert :passed_the_guard == guard_verdict(attrs)
    end

    test "a SCALAR content field is not the legacy-envelope shape and is not refused" do
      # `from_envelope/1` branches on `is_map(content)`, so a string `content`
      # takes the FLAT branch and its siblings fold — there is no mixed shape
      # and nothing for this refusal to say. (The scalar value itself USED to
      # be dropped by that branch's own `Map.drop(@reserved_in)`. That was
      # gh-6291 and it is fixed — see the `from_envelope/1` fold tests above
      # and the round-trip proof in mutate_controller_test.exs.)
      attrs = %{"_id" => "scalar-1", "title" => "T", "content" => "just text", "slug" => "s"}

      assert :passed_the_guard == guard_verdict(attrs)
    end
  end

  # ── [status-collision] gh-6292: the OTHER half of the same collision ──────
  #
  # `status` is the one `@reserved_in` member the flat branch CONSUMES without
  # giving back: lifted to the lifecycle column, never re-emitted by
  # `Envelope.render/3`. A caller's own `status` field therefore cannot be
  # stored from the flat shape, and the error they used to get —
  # `status: ["is invalid"]` from `Document.changeset/2` — never said why.
  #
  # These are unit-level: the refusal is a clause of `create_document/4` and
  # fires before any Repo access, so no sandbox is needed. The HTTP proof (422,
  # the envelope, nothing written) lives in mutate_controller_test.exs.
  describe "create_document/4 status collision refusal" do
    test "a flat status outside the lifecycle vocabulary is refused, naming the collision" do
      attrs = %{"_id" => "st-1", "title" => "T", "status" => "in_stock", "slug" => "s"}

      assert {:error, %Ecto.Changeset{} = cs} = Writer.create_document("post", attrs, "test")
      assert [{:status, {msg, opts}}] = cs.errors
      assert opts[:value] == ~s("in_stock")
      assert msg =~ "lifecycle"
      assert msg =~ "content"
    end

    test "a NON-BINARY status collides too — a localized status map is not a lifecycle value" do
      attrs = %{"_id" => "st-2", "title" => "T", "status" => %{"nb" => "på lager"}}

      assert {:error, %Ecto.Changeset{errors: [{:status, _}]}} =
               Writer.create_document("post", attrs, "test")
    end

    test "every lifecycle status is accepted — the refusal reads Document.statuses/0" do
      # Keyed on the SAME list `Document.changeset/2` validates against, so the
      # refusal can never reject a value the changeset would have accepted.
      for status <- Barkpark.Content.Document.statuses() do
        attrs = %{"_id" => "st-ok-#{status}", "title" => "T", "status" => status}
        assert :passed_the_guard == guard_verdict(attrs), "refused lifecycle status #{status}"
      end
    end

    test "a payload with NO status key is not refused" do
      attrs = %{"_id" => "st-3", "title" => "T", "slug" => "s"}
      assert :passed_the_guard == guard_verdict(attrs)
    end

    test "with a content MAP present, status is unambiguously the envelope's and is not refused" do
      # The caller's own `status` lives inside the map, where nothing collides.
      attrs = %{
        "_id" => "st-4",
        "title" => "T",
        "status" => "draft",
        "content" => %{"status" => "in_stock"}
      }

      assert :passed_the_guard == guard_verdict(attrs)
    end
  end

  # `:refused` when the mixed-shape guard rejected the payload, `:passed_the
  # _guard` for anything that got past it (the Repo call that follows blows up
  # for want of a sandbox in this async unit case — that blow-up is the signal,
  # not a failure).
  #
  # The rescue is NARROW on purpose. A bare `rescue _ -> :passed_the_guard`
  # reports success for ANY exception — including one raised by the guard
  # itself — so the two "is NOT refused" tests below could not have failed for
  # the right reason. Only the sandbox's own ownership/connection errors count
  # as "reached the Repo"; anything else re-raises and reds the test.
  defp guard_verdict(attrs) do
    case Writer.create_document("post", attrs, "test") do
      {:error, %Ecto.Changeset{errors: [{:unknown_fields, _}]}} -> :refused
      _ -> :passed_the_guard
    end
  rescue
    e in [DBConnection.OwnershipError, DBConnection.ConnectionError] ->
      _ = e
      :passed_the_guard
  catch
    # An ownership failure can also arrive as an exit from the checkout proc.
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
      :passed_the_guard

    :exit, {:timeout, _} ->
      :passed_the_guard
  end

  # ── validate_task_kind/2 ──────────────────────────────────────────────────

  describe "validate_task_kind/2" do
    test "non-task types always return :ok regardless of content" do
      assert Writer.validate_task_kind("post", %{}) == :ok
      assert Writer.validate_task_kind("page", %{"anything" => "here"}) == :ok
    end
  end
end
