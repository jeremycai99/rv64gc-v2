@echo off
cd /d D:\agent-workspace\rv64gc-v2
call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_xsim_sim --runall --testplusarg "MEMFILE=tests/hex/dhrystone.hex" --testplusarg "MAX_CYCLES=2000" --testplusarg "VCD_FOCUSED"
