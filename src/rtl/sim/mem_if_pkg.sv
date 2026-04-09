/* file: mem_if_pkg.sv
 * Description: Memory interface package for simulation.  Defines types and
 *              constants used by sim_memory and the top-level testbench.
 * Version: 2.0
 */

`ifndef MEM_IF_PKG_SV
`define MEM_IF_PKG_SV
package mem_if_pkg;

    // Default simulation memory size: 256 MB
    localparam int SIM_MEM_SIZE_BYTES = 256 * 1024 * 1024;
    localparam int SIM_MEM_ADDR_BITS  = $clog2(SIM_MEM_SIZE_BYTES);  // 28

    // Cache-line width in bits (64 bytes = 512 bits)
    localparam int CACHE_LINE_BITS  = 512;
    localparam int CACHE_LINE_BYTES = 64;

endpackage
`endif
