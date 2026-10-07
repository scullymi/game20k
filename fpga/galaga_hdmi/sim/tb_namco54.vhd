-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file tb_namco54.vhd
--! @brief Replays a MAME bus log against namco_io.vhd with the 54XX on chip select 3, and
--! lists every nibble the 54XX reads with inK or inR.
--!
--! Same bus log as tb_namco_io.vhd. The 54XX gets its command byte and its IRQ as in
--! galaga.vhd. Each read is reported as "54XX <op> <nibble> at <us>", to compare with the
--! values MAME's 54XX read (mame2steps.py, step file column inval). CLK54 sets the clocks per
--! 54XX instruction cycle (72 on the board, 18.432 MHz / 12 / 6).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_namco54 is
  generic (
    BUSLOG : string := "bus.log";
    ROM51  : string := "rom51.hex";
    ROM54  : string := "rom54.hex";
    CLK54  : natural := 72;
    FROM_US : natural := 0;             --! events before this time are skipped
    SHIFT_US : natural := 0             --! data writes (0x7000) come this much later than in MAME
  );
end entity tb_namco54;

architecture sim of tb_namco54 is
  constant T : time := 54.253 ns;
  type rom_t is array (0 to 1023) of std_logic_vector(7 downto 0);

  impure function load_rom(name : string) return rom_t is
    file f     : text open read_mode is name;
    variable l : line;
    variable r : rom_t := (others => (others => '0'));
  begin
    for i in rom_t'range loop
      exit when endfile(f);
      readline(f, l);
      hread(l, r(i));
    end loop;
    return r;
  end function;
  constant R51 : rom_t := load_rom(ROM51);
  constant R54 : rom_t := load_rom(ROM54);

  signal clk      : std_logic := '0';
  signal mcu_rst  : std_logic := '0';
  signal ena51    : std_logic := '0';
  signal ena54    : std_logic := '0';
  signal cpu_we   : std_logic := '0';
  signal cpu_sel  : std_logic := '0';
  signal cpu_di   : std_logic_vector(7 downto 0) := x"00";
  signal vblank   : std_logic := '0';
  signal cs       : std_logic_vector(3 downto 1);
  signal dev_we   : std_logic_vector(3 downto 1);
  signal dev_data : std_logic_vector(7 downto 0);
  signal cmd      : std_logic_vector(7 downto 0) := x"00";
  signal irq54_n  : std_logic;
  signal a51, a54 : std_logic_vector(10 downto 0);
  signal d51, d54 : std_logic_vector(7 downto 0) := x"00";
  signal done     : boolean := false;
begin
  clk <= not clk after T / 2 when not done;

  io : entity work.namco_io
    port map (
      clk => clk, reset => '0', mcu_reset_n => mcu_rst, mcu_ena => ena51,
      cpu_we => cpu_we, cpu_sel => cpu_sel, cpu_di => cpu_di, cpu_do => open, nmi => open,
      cs => cs, dev_we => dev_we, dev_data => dev_data, dev_do => x"FF",
      in_r => x"FFFF", vblank => vblank, rom_addr => a51(9 downto 0), rom_data => d51,
      p_out => open);
  a51(10) <= '0';

  -- as galaga.vhd: the command latch on the falling edge, IRQ from chip select 3
  cmd     <= dev_data when falling_edge(clk) and dev_we(3) = '1';
  irq54_n <= not cs(3);

  mcu54 : entity work.mb88
    port map (
      reset_n => mcu_rst, clock => clk, ena => ena54,
      r0_port_in => cmd(3 downto 0), r1_port_in => x"0", r2_port_in => x"0", r3_port_in => x"0",
      r0_port_out => open, r1_port_out => open, r2_port_out => open, r3_port_out => open,
      k_port_in => cmd(7 downto 4), ol_port_out => open, oh_port_out => open, o_we => open,
      p_port_out => open, stby_n => '0', tc_n => '0', irq_n => irq54_n, sc_in_n => '0',
      si_n => '0', sc_out_n => open, so_n => open, to_n => open,
      rom_addr => a54, rom_data => d54);

  d51 <= R51(to_integer(unsigned(a51(9 downto 0)))) when falling_edge(clk);
  d54 <= R54(to_integer(unsigned(a54(9 downto 0)))) when falling_edge(clk);

  p_ena : process (clk)
    variable n51, n54 : natural := 0;
  begin
    if rising_edge(clk) then
      ena51 <= '0';
      ena54 <= '0';
      if n51 = 71 then n51 := 0; ena51 <= '1'; else n51 := n51 + 1; end if;
      if n54 = CLK54 - 1 then n54 := 0; ena54 <= '1'; else n54 := n54 + 1; end if;
    end if;
  end process p_ena;

  p_vbl : process
  begin
    loop
      wait for 14 ms;
      vblank <= '0';
      wait for 2.5 ms;
      vblank <= '1';
    end loop;
  end process p_vbl;

  -- every inK / inR the 54XX executes, with the nibble it reads
  p_mon : process (clk)
    alias s_op  is << signal .tb_namco54.mcu54.rom_data       : std_logic_vector(7 downto 0) >>;
    alias s_sbo is << signal .tb_namco54.mcu54.single_byte_op : std_logic >>;
    alias s_brn is << signal .tb_namco54.mcu54.burn           : std_logic_vector(1 downto 0) >>;
    alias s_pnd is << signal .tb_namco54.mcu54.pend_ext       : std_logic >>;
    alias s_y   is << signal .tb_namco54.mcu54.r_y            : std_logic_vector(3 downto 0) >>;
    variable l : line;
  begin
    if rising_edge(clk) and ena54 = '1' and s_sbo = '1' and s_brn = "00" then
      if s_op = x"12" then
        write(l, string'("54XX K "));
        write(l, to_hstring(cmd(7 downto 4)));
        write(l, string'(" at "));
        write(l, now / 1 us);
        writeline(output, l);
      elsif s_op = x"13" then
        write(l, string'("54XX R" & integer'image(to_integer(unsigned(s_y)))) & " ");
        write(l, to_hstring(cmd(3 downto 0)));
        write(l, string'(" at "));
        write(l, now / 1 us);
        writeline(output, l);
      end if;
    end if;
  end process p_mon;

  p_main : process
    file f : text open read_mode is BUSLOG;
    variable l : line;
    variable t_us : natural;
    variable kind, c : character;
    variable a16 : std_logic_vector(15 downto 0);
    variable d8 : std_logic_vector(7 downto 0);
  begin
    while not endfile(f) loop
      readline(f, l);
      read(l, t_us);
      read(l, c);
      read(l, kind);
      next when t_us < FROM_US or kind = 'R' or kind = 'I';
      hread(l, a16);
      hread(l, d8);
      -- the NMI handler writes the data, the control register starts the 06XX clock: only
      -- the data moves against the chip selects
      if kind = 'W' and a16(8) = '0' then t_us := t_us + SHIFT_US; end if;
      if t_us * 1 us > now then
        wait for t_us * 1 us - now;
      end if;
      if kind = 'W' then
        wait until rising_edge(clk);
        cpu_sel <= a16(8);
        cpu_di  <= d8;
        cpu_we  <= '1';
        wait until rising_edge(clk);
        cpu_we  <= '0';
      elsif kind = 'L' and a16 = x"6823" then
        mcu_rst <= d8(0);
      end if;
    end loop;
    done <= true;
    wait;
  end process p_main;
end architecture sim;
