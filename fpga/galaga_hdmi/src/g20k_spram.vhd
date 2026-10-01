-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file g20k_spram.vhd
--! @brief Inferred single-port RAM for Gowin with a synchronous, read-first output.
--!
--! Written for game20k in the style of g20k_dpram.vhd of the Pac-Man core. The Galaga core
--! uses it for its work, sprite, sound and shadow RAMs. Its instances set the generics
--! dWidth and aWidth and connect clk, we, addr, d and q.
--!
--! The address is taken at the rising edge and the word appears right after it. In a write
--! cycle the output shows the word as it was before the write (read-first), as the core
--! expects. All words start at zero.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity g20k_spram is
  generic (
    dWidth : integer := 8;    --! data width in bits
    aWidth : integer := 10    --! address width in bits
  );
  port (
    clk  : in  std_logic;
    we   : in  std_logic;                            --! write d at addr on this edge
    addr : in  std_logic_vector(aWidth-1 downto 0);
    d    : in  std_logic_vector(dWidth-1 downto 0);
    q    : out std_logic_vector(dWidth-1 downto 0)   --! the word at addr, one edge later
  );
end entity g20k_spram;

architecture rtl of g20k_spram is
  type mem_t is array (0 to 2**aWidth - 1) of std_logic_vector(dWidth-1 downto 0);
  signal mem : mem_t := (others => (others => '0'));
begin
  -- Read and write in one process: q takes the word before this edge's write, which is
  -- what a signal assignment gives within the same process.
  p_ram : process (clk)
    variable a : natural range 0 to 2**aWidth - 1;
  begin
    if rising_edge(clk) then
      a := to_integer(unsigned(addr));
      q <= mem(a);
      if we = '1' then
        mem(a) <= d;
      end if;
    end if;
  end process p_ram;
end architecture rtl;
