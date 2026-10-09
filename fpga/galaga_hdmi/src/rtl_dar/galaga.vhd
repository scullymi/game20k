---------------------------------------------------------------------------------
-- Galaga Midway by Dar (darfpga@aol.fr)
-- http://darfpga.blogspot.fr
---------------------------------------------------------------------------------
---------------------------------------------------------------------------------
-- MODIFIED VERSION, not Dar's original.
-- game20k changes this file: DIP switches as ports, one clock of delay in the tile
-- path (Gowin specific!), all PROMs loadable at run time instead of fixed in the
-- bitstream, a defined slot phase after reset, the Namco 51XX running its own program
-- (51xx.bin) behind a 06XX after MAME's namco06.cpp, and the RAM mirror for
-- RetroAchievements.
-- The README in this folder gives the reason for each change and names the upstream
-- commit to diff against. THIRD-PARTY.md covers licensing.
-- Some places are marked "game20k" in the text, not all: the diff is the complete list.
--
-- Dar's original condition applies unchanged: educational use only, no redistribution
-- of synthesized files with ROMs, no redistribution of ROMs.
---------------------------------------------------------------------------------
-- gen_ram.vhd & io_ps2_keyboard
-------------------------------- 
-- Copyright 2005-2008 by Peter Wendrich (pwsoft@syntiac.com)
-- http://www.syntiac.com/fpga64.html
---------------------------------------------------------------------------------
-- T80/T80se - Version : 0247
-----------------------------
-- Z80 compatible microprocessor core
-- Copyright (c) 2001-2002 Daniel Wallner (jesus@opencores.org)
---------------------------------------------------------------------------------
-- Educational use only
-- Do not redistribute synthetized file with roms
-- Do not redistribute roms whatever the form
-- Use at your own risk
---------------------------------------------------------------------------------
-- Galaga releases
--
-- Release 0.3 - 06/05/2018 - Dar
--    add mb88 explosion sound ship 
--
-- Release 0.2 - 06/11/2017 - Dar
--    fixes twice bullets on single shot => add edge detection en fire
--
-- Release 0.1 - 04/11/2017 - Dar
--		fixes 2 ships bullet bug (swap 2xH/2xV command bits)
--
-- Release 0.0 - December 2016 - Dar
--		initial release
---------------------------------------------------------------------------------
--  Features :
--   TV 15KHz mode only (atm)
--   Coctail mode ok
--   Sound ok
--   Starfield from MAME information  

--  Use with MAME roms from galagamw.zip
--
--  Use make_galaga_proms.bat to build vhd file from binaries

--   galaga_cpu1.vhd   : 3200a.bin, 3300b.bin, 3400c.bin,3500d.bin, 
--   galaga_cpu2.vhd   : 3600e.bin
--   galaga_cpu3.vhd   : 3700g.bin
--   bg_graphx.vhd     : 2600j.bin
--   sp_graphx.vhd     : 2800l.bin, 2700k.bin
--   rgb.vhd           : prom-5.5n
--   bg_palette.vhd    : prom-4.2n
--   sp_palette.vhd    : prom-3.1c
--   sound_seq.vhd     : prom-2.5c
--   sound_samples.vhd : prom-1.1d

--  Galaga Hardware caracteristics :
--
--    3xZ80 CPU accessing each own program rom and shared ram/devices
--
--    One char tile map 32x28 (called background/bg although being front of other layers) 
--      3 colors/64sets among 16 colors
--      1Ko ram, 4Ko rom graphics, 4pixels of 2bits/byte 
--      full emulation in vhdl
--
--    64 sprites with priorities, flip H/V, 2x size H/V, 
--      3 colors/64sets among 16 colors (different of char colors).
--      8Ko rom graphics, 4pixels of 2bits/byte
--      full emulation in vhdl (improved capabilities : more sprites/scanline)
--
--    Namco 05XX Starfield 
--      4 sets, 63 stars/set, 2 set displayed at one time for blinking   
--      6bits colors: 2red/2green/2blue
--      full emulation in vhdl (from MAME information)
--
--    Char/sprites color palette 2x16 colors among 256 colors
--      8bits 3red/3green/2blue
--      full emulation in vhdl
--
--    Namco 06XX for 51/54XX control 
--      game20k: clock, NMI and chip selects after MAME's namco06.cpp
--
--    Namco 51XX for coin/credit management 
--      game20k: mb88 running the original program 51xx.bin
--
--    Namco 54XX for sound effects 
--      m88 ok
--
--    Namco sound waveform and frequency synthetizer
--      full original emulation in vhdl
--
--    Namco 00XX,04XX,02XX,07XX,08XX address generator, H/V counters and shift registers
--      full emulation in vhdl from what I think they should do.
--
--    Working ram : 3x1Kx8bits shared
--    Sprites ram : 1 scan line delay flip/flop 512x4bits  
--    Sound registers ram : 2x16x4bits
--    Sound sequencer rom : 256x4bits (3 sequential 4 bits adders)
--    Sound wavetable rom : 256x4bits 8 waveform of 32 samples of 4bits/level  
---------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity galaga is
port(
 clock_18     : in std_logic;
 reset        : in std_logic;
 video_reset  : in std_logic;  -- game20k: resets the pixel counters, sets their phase to slot
 dip_a        : in std_logic_vector(7 downto 0);  -- game20k: DSW A, bit map at dip_switch_a
 dip_b        : in std_logic_vector(7 downto 0);  -- game20k: DSW B, bit map at dip_switch_b
 -- game20k: write side of the ROMs, fed by the rom_loader (all PROMs load at run time)
 rom_wr_clk   : in std_logic;
 rom_wr_addr  : in std_logic_vector(13 downto 0);
 rom_wr_data  : in std_logic_vector(7 downto 0);
 rom_wr_en    : in std_logic_vector(10 downto 0);
 -- game20k diagnostics: internal signals of the background tile path
 dbg_tile_num   : out std_logic_vector(7 downto 0);
 dbg_tile_color : out std_logic_vector(7 downto 0);
 dbg_hcnt       : out std_logic_vector(8 downto 0);
 dbg_vcnt       : out std_logic_vector(8 downto 0);
 dbg_bgaddr     : out std_logic_vector(11 downto 0);
 dbg_bgdata     : out std_logic_vector(7 downto 0);
 dbg_bgbits     : out std_logic_vector(3 downto 0);
 -- game20k diagnostics: the writes to the four work RAMs, as the game issues them.
 -- Outputs only, no effect on the core: the same signals drive the memories.
 dbg_ram_we     : out std_logic_vector(3 downto 0);   -- bgram, wram1, wram2, wram3
 dbg_ram_addr   : out std_logic_vector(10 downto 0);  -- mux_addr(10 downto 0)
 dbg_ram_data   : out std_logic_vector(7 downto 0);   -- mux_cpu_do, the written byte
 dbg_score      : out std_logic_vector(47 downto 0);  -- score digits as the harvest reads them
 dbg_shadow     : out std_logic_vector(7 downto 0);   -- byte read back from the bgram shadow
 -- game20k: snapshot delivery to the Pico. One byte per round in slot 5, as long as a
 -- transfer runs and no harvest is running.
 snap_run       : in  std_logic;                      -- an SPI transfer is running
 snap_full      : in  std_logic;                      -- the receiving FIFO is full, pause
 snap_byte      : out std_logic_vector(7 downto 0);
 snap_push      : out std_logic;
 snap_frame     : out std_logic_vector(15 downto 0);  -- number of the harvested frame
 dbg_skip       : out std_logic_vector(15 downto 0);  -- harvests skipped while a transfer runs
 dbg_nzmax      : out std_logic_vector(15 downto 0);  -- peak fill of the catch-up queue, sticky
 dbg_harv       : out std_logic;                      -- a harvest is running
-- tv15Khz_mode : in std_logic;
 video_r        : out std_logic_vector(2 downto 0);
 video_g        : out std_logic_vector(2 downto 0);
 video_b        : out std_logic_vector(1 downto 0);
 video_clk      : out std_logic;
 video_csync    : out std_logic;
 video_blankn   : out std_logic;
 video_hs     : out std_logic;
 video_vs     : out std_logic;
 audio          : out std_logic_vector(9 downto 0);

 b_test         : in std_logic;
 b_svce         : in std_logic;
 coin           : in std_logic;
 start1         : in std_logic;
 left1          : in std_logic;
 right1         : in std_logic;
 fire1          : in std_logic;
 start2         : in std_logic;
 left2          : in std_logic;
 right2         : in std_logic;
 fire2          : in std_logic
 );
end galaga;

architecture struct of galaga is
-- game20k: the wram inputs as signals, GHDL takes no conditional expression in a port map
signal wram1_d, wram2_d, wram3_d : std_logic_vector(7 downto 0);

 signal reset_n: std_logic;
 signal clock_18n : std_logic;

 signal hcnt : std_logic_vector(8 downto 0);
 signal vcnt : std_logic_vector(8 downto 0);
 signal ena_vidgen      : std_logic;
 signal ena_snd_machine : std_logic;
 signal cpu1_ena        : std_logic;
 signal cpu2_ena        : std_logic;
 signal cpu3_ena        : std_logic;

 signal cpu1_addr   : std_logic_vector(15 downto 0);
 signal cpu1_di     : std_logic_vector( 7 downto 0);
 signal cpu1_do     : std_logic_vector( 7 downto 0);
 signal cpu1_wr_n   : std_logic;
 signal cpu1_mreq_n : std_logic;
 signal cpu1_irq_n  : std_logic;
 signal cpu1_nmi_n  : std_logic;
 signal cpu1_m1_n   : std_logic;

 signal cpu2_addr   : std_logic_vector(15 downto 0);
 signal cpu2_di     : std_logic_vector( 7 downto 0);
 signal cpu2_do     : std_logic_vector( 7 downto 0);
 signal cpu2_wr_n   : std_logic;
 signal cpu2_mreq_n : std_logic;
 signal cpu2_irq_n : std_logic;
 signal cpu2_m1_n   : std_logic;
 
 signal cpu3_addr   : std_logic_vector(15 downto 0);
 signal cpu3_di     : std_logic_vector( 7 downto 0);
 signal cpu3_do     : std_logic_vector( 7 downto 0);
 signal cpu3_wr_n   : std_logic;
 signal cpu3_mreq_n : std_logic;
 signal cpu3_nmi_n  : std_logic;
 signal cpu3_m1_n   : std_logic;

 signal bgtile_addr : std_logic_vector(15 downto 0);
 signal sprite_addr : std_logic_vector(15 downto 0);

 signal cpu1_rom_do : std_logic_vector( 7 downto 0);
 signal cpu2_rom_do : std_logic_vector( 7 downto 0);
 signal cpu3_rom_do : std_logic_vector( 7 downto 0);
 
 signal bgram_do    : std_logic_vector( 7 downto 0);
 -- Address paths of the RAM mirror. The three work RAMs are 2K deep: the lower half is
 -- the game's 1K, the upper half its shadow. wram_sel names the owner of the wram address
 -- bus in the current slot, wram_hi is a constant 0 register (see wram_addr), and
 -- harv_ptr feeds mux_addr in slot 5 as the bgram read address of the harvest.
 signal harv_ptr    : std_logic_vector(10 downto 0) := (others => '0');
 signal wram_addr   : std_logic_vector(10 downto 0);
 signal wram_hi     : std_logic := '0';   -- address bit 10 of the game path, constant 0
 signal wram_sel    : std_logic_vector(1 downto 0) := "00";  -- bus owner, see wram_addr
 signal aux_addr    : std_logic_vector(9 downto 0);   -- delivery index or catch-up address
 signal wram_idx    : std_logic_vector(9 downto 0);   -- harvest index into the wram, round/2
 -- The interleaved harvest. Round r runs from 0 to 2047, one round per pass through the
 -- six slots. bgram is read in EVERY round (index r), the three wram in every SECOND
 -- round (index r>>1, the same in the even and the odd round). The wram shadow is
 -- written one round after the read, from the captures cap_w1..cap_w3.
 signal harv_run    : std_logic := '0';
 signal harv_round  : unsigned(11 downto 0) := (others => '0');
 signal harv_wr     : std_logic;          -- wram shadow write, slot 3 of odd rounds
 -- Game writes only, without the shadow writes of harvest and drain. They feed the
 -- catch-up queue, which must see exactly the game's writes, and dbg_ram_we, so the
 -- observer in ram_diag.sv does not count the mirror's own work as game activity.
 signal wram1_we_cpu, wram2_we_cpu, wram3_we_cpu : std_logic;
 signal harv_rd     : std_logic := '0';   -- unused, never driven
 signal bg_shadow_we : std_logic := '0';
 signal bg_shadow_a  : std_logic_vector(10 downto 0) := (others => '0');
 signal cap_bg, cap_w1, cap_w2, cap_w3 : std_logic_vector(7 downto 0) := (others => '0');
 signal vcnt_d1     : std_logic_vector(8 downto 0) := (others => '0');  -- vcnt edge detect
 -- Probe for dbg_score: the six score digits as the harvest reads them (flat 0x03F8..0x03FD)
 signal score_cap   : std_logic_vector(47 downto 0) := (others => '0');
 -- Read port of the bgram shadow. The delivery reads it during a transfer. Outside both
 -- harvest and delivery the address rests on a fixed probe cell, so dbg_shadow always
 -- shows a live byte of the shadow block.
 signal bg_shadow_q : std_logic_vector(7 downto 0);
 -- Snapshot delivery: flat address 0..5119
 --   0x0000 bgram 2048, 0x0800 wram1 1024, 0x0C00 wram2 1024, 0x1000 wram3 1024
 signal snap_idx    : unsigned(12 downto 0) := (others => '0');
 signal snap_busy   : std_logic := '0';
 signal snap_run_d  : std_logic := '0';
 signal snap_stage  : std_logic_vector(1 downto 0) := "00";  -- 00 capture in slot 5, 10 push
 signal snap_cap    : std_logic_vector(7 downto 0) := (others => '0');
 signal frame_no    : unsigned(15 downto 0) := (others => '0');
 signal snap_skip   : unsigned(15 downto 0) := (others => '0');  -- harvests skipped, saturating

-- Catch-up writes (nz): game writes during the harvest window also go into the shadow,
-- so the shadow holds the state of one instant. Two paths, because the targets differ:
--   bgram : own shadow block, write port free except in slot 0, so no queue is needed.
--   wram  : one port shared with the game, one free slot per round (3 in even rounds,
--           5 in odd ones), but three CPUs can write. Hence the queue nzq.
signal harv_copy   : std_logic := '0';   -- the 2048 copy rounds only, without the drain tail
signal harv_tailc  : unsigned(6 downto 0) := (others => '0');  -- drain tail bound, in rounds
signal bg_shadow_d : std_logic_vector(7 downto 0) := (others => '0');
type   nz_array    is array (0 to 15) of std_logic_vector(19 downto 0);
signal nzq         : nz_array;  -- entries: target(19:18) addr(17:8) data(7:0)
signal nzq_wp      : unsigned(3 downto 0) := (others => '0');
signal nzq_rp      : unsigned(3 downto 0) := (others => '0');
signal nzq_cnt     : unsigned(4 downto 0) := (others => '0');
signal nzq_max     : unsigned(15 downto 0) := (others => '0');  -- sticky peak, FFFF = overflow
signal nz_slot     : std_logic;  -- the free wram slot of this round
signal nz_wr       : std_logic;  -- drain one entry in this clock
signal nz_out      : std_logic_vector(19 downto 0);  -- queue head
signal nz_w1, nz_w2, nz_w3 : std_logic;  -- drain write enable per wram
 signal bgram_we    : std_logic;
 signal wram1_do    : std_logic_vector( 7 downto 0);
 signal wram1_we    : std_logic;
 signal wram2_do    : std_logic_vector( 7 downto 0);
 signal wram2_we    : std_logic;
 signal wram3_do    : std_logic_vector( 7 downto 0);
 signal wram3_we    : std_logic;
 signal port_we     : std_logic;

 signal slot       : std_logic_vector(2 downto 0) := (others => '0');
 signal mux_addr   : std_logic_vector(15 downto 0);
 signal mux_cpu_do : std_logic_vector( 7 downto 0);
 signal mux_cpu_we : std_logic;
 signal mux_cpu_mreq : std_logic;
 signal latch_we   : std_logic;
 signal io_we      : std_logic;

 signal cs06XX_control : std_logic_vector( 7 downto 0);
 signal cs06XX_do      : std_logic_vector( 7 downto 0);
 signal cs06XX_di      : std_logic_vector( 7 downto 0);

 -- game20k: Namco 06XX and 51XX in namco_io.vhd, the 54XX on its chip select 3
 signal n06_nmi         : std_logic;
 signal n06_cs          : std_logic_vector(3 downto 1);
 signal n06_we          : std_logic_vector(3 downto 1);
 signal n06_wdata       : std_logic_vector(7 downto 0);
 signal cs51xx_ena      : std_logic := '0';
 signal cs51xx_ena_div  : std_logic_vector(3 downto 0) := "0000";
 signal cs51xx_in       : std_logic_vector(15 downto 0);
 signal cs51xx_vblank   : std_logic;
 signal cs51xx_rom_addr : std_logic_vector( 9 downto 0);
 signal cs51xx_rom_do   : std_logic_vector( 7 downto 0);
 signal cs54xx_cmd      : std_logic_vector( 7 downto 0);         -- byte from the 06XX, K and R0 of the 54XX
 
-- signal cs54xx_cmd        : std_logic_vector( 3 downto 0);
 signal cs54xx_do         : std_logic_vector( 7 downto 0);
 
 signal cs54xx_ena      : std_logic;
 signal cs54xx_ena_div  : std_logic_vector(2 downto 0) := "000";
 signal cs5Xxx_rw       : std_logic;
 
 signal cs54xx_rom_addr : std_logic_vector(10 downto 0); 
 signal cs54xx_rom_do   : std_logic_vector( 7 downto 0); 
 
 signal cs54xx_irq_n      : std_logic := '1'; 
 signal cs54xx_audio_1    : std_logic_vector( 3 downto 0); 
 signal cs54xx_audio_2    : std_logic_vector( 3 downto 0); 
 signal cs54xx_audio_3    : std_logic_vector( 3 downto 0); 

 signal cs05XX_ctrl       : std_logic_vector( 5 downto 0);
 
 signal dip_switch_a  : std_logic_vector (7 downto 0);
 signal dip_switch_b  : std_logic_vector (7 downto 0);
 signal dip_switch_do : std_logic_vector (1 downto 0);
 
 signal bgtile_num     : std_logic_vector( 7 downto 0);
 signal bgtile_num_r   : std_logic_vector( 7 downto 0);
 signal bgtile_color   : std_logic_vector( 7 downto 0);
 signal bgtile_color_r : std_logic_vector( 7 downto 0);
 signal bggraphx_addr  : std_logic_vector(11 downto 0);
 signal bggraphx_do    : std_logic_vector( 7 downto 0);
 signal bgpalette_addr : std_logic_vector( 7 downto 0);
 signal bgpalette_do   : std_logic_vector( 7 downto 0); 
 signal bgbits         : std_logic_vector( 3 downto 0);
 signal hcnt_bg_d      : std_logic_vector( 1 downto 0);  -- game20k: delayed hcnt(1 downto 0)

 signal rgb_palette_addr : std_logic_vector( 4 downto 0);
 signal rgb_palette_do   : std_logic_vector( 7 downto 0); 
 
 signal sprite_num     : std_logic_vector(5 downto 0);
 signal sprite_state   : std_logic_vector(2 downto 0); 
 signal sprite_line    : std_logic_vector(7 downto 0);
 signal sptile_num     : std_logic_vector(7 downto 0);
 signal sptile_color   : std_logic_vector(7 downto 0);
 signal spdata         : std_logic_vector(3 downto 0);
 signal spvcnt         : std_logic_vector(4 downto 0);
 signal sphcnt         : std_logic_vector(4 downto 0);
 signal spram_wr_addr  : std_logic_vector(8 downto 0);
 signal spram_rd_addr  : std_logic_vector(8 downto 0);
 signal spram_we       : std_logic;
 signal spram_clr      : std_logic;
 signal spgraphx_addr  : std_logic_vector(12 downto 0);
 signal spgraphx_do    : std_logic_vector(7 downto 0);
 signal sppalette_addr : std_logic_vector(7 downto 0);
 signal sppalette_do   : std_logic_vector(7 downto 0); 
 signal spbits_wr      : std_logic_vector(3 downto 0);
 signal spbits_rd      : std_logic_vector(3 downto 0);
 signal spflip_V ,spflip_H  : std_logic;
 signal spflip_2V,spflip_2H : std_logic_vector(1 downto 0);
 signal spflip_3V,spflip_3H : std_logic_vector(2 downto 0);
 signal spflips             : std_logic_vector(12 downto 0);

 signal flip_h         : std_logic; 
 
 signal spram1_addr    : std_logic_vector(8 downto 0);
 signal spram1_di      : std_logic_vector(3 downto 0);
 signal spram1_do      : std_logic_vector(3 downto 0);
 signal spram1_we      : std_logic;
 signal spram2_addr    : std_logic_vector(8 downto 0);
 signal spram2_di      : std_logic_vector(3 downto 0);
 signal spram2_do      : std_logic_vector(3 downto 0);
 signal spram2_we      : std_logic;
 
 signal stars_hcnt      : std_logic_vector( 8 downto 0);
 signal stars_vcnt      : std_logic_vector( 8 downto 0);
 signal stars_offset    : std_logic_vector( 7 downto 0); 
 signal stars_set0_addr : std_logic_vector( 6 downto 0);
 signal stars_set0_data : std_logic_vector(15 downto 0);
 signal star_color_set0 : std_logic_vector( 5 downto 0);
 signal stars_set1_addr : std_logic_vector( 6 downto 0);
 signal stars_set1_data : std_logic_vector(15 downto 0);
 signal star_color_set1 : std_logic_vector( 5 downto 0);
 signal stars_set2_addr : std_logic_vector( 6 downto 0);
 signal stars_set2_data : std_logic_vector(15 downto 0);
 signal star_color_set2 : std_logic_vector( 5 downto 0);
 signal stars_set3_addr : std_logic_vector( 6 downto 0);
 signal stars_set3_data : std_logic_vector(15 downto 0);
 signal star_color_set3 : std_logic_vector( 5 downto 0);
 signal star_color      : std_logic_vector( 5 downto 0);
 
 signal irq1_clr_n  : std_logic;
 signal irq2_clr_n  : std_logic;
 signal nmion_n     : std_logic;
 signal reset_cpu_n : std_logic;

 signal snd_ram_0_we : std_logic;
 signal snd_ram_1_we : std_logic;
 signal snd_audio    : std_logic_vector(9 downto 0);

 

begin

clock_18n <= not clock_18;
reset_n   <= not reset;

dip_switch_a <= dip_a; -- game20k: cab:7 na:6 test:5 freeze:4 demo sound:3 na:2 difficulty:1-0
dip_switch_b <= dip_b; -- game20k: lives:7-6 bonus:5-3 coinage:2-0
dip_switch_do <= 	dip_switch_a(to_integer(unsigned(mux_addr(2 downto 0)))) & 
									dip_switch_b(to_integer(unsigned(mux_addr(2 downto 0))));

audio <= ("00" & cs54xx_audio_1 &  "0000" ) + ("00" & cs54xx_audio_2 &  "0000" )+ ('0'&snd_audio(9 downto 1));
--audio <= ("00" & cs54xx_audio_1 &  "00000" ) + ('0'&snd_audio);
--audio <= ('0'&snd_audio);

-- make access slots from 18MHz
-- 6MHz for pixel clock and sound machine
-- 3MHz for cpu, background and sprite machine

--       slots  |   0  |   1  |   2  |    3   |   4   |   5   |
-- wram  access | cpu1 | cpu2 | cpu3 | bgram  | spram | n.u.  | 
-- sound access | cpu1 | cpu2 | cpu3 | sndram | n.u.  | sndram| 

-- enable signals are one slot early

process (clock_18)
begin
 if rising_edge(clock_18) then
  ena_vidgen      <= '0';
  ena_snd_machine <= '0';
  cpu1_ena   <= '0';
  cpu2_ena   <= '0';
  cpu3_ena   <= '0';
  cs54xx_ena <= '0';
  cs51xx_ena <= '0';

  -- game20k: reset puts the slot counter into a defined phase, the same as its power-up
  -- value, otherwise the phase between slot and hcnt depends on how the clock starts up
  if reset = '1' then
   slot <= (others => '0');
   cs54xx_ena_div <= (others => '0');
   cs51xx_ena_div <= (others => '0');
  elsif slot = "101" then
   slot <= (others => '0');
	cs54xx_ena_div <= cs54xx_ena_div +'1';
	-- game20k: the 51XX and the 54XX run at 18.432 MHz / 12 / 6 as on the board, one
	-- instruction cycle every 12 slot rounds
	if cs51xx_ena_div = "1011" then cs51xx_ena_div <= "0000"; else cs51xx_ena_div <= cs51xx_ena_div + '1'; end if;
  else
		slot <= std_logic_vector(unsigned(slot) + 1);
  end if;   
	
	if slot = "101" or slot = "010" then ena_vidgen      <= '1';	end if;	
	if slot = "010" or slot = "100" then ena_snd_machine <= '1';	end if;	
	if slot = "101" then cpu1_ena <= '1';	end if;
	if slot = "000" then cpu2_ena <= '1';	end if;	
	if slot = "001" then cpu3_ena <= '1';	end if;
	
	-- game20k: the 54XX on the board clock too. Faster, it takes the 06XX byte before the
	-- main CPU has written it (cs54xx_ena_div is no longer used)
	if slot = "000" and cs51xx_ena_div = "0000" then cs54xx_ena <= '1'; end if;
	if slot = "000" and cs51xx_ena_div = "0000" then cs51xx_ena <= '1'; end if;
		
 end if;
end process;

--- SPRITES MACHINE ---
-----------------------
	
-- 0x8B80 - 0x8BFF : 64 sprites tile num, tile color
-- 0x9380 - 0x93FF : 64 sprites pos v, pos h lsb
-- 0x9B80 - 0x9BFF : 64 sprites 2xH, 2xV, flip H, flip V

sprite_addr <= X"03"&'1' & sprite_num & sprite_state(0);
sprite_line <= wram2_do + vcnt(7 downto 0);

process (clock_18, slot)
begin
 if rising_edge(clock_18) then 
	if hcnt = std_logic_vector(to_unsigned(191,9)) then
		sprite_num   <= "000000";
		sprite_state <= "000";
		spram_rd_addr<= "111101111";
	end if;
	
	if slot = "100" and sprite_state = "000" then
		sptile_num   <= wram1_do;
		spdata       <= wram3_do(3 downto 0);
		spvcnt       <= sprite_line(4 downto 0);
		if  sprite_line(7 downto 4) = "1111" or      				     -- size V x 1
		   (sprite_line(7 downto 5) = "111" and wram3_do(3)='1' )then -- size V x 2 -- fixed Dar : 04/11/2017
--		   (sprite_line(7 downto 5) = "111" and wram3_do(2)='1' )then -- size V x 2
			sprite_state <= "001";
		else
			if sprite_num = "111111" then
				sprite_state <= "111";
			else
				sprite_num <= sprite_num + "000001";			
				sprite_state <= "000";
			end if;		
		end if;	
	end if;
	
	if slot = "100" and sprite_state = "001" then
		sptile_color  <= wram1_do;
		spram_wr_addr <= wram3_do(0) & wram2_do;
		sphcnt        <= "00000";
		sprite_state  <= "010";
	end if;

	if sprite_state = "010" then
		sphcnt <= sphcnt + "00001";
		sprite_state  <= "011";
	end if; 

	if sprite_state = "011" then
		sphcnt <= sphcnt + "00001";
		spram_wr_addr <= spram_wr_addr + "000000001";
		if 	(sphcnt = "01111" and spdata(2) = '0' ) or   -- size H x 1  -- fixed Dar : 04/11/2017
				(sphcnt = "11111" and spdata(2) = '1' ) then -- size H x 2  -- fixed Dar : 04/11/2017 
--		if 	(sphcnt = "01111" and spdata(3) = '0' ) or   -- size H x 1
--				(sphcnt = "11111" and spdata(3) = '1' ) then -- size H x 2
			if sprite_num = "111111" then
				sprite_state <= "111";
			else
				sprite_num <= sprite_num + "000001";			
				sprite_state <= "000";
			end if;		
		end if;
	end if; 
	
	if slot = "000" or slot = "011" then
		if vcnt(0) = '1' then
			spbits_rd <= spram2_do;
		else
			spbits_rd <= spram1_do;
		end if;
	end if;
	
	spram_clr <= '0';
	if slot = "001" or slot = "100" then
		spram_clr <= '1';
	end if;
	
	if slot = "010" or slot = "101" then
		spram_rd_addr <= spram_rd_addr + "000000001";
	end if;

 end if;
end process;

spram_we <= '1' when sprite_state = "011" and spbits_wr /= "1111" else '0';

spram1_addr <= spram_wr_addr when vcnt(0) = '1' else spram_rd_addr;
spram2_addr <= spram_wr_addr when vcnt(0) = '0' else spram_rd_addr;

spram1_di  <= spbits_wr when vcnt(0) = '1' else "1111";
spram2_di  <= spbits_wr when vcnt(0) = '0' else "1111";
 
spram1_we <= spram_we when vcnt(0) = '1' else spram_clr;
spram2_we <= spram_we when vcnt(0) = '0' else spram_clr; 

spflip_H <= spdata(0) xor flip_h; spflip_2H <= spflip_H & spflip_H;
spflip_V <= spdata(1); spflip_2V <= spflip_V & spflip_V;

with spdata(3 downto 2) select
spflips <= 	"0000000"                       & spflip_V & spflip_2H & spflip_V & spflip_2V when "00",
						"000000"  &            spflip_H & spflip_V & spflip_2H & spflip_V & spflip_2V when "01",
						"00000"   & spflip_V & '0'      & spflip_V & spflip_2H & spflip_V & spflip_2V when "10",
						"00000"   & spflip_V & spflip_H & spflip_V & spflip_2H & spflip_V & spflip_2V when others;

with spdata(3 downto 2) select
spgraphx_addr <=  (sptile_num(6 downto 0)                             & spvcnt(3) & sphcnt(3 downto 2) & spvcnt(2 downto 0) ) xor spflips when "00",
						(sptile_num(6 downto 1) & 						sphcnt(4) & spvcnt(3) & sphcnt(3 downto 2) & spvcnt(2 downto 0) ) xor spflips when "01",
						(sptile_num(6 downto 2) & spvcnt(4) & sptile_num(0) & spvcnt(3) & sphcnt(3 downto 2) & spvcnt(2 downto 0) ) xor spflips when "10",
						(sptile_num(6 downto 2) & spvcnt(4) & sphcnt(4)     & spvcnt(3) & sphcnt(3 downto 2) & spvcnt(2 downto 0) ) xor spflips when others;

sppalette_addr <= sptile_color(5 downto 0) &
									spgraphx_do(to_integer(unsigned('1' & ((not sphcnt(1 downto 0)) xor spflip_2H )))) &
									spgraphx_do(to_integer(unsigned('0' & ((not sphcnt(1 downto 0)) xor spflip_2H )))); 

spbits_wr <= 	sppalette_do(3 downto 0);

--- BACKGROUND TILES MACHINE ---
-----------------------_--------
	
-- 0x8000-0x83FF : tile num
-- 0x8400-0x87FF : tile color

bgtile_addr <= 	"10000" & hcnt(1) & vcnt(7 downto 3) & hcnt(7 downto 3)                                when (hcnt(8)='1' and flip_h='0') else
						"10000" & hcnt(1) & hcnt(4) & hcnt(4) & hcnt(4) & hcnt(4) & hcnt(3) & vcnt(7 downto 3) when (hcnt(8)='0' and flip_h='0') else
						"10000" & hcnt(1) & not( vcnt(7 downto 3) & hcnt(7 downto 3))                          when (hcnt(8)='1' and flip_h='1') else
						"10000" & hcnt(1) & not( hcnt(4) & hcnt(4) & hcnt(4) & hcnt(4) & hcnt(3) & vcnt(7 downto 3));
								

-- Attention : slot et hcnt ne sont pas entierement synchronisés
-- slot  |0 |1 | 2 |3 |4 |5 | ...
-- hcnt  | 0 or 1  | 1 or 2 | ...

process (clock_18, slot)
begin
 if rising_edge(clock_18) then 
		if slot = "011" and hcnt(2 downto 1) = "00" then
			bgtile_num <= bgram_do;
		end if;
		if slot = "011" and hcnt(2 downto 1) = "01" then
			bgtile_color <= bgram_do;
		end if;
		if (slot = "000" or slot = "011") and hcnt(2 downto 0) = "111" then
			bgtile_num_r <= bgtile_num;
			bgtile_color_r <= bgtile_color;
		end if;
 end if;
end process;

bggraphx_addr <= 	'1' & bgtile_num_r(6 downto 0) & not hcnt(2) &     vcnt(2 downto 0) when flip_h='0' else
									'1' & bgtile_num_r(6 downto 0) &     hcnt(2) & not vcnt(2 downto 0);

-- game20k: the character ROM bg_graphics reads on the rising edge of clock_18, one register
-- stage, so its byte arrives one clock after the address (Gowin specific, see the header).
-- The bit select therefore uses hcnt(1 downto 0) delayed by one clock to match the byte.
process (clock_18)
begin
 if rising_edge(clock_18) then
  hcnt_bg_d <= hcnt(1 downto 0);
 end if;
end process;

bgpalette_addr <= bgtile_color_r(5 downto 0) &
									bggraphx_do(to_integer(unsigned('1' & ((hcnt_bg_d) xor (flip_h & flip_h))))) &
									bggraphx_do(to_integer(unsigned('0' & ((hcnt_bg_d) xor (flip_h & flip_h))))); 

bgbits <= bgpalette_do(3 downto 0);

dbg_tile_num   <= bgtile_num_r;
dbg_tile_color <= bgtile_color_r;
dbg_hcnt       <= hcnt;
dbg_vcnt       <= vcnt;
dbg_bgaddr     <= bggraphx_addr;
dbg_ram_we     <= bgram_we & wram1_we_cpu & wram2_we_cpu & wram3_we_cpu;  -- game writes only
dbg_ram_addr   <= mux_addr(10 downto 0);
dbg_ram_data   <= mux_cpu_do;
dbg_score      <= score_cap;
dbg_shadow     <= bg_shadow_q;
dbg_bgdata     <= bggraphx_do;
dbg_bgbits     <= bgbits;

--- STARS MACHINE --- 
---------------------

stars_data : entity work.stars
port map(
	clk       => clock_18n,
	addr_set0 => stars_set0_addr,
	data_set0 => stars_set0_data,
	addr_set1 => stars_set1_addr,
	data_set1 => stars_set1_data,
	addr_set2 => stars_set2_addr,
	data_set2 => stars_set2_data,
	addr_set3 => stars_set3_addr,
	data_set3 => stars_set3_data
);

stars_machine_0 : entity work.stars_machine
port  map(
	clk              => clock_18,
	ena_hcnt         => ena_vidgen,
	hcnt             => stars_hcnt,
	vcnt             => stars_vcnt,
	stars_set_addr_o => stars_set0_addr,
  stars_set_data   => stars_set0_data,
  offset_y         => stars_offset,
  star_color       => star_color_set0
);

stars_machine_1 : entity work.stars_machine
port  map(
	clk              => clock_18,
	ena_hcnt         => ena_vidgen,
	hcnt             => stars_hcnt,
	vcnt             => stars_vcnt,
	stars_set_addr_o => stars_set1_addr,
  stars_set_data   => stars_set1_data,
  offset_y         => stars_offset,
  star_color       => star_color_set1
);

stars_machine_2 : entity work.stars_machine
port  map(
	clk              => clock_18,
	ena_hcnt         => ena_vidgen,
	hcnt             => stars_hcnt,
	vcnt             => stars_vcnt,
	stars_set_addr_o => stars_set2_addr,
  stars_set_data   => stars_set2_data,
  offset_y         => stars_offset,
  star_color       => star_color_set2
);

stars_machine_3 : entity work.stars_machine
port  map(
	clk              => clock_18,
	ena_hcnt         => ena_vidgen,
	hcnt             => stars_hcnt,
	vcnt             => stars_vcnt,
	stars_set_addr_o => stars_set3_addr,
  stars_set_data   => stars_set3_data,
  offset_y         => stars_offset,
  star_color       => star_color_set3
);

process (clock_18)
	subtype speed is integer range -3 to 3;
	type speed_array is array(0 to 7) of speed; 
	variable speeds : speed_array := ( -1, -2, -3, 0, 3, 2, 1, 0 ); 
begin
 if rising_edge(clock_18) then 

	if ena_vidgen = '1' then
		if hcnt = std_logic_vector(to_unsigned(256+8,9)) then
			stars_hcnt <= "000000000";
			stars_vcnt <= stars_vcnt + "000000001";
			if vcnt = std_logic_vector(to_unsigned(128+6,9)) then
				stars_vcnt <= "000000000";
				stars_offset <= stars_offset + 
					std_logic_vector(to_signed(speeds(to_integer(unsigned(cs05XX_ctrl(2 downto 0)))),8));
			end if;
		else
			stars_hcnt <= stars_hcnt + "000000001";
		end if;	
	end if; 
	
	star_color <= "000000";
	if cs05XX_ctrl(5) = '1' then
		if cs05XX_ctrl(4 downto 3) = "00" then star_color <= star_color_set0 or star_color_set2; end if;
		if cs05XX_ctrl(4 downto 3) = "01" then star_color <= star_color_set1 or star_color_set2; end if;
		if cs05XX_ctrl(4 downto 3) = "10" then star_color <= star_color_set0 or star_color_set3; end if;
		if cs05XX_ctrl(4 downto 3) = "11" then star_color <= star_color_set1 or star_color_set3; end if;
	end if;

 end if;
end process; 
	
--- VIDEO MUX ---
-----------------

rgb_palette_addr <= ('0' & spbits_rd) when bgbits = "1111" else ('1' & bgbits);

process (clock_18, rgb_palette_addr)
begin
 if rising_edge(clock_18)then
  if rgb_palette_addr(3 downto 0) = "1111" then
		video_r <= star_color(1 downto 0) & "0";
		video_g <= star_color(3 downto 2) & "0";
		video_b <= star_color(5 downto 4);		
	else
		video_r <= rgb_palette_do(2 downto 0);
		video_g <= rgb_palette_do(5 downto 3);
		video_b <= rgb_palette_do(7 downto 6);	
	end if;
 end if;
end process;


--- SOUND MACHINE ---
---------------------

sound_machine : entity work.sound_machine
port map(
clock_18  => clock_18,
ena       => ena_snd_machine,
hcnt      => hcnt(5 downto 0),
cpu_addr  => mux_addr(3 downto 0), 
cpu_do    => mux_cpu_do(3 downto 0), 
ram_0_we  => snd_ram_0_we,
ram_1_we  => snd_ram_1_we,
audio     => snd_audio,
rom_wr_clk  => rom_wr_clk,
rom_wr_addr => rom_wr_addr(7 downto 0),
rom_wr_data => rom_wr_data,
rom_wr_en   => rom_wr_en(9 downto 8)   -- 8 = sound_seq, 9 = sound_samples
);

--- Harvest for the RAM mirror ----------------------------------------------------------
-- The ring has six slots, slot="101" is the last one. The harvest starts on the edge
-- vcnt 239 -> 240, the start of vertical blanking, and runs 2048 rounds:
--   every round r : slot 5 reads bgram[r], its shadow lives in a separate block
--   even round r  : slot 5 also reads wram[r>>1] from the GAME half
--   odd round r   : slot 3 writes the wram shadow[r>>1] (upper half) from the capture
-- The interleaving puts the catch-up drain of odd rounds behind the shadow write, so the
-- drain wins (see nz_slot).
process (clock_18)
	variable idx : integer range 0 to 7;
begin
	if rising_edge(clock_18) then
		vcnt_d1      <= vcnt;
		bg_shadow_we <= '0';

		-- A harvest starts only while no transfer runs. Otherwise frame_no would change
		-- in the middle of a transfer and the snapshot would be half old and half new.
		-- Harvest and delivery also share slot 5, so they must never overlap. A start
		-- that falls into a transfer counts as skipped (snap_skip saturates at FFFF).
		if vcnt_d1 = "011101111" and vcnt = "011110000" then   -- 239 -> 240
			if snap_run = '0' then
				harv_run   <= '1';
				harv_copy  <= '1';
				harv_round <= (others => '0');
				harv_tailc <= (others => '0');
				frame_no   <= frame_no + 1;
			elsif snap_skip /= x"FFFF" then
				snap_skip <= snap_skip + 1;
			end if;
		end if;

		if harv_run = '0' then
			-- Outside the harvest the delivery owns the shadow address. While no delivery runs
			-- either, it rests on the probe cell bgram index 1018 = flat 0x03FA for dbg_shadow.
			-- NOT 0x03F8: that is the ones digit of the score, which is always 0.
			if snap_busy = '1' and snap_idx < 2048 then
				bg_shadow_a <= std_logic_vector(snap_idx(10 downto 0));
			else
				bg_shadow_a <= "01111111010";
			end if;
		end if;

		if harv_copy = '1' then
			-- Slot 5: read and advance the round. The wram clock on clock_18n and deliver in
			-- the middle of the slot, bgram reads asynchronously, the capture is at the slot end.
			if slot = "101" then
				cap_bg <= bgram_do;
				if harv_round(0) = '0' then
					cap_w1 <= wram1_do;
					cap_w2 <= wram2_do;
					cap_w3 <= wram3_do;
				end if;

				bg_shadow_we <= '1';
				bg_shadow_a  <= std_logic_vector(harv_round(10 downto 0));
				bg_shadow_d  <= bgram_do;

				-- Probe for dbg_score: record the six score digits, flat 0x03F8 to 0x03FD,
				-- bgram index 1016 to 1021.
				if harv_round >= 1016 and harv_round <= 1021 then
					idx := to_integer(harv_round - 1016);
					score_cap(idx*8+7 downto idx*8) <= bgram_do;
				end if;

				if harv_round = 2047 then
					harv_copy <= '0';    -- copied, only the drain tail remains
				else
					harv_round <= harv_round + 1;
				end if;
			end if;
		elsif harv_run = '1' then
			-- DRAIN TAIL. The window ends only when the queue is empty: the queue resets as
			-- soon as harv_run drops, so entries still queued would be lost and the shadow
			-- would not hold the state of one instant. Nothing copies here, so slot 3 and slot 5
			-- are both free and two entries drain per round: a full queue of 16 empties in
			-- eight rounds. The bound of 63 rounds only matters under a continuous stream of
			-- game writes, which could otherwise keep the window open and with it block every
			-- transfer, since a transfer waits for the window to end.
			if slot = "101" then
				if nzq_cnt = 0 or harv_tailc = 63 then
					harv_run <= '0';
				else
					harv_tailc <= harv_tailc + 1;
				end if;
			end if;
		end if;

		-- CATCH-UP FOR bgram, without a queue: one clock after the game write. The shadow
		-- block is separate and its write port is free except in slot 0. A game write always
		-- comes in slot 0, 1 or 2, so it lands here in slot 1, 2 or 3 and never collides
		-- with the harvest write, which lands in slot 0.
		-- This block sits BELOW the harvest block on purpose: if both ever assign in the
		-- same clock, the later assignment wins.
		if harv_run = '1' and bgram_we = '1' then
			bg_shadow_we <= '1';
			bg_shadow_a  <= mux_addr(10 downto 0);
			bg_shadow_d  <= mux_cpu_do;
		end if;
	end if;
end process;

-- Snapshot delivery. One byte per round: address in slot 5, capture at the end of that
-- slot, push on the next clock. Runs only while no harvest runs, because harvest and
-- delivery share slot 5: a harvest starts only outside a transfer, and a transfer that
-- begins during a harvest waits for its end. snap_full pauses the delivery.
process (clock_18)
begin
	if rising_edge(clock_18) then
		snap_push <= '0';
		snap_run_d <= snap_run;

		if snap_run = '1' and snap_run_d = '0' then
			snap_idx   <= (others => '0');    -- new transfer, start over
			snap_busy  <= '1';
			snap_stage <= "00";
		end if;
		if snap_run = '0' then
			snap_busy <= '0';
		end if;

		if snap_busy = '1' and harv_run = '0' and snap_full = '0' then
			if slot = "101" and snap_stage = "00" then
				-- CAPTURE IN THE SAME SLOT, not one clock later. The three wram clock on
				-- clock_18n, so they deliver mid slot and hold the value only until the next
				-- falling edge. That edge lies in the middle of slot 0, where the game address
				-- is already applied, so a capture one clock later would take the GAME's read
				-- value instead of the shadow's. The bgram shadow block clocks on the rising
				-- edge and holds its output, so it would tolerate a late capture. This is why
				-- the wram bytes are sensitive to this timing and the bgram bytes are not.
				-- The push follows one clock later (snap_stage "10"), so snap_byte is already
				-- stable while snap_push is high.
				if snap_idx < 2048 then snap_cap <= bg_shadow_q;
				elsif snap_idx < 3072 then snap_cap <= wram1_do;
				elsif snap_idx < 4096 then snap_cap <= wram2_do;
				else                        snap_cap <= wram3_do;
				end if;
				snap_stage <= "10";
			elsif snap_stage = "10" then
				snap_push  <= '1';
				snap_stage <= "00";
				if snap_idx = 5119 then snap_busy <= '0';
				else                    snap_idx <= snap_idx + 1;
				end if;
			end if;
		end if;
	end if;
end process;
snap_byte  <= snap_cap;
snap_frame <= std_logic_vector(frame_no);
dbg_skip   <= std_logic_vector(snap_skip);
dbg_nzmax  <= std_logic_vector(nzq_max);
dbg_harv   <= harv_run;

-- Address selection. The wram index is harv_round/2, the same in the even and odd round.
harv_ptr <= std_logic_vector(harv_round(10 downto 0));
wram_idx <= std_logic_vector(harv_round(10 downto 1));
-- The shadow write enable must be COMBINATIONAL so that it applies in the same slot as
-- the address. As a register it would be one clock late: by then the game address is
-- applied, wram_sel is back to "00", and the harvest would write its captures into the
-- game half of the work RAM.
harv_wr <= '1' when (harv_copy = '1' and slot = "011" and harv_round(0) = '1') else '0';

-- Drain slot of the catch-up queue: whichever of the two is free. During the copy phase
-- the harvest holds slot 3 in odd rounds and slot 5 in even rounds, the other one is
-- free. In the drain tail nothing copies, both are free and the queue drains twice as
-- fast. In odd rounds the drain lies BEHIND the shadow write on purpose, so a game write
-- that arrived after the capture wins. In even rounds the drain lies before the harvest
-- read, and the harvest wins: it copies the CURRENT memory content, which is the same
-- or a newer value.
nz_slot <= '1' when (slot = "011" and (harv_copy = '0' or harv_round(0) = '0')) or
                    (slot = "101" and (harv_copy = '0' or harv_round(0) = '1')) else '0';
nz_wr   <= '1' when harv_run = '1' and nzq_cnt /= 0 and nz_slot = '1' else '0';
nz_out  <= nzq(to_integer(nzq_rp));
nz_w1   <= '1' when nz_wr = '1' and nz_out(19 downto 18) = "01" else '0';
nz_w2   <= '1' when nz_wr = '1' and nz_out(19 downto 18) = "10" else '0';
nz_w3   <= '1' when nz_wr = '1' and nz_out(19 downto 18) = "11" else '0';

-- Delivery and catch-up share the code "11": both address the upper half, and they never
-- run at the same time. The delivery runs only outside the harvest window, the catch-up
-- only inside it.
aux_addr <= nz_out(17 downto 8) when harv_run = '1' else std_logic_vector(snap_idx(9 downto 0));
wram_sel <= "01" when (harv_copy = '1' and slot = "101" and harv_round(0) = '0') else
            "10" when (harv_copy = '1' and slot = "011" and harv_round(0) = '1') else
            "11" when (nz_wr = '1') else
            "11" when (snap_busy = '1' and harv_run = '0' and slot = "101"
                       and snap_idx >= 2048) else
            "00";

-- The catch-up queue. Enqueue: every game write into the three work RAMs during the
-- harvest window, unconditionally, with no comparison against the harvest pointer.
-- Dequeue: one entry per free slot (nz_wr). Both can happen in the same clock.
process (clock_18)
	variable c : unsigned(4 downto 0);
begin
	if rising_edge(clock_18) then
		c := nzq_cnt;
		if harv_run = '1' then
			if (wram1_we_cpu or wram2_we_cpu or wram3_we_cpu) = '1' then
				if nzq_cnt = 16 then
					-- The queue is sized well above the expected peak. If it fills anyway, one entry is lost and nzq_max jumps to
					-- FFFF, so the loss is visible instead of silent.
					nzq_max <= x"FFFF";
				else
					-- target code: wram1 = "01", wram2 = "10", wram3 = "11"
					nzq(to_integer(nzq_wp)) <=
						((wram2_we_cpu or wram3_we_cpu) & (wram1_we_cpu or wram3_we_cpu))
						& mux_addr(9 downto 0) & mux_cpu_do;
					nzq_wp <= nzq_wp + 1;
					c := c + 1;
				end if;
			end if;
			if nz_wr = '1' then
				nzq_rp <= nzq_rp + 1;
				c := c - 1;
			end if;
			nzq_cnt <= c;
			if nzq_max /= x"FFFF" and c > nzq_max(4 downto 0) then
				nzq_max <= "00000000000" & c;
			end if;
		else
			nzq_wp  <= (others => '0');
			nzq_rp  <= (others => '0');
			nzq_cnt <= (others => '0');
		end if;
	end if;
end process;

-- Shadow of the video RAM: own block, not bound to a slot, written only by the harvest process.
bgram_shadow : entity work.g20k_spram
generic map( dWidth => 8, aWidth => 11)
port map(
 clk  => clock_18,
 we   => bg_shadow_we,
 addr => bg_shadow_a,
 d    => bg_shadow_d,
 q    => bg_shadow_q
);

--- CPUS -------------
----------------------

with slot select
mux_addr <= 	cpu1_addr   when "000",
							cpu2_addr   when "001",
							cpu3_addr   when "010",
							bgtile_addr when "011",
							sprite_addr when "100",
							-- Slot 5: the lower eleven bits carry the harvest pointer for bgram,
							-- the read address of the harvest. The upper five bits stay 01010,
							-- Dar's idle value X"5555", which no address decoder in this file
							-- matches, so the decoders keep seeing an idle address in slot 5
							-- and the pointer reaches bgram without a second address mux.
							"01010" & harv_ptr when others;

with slot select
mux_cpu_do <= 	cpu1_do when "000",
					cpu2_do when "001",
					cpu3_do when "010",
					X"00"   when others;

mux_cpu_we <= 	(not cpu1_wr_n and cpu1_ena)or
					(not cpu2_wr_n and cpu2_ena)or
					(not cpu3_wr_n and cpu3_ena);

mux_cpu_mreq <= 	(not cpu1_mreq_n and cpu1_ena) or
						(not cpu2_mreq_n and cpu2_ena) or
						(not cpu3_mreq_n and cpu3_ena);
									
-- Address of the three work RAMs (2K each: game in the lower half, shadow in the upper).
-- Bit 10 of the game path is the constant register wram_hi, NEVER mux_addr(10): a game
-- access to 0x8C00/0x9400/0x9C00 stays the alias of 0x8800/0x9000/0x9800 it is on 1K RAMs.
with wram_sel select
wram_addr <= 	wram_hi & mux_addr(9 downto 0)   when "00",  -- game, bit 10 from the register
					'0'     & wram_idx               when "01",  -- harvest reads the GAME half
					'1'     & wram_idx               when "10",  -- shadow write
					'1'     & aux_addr               when others; -- delivery / catch-up

latch_we <= '1' when mux_cpu_we = '1' and mux_addr(15 downto 11) = "01101" else '0';
io_we    <= '1' when mux_cpu_we = '1' and mux_addr(15 downto 11) = "01110" else '0';
bgram_we <= '1' when mux_cpu_we = '1' and mux_addr(15 downto 11) = "10000" else '0';
wram1_we_cpu <= '1' when mux_cpu_we = '1' and mux_addr(15 downto 11) = "10001" else '0';
wram2_we_cpu <= '1' when mux_cpu_we = '1' and mux_addr(15 downto 11) = "10010" else '0';
wram3_we_cpu <= '1' when mux_cpu_we = '1' and mux_addr(15 downto 11) = "10011" else '0';
wram1_we <= wram1_we_cpu or harv_wr or nz_w1;
wram2_we <= wram2_we_cpu or harv_wr or nz_w2;
wram3_we <= wram3_we_cpu or harv_wr or nz_w3;
port_we  <= '1' when mux_cpu_we = '1' and mux_addr(15 downto 11) = "10100" else '0';

snd_ram_0_we <= '1' when mux_cpu_we = '1' and mux_addr(15 downto 11) = "01101"  and mux_addr(5 downto 4) = "00" else '0';
snd_ram_1_we <= '1' when mux_cpu_we = '1' and mux_addr(15 downto 11) = "01101"  and mux_addr(5 downto 4) = "01" else '0';

process (reset, clock_18n, io_we) 
begin
 if reset='1' then
			irq1_clr_n  <= '0';
			irq2_clr_n  <= '0';
			nmion_n     <= '0';
			reset_cpu_n <= '0';
			cpu1_irq_n  <= '1';
			cpu2_irq_n  <= '1';
			cs05XX_ctrl <= "000000";
			flip_h <= '0';
			cs54xx_cmd  <= X"00";  -- game20k
			
 else 
  if rising_edge(clock_18n) then 
		if latch_we ='1' and mux_addr(5 downto 4) = "10" then 
			if mux_addr(2 downto 0) = "000" then irq1_clr_n  <= mux_cpu_do(0); end if;
			if mux_addr(2 downto 0) = "001" then irq2_clr_n  <= mux_cpu_do(0); end if;
			if mux_addr(2 downto 0) = "010" then nmion_n     <= mux_cpu_do(0); end if;
			if mux_addr(2 downto 0) = "011" then reset_cpu_n <= mux_cpu_do(0); end if;
		end if;
		
		if port_we ='1' then 
			if mux_addr(2 downto 0) < "110" then cs05XX_ctrl(to_integer(unsigned(mux_addr(2 downto 0)))) <= mux_cpu_do(0); end if;
			if mux_addr(2 downto 0) = "111" then flip_h <= mux_cpu_do(0); end if;
		end if;

		if irq1_clr_n = '0' then 
		  cpu1_irq_n <= '1';
		elsif vcnt = std_logic_vector(to_unsigned(240,9)) then cpu1_irq_n <= '0';
 		end if;
		if irq2_clr_n = '0' then 
		  cpu2_irq_n <= '1';
		elsif vcnt = std_logic_vector(to_unsigned(240,9)) then cpu2_irq_n <= '0';
		end if;
		
		-- game20k: the 54XX takes the bytes the 06XX writes to it
		if n06_we(3) = '1' then cs54xx_cmd <= n06_wdata; end if;
		
  end if;
 end if;
end process;

-- game20k: Namco 06XX and 51XX, see namco_io.vhd. The 54XX sits on chip select 3 and gives
-- nothing back.
namco : entity work.namco_io
port map(
 clk         => clock_18,
 reset       => reset,
 mcu_reset_n => reset_cpu_n,
 mcu_ena     => cs51xx_ena,
 cpu_we      => io_we,
 cpu_sel     => mux_addr(8),
 cpu_di      => mux_cpu_do,
 cpu_do      => cs06XX_do,
 nmi         => n06_nmi,
 cs          => n06_cs,
 dev_we      => n06_we,
 dev_data    => n06_wdata,
 dev_do      => X"FF",
 in_r        => cs51xx_in,
 vblank      => cs51xx_vblank,
 rom_addr    => cs51xx_rom_addr,
 rom_data    => cs51xx_rom_do,
 p_out       => open           -- coin counters and lamps, not used
);

cpu1_nmi_n   <= not n06_nmi;
cs54xx_irq_n <= not n06_cs(3);

-- game20k: inputs of the 51XX as on the board (MAME galaga.cpp IN0, IN1), active low.
-- R0/R1: joysticks of player 1 and 2, R2: fire and start, R3: coin 1. Coin 2, service
-- and test stay off.
cs51xx_in <= "111" & (not coin) &
             (not start2) & (not start1) & (not fire2) & (not fire1) &
             (not left2) & '1' & (not right2) & '1' &
             (not left1) & '1' & (not right1) & '1';
-- the 51XX timer counts vertical blanks, from line 240 where the CPUs get their IRQ
cs51xx_vblank <= '1' when vcnt >= 240 or vcnt < 16 else '0';

process (clock_18, nmion_n)
begin
 if nmion_n = '1' then
 elsif rising_edge(clock_18) and ena_vidgen = '1' then
		if hcnt = "100000000" then
			if vcnt = "001000000" or vcnt = "011000000" then cpu3_nmi_n <= '0'; end if;
			if vcnt = "001000001" or vcnt = "011000001" then cpu3_nmi_n <= '1'; end if;
		end if;
 end if;
end process;

with cpu1_addr(15 downto 11) select
cpu1_di <= 	cpu1_rom_do when "00000",
						cpu1_rom_do when "00001",
						cpu1_rom_do when "00010",
						cpu1_rom_do when "00011",
						cpu1_rom_do when "00100",
						cpu1_rom_do when "00101",
						cpu1_rom_do when "00110",
 						cpu1_rom_do when "00111",
						"000000" & dip_switch_do when "01101",
						cs06XX_do   when "01110",
						bgram_do    when "10000",
						wram1_do    when "10001",
						wram2_do    when "10010",
						wram3_do    when "10011",
						X"00"       when others;

with cpu2_addr(15 downto 11) select
cpu2_di <= 	cpu2_rom_do when "00000",
						cpu2_rom_do when "00001",
						"000000" & dip_switch_do when "01101",
						cs06XX_do   when "01110",
						bgram_do    when "10000",
						wram1_do    when "10001",
						wram2_do    when "10010",
						wram3_do    when "10011",
						X"00"       when others;

with cpu3_addr(15 downto 11) select
cpu3_di <= 	cpu3_rom_do when "00000",
						cpu3_rom_do when "00001",
						"000000" & dip_switch_do when "01101",
						cs06XX_do   when "01110",
						bgram_do    when "10000",
						wram1_do    when "10001",
						wram2_do    when "10010",
						wram3_do    when "10011",
						X"00"       when others;

-- video address/sync generator
gen_video : entity work.gen_video
port map(
clk     => clock_18,
reset   => video_reset,
enable  => ena_vidgen,
hcnt    => hcnt,
vcnt    => vcnt,
hsync   => video_hs,
vsync   => video_vs,
csync   => video_csync,
blankn  => video_blankn
);

-- microprocessor Z80 - 1
cpu1 : entity work.T80se
generic map(Mode => 0, T2Write => 1, IOWait => 1)
port map(
  RESET_n => reset_n,
  CLK_n   => clock_18,
	CLKEN   => cpu1_ena,
  WAIT_n  => '1',
  INT_n   => cpu1_irq_n,
  NMI_n   => cpu1_nmi_n,
  BUSRQ_n => '1',
  M1_n    => cpu1_m1_n,
  MREQ_n  => cpu1_mreq_n,
  IORQ_n  => open,
  RD_n    => open,
  WR_n    => cpu1_wr_n,
  RFSH_n  => open,
  HALT_n  => open,
  BUSAK_n => open,
  A       => cpu1_addr,
  DI      => cpu1_di,
  DO      => cpu1_do
);

-- microprocessor Z80 - 2
cpu2 : entity work.T80se
generic map(Mode => 0, T2Write => 1, IOWait => 1)
port map(
--  RESET_n => reset_n,
  RESET_n => reset_cpu_n,
  CLK_n   => clock_18,
	CLKEN   => cpu2_ena,
  WAIT_n  => '1',
  INT_n   => cpu2_irq_n,
  NMI_n   => '1', --cpu_int_n,
  BUSRQ_n => '1',
  M1_n    => cpu2_m1_n,
  MREQ_n  => cpu2_mreq_n,
  IORQ_n  => open,
  RD_n    => open,
  WR_n    => cpu2_wr_n,
  RFSH_n  => open,
  HALT_n  => open,
  BUSAK_n => open,
  A       => cpu2_addr,
  DI      => cpu2_di,
  DO      => cpu2_do
);

-- microprocessor Z80 - 3
cpu3 : entity work.T80se
generic map(Mode => 0, T2Write => 1, IOWait => 1)
port map(
--  RESET_n => reset_n,
  RESET_n => reset_cpu_n,
  CLK_n   => clock_18,
	CLKEN   => cpu3_ena,
  WAIT_n  => '1',
  INT_n   => '1',
  NMI_n   => cpu3_nmi_n,
  BUSRQ_n => '1',
  M1_n    => cpu3_m1_n,
  MREQ_n  => cpu3_mreq_n,
  IORQ_n  => open,
  RD_n    => open,
  WR_n    => cpu3_wr_n,
  RFSH_n  => open,
  HALT_n  => open,
  BUSAK_n => open,
  A       => cpu3_addr,
  DI      => cpu3_di,
  DO      => cpu3_do
);

-- mb88 - cs54xx (28 pins IC, 1024 bytes rom)
mb88_54xx : entity work.mb88
port map(
 reset_n    => reset_cpu_n, --reset_n,
 clock      => clock_18,
 ena        => cs54xx_ena,

 r0_port_in  => cs54xx_cmd(3 downto 0), -- pin 12,13,15,16
 r1_port_in  => X"0",
 r2_port_in  => X"0",
 r3_port_in  => X"0",
 r0_port_out => open,
 r1_port_out => cs54xx_audio_3,   -- pin 17,18,19,20 (resistor divider )
 r2_port_out => open,
 r3_port_out => open,
 k_port_in   => cs54xx_cmd(7 downto 4), -- pin 24,25,26,27
 ol_port_out => cs54xx_audio_1,   -- pin  4, 5, 6, 7 (resistor divider 150K/22K)
 oh_port_out => cs54xx_audio_2,   -- pin  8, 9,10,11 (resistor divider  47K/10K)
 o_we        => open,
 p_port_out  => open,

 stby_n    => '0',
 tc_n      => '0',
 irq_n     => cs54xx_irq_n,
 sc_in_n   => '0',
 si_n      => '0',
 sc_out_n  => open,
 so_n      => open,
 to_n      => open,
 
 rom_addr  => cs54xx_rom_addr,
 rom_data  => cs54xx_rom_do
);

-- game20k: program ROMs of the 54XX (lower half) and the 51XX (upper half) in one block,
-- loaded as one section of 2048 bytes
cs5xxx_prog : entity work.g20k_promram2
generic map(aWidth => 10)
port map(
 clk     => clock_18n,
 addr_a  => cs54xx_rom_addr(9 downto 0),
 data_a  => cs54xx_rom_do,
 addr_b  => cs51xx_rom_addr,
 data_b  => cs51xx_rom_do,
 wr_clk  => rom_wr_clk,
 wr_addr => rom_wr_addr(10 downto 0),
 wr_data => rom_wr_data,
 wr_en   => rom_wr_en(5)
);

-- cpu1 program ROM
rom_cpu1 : entity work.g20k_promram
generic map(aWidth => 14)
port map(
 clk     => clock_18n,
 addr    => mux_addr(13 downto 0),
 data    => cpu1_rom_do,
 wr_clk  => rom_wr_clk,
 wr_addr => rom_wr_addr(13 downto 0),
 wr_data => rom_wr_data,
 wr_en   => rom_wr_en(0)
);

-- cpu2 program ROM
rom_cpu2 : entity work.g20k_promram
generic map(aWidth => 12)
port map(
 clk     => clock_18n,
 addr    => mux_addr(11 downto 0),
 data    => cpu2_rom_do,
 wr_clk  => rom_wr_clk,
 wr_addr => rom_wr_addr(11 downto 0),
 wr_data => rom_wr_data,
 wr_en   => rom_wr_en(1)
);

-- cpu3 program ROM
rom_cpu3 : entity work.g20k_promram
generic map(aWidth => 12)
port map(
 clk     => clock_18n,
 addr    => mux_addr(11 downto 0),
 data    => cpu3_rom_do,
 wr_clk  => rom_wr_clk,
 wr_addr => rom_wr_addr(11 downto 0),
 wr_data => rom_wr_data,
 wr_en   => rom_wr_en(2)
);
-- background graphics ROM
bg_graphics : entity work.g20k_promram
generic map(aWidth => 12)
port map(
 clk     => clock_18,   -- game20k: rising edge, one clock read latency, see hcnt_bg_d
 addr    => bggraphx_addr(11 downto 0),
 data    => bggraphx_do,
 wr_clk  => rom_wr_clk,
 wr_addr => rom_wr_addr(11 downto 0),
 wr_data => rom_wr_data,
 wr_en   => rom_wr_en(3)
);

-- background palette ROM
bg_palette : entity work.g20k_promram
generic map(aWidth => 8)
port map(
 clk     => clock_18,
 addr    => bgpalette_addr,
 data    => bgpalette_do,
 wr_clk  => rom_wr_clk,
 wr_addr => rom_wr_addr(7 downto 0),
 wr_data => rom_wr_data,
 wr_en   => rom_wr_en(6)
);

-- background char RAM   0x8000-0x87FF
bgram : entity work.g20k_lutram   -- game20k: distributed LUT RAM, asynchronous read
generic map( dWidth => 8, aWidth => 11)
port map(
 clk  => clock_18n,
 we   => bgram_we,
 addr => mux_addr(10 downto 0),
 d    => mux_cpu_do,
 q    => bgram_do
);
-- working/sprite register RAM1   0x8800-0x8BFF / 0x8C00-0x8FFF
wram1_d <= cap_w1 when harv_wr = '1' else nz_out(7 downto 0) when nz_wr = '1' else mux_cpu_do;
wram1 : entity work.g20k_spram
generic map( dWidth => 8, aWidth => 11)
port map(
 clk  => clock_18n,
 we   => wram1_we,
 addr => wram_addr,
 d    => wram1_d,
 q    => wram1_do
);
-- working/sprite register RAM2   0x9000-0x93FF / 0x9400-0x97FF
wram2_d <= cap_w2 when harv_wr = '1' else nz_out(7 downto 0) when nz_wr = '1' else mux_cpu_do;
wram2 : entity work.g20k_spram
generic map( dWidth => 8, aWidth => 11)
port map(
 clk  => clock_18n,
 we   => wram2_we,
 addr => wram_addr,
 d    => wram2_d,
 q    => wram2_do
);
-- working/sprite register RAM3   0x9800-0x9BFF / 0x9C00-0x9FFF
wram3_d <= cap_w3 when harv_wr = '1' else nz_out(7 downto 0) when nz_wr = '1' else mux_cpu_do;
wram3 : entity work.g20k_spram
generic map( dWidth => 8, aWidth => 11)
port map(
 clk  => clock_18n,
 we   => wram3_we,
 addr => wram_addr,
 d    => wram3_d,
 q    => wram3_do
);

-- sprite RAM1
spram1 : entity work.g20k_spram
generic map( dWidth => 4, aWidth => 9)
port map(
 clk  => clock_18,
 we   => spram1_we,
 addr => spram1_addr,
 d    => spram1_di,
 q    => spram1_do
);

-- sprite RAM2
spram2 : entity work.g20k_spram
generic map( dWidth => 4, aWidth => 9)
port map(
 clk  => clock_18,
 we   => spram2_we,
 addr => spram2_addr,
 d    => spram2_di,
 q    => spram2_do
);

-- sprite graphics ROM
sp_graphics : entity work.g20k_promram
generic map(aWidth => 13)
port map(
 clk     => clock_18n,
 addr    => spgraphx_addr,
 data    => spgraphx_do,
 wr_clk  => rom_wr_clk,
 wr_addr => rom_wr_addr(12 downto 0),
 wr_data => rom_wr_data,
 wr_en   => rom_wr_en(4)
);

-- sprite palette ROM
sp_palette : entity work.g20k_promram
generic map(aWidth => 8)
port map(
 clk     => clock_18,
 addr    => sppalette_addr,
 data    => sppalette_do,
 wr_clk  => rom_wr_clk,
 wr_addr => rom_wr_addr(7 downto 0),
 wr_data => rom_wr_data,
 wr_en   => rom_wr_en(7)
);

-- RGB palette ROM
rgb_palette : entity work.g20k_promram
generic map(aWidth => 5)
port map(
 clk     => clock_18,
 addr    => rgb_palette_addr,
 data    => rgb_palette_do,
 wr_clk  => rom_wr_clk,
 wr_addr => rom_wr_addr(4 downto 0),
 wr_data => rom_wr_data,
 wr_en   => rom_wr_en(10)
);

end struct;
