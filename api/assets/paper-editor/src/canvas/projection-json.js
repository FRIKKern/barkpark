// Structural deep clone, DOM-free and Node-API-free. structuredClone is a
// global in modern V8 (and browsers); fall back to JSON for older runtimes.
// Both are pure and create zero shared references with the source.
export function deepClone(value) {
  if (typeof structuredClone === "function") return structuredClone(value);
  return JSON.parse(JSON.stringify(value));
}

// Order-insensitive deep stringify: sorts OBJECT keys recursively (array order
// is preserved — content/marks order is significant). Without this, two
// semantically-identical text nodes that differ only in KEY ORDER would hash
// differently — exactly the runToTiptap `{type,text,marks}` vs ProseMirror
// getJSON `{type,marks,text}` mismatch that otherwise flags EVERY marked block
// as "changed" on every keystroke.
export function canonicalJSON(value) {
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalJSON).join(",") + "]";
  }
  if (value && typeof value === "object") {
    return (
      "{" +
      Object.keys(value)
        .sort()
        .map((k) => JSON.stringify(k) + ":" + canonicalJSON(value[k]))
        .join(",") +
      "}"
    );
  }
  return JSON.stringify(value);
}
