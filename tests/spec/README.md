# SPEC Benchmark Harness

SPEC CPU sources and reference inputs are licensed material, so this repository
does not include them. The supported flow is:

1. Build or obtain a bare-metal RISC-V hex image from your licensed SPEC tree.
2. Keep that image outside the repository, or under an ignored local work area.
3. Add a local manifest using `spec_manifest.example.json` as the template.
4. Run it with `tools/run_benchmarks.py --manifest <your-manifest>.json`.

The runner can report:

- `ipc`: retired instructions divided by cycles from the simulation testbench.
- `spec_ratio_per_mhz`: `spec_ref_seconds * 1_000_000 / timed_cycles`.

The second metric is intentionally named ratio-per-MHz. It is useful for
microarchitecture tracking, but it is not an official SPEC score unless the
full SPEC run rules, inputs, validation, compiler settings, and disclosure
requirements are satisfied.

For better measurements, have the benchmark write the result block defined in
`tests/benchmarks/bench_mmio.h` before writing `tohost`. Without that block,
the runner falls back to the total `mcycle` value printed at PASS or TIMEOUT.
