// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// game20k, Dig Dug: clock driver for tb_digdug. 46.40625 MHz core clock and, with ROM_PATH,
// the 64.8 MHz SDRAM clock, both as edges on a picosecond time line.
#include "Vtb_digdug.h"
#include "verilated.h"
#include <cstdint>

int main(int argc, char **argv) {
    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vtb_digdug *tb = new Vtb_digdug{ctx};
    const uint64_t half_core = 10774;    // ps, 46.40625 MHz
#ifdef ROM_PATH
    const uint64_t half_sd = 7716;       // ps, 64.8 MHz
    uint64_t t_sd = 3000;
    tb->clk_sdram = 0;
#endif
    uint64_t t_core = half_core;
    tb->clk = 0;
    tb->eval();
    while (!ctx->gotFinish()) {
#ifdef ROM_PATH
        if (t_sd < t_core) {
            ctx->time(t_sd);
            tb->clk_sdram = !tb->clk_sdram;
            t_sd += half_sd;
        } else
#endif
        {
            ctx->time(t_core);
            tb->clk = !tb->clk;
            t_core += half_core;
        }
        tb->eval();
    }
    tb->final();
    delete tb;
    delete ctx;
    return 0;
}
