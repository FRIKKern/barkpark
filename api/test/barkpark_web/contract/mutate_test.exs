defmodule BarkparkWeb.Contract.MutateTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  setup do
    Barkpark.Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    :ok
  end

  defp do_mutate(conn, body) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/test", Jason.encode!(body))
  end

  test "batch is atomic — partial failure rolls everything back", %{conn: conn} do
    body = %{
      "mutations" => [
        %{"create" => %{"_id" => "ok-1", "_type" => "post", "title" => "ok"}},
        %{"publish" => %{"id" => "does-not-exist", "type" => "post"}}
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status in [404, 422]
    body_json = Jason.decode!(resp.resp_body)
    assert body_json["error"]["code"] in ~w(validation_failed not_found)

    # Critically: ok-1 must NOT exist
    assert {:error, :not_found} = Content.get_document("drafts.ok-1", "post", "test")
  end

  test "successful batch returns envelopes with transactionId", %{conn: conn} do
    body = %{
      "mutations" => [
        %{"create" => %{"_id" => "tx-1", "_type" => "post", "title" => "t"}}
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status == 200
    body_json = Jason.decode!(resp.resp_body)
    assert is_binary(body_json["transactionId"])

    assert [%{"id" => _, "operation" => "create", "document" => %{"_id" => _, "_type" => "post"}}] =
             body_json["results"]
  end

  test "patch with stale ifRevisionID returns 412 precondition_failed with details", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "rm-1", "title" => "v1"}, "test")

    body = %{
      "mutations" => [
        %{
          "patch" => %{
            "id" => doc.doc_id,
            "type" => "post",
            "ifRevisionID" => "wrong-rev",
            "set" => %{"title" => "v2"}
          }
        }
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status == 412
    parsed = Jason.decode!(resp.resp_body)
    assert parsed["error"]["code"] == "precondition_failed"
    assert parsed["error"]["details"]["expected"] == "wrong-rev"
    assert parsed["error"]["details"]["actual"] == doc.rev
  end

  test "patch with matching ifRevisionID succeeds", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "rm-2", "title" => "v1"}, "test")

    body = %{
      "mutations" => [
        %{
          "patch" => %{
            "id" => doc.doc_id,
            "type" => "post",
            "ifRevisionID" => doc.rev,
            "set" => %{"title" => "v2"}
          }
        }
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status == 200
  end

  test "patch unset removes a content key, leaving the rest (Phase-1B)", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "unset-1", "title" => "v1"}, "test")
    # Establish content via set, then unset one key.
    do_mutate(conn, %{
      "mutations" => [
        %{
          "patch" => %{
            "id" => doc.doc_id,
            "type" => "post",
            "set" => %{"draft" => true, "tags" => ["a"]}
          }
        }
      ]
    })

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{"patch" => %{"id" => doc.doc_id, "type" => "post", "unset" => ["draft"]}}
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    refute Map.has_key?(after_doc.content, "draft")
    assert after_doc.content["tags"] == ["a"]
  end

  test "patch set + unset in one op applies both (unset clause wins on ordering)", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "unset-2", "title" => "v1"}, "test")

    do_mutate(conn, %{
      "mutations" => [
        %{"patch" => %{"id" => doc.doc_id, "type" => "post", "set" => %{"a" => 1, "b" => 2}}}
      ]
    })

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{
            "patch" => %{
              "id" => doc.doc_id,
              "type" => "post",
              "set" => %{"c" => 3},
              "unset" => ["a"]
            }
          }
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    # set-only clause would have matched on `set` and ignored `unset`, leaving "a".
    refute Map.has_key?(after_doc.content, "a")
    assert after_doc.content["b"] == 2
    assert after_doc.content["c"] == 3
  end

  test "patch unset cannot remove promoted/system fields (title survives)", %{conn: conn} do
    {:ok, doc} =
      Content.create_document("post", %{"_id" => "unset-3", "title" => "keep-me"}, "test")

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{"patch" => %{"id" => doc.doc_id, "type" => "post", "unset" => ["title"]}}
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    assert after_doc.title == "keep-me"
  end

  test "patch inc increments a numeric field; a missing field starts from 0 (Phase-1B)", %{
    conn: conn
  } do
    {:ok, doc} = Content.create_document("post", %{"_id" => "inc-1", "title" => "v1"}, "test")

    do_mutate(conn, %{
      "mutations" => [
        %{"patch" => %{"id" => doc.doc_id, "type" => "post", "set" => %{"views" => 10}}}
      ]
    })

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{
            "patch" => %{
              "id" => doc.doc_id,
              "type" => "post",
              "inc" => %{"views" => 5, "hits" => 3}
            }
          }
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    assert after_doc.content["views"] == 15
    # `hits` did not exist — inc treats the missing value as 0.
    assert after_doc.content["hits"] == 3
  end

  test "patch dec decrements a numeric field", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "dec-1", "title" => "v1"}, "test")

    do_mutate(conn, %{
      "mutations" => [
        %{"patch" => %{"id" => doc.doc_id, "type" => "post", "set" => %{"stock" => 8}}}
      ]
    })

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{"patch" => %{"id" => doc.doc_id, "type" => "post", "dec" => %{"stock" => 3}}}
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    assert after_doc.content["stock"] == 5
  end

  test "patch set + inc compose in one op (inc reads the set value)", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "inc-2", "title" => "v1"}, "test")

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{
            "patch" => %{
              "id" => doc.doc_id,
              "type" => "post",
              "set" => %{"score" => 100},
              "inc" => %{"score" => 1}
            }
          }
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    assert after_doc.content["score"] == 101
  end

  test "patch setIfMissing fills an absent field but leaves an existing one (Phase-1B)", %{
    conn: conn
  } do
    {:ok, doc} = Content.create_document("post", %{"_id" => "sim-1", "title" => "v1"}, "test")

    do_mutate(conn, %{
      "mutations" => [
        %{"patch" => %{"id" => doc.doc_id, "type" => "post", "set" => %{"lang" => "en"}}}
      ]
    })

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{
            "patch" => %{
              "id" => doc.doc_id,
              "type" => "post",
              "setIfMissing" => %{"lang" => "no", "region" => "EU"}
            }
          }
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    # `lang` already existed — left untouched; `region` was absent — filled.
    assert after_doc.content["lang"] == "en"
    assert after_doc.content["region"] == "EU"
  end

  test "patch set + setIfMissing compose: set overrides its key, setIfMissing fills another", %{
    conn: conn
  } do
    {:ok, doc} = Content.create_document("post", %{"_id" => "sim-2", "title" => "v1"}, "test")

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{
            "patch" => %{
              "id" => doc.doc_id,
              "type" => "post",
              "setIfMissing" => %{"tier" => "free", "plan" => "basic"},
              "set" => %{"tier" => "pro"}
            }
          }
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    # set wins on `tier`; setIfMissing fills the absent `plan` (set-clause-only
    # handling would drop setIfMissing entirely, leaving `plan` unset).
    assert after_doc.content["tier"] == "pro"
    assert after_doc.content["plan"] == "basic"
  end

  test "patch append extends a list field; prepend adds to the front (Phase-1B)", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "arr-1", "title" => "v1"}, "test")

    do_mutate(conn, %{
      "mutations" => [
        %{"patch" => %{"id" => doc.doc_id, "type" => "post", "set" => %{"tags" => ["a", "b"]}}}
      ]
    })

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{
            "patch" => %{
              "id" => doc.doc_id,
              "type" => "post",
              "append" => %{"tags" => ["c"]},
              "prepend" => %{"tags" => ["z"]}
            }
          }
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    # prepend runs after append in the pipeline, both off the merged list.
    assert after_doc.content["tags"] == ["z", "a", "b", "c"]
  end

  test "patch append to a missing field creates the list; leaves a scalar untouched", %{
    conn: conn
  } do
    {:ok, doc} = Content.create_document("post", %{"_id" => "arr-2", "title" => "v1"}, "test")

    do_mutate(conn, %{
      "mutations" => [
        %{"patch" => %{"id" => doc.doc_id, "type" => "post", "set" => %{"name" => "scalar"}}}
      ]
    })

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{
            "patch" => %{
              "id" => doc.doc_id,
              "type" => "post",
              "append" => %{"fresh" => ["x"], "name" => ["y"]}
            }
          }
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    # missing `fresh` → created as the appended list.
    assert after_doc.content["fresh"] == ["x"]
    # `name` is a scalar string — append must NOT clobber it with an array.
    assert after_doc.content["name"] == "scalar"
  end

  test "delete with stale ifRevisionID returns 412", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "rm-3", "title" => "v1"}, "test")

    body = %{
      "mutations" => [
        %{"delete" => %{"id" => doc.doc_id, "type" => "post", "ifRevisionID" => "nope"}}
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status == 412
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "precondition_failed"
  end

  test "guarded delete of a draft-only doc by its canonical id succeeds (rev-guard coherence)",
       %{conn: conn} do
    # Created-but-never-published: the row exists only as drafts.rm-guard.
    {:ok, doc} = Content.create_document("post", %{"_id" => "rm-guard", "title" => "v1"}, "test")
    assert doc.doc_id == "drafts.rm-guard"

    # Delete by the PUBLISHED/canonical spelling with the draft's real rev. The
    # guard must resolve the sibling draft, not spuriously 412 on an exact-id miss.
    body = %{
      "mutations" => [
        %{"delete" => %{"id" => "rm-guard", "type" => "post", "ifRevisionID" => doc.rev}}
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status == 200
    # Both spellings gone.
    assert {:error, :not_found} = Content.get_document("rm-guard", "post", "test")
    assert {:error, :not_found} = Content.get_document("drafts.rm-guard", "post", "test")
  end

  test "guarded delete by the drafts.-prefixed id still succeeds", %{conn: conn} do
    {:ok, doc} =
      Content.create_document("post", %{"_id" => "rm-draftspell", "title" => "v1"}, "test")

    body = %{
      "mutations" => [
        %{"delete" => %{"id" => doc.doc_id, "type" => "post", "ifRevisionID" => doc.rev}}
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status == 200
    assert {:error, :not_found} = Content.get_document("drafts.rm-draftspell", "post", "test")
  end

  # ── paper hollow-body quality gate (epic p-quality-gate, charter D2) ──────
  #
  # Path A end-to-end: the mutate surface can never produce a hollow PUBLISHED
  # paper. Drafts stay free (creation must not brick); the hard stop fires at
  # the publish boundary — and at the before_save seam for any writer that
  # ever emits a published-surface payload.

  defp hollow_paper_blocks do
    [
      %{
        "id" => "tpl-title",
        "type" => "heading",
        "level" => 1,
        "role" => "title",
        "locked" => true,
        "text" => "Hollow stub"
      },
      %{"id" => "tpl-body", "type" => "paragraph", "content" => []}
    ]
  end

  defp real_paper_blocks do
    List.update_at(hollow_paper_blocks(), 1, fn body ->
      Map.put(body, "content", [%{"type" => "text", "value" => "A real body block."}])
    end)
  end

  defp create_paper_mutation(id, blocks) do
    # The publish wall (authoring-excellence) requires a compliant label spine
    # on every NEW paper publish — these tests target the hollow-body gate,
    # which fires AFTER the wall, so the fixture must pass the wall first.
    %{
      "mutations" => [
        %{
          "create" => %{
            "_id" => id,
            "_type" => "paper",
            "title" => "Hollow-gate paper",
            "content" => Barkpark.LabelFixtures.with_labels(%{"blocks" => blocks})
          }
        }
      ]
    }
  end

  defp publish_paper_mutation(id) do
    %{"mutations" => [%{"publish" => %{"id" => id, "type" => "paper"}}]}
  end

  describe "paper hollow-body quality gate" do
    setup do
      # Wire the Bulldocs plugin in so Barkpark.Plugins.Hooks fires its
      # before_save/before_publish gates deterministically (the same pattern
      # tasks_quality_gate_test.exs uses for the Tasks plugin).
      # `PluginEnv.capture/0`, not `get_env(…, [])`: on the unset boot baseline
      # a `[]` default would restore an EXPLICIT `[]`, which BootCollectors
      # reads as the discovery kill switch and leaks to later tests.
      prior = Barkpark.PluginEnv.capture()
      Application.put_env(:barkpark, :plugins, [Barkpark.Plugins.Bulldocs])
      on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)
      Barkpark.LabelFixtures.register_tags!("test")
      :ok
    end

    test "draft saves stay free: creating a hollow draft paper succeeds", %{conn: conn} do
      resp = do_mutate(conn, create_paper_mutation("hollow-draft-1", hollow_paper_blocks()))

      assert resp.status == 200
      assert {:ok, _} = Content.get_document("drafts.hollow-draft-1", "paper", "test")
    end

    test "publish op on a hollow draft paper → HTTP 409 code halted with the honest copy",
         %{conn: conn} do
      assert do_mutate(conn, create_paper_mutation("hollow-pub-1", hollow_paper_blocks())).status ==
               200

      resp = do_mutate(conn, publish_paper_mutation("hollow-pub-1"))

      assert resp.status == 409
      parsed = Jason.decode!(resp.resp_body)
      assert parsed["error"]["code"] == "halted"

      assert parsed["error"]["message"] ==
               "This paper has a title but no content yet — add at least one body block."

      # Nothing published; the draft is still there to be finished.
      assert {:error, :not_found} = Content.get_document("hollow-pub-1", "paper", "test")
      assert {:ok, _} = Content.get_document("drafts.hollow-pub-1", "paper", "test")
    end

    test "positive control: a real paper draft publishes", %{conn: conn} do
      assert do_mutate(conn, create_paper_mutation("real-pub-1", real_paper_blocks())).status ==
               200

      resp = do_mutate(conn, publish_paper_mutation("real-pub-1"))

      assert resp.status == 200
      assert {:ok, published} = Content.get_document("real-pub-1", "paper", "test")
      assert published.status == "published"
    end

    test "a published-surface hollow write is vetoed at the before_save seam → 409 halted" do
      # Every /v1/data/mutate write is draft-coerced by Content.Writer (the
      # doc_id is drafts.-prefixed and status "published" → "draft"), so no
      # HTTP mutate request can carry this payload TODAY — this pins the
      # layer-parity backstop for any writer that ever fires before_save with
      # a published-surface paper (published status or a non-drafts doc_id),
      # through the exact payload shape Writer builds and the exact envelope
      # every HTTP consumer would receive.
      payload = %{
        event: :before_save,
        doc: %{
          "doc_id" => "hollow-published-1",
          "type" => "paper",
          "status" => "published",
          "content" => %{"blocks" => hollow_paper_blocks()}
        },
        dataset: "test",
        prev_doc: nil,
        ctx: %{source: :api, user_id: nil}
      }

      assert {:halt, msg} = Barkpark.Plugins.Hooks.fire(:before_save, payload)
      assert msg == "This paper has a title but no content yet — add at least one body block."

      # Writer maps {:halt, msg} → {:error, {:halted, msg}}; the canonical
      # envelope for that is HTTP 409, code "halted", message verbatim.
      envelope = Barkpark.Content.Errors.to_envelope({:error, {:halted, msg}})
      assert envelope.status == 409
      assert envelope.code == "halted"
      assert envelope.message == msg

      # The non-drafts doc_id spelling (a publish-in-place write) is vetoed too.
      in_place =
        put_in(payload, [:doc, "status"], "draft")

      assert {:halt, _} = Barkpark.Plugins.Hooks.fire(:before_save, in_place)

      # …while the true draft spelling stays free (creation must not brick).
      draft =
        payload
        |> put_in([:doc, "doc_id"], "drafts.hollow-published-1")
        |> put_in([:doc, "status"], "draft")

      assert Barkpark.Plugins.Hooks.fire(:before_save, draft) == :ok
    end
  end

  test "If-Match HTTP header applies as ifRevisionID for single-doc mutation", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "rm-4", "title" => "v1"}, "test")

    body = %{
      "mutations" => [
        %{
          "patch" => %{
            "id" => doc.doc_id,
            "type" => "post",
            "set" => %{"title" => "v2"}
          }
        }
      ]
    }

    stale =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("if-match", ~s("not-the-rev"))
      |> post("/v1/data/mutate/test", Jason.encode!(body))

    assert stale.status == 412

    fresh =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("if-match", ~s("#{doc.rev}"))
      |> post("/v1/data/mutate/test", Jason.encode!(body))

    assert fresh.status == 200
  end

  # A single HTTP If-Match header carries ONE ETag, but a 2+-op batch touches N
  # potentially-different docs — the header cannot unambiguously target any of
  # them. The old code silently DROPPED it for multi-op batches (only the
  # [mutation] single-op head injected it), so a client's optimistic-lock intent
  # evaporated and both patches applied last-write-wins with no 412 → lost update.
  # Fail CLOSED with a 400 that steers callers to the per-op ifRevisionID/ifMatch
  # mechanism, which fences each doc unambiguously.
  test "If-Match HTTP header on a multi-op batch is rejected 400, not silently dropped",
       %{conn: conn} do
    {:ok, a} = Content.create_document("post", %{"_id" => "batch-im-a", "title" => "a1"}, "test")
    {:ok, b} = Content.create_document("post", %{"_id" => "batch-im-b", "title" => "b1"}, "test")

    body = %{
      "mutations" => [
        %{"patch" => %{"id" => a.doc_id, "type" => "post", "set" => %{"title" => "a2"}}},
        %{"patch" => %{"id" => b.doc_id, "type" => "post", "set" => %{"title" => "b2"}}}
      ]
    }

    resp =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("if-match", ~s("#{a.rev}"))
      |> post("/v1/data/mutate/test", Jason.encode!(body))

    assert resp.status == 400
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "unsupported_if_match_for_batch"

    # And the writes must NOT have applied — fail-closed, not last-write-wins.
    # A successful patch bumps the rev, so an unchanged rev proves no write ran.
    assert {:ok, still_a} = Content.get_document(a.doc_id, "post", "test")
    assert still_a.rev == a.rev
  end

  # The per-op fence is the sanctioned batch mechanism: an ifRevisionID INSIDE
  # each mutation is honored regardless of batch size (Content.Mutations.if_rev/1),
  # and no HTTP If-Match header is present, so the batch is accepted.
  test "per-op ifRevisionID fences each doc in a multi-op batch (no HTTP header)",
       %{conn: conn} do
    {:ok, a} = Content.create_document("post", %{"_id" => "batch-op-a", "title" => "a1"}, "test")
    {:ok, b} = Content.create_document("post", %{"_id" => "batch-op-b", "title" => "b1"}, "test")

    fresh = %{
      "mutations" => [
        %{
          "patch" => %{
            "id" => a.doc_id,
            "type" => "post",
            "ifRevisionID" => a.rev,
            "set" => %{"title" => "a2"}
          }
        },
        %{
          "patch" => %{
            "id" => b.doc_id,
            "type" => "post",
            "ifRevisionID" => b.rev,
            "set" => %{"title" => "b2"}
          }
        }
      ]
    }

    assert do_mutate(conn, fresh).status == 200

    stale = %{
      "mutations" => [
        %{
          "patch" => %{
            "id" => a.doc_id,
            "type" => "post",
            "ifRevisionID" => "not-the-rev",
            "set" => %{"title" => "a3"}
          }
        }
      ]
    }

    assert do_mutate(conn, stale).status == 412
  end
end
