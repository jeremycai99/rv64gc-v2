@echo off
cd /d D:\agent-workspace\rv64gc-v2
call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_xsim_sim --runall --testplusarg "MEMFILE=tests/hex/test_ret.hex" --testplusarg "MAX_CYCLES=50000" --testplusarg "NOVCD"
