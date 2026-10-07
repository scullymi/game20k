-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file namco_io.vhd
--! @brief Namco 06XX interface with a 51XX I/O chip that runs its original program.
--!
--! Written for game20k after the behaviour MAME describes in namco06.cpp, namco51.cpp and
--! mb88xx.cpp (BSD-3-Clause). No code is taken from other cores.
--!
--! 06XX: its clock is clk / 384 (48 kHz at 18.432 MHz), divided by 2^(control bits 7..5).
--! Each half period toggles an internal state. Going high it sets R/W from control bit 4,
--! raises the chip selects named in control bits 3..0 (the IRQs of the custom MCUs) and
--! the NMI of the main CPU, going low it drops selects and NMI. A read suppresses the first
--! NMI, so the chip has one period to answer. A zero divider stops the clock.
--!
--! Unlike MAME, the chip selects follow NMI by CS_DELAY clocks. With both at once, the MCUs
--! read a byte about 5 to 15 us after the main CPU's NMI handler writes it, and a handler a
--! few us later than in MAME leaves them the old byte (measured with tb_namco54.vhd). Then
--! the 54XX takes wrong explosion parameters, depending on the phase at reset.
--!
--! 51XX: an MB8843 (mb88 with 64 nibbles of RAM) on chip select 0. K is R/W and the low
--! three bits of the latch between 06XX and 51XX, the MCU answers through the same latch
--! with outO. R0..R3 are the inputs as the board wires them, active low. TC counts the
--! vertical blanks.
--!
--! Chip selects 1..3 go out for other customs (Galaga: the 54XX on 3), with a write strobe
--! per chip and the written byte.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity namco_io is
  generic (
    CS_DELAY : natural := 192                          --! clocks from NMI to the chip selects, 1..383
  );
  port (
    clk         : in  std_logic;                     --! 18.432 MHz, the 06XX logic uses the falling edge
    reset       : in  std_logic;                     --! the 06XX, active high
    mcu_reset_n : in  std_logic;                     --! the 51XX, active low
    mcu_ena     : in  std_logic;                     --! one 51XX instruction cycle, every 72 clocks
    -- main CPU side: data at address bit 8 = 0, control at 1
    cpu_we      : in  std_logic;                     --! write strobe, sampled on the falling edge
    cpu_sel     : in  std_logic;
    cpu_di      : in  std_logic_vector(7 downto 0);
    cpu_do      : out std_logic_vector(7 downto 0);  --! read data, combinational
    nmi         : out std_logic;                     --! to the main CPU, active high
    -- customs on chip selects 1..3
    cs          : out std_logic_vector(3 downto 1);  --! chip selects, active high
    dev_we      : out std_logic_vector(3 downto 1);  --! one clock per write to the chip
    dev_data    : out std_logic_vector(7 downto 0);  --! the byte written
    dev_do      : in  std_logic_vector(7 downto 0);  --! AND of what the selected chips 1..3 give, FF if none
    -- 51XX
    in_r        : in  std_logic_vector(15 downto 0); --! R3..R0, active low as on the board
    vblank      : in  std_logic;                     --! the timer steps on its rising edge
    rom_addr    : out std_logic_vector(9 downto 0);
    rom_data    : in  std_logic_vector(7 downto 0);
    p_out       : out std_logic_vector(3 downto 0)   --! coin counters and lamps
  );
end entity namco_io;

architecture rtl of namco_io is
  signal clk_n   : std_logic;
  signal control : std_logic_vector(7 downto 0) := x"00";
  signal base    : unsigned(8 downto 0) := (others => '0');   -- one period of the 48 kHz clock
  signal cnt     : unsigned(14 downto 0) := (others => '0');  -- clocks to the next half period
  signal run     : std_logic := '0';
  signal state   : std_logic := '0';
  signal stretch : std_logic := '0';
  signal nmi_r   : std_logic := '0';
  signal rw      : std_logic := '0';                          -- '1' = read
  signal sel     : std_logic_vector(3 downto 0) := "0000";      -- chip selects as MAME has them
  signal sel_out : std_logic_vector(3 downto 0) := "0000";      -- the same, CS_DELAY clocks later
  signal latch   : std_logic_vector(7 downto 0) := x"00";     -- between 06XX and 51XX
  signal ol, oh  : std_logic_vector(3 downto 0);
  signal o_we    : std_logic;
  signal k       : std_logic_vector(3 downto 0);
  signal rom_a   : std_logic_vector(10 downto 0);
  signal irq_n   : std_logic;
  signal rd_51   : std_logic_vector(7 downto 0);
  signal rd_dev  : std_logic_vector(7 downto 0);
begin
  clk_n <= not clk;

  p_06xx : process (clk_n)
  begin
    if rising_edge(clk_n) then
      dev_we <= "000";
      if base = 383 then base <= (others => '0'); else base <= base + 1; end if;

      -- the clock: every half period toggles the state, going high it latches R/W and
      -- raises chip selects and NMI (unless a read suppresses this first NMI)
      if run = '1' then
        if cnt = 0 then
          cnt   <= shift_left(to_unsigned(192, 15), to_integer(unsigned(control(7 downto 5)))) - 1;
          state <= not state;
          if state = '0' then
            rw    <= control(4);
            nmi_r <= not stretch;
            sel   <= control(3 downto 0);
          else
            nmi_r <= '0';
            sel   <= "0000";
          end if;
          stretch <= '0';
        else
          cnt <= cnt - 1;
        end if;
      end if;

      -- the 51XX answers through the latch the main CPU writes to
      if o_we = '1' then latch <= oh & ol; end if;

      if cpu_we = '1' then
        if cpu_sel = '0' then
          -- data: taken only in write mode, by every selected chip
          if control(4) = '0' then
            if control(0) = '1' then latch <= cpu_di; end if;
            dev_we   <= control(3 downto 1);
            dev_data <= cpu_di;
          end if;
        else
          -- control: a zero divider stops the clock, otherwise it restarts with the next
          -- period of the 48 kHz clock, and a read clears the NMI at once
          control <= cpu_di;
          if cpu_di(7 downto 5) = "000" then
            run   <= '0';
            state <= '0';
            nmi_r <= '0';
            sel   <= "0000";
          else
            run     <= '1';
            cnt     <= to_unsigned(383, 15) - resize(base, 15);
            stretch <= cpu_di(4);
            if cpu_di(4) = '1' then nmi_r <= '0'; end if;
          end if;
        end if;
      end if;

      if reset = '1' then
        control <= x"00";
        run     <= '0';
        state   <= '0';
        stretch <= '0';
        nmi_r   <= '0';
        rw      <= '0';
        sel     <= "0000";
        latch   <= x"00";
        dev_we  <= "000";
      end if;
    end if;
  end process p_06xx;

  -- the chip selects: every change of sel, CS_DELAY clocks later, short pulses included. MAME
  -- has a select rise 3 us before the main CPU stops the clock, and the 51XX counts that
  -- pulse. Changes come a half period (at least 384 clocks) apart, plus a stop at any time,
  -- so at most two wait at once.
  p_csdelay : process (clk_n)
    variable last   : std_logic_vector(3 downto 0) := "0000";
    variable v0, v1 : std_logic_vector(3 downto 0) := "0000";
    variable c0, c1 : natural range 0 to 383 := 0;          -- clocks left, 0 = slot empty
    variable fire   : boolean;
  begin
    if rising_edge(clk_n) then
      fire := c0 = 1;
      if c0 /= 0 then c0 := c0 - 1; end if;
      if c1 /= 0 then c1 := c1 - 1; end if;
      if fire then
        sel_out <= v0;
        v0 := v1;
        c0 := c1;
        c1 := 0;
      end if;
      if sel /= last then
        last := sel;
        if c0 = 0 then
          v0 := sel;
          c0 := CS_DELAY;
        else
          v1 := sel;
          c1 := CS_DELAY;
        end if;
      end if;
      if reset = '1' then
        last := "0000";
        c0 := 0;
        c1 := 0;
        sel_out <= "0000";
      end if;
    end if;
  end process p_csdelay;

  nmi      <= nmi_r;
  cs       <= sel_out(3 downto 1);

  -- read: 0 in write mode, else the AND of the selected chips
  rd_51  <= latch  when control(0) = '1' else x"FF";
  rd_dev <= dev_do when control(3 downto 1) /= "000" else x"FF";
  cpu_do <= control when cpu_sel = '1' else
            x"00"   when control(4) = '0' else
            rd_51 and rd_dev;

  k     <= rw & latch(2 downto 0);
  irq_n <= not sel_out(0);

  mcu : entity work.mb88
    generic map (data_6bit => true)
    port map (
      reset_n => mcu_reset_n, clock => clk, ena => mcu_ena,
      r0_port_in => in_r(3 downto 0), r1_port_in => in_r(7 downto 4),
      r2_port_in => in_r(11 downto 8), r3_port_in => in_r(15 downto 12),
      r0_port_out => open, r1_port_out => open, r2_port_out => open, r3_port_out => open,
      k_port_in => k, ol_port_out => ol, oh_port_out => oh, o_we => o_we, p_port_out => p_out,
      stby_n => '0', tc_n => vblank, irq_n => irq_n, sc_in_n => '0', si_n => '0',
      sc_out_n => open, so_n => open, to_n => open,
      rom_addr => rom_a, rom_data => rom_data);

  rom_addr <= rom_a(9 downto 0);
end architecture rtl;
