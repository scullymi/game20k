-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file g20k_promram.vhd
--! @brief A ROM of the Galaga core that the ROM loader fills from the SD card at run time.
--!
--! Written for game20k. It stands in for the fixed PROM entities of Dar's core, so the ROM
--! contents come from the card and not from the bitstream.
--!
--! Read side: one register stage, the latency of the PROMs it stands in for, which the tile
--! path of the core relies on. The caller picks the read edge through clk, the core uses
--! clock_18 for some instances and clock_18n for others.
--!
--! Load side: the loader's own clock. With two clocks Gowin maps the array to a semi
--! dual-port block RAM (SDPB). One clock with an address multiplexer in front of the array
--! often ends up in LUT RAM instead.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity g20k_promram is
  generic (
    aWidth : integer := 12    --! address width in bits, the data is a byte
  );
  port (
    -- read side, clock and edge as in the PROM the instance stands in for
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
  p_load : process (wr_clk)
  begin
    if rising_edge(wr_clk) then
      if wr_en = '1' then
        mem(to_integer(unsigned(wr_addr))) <= wr_data;
      end if;
    end if;
  end process p_load;

  p_read : process (clk)
  begin
    if rising_edge(clk) then
      data <= mem(to_integer(unsigned(addr)));
    end if;
  end process p_read;
end architecture rtl;
