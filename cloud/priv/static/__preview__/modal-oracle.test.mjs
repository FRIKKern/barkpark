// modal-oracle.test.mjs — the oracle's roster predicate, without Chrome.
//
// modal-oracle.mjs refuses (exit 2, before a browser) any scenario it has no
// plan for. The account family's plan used to be granted by NAME,
// `/^account-modal/`, after the shot pipeline had moved the account seam to the
// scenario's declared `modal` field (shoot.sh column 6, mock.js MODAL_DRIVERS).
// task-31d8058ed865a3bd moved the oracle to the field. These tests pin that:
//
//   * renamed-account-scenario-is-planned — the shipped `account-modal` and
//     `account-modal-2fa-badcode` objects under names that share nothing with
//     the old prefix, the old keys DELETED so no name match can supply the plan.
//     MUTANT: restoring `/^account-modal/.test(s)` in hasPlan reds this test.
//   * prefix-without-a-driver-is-not-planned — the other direction: a name in
//     the old prefix that declares no account driver is refused. Proves the
//     convention is GONE, not widened into "name OR field".
//   * shipped-roster-unchanged — the planned set over the real corpus, quoted
//     from the old predicate on origin/main c0994c66a before the change, so the
//     move cannot silently drop or add a state.
//
// ─────── history
// 2026-09-24  created (task-31d8058ed865a3bd).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SCENARIOS } from './scenarios.mjs';
import { hasPlan, plannedRoster, DEFAULT_SCEN } from './modal-oracle.mjs';

const rename = (from, to) => {
  const out = { ...SCENARIOS, [to]: SCENARIOS[from] };
  delete out[from];
  return out;
};

test('renamed-account-scenario-is-planned: the account family is the modal field, not the name', () => {
  for (const [from, to] of [
    ['account-modal', 'identity-sheet'],
    ['account-modal-2fa-badcode', 'twofactor-rejected-code'],
  ]) {
    assert.ok(SCENARIOS[from], `fixture source ${from} is gone from scenarios.mjs`);
    const renamed = rename(from, to);
    assert.equal(renamed[from], undefined, `precondition: ${from} must be deleted from the fixture`);
    assert.equal(
      hasPlan(to, renamed),
      true,
      `${to} (the shipped ${from}, modal=${JSON.stringify(SCENARIOS[from].modal)}) was refused ` +
        'UNPLANNED — the oracle is granting the account plan by NAME again',
    );
  }
});

test('prefix-without-a-driver-is-not-planned: the name convention is gone, not widened', () => {
  const impostor = 'account-modal-no-driver';
  const { modal, ...noDriver } = SCENARIOS['account-modal'];
  assert.equal(modal, 'account', 'precondition: the source fixture declares the account driver');
  const fixture = { ...SCENARIOS, [impostor]: noDriver };
  assert.equal(
    hasPlan(impostor, fixture),
    false,
    `${impostor} declares no modal driver and was planned anyway — the account-modal* prefix is granting a plan`,
  );
  // And a name the corpus does not carry at all is never planned.
  assert.equal(hasPlan('account-modal-not-a-key'), false);
});

test('shipped-roster-unchanged: the same 13 states are planned as under the name predicate', () => {
  assert.deepEqual(plannedRoster(), [
    'account-modal',
    'account-modal-2fa-badcode',
    'account-modal-2fa-on',
    'account-modal-cruel-identity',
    'account-modal-me-unreadable',
    'account-modal-revoke',
    'account-modal-tall',
    'instance-pin-version',
    'instance-update-conflict',
    'mixed-fleet',
    'overview-attention',
    'tokens-reveal',
    'tokens-revoke',
  ]);
  const unplannedDefaults = DEFAULT_SCEN.filter((s) => !hasPlan(s));
  assert.deepEqual(unplannedDefaults, [], 'a DEFAULT_SCEN entry would be refused by the roster guard');
});
