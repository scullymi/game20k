-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file g20k_promram.vhd
--! @brief A ROM of the Galaga core that the ROM loader fills from the SD card at run time.
--!
--! Written for game20k. The Galaga core uses it for all its program, graphics, palette and
--! sound ROMs, so their contents come from the card and not from the bitstream.
--!
--! Read side: one register stage, which the tile path of the core relies on. The caller
--! picks the read clock and edge, the core uses clock_18 for some instances and clock_18n
--! for others.
--!
--! Load side: a write port of its own on wr_clk, which the loader drives (in game20k the core
--! clock). Gowin picks the RAM by the size that is really used: the larger arrays become
--! semi dual-port block RAM (SDPB), the smallest ones LUT RAM.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity g20k_promram is
  generic (
    aWidth : integer := 12    --! address width in bits, the data is a byte
  );
  port (
    -- read side, clock and edge as the instance needs them
    clk     : in  std_logic;
    addr    : in  std_logic_vector(aWidth-1 downto 0);
    data    : out std_logic_vector(7 downto 0);
    -- load side, driven by the ROM loader
    wr_clk  : in  std_logic;
    wr_addr : in  std_logic_vector(aWidth-1 downto 0);
    wr_data : in  std_logic_vector(7 downto 0);
    wr_en   : in  std_logic
  );
end entity g20k_promram;

architecture rtl of g20k_promram is
  type mem_t is array (0 to 2**aWidth - 1) of std_logic_vector(7 downto 0);
  signal mem : mem_t := (others => (others => '0'));
begin
  -- the loader writes one byte per enabled edge
  p_load : process (wr_clk)
  begin
    if rising_edge(wr_clk) then
      if wr_en = '1' then
        mem(to_integer(unsigned(wr_addr))) <= wr_data;
      end if;
    end if;
  end process p_load;

  -- one register stage on the caller's clock
  p_read : process (clk)
  begin
    if rising_edge(clk) then
      data <= mem(to_integer(unsigned(addr)));
    end if;
  end process p_read;
end architecture rtl;
