# Flat::Schema

**Flat::Schema** is the second module in the Flat::* series.

It consumes reports produced by **Flat::Profile** and generates a **deterministic, inspectable schema contract** describing what tabular data *should* look like — intended as the primary input to **Flat::Validate**.

## Status

This repository is under active development.

Current progress:
- Canonical schema structure (v1) established
- Deterministic JSON/YAML serialization implemented
- v1 type inference rules implemented (based on profile evidence)

Next milestones:
- Nullability inference + null-related issues (v1)
- User overrides (v1)
- Documentation pass + `minil dist` regen preview

## Design goals

- Streaming-first ETL ergonomics
- Real-world legacy data focus
- Explicit, predictable behavior (low human error)
- Deterministic output (identical inputs produce identical schemas)

## Notes

- POD in `lib/Flat/Schema.pm` is the documentation source of truth.
- `README.md` may be regenerated during release workflows; i'll keep it short and aligned with the POD.

