DISPLAYD.R4X
============

DISPLAYD.R4X ist die Display- und Present-Diagnose.

Projektstruktur seit 0.51.21:
- `build.zig` baut die Diagnose als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4L-Imports und Contract.

Build:

    cd Code\System\Diagnostics\DisplayDiag
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Diagnostics\DisplayDiag\zig-out\DISPLAYD.R4X

Contract:
- Build-Profil: `Zig/R4XStart`
- R4XStart-Entry: `displayd_main`
- App-Klasse: `console`
- R4L-Imports: `R4SYS`, `R4DEV`, `R4DRAW`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\DIAG\DISPLAYD.R4X`
