@echo off
setlocal
cd /d D:\agent-workspace\rv64gc-v2
echo === xsim (CoreMark + TRACE_LEAK, 10000 cycles) ===
call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_xsim_sim --runall ^
    --testplusarg "MEMFILE=tests/hex/coremark.hex" ^
    --testplusarg "MAX_CYCLES=10000" ^
    --testplusarg "NOVCD" ^
    --testplusarg "TRACE_LEAK"
endlocal
