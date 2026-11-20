<!-- doc-tier: agent | canonical-for: schema-cross-validations | budget: 300tok -->
# Schema cross-field rules

`cross_validations` entries: `{name, title, rule, level, fields, each?, type?}`. `rule` is a `visibleWhen` predicate or `{all|any|one: [...]}` of them (`one`: exactly one holds). A broken rule shows in Studio and is a write finding (code `cross_validation`, path `/<first of fields>`) through the `validation` warnings/422 door ([schema-reference.md](schema-reference.md)) by `level`. A rule with an undeclared field, an unknown operator or no `rule` is skipped and logged.

`each: "meny"` (dotted, fans out over lists; `type` picks a `_type`) runs the rule per object item: a leaf reads the item, `scope: "document"` the root; each broken item is a finding at `/meny/<i>/<first field>`.

Operators (as `visibleWhen`): `eq neq in empty non_empty starts_with count_eq count_neq count_gt count_lt gt gte lt lte`. A compare fails only when both sides are numbers or non-empty strings (dates compare as text) and it is false. `valueField` instead of `value` names the other side; an undeclared one skips the rule.

## Code anchors

- `api/lib/barkpark/content/cross_validator.ex`
