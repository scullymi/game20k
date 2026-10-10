#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Writes the NOTICE file that accompanies the bitstreams of a release.

Usage: scripts/bitstream_notice.py <output file> <version> <core> [<core> ...]

The synthesis project of each core, fpga/<core>/impl/gwsynthesis/<core>.prj, lists the source
files that went into its bitstream. Every one of them has to belong to a component below, and
each component names the notice it needs. A file that no component claims ends the script with
exit code 1, so new HDL cannot get into a release without its notice. So do a diagnostic build,
a bitstream older than one of its sources or than its synthesis project, a source that reads a
data file, an interface tag that does not come from today's menu sources, and a source with
uncommitted changes or one that git does not track (ALLOW_DIRTY=1 lets those two pass for a
trial run): the NOTICE describes exactly the files it lists.

The bitstreams hold no ROM image, the cores load their ROMs from the SD card at run time. The
one exception is the content of Pac-Man's sound timing PROM 3M, which MikeJ's core holds as a
logic table.
"""

import hashlib
import os
import re
import subprocess
import sys
import textwrap

import make_menu  # the menu generator, the interface tag in the bitstream comes from it

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_URL = "https://github.com/scullymi/game20k"

# Each component: the name in the NOTICE, a short licence label for the contents, where its
# source comes from, a pattern on the repository-relative path, and what the NOTICE shows. The
# list order matters, the first matching component claims a file. The patterns of third-party
# components name every file exactly, our own files are claimed by their SPDX line (own_file),
# so a new file without either stops the release until someone assigns it.
# "show" entries: ("file", path) prints a whole file, ("lines", path, first, last) the lines
# between the first line containing <first> and the next line containing <last>, both included.
# "copyrights": the BSD-style notices ask for "the above copyright notice" of every file, and
# each file names its own holder, so their "Copyright (c)" lines are listed as well.
# "cores": the component claims files only for these cores. fpga/vendor holds one copy of a
# file that several cores use, and each core's component names it with that core's changes.
COMPONENTS = [
    {
        "name": "FPGA-SDcard-Reader by WangXuan95, via Nanomig",
        "short": "GPL-3.0",
        "url": "https://github.com/WangXuan95/FPGA-SDcard-Reader, the files from "
               "https://github.com/MiSTle-Dev/Nanomig at 0f3d2fd, which contains "
               "https://github.com/MiSTle-Dev/NanoMig/pull/168",
        "match": r"^fpga/common/src/misc/(sd_rw|sdcmd_ctrl)\.v$",
        "licence": "GPL-3.0, see the GPL text at the end",
        "note": "Nanomig ships these two files without the licence text. Under GPL-3.0 section 10 "
                "every recipient is licensed by the original licensor. sd_rw.v contains changes "
                "by Manger74 and by game20k, Copyright (C) 2026 scullymi.",
        "show": [],
    },
    {
        "name": "MiSTeryNano and Nanomig files by Till Harbaum",
        "short": "GPL-3.0-or-later",
        "url": "https://github.com/MiSTle-Dev/MiSTeryNano at c8e4601 (src/misc), "
               "https://github.com/MiSTle-Dev/Nanomig at 0f3d2fd (sd_card.v)",
        "match": r"^fpga/common/src/misc/(hid|mcu_spi|osd_u8g2|sd_card|sysctrl)\.v$",
        "licence": "GPL-3.0-or-later, see the GPL text at the end",
        "note": "Upstream these files carry no licence header. game20k's copies carry the SPDX "
                "tag, its changes in them are under the same licence, Copyright (C) 2026 "
                "scullymi. sysctrl.v is reduced to what game20k needs and extended by it. "
                "sd_card.v contains changes by Manger74.",
        "show": [],
    },
    {
        "name": "hdl-util/hdmi by Sameer Puri",
        "short": "MIT",
        "url": "https://github.com/hdl-util/hdmi at 08936f6",
        "match": r"^fpga/common/src/hdmi/(audio_clock_regeneration_packet|audio_info_frame|"
                 r"audio_sample_packet|auxiliary_video_information_info_frame|hdmi|"
                 r"packet_assembler|packet_picker|serializer|source_product_description_info_frame|"
                 r"tmds_channel)\.sv$",
        "licence": "MIT OR Apache-2.0 upstream, used under MIT",
        "note": "hdmi.sv, packet_assembler.sv and tmds_channel.sv carry game20k changes, "
                "serializer.sv is NESTang's version of it.",
        "show": [("file", "fpga/common/src/hdmi/LICENSE")],
    },
    {
        "name": "sdram_fb.v, derived from NESTang's sdram_nes.v by nand2mario",
        "short": "GPL-3.0",
        "url": "https://github.com/nand2mario/nestang",
        "match": r"^fpga/common/src/sdram_fb\.v$",
        "licence": "GPL-3.0, see the GPL text at the end",
        "note": "",
        "show": [],
        "copyrights": True,
    },
    {
        "name": "T80, the Z80 core by Daniel Wallner, in the Galaga core",
        "short": "BSD-like, the notice below",
        "url": "https://github.com/DECAfpga/Arcade_Galaga at e06ba91, folder rtl_T80",
        "match": r"^fpga/galaga_hdmi/src/rtl_T80/(T80|T80_ALU|T80_MCode|T80_Pack|T80_Reg|T80se)\.vhd$",
        "licence": "BSD-like, three conditions, the notice below",
        "note": "",
        "show": [("lines", "fpga/galaga_hdmi/src/rtl_T80/T80.vhd", "Copyright (c)",
                  "SUCH DAMAGE.")],
        "copyrights": True,
    },
    {
        "name": "T80 Ver 300 with T80sed by MikeJ, in the Pac-Man core",
        "short": "BSD-like, the notice below",
        "url": "https://github.com/MiSTer-devel/Arcade-Pacman_MiSTer at 648172d, folder rtl/cpu",
        "match": r"^fpga/pacman_hdmi/src/rtl_T80/(T80|T80_ALU|T80_MCode|T80_Pack|T80_Reg|T80sed)\.vhd$",
        "licence": "BSD-like, three conditions, the notice below",
        "note": "",
        "show": [("lines", "fpga/pacman_hdmi/src/rtl_T80/T80.vhd", "Copyright (c)",
                  "SUCH DAMAGE.")],
        "copyrights": True,
    },
    {
        "name": "T80 Ver 350, the Z80 core by Daniel Wallner, in the 1942, 1943, Ghosts'n Goblins "
                "and Pang cores",
        "short": "BSD-like, the notice below",
        "url": "https://github.com/jotego/jtcores at 548b87b, folder modules/jtframe/hdl/cpu/t80",
        "match": r"^fpga/vendor/jtcores/modules/jtframe/hdl/cpu/t80/(T80|T80_ALU|T80_MCode|T80_Reg|"
                 r"T80s)\.vhd$",
        "licence": "BSD-like, three conditions, the notice below",
        "note": "",
        "show": [("lines", "fpga/vendor/jtcores/modules/jtframe/hdl/cpu/t80/T80.vhd",
                  "Copyright (c)", "SUCH DAMAGE.")],
        "copyrights": True,
    },
    {
        "name": "T80 Ver 350, the Z80 core by Daniel Wallner, in the Time Pilot core",
        "short": "BSD-like, the notice below",
        "url": "https://github.com/MiSTer-devel/Arcade-TimePilot_MiSTer at 5a148e2, folder "
               "rtl/cpu/T80",
        "match": r"^fpga/timepilot_hdmi/src/rtl_timepilot/cpu/T80/(T80|T80_ALU|T80_MCode|T80_Pack|"
                 r"T80_Reg|T80s)\.vhd$",
        "licence": "BSD-like, three conditions, the notice below",
        "note": "game20k writes one bit string literal in T80.vhd with its full width and "
                "instantiates the T80 in T80s.vhd as entity work.T80. Neither change is marked.",
        "show": [("lines", "fpga/timepilot_hdmi/src/rtl_timepilot/cpu/T80/T80.vhd",
                  "Copyright (c)", "SUCH DAMAGE.")],
        "copyrights": True,
    },
    {
        "name": "mc6809i, the 6809 core by Greg Miller, in jotego's copy",
        "short": "BSD-like, the notice below",
        "url": "https://github.com/jotego/jtcores at 548b87b, modules/jtframe/hdl/cpu/mc6809i.v, "
               "jotego's changed copy of mc6809i.v from https://github.com/cavnex/mc6809",
        "match": r"^fpga/vendor/jtcores/modules/jtframe/hdl/cpu/mc6809i\.v$",
        "licence": "the standard BSD licence of the author's LICENSE.md, three clauses, the notice "
                   "below",
        "note": "The file carries only the author's copyright line. His LICENSE.md (cavnex/mc6809 "
                "at 17e94a6, documentation/LICENSE.md, copied beside the file as "
                "mc6809i_LICENSE.md) offers the standard BSD licence or a binary-only variant. "
                "game20k distributes the source and so uses the standard BSD licence. Unchanged "
                "from jotego's copy.",
        "show": [("lines", "fpga/vendor/jtcores/modules/jtframe/hdl/cpu/mc6809i_LICENSE.md",
                  "Copyright (c) 2016, Greg Miller", "SOFTWARE, EVEN IF ADVISED")],
        "copyrights": True,
    },
    {
        "name": "jt1942 and JTFRAME by Jose Tejada Gomez (jotego)",
        "short": "GPL-3.0-or-later",
        "url": "https://github.com/jotego/jtcores at 548b87b, folders cores/1942/hdl, cores/gng/hdl "
               "and modules/jtframe/hdl",
        # every file of these folders except the T80, which the component above claims first
        "match": r"^fpga/vendor/jtcores/(cores/(1942|gng)/hdl/[^/]+|modules/jtframe/hdl/.+)\.(v|vh|inc)$",
        "cores": ("g1942_hdmi",),
        "licence": "GPL-3.0-or-later, see the GPL text at the end",
        "note": "jtframe_dual_ram.v writes in Gowin's normal mode, jt1942_obj.v declares a net "
                "before its first use, jt1942_main.v, jt1942_sound.v and jt1942_game.v bring out "
                "the CPU writes for the RAM mirror, jt1942_colmix.v, jt1942_video.v and "
                "jt1942_game.v bring out the palette index, all marked game20k. The ROMs of 1942, its "
                "PROMs included, come from the SD card at run time. The RAM modules read data "
                "files only in simulation or through a SYN* parameter, which no instance sets.",
        "show": [],
    },
    {
        "name": "jt1943 and JTFRAME by Jose Tejada Gomez (jotego)",
        "short": "GPL-3.0-or-later",
        "url": "https://github.com/jotego/jtcores at 548b87b, folders cores/1943/hdl, cores/gng/hdl "
               "and modules/jtframe/hdl",
        # every file of these folders except the T80, which a component above claims first
        "match": r"^fpga/vendor/jtcores/(cores/(1943|gng)/hdl/[^/]+|modules/jtframe/hdl/.+)\.(v|vh|inc)$",
        "cores": ("g1943_hdmi",),
        "licence": "GPL-3.0-or-later, see the GPL text at the end",
        "note": "jtframe_dual_ram.v writes in Gowin's normal mode, jtgng_sound.v takes its reset on "
                "the rising clock edge, jt1943_main.v and jt1943_game.v bring out the CPU writes "
                "for the RAM mirror, jt1943_colmix.v, jt1943_video.v and jt1943_game.v bring out "
                "the palette index, jt1943_game.v lets the sound CPU wait for its ROM, all marked "
                "game20k. jt1943_security.v answers the protection check from a table, the program "
                "of the protection MCU is not used. The ROMs of 1943, its PROMs included, come from "
                "the SD card at run time. The RAM modules read data files only in simulation or "
                "through a SYN* parameter, which no instance sets.",
        "show": [],
    },
    {
        "name": "jtgng and JTFRAME by Jose Tejada Gomez (jotego)",
        "short": "GPL-3.0-or-later",
        "url": "https://github.com/jotego/jtcores at 548b87b, folders cores/gng/hdl and "
               "modules/jtframe/hdl",
        # every file of these folders except the T80 and mc6809i.v, which components above claim
        "match": r"^fpga/vendor/jtcores/(cores/gng/hdl/[^/]+|modules/jtframe/hdl/.+)\.(v|vh|inc)$",
        "cores": ("gng_hdmi",),
        "licence": "GPL-3.0-or-later, see the GPL text at the end",
        "note": "jtframe_dual_ram.v writes in Gowin's normal mode, jtgng_sound.v takes its reset on "
                "the rising clock edge, jtgng_game.v takes its clock enables from outside, "
                "jtgng_main.v and jtgng_game.v bring out the CPU writes for the RAM mirror, all "
                "marked game20k. The ROMs of Ghosts'n Goblins come from the SD card at run time. "
                "The RAM modules read data files only in simulation or through a SYN* parameter, "
                "which no instance sets.",
        "show": [],
    },
    {
        "name": "jtpang and JTFRAME by Jose Tejada Gomez (jotego)",
        "short": "GPL-3.0-or-later",
        "url": "https://github.com/jotego/jtcores at 548b87b, folders cores/pang/hdl and "
               "modules/jtframe/hdl",
        # every file of these folders except the T80, which a component above claims first
        "match": r"^fpga/vendor/jtcores/(cores/pang/hdl/[^/]+|modules/jtframe/hdl/.+)\.(v|vh|inc)$",
        "cores": ("pang_hdmi",),
        "licence": "GPL-3.0-or-later, see the GPL text at the end",
        "note": "jtpang_main.v takes the program decrypted ahead instead of through jtframe_kabuki, "
                "leaves out a VRAM wait block that never stops the CPU and brings out the work RAM "
                "for the RAM mirror, jtframe_z80wait.v keeps the CPU's clock enables a minimum "
                "number of clocks apart, jtframe_dual_ram.v writes in Gowin's normal mode, all "
                "marked game20k. The ROMs of Pang and Super Pang and the EEPROM content come from "
                "the SD card at run time. The RAM modules read data files only in simulation or "
                "through a SYN* parameter, which no instance sets.",
        "show": [],
    },
    {
        "name": "JT12 by Jose Tejada Gomez (jotego)",
        "short": "GPL-3.0-or-later",
        "url": "https://github.com/jotego/jt12 at d495f64, folder hdl",
        "match": r"^fpga/vendor/jt12/hdl/(adpcm/(jt10_adpcm|jt10_adpcm_acc|jt10_adpcm_cnt|"
                 r"jt10_adpcm_div|jt10_adpcm_drvA|jt10_adpcm_drvB|jt10_adpcm_gain|jt10_adpcma_lut|"
                 r"jt10_adpcmb|jt10_adpcmb_cnt|jt10_adpcmb_gain|jt10_adpcmb_interpol)|jt03|jt03_acc|"
                 r"jt10_acc|jt12_acc|jt12_csr|jt12_div|jt12_dout|jt12_eg|jt12_eg_cnt|jt12_eg_comb|"
                 r"jt12_eg_ctrl|jt12_eg_final|jt12_eg_pure|jt12_eg_step|jt12_exprom|jt12_kon|"
                 r"jt12_lfo|jt12_logsin|jt12_mmr|jt12_mod|jt12_op|jt12_pg|jt12_pg_comb|jt12_pg_dt|"
                 r"jt12_pg_inc|jt12_pg_sum|jt12_pm|jt12_reg|jt12_reg_ch|jt12_rst|jt12_sh|"
                 r"jt12_sh_rst|jt12_single_acc|jt12_sumch|jt12_timers|jt12_top)\.v$",
        "licence": "GPL-3.0-or-later, see the GPL text at the end",
        "note": "jt12_rst.v takes its reset on the rising clock edge, jt12_top.v keeps SSG level "
                "table 1, both marked game20k.",
        "show": [],
    },
    {
        "name": "JT49 by Jose Tejada Gomez (jotego)",
        "short": "GPL-3.0-or-later",
        "url": "https://github.com/jotego/jt49 at 7f6abfd, folder hdl",
        "match": r"^fpga/vendor/jt49/hdl/(jt49|jt49_bus|jt49_cen|jt49_div|jt49_eg|jt49_exp|"
                 r"jt49_noise)\.v$",
        "licence": "GPL-3.0-or-later, see the GPL text at the end",
        "note": "Unchanged.",
        "show": [],
    },
    {
        "name": "JT49 by Jose Tejada Gomez (jotego), in the Time Pilot core",
        "short": "GPL-3.0-or-later",
        "url": "https://github.com/MiSTer-devel/Arcade-TimePilot_MiSTer at 5a148e2, folder "
               "rtl/sound/jt49/hdl, a copy of https://github.com/jotego/jt49",
        "match": r"^fpga/timepilot_hdmi/src/rtl_timepilot/sound/jt49/hdl/(jt49|jt49_bus|jt49_cen|"
                 r"jt49_div|jt49_eg|jt49_exp|jt49_noise|filter/jt49_dcrm2)\.v$",
        "licence": "GPL-3.0-or-later, see the GPL text at the end",
        "note": "Unchanged from the Time Pilot repository. Its README says Ace changed the volume "
                "scale.",
        "show": [],
    },
    {
        "name": "JTOPL by Jose Tejada Gomez (jotego)",
        "short": "GPL-3.0-or-later",
        "url": "https://github.com/jotego/jtopl at 7ac0c81, folder hdl",
        "match": r"^fpga/vendor/jtopl/hdl/(jt2413|jtopl_acc|jtopl_csr|jtopl_div|jtopl_eg|"
                 r"jtopl_eg_cnt|jtopl_eg_comb|jtopl_eg_ctrl|jtopl_eg_final|jtopl_eg_pure|"
                 r"jtopl_eg_step|jtopl_exprom|jtopl_lfo|jtopl_logsin|jtopl_noise|jtopl_op|jtopl_pg|"
                 r"jtopl_pg_comb|jtopl_pg_inc|jtopl_pg_rhy|jtopl_pg_sum|jtopl_pm|jtopl_sh|"
                 r"jtopl_sh_rst|jtopl_single_acc|jtopl_slot_cnt|jtopl_timers|jtopll_mmr|jtopll_reg|"
                 r"jtopll_reg_ch)\.v$",
        "licence": "GPL-3.0-or-later, see the GPL text at the end",
        "note": "Unchanged.",
        "show": [],
    },
    {
        "name": "JT6295 by Jose Tejada Gomez (jotego)",
        "short": "GPL-3.0-or-later",
        "url": "https://github.com/jotego/jt6295 at 7d76b0b, folder hdl",
        "match": r"^fpga/vendor/jt6295/hdl/(jt12_comb|jt12_interpol|jt6295|jt6295_acc|"
                 r"jt6295_adpcm|jt6295_ctrl|jt6295_rom|jt6295_serial|jt6295_sh_rst|"
                 r"jt6295_timing)\.v$",
        "licence": "GPL-3.0-or-later, see the GPL text at the end",
        "note": "Unchanged.",
        "show": [],
    },
    {
        "name": "JTEEPROM by Jose Tejada Gomez (jotego)",
        "short": "GPL-3.0-or-later",
        "url": "https://github.com/jotego/jteeprom at 9c68ce8, folder hdl",
        "match": r"^fpga/vendor/jteeprom/hdl/(jt9346|jt9346_16b8b)\.v$",
        "licence": "GPL-3.0-or-later, see the GPL text at the end",
        "note": "jt9346.v writes its RAM in Gowin's normal mode, marked game20k.",
        "show": [],
    },
    {
        "name": "Dig Dug core by MiSTer-X",
        "short": "GPL-3.0",
        "url": "https://github.com/MiSTer-devel/Arcade-DigDug_MiSTer at 3022bcc, folder rtl",
        "match": r"^fpga/digdug_hdmi/src/rtl_digdug/(FPGA_DIGDUG|DIGDUG_CORES|DIGDUG_IODEV|"
                 r"DIGDUG_SPRITE|DIGDUG_VIDEO|HVGEN|cpucore|dprams|wsg)\.v$",
        "licence": "GPL-3.0 by the repository's LICENSE, see the GPL text at the end",
        "note": "The files carry MiSTer-X's copyright line and no licence text, cpucore.v carries no "
                "header. The repository's LICENSE is GPL-3.0 and names no version choice. game20k "
                "runs the core on one clock with enables, reads the program of the main CPU from "
                "SDRAM, replaces the imitation of the custom I/O chips by the 06XX with the 51XX "
                "and 53XX running their own programs (our namco_io.sv), sets the raster and the "
                "sound divider for its clock and brings out the RAM writes for the RAM mirror, all "
                "marked game20k. The ROMs of Dig Dug, its PROMs and the programs of the 51XX and "
                "53XX included, come from the SD card at run time.",
        "show": [],
    },
    {
        "name": "TV80, the Z80 core by Guy Hutchison, in the Dig Dug core",
        "short": "MIT, the notice below",
        "url": "https://github.com/MiSTer-devel/Arcade-DigDug_MiSTer at 3022bcc, folder rtl/cpu",
        "match": r"^fpga/digdug_hdmi/src/rtl_digdug/cpu/(tv80_alu|tv80_core|tv80_mcode|tv80_reg|"
                 r"tv80s)\.v$",
        "licence": "MIT, the notice below",
        "note": "The headers say the core is based on the VHDL T80 by Daniel Wallner. tv80s.v takes "
                "a clock enable, marked game20k.",
        "show": [("lines", "fpga/digdug_hdmi/src/rtl_digdug/cpu/tv80_core.v",
                  "Copyright (c) 2004 Guy Hutchison", "SOFTWARE OR THE USE OR OTHER DEALINGS")],
        "copyrights": True,
    },
    {
        "name": "Time Pilot core by Ace, with the ROM loader by Kitrinx",
        "short": "MIT, the notice below",
        "url": "https://github.com/MiSTer-devel/Arcade-TimePilot_MiSTer at 5a148e2, folder rtl",
        "match": r"^fpga/timepilot_hdmi/src/rtl_timepilot/(TimePilot|TimePilot_CPU|TimePilot_SND|"
                 r"custom/(k082|k083|k501|k502|k503|k526|k528)|ram_rom/rom_loader)\.sv$",
        "licence": "MIT, the notice below",
        "note": "Each file carries the MIT notice with its own copyright line, listed below. "
                "k526.sv and k528.sv describe the address decoding PLAs of the board (82S153) as "
                "logic, converted from dumps in the PLD Archive. game20k reads the program from "
                "SDRAM, sets the clock dividers for its clock, uses one switchable low-pass filter "
                "per channel (our tp_lpf_sel.sv, with the coefficients of Ace's filters) and "
                "brings out the work RAM writes for the RAM mirror, marked game20k. In "
                "rom_loader.sv game20k swaps the two ports of each RAM, without a mark. The ROMs "
                "of Time Pilot, its PROMs included, come from the SD card at run time.",
        "show": [("lines", "fpga/timepilot_hdmi/src/rtl_timepilot/TimePilot.sv",
                  "Permission is hereby granted", "DEALINGS IN THE SOFTWARE.")],
        "copyrights": True,
    },
    {
        "name": "jtframe_frac_cen.v and spram.vhd from the Time Pilot repository",
        "short": "no licence statement, see the note",
        "url": "https://github.com/MiSTer-devel/Arcade-TimePilot_MiSTer at 5a148e2, "
               "rtl/jtframe_frac_cen.v and rtl/ram_rom/spram.vhd",
        "match": r"^fpga/timepilot_hdmi/src/rtl_timepilot/(jtframe_frac_cen\.v|ram_rom/spram\.vhd)$",
        "licence": "none stated, see the note",
        "note": "Neither file has a header, and the repository has no licence file. "
                "jtframe_frac_cen.v is an earlier version of a module of jotego's JTFRAME, which "
                "jtcores carries as modules/jtframe/hdl/clocking/jtframe_frac_cen.v under "
                "GPL-3.0-or-later. spram.vhd is a generic single-port RAM whose author is not "
                "named. game20k declares its memory as a signal instead of a shared variable, "
                "marked game20k.",
        "show": [],
    },
    {
        "name": "Galaga core by Dar",
        "short": "a condition, no licence",
        "url": "https://github.com/DECAfpga/Arcade_Galaga at e06ba91, folder rtl_dar",
        "match": r"^fpga/galaga_hdmi/src/rtl_dar/(galaga|gen_video|mb88|sound_machine|stars|"
                 r"stars_machine)\.vhd$",
        "licence": "no licence granted, the condition below",
        "note": "MiSTer and MiST publish bitstreams of Dar's cores. game20k reads the condition "
                "the strict way: a bitstream without any ROM image may be passed on, ROMs never, "
                "in any form. This bitstream holds no ROM image, all ROMs of the game, its PROMs "
                "and the programs of the 51XX and 54XX included, come from the SD card at run "
                "time. The star table in stars.vhd comes "
                "from MAME's recording of the 05xx starfield chip (MAME 0.190, "
                "src/mame/video/galaga.cpp, BSD-3-Clause, copyright holder Nicola Salmoria).",
        "show": [("lines", "fpga/galaga_hdmi/src/rtl_dar/galaga.vhd", "Galaga Midway by Dar",
                  "darfpga.blogspot"),
                 ("lines", "fpga/galaga_hdmi/src/rtl_dar/galaga.vhd", "-- Educational use only",
                  "-- Use at your own risk")],
    },
    {
        "name": "Pac-Man core by MikeJ",
        "short": "BSD-like, the notice below",
        "url": "https://github.com/MiSTer-devel/Arcade-Pacman_MiSTer at 6b5ccb0, folder rtl",
        "match": r"^fpga/pacman_hdmi/src/rtl_pacman/(pacman|pacman_video|pacman_audio|"
                 r"pacman_vram_addr|pacman_rom_descrambler)\.vhd$",
        "licence": "BSD-like, three conditions, the notice below",
        "note": "The ROM descrambler is by d18c7db, pacman_vram_addr.vhd by MikeJ and CarlW, later "
                "changes by Alexey Melnikov and Alan Steremberg, the Jr. Pac-Man support in "
                "pacman.vhd, pacman_video.vhd and pacman_audio.vhd by Rodimus Prime (upstream "
                "9bcb0b6, no copyright line of its own). game20k reads Jr. Pac-Man's program, "
                "decrypted ahead, from SDRAM instead of decrypting it into block RAM, marked "
                "game20k. pacman_audio.vhd holds the whole "
                "content of the sound timing PROM 3M (82s126, 256x4, its upper half empty) as a "
                "16-case logic table, inverted, as MiSTer's port does. The other ROMs come from "
                "the SD card at run time.",
        "show": [("lines", "fpga/pacman_hdmi/src/rtl_pacman/pacman.vhd", "Copyright (c)",
                  "SUCH DAMAGE.")],
        "copyrights": True,
    },
    {
        "name": "sector_dpram.v, output of the Gowin IP generator, via MiSTeryNano",
        "short": "generator output under Gowin's header",
        "url": "https://github.com/MiSTle-Dev/MiSTeryNano at c8e4601, "
               "src/tang/nano20k/gowin_dpb/sector_dpram.v",
        "match": r"^fpga/common/src/mcu/sector_dpram\.v$",
        "licence": "no licence text, Gowin's copyright header, see the note",
        "note": "The file instantiates the DPB block RAM primitive as Gowin's IP generator writes "
                "it, and keeps Gowin's header, shown below. Gowin's licence agreement lets the user "
                "keep and use the output data of its tools. game20k added wire in the port "
                "declarations, a default_nettype line and comments.",
        "show": [("lines", "fpga/common/src/mcu/sector_dpram.v", "//Copyright (C)2014-2023 Gowin",
                  "//All rights reserved.")],
    },
    {
        "name": "game20k",
        "short": "GPL-3.0-only",
        "url": REPO_URL,
        # our files: everything else under fpga/ that carries our SPDX line, see own_file()
        "match": r"^fpga/(common|galaga_hdmi|pacman_hdmi|g1942_hdmi|g1943_hdmi|gng_hdmi|digdug_hdmi|"
                 r"pang_hdmi|timepilot_hdmi)/",
        "licence": "GPL-3.0-only, see the GPL text at the end",
        "note": "Copyright (C) 2026 scullymi. The generated files gen/rom_map_pkg.sv and "
                "gen/iface_pkg.sv come from the game's manifest and, by scripts/make_menu.py, "
                "from menu/base.xml and the game's menu_core.xml. "
                "The rPLL instantiation in pll_sdram.v is output of the Gowin IP generator as "
                "NESTang's gowin_pll_nes.v carries it, with our parameters.",
        "show": [],
    },
]
OWN = len(COMPONENTS) - 1
# the normal top level, a diagnostic build replaces it with gen/game20k_top_gen.sv (build.tcl)
TOP = "fpga/common/src/game20k_top.sv"
# the only files of a core's gen/ folder that belong into a release build
GEN_OK = ("gen/rom_map_pkg.sv", "gen/iface_pkg.sv")
# the files of a core that its build writes and no commit holds
BUILT = GEN_OK
# Statements that pull a file into the design at synthesis. None is allowed, so no ROM image
# reaches a bitstream unseen.
FILE_READ = re.compile(r"\$readmem|`include|\$fopen|\$fread|textio|file_open", re.I)
# generated files of ours without an SPDX line, with the line that proves where they come from
GENERATED = {
    r"^fpga/(galaga_hdmi|pacman_hdmi|g1942_hdmi|g1943_hdmi|gng_hdmi|digdug_hdmi|pang_hdmi|"
    r"timepilot_hdmi)/gen/rom_map_pkg\.sv$": "// Generated by scripts/make_rom.py from",
    r"^fpga/(galaga_hdmi|pacman_hdmi|g1942_hdmi|g1943_hdmi|gng_hdmi|digdug_hdmi|pang_hdmi|"
    r"timepilot_hdmi)/gen/iface_pkg\.sv$": "// Generated by scripts/make_menu.py from",
}


def die(msg):
    print("bitstream_notice.py: " + msg, file=sys.stderr)
    sys.exit(1)


def field(label, value):
    """A "Label:  value" line, wrapped at 78 columns with the value column kept."""
    return textwrap.fill(label + value, 78, subsequent_indent=" " * len(label),
                         break_long_words=False, break_on_hyphens=False)


def read(rel):
    path = os.path.join(ROOT, rel)
    if not os.path.isfile(path):
        die("missing: %s" % rel)
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().replace("\r\n", "\n")


def lines_between(rel, first, last):
    """The lines of a file from the first line containing first to the next containing last."""
    lines = read(rel).split("\n")
    for i, l in enumerate(lines):
        if first in l:
            for j in range(i, len(lines)):
                if last in lines[j]:
                    return "\n".join(lines[i:j + 1])
            break
    die("%s: no block from \"%s\" to \"%s\", the notice moved" % (rel, first, last))


def own_file(rel):
    """True for a file of ours: our SPDX line at the top, or a known generated file."""
    head = read(rel).split("\n")[:3]
    if any("SPDX-License-Identifier: GPL-3.0-only" in l for l in head):
        return True
    for pattern, line in GENERATED.items():
        if re.search(pattern, rel) and head and head[0].startswith(line):
            return True
    return False


def inputs(core):
    """The repository-relative source files of a core's last synthesis."""
    prj = os.path.join(ROOT, "fpga", core, "impl", "gwsynthesis", core + ".prj")
    if not os.path.isfile(prj):
        die("%s missing, build %s first" % (os.path.relpath(prj, ROOT), core))
    with open(prj, encoding="utf-8") as f:
        paths = re.findall(r'<File path="([^"]+)"', f.read())
    if not paths:
        die("%s lists no files" % os.path.relpath(prj, ROOT))
    rel = []
    for p in paths:
        r = os.path.relpath(os.path.realpath(p), ROOT)
        if r.startswith(".."):
            die("%s: %s lies outside the repository" % (core, p))
        rel.append(r)
    # a diagnostic build replaces the top level with a generated one, a release is the normal one
    gen_ok = ["fpga/%s/%s" % (core, g) for g in GEN_OK]
    odd = [r for r in rel if "/gen/" in r and r not in gen_ok]
    if odd or TOP not in rel:
        die("%s is not the normal build (%s), build it again without diagnostic variables"
            % (core, ", ".join(odd) or TOP + " missing"))
    # the interface tag comes from the menu sources, they are sources of the bitstream too
    check_iface(core)
    rel += [make_menu.BASE, "fpga/%s/menu_core.xml" % core]
    return rel


def check_iface(core):
    """Stops unless gen/iface_pkg.sv holds the tag make_menu.py derives from today's sources.
    The firmware of the release takes its menus from them, a core with an older tag would get
    the basic menu."""
    pkg = "fpga/%s/gen/iface_pkg.sv" % core
    if read(pkg) != make_menu.iface_pkg(core, make_menu.iface_tag(core)):
        die("%s does not hold the tag of %s and fpga/%s/menu_core.xml, build %s again"
            % (pkg, make_menu.BASE, core, core))


# jtframe's RAM and PROM modules: a data file read here is allowed when it hangs on one of these
# parameters and the synthesis log shows no instance that sets one (see syn_params_set)
SYN_PARAM = re.compile(r"\bSYN(HEX|FILE|BINFILE)\b")
SYN_FILES = re.compile(r"^fpga/vendor/jtcores/modules/jtframe/hdl/ram/(jtframe_ram|jtframe_dual_ram|"
                       r"jtframe_prom)\.v$")
INCLUDE = re.compile(r'^\s*`include\s+"([^"]+)"')
DIRECTIVE = re.compile(r"^\s*`(ifdef|ifndef|elsif|else|endif|define|undef)\b\s*(\w*)")


def active_lines(text, defined):
    """The line numbers of a Verilog text that synthesis sees, following `ifdef, `ifndef, `elsif,
    `else and `endif with the macros defined so far, and the `define and `undef lines in active
    code, which change the set in place (Gowin compiles all files as one unit)."""
    stack = []          # per level: (this branch active, some branch taken, parent active)
    active = set()
    for n, l in enumerate(text.split("\n"), 1):
        on = all(s[0] for s in stack)
        m = DIRECTIVE.match(l.split("//", 1)[0])
        if m:
            kind, name = m.group(1), m.group(2)
            if kind in ("ifdef", "ifndef"):
                cond = (name in defined) == (kind == "ifdef")
                stack.append([on and cond, cond, on])
            elif kind == "elsif" and stack:
                top = stack[-1]
                cond = name in defined and not top[1]
                top[0] = top[2] and cond
                top[1] = top[1] or cond
            elif kind == "else" and stack:
                top = stack[-1]
                top[0] = top[2] and not top[1]
                top[1] = True
            elif kind == "endif" and stack:
                stack.pop()
            elif kind == "define" and on:
                defined.add(name)
            elif kind == "undef" and on:
                defined.discard(name)
            continue
        if on:
            active.add(n)
    return active


def syn_params_set(core):
    """The compiled module lines of the synthesis log that set a SYN* parameter."""
    log = os.path.join(ROOT, "fpga", core, "impl", "gwsynthesis", core + ".log")
    if not os.path.isfile(log):
        die("%s missing, build %s first" % (os.path.relpath(log, ROOT), core))
    with open(log, encoding="utf-8", errors="replace") as f:
        return [l.strip() for l in f if "Compiling module" in l and SYN_PARAM.search(l)]


def include_target(core, rel, name):
    """The repository-relative file an `include in rel names: beside rel, else exactly one file
    of that name in the core's src/ and fpga/vendor (build.tcl puts folders of both on the
    include path)."""
    beside = os.path.join(os.path.dirname(rel), name)
    if os.path.isfile(os.path.join(ROOT, beside)):
        return beside
    hits = [os.path.relpath(os.path.join(d, name), ROOT)
            for top in (os.path.join(ROOT, "fpga", core, "src"), os.path.join(ROOT, "fpga", "vendor"))
            for d, _, fs in os.walk(top) if name in fs]
    if len(hits) != 1:
        die("%s includes %s, found %d files of that name under fpga/%s/src and fpga/vendor"
            % (rel, name, len(hits), core))
    return hits[0]


def file_reads(core, files):
    """The source lines that read a data file at synthesis, and the files they include. Only
    lines synthesis sees count (active_lines). An `include of a source file is no data: the
    included file joins the list, so a component has to claim it.
    In jtframe's RAM and PROM modules a read through a SYN* parameter passes when no instance
    sets one."""
    syn_set = syn_params_set(core)
    defined = set()
    hits, included = [], []
    todo = [f for f in files if re.search(r"\.(s?vh?)$", f)]
    vhdl = [f for f in files if re.search(r"\.vhdl?$", f)]
    def scan(rel):
        text = read(rel)
        lines = text.split("\n")
        for n in sorted(active_lines(text, defined)):
            l = lines[n - 1]
            m = INCLUDE.match(l)
            if m:
                inc = include_target(core, rel, m.group(1))
                if inc not in included:
                    included.append(inc)
                    scan(inc)          # its directives act at the point of the include
                continue
            if not FILE_READ.search(l):
                continue
            if SYN_FILES.search(rel) and SYN_PARAM.search(l) and not syn_set:
                continue
            hits.append("%s:%d: %s" % (rel, n, l.strip()))
    for rel in todo:
        scan(rel)
    for rel in vhdl:
        for n, l in enumerate(read(rel).split("\n"), 1):
            if FILE_READ.search(l):
                hits.append("%s:%d: %s" % (rel, n, l.strip()))
    if syn_set:
        hits += ["%s synthesis log: %s" % (core, s) for s in syn_set]
    return hits, included


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git(*args):
    return subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True,
                          text=True).stdout.strip()


def slot_of(core):
    for line in read("fpga/common/slots.txt").split("\n"):
        parts = line.split()
        if len(parts) == 2 and not line.startswith("#") and parts[0] == core:
            return parts[1]
    die("fpga/common/slots.txt has no address for %s" % core)


def gowin_version(core):
    """The tool version in the header of the core's .fs, e.g. "V1.9.11.03 Education (81398)"."""
    fs = os.path.join(ROOT, "fpga", core, "impl", "pnr", core + ".fs")
    with open(fs, encoding="utf-8", errors="replace") as f:
        head = f.read(2000)
    m = re.search(r"^//Tool Version: (.+)$", head, re.M)
    if not m:
        die("%s has no tool version in its header" % os.path.relpath(fs, ROOT))
    return m.group(1).strip()


def copyright_lines(files):
    """The "Copyright (c)" lines in the headers of these files, each once, in file order."""
    seen = []
    for rel in files:
        for l in read(rel).split("\n")[:80]:
            m = re.match(r"^\s*(?:--|//)\s*(Copyright \([cC]\).*?)\s*$", l)
            if m and m.group(1) not in seen:
                seen.append(m.group(1))
    return seen


def main():
    if len(sys.argv) < 4:
        die("usage: bitstream_notice.py <output file> <version> <core> [<core> ...]")
    out_path, version, cores = sys.argv[1], sys.argv[2], sys.argv[3:]
    allow_dirty = os.environ.get("ALLOW_DIRTY") == "1"

    claimed = {i: set() for i in range(len(COMPONENTS))}
    per_core = {}
    unclaimed = []
    reads = []
    for core in cores:
        files = inputs(core)
        per_core[core] = files
        # The bitstream must be newer than its synthesis project and every source in it. A
        # build that stopped halfway leaves the old .fs behind a new .prj.
        base = os.path.join(ROOT, "fpga", core, "impl", "pnr", core)
        for out in (base + ".fs", base + ".bin"):
            if not os.path.isfile(out):
                die("%s missing, build %s first" % (os.path.relpath(out, ROOT), core))
        built = min(os.path.getmtime(base + ".fs"), os.path.getmtime(base + ".bin"))
        prj = "fpga/%s/impl/gwsynthesis/%s.prj" % (core, core)
        newer = [f for f in [prj] + files if os.path.getmtime(os.path.join(ROOT, f)) > built]
        if newer:
            die("%s is older than %s, build it again" % (core, ", ".join(newer)))
        found, included = file_reads(core, files)
        reads += found
        files += [f for f in included if f not in files]
        # the included headers are sources of this bitstream as well
        newer = [f for f in included if os.path.getmtime(os.path.join(ROOT, f)) > built]
        if newer:
            die("%s is older than %s, build it again" % (core, ", ".join(newer)))
        # first matching component claims the file, ours only with our SPDX line
        for f in files:
            for i, comp in enumerate(COMPONENTS):
                if core not in comp.get("cores", (core,)):
                    continue
                if re.search(comp["match"], f) and (i != OWN or own_file(f)):
                    claimed[i].add(f)
                    break
            else:
                unclaimed.append("%s (%s)" % (f, core))
    if reads:
        die("sources read data files at synthesis, a ROM image could reach "
            "the bitstream that way:\n  " + "\n  ".join(reads))
    if unclaimed:
        die("no component claims these files, add them to COMPONENTS or give them our SPDX line:\n  "
            + "\n  ".join(sorted(set(unclaimed))))
    # A source git does not know is as uncommitted as a changed one, the files the build
    # writes aside, which no commit holds.
    every = sorted({f for fs in per_core.values() for f in fs})
    tracked = set(git("ls-files", "--", *every).split("\n")) - {""}
    untracked = ["?? " + f for f in every
                 if f not in tracked and not any(f.endswith("/" + g) for g in BUILT)]
    dirty = "\n".join([git("status", "--porcelain", "--", *sorted(tracked))] + untracked).strip()
    if dirty and not allow_dirty:
        die("sources with uncommitted changes or unknown to git, a NOTICE names committed files "
            "only:\n" + dirty)

    present = [i for i in range(len(COMPONENTS)) if claimed[i]]
    rule = "=" * 78
    commit = git("rev-parse", "HEAD") + (" (with uncommitted changes)" if dirty else "")
    title = "game20k %s bitstreams for the Tang Nano 20K" % version
    out = [title, "=" * len(title), ""]
    out += textwrap.wrap(
        "This file accompanies the bitstreams of game20k %s. They were built by %s at commit %s "
        "with Gowin EDA %s. Gowin provides its Education edition for education, research and "
        "other non-commercial purposes. These files were built for a non-commercial open "
        "source project and are published free of charge. This describes how they were made "
        "and adds no condition to the licences below. The flash image holds each core's "
        "bitstream at its flash address as the tool writes it to the .bin file, 0xFF in "
        "between. Each bitstream contains the hardware descriptions listed "
        "below, each part under its own terms. The source of every part is in the repository "
        "at that commit."
        % (version, REPO_URL, commit, gowin_version(cores[0])), 78, break_long_words=False,
        break_on_hyphens=False)
    out += [""]
    out += textwrap.wrap(
        "THE BITSTREAMS HOLD NO ROM IMAGE, WITH ONE EXCEPTION. The cores load the ROMs of their "
        "game from the SD card at run time, from files each user makes from their own ROM sets, "
        "PROMs and the programs of the Namco MCUs included. The exception is in third-party code: MikeJ's "
        "Pac-Man core reproduces the sound timing PROM 3M (82s126, 256x4, its upper half empty) "
        "in pacman_audio.vhd as a 16-case logic table, inverted, as MiSTer's port does. The "
        "star table of Dar's Galaga core in stars.vhd comes from MAME's recording of the "
        "starfield chip, not from a ROM.", 78)
    out += ["", "Bitstreams", ""]
    for core in cores:
        base = os.path.join(ROOT, "fpga", core, "impl", "pnr", core)
        out.append(field("%s  " % core, "flash address %s, %d source files"
                         % (slot_of(core), len(per_core[core]))))
        out.append(field(" " * (len(core) + 2), "SHA-256 of %s.bin: %s" % (core, sha256(base + ".bin"))))
    out += ["", "Contents", ""]
    for n, i in enumerate(present, 1):
        out.append("%3d. %s" % (n, COMPONENTS[i]["name"]))
        out.append("     " + COMPONENTS[i]["short"])
    out.append("")

    for n, i in enumerate(present, 1):
        comp = COMPONENTS[i]
        out += [rule, "%d. %s" % (n, comp["name"]), rule, ""]
        out.append(field("Source:  ", comp["url"]))
        out.append(field("Licence: ", comp["licence"]))
        files = sorted(claimed[i])
        # paths below fpga/, both cores have files of the same name
        out.append(field("Files:   ", ", ".join(f[len("fpga/"):] if f.startswith("fpga/") else f
                                                for f in files)))
        if comp["note"]:
            out += [""] + textwrap.wrap(comp["note"], 78, break_long_words=False, break_on_hyphens=False)
        if comp.get("copyrights"):
            out += ["", "Copyright lines in these files:"] + ["  " + l for l in copyright_lines(files)]
        for s in comp["show"]:
            if s[0] == "file":
                out += ["", "Text of %s:" % s[1], "", read(s[1]).rstrip("\n")]
            else:
                out += ["", "From %s:" % s[1], "", lines_between(s[1], s[2], s[3])]
        out.append("")

    out += [rule, "GNU General Public License, version 3", rule, "", read("LICENSE").rstrip("\n")]
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(out).rstrip("\n") + "\n")
    print("%s: %d components, %d source files in %d bitstreams, all claimed"
          % (out_path, len(present), len({f for fs in per_core.values() for f in fs}), len(cores)))


if __name__ == "__main__":
    main()
