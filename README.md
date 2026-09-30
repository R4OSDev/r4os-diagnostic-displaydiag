# DISPLAYD.R4X

`DISPLAYD.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.1.60`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/DISPLAYD.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

Version60 additionally opens two native COPY-only queues on NVIDIA185. Six
CE0 jobs compare three distinct patterns and complete readback guards; the
first queue must retire native resources before the second executes again.
Driver receipts independently identify the shared context/method storage and
distinct channel/FIFO/USERD ownership. Build6/6 and SMP4/KVM60.24s pass.
Physical185/60 passes265CE/27native/8images/73138772 exact bytes with full
settled balance and no reset. The two channels share context0:3/methods20KB,
with CHID24/32 and2/4 completed jobs. Archive physical185. NVIDIA186 repeats this complete matrix and qualifies
private control initial clear in its driver before backend publication; its
normal post-GPU restart and fresh short CE/GR probe pass (physical186).

Version59 extends `/NVIDIAMEM` with whole-allocation raw VA copies around
the eight existing image cases. It fills all native bytes with A5 before
logical writes and then compares every pixel byte, GOB/pitch padding byte,
64KB plane tail and readback guard against an independent Mesa TuringColor2D
coordinate oracle. The existing host unit-test step checks its fixed original
sector table. These checks target native VA representation under the MMU
kind; they are not a direct physical memory-controller dump. Physical59 on
NVIDIA184 passes265 canonical CE/21 native jobs,8 images and73077332 exact
bytes, including653694 native padding bytes and32768 guard bytes. Complete
500ms settled balance and no reset are confirmed. Build6/6, unchanged oracle
unit-test5/5steps3/3 and fresh SMP4/KVM60.53s pass. Version58 had requested
non-page-aligned system VA bindings and was rejected before raw GPU work;
59 allocates a complete logical guard page and preserves the failing API code.

`DISPLAYD /AMDCOMPILER` runs the loaded optional R4ACO compiler in real
R4SYS workers. It compiles six SPIR-V graphics/compute/texture fixtures, records
GFX9 code identities and tests OOM retirement, deadline, recovery and
checksummed atomic cache files under C:\TEMP. It is an explicit CPU-only
probe; no GPU command or physical-device access is performed.

`DISPLAYD /AMDRENDER` loads optional R4AMD `RENDER_V1` and `IMAGE_V1`.
It hashes six embedded ACO programs and calls the real AddrLib and C++ PM4
encoders for pipeline, indexed and automatic draws. Invalid state, index
bounds and alias errors must preserve outputs. The addresses and Picasso
profile are synthetic; all work stays on the CPU.

`DISPLAYD /AMDIMAGE` exercises the optional R4AMD `IMAGE_V1` provider on
the CPU. It verifies actual loaded AddrLib surface/address/mip/metadata and
descriptor calls, C++ relocations, modifier rejection and bounded OOM. The
Picasso profile and GPU address are synthetic; no device, BO or MMIO is used.
A missing provider reports unavailable. This explicit diagnostic has no
automatic boot or physical-hardware probe.

With the explicit EXAMPLE `gfx-allocation-test` fixture, `/BUFFERS` also checks
native request dispatch/wait, canonical BO transfer/import/release, stale
memory generations and unchanged failure outputs. The provider has synthetic
backing and never executes GPU work. Without that fixture the normal check
retains its software scope.

Baseline schema 2 accepts bootfb and native CPU presentation and reports the
loaded driver/firmware policy. Its 15-second cap bounds the entire measurement.
All requested samples must succeed and backend/geometry must remain unchanged.
Logical byte models, wall spans, coarse scheduler ticks and actual completion
milestones are separate. Eight-sample p95/p99 are maxima, not tail-confidence
estimates. See Docs/Desktop/GrafikIntegration07944.txt.

`DISPLAYD /AMDPROFILE` explicitly runs the fixed 256x128 fill/copy scene on
an AMD DEVICE_V1 backend. `/AMDPROFILE SOFTWARE` selects the same dimensions
and colors on the CPU. The diagnostic reuses images and pipelines, verifies
all 32768 output pixels, and waits for exact resource retirement. It reports
upload, render, device copy and readback caller/wait wall intervals separately.
Allocation and warm-up are excluded. These spans are not GPU timers or FPS;
software copy labels describe the logical phases only. `/STATS`, `/STATE`
and `/POWER` separately expose presentation receipts, budgets and telemetry.
Physical qualification and the paired comparison belong to 0.80.39.

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

`DISPLAYD /POWER` requests bounded GPU telemetry collection and prints the
current shared cache without waiting or generating work. Run it again after
one second for updated data. P-state, firmware target clocks, temperature,
power, limits, utilization and GPU timer values retain explicit reliability
states. Unsupported devices report unknown. Timer deltas are sampling
intervals, not job durations; clocks are firmware targets. The optional
R4DRAW tail is available from Kernel 0.1.179.

`DISPLAYD /STATS [head-id]` reads one coherent native presentation snapshot
(default head 0), without submitting a frame. Acquire/render, Window submit,
visible activation and old-image release have separate counters. The latest
visible receipt includes its source queue fence, CE/Window points, raw GPU
timestamp and monotonic CPU observation times. These are independent of CPU
presentation fences; `released` counts completed scanout uses, not freed
allocations. Missing native reports are unavailable, including on bootfb.
The optional R4DRAW slot requires Kernel 0.1.162 or later; an older kernel
leaves the rest of DISPLAYD usable.

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
/DRIVER` also requires this boot's successful EXAMPLE gfx-memory-test and
ordinary-Work markers. If the optional deliberate init rejection is recorded,
it additionally requires the successful closed-owner cleanup marker. Version
0.1.13 exports these records for the same existing guest check.

Version 0.1.12 also imports the independent R4GFX `RENDER_V1` table. The same
`/BUFFERS` entrypoint executes a three-command fill/scaled-blit/source-over
scene on separate shared BO maps, checks exact colors and logical byte counts,
rejects an invalid final command without earlier pixel writes, then verifies
the original `API_V1` path and full resource balance. The source read lease
survives producer-reference release. Both interfaces come from R4GFX 0.1.1;
the scene reports `backend=software` and does not submit NVIDIA work.

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

`DISPLAYD /NVIDIASMOKE` runs two bounded32x16 CE/GR rounds through DEVICE_V1,
checks exact readback pixels and steady-state resource balance, and rejects
software backends. It does not present or query receivers. Initial driver
cache growth is reported separately; full driver retirement remains required.
NVIDIA178/Kernel235 pass both rounds and subsequent clean ordinary reboots
on OssiPC; output and manual display qualification remain separate.

`DISPLAYD /NVIDIAMEM` (0.1.60) uses the public native allocation and device
execution queue for raw VRAM transfers. It checks odd offsets and lengths,
31 readback guard bytes, and two patterns through the same system BO after
its original reference closes. The large system BO contains 34 MB plus
123 bytes (8705 pages); one native working buffer tries at most three shrinking sizes: 8 MB,
1 MB and 64 KB, each plus 5 bytes. Only an acknowledged OOM permits the
next candidate; other failures stop the probe. All its contents pass through GPU upload/readback in bounded parts.
A separate 64-MB native request must report OOM on the qualified GA106 heap,
followed by exact GPU work in the same epoch and a balanced resource count.
If another GPU can allocate that request, `OomNotReached` explicitly leaves
that criterion unqualified. This is an opt-in physical probe; software
backends fail before allocation. Version52 additionally spawns a bounded child that creates a patterned BO.
The parent imports the same BO and retains an explicit partial GPU mapping,
checks a CPU mapping across a page boundary, and copies before and after the
child is killed and reaped. The old producer reference must become stale while
the held GPU binding stays unchanged; child mappings retire before the range.
On physical180, all228 CE jobs and71377492 exact bytes pass, including
copies before/after child kill/reap. Final balance fails with a driver-side
mapping collection Retained error; this is not a passed lifetime acceptance.
NVIDIA181 removes that fatal retirement error; version52 then reveals a
premature baseline containing two warm-up mappings. Version53 waits for all
BO counters to remain identical for500ms with no pending/retained bytes;
exact before/after equality remains mandatory. Both the warm and fresh-boot
physical53 runs pass all228 CE jobs and71377492 exact bytes, with identical
BO/runtime counts and no reset. Normal181 shutdown releases all resources;
the restart returns after70.864 seconds without Wake-on-LAN.

Version55 adds eight129x41 XRGB/ARGB/NV12/P010 cases, each linear and
blocklinear. Frozen GA106 expectations check pitch, plane offsets, modifier,
alignment and size. Full rows and odd inner rectangles pass through CE into
separate system readback; all system row guards, plane gaps and tail bytes
are compared. These logical round trips do not independently prove native
GOB byte order or padded tail rows; explicit-VA raw copies cover that next.
Version54 incorrectly requested pitch bytes as logical row width; the common
owner correctly rejected the first image upload before a new GPU job.55 uses
the actual129/130-column plane widths and preserves the full system guards.
Physical55 passes all eight image cases:264 CE jobs,72180308 exact bytes
and identical settled BO/runtime counts, no fatal/reset/retained resources.
Build6/6, SMP4/KVM60.74s and full installed hash passed.
Version56 adds five native CE pushes through public explicit-VA bindings:
a16KB known pattern seeded by canonical CE, two system sources remapped at
the same VA, unaligned copies and complete separate readback guards. Every
push checks its own CE semaphore and the driver's device-execution fence;
its native producer queue and all child mappings retire before final balance.
Physical56 exposed the corrected NVIDIA183 GR/CE topology bug, then a real
XID13 because the public CE encoder used subchannel0 alongside GR. Version57
requires the new R4NV16 encoding feature and selects CE subchannel4.
Physical57 passes all265 canonical CE and5 native VA jobs,8 logical images,
72241748 exact bytes and identical settled BO/runtime balance without reset.
The previous183/56 XID13 retirement stalls atFIFO0 and requires a poweroff
and one Wake. NVIDIA184 fixes that reset-retirement defect: the same actual
XID13 retires all resources during headless terminal shutdown, ordinary reboot
returns in68.1223261s without Wake and fresh CE/GR work passes. Version59
adds the raw GOB/padding proof above. Shared-context hardware channels and
private initial-clear pattern checks remain open.
NVIDIA179 physically handles
the 49/50 allocation denials without losing the GPU or retaining resources;
CE/GR work after denial passes. On OssiPC,51 completes222 CE jobs and
71352844 exact byte checks across8705 pages using1MB+5 native storage,
including OOM/follow-up and full BO/runtime balance.

`DISPLAYD /NVIDIA [text]` replays complete bounded NVIDIA driver boot records.
An optional case-insensitive substring of up to 128 bytes selects relevant
lines, e.g. `/NVIDIA boot-` or `/NVIDIA rejected`, to keep SSH output small.
No match is reported explicitly with exit status 1; no filter preserves the
complete replay. The reader retains its existing 64-KB boot-log bound.
It does not probe PCI/MMIO or infer native GPU, connector or HDMI audio
support from a PCI name. Missing records are reported as unavailable.
The passive NVIDIA owner and physical hardware acceptances remain separate.

Queue resource handoff (0.79.11): the existing explicit queue fixture now
checks the legacy 56-byte canary, mapping-only BO references from ordinary
Work after producer exit, exact offset/DMA correspondence, retained device
leases and balanced release after the timer IRQ. No GPU commands run.
DISPLAYD exports these records; the focused SMP4 run injects one key and
uses no guest networking. Evidence: Docs/Drivers/GrafikSpeicher07911.json.

0.79.11 residency boundary: the existing queue fixture uses 4091-byte BOs
and 4079-byte offset jobs, while mapping-only references retain full 4096-byte
DMA/GPU pages. Focused SMP4 passes; evidence: native_buffer_checkpoint
in Docs/Drivers/GrafikSpeicher07911.json.

0.79.11 owned backing: the existing memory fixture checks the preserved
112-byte R4D prefix, native reservations/tickets and independent system
collection through real Init/Work/closing Shutdown. Synthetic backing only;
focused SMP4 passes. Evidence: owned_vram_checkpoint in GrafikSpeicher07911.json.

DEVICE_V1 revision2 in /BUFFERS queues two dependent row copies before waiting
for the final job. Source/target/staging use pitches16/24/32; six pixels are
copied through each hop, untouched pixels remain zero and the complete16-pixel
readback is checked. `copy-bytes=48 completed=2 dependencies=1` reports logical
bytes. backend1 is the common CPU queue; backend2 denotes actual native queue
completion. This small diagnostic allocates its BOs in system RAM; it does not
by itself qualify native VRAM layouts. Driver models and physical follow-up are
documented in Docs/Drivers/GrafikCopy07918.txt/.json and OssiGPU.txt /18.

The same `/BUFFERS` entrypoint optionally loads R4NV `SHADER_V1` and checks
one actual compiled SM86 fragment program through its byte-cache interface.
A synthetic device identity allows this software boundary check on any host:
changed driver identity and damaged code must return cache misses before the
original entry returns its header/code ranges. `software-cache` identifies
this result; no NVIDIA commands or GPU pixels are involved. A missing optional
shader interface reports `unavailable` and preserves the other diagnostics.


## Runtime compiler diagnostic

`DISPLAYD /COMPILER` explicitly loads the optional R4NAK `COMPILER_V1`
interface and translates a self-authored SPIR-V fragment shader on R4OS.
One bounded group checks SM75/86/89/120 output hashes, reproducibility,
changed source, worker OOM recovery, deadline, malformed/aliased input,
driver/GPU/ABI/format/generation cache identity, corruption/truncation,
atomic disk-cache publication and seven format descriptions. Temporary cache
files use private program-generation names under C:\TEMP and are removed.
Missing R4NAK reports a diagnostic failure; normal display commands remain
usable. This mode does not execute GPU work or establish hardware support.

Loaded versions (0.1.36)
------------------------
/STATE also prints the shared loaded-driver/fallback projection. /DRIVER N
reads one exact runtime owner from R4DEV driver_module_info; use the owner
reported by /STATE for native graphics. It reads retained container metadata,
not the potentially newer installed file. Firmware-bundle is a declaration,
not proof of device execution. Absent owners return an explicit absent result;
unsupported/busy APIs return a failure instead of synthesizing a version.

## Resource balance (0.79.43)

Existing `/BUFFERS`, `/QUEUES`, `/OUTPUTS` and `/VIRTIO` probes compare every
current BO counter, including backing, pins, mappings and pending destruction.
`/QUEUES` also compares current IRQ registration counts, work/deadline slots and
waiters with a 1000-ms bound for deferred cleanup. Historical counters and total
system timer counts are not substituted for live resource counts. The Virtio
timeout case checks the exact retiring primary BO and unchanged other counters.
Software evidence: workspace Docs/Deployment/GrafikStabilitaet07943.txt; SMP4
logs belong to Distribution/Tests/Reports/0.79.43. Physical NVIDIA evidence is separate.
