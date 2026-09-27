---------------------------------------------------------------------------------
-- Galaga sound machine by Dar (darfpga@aol.fr)
-- http://darfpga.blogspot.fr
---------------------------------------------------------------------------------
---------------------------------------------------------------------------------
-- MODIFIED VERSION, not Dar's original.
-- game20k change in this file: the load side of the two sound ROMs, so they come from SD card.
-- The README in this folder gives the reason for each change and names the upstream
-- commit to diff against. Scope: a few lines. Some places are marked "game20k" in the
-- text, not all: the diff is the complete list.
--
-- Upstream this file carries no licence text of its own. Dar's condition for the core
-- (educational use only, do not redistribute synthesized files with ROMs, do not
-- redistribute ROMs) stands in galaga.vhd and mb88.vhd, see the README in this folder
-- and THIRD-PARTY.md.
---------------------------------------------------------------------------------
-- 3 voices frequency/waveform synthetizer 
--
-- Original hardware done with only one 4 bits sequential adder to realise 
-- one 20 bits adder and two 16 bits adder.
--
-- Too nice and clever to be done another way, just doing it the same way! 
-- 

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity sound_machine is
port(
 clock_18     : in std_logic;
 hcnt         : in std_logic_vector(5 downto 0);
 ena          : in std_logic;
 cpu_addr     : in std_logic_vector(3 downto 0);
 cpu_do       : in std_logic_vector(3 downto 0);
 ram_0_we     : in std_logic;
 ram_1_we     : in std_logic;
 audio        : out std_logic_vector(9 downto 0);
 -- game20k: load side of the two sound ROMs, rom_wr_en(1) samples, rom_wr_en(0) sequencer
 rom_wr_clk   : in std_logic;
 rom_wr_addr  : in std_logic_vector(7 downto 0);
 rom_wr_data  : in std_logic_vector(7 downto 0);
 rom_wr_en    : in std_logic_vector(1 downto 0)
);
end sound_machine;

architecture struct of sound_machine is

 signal clock_18n : std_logic;
 signal snd_ram_addr : std_logic_vector(3 downto 0);
 signal snd_ram_di   : std_logic_vector(3 downto 0);
 signal snd_ram_0_we : std_logic;
 signal snd_ram_1_we : std_logic;
 signal snd_ram_0_do : std_logic_vector(3 downto 0);
 signal snd_ram_1_do : std_logic_vector(3 downto 0);
 
 signal snd_seq_addr : std_logic_vector(7 downto 0);
 signal snd_seq_do   : std_logic_vector(7 downto 0);

 signal snd_samples_addr : std_logic_vector(7 downto 0);
 signal snd_samples_do   : std_logic_vector(7 downto 0);
 
 signal sum      : std_logic_vector(4 downto 0) := (others => '0');
 signal sum_r    : std_logic_vector(4 downto 0) := (others => '0');
 signal sum_3_rr : std_logic := '0';
 
 signal samples_ch0 : std_logic_vector(3 downto 0);
 signal samples_ch1 : std_logic_vector(3 downto 0);
 signal samples_ch2 : std_logic_vector(3 downto 0);
 signal volume_ch0  : std_logic_vector(3 downto 0);
 signal volume_ch1  : std_logic_vector(3 downto 0);
 signal volume_ch2  : std_logic_vector(3 downto 0);
 
begin

clock_18n <= not clock_18;

snd_seq_addr <= '0' & not ram_0_we & hcnt(5 downto 0);

snd_ram_addr <= cpu_addr when (ram_0_we = '1' or ram_1_we = '1') else hcnt(5 downto 2);
snd_ram_di   <= cpu_do   when (ram_0_we = '1' or ram_1_we = '1') else sum_r(3 downto 0);

snd_ram_0_we <= (not snd_seq_do(1) and ena) or ram_0_we ;
snd_ram_1_we <= ram_1_we;

sum <= ('0' & snd_ram_0_do) + ('0' & snd_ram_1_do) + ("0000" & sum_r(4));

process (clock_18)
begin
 if rising_edge(clock_18) and ena = '1' then
	if snd_seq_do(3) = '0' then
		sum_r <= (others => '0');
		sum_3_rr <= '0';
	elsif snd_seq_do(0) = '0' then
		sum_r <= sum;
		sum_3_rr <= sum_r(3);
	end if ;

	snd_samples_addr <= snd_ram_0_do(2 downto 0) & sum_r(3 downto 0) & sum_3_rr;
	
	if snd_seq_do(2) = '0' then
		if hcnt(5 downto 2) = X"5" then
			samples_ch0 <= snd_samples_do(3 downto 0);
			volume_ch0  <= snd_ram_1_do;
		end if;
		if hcnt(5 downto 2) = X"A" then
			samples_ch1 <= snd_samples_do(3 downto 0);
			volume_ch1  <= snd_ram_1_do;
		end if;
		if hcnt(5 downto 2) = X"F" then
			samples_ch2 <= snd_samples_do(3 downto 0);
			volume_ch2  <= snd_ram_1_do;
		end if;
	end if;
	
	audio <= ("00" & samples_ch0) * volume_ch0 +
	         ("00" & samples_ch1) * volume_ch1 +
				   ("00" & samples_ch2) * volume_ch2;
	
 end if;
end process;

-- sound register RAM0
sound_ram_0 : entity work.gen_ram
generic map( dWidth => 4, aWidth => 4)
port map(
 clk  => clock_18n,
 we   => snd_ram_0_we,
 addr => snd_ram_addr,
 d    => snd_ram_di,
 q    => snd_ram_0_do
);

-- sound register RAM1
sound_ram_1 : entity work.gen_ram
generic map( dWidth => 4, aWidth => 4)
port map(
 clk  => clock_18n,
 we   => snd_ram_1_we,
 addr => snd_ram_addr,
 d    => snd_ram_di,
 q    => snd_ram_1_do
);

-- sound samples ROM
sound_samples : entity work.prom_ram
generic map(aWidth => 8)
port map(
 clk     => clock_18n,
 addr    => snd_samples_addr,
 data    => snd_samples_do,
 wr_clk  => rom_wr_clk,
 wr_addr => rom_wr_addr,
 wr_data => rom_wr_data,
 wr_en   => rom_wr_en(1)
);

-- sound compute sequencer ROM
sound_seq : entity work.prom_ram
generic map(aWidth => 8)
port map(
 clk     => clock_18n,
 addr    => snd_seq_addr,
 data    => snd_seq_do,
 wr_clk  => rom_wr_clk,
 wr_addr => rom_wr_addr,
 wr_data => rom_wr_data,
 wr_en   => rom_wr_en(0)
);

end struct;
