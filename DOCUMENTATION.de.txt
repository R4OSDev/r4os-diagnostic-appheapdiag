APPHEAPD.R4X
============

APPHEAPD.R4X ist seit 0.53.6 die historisch benannte VM-/Allocator-
Diagnose. Sie prueft R4SYS VM V2, den SDK-Allocator V2 und dass AppHeap V1
im produktiven Memory-Snapshot nicht mehr sichtbar wird.
Seit 0.53.8 prueft sie auch `ProgramVmRegionInfo`-Statistiken. `/HOLDVM`
haelt eine explizite R4X-VM-Region mit logischem Commit und resident
beruehrten Pages offen, damit MEMSUITE Kill-while-Commit-Cleanup messen kann.

Projektstruktur seit 0.51.21:
- `build.zig` baut die Diagnose als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4L-Imports und Contract.

Build:

    cd Code\System\Diagnostics\AppHeapDiag
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Diagnostics\AppHeapDiag\zig-out\APPHEAPD.R4X

Contract:
- Build-Profil: `Zig/R4XStart`
- R4XStart-Entry: `appheapd_main`
- App-Klasse: `console`
- R4L-Imports: `R4SYS`, `R4DEV`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\DIAG\APPHEAPD.R4X`
