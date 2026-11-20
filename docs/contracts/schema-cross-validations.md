<!-- doc-tier: agent | canonical-for: schema-cross-validations | budget: 300tok -->
# Schema cross-field rules

`cross_validations` entries: `{name, title, rule, level, fields}`. `rule` is a `visibleWhen` predicate, or `{all: [...]}` / `{any: [...]}` / `{one: [...]}` (exactly one holds) of them. Studio shows unsatisfied rules as a banner; API writes get the same rules as findings (code `cross_validation`, path `/<first of fields>`) through the same warnings/422 door as `validation` findings ([schema-reference.md](schema-reference.md)), by `level`. A rule naming an undeclared field or an unknown operator, or with no `rule`, is skipped and logged.

Operators (these and `visibleWhen`): `eq`, `neq`, `in`, `empty`, `non_empty`, `starts_with`, `count_eq`, `count_neq`, `count_gt`, `count_lt`, and `gt`, `gte`, `lt`, `lte`. A compare fails only when both sides are numbers or non-empty strings (ISO dates compare as text) and the comparison is false. `valueField` in place of `value` compares with another field (`{field: "end", operator: "gte", valueField: "start"}`). A `valueField` naming an undeclared field skips the rule.

## Code anchors

- `api/lib/barkpark/content/cross_validator.ex`
