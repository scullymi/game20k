# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# 1943 with HDMI. Invocation: scripts/build_fpga.sh g1943_hdmi
#
# The platform comes from ../common, see ../common/files.tcl. This folder holds the game:
# jotego's core in ../vendor/jtcores (jtcores 548b87b), jt12 (YM2203 as jt03) in ../vendor/jt12
# and jt49 in ../vendor/jt49, all GPL-3.0-or-later, the T80 BSD-style, each folder with a
# README.md. Changed files carry "game20k" in the text:
# jtframe_dual_ram (Gowin write mode, as for 1942), jt12_rst and jtgng_sound (reset on the
# rising edge), jt1943_main, _game, _video, _colmix (mirror taps, palette
# index, sound ROM from SDRAM). The RAM mirror g1943_mirror.sv is 1942's with a 1943 layout.
set_device GW2AR-LV18QN88C8/I7 -name GW2AR-18C

# jotego's global macros first: Gowin compiles all files as one unit
add_file src/jt1943_defs.v

# jotego's sources in dependency order
add_file ../vendor/jt12/hdl/jt12_rst.v
add_file ../vendor/jtcores/modules/jtframe/hdl/ram/jtframe_ram.v
add_file ../vendor/jtcores/modules/jtframe/hdl/cpu/t80/T80_ALU.vhd
add_file ../vendor/jtcores/modules/jtframe/hdl/cpu/t80/T80_MCode.vhd
add_file ../vendor/jtcores/modules/jtframe/hdl/cpu/t80/T80_Reg.vhd
add_file ../vendor/jtcores/modules/jtframe/hdl/cpu/t80/T80.vhd
add_file ../vendor/jtcores/modules/jtframe/hdl/cpu/t80/T80s.vhd
add_file ../vendor/jtcores/modules/jtframe/hdl/ram/jtframe_dual_ram.v
add_file ../vendor/jtcores/modules/jtframe/hdl/ram/jtframe_dual_nvram.v
add_file ../vendor/jtcores/modules/jtframe/hdl/cpu/jtframe_z80wait.v
add_file ../vendor/jtcores/modules/jtframe/hdl/cpu/jtframe_z80.v
add_file ../vendor/jtcores/cores/1943/hdl/jt1943_main.v
add_file ../vendor/jtcores/cores/1943/hdl/jt1943_security.v
add_file ../vendor/jtcores/modules/jtframe/hdl/ram/jtframe_prom.v
add_file ../vendor/jtcores/modules/jtframe/hdl/jtframe_sh.v
add_file ../vendor/jtcores/cores/1943/hdl/jt1943_colmix.v
add_file ../vendor/jtcores/cores/1943/hdl/jt1943_map.v
add_file ../vendor/jtcores/cores/1943/hdl/jt1943_map_cache.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_tile4.v
add_file ../vendor/jtcores/cores/1943/hdl/jt1943_scroll.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_tilemap.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_char.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_objbuf.v
add_file ../vendor/jtcores/modules/jtframe/hdl/clocking/jtframe_cencross_strobe.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_objcnt.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_dual_ram.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_objdma.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_objdraw.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_objpxl.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_obj.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_timer.v
add_file ../vendor/jtcores/cores/1943/hdl/jt1943_video.v
add_file ../vendor/jtcores/modules/jtframe/hdl/clocking/jtframe_crossclk_cen.v
add_file ../vendor/jt12/hdl/jt12_single_acc.v
add_file ../vendor/jt12/hdl/jt03_acc.v
add_file ../vendor/jt12/hdl/jt10_acc.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcma_lut.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcm.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcm_acc.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcm_cnt.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcm_gain.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcm_drvA.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcmb.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcmb_cnt.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcmb_gain.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcm_div.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcmb_interpol.v
add_file ../vendor/jt12/hdl/adpcm/jt10_adpcm_drvB.v
add_file ../vendor/jt12/hdl/jt12_acc.v
add_file ../vendor/jt12/hdl/jt12_dout.v
add_file ../vendor/jt12/hdl/jt12_eg_cnt.v
add_file ../vendor/jt12/hdl/jt12_eg_ctrl.v
add_file ../vendor/jt12/hdl/jt12_eg_final.v
add_file ../vendor/jt12/hdl/jt12_eg_pure.v
add_file ../vendor/jt12/hdl/jt12_eg_step.v
add_file ../vendor/jt12/hdl/jt12_eg_comb.v
add_file ../vendor/jt12/hdl/jt12_sh.v
add_file ../vendor/jt12/hdl/jt12_sh_rst.v
add_file ../vendor/jt12/hdl/jt12_eg.v
add_file ../vendor/jt12/hdl/jt12_lfo.v
add_file ../vendor/jt12/hdl/jt12_div.v
add_file ../vendor/jt12/hdl/jt12_csr.v
add_file ../vendor/jt12/hdl/jt12_kon.v
add_file ../vendor/jt12/hdl/jt12_mod.v
add_file ../vendor/jt12/hdl/jt12_reg_ch.v
add_file ../vendor/jt12/hdl/jt12_sumch.v
add_file ../vendor/jt12/hdl/jt12_reg.v
add_file ../vendor/jt12/hdl/jt12_mmr.v
add_file ../vendor/jt12/hdl/jt12_exprom.v
add_file ../vendor/jt12/hdl/jt12_logsin.v
add_file ../vendor/jt12/hdl/jt12_op.v
add_file ../vendor/jt12/hdl/jt12_pg_dt.v
add_file ../vendor/jt12/hdl/jt12_pg_inc.v
add_file ../vendor/jt12/hdl/jt12_pg_sum.v
add_file ../vendor/jt12/hdl/jt12_pm.v
add_file ../vendor/jt12/hdl/jt12_pg_comb.v
add_file ../vendor/jt12/hdl/jt12_pg.v
add_file ../vendor/jt12/hdl/jt12_timers.v
add_file ../vendor/jt49/hdl/jt49_cen.v
add_file ../vendor/jt49/hdl/jt49_div.v
add_file ../vendor/jt49/hdl/jt49_eg.v
add_file ../vendor/jt49/hdl/jt49_exp.v
add_file ../vendor/jt49/hdl/jt49_noise.v
add_file ../vendor/jt49/hdl/jt49.v
add_file ../vendor/jt12/hdl/jt12_top.v
add_file ../vendor/jt12/hdl/jt03.v
add_file ../vendor/jtcores/cores/gng/hdl/jtgng_sound.v
add_file ../vendor/jtcores/modules/jtframe/hdl/ram/jtframe_ram_rst.v
add_file ../vendor/jtcores/modules/jtframe/hdl/clocking/jtframe_sync.v
add_file ../vendor/jtcores/cores/1943/hdl/jt1943_game.v
add_file ../vendor/jtcores/modules/jtframe/hdl/jtframe_bcd_cnt.v
add_file ../vendor/jtcores/modules/jtframe/hdl/clocking/jtframe_freqinfo.v
add_file ../vendor/jtcores/modules/jtframe/hdl/clocking/jtframe_gated_cen.v

add_file src/g1943_mirror.sv
add_file src/tile_prefetch.sv
add_file src/map_prefetch.sv
add_file src/game_pkg.sv
add_file src/game_core.sv

file mkdir gen
if {[catch {exec python3 ../../scripts/make_rom.py --package 1943.manifest gen/rom_map_pkg.sv} msg]} {
    error "rom_map_pkg.sv: $msg"
}
add_file gen/rom_map_pkg.sv

source ../common/files.tcl
# RAMDIAG=1: late map words and scroll samples on the LEDs (end of src/game_core.sv). The
# top's parameter line is rewritten into a copy, as in ../galaga_hdmi/build.tcl.
if {[info exists ::env(RAMDIAG)]} {
    set fin [open $top_src r]; set src [read $fin]; close $fin
    set from "parameter bit RAMDIAG   = 0"
    set i [string first $from $src]
    if {$i < 0 || [string first $from $src [expr {$i + 1}]] >= 0} {
        error "$top_src: \"$from\" must occur exactly once"
    }
    set fout [open gen/game20k_top_gen.sv w]
    puts $fout [string map [list $from "parameter bit RAMDIAG   = 1"] $src]; close $fout
    add_file gen/game20k_top_gen.sv
} else {
    add_file $top_src
}

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name g1943_hdmi
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -top_module game20k_top
set_option -include_path "src/inc;../vendor/jtcores/modules/jtframe/hdl/inc;../vendor/jtcores/cores/1943/hdl;../vendor/jt12/hdl"
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -bit_compress 1
set_option -place_option 1

run all
