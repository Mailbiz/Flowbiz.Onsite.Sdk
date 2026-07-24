# shared/fixtures

Cross-platform contract fixtures: event input → expected envelope JSON pairs.

Both SDKs (Android and iOS) consume these in their unit tests so that identical
event inputs produce equivalent envelope JSON (ignoring uuids/timestamps).
See SPEC.md §14. Populated in later slices.
