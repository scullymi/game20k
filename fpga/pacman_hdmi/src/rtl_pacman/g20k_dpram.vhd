-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file g20k_dpram.vhd
--! @brief Inferred dual-port RAM for Gowin. Replaces the Altera dpram (altsyncram) of the
--!        MiSTer Pac-Man core. Written from scratch for the synthesis spike.
--!
--! Port A reads and writes, port B only reads. Both ports run on the same clock, each with its
--! own clock enable. Reads are synchronous: the address is taken at the rising edge and the
--! data is valid right after it. That is what the core expects from altsyncram with
--! unregistered outputs (address register only).
--!
--! Port A is write-through: a write returns the new data, like "NEW_DATA_NO_NBE_READ" of the
--! altsyncram it replaces. (Read-first would be WRITE_MODE 2'b10, which Gowin PnR 1.9.11.03
--! rejects for a DPB: "PA2122 Not support ... WRITE_MODE0 = 2'b10".) The core never uses the
--! read data of a write cycle anyway. When port B reads the address that port A writes in
--! the same cycle, the result is not defined (the Altera default for mixed ports is "don't
--! care" as well).
--!
--! RAMSTYLE "auto" leaves the choice between BSRAM and SSRAM to Gowin synthesis. Any other
--! value is handed over as syn_ramstyle, for example "block_ram" or "distributed_ram".
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity g20k_dpram is
  generic (
    AW       : positive := 8;       --! address width in bits
    DW       : positive := 8;       --! data width in bits
    RAMSTYLE : string   := "auto"   --! see above
  );
  port (
    clk    : in  std_logic;
    -- Port A: read and write
    a_ce   : in  std_logic := '1';  --! clock enable for read and write
    a_we   : in  std_logic := '0';  --! write enable, only effective with a_ce
    a_addr : in  std_logic_vector(AW-1 downto 0);
    a_din  : in  std_logic_vector(DW-1 downto 0) := (others => '0');
    a_dout : out std_logic_vector(DW-1 downto 0);
    -- Port B: read only
    b_ce   : in  std_logic := '1';  --! clock enable for the read register
    b_addr : in  std_logic_vector(AW-1 downto 0);
    b_dout : out std_logic_vector(DW-1 downto 0)
  );
end entity g20k_dpram;

architecture rtl of g20k_dpram is
  type mem_t is array (0 to 2**AW - 1) of std_logic_vector(DW-1 downto 0);
begin

  -- The two branches differ only in the attribute. VHDL cannot attach an attribute
  -- conditionally, so the memory is declared once per branch.
  g_auto : if RAMSTYLE = "auto" generate
    signal mem : mem_t;
  begin
    -- Port A: write when enabled and pass the new data through (write-through).
    p_port_a : process (clk)
    begin
      if rising_edge(clk) then
        if a_ce = '1' then
          if a_we = '1' then
            mem(to_integer(unsigned(a_addr))) <= a_din;
            a_dout <= a_din;
          else
            a_dout <= mem(to_integer(unsigned(a_addr)));
          end if;
        end if;
      end if;
    end process;

    -- Port B: plain synchronous read.
    p_port_b : process (clk)
    begin
      if rising_edge(clk) then
        if b_ce = '1' then
          b_dout <= mem(to_integer(unsigned(b_addr)));
        end if;
      end if;
    end process;
  end generate;

  g_forced : if RAMSTYLE /= "auto" generate
    signal mem : mem_t;
    attribute syn_ramstyle : string;
    attribute syn_ramstyle of mem : signal is RAMSTYLE;
  begin
    p_port_a : process (clk)
    begin
      if rising_edge(clk) then
        if a_ce = '1' then
          if a_we = '1' then
            mem(to_integer(unsigned(a_addr))) <= a_din;
            a_dout <= a_din;
          else
            a_dout <= mem(to_integer(unsigned(a_addr)));
          end if;
        end if;
      end if;
    end process;

    p_port_b : process (clk)
    begin
      if rising_edge(clk) then
        if b_ce = '1' then
          b_dout <= mem(to_integer(unsigned(b_addr)));
        end if;
      end if;
    end process;
  end generate;

end architecture rtl;
