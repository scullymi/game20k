-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file g20k_lutram.vhd
--! @brief RAM with a synchronous write and an asynchronous read, pinned to LUT RAM.
--!
--! Written for game20k. The Galaga core uses it for the background character RAM (bgram):
--! the RetroAchievements harvest reads the word in the same slot in which it presents the
--! address, which a block RAM with its registered read cannot deliver. Same interface as
--! g20k_spram.vhd.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity g20k_lutram is
  generic (
    dWidth : integer := 8;    --! data width in bits
    aWidth : integer := 10    --! address width in bits
  );
  port (
    clk  : in  std_logic;
    we   : in  std_logic;                            --! write d at addr on this edge
    addr : in  std_logic_vector(aWidth-1 downto 0);
    d    : in  std_logic_vector(dWidth-1 downto 0);
    q    : out std_logic_vector(dWidth-1 downto 0)   --! the word at addr, without a clock
  );
end entity g20k_lutram;

architecture rtl of g20k_lutram is
  type mem_t is array (0 to 2**aWidth - 1) of std_logic_vector(dWidth-1 downto 0);
  signal mem : mem_t := (others => (others => '0'));
  -- block RAM reads only on a clock edge, so the array has to stay in LUTs
  attribute syn_ramstyle : string;
  attribute syn_ramstyle of mem : signal is "distributed_ram";
begin
  p_write : process (clk)
  begin
    if rising_edge(clk) then
      if we = '1' then
        mem(to_integer(unsigned(addr))) <= d;
      end if;
    end if;
  end process p_write;

  q <= mem(to_integer(unsigned(addr)));
end architecture rtl;
