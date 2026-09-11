<!-- doc-tier: agent | canonical-for: barkpark-writing | budget: 1600tok -->
# Writing standard

Barkpark uses plain, specific language in everything it authors. Readers should understand what something does, why it matters to them, and what they can do next. This standard applies from the first draft, without a separate skill invocation.

It covers agent replies, plans, tasks, Papers, documentation, comments, commit messages, pull requests, reviews, release notes, websites, Studio, TUI, CLI output, and email. Contributors and agents use the same standard. Product-specific contracts may add requirements for their readers and formats.

## Start with the reader

Lead with the answer, observable change, or action. Give enough context to understand it, then the evidence and any limitation that affects the reader's decision. Match the detail to the task. A one-line answer can be complete; a complex decision may need several paragraphs and examples.

Use familiar words, concrete subjects, and verbs that say what happens. Name the actor when it matters. Keep necessary technical terms and explain unfamiliar ones. Use the same name for the same thing throughout. Write complete sentences in prose; keep buttons, labels, and table cells short when their context supplies the meaning.

## Make every claim useful

- Describe behavior, conditions, and consequences. Replace broad praise with the specific change a reader can observe.
- Support factual claims with an identifiable source, a relevant check, or a measurement. Preserve uncertainty when the evidence is incomplete. Distinguish a proposal, an inference, and a verified result.
- Explain errors with what happened and an available next action. State whether work was saved or changed only when the implementation proves it. Keep secrets and sensitive internals out of messages.
- Explain technical choices through the problem they solve and their tradeoffs. Prefer names that describe the domain. A new abstraction needs a concrete responsibility and a reason existing code cannot serve it. Writing alone cannot prove behavior; use the repository's engineering and verification rules.

## Remove habits that obscure meaning

Cut empty introductions, praise of the question or plan, repeated conclusions, promotional claims, and offers to continue work that is already requested. Report progress through findings, decisions, evidence, and the next useful action.

Replace fashionable jargon, vague metaphors, invented compound labels, and inflated synonyms with the actual thing or action. Avoid decorative comparisons, forced groups of three, and repeated rhetorical formulas. Do not introduce an irrelevant alternative just to make the chosen approach sound better.

Prefer sentences that read naturally on the first pass. Split a sentence when its clauses make the reader backtrack. Remove filler and redundant qualifiers; keep conditions and caveats that change the meaning. Do not compress prose into dropped articles, unexplained abbreviations, arrows, or fragments that readers must decode.

Use sentence case for headings. Add headings, lists, tables, diagrams, and emphasis when they help navigation or comparison. Avoid bold labels that repeat the sentence, decorative emoji, and punctuation used for dramatic effect. Let related sentences form paragraphs. Do not turn every sentence into its own section.

## Preserve the facts and the format

An editing pass must preserve meaning, intended tone, commitments, numbers, units, scope, qualifications, and source attribution. Do not invent a fact to make a sentence more specific. If evidence is missing, narrow the claim, name the gap, or remove the claim.

Preserve literal quotations, code, commands, paths, URLs, identifiers, protocol fields, and required output formats. Technical words with a precise domain meaning stay when they are the clearest choice. Follow the language and typography of the locale. Style preferences do not justify changing an API, weakening a security instruction, or falsifying a historical record.

Apply this standard to new and changed text during ordinary work. Edit existing text when it is relevant to the task. A project-wide rewrite needs its own scope and verification. Existing product contracts, accessibility requirements, and evidence requirements still apply.

## Examples

These are wording examples, not claims about current behavior. Use the specific version only when its facts are verified.

| Context | Vague or difficult | Clear and specific |
|---|---|---|
| Product copy | Seamlessly unlock your content's potential. | Publish an article from Studio. |
| Error | An unexpected issue occurred. | The upload failed. Check your connection and try again. |
| Progress | We are making significant progress on robustness. | The retry test passes. I am checking what happens when the connection drops. |
| Review | This introduces a problematic abstraction. | This helper has one caller and only renames the arguments. Inline it so the reader can follow the request. |
| Verification | Parser rejects bad date → exit 2, no write. | The parser rejects an invalid date, exits with code 2, and writes nothing. |

## Review before delivery

Read the text once for meaning and once for unnecessary wording. Check that the reader can identify the answer or action, that the claims match the evidence, and that the edit preserved all material facts and literal content. Fix repetition, unexplained terms, and formulas that hide the point. A word blacklist cannot replace this review.

Authors apply this pass before sending or publishing. Reviewers use it for prose and product copy alongside behavior, accessibility, and tests. Completion reports state the result, relevant validation, and any remaining gap without repeating the work log.

## Foundation

This is Barkpark's own standard, informed by [pstack's unslop skill](https://github.com/cursor/plugins/blob/e8d856f0273b42ebafe0ec3546bd645709e7c1b0/pstack/skills/unslop/SKILL.md) by Lauren Tan, reviewed on 2026-09-08. The upstream skill is [MIT licensed](https://github.com/cursor/plugins/blob/e8d856f0273b42ebafe0ec3546bd645709e7c1b0/pstack/LICENSE). Barkpark maintains this adaptation locally; upstream updates need review before adoption.
