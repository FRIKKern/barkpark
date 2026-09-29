defmodule BarkparkCloud.Notifications.DeliveryContentProofTest do
  @moduledoc """
  dr-w34 — A DIGEST SEND MUST BE ABLE TO PROVE WHAT IT CONTAINED.

  `notification_deliveries` carried thirteen columns and not one of them was
  content, so a row proved an address and a transport verdict and could never
  prove a SENTENCE. The consequence was measured: the only fleet digest ever
  delivered (2026-08-09T06:00:00Z) could only be tied to its text through a prod
  git reflog, because the receipt said nothing and `cloud-postfix-1` is recreated
  on every control-plane deploy.

  ## What these tests hold, and why each one is not the weak version of itself

  A test asserting `content_sha256` is non-null would pass against a column
  filled with a constant. So:

    * §1 takes the fingerprint off the row and compares it against the
      `%Swoosh.Email{}` THE TRANSPORT ACTUALLY RECEIVED — captured out of the
      Test adapter's message, not re-rendered — and against a hash this file
      computes with its own arithmetic, so the row must agree with a second,
      independent implementation of the canonicalisation rather than with the
      one that wrote it.
    * §2 is the CONTROL: a message that differs from the delivered one by a
      single character must be REFUTED by the same row. A fingerprint that
      cannot lose proves nothing, and `content_matches?/2` is the reader that
      has to be able to say no.
    * §3 holds that the value TRACKS the render — two recipients whose digests
      say different things get different fingerprints, and the identical render
      hashes identically.
    * §4 is the QUIET arm: a send recorded without the rendered message in hand
      leaves the column NULL and says so in words. The column must not
      manufacture a fingerprint for a message nobody measured.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Registry

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "correct horse staple"})
    u
  end

  defp team(user) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    team
  end

  defp instance(team, name, slug, attrs) do
    {:ok, bp} = Registry.register_barkpark(team, %{name: name, slug: slug})

    bp
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  # THE SECOND IMPLEMENTATION. Transcribed from the contract in
  # `Delivery.content_digest/1`'s doc — version tag, then each of subject / text
  # / html as `byte_size:value`, newline-joined — and deliberately NOT a call
  # into the module under test. If the two ever disagree, one of them is wrong
  # and this file says so instead of agreeing with itself.
  defp independent_digest(%Swoosh.Email{} = email) do
    part = fn
      v when is_binary(v) -> Integer.to_string(byte_size(v)) <> ":" <> v
      _ -> "0:"
    end

    envelope =
      Enum.join(
        ["bpdlv1", part.(email.subject), part.(email.text_body), part.(email.html_body)],
        "\n"
      )

    :sha256 |> :crypto.hash(envelope) |> Base.encode16(case: :lower)
  end

  defp digest_rows do
    Delivery
    |> where([d], d.event == "fleet_digest")
    |> Repo.all()
  end

  ## 1. THE ROW MATCHES THE BYTES THAT WENT TO THE TRANSPORT.

  test "a real digest send records a fingerprint of the message the transport received" do
    n = System.unique_integer([:positive])
    owner = user("op-#{n}@example.com")
    t = team(owner)
    bp = instance(t, "Prod", "prod-#{n}", %{update_state: "behind"})

    assert {:ok, %{sent: 1, recipients: [recipient]}} = Notifications.deliver_fleet_digest([bp])

    # THE DELIVERED STRUCT, taken out of the transport seam. `Swoosh.Adapters.Test`
    # forwards the email it was handed to this process, so this is the message as
    # the adapter saw it and not a second rendering of the same summary.
    assert_receive {:email, %Swoosh.Email{} = delivered}
    assert {_name, ^recipient} = hd(delivered.to)

    assert [row] = digest_rows()
    assert row.recipient == recipient

    # Non-null is the weak assertion, so it is not the assertion: the stored
    # value must EQUAL a hash computed here, by this file's own arithmetic, over
    # the bytes the transport got.
    assert is_binary(row.content_sha256)
    assert String.length(row.content_sha256) == 64
    assert row.content_sha256 == independent_digest(delivered)

    # And the predicate a reader is actually pointed at agrees.
    assert Delivery.content_matches?(row, delivered)

    # The fingerprint is IN POSTGRES, not merely on a struct — the whole reason
    # the 2026-08-09 receipts survived the container that wrote them.
    assert %{rows: [[stored]]} =
             Repo.query!(
               "SELECT content_sha256 FROM notification_deliveries WHERE id = $1",
               [Ecto.UUID.dump!(row.id)]
             )

    assert stored == row.content_sha256
  end

  ## 2. THE CONTROL — a mismatch must be DETECTED.

  test "a message that differs by one character is REFUTED by the recorded fingerprint" do
    n = System.unique_integer([:positive])
    owner = user("op-#{n}@example.com")
    t = team(owner)
    bp = instance(t, "Prod", "prod-#{n}", %{update_state: "behind"})

    assert {:ok, %{sent: 1}} = Notifications.deliver_fleet_digest([bp])
    assert_receive {:email, %Swoosh.Email{} = delivered}
    assert [row] = digest_rows()

    # A body altered by ONE character. This is the claim "the digest said X"
    # being checked against the receipt and losing.
    tampered = %{delivered | text_body: delivered.text_body <> "."}
    refute Delivery.content_matches?(row, tampered)
    assert independent_digest(tampered) != row.content_sha256

    # A different SUBJECT loses too — the subject is inside the envelope, so a
    # message whose body is byte-identical and whose subject is not cannot pass.
    resubjected = %{delivered | subject: delivered.subject <> " (revised)"}
    refute Delivery.content_matches?(row, resubjected)

    # Length-prefixing is load-bearing: moving a character from the end of the
    # subject to the front of the body would produce the same concatenation
    # under a naive envelope. It must not verify.
    assert is_binary(delivered.subject) and byte_size(delivered.subject) > 1
    {head, tail} = String.split_at(delivered.subject, -1)
    recut = %{delivered | subject: head, text_body: tail <> delivered.text_body}
    refute Delivery.content_matches?(row, recut)

    # And the unaltered message still verifies, so the three refusals above are
    # the mutation losing rather than the comparison never winning.
    assert Delivery.content_matches?(row, delivered)
  end

  ## 3. THE VALUE TRACKS THE RENDER.

  test "different rendered digests fingerprint differently; the identical render does not" do
    n = System.unique_integer([:positive])
    owner_a = user("op-a-#{n}@example.com")
    owner_b = user("op-b-#{n}@example.com")
    team_a = team(owner_a)
    team_b = team(owner_b)

    # Two teams with DIFFERENT fleets, so the two digests say different things.
    bp_a = instance(team_a, "A", "a-#{n}", %{update_state: "behind"})
    bp_b = instance(team_b, "B1", "b1-#{n}", %{update_state: "current"})
    bp_b2 = instance(team_b, "B2", "b2-#{n}", %{update_state: "current"})

    assert {:ok, %{sent: 2}} = Notifications.deliver_fleet_digest([bp_a, bp_b, bp_b2])

    rows = digest_rows()
    assert length(rows) == 2
    fingerprints = rows |> Enum.map(& &1.content_sha256) |> Enum.uniq()

    # Two different bodies, two different fingerprints. A column filled with a
    # constant — or with a hash of something that is not the body — passes §1
    # and fails here.
    assert length(fingerprints) == 2

    # Both delivered messages, out of the transport seam.
    assert_receive {:email, %Swoosh.Email{} = first}
    assert_receive {:email, %Swoosh.Email{} = second}
    assert first.text_body != second.text_body

    # EVERY row is matched by exactly ONE of the two delivered messages. Not
    # "some row matches": a fingerprint that tracked the recipient rather than
    # the render would still produce two distinct values above, and would fail
    # to pair them here.
    for email <- [first, second] do
      assert [_one] = Enum.filter(rows, &Delivery.content_matches?(&1, email))
    end

    # The identical render hashes to the identical value, so the inequality is a
    # property of the CONTENT and not of the row, the address or the clock.
    assert Delivery.content_digest(first) == Delivery.content_digest(first)
    assert Delivery.content_digest(first) != Delivery.content_digest(second)
  end

  ## 4. THE QUIET ARM — an unfingerprinted send says so, rather than inventing one.

  test "a send recorded without the rendered message leaves the column NULL and says why" do
    n = System.unique_integer([:positive])
    owner = user("member-#{n}@example.com")
    t = team(owner)

    # `deliver_test/2` is a real send on the same rail that does NOT hand its
    # message to the receipt. The honest record of that is an absence.
    assert {:ok, _} = Notifications.deliver_test(t)

    assert [row] =
             Delivery
             |> where([d], d.event == "test")
             |> Repo.all()

    assert row.content_sha256 == nil
    refute Delivery.content_matches?(row, %Swoosh.Email{subject: "anything"})

    assert Delivery.content_proof_meaning(nil) =~ "Not fingerprinted"
    assert Delivery.content_proof_meaning(nil) =~ "cannot be proved from this row"

    # And the fingerprinted sentence is a DIFFERENT sentence — a reader that
    # renders one for both states is back to a blank caveat.
    assert Delivery.content_proof_meaning(String.duplicate("a", 64)) =~ "SHA-256"
    assert Delivery.content_proof_meaning(String.duplicate("a", 64)) =~ "not stored"
  end

  ## 5. A non-email argument never yields a fingerprint.

  test "content_digest/1 refuses anything that is not a rendered email" do
    assert Delivery.content_digest(nil) == nil
    assert Delivery.content_digest("a body") == nil
    assert Delivery.content_digest(%{subject: "s", text_body: "b"}) == nil

    # But a real one does, and a nil body is not a crash — it hashes as empty.
    assert is_binary(Delivery.content_digest(%Swoosh.Email{subject: "s", text_body: nil}))
  end
end
