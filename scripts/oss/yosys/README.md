# Yosys fixes

Patches against Yosys at `YOSYS_REV` in [build_tools.sh](../build_tools.sh), the commit of the
suite's Yosys. `build_tools.sh` applies them to the two files they change and builds those into
a plugin, which `scripts/build_fpga_oss.sh` loads for synthesis.

- `0001`, `0002`: `write_xaiger` and `submod` ordered their output by keys that tie or by heap
  address, so the netlist differed between macOS and Linux. Meant for Yosys upstream, under
  Yosys' ISC licence.
- `0003`: lets the plugin replace the built-in passes.
