@echo off
setlocal
cd /d D:\agent-workspace\rv64gc-v2
echo === test_call ===
call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_xsim_sim --runall ^
    --testplusarg "MEMFILE=tests/hex/test_call.hex" ^
    --testplusarg "MAX_CYCLES=50000" ^
    --testplusarg "NOVCD"
echo === rv64ui_branch ===
call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_xsim_sim --runall ^
    --testplusarg "MEMFILE=tests/hex/rv64ui_branch.hex" ^
    --testplusarg "MAX_CYCLES=50000" ^
    --testplusarg "NOVCD"
endlocal
