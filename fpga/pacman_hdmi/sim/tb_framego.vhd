-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file tb_framego.vhd
--! @brief Where the core's mirror tap lies: clocks from mir_frame_go to the rise of O_VBLANK.
--!
--! The mirror's window must end at the interrupt edge, which comes in the same P0 cycle as
--! the rise of vblank (pacman.vhd, p_sync and p_irq_req_watchdog). Its harvest runs 3089
--! rounds for Pac-Man and 4112 for Jr. Pac-Man (mod_jr), one round per pixel of three
--! clocks, so the tap must lie 3 x rounds clocks before that cycle; O_VBLANK shows the rise
--! one clock later. The generic JR picks the mode. Ends with PASS or a severity failure.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_framego is
  generic (JR : boolean := false);
end entity tb_framego;

architecture sim of tb_framego is
  constant T : time := 53.872 ns;   -- 18.5625 MHz
  function rounds return natural is
  begin
    if JR then return 4112; else return 3089; end if;
  end function;
  function to_sl(b : boolean) return std_logic is
  begin
    if b then return '1'; else return '0'; end if;
  end function;

  signal clk, rst : std_logic := '1';
  signal ena_6    : std_logic := '0';
  signal ph       : natural range 0 to 2 := 0;
  signal o_vb, frame_go : std_logic;
  signal hs_address  : std_logic_vector(11 downto 0) := (others => '0');
  signal hs_data_out : std_logic_vector(7 downto 0);
  signal done : boolean := false;
begin
  clk <= not clk after T / 2 when not done;
  p_ph : process (clk)
  begin
    if rising_edge(clk) then
      if ph = 2 then ph <= 0; else ph <= ph + 1; end if;
    end if;
  end process;
  ena_6 <= '1' when ph = 0 else '0';

  u_core : entity work.PACMAN
    port map (
      O_VIDEO_R => open, O_VIDEO_G => open, O_VIDEO_B => open,
      O_HSYNC => open, O_VSYNC => open, O_HBLANK => open, O_VBLANK => o_vb,
      O_AUDIO => open,
      in0 => x"FF", in1 => x"FF", dipsw1 => x"C9", dipsw2 => x"FF",
      mod_plus => '0', mod_jmpst => '0', mod_bird => '0', mod_mrtnt => '0', mod_ms => '0',
      mod_woodp => '0', mod_eeek => '0', mod_glob => '0', mod_alib => '0', mod_ponp => '0',
      mod_van => '0', mod_dshop => '0', mod_club => '0', mod_jr => to_sl(JR),
      flip_screen => '0', h_offset => "000", v_offset => "000",
      dn_addr => x"0000", dn_data => x"00", dn_wr => '0',
      pause => '0',
      hs_address => hs_address, hs_data_in => x"00", hs_data_out => hs_data_out,
      hs_write_enable => '0', hs_access_read => '0', hs_access_write => '0',
      mir_sxy_addr => "0000", mir_sxy_data => open, mir_flip => open,
      mir_we_ram => open, mir_we_sxy => open, mir_we_flip => open,
      mir_wr_addr => open, mir_wr_data => open, mir_frame_go => frame_go,
      RESET => rst, CLK => clk, ENA_6 => ena_6, ENA_4 => '0', ENA_1M79 => '0');

  p_measure : process
    variable n, taps : natural := 0;
    variable vb_d : std_logic := '1';
    variable counting : boolean := false;
  begin
    rst <= '1';
    for i in 1 to 30 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    -- three frames: every tap must be followed by the vblank rise at the same distance
    while taps < 3 loop
      wait until rising_edge(clk);
      if counting then n := n + 1; end if;
      if frame_go = '1' then
        assert not counting report "a second tap before the vblank rise" severity failure;
        counting := true;
        n := 0;
      end if;
      if o_vb = '1' and vb_d = '0' and counting then
        report "tap to vblank rise: " & integer'image(n) & " clocks, expected " & integer'image(3 * rounds + 1);
        assert n = 3 * rounds + 1 report "the tap is not " & integer'image(rounds) & " pixels before the interrupt" severity failure;
        counting := false;
        taps := taps + 1;
      end if;
      vb_d := o_vb;
    end loop;
    report "PASS";
    done <= true;
    wait;
  end process;
end architecture sim;
