# Third-Party Notices

DISPLAYD compiles the R4GFX EDID helper from the separate Libraries project.
Its CTA timing table is derived from libdisplay-info under MIT, Copyright
(c) 2022 The libdisplay-info Contributors. Exact provenance and the complete
license are in `R4GFX/ThirdParty/DisplayInfo/` in that repository. The image
ships the notice as `/R4OS/LICENSES/libdisplay-info-MIT.txt`.
Original R4OS code remains Apache-2.0. No upstream parser code is copied.

`src/nvidia_gob.zig` adapts the inverse TuringColor2D layout from Mesa26.2.2
`src/nouveau/nil/copy.rs` and `tiling.rs` (MIT, Copyright2024 Valve Corp.
and Collabora, Ltd.). It independently checks raw NVIDIA VA readback and
padding; it does not reuse NVIDIA.R4D's layout planner. The full notice,
original file hashes and source archive provenance are in
`Licenses/NVIDIA-GOB-MIT.txt`, also embedded in DISPLAYD.R4X.
