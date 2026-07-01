---
'@barkpark/core': minor
---

**Added:** `client.getAssetSearchSuggestions(prefix?, opts?)` — typeahead suggestions for a media search box (`GET /v1/media/:dataset/search/suggestions`): the caller's `recent` queries, the dataset's `popular` ones, and recent `nohits` (searches that returned nothing — a content-gap signal). `prefix` filters each bucket as the user types. Completes the media-search UX started with `searchAssets` (#585); the API's search-intelligence had suggestions but the SDK didn't expose them. New `AssetSearchSuggestions` / `AssetSearchSuggestion` / `AssetSearchSuggestionsOptions` types.
