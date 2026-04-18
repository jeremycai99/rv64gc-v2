@echo off
REM ============================================================================
REM build_dsim.bat -- DSim Studio build for rv64gc-v2 (DSim 2026)
REM
REM Companion to build_xsim.bat.  DSim is the SVA/productivity simulator;
REM xsim remains authoritative for signoff (see doc/xsim_lessons_learned.md
REM addendum on the dual-simulator policy).
REM
REM Prereq: DSim 2026 installed via DSim Studio extension or the Altair One
REM Marketplace installer.  Default install location:
REM    C:\Program Files\Altair\DSim\2026
REM Override by setting DSIM_HOME before calling this script.
REM
REM Produces dsim_image\tb_image ready to run via run_dsim.bat.
REM ============================================================================
setlocal enabledelayedexpansion
cd /d D:\agent-workspace\rv64gc-v2

if "%DSIM_HOME%"=="" set DSIM_HOME=C:\Program Files\Altair\DSim\2026

if not exist "%DSIM_HOME%\shell_activate.bat" (
    echo ERROR: DSim not found at %DSIM_HOME%.
    echo Install DSim via the VS Code extension or set DSIM_HOME manually.
    exit /b 1
)

call "%DSIM_HOME%\shell_activate.bat"

REM --- License discovery -----------------------------------------------------
REM Free Individual License file placed by the DSim Studio extension after
REM Altair One sign-in.  Default path per QuickStartGuide.html §Setup.
if "%DSIM_LICENSE%"=="" (
    if exist "%LOCALAPPDATA%\metrics-ca\dsim-license.json" (
        set DSIM_LICENSE=%LOCALAPPDATA%\metrics-ca\dsim-license.json
    )
)
if "%DSIM_LICENSE%"=="" if "%ALTAIR_LICENSE_PATH%"=="" (
    echo ERROR: No DSim license configured.
    echo Free Individual License setup steps:
    echo   1. Open VS Code, click the DSim Studio activity bar icon
    echo   2. Click Sign In, complete Altair One OAuth in browser
    echo   3. The extension creates %LOCALAPPDATA%\metrics-ca\dsim-license.json
    echo      automatically.  Re-run this script.
    echo Alternative: download dsim-license.json from altairone.com/Marketplace
    echo   and set DSIM_LICENSE to its path.
    exit /b 1
)

REM DSim creates dsim_work\ (underscore) as the default work dir; -genimage
REM paths are resolved RELATIVE to that work dir, so use a bare name.
if exist dsim_work rmdir /s /q dsim_work

REM --- Compile + elaborate into a reusable image -----------------------------
REM  -sv                  treat all files as SystemVerilog regardless of suffix
REM  +define+SIMULATION   matches xsim -d SIMULATION; enables defensive ifdef
REM                       resets in int_prf / icache / dcache tag RAMs
REM  +acc+rwb             generate support for wave dump + toggle coverage
REM                       (required at compile for -waves to work at runtime)
REM  -top tb_xsim         top-level module
REM  -genimage            write compiled code to given path; do not run
REM  -l                   log file (compile messages + errors)
REM  SVA is enabled by default; use -no-sva to disable if needed.
dsim -sv +define+SIMULATION +acc+rwb ^
     -top tb_xsim ^
     -genimage tb_image ^
     -l dsim_build.log ^
     src\rtl\core\include\rv64gc_pkg.sv ^
     src\rtl\core\include\isa_pkg.sv ^
     src\rtl\core\include\uarch_pkg.sv ^
     src\rtl\sim\mem_if_pkg.sv ^
     src\rtl\core\fetch\rvc_decompress.sv ^
     src\rtl\core\fetch\btb.sv ^
     src\rtl\core\fetch\ras.sv ^
     src\rtl\core\fetch\tage_sc_l.sv ^
     src\rtl\core\cache\icache_tag_ram.sv ^
     src\rtl\core\cache\icache_data_ram.sv ^
     src\rtl\core\cache\icache.sv ^
     src\rtl\core\fetch\next_line_prefetch_buffer.sv ^
     src\rtl\core\fetch\fetch_unit.sv ^
     src\rtl\core\decode\decode_slice.sv ^
     src\rtl\core\decode\decode.sv ^
     src\rtl\core\decode\fusion_detector.sv ^
     src\rtl\core\loop_buffer.sv ^
     src\rtl\core\rename\rat.sv ^
     src\rtl\core\rename\free_list.sv ^
     src\rtl\core\rename\checkpoint.sv ^
     src\rtl\core\rename\rename.sv ^
     src\rtl\core\dispatch\dispatch_queue.sv ^
     src\rtl\core\issue\wakeup_network.sv ^
     src\rtl\core\issue\issue_queue.sv ^
     src\rtl\core\execute\alu.sv ^
     src\rtl\core\execute\bru.sv ^
     src\rtl\core\execute\multiplier.sv ^
     src\rtl\core\execute\divider.sv ^
     src\rtl\core\regfile\int_prf.sv ^
     src\rtl\core\bypass_network.sv ^
     src\rtl\core\backend\rob.sv ^
     src\rtl\core\backend\commit.sv ^
     src\rtl\core\lsu\store_queue.sv ^
     src\rtl\core\lsu\load_queue.sv ^
     src\rtl\core\lsu\committed_store_buffer.sv ^
     src\rtl\core\lsu\lsu.sv ^
     src\rtl\core\cache\dcache_tag_ram.sv ^
     src\rtl\core\cache\dcache_data_ram.sv ^
     src\rtl\core\cache\dcache.sv ^
     src\rtl\core\cache\l2_cache.sv ^
     src\rtl\core\csr\csr_file.sv ^
     src\rtl\sim\sim_memory.sv ^
     src\rtl\core\rv64gc_core_top.sv ^
     src\tb\tb_top.sv ^
     src\tb\tb_xsim.sv
if errorlevel 1 (
    echo DSim compile failed -- see dsim_build.log
    exit /b 1
)

echo.
echo DSim build OK.  Image at dsim_work\tb_image
echo Run with:  run_dsim.bat ^<hex_path^> [MAX_CYCLES]
exit /b 0
