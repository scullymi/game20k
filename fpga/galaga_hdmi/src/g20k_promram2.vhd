-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file g20k_promram2.vhd
--! @brief Two program ROMs of the same size in one block RAM, loaded from the SD card.
--!
--! Written for game20k. The Galaga core keeps the programs of its two Namco MCUs here,
--! the 54XX in the lower half and the 51XX in the upper half, so both take one block RAM.
--!
--! Read side: one read port that serves both halves in turn, one clock each. Every result
--! goes through its own output register, so data_a and data_b each change at most two
--! clocks after their address. That suits callers that fetch once every many clocks, as
--! the MCUs do (one instruction byte every 48 or 72 clocks).
--!
--! Load side: a write port of its own on wr_clk, as in g20k_promram.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity g20k_promram2 is
  generic (
    aWidth : integer := 10    --! address width of ONE program, the block holds two
  );
  port (
    clk     : in  std_logic;
    addr_a  : in  std_logic_vector(aWidth-1 downto 0);
    data_a  : out std_logic_vector(7 downto 0);
    addr_b  : in  std_logic_vector(aWidth-1 downto 0);
    data_b  : out std_logic_vector(7 downto 0);
    -- load side, driven by the ROM loader, program A first
    wr_clk  : in  std_logic;
    wr_addr : in  std_logic_vector(aWidth downto 0);
    wr_data : in  std_logic_vector(7 downto 0);
    wr_en   : in  std_logic
  );
end entity g20k_promram2;

architecture rtl of g20k_promram2 is
  type mem_t is array (0 to 2**(aWidth+1) - 1) of std_logic_vector(7 downto 0);
  signal mem   : mem_t := (others => (others => '0'));
  signal sel   : std_logic := '0';  -- half the read port serves in this clock
  signal sel_d : std_logic := '0';  -- half the word in q belongs to
  signal q     : std_logic_vector(7 downto 0) := (others => '0');
begin
  p_load : process (wr_clk)
  begin
    if rising_edge(wr_clk) then
      if wr_en = '1' then
        mem(to_integer(unsigned(wr_addr))) <= wr_data;
      end if;
    end if;
  end process p_load;

  -- read A and B in turn, then hand each word to the output register of its half
  p_read : process (clk)
  begin
    if rising_edge(clk) then
      if sel = '0' then
        q <= mem(to_integer(unsigned('0' & addr_a)));
      else
        q <= mem(to_integer(unsigned('1' & addr_b)));
      end if;
      sel   <= not sel;
      sel_d <= sel;
      if sel_d = '0' then
        data_a <= q;
      else
        data_b <= q;
      end if;
    end if;
  end process p_read;
end architecture rtl;
