# APPHEAPD.R4X

`APPHEAPD.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.1.2`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/APPHEAPD.R4X`
- Image scope: `test`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

The normal diagnostic also runs bounded small- and direct-allocation churn,
checks VM call deltas and cache limits, and explicitly trims every reusable
region before returning.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
