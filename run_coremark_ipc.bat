@echo off
setlocal
cd /d D:\agent-workspace\rv64gc-v2
echo === xsim (CoreMark IPC measurement, 500000 cycles, NO TRACE) ===
call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_xsim_sim --runall ^
    --testplusarg "MEMFILE=tests/hex/coremark.hex" ^
    --testplusarg "MAX_CYCLES=500000" ^
    --testplusarg "NOVCD"
endlocal
