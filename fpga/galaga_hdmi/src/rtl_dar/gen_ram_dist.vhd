-- ---------------------------------------------------------------------------------
-- This file does not exist upstream. It is a game20k addition.
--
-- DERIVED from gen_ram.vhd, Copyright 2005-2008 Peter Wendrich (pwsoft@syntiac.com),
-- http://www.syntiac.com/fpga64.html. It takes the entity interface and the write
-- process from that file. Wendrich's file carries a copyright notice but NO licence
-- text, so its redistribution terms are unclear. See THIRD-PARTY.md.
-- The game20k parts are Copyright (C) 2026 scullymi. The file carries no SPDX tag because it
-- mixes them with Wendrich's lines.
-- ---------------------------------------------------------------------------------
-- game20k: RAM with asynchronous read (distributed LUT RAM). Used in every build for the
-- background character RAM (bgram) in galaga.vhd: the RetroAchievements harvest reads
-- bgram_do in the same slot in which it presents the address, which the registered read
-- of gen_ram cannot deliver.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;
entity gen_ram_dist is
	generic (
		dWidth : integer := 8;
		aWidth : integer := 10
	);
	port (
		clk : in std_logic;
		we : in std_logic;
		addr : in std_logic_vector((aWidth-1) downto 0);
		d : in std_logic_vector((dWidth-1) downto 0);
		q : out std_logic_vector((dWidth-1) downto 0)
	);
end entity;
architecture rtl of gen_ram_dist is
	type ramDef is array(0 to ((2**aWidth)-1)) of std_logic_vector((dWidth-1) downto 0);
	signal ram: ramDef := (others => (others => '0'));
	attribute syn_ramstyle : string;  -- pin ram to LUT RAM, block RAM has no asynchronous read
	attribute syn_ramstyle of ram : signal is "distributed_ram";
begin
	process(clk)  -- synchronous write port
	begin
		if rising_edge(clk) then
			if we = '1' then
				ram(to_integer(unsigned(addr))) <= d;
			end if;
		end if;
	end process;
	q <= ram(to_integer(unsigned(addr)));  -- asynchronous read, no register stage
end architecture;
