# Yosys fixes

Patches against [YosysHQ/yosys](https://github.com/YosysHQ/yosys) at `YOSYS_REV` in
[build_tools.sh](../build_tools.sh), the commit of the suite's Yosys. `build_tools.sh` applies them
to the files they change and builds those files into a plugin, which `scripts/build_fpga_oss.sh`
loads for synthesis. The patched files are Yosys' own, under its ISC licence.

- `0001`, `0002`: `write_xaiger` and `submod` order their output by keys that tie or by heap
  address, so the netlist differs between macOS and Linux. Meant for Yosys upstream.
- `0003`: lets the plugin replace the built-in passes.
