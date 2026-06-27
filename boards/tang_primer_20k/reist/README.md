# REIST benchmark engine

A standalone FPGA project that measures REIST centered-remainder arithmetic
against a real **vendor integer-divider IP** (Gowin Integer Division), in
hardware. It shares no files with the 6502 SBC — it only instantiates the
reusable `uart_tx_ser` serializer plus the generated divider IP.

The main REIST project is the CPU benchmark suite
[**reist-crypto-bench**](https://github.com/rudolfstepan/reist-crypto-bench);
this is its hardware counterpart. Full write-up: [`docs/REIST.md`](../../../docs/REIST.md).

## What it does

For each modulus in `MODULI` (`rtl/reist/reist_pkg.vhd`) the engine runs
`N_ITERS` modular additions and reports three clock-cycle counts:

- **REIST** — centered accumulator `acc <- center(acc + x)` in a dependency
  chain. One conditional add/subtract per step (`reist_core`), **1 cycle/step**,
  no divider.
- **IPdep** — the *same dependency chain* reduced with the divider IP: issue,
  wait the IP's latency, feed the result back, repeat. A dependency chain cannot
  fill the IP's pipeline, so every step pays the full latency.
- **IPind** — *independent* reductions streamed through the pipelined IP, one
  issue per clock. This is the IP's best case (~`N`+latency).

## The honest result

Against the real Gowin Integer Division IP (a **2-cycle** pipelined divider for
32 bit), the cycle picture is:

| | per step | meaning |
| --- | --- | --- |
| REIST | 1 cyc | comparator + adder |
| IP, dependency chain | ~4 cyc | latency + issue/capture, can't pipeline |
| IP, independent stream | ~1 cyc (throughput) | pipeline filled |

So REIST wins clearly **in dependency chains** (the realistic modular-accumulate
pattern, as in `reist-crypto-bench`) and roughly **ties** a pipelined IP on
independent throughput. The larger, separate win is **area and Fmax**: REIST's
step is a comparator and an adder, while the IP is a full 32-bit divide — read
that off the synthesis resource/timing report after building.

> The `IPdep` figure includes the issue and capture overhead of feeding the IP
> in a loop; the raw latency ratio is 2:1. Either way the conclusion holds.

## Files

| File | Role |
| --- | --- |
| `rtl/reist/reist_pkg.vhd` | width, modulus list, software references |
| `rtl/reist/reist_core.vhd` | combinational centered correction (the REIST step) |
| `rtl/reist/reist_bench_engine.vhd` | FSM, three measured paths, result registers |
| `rtl/reist/bench_report.vhd` | streams the results over UART (hex) |
| `rtl/reist/ip_divider.vhd` | **simulation** model of the divider IP (GHDL flow) |
| `rtl/reist/ip_divider_ip.vhd` | **hardware** wrapper binding the Gowin IP (`work.ip_divider`) |
| `rtl/reist/seq_divider.vhd` | a plain restoring divider (used only by the unit testbench) |
| `src/integer_division/…` | the generated Gowin Integer Division soft IP |
| `boards/tang_primer_20k/rtl/reist_top.vhd` | board top: clock, reset, LEDs |
| `reist_bench.gprj` / `.cst` / `.sdc` / `build.tcl` | this Gowin project |

`ip_divider.vhd` and `ip_divider_ip.vhd` both declare entity `ip_divider`;
compile exactly one per flow — the behavioural model in GHDL, the IP wrapper in
GowinEDA. The engine instantiates `work.ip_divider` either way.

## Simulate (no hardware)

```sh
make reist GHDL=ghdl
```

`tb_reist_core` checks the centered correction and the reference divider;
`tb_reist_bench` runs the sweep with the behavioural IP model (`IP_LAT`) and
prints the per-modulus cycle counts — the simulation counterpart of the UART
report.

## Build and run on the board

Open `reist_bench.gprj` in GowinEDA, synthesize/place/route, program the board.
The benchmark is a one-shot: on power-up it runs once and prints one line per
modulus over the CH340 UART at **115200 8N1**:

```text
B=000000FB R=00000040 D=00000100 I=00000042
```

modulus, REIST cyc, IP dependency-chain cyc, IP independent cyc — all hex. LEDs
(active-low): `[0]` running, `[1]` done, `[2]` report sent, `[3]` heartbeat.

## The divider IP

The wrapper `ip_divider_ip.vhd` instantiates the generated `Integer_Division_Top`
(ports `clk, rstn, dividend[31:0], divisor[31:0], remainder, quotient`; a
fixed-latency pipeline, no valid/ready). If you regenerate the IP with a
different latency, set the wrapper/engine generic **`IP_LAT`** to match (Gowin
prints it in the instance name, e.g. `LATENCY=2`). The benchmark counts clock
cycles, so the result stays valid for any latency.

## Area / Fmax comparison (the other half)

Cycle counts are only half the story. The bigger REIST win against a divider IP
is logic size and clock speed. Two tiny probe tops in `area/` make that
measurable with an **identical harness** (LFSR → input regs → adder → reduction
→ output reg → probe pin); only the reduction unit differs:

| Top | Reduction | Project |
| --- | --- | --- |
| `reist_reduce_top` | `reist_core` (comparator + add/sub) | `area/reist_reduce.gprj` |
| `ip_reduce_top` | `Integer_Division_Top` (32-bit divide) | `area/ip_reduce.gprj` |

Open each `.gprj` in GowinEDA and run synthesis + place/route (no programming
needed — we only want the reports). Confirm the Top Module is the probe top, then
read from the reports:

- **Resource usage** — LUTs, registers, and DSPs (resource/utilisation report).
- **Max Frequency** — from the timing report (`area_probe.sdc` constrains a tight
  250 MHz so the achievable maximum is shown).

(`gw_sh reist_reduce_build.tcl` / `gw_sh ip_reduce_build.tcl` do the same from the
command line.)

Record both for each top:

- **Resource usage** — LUTs, registers, and DSPs (resource/utilisation report).
- **Max Frequency** — from the timing report (the `area_probe.sdc` constrains a
  tight 250 MHz so the achievable maximum is shown).

Record both for each top and put them side by side: the REIST unit should use a
small fraction of the logic and reach a markedly higher Fmax than the divider IP.
Together with the cycle counts above, that is the complete, watertight picture.

## Pins

Benchmark top: `clk` H11 · `uart_tx` M11 · `led[3:0]` L16/L14/N14/N16. No
external reset pin — internal power-on reset, which also keeps clear of the
dock's dedicated SSPI button pins. The area probes use `clk` H11 and `probe` L16.
