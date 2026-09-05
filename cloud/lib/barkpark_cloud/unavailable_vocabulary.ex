defmodule BarkparkCloud.UnavailableVocabulary do
  @moduledoc """
  THE ONE DOCUMENT that states how the plane's TWO closed vocabularies for the
  same class of fact line up — "we asked a customer's box something and did not
  get an answer we could use".

  Wave 58 shipped both, on two surfaces, in two idioms, and nothing said how
  they relate:

    * `BarkparkCloud.Registry.Barkpark.update_unavailable_reasons/0` — persisted
      on `barkparks.update_unavailable_reason` by `Registry.refresh_update_status/1`.
      Its idiom is A STORED ADMIN CREDENTIAL BEING REFUTED: the words are about
      what the control plane may still spend on this box.
    * `BarkparkCloud.Usage.unavailable_reasons/0` — carried per-meter in the usage
      envelope. Its idiom is AN HTTP STATUS A PAYING CUSTOMER'S METER HAS TO
      EXPLAIN.

  Both idioms are correct where they live and NEITHER IS RENAMED HERE. What was
  missing is the mapping, and without it the third surface to need this
  vocabulary invents a third word for a fact that already has two.

  ## The mapping

  Read `facts/0`. Three shapes appear in it:

    * `:same_word` — both vocabularies already agree, letter for letter
      (`unreachable`, `bad_shape`, `instance_error`). That agreement is a
      COINCIDENCE OF TASTE, not a contract, until this table says so.
    * `:same_fact_different_word` — the pair this task is named for.
      `identity_refused` and `unauthorized` are ONE fact (the box answered, and
      it rejected the admin credential we hold) wearing two words.
    * `:one_sided` — a word one vocabulary needs and the other has no occasion
      for. Neither is a gap: `deadline_exceeded` and `too_many_datasets` are
      fan-out mechanics the single-call update probe cannot produce, and
      `no_admin_token` / `decrypt_failed` / `not_live` are control-plane
      preconditions where NO read is attempted — the meter's answer to that is
      not an unavailable reason at all, it is `unmetered`.

  ## What the pin buys, and what it does not

  `unavailable_vocabulary_census_test.exs` reds when a word appears anywhere in
  `cloud/lib` in this fact's context and is in NEITHER vocabulary — that is the
  third-surface drift this exists to stop. It does not prove the two idioms
  SHOULD merge (charter says they should not), and it does not stop either
  vocabulary from growing: it makes growth arrive HERE, in the one place that
  says what the new word means next to the other surface's word for it.
  """

  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Usage

  @typedoc "How a word relates across the two vocabularies."
  @type relation :: :same_word | :same_fact_different_word | :one_sided

  @facts [
    %{
      fact: "the box answered and rejected the admin credential we hold (401)",
      relation: :same_fact_different_word,
      registry: "identity_refused",
      usage: "unauthorized",
      note:
        "THE PAIR THIS TABLE IS NAMED FOR. The registry word is about the stored " <>
          "credential being refuted — it is what makes the plane stop spending on this " <>
          "box (see BoxRelay's dispatch refusal). The usage word is the HTTP status a " <>
          "customer's meter has to explain. One fact, two audiences."
    },
    %{
      fact: "the box answered and refused the request it was authorised to serve (403)",
      relation: :same_fact_different_word,
      registry: "forbidden",
      usage: "refused",
      note:
        "NOT an exact synonym and the difference is stated, not smoothed over: the " <>
          "registry word means 403 specifically, while the meter's `refused` is EVERY " <>
          "delivered non-2xx that is not 401 or 5xx. `forbidden` is a strict subset. A " <>
          "third surface that needs 403 alone says `forbidden`; one that needs the wider " <>
          "class says `refused`."
    },
    %{
      fact: "the box never answered (DNS, refused connection, TLS, socket close)",
      relation: :same_word,
      registry: "unreachable",
      usage: "unreachable",
      note:
        "Agreement by taste until now. Both mean NOBODY ANSWERED, and both exist so " <>
          "that a credential rejection is never reported as a network problem — telling " <>
          "a paying customer to check their network about a 401 sends them to the wrong room."
    },
    %{
      fact: "the box answered with a body we could not read",
      relation: :same_word,
      registry: "bad_shape",
      usage: "bad_shape",
      note: "Agreement by taste until now. Both mean the answer arrived and did not parse."
    },
    %{
      fact: "the box answered that it had failed on its own side (5xx)",
      relation: :same_word,
      registry: "instance_error",
      usage: "instance_error",
      note: "Agreement by taste until now. Both mean the box owned the failure."
    },
    %{
      fact: "the box answered 404 for the self-update route (an older build)",
      relation: :one_sided,
      registry: "no_self_update_route",
      usage: nil,
      note:
        "Registry-only: the meter reads no route that can 404 for a reason a customer " <>
          "would act on, and would report this as the wider `refused`."
    },
    %{
      fact: "the control plane holds no admin token for this box, so nothing was asked",
      relation: :one_sided,
      registry: "no_admin_token",
      usage: nil,
      note:
        "Registry-only BY SHAPE, not by omission. The meter's answer to `no read was " <>
          "attempted` is the deliberate `unmetered` value with NO :unavailable_reason key " <>
          "at all — a different axis, not a missing word."
    },
    %{
      fact: "the stored admin token would not decrypt, so nothing was asked",
      relation: :one_sided,
      registry: "decrypt_failed",
      usage: nil,
      note: "Registry-only, same axis as no_admin_token: no read was attempted."
    },
    %{
      fact: "the box is not live, so nothing was asked",
      relation: :one_sided,
      registry: "not_live",
      usage: nil,
      note: "Registry-only, same axis as no_admin_token: no read was attempted."
    },
    %{
      fact: "a meter read raised",
      relation: :one_sided,
      registry: nil,
      usage: "exception",
      note:
        "Usage-only: `within_deadline/2` mints it for a real raise. The update probe " <>
          "has no equivalent because its own failure surfaces as one of the rungs above."
    },
    %{
      fact: "a meter read overran its budget",
      relation: :one_sided,
      registry: nil,
      usage: "deadline_exceeded",
      note:
        "Usage-only: the meter fan-out runs under an aggregate budget. The update probe " <>
          "is one call and reports a timeout as `unreachable`."
    },
    %{
      fact: "a team has more datasets than the meter fan-out will read",
      relation: :one_sided,
      registry: nil,
      usage: "too_many_datasets",
      note: "Usage-only fan-out mechanics; the update probe fans out over nothing."
    }
  ]

  @doc """
  The mapping table. Each row names ONE fact and the word each vocabulary uses
  for it (`nil` where that vocabulary has no occasion for it).
  """
  @spec facts() :: [map()]
  def facts, do: @facts

  @doc "The Registry vocabulary, read from its owner — never a typed copy."
  @spec registry_words() :: [String.t()]
  def registry_words, do: Barkpark.update_unavailable_reasons()

  @doc "The Usage vocabulary, read from its owner — never a typed copy."
  @spec usage_words() :: [String.t()]
  def usage_words, do: Usage.unavailable_reasons()

  @doc """
  Every word EITHER vocabulary declares. A word for this fact class that is not
  in here is a third surface minting a third word, which is what the census reds on.
  """
  @spec words() :: [String.t()]
  def words, do: Enum.sort(Enum.uniq(registry_words() ++ usage_words()))

  @doc "True when `word` is named by one of the two vocabularies."
  @spec known_word?(String.t()) :: boolean()
  def known_word?(word) when is_binary(word), do: word in words()
end
