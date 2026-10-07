-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file tb_namco_io.vhd
--! @brief Replays the main CPU's 06XX accesses from a MAME run against namco_io.vhd.
--!
--! The bus log (MAME tap script) has one event per line, times in microseconds since power on:
--!   <t> W <addr> <data>   main CPU writes 0x7000 (data) or 0x7100 (control)
--!   <t> R <addr> <data>   main CPU reads, data is what MAME returned
--!   <t> L <addr> <data>   write to the misc latch, 0x6823 bit 0 is the reset of the customs
--!   <t> I <name> <0|1>    an input changes
--! The bench applies writes, resets and inputs at their time, makes every read at its time
--! and compares the result with MAME's. The vertical blank follows MAME's Galaga screen:
--! 16.5 ms per frame, MAME's frame ends where the blank begins, 40 of 264 lines long. Ends
--! with the number of reads and of differences, the first differences are listed.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_namco_io is
  generic (
    BUSLOG : string := "bus.log";
    ROMHEX : string := "rom51.hex";
    SHOW   : natural := 20;            --! differences to list
    SHIFT_US : natural := 0            --! data accesses (0x7000) come this much later than in MAME
  );
end entity tb_namco_io;

architecture sim of tb_namco_io is
  constant T : time := 54.253 ns;      -- 18.432 MHz
  type rom_t is array (0 to 1023) of std_logic_vector(7 downto 0);

  impure function load_rom return rom_t is
    file f     : text open read_mode is ROMHEX;
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
  constant ROM : rom_t := load_rom;

  signal clk      : std_logic := '0';
  signal mcu_rst  : std_logic := '0';
  signal mcu_ena  : std_logic := '0';
  signal cpu_we   : std_logic := '0';
  signal cpu_sel  : std_logic := '0';
  signal cpu_di   : std_logic_vector(7 downto 0) := x"00";
  signal cpu_do   : std_logic_vector(7 downto 0);
  signal in_r     : std_logic_vector(15 downto 0) := x"FFFF";
  signal vblank   : std_logic := '0';
  signal rom_addr : std_logic_vector(9 downto 0);
  signal rom_data : std_logic_vector(7 downto 0) := x"00";
  signal done     : boolean := false;
begin
  clk <= not clk after T / 2 when not done;

  dut : entity work.namco_io
    port map (
      clk => clk, reset => '0', mcu_reset_n => mcu_rst, mcu_ena => mcu_ena,
      cpu_we => cpu_we, cpu_sel => cpu_sel, cpu_di => cpu_di, cpu_do => cpu_do, nmi => open,
      cs => open, dev_we => open, dev_data => open, dev_do => x"FF",
      in_r => in_r, vblank => vblank, rom_addr => rom_addr, rom_data => rom_data,
      p_out => open);

  rom_data <= ROM(to_integer(unsigned(rom_addr))) when falling_edge(clk);

  -- one 51XX instruction cycle every 72 clocks, as in galaga.vhd
  p_ena : process (clk)
    variable n : natural := 0;
  begin
    if rising_edge(clk) then
      mcu_ena <= '0';
      if n = 71 then n := 0; mcu_ena <= '1'; else n := n + 1; end if;
    end if;
  end process p_ena;

  -- MAME's screen: 16.5 ms per frame, the vertical blank begins at the end of each frame
  p_vbl : process
  begin
    loop
      wait for 14 ms;
      vblank <= '0';
      wait for 2.5 ms;
      vblank <= '1';
    end loop;
  end process p_vbl;

  p_main : process
    file f : text open read_mode is BUSLOG;
    variable l : line;
    variable t_us : natural;
    variable kind : character;
    variable c : character;
    variable word : string(1 to 20);
    variable wl : natural;
    variable a16 : std_logic_vector(15 downto 0);
    variable d8 : std_logic_vector(7 downto 0);
    variable v : natural;
    variable reads, diffs : natural := 0;
    variable bit_no : integer;

    procedure read_word is
    begin
      word := (others => ' ');
      wl := 0;
      while l'length > 0 and l(l'left) = ' ' loop read(l, c); end loop;
      while l'length > 0 and l(l'left) /= ' ' loop
        read(l, c);
        wl := wl + 1;
        word(wl) := c;
      end loop;
    end procedure;
  begin
    while not endfile(f) loop
      readline(f, l);
      read(l, t_us);
      read(l, c);       -- blank
      read(l, kind);
      -- the NMI handler moves the data, the control register starts the 06XX clock: only the
      -- data accesses move against the chip selects (address 0x7000..0x70FF, 4 hex digits)
      if (kind = 'W' or kind = 'R') and l(l'left + 2) = '0' then t_us := t_us + SHIFT_US; end if;
      if t_us * 1 us > now then
        wait for t_us * 1 us - now;
      end if;
      case kind is
        when 'W' =>
          hread(l, a16);
          hread(l, d8);
          wait until rising_edge(clk);
          cpu_sel <= a16(8);
          cpu_di  <= d8;
          cpu_we  <= '1';
          wait until rising_edge(clk);
          cpu_we  <= '0';
        when 'R' =>
          hread(l, a16);
          hread(l, d8);
          cpu_sel <= a16(8);
          wait until rising_edge(clk);
          reads := reads + 1;
          if cpu_do /= d8 then
            diffs := diffs + 1;
            if diffs <= SHOW then
              report integer'image(t_us) & " us: read " & to_hstring(a16) & " gives " &
                     to_hstring(cpu_do) & ", MAME " & to_hstring(d8) severity warning;
            end if;
          end if;
        when 'L' =>
          hread(l, a16);
          hread(l, d8);
          if a16 = x"6823" then
            mcu_rst <= d8(0);
          end if;
        when 'I' =>
          read_word;
          read(l, v);
          bit_no := -1;
          if    word(1 to wl) = "P1_Left"        then bit_no := 3;
          elsif word(1 to wl) = "P1_Right"       then bit_no := 1;
          elsif word(1 to wl) = "P1_Button_1"    then bit_no := 8;
          elsif word(1 to wl) = "1_Player_Start" then bit_no := 10;
          elsif word(1 to wl) = "Coin_1"         then bit_no := 12;
          else
            report "unknown input " & word(1 to wl) severity failure;
          end if;
          in_r(bit_no) <= '0' when v = 1 else '1';
        when others =>
          report "unknown event " & kind severity failure;
      end case;
    end loop;
    report "reads " & integer'image(reads) & ", differences " & integer'image(diffs) severity note;
    done <= true;
    wait;
  end process p_main;
end architecture sim;
