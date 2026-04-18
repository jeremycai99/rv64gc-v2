@echo off
setlocal enabledelayedexpansion
cd /d D:\agent-workspace\rv64gc-v2
set PASS=0
set FAIL=0
set TOTAL=0

for %%t in (tests\hex\rv64ui_*.hex tests\hex\test_*.hex) do (
    set /a TOTAL+=1
    call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_xsim_sim --runall ^
        --testplusarg "MEMFILE=%%t" ^
        --testplusarg "MAX_CYCLES=50000" ^
        --testplusarg "NOVCD" 2>&1 | findstr /C:"PASS" /C:"FAIL" /C:"TIMEOUT" > tmp_result.txt
    set /p RESULT=<tmp_result.txt 2>nul
    if "!RESULT!" == "" (
        echo %%t: NO_RESULT
        set /a FAIL+=1
    ) else (
        echo %%t: !RESULT!
        echo !RESULT! | findstr /I "PASS" >nul && set /a PASS+=1 || set /a FAIL+=1
    )
)

echo.
echo ======================
echo TOTAL: !TOTAL!  PASS: !PASS!  FAIL: !FAIL!
echo ======================
del tmp_result.txt 2>nul
endlocal
