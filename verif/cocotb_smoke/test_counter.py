"""
Minimal cocotb smoke test: drives a 4-bit counter, checks increment
behaviour, reset discipline, and the enable gate.  Purpose is to confirm
cocotb + iverilog + DSim tooling is functional in this environment.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge


async def _reset(dut, cycles=3):
    dut.rst_n.value = 0
    dut.en.value    = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_reset_then_count(dut):
    """Counter resets to 0, then counts on enable."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)
    assert int(dut.q.value) == 0, f"reset value wrong: {int(dut.q.value)}"

    dut.en.value = 1
    for i in range(1, 10):
        await RisingEdge(dut.clk)
        # One extra FallingEdge so reads settle
        await FallingEdge(dut.clk)
        assert int(dut.q.value) == i, f"expected {i}, got {int(dut.q.value)}"


@cocotb.test()
async def test_enable_gate(dut):
    """Counter does not advance when en=0."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    dut.en.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    frozen_val = int(dut.q.value)

    dut.en.value = 0
    for _ in range(20):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert int(dut.q.value) == frozen_val, (
        f"counter advanced while disabled: {frozen_val} -> {int(dut.q.value)}"
    )


@cocotb.test()
async def test_wraparound(dut):
    """4-bit counter wraps from 0xF to 0x0."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)
    dut.en.value = 1
    for _ in range(16):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert int(dut.q.value) == 0, f"wraparound failed, got {int(dut.q.value)}"
