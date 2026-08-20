#!/usr/bin/env python3
"""Hermetic Codex app-server 0.144.1 JSONL fake. Never starts a model turn."""

import argparse
import json
import sys
import time


def send(message):
    print(json.dumps(message, separators=(",", ":")), flush=True)


def main():
    if sys.argv[1:] == ["--version"]:
        print("codex-cli 0.144.1")
        return 0

    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", default="normal")
    parser.add_argument("--log", required=True)
    args = parser.parse_args()

    with open(args.log, "a", encoding="utf-8") as log:
        for raw in sys.stdin:
            log.write(raw)
            log.flush()
            message = json.loads(raw)
            method = message.get("method")

            if method == "initialize":
                if args.scenario == "malformed":
                    print("{not-json", flush=True)
                send({"id": message["id"], "result": {
                    "codexHome": "/tmp/codex",
                    "platformFamily": "unix",
                    "platformOs": "linux",
                    "userAgent": "codex-cli/0.144.1",
                }})
            elif method == "account/read":
                send({"id": message["id"], "result": {
                    "account": {"type": "apiKey"},
                    "requiresOpenaiAuth": True,
                }})
            elif method == "thread/start":
                send({"id": message["id"], "result": {"thread": {"id": "thread-1"}}})
            elif method == "thread/resume":
                send({"id": message["id"], "result": {"thread": {"id": "thread-resumed"}}})
            elif method == "turn/start":
                if args.scenario == "die_on_turn":
                    return 17
                if args.scenario == "stall_turn":
                    time.sleep(2)
                    continue
                send({"id": message["id"], "result": {"turn": {"id": "turn-1"}}})
                send({"method": "turn/started", "params": {
                    "threadId": "thread-1", "turn": {"id": "turn-1", "items": [], "status": "inProgress"}}})
                send({"method": "item/agentMessage/delta", "params": {
                    "threadId": "thread-1", "turnId": "turn-1", "itemId": "item-1", "delta": "hello"}})
                approvals = [
                    (91, "item/commandExecution/requestApproval", "cmd-1", {"command": "printf ok"}),
                    (92, "item/fileChange/requestApproval", "patch-1", {}),
                    (93, "item/commandExecution/requestApproval", "cmd-2", {"command": "false"}),
                ]
                for request_id, approval_method, item_id, extra in approvals:
                    params = {"threadId": "thread-1", "turnId": "turn-1", "itemId": item_id,
                              "startedAtMs": request_id}
                    params.update(extra)
                    send({"id": request_id, "method": approval_method, "params": params})
            elif method == "turn/steer":
                send({"id": message["id"], "result": {}})
            elif method == "turn/interrupt":
                send({"id": message["id"], "result": {}})
                send({"method": "turn/completed", "params": {
                    "threadId": "thread-1", "turn": {"id": "turn-1", "items": [], "status": "interrupted"}}})

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
