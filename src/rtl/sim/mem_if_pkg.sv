/* file: mem_if_pkg.sv
 Description: Memory interface package for simulation.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Revision history:
    - Apr. 09, 2026: Imported into rv64gc-v2 RTL tree.
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
