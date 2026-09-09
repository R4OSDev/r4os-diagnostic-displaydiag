# DISPLAYD.R4X

`DISPLAYD.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.1.5`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/DISPLAYD.R4X`
- Image scope: `test`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux:

    ./Build.sh

The diagnostic validates display discovery, legacy presentation and the
canonical bounded multi-region XRGB32 path, including backend/fallback
capabilities, exact work accounting, synchronous completion and
input-to-present ticks. Both the external CPU blitter and the boot framebuffer
CPU fallback are accepted. A completed fence means CPU store completion.

`DISPLAYD /STATE` reads the coherent display-owner snapshot: active and pending
owner/generation, policy, fallback reason, capabilities and saved boot mode.
It does not present a frame or probe hardware. Older kernels without the
optional R4DEV slot report it as unavailable. The normal smoke also accepts
CPU presentation onto native scanout (`native-cpu`); GPU completion is not
implied.

`DISPLAYD /BASELINE` runs bounded CPU reference scenes in RAM. Add `/PRESENT`
to submit diagnostic images to the active screen, `/SAMPLES=1..64` to select
the sample count (default 32), and `/SAVE=C:\TEMP\GFX.TXT` to save the report.
`/TRACE` prints progress outside the measured phases. The baseline records
monotonic render/composition/submit wall times, nearest-rank percentiles,
scheduler ticks, logical byte models, presentation results and available
hardware/clock metadata. Unavailable hardware fields, GPU timestamps and
visible presentation timing are identified explicitly. It does not measure
Desktop's compositor, physical bus traffic, concurrent processes or live DDC.

Run `Build.bat unit-test` or `./Build.sh unit-test` for the two focused host
checks of scene bounds/byte models and sample statistics.

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

`/BUFFERS` loads R4GFX and checks real software pixels and row padding,
shared BO imports, concurrent read maps, stale release and exact lifetime
balance. Four result structures cross from a resident header into an initially
nonresident page to verify publication outside memory owners. `/BUFFERS
/DRIVER` also requires this boot's successful EXAMPLE gfx-memory-test marker.
