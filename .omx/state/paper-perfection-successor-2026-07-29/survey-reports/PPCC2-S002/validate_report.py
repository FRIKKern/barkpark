#!/usr/bin/env python3
"""Validate the immutable PPCC2-S002 read-only survey report against its authority."""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
AUTHORITY = Path('/Volumes/SATECHI/github/barkpark/.omx/state/paper-perfection-successor-2026-07-29/survey-authority/assignments/PPCC2-S002.json')
RECEIPT = Path('/Volumes/SATECHI/github/barkpark/.omx/state/paper-perfection-successor-2026-07-29/survey-cycle/assignment-receipts/PPCC2-S002.json')
EXPECTED_ASSIGNMENT_SHA = '62c0e37569230c61a8a93bf2c2778f5e1f8a50bdca33c7f5803ff2e4b54d78ab'
ALLOWED_VERDICTS = {'keep', 'repair', 'merge-candidate', 'superseded', 'blocked'}
READER_SURFACES = {'Studio', 'TUI80', 'email', 'public', 'CLI/API'}
REQUIRED_EDITORIAL_FIELDS = {
    'purpose_and_larger_goal', 'opening_and_criteria', 'outline_and_hierarchy',
    'human_voice_and_precision', 'compression_and_restraint', 'evidence_and_truth',
    'duplicate_disposition', 'rationale'
}


def load(path: Path):
    return json.loads(path.read_text())


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    checks: list[dict[str, object]] = []

    def check(name: str, condition: bool, evidence: object) -> None:
        checks.append({'name': name, 'status': 'PASS' if condition else 'FAIL', 'evidence': evidence})

    assignment = load(AUTHORITY)
    receipt = load(RECEIPT)
    report = load(HERE / 'report.json')
    index = load(HERE / 'readback-index.json')

    check('assignment-sha', sha256(AUTHORITY) == EXPECTED_ASSIGNMENT_SHA, sha256(AUTHORITY))
    check('assignment-identity', assignment['assignment_id'] == 'PPCC2-S002' and assignment['unit_count'] == 10, {'assignment_id': assignment['assignment_id'], 'unit_count': assignment['unit_count']})
    check('report-identity', report.get('assignment_id') == 'PPCC2-S002' and report.get('phase') == 'survey' and report.get('agent_type') == 'epic-surveyor', {'assignment_id': report.get('assignment_id'), 'phase': report.get('phase'), 'agent_type': report.get('agent_type')})
    check('ordered-checked-unit-ids', report.get('checked_unit_ids') == assignment['unit_ids'], report.get('checked_unit_ids'))

    unit_verdicts = report.get('unit_verdicts', [])
    check('one-verdict-per-unit', len(unit_verdicts) == assignment['unit_count'] and [v.get('unit_id') for v in unit_verdicts] == assignment['unit_ids'], len(unit_verdicts))
    verdict_by_id = {v.get('unit_id'): v for v in unit_verdicts}
    assignment_by_id = {u['unit_id']: u for u in assignment['units']}
    metadata_ok = all(
        uid in verdict_by_id
        and verdict_by_id[uid].get('document_id') == unit['document_id']
        and verdict_by_id[uid].get('document_rev') == unit['document_rev']
        for uid, unit in assignment_by_id.items()
    )
    check('verdict-metadata-pinned', metadata_ok, 'document_id/document_rev match all 10 assignment units')
    check('allowed-verdicts', all(v.get('verdict') in ALLOWED_VERDICTS for v in unit_verdicts), [v.get('verdict') for v in unit_verdicts])
    check('editorial-dimensions-complete', all(REQUIRED_EDITORIAL_FIELDS <= set(v) and all(isinstance(v[f], str) and v[f].strip() for f in REQUIRED_EDITORIAL_FIELDS) for v in unit_verdicts), sorted(REQUIRED_EDITORIAL_FIELDS))
    check('specific-best-and-failure-evidence', all(v.get('best_pattern_evidence') and v.get('failure_evidence') and all(e.get('block_ref','').startswith('blocks[') and e.get('evidence','').strip() for e in v['best_pattern_evidence'] + v['failure_evidence']) for v in unit_verdicts), 'nonempty block_ref/evidence for every unit')
    check('five-reader-risks', all(READER_SURFACES <= {risk.split(':', 1)[0] for risk in v.get('reader_risks', [])} for v in unit_verdicts), sorted(READER_SURFACES))

    attestation = report.get('mutation_attestation', {})
    check('false-mutation-attestations', attestation.get('production_papers_mutated') is False and attestation.get('cyclefleet_mutated') is False, attestation)
    check('unvisited-scope-empty', report.get('unvisited_scope') == [], report.get('unvisited_scope'))

    reads = index.get('reads', [])
    check('readback-count', index.get('all_pinned_revisions_read') is True and index.get('count') == 10 and len(reads) == 10, {'count': index.get('count'), 'all_pinned_revisions_read': index.get('all_pinned_revisions_read')})
    read_by_id = {r['document_id']: r for r in reads}
    readbacks_ok = True
    for unit in assignment['units']:
        path = HERE / 'readbacks' / f"{unit['document_id']}.json"
        raw = load(path)
        row = read_by_id.get(unit['document_id'], {})
        readbacks_ok = readbacks_ok and raw.get('_id') == unit['document_id'] and raw.get('_rev') == unit['document_rev'] and row.get('document_rev') == unit['document_rev'] and row.get('readback_sha256') == sha256(path)
    check('readbacks-exact-and-hashed', readbacks_ok, 'all _id/_rev and SHA-256 receipts match')

    snapshot = receipt.get('assignment', {}).get('snapshot', {})
    binding = report.get('cyclefleet_binding', {})
    binding_ok = (
        snapshot.get('status') == 'cyclefleet_bound'
        and snapshot.get('source_snapshot', {}).get('sha256') == EXPECTED_ASSIGNMENT_SHA
        and snapshot.get('unit_ids') == assignment['unit_ids']
        and snapshot.get('authority', {}).get('wave_revision') == binding.get('live_wave_revision')
        and receipt.get('assignment', {}).get('cycle_assignment_id') == binding.get('cycle_assignment_id')
        and receipt.get('assignment', {}).get('inventory_digest') == binding.get('inventory_digest')
    )
    check('immutable-cyclefleet-binding', binding_ok, binding)

    valid = all(c['status'] == 'PASS' for c in checks)
    result = {
        'schema_version': 'paper-perfection-successor-survey-report-validation/v1',
        'assignment_id': 'PPCC2-S002',
        'valid': valid,
        'checks': checks,
        'summary': {'pass': sum(c['status'] == 'PASS' for c in checks), 'fail': sum(c['status'] == 'FAIL' for c in checks)}
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if valid else 1


if __name__ == '__main__':
    sys.exit(main())
