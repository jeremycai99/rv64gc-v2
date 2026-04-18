@echo off
cd /d D:\agent-workspace\rv64gc-v2
if exist xsim.dir rmdir /s /q xsim.dir
call D:\Xilinx\Vivado\2024.1\bin\xvlog.bat --sv --relax -d SIMULATION ^
  src\rtl\core\include\rv64gc_pkg.sv ^
  src\rtl\core\include\isa_pkg.sv ^
  src\rtl\core\include\uarch_pkg.sv ^
  src\rtl\sim\mem_if_pkg.sv ^
  src\rtl\core\fetch\rvc_decompress.sv ^
  src\rtl\core\fetch\btb.sv ^
  src\rtl\core\fetch\ras.sv ^
  src\rtl\core\fetch\tage_sc_l.sv ^
  src\rtl\core\cache\icache_tag_ram.sv ^
  src\rtl\core\cache\icache_data_ram.sv ^
  src\rtl\core\cache\icache.sv ^
  src\rtl\core\fetch\next_line_prefetch_buffer.sv ^
  src\rtl\core\fetch\fetch_unit.sv ^
  src\rtl\core\decode\decode_slice.sv ^
  src\rtl\core\decode\decode.sv ^
  src\rtl\core\decode\fusion_detector.sv ^
  src\rtl\core\loop_buffer.sv ^
  src\rtl\core\rename\rat.sv ^
  src\rtl\core\rename\free_list.sv ^
  src\rtl\core\rename\checkpoint.sv ^
  src\rtl\core\rename\rename.sv ^
  src\rtl\core\dispatch\dispatch_queue.sv ^
  src\rtl\core\issue\wakeup_network.sv ^
  src\rtl\core\issue\issue_queue.sv ^
  src\rtl\core\execute\alu.sv ^
  src\rtl\core\execute\bru.sv ^
  src\rtl\core\execute\multiplier.sv ^
  src\rtl\core\execute\divider.sv ^
  src\rtl\core\regfile\int_prf.sv ^
  src\rtl\core\bypass_network.sv ^
  src\rtl\core\backend\rob.sv ^
  src\rtl\core\backend\commit.sv ^
  src\rtl\core\lsu\store_queue.sv ^
  src\rtl\core\lsu\load_queue.sv ^
  src\rtl\core\lsu\committed_store_buffer.sv ^
  src\rtl\core\lsu\lsu.sv ^
  src\rtl\core\cache\dcache_tag_ram.sv ^
  src\rtl\core\cache\dcache_data_ram.sv ^
  src\rtl\core\cache\dcache.sv ^
  src\rtl\core\cache\l2_cache.sv ^
  src\rtl\core\csr\csr_file.sv ^
  src\rtl\sim\sim_memory.sv ^
  src\rtl\core\rv64gc_core_top.sv ^
  src\tb\tb_top.sv ^
  src\tb\tb_iverilog.sv
if errorlevel 1 exit /b 1
call D:\Xilinx\Vivado\2024.1\bin\xelab.bat --relax -s tb_iverilog_sim tb_iverilog
