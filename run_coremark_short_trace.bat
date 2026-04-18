@echo off
setlocal
cd /d D:\agent-workspace\rv64gc-v2
call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_xsim_sim --runall ^
    --testplusarg "MEMFILE=tests/hex/coremark.hex" ^
    --testplusarg "MAX_CYCLES=5000" ^
    --testplusarg "NOVCD" ^
    --testplusarg "TRACE_LEAK"
endlocal
