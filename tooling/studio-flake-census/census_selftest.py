#!/usr/bin/env python3
"""Controls for census.py.

Every case is a MATCHED PAIR: a fixture the predicate must call one thing and
its minimal mutation it must call the other.  A case that only asserts the
expected verdict proves nothing — it passes for a predicate that answers that
verdict always.  The pair is what measures.

The fixtures use invented helper and file names (`poke/2`, `wiggle/3`,
`zz_synthetic_*`), so a predicate that got the two real regression sites right
by naming them in a list fails here.  An enumeration is a snapshot; a
predicate is a rule.
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import census  # noqa: E402

TRIG_LINE = 'render_hook(element(view, "#f"), "inner-flush", %{"values" => %{}})'
ARGPOS = ('render_hook(element(view, "#f"), "inner-flush", %{\n'
          '      "if_rev" => paper_rev(view),\n'
          '      "values" => %{}\n'
          '    })')
READ = ('    stored = Content.paper_blocks("s", "d")\n'
        '    assert stored == []\n')


def block(body):
    return ('defmodule ZzSyntheticTest do\n  use BarkparkWeb.ConnCase\n\n'
            '  test "synthetic" do\n' + body + '  end\n\n'
            '  defp paper_rev(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev\n'
            'end\n')


def helper_block(helper_body, call='poke(view)'):
    return ('defmodule ZzSyntheticTest do\n  use BarkparkWeb.ConnCase\n\n'
            '  test "synthetic" do\n    ' + call + '\n' + READ + '  end\n\n'
            '  defp poke(view) do\n' + helper_body + '  end\n\n'
            '  defp paper_rev(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev\n'
            'end\n')


def tree_block(tail):
    return ('defmodule ZzSyntheticTreeTest do\n  use BarkparkWeb.ConnCase\n\n'
            '  test "synthetic" do\n'
            '    view |> element(~s(button[phx-click="tree_node_select"])) |> render_click()\n'
            + tail + READ + '  end\n\n'
            '  defp wiggle(view, fuel) do\n'
            '    render(view)\n'
            '    case :erlang.process_info(view.pid, :message_queue_len) do\n'
            '      {:message_queue_len, 0} -> :ok\n'
            '      _ -> wiggle(view, fuel - 1)\n'
            '    end\n  end\n'
            'end\n')


def inline_fn(tail):
    """`derives_during(view.pid, fn -> ... end)` -- the trigger AND the barrier
    both inside the anonymous function passed to a probe."""
    return ('defmodule ZzSyntheticInlineTest do\n  use BarkparkWeb.ConnCase\n\n'
            '  test "synthetic" do\n'
            '    n =\n      probe(view.pid, fn ->\n'
            '        ' + TRIG_LINE + '\n' + tail +
            '      end)\n\n' + READ + '    assert n == 1\n  end\n\n'
            '  defp probe(_pid, fun), do: fun.()\n'
            'end\n')


CASES = [
    # id, source, expected verdict, what it measures
    ('C1a bare 1-hop, no barrier anywhere',
     block('    ' + TRIG_LINE + '\n' + READ), 'RACING-ONE-HOP'),
    ('C1b same + a plain render(view) in the gap  [v1 DEFECT D1: render/1 was '
     'absent from the barrier vocabulary, so this read RACING]',
     block('    ' + TRIG_LINE + '\n    render(view)\n' + READ), 'MASKED-BY-BARRIER'),

    ('C2a trigger helper with NO tail barrier',
     helper_block('    ' + TRIG_LINE + '\n'), 'RACING-ONE-HOP'),
    ('C2b same helper + a tail render(view)  [v1 DEFECT D2: the barrier scan '
     'started after the CALL SITE, so a barrier inside the helper was invisible]',
     helper_block('    ' + TRIG_LINE + '\n    render(view)\n'), 'MASKED-BY-BARRIER'),

    ('C3a barrier in ARGUMENT position of the enqueueing call — evaluated '
     'BEFORE the send, so NOT a barrier',
     block('    ' + ARGPOS + '\n' + READ), 'RACING-ONE-HOP'),
    ('C3b the same call with the barrier moved to TAIL position',
     block('    ' + ARGPOS + '\n    paper_rev(view)\n' + READ), 'MASKED-BY-BARRIER'),

    ('C9a trigger inside an inline `fn ->` block, no tail barrier in it',
     inline_fn(''), 'RACING-ONE-HOP'),
    ('C9b same inline block + a tail render(view) INSIDE it  [the D2 rung in '
     'different clothes: the barrier is inside the trigger STATEMENT, so a '
     'window opening where the statement closes never sees it]',
     inline_fn('        render(view)\n'), 'MASKED-BY-BARRIER'),

    ('C4a 3-hop CH-TREE with ONE barrier — one ping is not a drain',
     tree_block('    render(view)\n'), 'RACING-MULTI-HOP'),
    ('C4b 3-hop CH-TREE with a settle LOOP (detected by shape: it reads '
     'message_queue_len and recurses; the helper is called wiggle/2)',
     tree_block('    wiggle(view, 50)\n'), 'SETTLED-MULTI-HOP'),
]


def verdicts(src):
    with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as d:
        p = os.path.join(d, 'zz_synthetic_test.exs')
        open(p, 'w').write(src)
        return [r['verdict'] for r in census.analyse_file(p, 'zz_synthetic_test.exs')]


def main():
    fails = []
    for cid, src, want in CASES:
        got = verdicts(src)
        ok = got == [want]
        print(('PASS ' if ok else 'FAIL ') + cid)
        if not ok:
            print('      want [%s]  got %s' % (want, got))
            fails.append(cid)

    # DETERMINISM: the same tree must give the same answer twice.  An id-keyed
    # memo over per-file dicts once made this red (58/6 then 53/11).
    runs = []
    for _ in range(2):
        subprocess.run([sys.executable, os.path.join(HERE, 'census.py')],
                       check=True, capture_output=True)
        runs.append(json.load(open(os.path.join(HERE, 'RESULT-v2.json')))['by_verdict'])
    ok = runs[0] == runs[1]
    print(('PASS ' if ok else 'FAIL ') + 'C5  determinism over two full runs  %s' % (runs,))
    if not ok:
        fails.append('C5')

    # chains.json must still describe the tree it claims to describe.
    root = census.ROOT
    missing = []
    for name, c in census.CHAINS.items():
        for site in c['enqueue_sites']:
            head = site.split('HOP ')[-1].split(' ', 1)[-1] if site.startswith('HOP') else site
            path, _, rest = head.partition(':')
            lineno = rest.split(' ', 1)[0]
            if not lineno.isdigit():
                continue
            fp = os.path.join(root, path.strip())
            if not os.path.exists(fp):
                missing.append(site); continue
            lines = open(fp, encoding='utf8', errors='replace').read().split('\n')
            i = int(lineno) - 1
            if i >= len(lines) or not ('self()' in lines[i] or 'send_update(' in lines[i]):
                missing.append(site)
    ok = not missing
    print(('PASS ' if ok else 'FAIL ') + 'C6  chains.json enqueue sites still enqueue')
    for m in missing:
        print('      drifted:', m)
    if not ok:
        fails.append('C6')

    # C7 — THE TWO REFUTED SITES, as regression fixtures.  v1 called these
    # RACING and MASKED-BY-DUPLICATE; measurement (PR #19712, PR #19724) found
    # both MASKED-BY-BARRIER.  This case pins the OUTCOME.  What makes it a
    # regression test and not a special case is C8 below: neither file nor
    # helper is named anywhere in census.py's decision path.
    res = json.load(open(os.path.join(HERE, 'RESULT-v2.json')))['rows']
    reg = {
        'api/test/barkpark_web/live/studio/pds_w42_caps_derive_op_latency_test.exs':
            ('all sites', None),
        'flush_form/inner_change family': ('trigger_helpers', {'flush_form', 'inner_change'}),
    }
    f1 = [r for r in res if r['file'].endswith('pds_w42_caps_derive_op_latency_test.exs')]
    ok1 = bool(f1) and all(r['verdict'] == 'MASKED-BY-BARRIER' for r in f1)
    print(('PASS ' if ok1 else 'FAIL ') +
          'C7a pds_w42_caps_derive_op_latency: %d/%d MASKED-BY-BARRIER'
          % (sum(1 for r in f1 if r['verdict'] == 'MASKED-BY-BARRIER'), len(f1)))
    if not ok1:
        fails.append('C7a')

    fam = [r for r in res if set(r['trigger_helpers']) & {'flush_form', 'inner_change'}]
    bad = [r for r in fam if r['verdict'] != 'MASKED-BY-BARRIER']
    # the ONE exception is a CH-PAPEROP trigger in a block whose hazard is the
    # CH-TREE chain -- reported separately, not a family miss.
    ok2 = bool(fam) and len(bad) <= 1
    print(('PASS ' if ok2 else 'FAIL ') +
          'C7b flush_form/inner_change family: %d/%d MASKED-BY-BARRIER'
          % (len(fam) - len(bad), len(fam)))
    for b in bad:
        print('      not masked:', b['file'].split('/')[-1] + ':%d' % b['line'], b['verdict'])
    if not ok2:
        fails.append('C7b')

    # C8 — NO SPECIAL-CASING.  The predicate's decision path must not mention
    # any fixture file or helper by name.  Comments may (and do) discuss them.
    code = [l for l in open(os.path.join(HERE, 'census.py')).read().split('\n')]
    stripped, in_doc = [], False
    for l in code:
        t = l.strip()
        if t.startswith('"""') or t.endswith('"""'):
            in_doc = not in_doc if t.count('"""') == 1 else in_doc
            continue
        if in_doc or t.startswith('#'):
            continue
        stripped.append(l.split('  #')[0])
    body = '\n'.join(stripped)
    banned = ['flush_form', 'inner_change', 'derives_during', 'settle!',
              'pds_w42', 'pds_w43', 'pds_w44', 'pds_w45', 'composite_test',
              'legacy_tag', 'slash_menu', 'chat_live_test', 'paper_rev',
              'spawn_silent_session']
    # NOT banned: 'tree_node_select'.  That string is the LiveView EVENT name
    # (`phx-click="tree_node_select"`) and is CH-TREE's definition, so it
    # belongs in the trigger vocabulary.  A test helper in
    # pds_w42_tree_codelist_write_gate_test.exs happens to share the name; the
    # predicate reads the event, not the helper.
    hits = [b for b in banned if b in body]
    # CONTROL: the scan CAN find a name -- a token that IS in the decision path.
    assert 'message_queue_len' in body, 'C8 scan is vacuous: it found nothing at all'
    ok = not hits
    print(('PASS ' if ok else 'FAIL ') +
          'C8  no fixture name in census.py\'s decision path (control: the scan '
          'does see message_queue_len)')
    for h in hits:
        print('      special-cased on:', h)
    if not ok:
        fails.append('C8')

    print()
    print('%d/%d cases pass' % (len(CASES) + 5 - len(fails), len(CASES) + 5))
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
