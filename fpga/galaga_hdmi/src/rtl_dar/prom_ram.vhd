-- ---------------------------------------------------------------------------------
-- This file does not exist upstream. It is a game20k addition.
--
-- DERIVED from gen_ram.vhd, Copyright 2005-2008 Peter Wendrich (pwsoft@syntiac.com),
-- http://www.syntiac.com/fpga64.html. It takes the RAM array declaration and the write
-- process from that file. Wendrich's file carries a copyright notice but NO licence
-- text, so its redistribution terms are unclear. See THIRD-PARTY.md.
-- The game20k parts are Copyright (C) 2026 scullymi. The file carries no SPDX tag because it
-- mixes them with Wendrich's lines.
-- ---------------------------------------------------------------------------------
-- prom_ram.vhd (game20k)
--
-- Writable replacement for the fixed PROM entities of Dar's core, so the ROM contents
-- load from SD card at run time instead of sitting in the bitstream.
--
-- Read side: exactly one register stage, as in gen_ram.vhd. The tile path in galaga.vhd
-- relies on this latency. The caller sets the read edge through clk, the instances in
-- the core use clock_18 for some PROMs and clock_18n for others.
--
-- Write side: its own clock, the loader's clock. Separate read and write clocks let
-- Gowin map the array to a semi dual-port block RAM (SDPB). A shared clock with an address
-- multiplexer in front of the array often ends up as LUT RAM instead.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity prom_ram is
	generic (
		aWidth : integer := 12
	);
	port (
		-- read side, clock and edge as in the PROM this instance replaces
		clk     : in  std_logic;
		addr    : in  std_logic_vector((aWidth-1) downto 0);
		data    : out std_logic_vector(7 downto 0);
		-- load side, driven by the ROM loader
		wr_clk  : in  std_logic;
		wr_addr : in  std_logic_vector((aWidth-1) downto 0);
		wr_data : in  std_logic_vector(7 downto 0);
		wr_en   : in  std_logic
	);
end entity;

architecture rtl of prom_ram is
	subtype addressRange is integer range 0 to ((2**aWidth)-1);
	type ramDef is array(addressRange) of std_logic_vector(7 downto 0);
	signal ram : ramDef := (others => (others => '0'));
begin

	-- write side (loader)
	process(wr_clk)
	begin
		if rising_edge(wr_clk) then
			if wr_en = '1' then
				ram(to_integer(unsigned(wr_addr))) <= wr_data;
			end if;
		end if;
	end process;

	-- read side (core), one register stage
	process(clk)
	begin
		if rising_edge(clk) then
			data <= ram(to_integer(unsigned(addr)));
		end if;
	end process;

end architecture;
