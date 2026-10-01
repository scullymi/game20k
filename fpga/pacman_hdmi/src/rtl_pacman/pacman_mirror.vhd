-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file pacman_mirror.vhd
--! @brief The RAM mirror of Pac-Man for RetroAchievements: harvest, catch-up and delivery.
--!
--! Once per frame the mirror copies everything FBNeo's "All Ram" block holds for Pac-Man out
--! of the core into a shadow RAM, and on request streams that shadow to the platform in
--! FBNeo's order: work RAM, sprite x/y, colour RAM, video RAM and the flip bit, with zeros
--! in the gaps, 6272 bytes (MIRROR_DATA of the manifest, 6165 of them data). The shadow uses
--! the core's own RAM index as its address, so harvest and catch-up need no arithmetic:
--!   0x000-0x3FF video RAM, 0x400-0x7FF colour RAM, 0x800-0x80F sprite x/y, 0x810 flip,
--!   0xC00-0xFFF work RAM; 0x811-0xBFF unused (never written, never read).
--! Only the delivery translates, with a second pointer loaded at every region boundary.
--!
--! Phases. The core steps on ena_6, one clock in three. P0 is the cycle in which ena_6 is 1:
--! every core register keyed to ENA_6 (u_rams port A, control_reg, the sprite x/y RAMs)
--! updates at the edge that ends it. P1 and P2 are the two cycles after it. A round of the
--! harvest takes one P1/P2/P0 triple per byte: the read address is stable in P1 and the
--! core's read ports (u_rams port B, the sprite shadow's port B, both without enable) take
--! it at the P1 edge, the shadow is written in P2, and P0 belongs to the game. The harvest
--! therefore reads the core RAM only at P1 edges and the game writes it only at P0 edges, so
--! the undefined same-clock read of g20k_dpram never happens.
--!
--! Catch-up without a queue: every mirrored game write inside the window is copied to the
--! shadow at the next P1 edge, whether its index was harvested already or not. If not yet,
--! the harvest reads the new value later and agrees; if already, the copy lands after the
--! harvest write and wins. Catch-up (P1 edges) and harvest (P2 edges) never write the shadow
--! in the same clock. After the window the shadow holds the value of every mirrored byte at
--! the end of the window, which is what the Pico's oracle demands: the last logged value per
--! address.
--!
--! Window: frame_go is the core's tap for the P0 cycle with hcnt 0x09E and vcnt 0x1E7, 3089
--! pixels before the P0 cycle in which the core asserts the Z80 interrupt and raises vblank
--! (17 pixels to hcnt 0x0AF, then 8 lines of 384). The harvest starts at the P1 edge after
--! it, idles for P2 and P0, then runs 3089 rounds of which the last has no P0: 2 + 3 x 3089 -
--! 1 = 9268 clocks, ending at the P2 edge two clocks after the interrupt edge. A write in the
--! interrupt's own P0 cycle is still logged and caught up; the handler's first write comes 66
--! clocks later at the earliest and lies outside. The snapshot is therefore the state at the
--! frame boundary before the interrupt handler runs, the instant FBNeo shows to
--! RetroAchievements. A frame_go during a transfer, in reset, or during a running harvest is
--! skipped: frame_no unchanged is the observable.
--!
--! Dedupe: T80sed holds WR low for two T states of two pixel clocks each, so each Z80 write
--! asserts the raw strobes in the two consecutive P0 cycles of one CPU slot (hcnt 00 and 01),
--! and T1 of the next M cycle is strobe-free. The seen flag (the strobe of the previous P0)
--! turns that into one pulse per write, whichever slot cycle is the first with a strobe. The
--! T80 sets A at the end of the previous M cycle and DO at the end of T1, both before the
--! first strobe cycle, so either strobe cycle may be logged: both carry the same address and
--! data. A write to the core-only RAM 0x800-0xBFF (absent on the board and in FBNeo) is
--! never logged, never caught up and never harvested; its FBNeo position is delivered as
--! zeros.
--!
--! Delivery, against the platform contract of game20k_top.sv: snap_run rises at the verdict
--! byte, the top resets its FIFO at the end of the second snap_run cycle with priority over a
--! push, a push counts only with snap_full = 0 in the same clock, and everything is dropped
--! when snap_run falls. Here: rise in cycle 2, first read in cycle 3, first push in cycle 4,
--! one byte per clock while the FIFO has room, a combinational stall on snap_full, and no
--! delivery while a harvest runs (dl_go). The catch-up never writes the shadow while the
--! delivery reads it: cu_we exists only inside the window, dl_go needs harv_run = 0.
--!
--! Log bound: 9268 clocks are 1545 T states, the fastest Z80 write sequence is PUSH (11 T
--! for 2 bytes), so at most 281 entries per window against the platform's 512.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pacman_mirror is
  port (
    clk        : in  std_logic;                       --! clk_core, 18.5625 MHz
    ena_6      : in  std_logic;                       --! the core's pixel enable, high in P0
    reset      : in  std_logic;                       --! blocks harvest starts only
    frame_go   : in  std_logic;                       --! mir_frame_go of the core, one P0 per frame
    --! read side: the core's free read ports, one clock of latency, no enable
    ram_addr   : out std_logic_vector(11 downto 0);   --! hs_address (u_rams port B)
    ram_q      : in  std_logic_vector(7 downto 0);    --! hs_data_out
    sxy_addr   : out std_logic_vector(3 downto 0);    --! mir_sxy_addr (sprite x/y shadow port B)
    sxy_q      : in  std_logic_vector(7 downto 0);    --! mir_sxy_data
    flip       : in  std_logic;                       --! mir_flip = control_reg(3), live
    --! write side: the raw strobes, high only in P0 cycles
    we_ram     : in  std_logic;                       --! main RAM write, index wr_addr
    we_sxy     : in  std_logic;                       --! sprite x/y write, index wr_addr(3:0)
    we_flip    : in  std_logic;                       --! latch bit 3 write, value wr_data(0)
    wr_addr    : in  std_logic_vector(11 downto 0);   --! ab(11 downto 0) in the CPU slot
    wr_data    : in  std_logic_vector(7 downto 0);    --! cpu_data_out
    --! platform: the snapshot stream and the oracle
    snap_run   : in  std_logic;
    snap_full  : in  std_logic;
    snap_push  : out std_logic;
    snap_byte  : out std_logic_vector(7 downto 0);
    snap_frame : out std_logic_vector(15 downto 0);
    snap_harv  : out std_logic;
    log_we     : out std_logic;
    log_addr   : out std_logic_vector(15 downto 0);
    log_data   : out std_logic_vector(7 downto 0)
  );
end entity pacman_mirror;

architecture rtl of pacman_mirror is
  constant MIRROR_BYTES : natural := 6272;   --! pushes per transfer, MIRROR_DATA of the manifest

  -- phase: ena_6 delayed by one and two clocks, frame_go delayed by one
  signal p1, p2, go_d : std_logic := '0';

  -- game write decode
  signal seen     : std_logic := '0';              -- a strobe was high in the previous P0
  signal gw_raw, gw_ok, gw_pulse : std_logic;
  signal gw_sidx  : std_logic_vector(11 downto 0); -- shadow index of the write
  signal gw_data  : std_logic_vector(7 downto 0);
  signal gw_flat  : unsigned(12 downto 0);         -- its FBNeo position
  signal wr_lo    : unsigned(9 downto 0);
  signal wr_sx    : unsigned(3 downto 0);

  -- harvest
  signal harv_run, hw_we, harv_last : std_logic := '0';
  signal hidx, hidx_d : unsigned(11 downto 0) := (others => '0');
  signal frame_no : unsigned(15 downto 0) := (others => '0');

  -- catch-up capture
  signal cu_we   : std_logic := '0';
  signal cu_addr : std_logic_vector(11 downto 0) := (others => '0');
  signal cu_data : std_logic_vector(7 downto 0) := (others => '0');

  -- shadow port A (harvest and catch-up, by phase) and port B (delivery)
  signal sh_we   : std_logic;
  signal sh_addr : std_logic_vector(11 downto 0);
  signal sh_din, sh_q : std_logic_vector(7 downto 0);

  -- delivery
  signal run_s : std_logic_vector(1 downto 0) := "00";
  signal rise, dl_go : std_logic;
  signal dl_busy, dl_pend, dl_zero : std_logic := '0';
  signal dl_f  : unsigned(12 downto 0) := (others => '0');   -- FBNeo position of the next read
  signal dl_sp : unsigned(11 downto 0) := (others => '0');   -- its shadow address

  --! FBNeo positions that carry data: work RAM 0x0400-0x07FF, sprite x/y, colour and video
  --! RAM 0x1000-0x180F, flip 0x1814. Everything else is delivered as zeros.
  function populated(f : unsigned(12 downto 0)) return boolean is
  begin
    return f(12 downto 10) = "001" or (f >= 16#1000# and f <= 16#180F#) or f = 16#1814#;
  end function;
begin

  -- ---------------- game write decode (concurrent, from the raw taps) ----------------
  wr_lo <= unsigned(wr_addr(9 downto 0));
  wr_sx <= unsigned(wr_addr(3 downto 0));
  gw_raw <= we_ram or we_sxy or we_flip;
  -- a RAM write to index 0x800-0xBFF is core-only and stays out
  gw_ok  <= '0' when we_ram = '1' and wr_addr(11 downto 10) = "10" else gw_raw;
  gw_pulse <= gw_ok and not seen;
  gw_sidx <= wr_addr                    when we_ram = '1' else
             x"80" & wr_addr(3 downto 0) when we_sxy = '1' else
             x"810";
  gw_data <= wr_data when we_flip = '0' else "0000000" & wr_data(0);
  -- the FBNeo position of the write, the same constants as the region loads of dl_sp
  gw_flat <= "001" & wr_lo              when we_ram = '1' and wr_addr(11 downto 10) = "11" else  -- work   0x0400 + i
             ("100" & wr_lo) + 16       when we_ram = '1' and wr_addr(11 downto 10) = "01" else  -- colour 0x1010 + i
             ("101" & wr_lo) + 16       when we_ram = '1' and wr_addr(11 downto 10) = "00" else  -- video  0x1410 + i
             "1000000" & "00" & wr_sx   when we_sxy = '1' else                                    -- sprite 0x1000 + i
             to_unsigned(16#1814#, 13)  when we_flip = '1' else                                   -- flip
             (others => '0');

  -- ---------------- harvest and catch-up ----------------
  p_harvest : process (clk)
  begin
    if rising_edge(clk) then
      p1   <= ena_6;
      p2   <= p1;
      go_d <= frame_go;
      hw_we <= '0';

      -- the dedupe flag follows the strobes at P0 edges only
      if ena_6 = '1' then
        seen <= gw_raw;
      end if;

      -- catch-up capture at every edge: cu_we is 1 only in a P1 that follows a P0 with a
      -- mirrored game write inside the window, and port A takes it at that P1's edge
      cu_we   <= ena_6 and gw_pulse and harv_run;
      cu_addr <= gw_sidx;
      cu_data <= gw_data;

      if p1 = '1' then
        -- the edge ending P1: start, or one round's read
        if harv_run = '0' then
          if go_d = '1' and snap_run = '0' and reset = '0' then
            harv_run  <= '1';
            harv_last <= '0';
            hidx      <= (others => '0');
            frame_no  <= frame_no + 1;
          end if;
        else
          hidx_d <= hidx;
          hw_we  <= '1';
          if hidx = x"FFF" then
            harv_last <= '1';
          else
            harv_last <= '0';
          end if;
          -- 0x000..0x810, then 0xC00..0xFFF: 3089 rounds
          if hidx = x"810" then
            hidx <= x"C00";
          else
            hidx <= hidx + 1;
          end if;
        end if;
      elsif p2 = '1' then
        -- the edge ending P2: the shadow write of this round lands, the last round ends the window
        if hw_we = '1' and harv_last = '1' then
          harv_run <= '0';
        end if;
      end if;
    end if;
  end process;

  ram_addr <= std_logic_vector(hidx);
  sxy_addr <= std_logic_vector(hidx(3 downto 0));

  -- port A: the catch-up in P1, the harvest in P2; the two never meet in one clock
  sh_we   <= cu_we or hw_we;
  sh_addr <= cu_addr when cu_we = '1' else std_logic_vector(hidx_d);
  sh_din  <= cu_data            when cu_we = '1' else
             sxy_q              when hidx_d(11 downto 4) = x"80" else
             "0000000" & flip   when hidx_d = x"810" else
             ram_q;

  u_shadow : entity work.g20k_dpram
    generic map (AW => 12, DW => 8)
    port map (
      clk    => clk,
      a_we   => sh_we,
      a_addr => sh_addr,
      a_din  => sh_din,
      a_dout => open,
      b_ce   => dl_go,
      b_addr => std_logic_vector(dl_sp),
      b_dout => sh_q
    );

  -- ---------------- delivery ----------------
  rise  <= run_s(0) and not run_s(1);
  dl_go <= dl_busy and snap_run and not harv_run and not snap_full;

  p_deliver : process (clk)
  begin
    if rising_edge(clk) then
      run_s <= run_s(0) & snap_run;
      if rise = '1' then
        -- a new transfer: byte 0 first, the top resets its FIFO at this same edge
        dl_busy <= '1';
        dl_pend <= '0';
        dl_f    <= (others => '0');
        dl_sp   <= (others => '0');
      elsif snap_run = '0' then
        dl_busy <= '0';
        dl_pend <= '0';
      elsif dl_go = '1' then
        -- a go cycle reads byte dl_f and pushes byte dl_f - 1
        if dl_f = MIRROR_BYTES then
          dl_pend <= '0';
          dl_busy <= '0';
        else
          dl_pend <= '1';
          if populated(dl_f) then
            dl_zero <= '0';
          else
            dl_zero <= '1';
          end if;
          dl_f <= dl_f + 1;
          -- the shadow address of byte dl_f + 1: a region start, the next byte of the
          -- region, or don't care inside a zero region
          if    dl_f + 1 = 16#0400# then dl_sp <= x"C00";
          elsif dl_f + 1 = 16#1000# then dl_sp <= x"800";
          elsif dl_f + 1 = 16#1010# then dl_sp <= x"400";
          elsif dl_f + 1 = 16#1410# then dl_sp <= x"000";
          elsif dl_f + 1 = 16#1814# then dl_sp <= x"810";
          elsif populated(dl_f)     then dl_sp <= dl_sp + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  snap_push  <= dl_pend and dl_go;
  snap_byte  <= x"00" when dl_zero = '1' else sh_q;
  snap_frame <= std_logic_vector(frame_no);
  snap_harv  <= harv_run;

  -- ---------------- oracle ----------------
  -- game writes only, never the harvest or catch-up shadow writes; the platform gates the
  -- pulse with snap_harv, which is high in every P0 of the window
  log_we   <= gw_pulse;
  log_addr <= "000" & std_logic_vector(gw_flat);
  log_data <= gw_data;

end architecture rtl;
