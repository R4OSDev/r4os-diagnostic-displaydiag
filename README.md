# DISPLAYD.R4X

`DISPLAYD.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.1.11`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/DISPLAYD.R4X`
- Image scope: `full`
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
CPU fallback are accepted. Fence completion follows the selected backend's
milestone; CPU stores or device execution do not prove visible VBlank.

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

`/QUEUES` performs two asynchronous 8-MB software-buffer copies linked by an
explicit fence, releases the producer references early and verifies actual
bytes, untouched padding and balanced backing after the resource wait.
`/QUEUES /DRIVER` also requires `OPTION EXAMPLE mode=gfx-queue-test`. It checks
logical cancellation before physical retirement, three concurrent waiters,
timer-IRQ completion, stale reset generations and hard-kill of a producer
with three blocked graphics tasks. `/QUEUECHILD` is its internal subprocess
fixture and intentionally leaves handles to process cleanup. These modes
do not perform GPU DMA, visible presentation or HDMI-audio tests. The SMP4
acceptance additionally injects the `g` key and verifies SSH progress while
the first driver resource wait is pending.

`/RECEIVERS` reads the shared R4DRAW catalog, generation identities and receiver
status, then uses the common R4GFX EDID parser for monitor name, extension
counts, colors and audio facts. Receiver-only entries have no source/modeset
qualification. A changing catalog requests a fresh complete read; missing EDID
does not identify the monitor power state. This command never submits a frame
or performs PCI, DDC or GPU accesses.

`/OUTPUTS` checks the fixed firmware connector, exact boot geometry and
EDID availability, rejects invalid composite state without device changes,
and commits only retention of the existing firmware scanout.
`/OUTPUTS /DRIVER` additionally drives EXAMPLE's explicit virtual output fixture:
disconnect, a new receiver generation, reset, stale identity rejection and
the existing desktop activity wait. Neither option programs a native mode
or claims physical HDMI/DisplayPort detection. BO resources must balance.

Build.bat and Build.sh launch the same Build.ps1 and the SDK's shared module
builder, including caller-supplied Zig arguments and local library paths.

`/VIRTIO` prints the driver's bounded structured boot records. `/VIRTIO /TEST`
presents 32 alternating sparse frames and checks exact shared-BO lifetime
balance. `/VIRTIO /RESIZE` additionally expects the explicit distribution
runner to change the host's virtual monitor twice during its five-second
idle windows; it verifies new receiver generations, stale EDID rejection
and retained active source geometry. `/VIRTIO /FAIL` requires the explicit
VIRTGPU `mode=timeout` fixture and checks third-frame failure, acknowledged
bootfb recovery and release of the native BO and attachment lease.
The runner verifies 16384 captured pixels in each of two QMP screenshots.
These modes prove virtual device execution; they do not measure VBlank.

`DISPLAYD /NVIDIA [text]` replays complete bounded NVIDIA driver boot records.
An optional case-insensitive substring of up to 128 bytes selects relevant
lines, e.g. `/NVIDIA boot-` or `/NVIDIA rejected`, to keep SSH output small.
No match is reported explicitly with exit status 1; no filter preserves the
complete replay. The reader retains its existing 64-KB boot-log bound.
It does not probe PCI/MMIO or infer native GPU, connector or HDMI audio
support from a PCI name. Missing records are reported as unavailable.
The passive NVIDIA owner and physical hardware acceptances remain separate.
