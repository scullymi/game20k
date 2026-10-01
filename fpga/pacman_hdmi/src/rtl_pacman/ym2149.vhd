-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file ym2149.vhd
--! @brief Stub for the YM2149 sound chip that pacman.vhd instantiates as component "sn".
--!
--! The upstream core mixes this chip into O_AUDIO only for Dream Shopper (mod_dshop), which
--! this folder never selects: the wrapper ties every mod_* input to 0. The entity carries
--! exactly the port list of the component declaration in pacman.vhd (upstream rtl/ym2149.sv),
--! so the component binds to it by name without any change to pacman.vhd, and every output is
--! constant, so no SystemVerilog sound source enters the VHDL-only simulation. Gowin sweeps
--! the instance (NL0002). Anyone who enables mod_dshop later gets silence from here.
library ieee;
use ieee.std_logic_1164.all;

entity ym2149 is
  port (
    CLK       : in  std_logic;
    CE        : in  std_logic;
    RESET     : in  std_logic;
    BDIR      : in  std_logic;
    BC        : in  std_logic;
    DI        : in  std_logic_vector(7 downto 0);
    DO        : out std_logic_vector(7 downto 0);
    CHANNEL_A : out std_logic_vector(7 downto 0);
    CHANNEL_B : out std_logic_vector(7 downto 0);
    CHANNEL_C : out std_logic_vector(7 downto 0);

    SEL       : in  std_logic;
    MODE      : in  std_logic;
    IOA_in    : in  std_logic_vector(7 downto 0);
    IOA_out   : out std_logic_vector(7 downto 0);

    IOB_in    : in  std_logic_vector(7 downto 0);
    IOB_out   : out std_logic_vector(7 downto 0)
  );
end entity ym2149;

architecture stub of ym2149 is
begin
  DO        <= (others => '0');
  CHANNEL_A <= (others => '0');
  CHANNEL_B <= (others => '0');
  CHANNEL_C <= (others => '0');
  IOA_out   <= (others => '0');
  IOB_out   <= (others => '0');
end architecture stub;
