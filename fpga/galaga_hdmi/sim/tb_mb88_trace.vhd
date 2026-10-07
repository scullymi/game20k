-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file tb_mb88_trace.vhd
--! @brief Runs mb88.vhd in lock step with a MAME trace of the same firmware.
--!
--! The step file (mame2steps.py) holds the state MAME had before each instruction and what
--! came from outside: the value an inK or inR read, the interrupt line level a tsti saw,
--! timer steps and interrupt entries. The bench feeds exactly these inputs at the matching
--! instruction and compares PC, A, X, Y, SI, PIO, TH and TL before every instruction. The
--! first difference stops the run with both states. ROM and step file come from the caller,
--! neither is part of the tree.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_mb88_trace is
  generic (
    STEPS     : string := "steps.txt";   --! step file from mame2steps.py
    ROMHEX    : string := "rom.hex";     --! the program ROM, one byte per line in hex
    DATA_6BIT : boolean := true          --! MB8843/MB8844
  );
end entity tb_mb88_trace;

architecture sim of tb_mb88_trace is
  type rom_t is array (0 to 2047) of std_logic_vector(7 downto 0);

  impure function load_rom return rom_t is
    file f     : text open read_mode is ROMHEX;
    variable l : line;
    variable v : std_logic_vector(7 downto 0);
    variable r : rom_t := (others => (others => '0'));
    variable i : natural := 0;
  begin
    while not endfile(f) and i <= rom_t'high loop
      readline(f, l);
      hread(l, v);
      r(i) := v;
      i    := i + 1;
    end loop;
    return r;
  end function;

  constant ROM : rom_t := load_rom;

  signal clk      : std_logic := '0';
  signal clk_n    : std_logic;
  signal reset_n  : std_logic := '0';
  signal ena      : std_logic := '0';
  signal irq_n    : std_logic := '1';
  signal tc_n     : std_logic := '0';
  signal k_in     : std_logic_vector(3 downto 0) := x"0";
  signal r0_in, r1_in, r2_in, r3_in : std_logic_vector(3 downto 0) := x"0";
  signal rom_addr : std_logic_vector(10 downto 0);
  signal rom_data : std_logic_vector(7 downto 0) := x"00";
  signal done     : boolean := false;
begin
  clk <= not clk after 5 ns when not done;

  dut : entity work.mb88
    generic map (data_6bit => DATA_6BIT)
    port map (
      clock => clk, ena => ena, reset_n => reset_n,
      r0_port_in => r0_in, r1_port_in => r1_in, r2_port_in => r2_in, r3_port_in => r3_in,
      r0_port_out => open, r1_port_out => open, r2_port_out => open, r3_port_out => open,
      k_port_in => k_in, ol_port_out => open, oh_port_out => open, o_we => open,
      p_port_out => open, stby_n => '0', tc_n => tc_n, irq_n => irq_n, sc_in_n => '0',
      si_n => '0', sc_out_n => open, so_n => open, to_n => open,
      rom_addr => rom_addr, rom_data => rom_data);

  -- the ROM registers on an inverted clock, as the cores do (clock_18n)
  clk_n    <= not clk;
  rom_data <= ROM(to_integer(unsigned(rom_addr))) when rising_edge(clk_n);

  p_run : process
    alias s_pc  is << signal .tb_mb88_trace.dut.r_pc  : std_logic_vector(5 downto 0) >>;
    alias s_pa  is << signal .tb_mb88_trace.dut.r_pa  : std_logic_vector(4 downto 0) >>;
    alias s_a   is << signal .tb_mb88_trace.dut.r_a   : std_logic_vector(3 downto 0) >>;
    alias s_x   is << signal .tb_mb88_trace.dut.r_x   : std_logic_vector(3 downto 0) >>;
    alias s_y   is << signal .tb_mb88_trace.dut.r_y   : std_logic_vector(3 downto 0) >>;
    alias s_si  is << signal .tb_mb88_trace.dut.r_si  : std_logic_vector(1 downto 0) >>;
    alias s_pio is << signal .tb_mb88_trace.dut.r_pio : std_logic_vector(7 downto 0) >>;
    alias s_th  is << signal .tb_mb88_trace.dut.r_th  : std_logic_vector(3 downto 0) >>;
    alias s_tl  is << signal .tb_mb88_trace.dut.r_tl  : std_logic_vector(3 downto 0) >>;
    alias s_sbo is << signal .tb_mb88_trace.dut.single_byte_op : std_logic >>;

    file f : text open read_mode is STEPS;
    variable l : line;
    variable v12 : std_logic_vector(11 downto 0);
    variable v8  : std_logic_vector(7 downto 0);
    variable v4  : std_logic_vector(3 downto 0);
    variable pc, a, x, y, si, pio, th, tl, nb, inkind, inval, irqlev, tick, entry : natural;
    variable n : natural := 0;

    impure function rd4 return natural is
    begin
      hread(l, v4);
      return to_integer(unsigned(v4));
    end function;

    -- one ena cycle, then three idle clocks for the registered ROM and RAM paths. ena
    -- changes on the rising edge like the clock enables of the cores, the core's RAM
    -- writes on the inverted clock and must see the same ena as its main process.
    procedure one_ena is
    begin
      wait until rising_edge(clk);
      ena <= '1';
      wait until rising_edge(clk);
      ena <= '0';
      for i in 1 to 3 loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    -- a rising edge on tc_n, seen by the core before the next ena
    procedure tc_pulse is
    begin
      wait until falling_edge(clk);
      tc_n <= '1';
      wait until falling_edge(clk);
      wait until falling_edge(clk);
      tc_n <= '0';
    end procedure;

    procedure check(name : string; got, want : natural) is
    begin
      if got /= want then
        report "step " & integer'image(n) & " at $" & to_hstring(to_unsigned(pc, 12)) &
               ": " & name & " is " & to_hstring(to_unsigned(got, 8)) &
               ", MAME has " & to_hstring(to_unsigned(want, 8)) severity failure;
      end if;
    end procedure;
  begin
    for i in 1 to 8 loop
      wait until falling_edge(clk);
    end loop;
    reset_n <= '1';

    -- run the program from reset up to the first traced instruction
    readline(f, l);
    hread(l, v12);
    pc := to_integer(unsigned(v12));
    for i in 1 to 100 loop
      exit when s_sbo = '1' and to_integer(unsigned(std_logic_vector'(s_pa & s_pc))) = pc;
      one_ena;
    end loop;

    loop
      if n > 0 then
        exit when endfile(f);
        readline(f, l);
        hread(l, v12);
        pc := to_integer(unsigned(v12));
      end if;
      a := rd4; x := rd4; y := rd4; si := rd4;
      hread(l, v8); pio := to_integer(unsigned(v8));
      th := rd4; tl := rd4; nb := rd4; inkind := rd4; inval := rd4; irqlev := rd4;
      tick := rd4; entry := rd4;

      check("PC", to_integer(unsigned(std_logic_vector'(s_pa & s_pc))), pc);
      check("A", to_integer(unsigned(s_a)), a);
      check("X", to_integer(unsigned(s_x)), x);
      check("Y", to_integer(unsigned(s_y)), y);
      check("SI", to_integer(unsigned(s_si)), si);
      check("PIO", to_integer(unsigned(s_pio)), pio);
      check("TH", to_integer(unsigned(s_th)), th);
      check("TL", to_integer(unsigned(s_tl)), tl);

      -- inputs this instruction reads
      if inkind = 1 then
        k_in <= std_logic_vector(to_unsigned(inval, 4));
      elsif inkind = 2 then
        case y mod 4 is
          when 0 => r0_in <= std_logic_vector(to_unsigned(inval, 4));
          when 1 => r1_in <= std_logic_vector(to_unsigned(inval, 4));
          when 2 => r2_in <= std_logic_vector(to_unsigned(inval, 4));
          when others => r3_in <= std_logic_vector(to_unsigned(inval, 4));
        end case;
      end if;
      if irqlev = 0 then
        irq_n <= '1';
      elsif irqlev = 1 then
        irq_n <= '0';
      end if;

      -- the instruction; a timer step lands in its last byte, as MAME steps between
      -- this instruction and the next
      if nb = 2 then
        one_ena;
      end if;
      if tick = 1 then
        tc_pulse;
      end if;
      one_ena;

      -- an external interrupt entry: a fresh edge on the line, then the entry cycle
      if entry = 1 then
        if irq_n = '0' then
          irq_n <= '1';
          wait until falling_edge(clk);
          wait until falling_edge(clk);
        end if;
        irq_n <= '0';
        wait until falling_edge(clk);
        wait until falling_edge(clk);
        -- the entry cycle and the three cycles the entry takes on top
        for i in 1 to 4 loop
          one_ena;
        end loop;
      end if;

      n := n + 1;
      if n mod 500000 = 0 then
        report integer'image(n) & " steps" severity note;
      end if;
    end loop;
    report "PASS: " & integer'image(n) & " steps in lock step with MAME" severity note;
    done <= true;
    wait;
  end process p_run;
end architecture sim;
