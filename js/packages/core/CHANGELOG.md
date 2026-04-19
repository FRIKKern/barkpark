# @barkpark/core

## 1.0.0-preview.2

### Patch Changes

- [#24](https://github.com/FRIKKern/barkpark/pull/24) [`47b96c8`](https://github.com/FRIKKern/barkpark/commit/47b96c8b28ab8901be5fe971ba7762dcfdffd662) Thanks [@FRIKKern](https://github.com/FRIKKern)! - fix: SDK query()/doc() now read Phoenix's flat envelope shape (`data.documents` and `data` directly), not the non-existent `data.result` wrapper. Resolves shake-down defects #16 and #18.

## 1.0.0-preview.0

### Major Changes

- [#13](https://github.com/FRIKKern/barkpark/pull/13) [`1cc653b`](https://github.com/FRIKKern/barkpark/commit/1cc653be24c23bc5533b0b1a04da527a8518d562) Thanks [@FRIKKern](https://github.com/FRIKKern)! - Phase 8 beta: first `@preview` publish targeting 1.0.0. No breaking changes from Phase 7. Packages now enter Changesets pre-mode under the `preview` dist-tag.
