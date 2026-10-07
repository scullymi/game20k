-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file dpram_dc.vhd
--! @brief game20k stand-in for Ace's Altera dpram_dc: same entity, inferred block RAM.
--!
--! Port A reads and writes, port B only reads, both in one clock (clock_a): what Gowin maps
--! to one semi-dual-port BSRAM. rom_loader.sv writes the ROMs through port A and the game
--! reads them through port B. data_b, wren_b and byteena_* are accepted and ignored, so is
--! clock_b. Reads return the word one clock after the address, like the unregistered
--! altsyncram outputs of the original.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_dc is
  generic (
    init_file     : string  := " ";
    widthad_a     : natural;
    width_a       : natural := 8;
    outdata_reg_a : string  := "UNREGISTERED";
    outdata_reg_b : string  := "UNREGISTERED"
  );
  port (
    address_a : in  std_logic_vector(widthad_a-1 downto 0);
    address_b : in  std_logic_vector(widthad_a-1 downto 0) := (others => '0');
    clock_a   : in  std_logic;
    clock_b   : in  std_logic := '0';
    data_a    : in  std_logic_vector(width_a-1 downto 0) := (others => '0');
    data_b    : in  std_logic_vector(width_a-1 downto 0) := (others => '0');
    wren_a    : in  std_logic := '0';
    wren_b    : in  std_logic := '0';
    byteena_a : in  std_logic_vector(width_a/8-1 downto 0) := (others => '1');
    byteena_b : in  std_logic_vector(width_a/8-1 downto 0) := (others => '1');
    q_a       : out std_logic_vector(width_a-1 downto 0);
    q_b       : out std_logic_vector(width_a-1 downto 0)
  );
end entity dpram_dc;

architecture rtl of dpram_dc is
  type mem_t is array (0 to 2**widthad_a - 1) of std_logic_vector(width_a-1 downto 0);
  signal mem : mem_t;
begin
  p_port_a : process (clock_a)
  begin
    if rising_edge(clock_a) then
      if wren_a = '1' then
        mem(to_integer(unsigned(address_a))) <= data_a;
        q_a <= data_a;
      else
        q_a <= mem(to_integer(unsigned(address_a)));
      end if;
    end if;
  end process;

  p_port_b : process (clock_a)
  begin
    if rising_edge(clock_a) then
      q_b <= mem(to_integer(unsigned(address_b)));
    end if;
  end process;
end architecture rtl;
