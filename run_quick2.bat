@echo off
cd /d D:\agent-workspace\rv64gc-v2
call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_xsim_sim --runall --testplusarg "MEMFILE=tests/hex/rv64ui_add.hex" --testplusarg "MAX_CYCLES=5000" --testplusarg "NOVCD"
