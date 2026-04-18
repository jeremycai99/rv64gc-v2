"""
Minimal pyuvm smoke test: confirms pyuvm 4.0.1 loads under cocotb 2.0.1
and can drive the counter DUT from a uvm_test.run_phase.  Purpose is
framework verification only; NOT a reference UVM env.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from pyuvm import uvm_test, uvm_env, uvm_root


class CounterEnv(uvm_env):
    pass


class CounterTest(uvm_test):
    def build_phase(self):
        self.env = CounterEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        dut.rst_n.value = 0
        dut.en.value    = 0
        for _ in range(3):
            await RisingEdge(dut.clk)
        dut.rst_n.value = 1
        await RisingEdge(dut.clk)

        dut.en.value = 1
        vals = []
        for _ in range(20):
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
            vals.append(int(dut.q.value))

        expected = [(i+1) % 16 for i in range(20)]
        assert vals == expected, f"mismatch:\n got={vals}\n exp={expected}"
        self.logger.info(f"pyuvm run OK, counter sequence: {vals}")
        self.drop_objection()


@cocotb.test()
async def pyuvm_counter_test(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await uvm_root().run_test("CounterTest")
