#!/usr/bin/env python3
"""Deterministic missing-field and malformed-input gate for PPCC2-E011."""

import copy
import json
from pathlib import Path

import candidate


def fixture():
    return {
        "id": "hostile",
        "_rev": "rev-1",
        "title": "Hostile fixture",
        "source": {
            "kind": "blocks",
            "blocks": [
                {"id": "h", "type": "heading", "level": 2, "text": "Heading"},
                {
                    "id": "i",
                    "type": "image",
                    "src": "/image.png",
                    "alt": "Image description",
                    "caption": "Caption fallback",
                },
                {
                    "id": "a",
                    "type": "action",
                    "label": "Open evidence",
                    "href": "https://example.test/evidence",
                },
            ],
        },
    }


def main():
    records = []

    missing_alt = fixture()
    missing_alt["source"]["blocks"][1].pop("alt")
    result = candidate.build_or_quarantine(missing_alt, "paper:missing-alt")
    reasons = {
        item["reason"]
        for item in result.get("candidate", {}).get("degradations", [])
    }
    records.append(
        {
            "case": "missing_image_alt",
            "status": result["status"],
            "pass": result["status"] == "accepted"
            and "missing_image_alt" in reasons
            and "Caption fallback"
            in candidate.render_studio(result["candidate"]),
        }
    )

    unsafe_href = fixture()
    unsafe_href["source"]["blocks"][2]["href"] = "javascript:alert(1)"
    result = candidate.build_or_quarantine(unsafe_href, "paper:unsafe-href")
    studio = candidate.render_studio(result["candidate"])
    reasons = {
        item["reason"]
        for item in result.get("candidate", {}).get("degradations", [])
    }
    records.append(
        {
            "case": "unsafe_link_target",
            "status": result["status"],
            "pass": result["status"] == "accepted"
            and "missing_or_unsafe_link_target" in reasons
            and 'href="javascript:' not in studio,
        }
    )

    nested_null = fixture()
    nested_null["source"]["blocks"][0]["content"] = [None]
    result = candidate.build_or_quarantine(nested_null, "paper:nested-null")
    records.append(
        {
            "case": "nested_null",
            "status": result["status"],
            "pass": result["status"] == "quarantined"
            and result["raw_payload"] == nested_null,
        }
    )

    duplicate_id = fixture()
    duplicate_id["source"]["blocks"][1]["id"] = "h"
    result = candidate.build_or_quarantine(duplicate_id, "paper:duplicate-id")
    records.append(
        {
            "case": "duplicate_identifier",
            "status": result["status"],
            "pass": result["status"] == "quarantined"
            and "duplicate block identifier" in result["reason"],
        }
    )

    for case, raw, expected in (
        ("duplicate_json_key", '{"a":1,"a":2}', "duplicate JSON key"),
        ("non_finite_json", '{"a":NaN}', "non-finite JSON number"),
    ):
        error = ""
        try:
            candidate.strict_loads(raw)
        except ValueError as exception:
            error = str(exception)
        records.append(
            {
                "case": case,
                "status": "rejected" if error else "accepted",
                "pass": expected in error,
                "error": error,
            }
        )

    output = {
        "assignment_id": candidate.ASSIGNMENT_ID,
        "attempted": len(records),
        "passed": sum(record["pass"] for record in records),
        "failed": sum(not record["pass"] for record in records),
        "pass_rate": sum(record["pass"] for record in records) / len(records),
        "records": records,
    }
    Path("artifacts/hostile-results.json").write_text(
        json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(output, sort_keys=True))
    return 0 if output["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
