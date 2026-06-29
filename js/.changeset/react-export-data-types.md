---
'@barkpark/react': minor
---

Export the data-shape types the component props accept — `ImageAsset` (+ `ImageAssetRef`/`ImageAssetExpanded`/`ImageAssetMetadata`), `PortableTextNode`/`PortableTextBlock`/`PortableTextSpan`/`PortableTextMarkDef`/`CustomBlock`, and `RefInput`/`ResolvedDoc`/`BarkparkReferenceClient`. Previously only the `*Props` types were exported, so consumers couldn't type their own image/rich-text/reference fields without redefining them.
