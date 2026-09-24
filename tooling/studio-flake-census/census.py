#!/usr/bin/env python3
"""
studio-flake-census v2 — which LiveViewTest sites read the store before the
LiveView has processed the self-message that writes it.

WHY v2 EXISTS.  v1 (campaign scratchpad studio-s29-a1) produced exactly two
follow-up leads and BOTH were refuted by measurement (PR #19712, PR #19724).
Two defects, both in the BARRIER rung:

  D1  The barrier vocabulary did not contain `render/1` or any of the
      `render_*` family.  A plain `render(view)` sitting between the trigger
      and the read was invisible, although it is the single most common
      barrier in this tree.  (Control: `census_selftest.py` case C1.)

  D2  The barrier scan started at the line AFTER the trigger, so a barrier
      living INSIDE the trigger helper — a tail `render(view)` at the end of
      `inner_change/2` — was never looked at.  v1 resolved file-local helpers
      transitively when hunting the TRIGGER and the READ but judged "is there
      a barrier between them" over the test block's own statements alone.
      (Control: `census_selftest.py` case C2.)

THE PREDICATE, IN WORDS.

  A BARRIER is anything that issues a SECOND, LATER `GenServer.call` to the
  LiveView pid.  `Phoenix.LiveViewTest.render/1` and every `render_*`
  helper resolve to `Phoenix.LiveView.Channel.ping/1`, i.e.
  `GenServer.call(pid, {:phoenix, :ping}, :infinity)`.  `:sys.get_state/1`,
  `:sys.replace_state/2`, `:erlang.process_info/2` and `Process.info/2` are
  calls to the same pid.  `assert_receive`, `render_async` and
  `Process.sleep` order by other means but order all the same.  A file-local
  helper whose body transitively contains one of those IS one.

  A barrier only counts if it is LATER than the enqueue.  A call in ARGUMENT
  position of the enqueueing expression — `if_rev: paper_rev(view)` inside
  the `render_hook(..., %{...})` map — is evaluated BEFORE the message is
  sent and is therefore not a barrier for it.  The scan starts where the
  trigger's call expression CLOSES, not at the trigger's first line.

  A site is examined in TWO windows, not one:
    W1  the trigger helper's own body, from the close of its last enqueueing
        expression to the end of the helper   [THE RUNG v1 WAS MISSING]
    W2  the test block, from the close of the trigger expression to the
        assertion line
  with file-local helpers resolved transitively in both.

  HOW MANY BARRIERS ARE ENOUGH is decided by the chain's HOP COUNT, not by
  the site.  One barrier is one ping; it orders only against messages already
  in the mailbox when it arrives.  A 1-hop chain sends its message from inside
  the `GenServer.call` the trigger is already blocking on, so that message is
  in the mailbox before the next ping: ONE barrier drains it deterministically.
  A chain of 2+ hops enqueues hop N+1 while handling hop N, after the ping has
  been answered, so no fixed number of barriers is sound and only a settle
  loop (ping until `message_queue_len` is 0, twice) is.

  VERDICT LATTICE
    MASKED-BY-BARRIER     1-hop chain, >= 1 barrier in W1 or W2.  Safe today.
    RACING-ONE-HOP        1-hop chain, zero barriers.  Needs one barrier.
    RACING-MULTI-HOP      chain hops >= 2.  A single barrier does not save it;
                          needs a settle loop.  THIS IS THE HAZARD CLASS.
    SETTLED-MULTI-HOP     chain hops >= 2 and a settle loop is in the window.
"""
import json, os, re, sys, collections

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HERE = os.path.dirname(os.path.abspath(__file__))
CHAINS = json.load(open(os.path.join(HERE, "chains.json")))["chains"]

# ── trigger vocabulary: the events whose handler chain self-enqueues ────────
TRIG = {
 'CH-TREE':    r'"tree_node_select"',
 'CH-PAPEROP': r'"inner-change"|"inner-flush"|"inner-array-op"',
 'CH-AUTOSAVE':r'"select-media"|"clear-image"|"upload-image"|"select-ref"|"clear-ref"',
 'CH-CHAT':    r'phx-submit=["\']?send|render_hook\([^\n]*"send"|"dispatch_send"',
}
ANYTRIG = '|'.join('(?:%s)' % v for v in TRIG.values())

# ── barrier vocabulary: a SECOND, LATER GenServer.call to the LiveView pid ──
# render/1 and the render_* family -> Phoenix.LiveView.Channel.ping/1
RENDER_FAMILY = (r'\brender\s*\(|\brender_click\s*\(|\brender_change\s*\(|'
                 r'\brender_submit\s*\(|\brender_hook\s*\(|\brender_keydown\s*\(|'
                 r'\brender_keyup\s*\(|\brender_blur\s*\(|\brender_focus\s*\(|'
                 r'\brender_patch\s*\(|\brender_async\s*\(|\brender_upload\s*\(|'
                 r'\bfollow_trigger_action\s*\(|\bopen_browser\s*\(')
BARRIER = (RENDER_FAMILY +
           r'|:sys\.get_state\s*\(|:sys\.replace_state\s*\(|:sys\.suspend\s*\('
           r'|:erlang\.process_info\s*\(|\bProcess\.info\s*\('
           r'|\bGenServer\.call\s*\(|\bassert_receive\b|\brefute_receive\b'
           r'|\bProcess\.sleep\s*\(|\bmessage_queue_len\b')
# A SETTLE LOOP is a SHAPE, not a name.  It is the only sound construct on a
# multi-hop chain: repeat a barrier until the mailbox is observed quiet.  The
# observable that makes it a loop rather than a single ping is the mailbox
# read itself -- `:erlang.process_info(pid, :message_queue_len)`.  Detected
# structurally (see settle_shape/2): a helper qualifies when it reads the
# mailbox length, or when it is RECURSIVE and contains a barrier.  No helper
# is ever named here; `settle!` is found because of what it does.
SETTLE = r'\bmessage_queue_len\b'

STORE = (r'\bRepo\.|\bContent\.|\bDocuments\.|\bBulldocs\.|\bSheets\.|\bMedia\.'
         r'|\bRecorder\.|\bStudioChat\.|\bTasks\.|\bPapers\.'
         r'|paper_blocks\s*\(|get_document\s*\(|get_paper\s*\(|\bFile\.read|:ets\.')

DEF_RX = re.compile(r'^\s*defp?\s+([a-z_][A-Za-z0-9_?!]*)')
BLOCK_RX = re.compile(r'^\s*(test[ (]|describe[ (]|setup[ (]|setup_all[ (])')


# ── parsing ────────────────────────────────────────────────────────────────
def helper_bodies(lines):
    """name -> list of (absolute_index, line) for every file-local def/defp."""
    out = collections.defaultdict(list)
    cur, ind = None, 0
    for i, l in enumerate(lines):
        m = DEF_RX.match(l)
        if m:
            cur, ind = m.group(1), len(l) - len(l.lstrip())
            out[cur].append((i, l)); continue
        if cur is None:
            continue
        if l.strip() and (len(l) - len(l.lstrip())) <= ind and (BLOCK_RX.match(l) or DEF_RX.match(l)):
            cur = None; continue
        out[cur].append((i, l))
    return out


def body_text(bodies):
    return {n: '\n'.join(l for _, l in b) for n, b in bodies.items()}


def calls_of(txt):
    """name -> set of helper names it calls (restricted to the index).

    NOT memoised on `id(txt)`: a per-file dict is garbage-collected and CPython
    reuses the address, so an id-keyed memo silently served one file's call
    graph to another and two runs of this script over an unchanged tree printed
    DIFFERENT verdict counts (58/6 then 53/11).  A census whose answer moves
    when nothing moved is the signature of a broken instrument; the selftest's
    DETERMINISM case reds on it."""
    names = set(txt)
    return {n: {c for c in re.findall(r'\b([a-z_][A-Za-z0-9_?!]*)\s*\(', t)
                if c in names and c != n}
            for n, t in txt.items()}


def closure(bodies, base_rx, txt=None, seed=frozenset(), calls=None):
    """helper names whose body transitively matches base_rx (or calls a seeded one)."""
    txt = txt if txt is not None else body_text(bodies)
    calls = calls if calls is not None else calls_of(txt)
    hot = {n for n, t in txt.items() if re.search(base_rx, t)} | (set(seed) & set(txt))
    hot |= {n for n, cs in calls.items() if cs & set(seed)}
    while True:
        grew = {n for n, cs in calls.items() if n not in hot and (cs & hot)}
        if not grew:
            return hot
        hot |= grew


def with_helpers(base_rx, names):
    if not names:
        return base_rx
    return base_rx + '|' + '|'.join(r'\b%s\s*\(' % re.escape(n) for n in sorted(names))


def expr_end(lines, i, col):
    """Index of the last line of the call expression whose '(' is at lines[i][col:].
    Balances parens/brackets/braces across lines, skipping string contents."""
    depth, instr, esc = 0, None, False
    j, k = i, col
    while j < len(lines):
        l = lines[j]
        while k < len(l):
            c = l[k]
            if instr:
                if esc: esc = False
                elif c == '\\': esc = True
                elif c == instr: instr = None
            else:
                if c in '"\'': instr = c
                elif c == '#': break            # comment to EOL
                elif c in '([{': depth += 1
                elif c in ')]}':
                    depth -= 1
                    if depth == 0:
                        return j
            k += 1
        if depth == 0 and j > i:
            return j
        j += 1; k = 0
        instr = None if instr == '"' or instr is None else instr
    return len(lines) - 1


def first_open_paren(line, mstart):
    p = line.find('(', mstart)
    return p if p != -1 else None


def statements(lines, lo, hi):
    """Yield (start, end) spans of whole STATEMENTS in lines[lo:hi].

    A trigger's window must open after the END OF ITS STATEMENT, not after the
    sub-expression that happens to carry the event name.  Two shapes in this
    tree break a line-wise scan:

        view                                   render_submit(
        |> element(~s(... "tree_node_select" ...))   element(view, "form[phx-submit=send]"),
        |> render_click()                           %{"message" => "hi"}
                                               )

    In the first the event name is on the `element(...)` line and the driving
    `render_click()` is the NEXT pipeline segment; closing at `element(...)`
    put the trigger's OWN render_click inside the barrier window and it counted
    as a barrier for itself.  In the second the event name is on an ARGUMENT
    line of the enclosing `render_submit(...)`.  Spanning the statement fixes
    both."""
    i = lo
    while i < hi:
        l = lines[i]
        if not l.strip() or l.lstrip().startswith('#'):
            i += 1; continue
        po = first_open_paren(l, 0)
        end = max(expr_end(lines, i, po) if po is not None else i, i)
        # a pipeline continues while the next non-blank line starts with `|>`
        while True:
            j = end + 1
            while j < hi and (not lines[j].strip() or lines[j].lstrip().startswith('#')):
                j += 1
            if j < hi and lines[j].lstrip().startswith('|>'):
                po2 = first_open_paren(lines[j], 0)
                nxt = expr_end(lines, j, po2) if po2 is not None else j
                if nxt <= end:          # never let the span fail to advance
                    end = j
                    continue
                end = nxt
                continue
            break
        yield (i, end)
        i = max(end + 1, i + 1)


def scan_window(lines, lo, hi, rx_bar, rx_settle):
    """barrier hits in lines[lo:hi], skipping comment lines."""
    bars, settles = [], []
    for i in range(max(lo, 0), min(hi, len(lines))):
        l = lines[i]
        if l.lstrip().startswith('#') or not l.strip():
            continue
        for m in re.finditer(rx_bar, l):
            bars.append((i + 1, m.group(0).strip()))
        if re.search(rx_settle, l):
            settles.append((i + 1, l.strip()[:80]))
    return bars, settles


def last_trigger_in(lines, idxs, rx_trig):
    """(start, end) of the LAST triggering STATEMENT among the lines in idxs."""
    if not idxs:
        return None
    hit = None
    for a, b in statements(lines, idxs[0], idxs[-1] + 1):
        if re.search(rx_trig, '\n'.join(lines[a:b + 1])):
            hit = (a, b)
    return hit


SUPPORT_CACHE = {}


def support_index():
    """Helpers defined in api/test/support/**.ex, indexed once.

    THE SECOND CLOSURE RUNG.  File-local helpers are not the only place a
    barrier hides: `BarkparkWeb.LiveSettle.settle!/2` and the PaperEditor test
    helpers are IMPORTED, so a file-local closure alone walks past them exactly
    the way v1 walked past `inner_change/2`'s tail `render(view)`."""
    if SUPPORT_CACHE:
        return SUPPORT_CACHE
    lines = []
    sup = os.path.join(ROOT, 'api', 'test', 'support')
    for dp, _, fns in os.walk(sup):
        for fn in sorted(fns):
            if fn.endswith(('.ex', '.exs')):
                lines += open(os.path.join(dp, fn), encoding='utf8',
                              errors='replace').read().split('\n') + ['']
    b = helper_bodies(lines)
    t = body_text(b)
    c = calls_of(t)
    trig = closure(b, ANYTRIG, t, calls=c)
    bar = closure(b, BARRIER, t, calls=c)
    SUPPORT_CACHE.update(dict(lines=lines, bodies=b, txt=t, calls=c,
                              trig=trig, bar=bar,
                              store=closure(b, STORE, t, calls=c),
                              settle=closure(b, SETTLE, t, calls=c)))
    # W1 for support helpers, computed ONCE.  A support helper cannot call a
    # helper defined in a test file, so support-only regexes are exact here --
    # and recomputing this per test file made the run O(files x support
    # helpers) and it stopped terminating in reasonable time.
    SUPPORT_CACHE['w1'] = helper_tail_windows(
        b, lines, with_helpers(ANYTRIG, trig), with_helpers(BARRIER, bar),
        with_helpers(SETTLE, SUPPORT_CACHE['settle']))
    return SUPPORT_CACHE


def tail_barriers(lines, lo, hi, rx_trig, rx_bar, rx_settle):
    """Barriers after the LAST enqueueing statement in lines[lo:hi]."""
    lt = last_trigger_in(lines, list(range(lo, hi)), rx_trig)
    if lt is None:
        return None
    _, close = lt
    bars, settles = scan_window(lines, close + 1, hi, rx_bar, rx_settle)
    return dict(after_line=close + 1, barriers=bars, settles=settles)


BLOCK_OPEN = re.compile(r'(\bfn\b[^\n]*->|\bdo\b)\s*$')


def inline_block_window(lines, tline, tclose, rx_trig, rx_bar, rx_settle):
    """W1 for an INLINE block -- `derives_during(view.pid, fn -> ... end)`.

    The same rung as the named-helper one, wearing different clothes: the
    trigger and a tail `render(view)` both live inside the anonymous function
    passed to the trigger statement, so a window that opens where the STATEMENT
    closes never sees the barrier.  Gated on an actual block opener (`fn ->` or
    a trailing `do`) so that the continuation lines of a plain multi-line call
    -- the `%{...}` map argument of `render_hook/3` -- are NOT treated as
    statements; those are argument position and must not count."""
    opener = next((i for i in range(tline, tclose + 1)
                   if BLOCK_OPEN.search(lines[i].split('#')[0].rstrip())), None)
    if opener is None or opener >= tclose:
        return None
    return tail_barriers(lines, opener + 1, tclose, rx_trig, rx_bar, rx_settle)


def helper_tail_windows(bodies, lines, rx_trig, rx_bar, rx_settle):
    """W1 PER HELPER — THE RUNG v1 WAS MISSING.

    For every helper that ENQUEUES (contains a trigger expression), collect the
    barriers that follow the CLOSE of its last enqueueing expression.  Closing
    the expression is what excludes an ARGUMENT-position call: `if_rev:
    paper_rev(view)` inside `render_hook(target, "inner-flush", %{...})` is
    evaluated BEFORE the message is sent and is not a barrier for it, while a
    tail `render(view)` on the next line is."""
    out = {}
    for n, b in bodies.items():
        idxs = [i for i, _ in b]
        w = tail_barriers(lines, idxs[0], idxs[-1] + 1, rx_trig, rx_bar, rx_settle)
        if w is not None:
            out[n] = w
    return out


def settle_shape(bodies, h_bar, txt=None, calls=None):
    """Helpers that are SETTLE LOOPS, by shape: they read the mailbox length,
    or they call themselves AND contain a barrier.  A single ping is not a
    drain on a multi-hop chain; a loop that observes the mailbox is."""
    txt = txt if txt is not None else body_text(bodies)
    calls = calls if calls is not None else calls_of(txt)
    # RECURSION is tested on the body WITHOUT its `def`/`defp` header lines:
    # `defp flush_form(view, selector, values) do` contains `flush_form(`, so
    # testing the raw body made EVERY barrier-carrying helper look recursive
    # and promoted `flush_form/3` to a settle loop it is not.
    def recursive(n, b):
        body = '\n'.join(l for _, l in b if not DEF_RX.match(l))
        return bool(re.search(r'\b%s\s*\(' % re.escape(n), body))

    base = {n for n, t in txt.items()
            if re.search(SETTLE, t) or (n in h_bar and recursive(n, bodies[n]))}
    hot = set(base)
    while True:
        grew = {n for n, cs in calls.items() if n not in hot and (cs & hot)}
        if not grew:
            return hot
        hot |= grew


def chains_of(expr, bodies, h_trig):
    """Which chain(s) does THIS trigger expression enqueue?  Attribution is per
    TRIGGER, never per test block: a block can host triggers on two different
    chains (slash_menu_and_codelist_test.exs:256 clicks `tree_node_select` AND
    calls `flush_form/3`), and a block-level union hands the 3-hop CH-TREE label
    to the 1-hop CH-PAPEROP trigger's window."""
    found = {c for c, rx in TRIG.items() if re.search(rx, expr)}
    for h in h_trig:
        if re.search(r'\b%s\s*\(' % re.escape(h), expr):
            ht = '\n'.join(l for _, l in bodies.get(h, []))
            found |= {c for c, rx in TRIG.items() if re.search(rx, ht)}
    return sorted(found)


def analyse_file(path, rel):
    lines = open(path, encoding='utf8', errors='replace').read().split('\n')
    bodies = helper_bodies(lines)
    sup = support_index()
    merged = dict(sup['bodies']); merged.update(bodies)
    ltxt = body_text(bodies)
    lcalls = calls_of(ltxt)

    h_trig = sup['trig'] | closure(bodies, ANYTRIG, ltxt, sup['trig'], lcalls)
    h_bar = sup['bar'] | closure(bodies, BARRIER, ltxt, sup['bar'], lcalls)
    h_store = sup['store'] | closure(bodies, STORE, ltxt, sup['store'], lcalls)
    h_settle = (settle_shape(sup['bodies'], h_bar, sup['txt'], sup['calls'])
                | settle_shape(bodies, h_bar, ltxt, lcalls)
                | closure(bodies, SETTLE, ltxt, sup['settle'], lcalls))
    rx_trig = with_helpers(ANYTRIG, h_trig)
    rx_bar = with_helpers(BARRIER, h_bar)
    rx_store = with_helpers(STORE, h_store - h_bar)
    rx_settle = with_helpers(SETTLE, h_settle)

    w1 = dict(sup['w1'])
    w1.update(helper_tail_windows(bodies, lines, rx_trig, rx_bar, rx_settle))

    starts = [i for i, l in enumerate(lines) if re.match(r'\s*test[ (]', l)]
    rows = []
    for a in starts:
        ind = len(lines[a]) - len(lines[a].lstrip())
        end = len(lines)
        for j in range(a + 1, len(lines)):
            l = lines[j]
            if l.strip() and (len(l) - len(l.lstrip())) <= ind and (BLOCK_RX.match(l) or DEF_RX.match(l)):
                end = j; break

        # EVERY triggering STATEMENT in the block, not just the last one.
        trigs = [(x, y) for x, y in statements(lines, a, end)
                 if re.search(rx_trig, '\n'.join(lines[x:y + 1]))]

        for tline, tclose in trigs:
            expr = '\n'.join(lines[tline:tclose + 1])
            chains = chains_of(expr, merged, h_trig)
            if not chains:
                continue

            fa = None
            for k in range(tclose + 1, end):
                l = lines[k]
                if not l.strip() or l.lstrip().startswith('#'):
                    continue
                if re.match(r'\s*(assert|refute)', l) and re.search(rx_store, l):
                    fa = k; break
                m = re.match(r'\s*(\{:ok,\s*)?([a-z_][A-Za-z0-9_]*)\}?\s*=', l)
                if m and re.search(rx_store, '\n'.join(lines[k:k + 4])):
                    v = m.group(2)
                    if re.search(r'^\s*(assert|refute)[^\n]*\b%s\b' % re.escape(v),
                                 '\n'.join(lines[k + 1:end]), re.M):
                        fa = k; break
            if fa is None:
                continue

            w2_bars, w2_settles = scan_window(lines, tclose + 1, fa, rx_bar, rx_settle)
            w1_bars, w1_settles, via = [], [], []
            for h in sorted(h_trig):
                if re.search(r'\b%s\s*\(' % re.escape(h), expr) and h in w1:
                    via.append(h)
                    w1_bars += w1[h]['barriers']
                    w1_settles += w1[h]['settles']
            ib = inline_block_window(lines, tline, tclose, rx_trig, rx_bar, rx_settle)
            if ib:
                via.append('<inline block>')
                w1_bars += ib['barriers']
                w1_settles += ib['settles']

            hops = max(CHAINS[c]['hops'] for c in chains)
            nbar = len(w1_bars) + len(w2_bars)
            nset = len(w1_settles) + len(w2_settles)
            if hops >= 2:
                verdict = 'SETTLED-MULTI-HOP' if nset else 'RACING-MULTI-HOP'
            else:
                verdict = 'MASKED-BY-BARRIER' if nbar else 'RACING-ONE-HOP'
            where = '+'.join(x for x, ok in (('TRIGGER-HELPER', w1_bars),
                                             ('TEST-BLOCK', w2_bars)) if ok) or None
            rows.append(dict(
                file=rel, line=a + 1, name=re.sub(r'\s+', ' ', lines[a].strip())[:120],
                chains=chains, hops=hops,
                trig_line=tline + 1, trig=lines[tline].strip()[:110],
                trig_expr_closes=tclose + 1, trigger_helpers=via,
                assert_line=fa + 1, assert_src=lines[fa].strip()[:110],
                w1_barriers=w1_bars, w2_barriers=w2_bars,
                settles=w1_settles + w2_settles,
                barrier_count=nbar, masked_where=where, verdict=verdict))
    return rows


def main():
    files = []
    for dp, _, fns in os.walk(os.path.join(ROOT, 'api', 'test')):
        for fn in fns:
            if fn.endswith('.exs'):
                files.append(os.path.join(dp, fn))
    files.sort()
    rows = []
    for p in files:
        rel = os.path.relpath(p, ROOT)
        try:
            rows += analyse_file(p, rel)
        except Exception as e:  # noqa
            print('ERR', rel, e, file=sys.stderr)
    out = dict(
        generated_from='tooling/studio-flake-census/census.py (v2)',
        supersedes='campaign scratchpad studio-s29-a1/RESULT.json (v1) — REFUTED, see README.md',
        files_scanned=len(files), sites=len(rows),
        by_verdict=dict(collections.Counter(r['verdict'] for r in rows)),
        by_hops=dict(collections.Counter(r['hops'] for r in rows)),
        by_chain=dict(collections.Counter(c for r in rows for c in r['chains'])),
        multi_hop_sites=sum(1 for r in rows if r['hops'] >= 2),
        one_hop_sites=sum(1 for r in rows if r['hops'] == 1),
        rows=sorted(rows, key=lambda r: (r['verdict'], r['file'], r['line'])))
    json.dump(out, open(os.path.join(HERE, 'RESULT-v2.json'), 'w'), indent=1)
    print('files scanned                :', out['files_scanned'])
    print('sites (trigger + store read) :', out['sites'])
    print('by hop count                 :', out['by_hops'])
    print('multi-hop / one-hop          :', out['multi_hop_sites'], '/', out['one_hop_sites'])
    print('by verdict                   :', out['by_verdict'])
    print('by chain                     :', out['by_chain'])
    print()
    for r in out['rows']:
        print(f"{r['verdict']:18} {r['file'].split('/')[-1]}:{r['line']}(trig L{r['trig_line']}) "
              f"[{'+'.join(r['chains'])} {r['hops']}-hop] bars={r['barrier_count']}"
              f"{' via ' + r['masked_where'] if r['masked_where'] else ''}"
              f"{' helpers=' + ','.join(r['trigger_helpers']) if r['trigger_helpers'] else ''}")


if __name__ == '__main__':
    main()
