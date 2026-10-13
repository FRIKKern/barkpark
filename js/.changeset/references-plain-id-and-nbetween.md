---
'@barkpark/core': minor
---

`filter[_references]=<id>` matches a scalar reference field stored as a bare
id string, and a new `nbetween` operator excludes a range.

`filter[_references]=<id>` previously matched only the structural
`{"_ref": id}` shape anywhere in a document's content, so a single reference
field stored as a bare id string (the common storage shape) was invisible to
it — `filter[_references]=author-alan` answered zero documents while
`filter[author][eq]=author-alan` answered the same ten. It now ALSO matches a
bare-string value, scoped to the fields the type's own schema declares
reference-shaped (a scalar `reference` field or an `arrayOf` of one), so an
ordinary string field that happens to equal the probed id is never mistaken
for a reference.

`nbetween` is a new, additive operator: `filter[<field>][nbetween]=a,b`
excludes rows whose value falls inside `[a, b]`, both bounds inclusive — the
complement Sanity's "is not [that day]" needs, which the filter grammar had no
op for at all. `FILTER_OPS`/`FilterOp` and the builder's runtime guard both
gain it (exactly two bounds, same comma-safety rule as `in`/`nin`).
