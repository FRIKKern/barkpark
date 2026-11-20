<!-- doc-tier: human | canonical-for: barkui-decision-real-presses | budget: 800tok -->
# 0008 Press checks press real keys in a real browser

Date: 2026-11-19 · Status: accepted

```
press.mjs step: keys ['Tab'] ─► headless Chromium's own input pipeline ─► expect(root) true or a reason
                                                                       └► what a screen reader gets (role, name, states)
```

## Context

A check can move focus or fire events from a script, or it can press keys the way a person does. A script skips the path a key press takes through the browser, so a part can pass scripted presses and still fail under a real keyboard.

UI SDK has a testing kit of its own, `@ui-sdk/core/testing`. Its docs say it provides helpers to simulate input, check focus and accessibility attributes, and inspect a primitive's state and server output.

## Decision

- Each part's `press.mjs` lists steps: keys to press or an element to click, then what must be true. The check runs them in headless Chromium. Keys go through the browser's own input, the same path a keyboard takes. A click is a real pointer press at the element's centre, made only when the element is what is on top there; a cover or anything else in the way fails the step.
- Each step's setup and expectation run in an isolated world: they share the page's elements but none of its script, so page script cannot patch the check's helpers or the functions a step calls. What a part's demo wires into the page is part of what the steps test.
- Where a step names them, the role, name and states are read from the browser's accessibility tree, which is what a screen reader gets.
- The "Pressed by real keys" light is on only when every step passed in the last run ([QUALITY.md](../../QUALITY.md)).

UI SDK's testing kit is not used today.

## What would change it

We would add UI SDK's testing kit beside the real presses, not in place of them, when either holds:

- Parts get a React face (planned). The kit may then check part of that behaviour in the fast tests.
- UI SDK's kit checks something the browser run does not, such as the attributes a server prints for a state.

## Considered

- **UI SDK's testing kit alone.** Not chosen for now: the kit simulates input, while the browser run presses real keys and reads what a screen reader gets.
