#!/usr/bin/env python3
"""Assert the D59 stable-frame contract on the RAW SSE bytes of a real drive.

Input is `events.log` exactly as `drive.sh` wrote it — the unparsed byte log of
one long-lived `GET /v1/chat/sessions/:id/events` connection. Nothing here reads
the server, the transcript, or any implementation: if the assertions below pass,
they passed on bytes that a production Barkpark actually put on a socket.

The contract (mobile charter D59/D61, emitted by
`Barkpark.StudioChat.StreamSegments` and serialized by
`BarkparkWeb.ChatController.sse_stable_frame/1`):

  * `event: stable`     data = {"turn","from","to","blocks","skeleton"} — EXACTLY
                        those keys. Half-open [from,to), `to` strictly greater
                        than `from`; the first `from` of a turn is 0 and every
                        later `from` equals the previous `to` (a client walks
                        SOURCE offsets, never rendered block text).
  * `event: stable_end` data = {"turn","from","reason"} — exactly once per turn,
                        `reason` "settled" for a clean turn, its `from` at or
                        after the last `to`.
  * NEITHER frame kind carries an `id:` line: both consumers advance their
    resume cursor for ANY id-carrying frame before dispatch, so an id here would
    strand the next reconnect on a seq that never existed.

And the one property that makes the capture non-vacuous: at least one stable
frame of the analysed turn must land BEFORE that turn's `"type":"result"` frame
in the same byte log. Without it a "settled" turn is indistinguishable from a
single-shot one, and the whole point of the live document is that the reader
paints while the model is still talking.

Usage:
    assert-stable-capture.py <events.log|capture-dir> [--turn N] [--emit out.json]

`--emit` writes the analysed turn's frames as the `{event,data}` envelope both
client consumers already read (internal/pdrender/testdata/chat_stable_frames*.json).
Exit 0 = every assertion held; exit 1 = the first failure, named on stderr.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

STABLE_KEYS = {"turn", "from", "to", "blocks", "skeleton"}
STABLE_END_KEYS = {"turn", "from", "reason"}


class CaptureError(Exception):
    """A contract violation in the captured bytes."""


class Frame:
    """One parsed SSE frame, with the byte-log ordering it arrived in."""

    def __init__(self, index: int, event: str, data: object, has_id: bool):
        self.index = index
        self.event = event
        self.data = data
        self.has_id = has_id


def parse_events_log(text: str) -> list[Frame]:
    """Split a raw SSE byte log into frames, in arrival order.

    Deliberately literal: an `event:`/`data:`/`id:` line is recognised only at
    the start of a line, a blank line terminates the frame, and `: keepalive`
    comments are dropped. A frame with no `event:` line is named "message" (the
    SSE default), which is what the replay rows arrive as.
    """
    frames: list[Frame] = []
    event = ""
    data_lines: list[str] = []
    has_id = False
    started = False

    def flush() -> None:
        nonlocal event, data_lines, has_id, started
        if started and (event or data_lines):
            raw = "\n".join(data_lines)
            try:
                payload: object = json.loads(raw) if raw else None
            except json.JSONDecodeError:
                payload = raw
            frames.append(Frame(len(frames), event or "message", payload, has_id))
        event = ""
        data_lines = []
        has_id = False
        started = False

    for line in text.split("\n"):
        line = line.rstrip("\r")
        if line == "":
            flush()
            continue
        if line.startswith(":"):
            continue  # keepalive / comment
        started = True
        if line.startswith("event:"):
            event = line[len("event:"):].strip()
        elif line.startswith("data:"):
            # One leading space is the SSE field separator; anything beyond it
            # is payload, so only that one byte is stripped.
            value = line[len("data:"):]
            data_lines.append(value[1:] if value.startswith(" ") else value)
        elif line.startswith("id:"):
            has_id = True
    flush()
    return frames


def pick_turn(frames: list[Frame], want: int | None) -> int:
    """The turn to analyse: the requested one, else the richest captured one.

    "Richest" (most stable frames, latest on a tie) is chosen because a drive
    may contain several turns and only a blank-line-separated one crosses a
    boundary more than once — the analysis is per-turn precisely so a
    single-frame neighbour cannot dilute or falsely satisfy the contract.
    """
    counts: dict[int, int] = {}
    for f in frames:
        if f.event == "stable" and isinstance(f.data, dict):
            turn = f.data.get("turn")
            if isinstance(turn, int):
                counts[turn] = counts.get(turn, 0) + 1
    if want is not None:
        if want not in counts:
            raise CaptureError(f"no stable frames captured for turn {want}")
        return want
    if not counts:
        raise CaptureError("no `event: stable` frames in the capture at all")
    best = max(counts.values())
    return max(t for t, n in counts.items() if n == best)


def check(frames: list[Frame], turn: int) -> dict:
    """Assert the whole contract for one turn. Raises CaptureError on the first
    violation; returns the analysed frames on success."""
    stable = [
        f
        for f in frames
        if f.event == "stable" and isinstance(f.data, dict) and f.data.get("turn") == turn
    ]
    ends = [
        f
        for f in frames
        if f.event == "stable_end" and isinstance(f.data, dict) and f.data.get("turn") == turn
    ]

    if len(stable) < 2:
        raise CaptureError(
            f"turn {turn} carries {len(stable)} stable frame(s); a progressive turn needs >= 2 "
            "(one frame is what a single-shot turn also produces)"
        )

    cursor = 0
    for i, f in enumerate(stable):
        d = f.data
        assert isinstance(d, dict)
        if set(d.keys()) != STABLE_KEYS:
            raise CaptureError(
                f"stable frame {i} of turn {turn} has keys {sorted(d.keys())}, "
                f"wanted exactly {sorted(STABLE_KEYS)}"
            )
        if f.has_id:
            raise CaptureError(f"stable frame {i} of turn {turn} carries an `id:` line")
        frm, to = d["from"], d["to"]
        if not isinstance(frm, int) or not isinstance(to, int):
            raise CaptureError(f"stable frame {i} of turn {turn}: from/to are not integers")
        if to <= frm:
            raise CaptureError(
                f"stable frame {i} of turn {turn}: to={to} is not strictly greater than from={frm}"
            )
        if frm != cursor:
            where = "first frame does not start at 0" if i == 0 else "byte cursor broken"
            raise CaptureError(
                f"stable frame {i} of turn {turn}: from={frm} but the cursor is at {cursor} ({where})"
            )
        if not isinstance(d["blocks"], list) or not d["blocks"]:
            raise CaptureError(f"stable frame {i} of turn {turn} carries no blocks")
        cursor = to

    if len(ends) != 1:
        raise CaptureError(f"turn {turn} carries {len(ends)} stable_end frames, wanted exactly 1")
    end = ends[0]
    d = end.data
    assert isinstance(d, dict)
    if set(d.keys()) != STABLE_END_KEYS:
        raise CaptureError(
            f"stable_end of turn {turn} has keys {sorted(d.keys())}, "
            f"wanted exactly {sorted(STABLE_END_KEYS)}"
        )
    if end.has_id:
        raise CaptureError(f"stable_end of turn {turn} carries an `id:` line")
    if d["reason"] != "settled":
        raise CaptureError(f"stable_end of turn {turn} reason={d['reason']!r}, wanted 'settled'")
    if not isinstance(d["from"], int) or d["from"] < cursor:
        raise CaptureError(
            f"stable_end of turn {turn}: from={d['from']} is behind the last to={cursor}"
        )
    if end.index < stable[-1].index:
        raise CaptureError(f"turn {turn} emitted a stable frame AFTER its stable_end")

    # THE non-vacuity check: the reader was given committed content while the
    # model was still talking, not only once the turn had already finished.
    result_idx = next(
        (
            f.index
            for f in frames
            if f.index > stable[0].index
            and f.event == "chat"
            and isinstance(f.data, dict)
            and f.data.get("type") == "result"
        ),
        None,
    )
    if result_idx is None:
        raise CaptureError(
            f"no `\"type\":\"result\"` frame after turn {turn}'s first stable frame — "
            "the capture cannot show that anything landed MID-turn"
        )
    mid = [f for f in stable if f.index < result_idx]
    if not mid:
        raise CaptureError(
            f"every stable frame of turn {turn} lands after its result frame — nothing painted mid-turn"
        )

    return {
        "turn": turn,
        "stable": stable,
        "end": end,
        "mid_turn": len(mid),
        "result_index": result_idx,
        "bytes": cursor,
    }


def envelope(frames: list[Frame]) -> list[dict]:
    return [{"event": f.event, "data": f.data} for f in frames]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", help="events.log, or the capture directory holding it")
    ap.add_argument("--turn", type=int, default=None, help="analyse this turn (default: the richest)")
    ap.add_argument("--emit", default=None, help="write the analysed turn's frames as JSON envelopes")
    args = ap.parse_args(argv)

    path = args.path
    if os.path.isdir(path):
        path = os.path.join(path, "events.log")
    with open(path, encoding="utf-8", errors="replace") as fh:
        frames = parse_events_log(fh.read())

    try:
        turn = pick_turn(frames, args.turn)
        res = check(frames, turn)
    except CaptureError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    print(
        f"PASS: {path}: turn {res['turn']} — {len(res['stable'])} stable frames "
        f"({res['mid_turn']} of them before the turn's result frame), "
        f"{res['bytes']} source bytes committed, stable_end reason=settled, no id: lines"
    )

    if args.emit:
        ordered = sorted(res["stable"] + [res["end"]], key=lambda f: f.index)
        out = {
            "scope": "chat-stable-frame-wire-real-capture",
            "captured_turn": res["turn"],
            "mid_turn_frames": res["mid_turn"],
            "committed_bytes": res["bytes"],
            "frames": envelope(ordered),
        }
        with open(args.emit, "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        print(f"emitted {len(ordered)} frames -> {args.emit}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
