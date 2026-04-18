@echo off
setlocal
cd /d D:\agent-workspace\rv64gc-v2
echo === Dhrystone 100K cyc + STAT_DUMP ===
call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_xsim_sim --runall ^
    --testplusarg "MEMFILE=tests/hex/dhrystone.hex" ^
    --testplusarg "MAX_CYCLES=100000" ^
    --testplusarg "NOVCD" ^
    --testplusarg "STAT_DUMP"
endlocal
