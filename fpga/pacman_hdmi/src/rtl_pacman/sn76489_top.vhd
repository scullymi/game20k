-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file sn76489_top.vhd
--! @brief Stub for the SN76489 sound chip that pacman.vhd instantiates twice (sn1, sn2).
--!
--! The upstream core drives these chips only for Van-Van Car (mod_van), which this folder
--! never selects: the wrapper ties every mod_* input to 0, so their outputs never reach
--! O_AUDIO. The entity here carries exactly the port list of the upstream
--! rtl/sn76489/sn76489_top.vhd (Arnim Laeuger's implementation, GPL-2 in the upstream tree),
--! so pacman.vhd binds to it unchanged, and constant outputs, so neither the GPL-2 sources
--! nor a working chip enter this repository. Gowin sweeps the instances (NL0002). Anyone who
--! enables mod_van later gets silence from here, not sound.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sn76489_top is
  generic (
    clock_div_16_g : integer := 1   --! upstream generic, accepted and unused
  );
  port (
    clock_i    : in  std_logic;
    clock_en_i : in  std_logic;
    res_n_i    : in  std_logic;
    ce_n_i     : in  std_logic;
    we_n_i     : in  std_logic;
    ready_o    : out std_logic;
    d_i        : in  std_logic_vector(0 to 7);
    aout_o     : out signed(0 to 7)
  );
end entity sn76489_top;

architecture stub of sn76489_top is
begin
  -- Always ready, so the write handshake in pacman.vhd (sn1_ce, sn2_ce) never waits.
  ready_o <= '1';
  aout_o  <= (others => '0');
end architecture stub;
