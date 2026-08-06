<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-09 | budget: 1400tok -->
# Restart Survey 09 — public negative capability and evidence strength

Assignment `restart-survey-09` re-attested `cloud-console-hardening-wave-28-2026-08-03::public` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **public content proven; provenance and accessibility partial; reliability contradicted**.

## Direct answer

Successful public reads preserve current block identity and sampled visible content. The reader does not expose the immutable Paper revision, several authored semantics are contradicted in its DOM, actual assistive-technology usability is blocked, and transient 500s contradict uniformly dependable availability.

## Fresh controls

The initial positive snapshot returned flat HTTP 200/315,953 bytes/237 block IDs, dataset HTTP 200/315,966 bytes/237 IDs, and scoped HTTP 500. Source revision is `49c1534d9fb76d0d9adc7b97f25ec471`. Source and public DOM each carried 237/237 unique block IDs with identical ordered-ID SHA-256 `a692b17d055bd261cefebe526d9ade136178ee8eac0312e9dc393befeacaaf51`; three unique content strings survived 3/3.

Missing flat, dataset, and scoped Papers returned 3/3 HTTP 404. Encoded `/papers/%2e%2e`, an invalid flat dataset query, and an invalid dataset path also returned 404. `?perspective=draft` and `?perspective=bogus` each returned HTTP 200 with the same published structure, proving arbitrary perspective queries do not select draft content.

Reliability sequences: flat 5/5 success; dataset 4/5 success plus one 500; scoped had an initial 500 followed by a recorded 5/5 success sequence, with another curl failure aborting an earlier loop. Successful physical hashes differ because request-specific session/CSRF material changes, while structural counts remain stable.

## Evidence ruling

Proven: published content selection; 237/237 unique ordered identity; sampled visible-content preservation; missing/invalid closure; basic document landmarks.

Inferred: a successful page represents revision `49c153…`, supported by exact block order and content. The HTML has zero exact revision tokens, `data-rev="0"`, and no ETag, Last-Modified, or Content-Location, so response identity does not prove the pin. Live task resolution also means identical Paper revisions need not yield immutable page bytes.

Blocked: real assistive technology, non-Chromium browsers, authenticated/draft visibility, dynamic LiveView recovery, and a live ambiguous-source mutation control.

Contradicted: immutable provenance identity; accessible data-table relationships; semantic preservation of 67 marks; faithful severity for four `warn` callouts; uniformly dependable availability. All 18 data tables use `role=presentation`, with 0/57 scoped headers and 0/18 captions. Source has 26 strong and 41 code marks, while public output has zero authored strong/code/em carriers. Thirteen callouts become visual classes without accessible severity; unsupported `warn` is normalized to informational styling.

Basic `lang`, viewport, title, H1, main, article, and all block wrappers were found. Screen-reader, focus order, zoom, forced colors, contrast, Safari, Firefox, touch, and print were not exercised. Raw DOM inspection is not an accessibility pass.

The task queue remained partially unavailable: `bp task ls --all` returned server request ID `GMkZBif9UJ82yY0AAIbS`. Transient failure cause remains unproven without server/proxy logs.

## Cycle payload

```json
{"assignment_id":"restart-survey-09","unit":"cloud-console-hardening-wave-28-2026-08-03::public","revision":"49c1534d9fb76d0d9adc7b97f25ec471","verdict":"PUBLIC_CONTENT_PROVEN_PROVENANCE_AND_ACCESSIBILITY_PARTIAL_RELIABILITY_CONTRADICTED","source_blocks":237,"ordered_block_identity":"237/237","ordered_id_sha256":"a692b17d055bd261cefebe526d9ade136178ee8eac0312e9dc393befeacaaf51","content_samples":"3/3","missing_controls":"3/3_404","invalid_dataset":"2/2_404","invalid_perspective":"2/2_published_200","flat_reliability":"5/5","dataset_reliability":"4/5","dataset_500":"1/5","scoped_recorded_reliability":"5/5","initial_scoped_status":500,"revision_carriers":"0/4","article_data_rev":"0","semantic_tables":"0/18","scoped_headers":"0/57","captions":"0/18","semantic_marks":"0/67","screen_reader_cells":0,"classifications":{"proven":5,"inferred":1,"blocked":5,"contradicted":5}}
```
