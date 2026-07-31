# Re-derivation recipe — vf-react-test-green (react gate + comparator strictness + Next 16 proof)

Claims:
1. `@barkpark/react` is green at origin/main state: **15 files / 329 tests**.
2. The registry pin is **70**, the golden corpus is **60**, the parity suite is **77 tests** —
   the literal "42" survives only in stale describe-strings and `>=` floors.
3. `@barkpark/next-parity` builds under **Next 16.2.1** with `PortableDoc` as a real
   Server Component and passes **66 tests**, all 60 goldens shape-equal off built HTML.
4. `assertShapeEqual` compares tag / class-SET / `data-*` / `style`-map / collapsed
   immediate text / ordered element children. It ignores `href`/`src`/`id`/`alt`/`aria-*`
   and never resolves CSS. A drakt is invisible; an extra INNER class or extra ANCESTOR reds.

```sh
cd /Users/frikkjarl/Documents/GitHub/barkpark/js

# 0. the react/next-parity trees are identical to origin/main (no local drift)
git -C .. diff --stat HEAD origin/main -- js/packages/react js/packages/next-parity
# expect: no output

# 1. the gate
pnpm install --frozen-lockfile && pnpm --filter @barkpark/react test 2>&1 | tail -5
# expect: Test Files  15 passed (15) / Tests  329 passed (329)

# 2. the three numbers
grep -n "toHaveLength(70)" packages/react/tests/PortableDoc.test.tsx      # registry pin = 70
ls packages/react/tests/fixtures/pd-golden/*.golden.json | wc -l          # goldens = 60
grep -c "" /dev/null; pnpm --filter @barkpark/react test 2>&1 | grep "PortableDoc.parity"
# expect: ✓ tests/PortableDoc.parity.test.tsx (77 tests)

# 3. Next 16 consumption proof (jarl runs Next 16)
pnpm --filter @barkpark/next-parity build && pnpm --filter @barkpark/next-parity test 2>&1 | tail -5
# expect: ✓ Compiled successfully ... / Test Files 1 passed (1) / Tests 66 passed (66)

# 4. comparator strictness probe (scratch file, never committed)
#    A extra class on the SURFACE ROOT + unwrapClass -> GREEN (swallowed)
#    B extra class on an INNER block                 -> RED (class set)
#    C extra ANCESTOR <article class="band">         -> RED (tag) unless extracted first
#    D/E CSS token overrides, href/src/id/alt/aria   -> GREEN (never compared)
#    F suppressing an empty <p></p>                  -> RED (child count) vs unchanged golden
node --experimental-strip-types <scratch>.mts   # see wave paper vf-react-test-green for the file
```

Verified 2026-07-31 on node v22.22.2, vitest 4.1.9, next 16.2.1.
