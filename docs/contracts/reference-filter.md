<!-- doc-tier: agent | canonical-for: schema-reference-filter | budget: 600tok -->
# Reference field filter

A `reference` field, an `arrayOf` reference item or a reference subfield of a `composite` may narrow its Studio picker with Sanity's `options.filter`:

```json
"options": {
  "filter": "isSeriesParent == true && _id != $self",
  "filterParams": {"self": {"fromDocument": "_id"}}
}
```

- `filter` is a GROQ condition on the candidate document, the text Sanity puts between `*[` and `]`.
- `filterParams` holds GROQ parameters, names without `$`. A value is passed as it is, except `{"fromDocument": "<dotted path>"}`, which reads the open document's form value. `_id` is its published id; a reference reads as its `_ref`. The name `bpCandidateIds` is taken.
- A filter that is not a string, `filterParams` that is not an object, or GROQ that does not parse with its parameters is refused 422 at schema apply.

The picker searches as usual, 100 hits deep, then keeps the hits `*[_id in $bpCandidateIds && (<filter>)]._id` returns from the scoped GROQ endpoint with `perspective=raw`. A failed read lists nothing. A match ranked below the first 100 search hits is not offered.

Writes are not checked against the filter, as in Sanity. A target can stop matching after it is linked, and refusing then would block every later save of the linking document over a field the editor did not touch. The filter can also read the document's unsaved values, which the write path does not see.

## Code anchors

- `api/lib/barkpark/content/reference_filter.ex`
- `api/priv/static/assets/bp-reference-picker.js`
