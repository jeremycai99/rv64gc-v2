@echo off
REM ============================================================================
REM run_dsim.bat -- run a test/benchmark under DSim 2026
REM
REM Usage:
REM   run_dsim.bat path\to\test.hex [MAX_CYCLES]
REM
REM Example:
REM   run_dsim.bat tests\benchmarks\coremark_O2.hex 500000
REM
REM Produces:
REM   dsim_run.log    -- simulation log (IPC, SVA fires, final summary)
REM   run.mxd         -- MXD waveform (assertion-aware; open in DSim Studio)
REM ============================================================================
setlocal
cd /d D:\agent-workspace\rv64gc-v2

if "%DSIM_HOME%"=="" set DSIM_HOME=C:\Program Files\Altair\DSim\2026

if not exist "%DSIM_HOME%\shell_activate.bat" (
    echo ERROR: DSim not found at %DSIM_HOME%.
    exit /b 1
)

if "%~1"=="" (
    echo Usage: run_dsim.bat ^<hex_path^> [MAX_CYCLES]
    exit /b 1
)

set HEX=%~1
set MAX_CYC=%~2
if "%MAX_CYC%"=="" set MAX_CYC=200000

call "%DSIM_HOME%\shell_activate.bat"

if "%DSIM_LICENSE%"=="" (
    if exist "%LOCALAPPDATA%\metrics-ca\dsim-license.json" (
        set DSIM_LICENSE=%LOCALAPPDATA%\metrics-ca\dsim-license.json
    )
)

if not exist dsim_work\tb_image.so (
    echo ERROR: dsim_work\tb_image.so not found.  Run build_dsim.bat first.
    exit /b 1
)

REM -image     run the pre-compiled image (name resolved under dsim_work\)
REM -waves     MXD dump for assertion-aware wave viewer (compile used +acc)
REM -l         log file
REM +plusargs  forwarded verbatim to tb_xsim
dsim -image tb_image ^
     -waves run.mxd ^
     -l dsim_run.log ^
     +MEMFILE=%HEX% ^
     +MAX_CYCLES=%MAX_CYC%
set RC=%errorlevel%

if %RC% neq 0 (
    echo DSim run exited with code %RC%
) else (
    echo DSim run complete.  Log: dsim_run.log   Waves: run.mxd
)
exit /b %RC%
