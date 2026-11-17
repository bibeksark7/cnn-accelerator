import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

@cocotb.test()
async def test_counter(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start()) # Start Clock

    dut.rst.value = 1
    dut.en.value = 0
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    dut.en.value = 1

    expected = 0

    for _ in range(300):
        await RisingEdge(dut.clk)
        await ReadOnly()
        expected = (expected + 1) % 256
        assert int(dut.count.value) == expected, f"got {int(dut.count.value)}, expected {expected}"
