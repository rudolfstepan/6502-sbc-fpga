# REIST on FPGA — a benchmark engine

REIST (Remainder-Extended Inversion and Subtraction Technique) is my own
arithmetic idea: instead of the classical non-negative remainder `0 ≤ r < B`,
keep a **centered** remainder `-floor(B/2) ≤ r < ceil(B/2)`. For a running
modular value that turns the remainder into a signed correction term, so a
modular accumulation becomes one conditional add/subtract per step instead of a
division. The CPU side of this is measured in a separate project
(`reist-crypto-bench`, ARMv8-A and x86-64). This page is about the **hardware**
side: a standalone FPGA engine that pits REIST against a real vendor integer
divider on a Tang Primer 20K, and what the silicon actually says.

It lives entirely on its own — it shares no files with the 6502 SBC and only
reuses the `uart_tx_ser` serializer plus the generated Gowin divider IP. The
build quickstart is in [`boards/tang_primer_20k/reist/README.md`](../boards/tang_primer_20k/reist/README.md).

## The idea in one step

With `acc` and the addend `x` both already centered in `[-floor(B/2), ceil(B/2))`,
their sum lands in `(-B, B)`, so a single conditional correction brings it back:

```
lo = -floor(B/2)        hi = lo + B = ceil(B/2)
if  sum >= hi : sum - B
if  sum <  lo : sum + B
else          : sum
```

That is the whole REIST datapath — a comparator, an adder/subtractor and a mux
(`rtl/reist/reist_core.vhd`). No divider, no loop. It is correct for odd and
even `B` (the floor/ceil split handles the parity), checked against the
`reist_res()` reference in simulation.

## What we compare against

The honest baseline is not a hand-rolled divider but the **Gowin Integer
Division soft IP** — the thing a designer would actually instantiate for `a mod B`.
The version generated here is 32-bit with `LATENCY=2` (a pipeline, throughput 1,
no valid/ready). The engine drives it through a thin wrapper
(`rtl/reist/ip_divider_ip.vhd`); in simulation a behavioural model
(`rtl/reist/ip_divider.vhd`, generic `LATENCY`) stands in so the whole thing
runs in GHDL without the encrypted IP.

The one insight that makes the comparison fair: **modular accumulation is a
dependency chain.** Each step needs the previous result (`acc <- reduce(acc + x)`),
so a pipelined divider cannot overlap iterations — it pays its full latency every
step. That is exactly where REIST's one-cycle correction earns its keep, and it
holds against a pipelined IP, not just a naive one.

## How it is tested

Two layers, both reproducible.

### Cycle counts (the engine)

`rtl/reist/reist_bench_engine.vhd` sweeps a list of moduli (251, 256, 1009,
65521 — odd/even, small/large) and measures three clock-cycle counts per modulus
over `N_ITERS` modular additions:

| Column | What it times |
| --- | --- |
| `R` (REIST) | centered correction in a dependency chain, 1 cycle/step |
| `D` (IP dep) | the same dependency chain reduced by the divider IP — issue, wait the latency, feed back |
| `I` (IP ind) | independent reductions streamed through the pipelined IP, one issue per clock |

In simulation (`make reist GHDL=ghdl`) `tb_reist_core` checks the math against
software references and `tb_reist_bench` prints the counts. On hardware
`reist_top` runs the sweep once at power-up and reports over UART (115200 8N1),
one hex line per modulus: `B= R= D= I=`.

### Area and Fmax (the probes)

Cycles are only half the story. Two tiny tops with an **identical** harness
(LFSR → input regs → adder → reduction → output reg → probe pin) isolate the cost
of one reduction unit, differing only in that unit:

- `reist_reduce_top` — the REIST correction.
- `ip_reduce_top` — the Gowin division IP.

Build each (`boards/tang_primer_20k/reist/area/`, its own `.gprj` or the
`gw_sh *_build.tcl` script) and read the resource and timing reports. The
`area_probe.sdc` constrains a tight 250 MHz so the report shows the true Max
Frequency.

## Results (measured on hardware)

### Cycle counts — `N_ITERS = 1024`, all moduli identical (data-independent)

| | hex | cycles | per step |
| --- | --- | ---: | ---: |
| REIST | `0x400` | 1024 | **1** |
| IP, dependency chain | `0x1000` | 4096 | **4** |
| IP, independent stream | `0x402` | 1026 | ~1 (throughput) |

### Area and Fmax — REIST vs. the IP (`LATENCY=2`)

| Metric | REIST | IP (divide) | REIST advantage |
| --- | ---: | ---: | ---: |
| Logic (LUT + ALU) | 101 | 1276 | **12.6× smaller** |
| Registers (FF) | 84 | 193 | 2.3× fewer |
| DSP | 0 | 0 | — |
| Max frequency | **161.8 MHz** | **8.1 MHz** | **20× faster** |

The IP at `LATENCY=2` packs a 32-bit divide into two pipeline stages, so each
stage is an enormous combinational path — hence only 8.1 MHz. REIST's correction
is a comparator and an adder, so it closes at 161.8 MHz in the same harness.

### Putting cycles and Fmax together (wall-clock per step)

| Workload | REIST | IP | REIST faster by |
| --- | ---: | ---: | ---: |
| Dependency chain | 1 cyc @161.8 MHz = 6.2 ns | 4 cyc @8.1 MHz = 494 ns | **~80×** |
| Independent stream | 6.2 ns/result | 124 ns/result | **~20×** |

So the apparent cycle-count "tie" for independent work disappears once Fmax is in
the picture: against this IP, REIST wins on area, on clock, and on real-time
throughput in both workloads.

## Honest caveats

- The IP's latency is a knob. At `LATENCY=2` its Fmax is awful (8 MHz); spending
  more pipeline stages would raise the Fmax but lengthen the latency — which
  makes the **dependency-chain** case worse for the IP (latency is paid in full
  there) while only helping the **independent** case. REIST avoids the tradeoff
  entirely: small, fast, one cycle. A second IP build at a high latency (e.g. 16)
  would pin down the other end of that tradeoff and is the next thing to add.
- The `D` figure includes a little issue/capture overhead in the feedback loop;
  the pure architectural floor from latency is 2:1. Either way REIST wins.
- REIST replaces only the **reduction** in modular addition/accumulation. It is
  not a general divider or a multiplier. For real division you still need a
  divider; for `(a*b) mod B` you would pair a DSP multiply with a REIST (or
  Barrett/Montgomery) reduction.
- The classical baseline is the `%`/divider path, matching the methodology of
  the REIST paper — not a claim against Barrett or Montgomery reduction.

## What is coming

- **High-latency IP variant** as a second baseline column (close the tradeoff
  argument completely).
- **Modular-multiply path**: DSP multiply followed by REIST vs. IP-divide
  reduction, to show REIST in the multiply context.
- **Decimal UART report** (double-dabble) instead of hex, for readability.
- More **moduli and word widths** (16/64-bit) to chart how the divider's latency
  and area grow while REIST stays flat.
- A possible **memory-mapped REIST coprocessor** for the 6502 SBC itself (the
  `$88B0` FPU pattern), so software can use centered reduction directly.

## Files

| Path | Role |
| --- | --- |
| `rtl/reist/reist_pkg.vhd` | width, modulus list, software references |
| `rtl/reist/reist_core.vhd` | the centered-correction step |
| `rtl/reist/reist_bench_engine.vhd` | FSM, three measured paths |
| `rtl/reist/bench_report.vhd` | UART hex report |
| `rtl/reist/ip_divider.vhd` / `ip_divider_ip.vhd` | divider IP — sim model / Gowin wrapper |
| `rtl/reist/seq_divider.vhd` | restoring divider (unit testbench only) |
| `boards/tang_primer_20k/rtl/reist_top.vhd` | benchmark board top |
| `boards/tang_primer_20k/rtl/reist_reduce_top.vhd`, `ip_reduce_top.vhd` | area/Fmax probes |
| `boards/tang_primer_20k/reist/` | Gowin projects (`reist_bench`, `area/`), constraints, README |
| `sim/tb/tb_reist_core.vhd`, `tb_reist_bench.vhd` | testbenches (`make reist`) |
