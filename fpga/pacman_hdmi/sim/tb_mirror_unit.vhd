-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file tb_mirror_unit.vhd
--! @brief Unit test of pacman_mirror alone, against a core emulator and a platform model.
--!
--! The core is replaced by models: a g20k_dpram as the 4 KB main RAM (port A written by the
--! emulated game, port B the mirror's read port), a g20k_dpram as the sprite x/y shadow, a
--! flip register, and an emulator that issues writes exactly as the core does: an ena_6
--! divider of three clocks, the strobes high in two consecutive ena_6 cycles with the same
--! address and data (the RAM written at both edges), and the frame_go tap as one ena_6 cycle.
--! The platform is modelled after game20k_top.sv: an eight-slot FIFO with the reset one
--! clock after the snap_run rise (priority over a push), pops in four patterns, a log
--! collector that skips the first window clock like snap_log, and the Pico's oracle rule.
--!
--! The testbench keeps its own picture of the RAM (exp_ram, exp_sxy, exp_flip), copies it at
--! the end of every window (snap_*) and flattens it with a function written from FBNeo's
--! table, not from the mirror's constants. The checks, as the design lists them:
--!   (a) harvest without writes: the delivered 6272 bytes equal the flat picture, exactly
--!       6272 pushes, snap_frame + 1, the window one contiguous level of 9268 clocks that
--!       starts in the clock after the P1 following the frame_go P0
--!   (b) race sweep: ten shadow indices, each written at every offset -9..+9 clocks around
--!       the P2 edge at which the harvest writes it; the delivered picture equals the state at
--!       the end of the window and the oracle rule reports zero mismatches
--!   (c) a write every 12 clocks through the whole window: picture, oracle, log count
--!   (d) writes to the core-only RAM 0x800-0xBFF are never logged, flat 0x0000-0x03FF and
--!       0x0800-0x0FFF stay zero
--!   (e) a transfer aborted 400 clocks after the rise and restarted delivers byte 0 first
--!       and 6272 pushes
--!   (f) a frame_go while snap_run = 1 starts no harvest and leaves frame_no unchanged
--!   (g) exactly one log entry per emulated write, with the address of the table, whichever
--!       cycle of the strobe pair comes first relative to the rounds
--! The generic JR runs the same checks in Jr. Pac-Man's layout (d_jrpacman.cpp: sprite x/y,
--! video RAM, Z80 RAM), 4112 rounds and a window of 12337 clocks; there the core RAM
--! 0x800-0xBFF is the board's and is mirrored, and the flip bit is the one never logged.
--! Ends with one line PASS, or a severity failure.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_mirror_unit is
  generic (JR : boolean := false);
end entity tb_mirror_unit;

architecture sim of tb_mirror_unit is
  constant T        : time    := 53.872 ns;   -- 18.5625 MHz
  constant N_MIRROR : natural := 6272;        -- pushes per transfer
  -- clocks per harvest: 2 + 3 x rounds - 1, Pac-Man 3089 rounds, Jr. 4112
  function window_clocks return natural is
  begin
    if JR then return 12337; else return 9268; end if;
  end function;
  constant N_WINDOW : natural := window_clocks;

  type byte_arr is array (natural range <>) of std_logic_vector(7 downto 0);
  type nat_arr  is array (natural range <>) of natural;
  type kind_t   is (K_RAM, K_SXY, K_FLIP);

  signal clk   : std_logic := '0';
  function to_sl(b : boolean) return std_logic is
  begin
    if b then return '1'; else return '0'; end if;
  end function;
  constant jr_sl : std_logic := to_sl(JR);
  signal done  : boolean   := false;
  signal ph    : unsigned(1 downto 0) := "00";
  signal ena_6 : std_logic;
  signal reset : std_logic := '0';
  signal frame_go : std_logic := '0';

  -- the emulated game's strobes
  signal we_ram, we_sxy, we_flip, emu_first : std_logic := '0';
  signal wr_addr : std_logic_vector(11 downto 0) := (others => '0');
  signal wr_data : std_logic_vector(7 downto 0)  := (others => '0');

  -- the core's read side
  signal ram_addr : std_logic_vector(11 downto 0);
  signal ram_q    : std_logic_vector(7 downto 0);
  signal sxy_addr : std_logic_vector(3 downto 0);
  signal sxy_q    : std_logic_vector(7 downto 0);
  signal flip     : std_logic := '0';

  -- the platform side
  signal snap_run, snap_full, snap_push, snap_harv, log_we : std_logic := '0';
  signal snap_byte, log_data : std_logic_vector(7 downto 0);
  signal snap_frame, log_addr : std_logic_vector(15 downto 0);

  -- the testbench's own picture of the game RAM, and its copy at the end of the window
  signal exp_ram  : byte_arr(0 to 4095) := (others => x"00");
  signal exp_sxy  : byte_arr(0 to 15)   := (others => x"00");
  signal exp_flip : std_logic := '0';
  signal snap_ram : byte_arr(0 to 4095) := (others => x"00");
  signal snap_sxy : byte_arr(0 to 15)   := (others => x"00");
  signal snap_flip : std_logic := '0';

  -- platform model
  signal pop_mode : natural := 0;   -- 0 pop every clock, 1 no pops, 2 random 0..40, 3 every 22
  signal fifo_cnt : natural := 0;
  signal run_s    : std_logic_vector(1 downto 0) := "00";
  signal push_n   : natural := 0;
  signal deliv    : byte_arr(0 to N_MIRROR - 1) := (others => x"00");

  -- log collector and the emulator's expected log
  signal log_a : nat_arr(0 to 1023) := (others => 0);
  signal log_d : byte_arr(0 to 1023) := (others => x"00");
  signal log_n : natural := 0;
  signal exp_a : nat_arr(0 to 1023) := (others => 0);
  signal exp_d : byte_arr(0 to 1023) := (others => x"00");
  signal exp_n : natural := 0;

  -- harvest monitor
  signal harv_rises, harv_falls, harv_len, last_len : natural := 0;

  --! FBNeo's "All Ram" positions, from the shadow index: the same table as mirror-map.md,
  --! written as subtractions so that it shares no constant expression with the mirror.
  function flat_addr(k : kind_t; idx : natural) return integer is
  begin
    if JR then
      case k is
        when K_RAM  => return 16#0010# + idx;     -- video RAM 0x000-0x7FF, Z80 RAM 0x800-0xFFF
        when K_SXY  => return idx;
        when K_FLIP => return -1;                 -- not in FBNeo's block, never
      end case;
    end if;
    case k is
      when K_RAM =>
        if    idx >= 16#C00# then return 16#0400# + (idx - 16#C00#);   -- work RAM
        elsif idx >= 16#800# then return -1;                            -- core-only, never
        elsif idx >= 16#400# then return 16#1010# + (idx - 16#400#);   -- colour RAM
        else                      return 16#1410# + idx;                -- video RAM
        end if;
      when K_SXY  => return 16#1000# + idx;
      when K_FLIP => return 16#1814#;
    end case;
  end function;

  --! The flat picture from the testbench's own copy of the RAM.
  function flat_of(ram : byte_arr(0 to 4095); sxy : byte_arr(0 to 15); fl : std_logic;
                   f : natural) return std_logic_vector is
  begin
    if JR then
      if    f <= 16#000F# then return sxy(f);
      elsif f <= 16#100F# then return ram(f - 16#0010#);
      else                     return x"00";
      end if;
    end if;
    if    f >= 16#0400# and f <= 16#07FF# then return ram(16#C00# + (f - 16#0400#));
    elsif f >= 16#1000# and f <= 16#100F# then return sxy(f - 16#1000#);
    elsif f >= 16#1010# and f <= 16#140F# then return ram(16#400# + (f - 16#1010#));
    elsif f >= 16#1410# and f <= 16#180F# then return ram(f - 16#1410#);
    elsif f = 16#1814#                    then return "0000000" & fl;
    else                                       return x"00";
    end if;
  end function;

  function hex(v : std_logic_vector) return string is
  begin
    return to_hstring(v);
  end function;

  function hex(n : natural) return string is
  begin
    return to_hstring(to_unsigned(n, 16));
  end function;
begin
  clk <= not clk after T / 2 when not done;

  -- ---------------- the emulated core's clock enable ----------------
  p_ph : process (clk)
  begin
    if rising_edge(clk) then
      if ph = 2 then ph <= "00"; else ph <= ph + 1; end if;
    end if;
  end process;
  ena_6 <= '1' when ph = 0 else '0';

  -- ---------------- the core's memories, as models ----------------
  -- main RAM: port A takes the game's writes at both strobe edges, port B is the mirror's
  u_ram : entity work.g20k_dpram
    generic map (AW => 12, DW => 8)
    port map (clk => clk, a_we => we_ram, a_addr => wr_addr, a_din => wr_data, a_dout => open,
              b_addr => ram_addr, b_dout => ram_q);
  -- the sprite x/y shadow, gated by ENA_6 as in pacman_video.vhd
  u_sxy : entity work.g20k_dpram
    generic map (AW => 4, DW => 8)
    port map (clk => clk, a_ce => ena_6, a_we => we_sxy, a_addr => wr_addr(3 downto 0),
              a_din => wr_data, a_dout => open, b_addr => sxy_addr, b_dout => sxy_q);
  -- the flip latch, bit 3 of control_reg
  p_flip : process (clk)
  begin
    if rising_edge(clk) and ena_6 = '1' and we_flip = '1' then
      flip <= wr_data(0);
    end if;
  end process;

  -- ---------------- the device under test ----------------
  u_mirror : entity work.pacman_mirror
    port map (
      clk => clk, ena_6 => ena_6, reset => reset, jr => jr_sl, frame_go => frame_go,
      ram_addr => ram_addr, ram_q => ram_q, sxy_addr => sxy_addr, sxy_q => sxy_q, flip => flip,
      we_ram => we_ram, we_sxy => we_sxy, we_flip => we_flip, wr_addr => wr_addr, wr_data => wr_data,
      snap_run => snap_run, snap_full => snap_full, snap_push => snap_push, snap_byte => snap_byte,
      snap_frame => snap_frame, snap_harv => snap_harv,
      log_we => log_we, log_addr => log_addr, log_data => log_data);

  -- ---------------- the testbench's picture of the RAM ----------------
  -- Updated at the P0 edges from the strobes, like the core's memories, and copied at the
  -- first edge after the window: a write in the P0 after the last P2 is outside the window
  -- and lands after the copy, as it lands after the harvest.
  p_exp : process (clk)
    variable harv_d : std_logic := '0';
  begin
    if rising_edge(clk) then
      assert not ((we_ram = '1' or we_sxy = '1' or we_flip = '1') and ena_6 = '0')
        report "emulator: a strobe outside P0" severity failure;
      if ena_6 = '1' then
        if we_ram = '1'  then exp_ram(to_integer(unsigned(wr_addr))) <= wr_data; end if;
        if we_sxy = '1'  then exp_sxy(to_integer(unsigned(wr_addr(3 downto 0)))) <= wr_data; end if;
        if we_flip = '1' then exp_flip <= wr_data(0); end if;
      end if;
      if harv_d = '1' and snap_harv = '0' then
        snap_ram <= exp_ram; snap_sxy <= exp_sxy; snap_flip <= exp_flip;
      end if;
      harv_d := snap_harv;
    end if;
  end process;

  -- ---------------- platform model: FIFO, reset, pops, delivered bytes ----------------
  snap_full <= '1' when fifo_cnt >= 8 else '0';
  p_platform : process (clk)
    variable cnt   : natural := 0;
    variable pop   : boolean;
    variable hold  : natural := 0;
    variable s1    : positive := 7;
    variable s2    : positive := 11;
    variable r     : real;
  begin
    if rising_edge(clk) then
      run_s <= run_s(0) & snap_run;
      cnt := fifo_cnt;
      -- the SPI side takes one byte per pop when one is there
      case pop_mode is
        when 0 => pop := true;
        when 1 => pop := false;
        when 2 =>
          pop := hold = 0;
          if hold = 0 then uniform(s1, s2, r); hold := integer(floor(r * 41.0)); else hold := hold - 1; end if;
        when others =>
          pop := hold = 0;
          if hold = 0 then hold := 21; else hold := hold - 1; end if;
      end case;
      if pop and cnt > 0 then cnt := cnt - 1; end if;
      if run_s(0) = '1' and run_s(1) = '0' then
        -- the top's reset clock: the write pointer starts over, a push here would be lost
        assert snap_push = '0' report "push in the top's reset clock" severity failure;
        cnt := 0;
        push_n <= 0;
      elsif snap_push = '1' then
        assert snap_full = '0' report "push while full" severity failure;
        assert push_n < N_MIRROR report "more than 6272 pushes in one transfer" severity failure;
        deliv(push_n) <= snap_byte;
        push_n <= push_n + 1;
        cnt := cnt + 1;
      end if;
      fifo_cnt <= cnt;
    end if;
  end process;

  -- ---------------- log collector (snap_log) and the emulator's expected log ----------------
  p_log : process (clk)
    variable lh_d : std_logic := '0';
    variable idx  : natural;
    variable fa   : integer;
  begin
    if rising_edge(clk) then
      if snap_harv = '1' and lh_d = '0' then
        log_n <= 0;                     -- the first window clock is skipped, as snap_log does
        exp_n <= 0;
      else
        if snap_harv = '1' and log_we = '1' then
          log_a(log_n) <= to_integer(unsigned(log_addr));
          log_d(log_n) <= log_data;
          log_n <= log_n + 1;
        end if;
        -- the emulator's own count: a write counts at its first strobe cycle when the
        -- window is open, the address from the table
        if ena_6 = '1' and emu_first = '1' and snap_harv = '1' then
          idx := to_integer(unsigned(wr_addr));
          if we_ram = '1' then fa := flat_addr(K_RAM, idx);
          elsif we_sxy = '1' then fa := flat_addr(K_SXY, idx mod 16);
          else fa := flat_addr(K_FLIP, 0);
          end if;
          if fa >= 0 then
            exp_a(exp_n) <= fa;
            if we_flip = '1' then exp_d(exp_n) <= "0000000" & wr_data(0); else exp_d(exp_n) <= wr_data; end if;
            exp_n <= exp_n + 1;
          end if;
        end if;
      end if;
      lh_d := snap_harv;
    end if;
  end process;

  -- ---------------- harvest monitor: one level per frame_go, 9268 clocks, right phase ----------------
  p_harv : process (clk)
    variable hm_d, fg1, fg2 : std_logic := '0';
  begin
    if rising_edge(clk) then
      if snap_harv = '1' and hm_d = '0' then
        harv_len <= 1;
        harv_rises <= harv_rises + 1;
        -- frame_go was high in the P0 two cycles before the first window cycle
        assert fg2 = '1' report "harvest did not start in the clock after the P1 following frame_go" severity failure;
        assert ph = 2 report "harvest did not start in a P2 cycle" severity failure;
      elsif snap_harv = '1' then
        harv_len <= harv_len + 1;
      elsif hm_d = '1' then
        last_len <= harv_len;
        harv_falls <= harv_falls + 1;
        assert harv_len = N_WINDOW
          report "window of " & integer'image(harv_len) & " clocks, expected " & integer'image(N_WINDOW)
          severity failure;
      end if;
      fg2 := fg1; fg1 := frame_go; hm_d := snap_harv;
    end if;
  end process;

  -- ---------------- stimulus ----------------
  p_stim : process
    variable errors   : natural := 0;
    variable mism     : natural := 0;
    variable frame0   : std_logic_vector(15 downto 0);
    variable n_before : natural;
    variable seq      : natural := 0;
    variable cases    : natural := 0;
    variable log_min, log_max, log_sum : natural := 0;

    procedure tick(n : natural := 1) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;

    -- to the start of the next P0 cycle (ph read before the edge is the old value)
    procedure at_p0 is
    begin
      loop
        wait until rising_edge(clk);
        exit when ph = 2;
      end loop;
    end procedure;

    procedure drive(k : kind_t; idx : natural; data : std_logic_vector(7 downto 0); strobe : boolean) is
    begin
      we_ram <= '0'; we_sxy <= '0'; we_flip <= '0';
      if strobe then
        case k is
          when K_RAM  => we_ram <= '1';  wr_addr <= std_logic_vector(to_unsigned(idx, 12));
          when K_SXY  => we_sxy <= '1';  wr_addr <= x"06" & std_logic_vector(to_unsigned(idx, 4));
          when K_FLIP => we_flip <= '1'; wr_addr <= x"003";
        end case;
        wr_data <= data;
      end if;
    end procedure;

    -- one Z80 write as the core presents it: strobes in two consecutive P0 cycles, the same
    -- address and data both times. Call at the start of a P0 cycle; returns at the start of
    -- the P1 after the second strobe cycle.
    procedure emu_write(k : kind_t; idx : natural; data : std_logic_vector(7 downto 0)) is
    begin
      drive(k, idx, data, true); emu_first <= '1';
      tick;
      drive(k, idx, data, false); emu_first <= '0';
      tick(2);
      drive(k, idx, data, true);
      tick;
      drive(k, idx, data, false);
    end procedure;

    -- after emu_write: gap strobe-free P0 cycles, then the start of the next P0
    procedure gap(n : natural) is
    begin
      tick(2 + 3 * n);
    end procedure;

    -- one frame_go pulse in the next P0 cycle; returns at the start of the P1 after it
    procedure pulse_frame_go is
    begin
      at_p0;
      frame_go <= '1';
      tick;
      frame_go <= '0';
    end procedure;

    -- wait for the harvest that is running or about to start to end
    procedure wait_harvest is
      variable n : natural;
    begin
      n := harv_falls;
      loop
        exit when harv_falls /= n;
        wait until rising_edge(clk);
      end loop;
    end procedure;

    -- a full transfer in the given pop pattern: snap_run up until 6272 pushes were counted
    procedure transfer(mode : natural) is
      variable guard : natural := 0;
    begin
      pop_mode <= mode;
      snap_run <= '1';
      -- the platform model clears push_n at the second edge after snap_run rises, as the top
      -- resets its FIFO; checking earlier would see the count of the previous transfer
      tick(2);
      loop
        tick;
        guard := guard + 1;
        exit when push_n = N_MIRROR;
        assert guard < 400000 report "transfer did not finish" severity failure;
      end loop;
      tick(4);
      snap_run <= '0';
      tick(6);
    end procedure;

    -- the delivered picture against the copy at the end of the window
    procedure check_image(what : string) is
      variable want : std_logic_vector(7 downto 0);
      variable n : natural := 0;
    begin
      for f in 0 to N_MIRROR - 1 loop
        want := flat_of(snap_ram, snap_sxy, snap_flip, f);
        if deliv(f) /= want then
          n := n + 1;
          if n <= 5 then
            report what & ": flat 0x" & hex(f) & " = 0x" & hex(deliv(f)) & ", expected 0x" & hex(want) severity error;
          end if;
        end if;
      end loop;
      if n > 0 then errors := errors + 1; end if;
      mism := n;
    end procedure;

    -- the Pico's rule: walk the log backwards, first hit per address, compare with the byte
    procedure check_oracle(what : string) is
      variable hit : std_logic_vector(0 to 16#187F#) := (others => '0');
      variable n : natural := 0;
    begin
      for i in log_n - 1 downto 0 loop
        assert log_a(i) <= 16#1814# report what & ": log address 0x" & hex(log_a(i)) & " outside the mirror" severity failure;
        if hit(log_a(i)) = '0' then
          hit(log_a(i)) := '1';
          if deliv(log_a(i)) /= log_d(i) then
            n := n + 1;
            if n <= 5 then
              report what & ": oracle flat 0x" & hex(log_a(i)) & " delivered 0x" & hex(deliv(log_a(i))) & ", logged 0x" & hex(log_d(i)) severity error;
            end if;
          end if;
        end if;
      end loop;
      if n > 0 then errors := errors + 1; end if;
      mism := mism + n;
    end procedure;

    -- the collected log against the emulator's expectation, entry by entry
    procedure check_log(what : string) is
    begin
      if log_n /= exp_n then
        report what & ": " & integer'image(log_n) & " log entries, the emulator counted " & integer'image(exp_n) severity error;
        errors := errors + 1;
      else
        for i in 0 to log_n - 1 loop
          if log_a(i) /= exp_a(i) or log_d(i) /= exp_d(i) then
            report what & ": log entry " & integer'image(i) & " = (0x" & hex(log_a(i)) & ", 0x" & hex(log_d(i)) &
                   "), expected (0x" & hex(exp_a(i)) & ", 0x" & hex(exp_d(i)) & ")" severity error;
            errors := errors + 1;
            exit;
          end if;
        end loop;
      end if;
      -- (d): nothing from the core-only RAM, nothing in the zero regions (Jr.: nothing past
      -- the Z80 RAM, which is where a flip entry would have to go)
      for i in 0 to log_n - 1 loop
        if JR then
          assert log_a(i) <= 16#100F#
            report what & ": log entry at zero region 0x" & hex(log_a(i)) severity failure;
        else
          assert not (log_a(i) < 16#0400# or (log_a(i) >= 16#0800# and log_a(i) < 16#1000#))
            report what & ": log entry at zero region 0x" & hex(log_a(i)) severity failure;
        end if;
      end loop;
    end procedure;

    procedure check_zero_regions(what : string) is
    begin
      if JR then
        for f in 16#1010# to N_MIRROR - 1 loop
          assert deliv(f) = x"00" report what & ": flat 0x" & hex(f) & " not zero" severity failure;
        end loop;
        return;
      end if;
      for f in 0 to 16#03FF# loop
        assert deliv(f) = x"00" report what & ": flat 0x" & hex(f) & " not zero" severity failure;
      end loop;
      for f in 16#0800# to 16#0FFF# loop
        assert deliv(f) = x"00" report what & ": flat 0x" & hex(f) & " not zero" severity failure;
      end loop;
      for f in 16#1810# to 16#1813# loop
        assert deliv(f) = x"00" report what & ": flat 0x" & hex(f) & " not zero" severity failure;
      end loop;
      for f in 16#1815# to 16#187F# loop
        assert deliv(f) = x"00" report what & ": flat 0x" & hex(f) & " not zero" severity failure;
      end loop;
    end procedure;

    -- (b): one race case. The write's first strobe lands on the P0 edge nearest to d clocks
    -- from the P2 edge at which the harvest writes shadow index k.
    procedure race_case(k : natural; d : integer) is
      variable r, cg, cw, o, m, last : integer;
      variable falls : natural;           -- harvests finished before this case
      variable kind : kind_t;
      variable idx  : natural;
      variable data : std_logic_vector(7 downto 0);
    begin
      -- the round that harvests k: Pac-Man 0x000..0x810 then 0xC00.., Jr. 0x000..0xFFF then
      -- the sprite x/y, which this sweep names 0x1000 + i
      if JR then r := k;
      elsif k <= 16#810# then r := k; else r := 16#811# + (k - 16#C00#); end if;
      -- P0 edges lie at offsets 1 mod 3 from a P2 edge: the nearest one to d
      m := integer(round(real(d - 1) / 3.0));
      o := 1 + 3 * m;
      cg := 6;                         -- the frame_go P0 is cycle 6 from t0
      cw := cg + 5 + 3 * r + o;        -- the first strobe cycle
      assert cw >= 0 and cw mod 3 = 0 report "race_case: bad cycle arithmetic" severity failure;
      if JR and k >= 16#1000# then kind := K_SXY; idx := k - 16#1000#; data := std_logic_vector(to_unsigned((seq * 29 + 17) mod 256, 8));
      elsif JR then kind := K_RAM; idx := k; data := std_logic_vector(to_unsigned((seq * 29 + 17) mod 256, 8));
      elsif k = 16#810# then kind := K_FLIP; idx := 0; data := x"00"; data(0) := not exp_flip;
      elsif k >= 16#800# then kind := K_SXY; idx := k - 16#800#; data := std_logic_vector(to_unsigned((seq * 29 + 17) mod 256, 8));
      else kind := K_RAM; idx := k; data := std_logic_vector(to_unsigned((seq * 29 + 17) mod 256, 8));
      end if;
      seq := seq + 1;
      if cw + 3 > cg then last := cw + 3; else last := cg; end if;
      falls := harv_falls;
      at_p0;
      for c in 0 to last loop
        if c = cg then frame_go <= '1'; else frame_go <= '0'; end if;
        if c = cw then
          drive(kind, idx, data, true); emu_first <= '1';
        elsif c = cw + 3 then
          drive(kind, idx, data, true); emu_first <= '0';
        else
          drive(kind, idx, data, false); emu_first <= '0';
        end if;
        tick;
      end loop;
      frame_go <= '0';
      drive(kind, idx, data, false); emu_first <= '0';
      -- the harvest of this case; a write placed after the window (the last index with a
      -- positive offset) lets the loop above outlast it, so count from before the loop
      while harv_falls = falls loop tick; end loop;
      transfer(0);
      check_image("(b) k=0x" & hex(k) & " d=" & integer'image(d));
      check_oracle("(b) k=0x" & hex(k) & " d=" & integer'image(d));
      if mism > 0 then
        report "(b) k=0x" & hex(k) & " d=" & integer'image(d) & ": " & integer'image(mism) & " mismatches" severity error;
      end if;
      cases := cases + 1;
    end procedure;

    -- the shadow indices of the race sweep (Jr.: the sprite x/y as 0x1000 + i)
    function sweep_list return nat_arr is
    begin
      if JR then
        return (16#000#, 16#001#, 16#7FF#, 16#800#, 16#BFF#, 16#C00#, 16#FFF#, 16#1000#, 16#1007#, 16#100F#);
      else
        return (16#000#, 16#001#, 16#3FF#, 16#400#, 16#7FF#, 16#800#, 16#80F#, 16#810#, 16#C00#, 16#FFF#);
      end if;
    end function;
    constant SWEEP_K : nat_arr(0 to 9) := sweep_list;
    variable kind : kind_t;
    variable idx  : natural;
    variable data : std_logic_vector(7 downto 0);
    variable n_go : natural;
    variable falls_c : natural;   -- harvests finished before a write stream
  begin
    tick(10);

    -- ---------------- fill the RAM with a known picture, no window open ----------------
    at_p0;
    for i in 0 to 4095 loop
      emu_write(K_RAM, i, std_logic_vector(to_unsigned((i * 13 + 5) mod 256, 8)));
      gap(2);
    end loop;
    for i in 0 to 15 loop
      emu_write(K_SXY, i, std_logic_vector(to_unsigned(16#10# + i, 8)));
      gap(2);
    end loop;
    emu_write(K_FLIP, 0, x"01");
    gap(2);
    tick(20);

    -- ---------------- (a) harvest without writes ----------------
    frame0 := snap_frame;
    n_before := harv_rises;
    pulse_frame_go;
    wait_harvest;
    assert harv_rises = n_before + 1 report "(a) no harvest" severity failure;
    assert unsigned(snap_frame) = unsigned(frame0) + 1 report "(a) snap_frame did not advance by one" severity failure;
    transfer(0);
    assert push_n = N_MIRROR report "(a) pushes" severity failure;
    check_image("(a)");
    check_oracle("(a)");
    assert log_n = 0 report "(a) log not empty" severity failure;
    check_zero_regions("(a)");
    report "(a) window " & integer'image(last_len) & " clocks, " & integer'image(push_n) & " pushes, " &
           integer'image(mism) & " mismatches, frame 0x" & hex(snap_frame);

    -- ---------------- (b) race sweep ----------------
    for ki in SWEEP_K'range loop
      for d in -9 to 9 loop
        race_case(SWEEP_K(ki), d);
      end loop;
    end loop;
    report "(b) " & integer'image(cases) & " race cases, window " & integer'image(last_len) & " clocks each";

    -- ---------------- (c), (d), (g) continuous write stream through a window ----------------
    -- a write every 12 clocks (two strobe P0 cycles, two strobe-free ones), denser than any
    -- Z80 program: back-to-back write cycles of a PUSH are 18 clocks apart, so a real window
    -- holds at most 281 entries against the platform's 512, here it holds several hundred
    -- more and the collector has no bound. The frame_go lies inside the stream, and now and
    -- then a 15-clock spacing makes the pair's position against the rounds alternate. Addresses cover every
    -- region including the core-only RAM, which must never appear in the log.
    n_before := harv_rises;
    falls_c := harv_falls;
    at_p0;
    for j in 0 to 900 loop
      if j mod 5 = 4 then kind := K_SXY; idx := j mod 16;
      elsif j mod 7 = 6 then kind := K_FLIP; idx := 0;
      else kind := K_RAM; idx := (j * 37 + 11) mod 4096;
      end if;
      data := std_logic_vector(to_unsigned((j * 7 + 3) mod 256, 8));
      if j = 10 then frame_go <= '1'; end if;
      emu_write(kind, idx, data);
      frame_go <= '0';
      if j mod 11 = 3 then gap(3); else gap(2); end if;
    end loop;
    assert harv_rises = n_before + 1 report "(c) no harvest" severity failure;
    -- the stream is longer than the window, the harvest ended inside it
    while harv_falls = falls_c loop tick; end loop;
    transfer(0);
    check_image("(c)");
    check_oracle("(c)");
    check_log("(c)/(g)");
    check_zero_regions("(d)");
    report "(c) window " & integer'image(last_len) & " clocks, " & integer'image(log_n) & " log entries (emulator " &
           integer'image(exp_n) & "), " & integer'image(push_n) & " pushes, " & integer'image(mism) & " mismatches";
    -- a second stream at random pops, so the delivery stalls on snap_full as on the device
    n_before := harv_rises;
    falls_c := harv_falls;
    at_p0;
    for j in 0 to 900 loop
      if j mod 3 = 2 then kind := K_SXY; idx := (j / 3) mod 16;
      elsif j mod 13 = 5 then kind := K_FLIP; idx := 0;
      else kind := K_RAM; idx := (j * 53 + 7) mod 4096;
      end if;
      data := std_logic_vector(to_unsigned((j * 11 + 5) mod 256, 8));
      if j = 25 then frame_go <= '1'; end if;
      emu_write(kind, idx, data);
      frame_go <= '0';
      gap(2);
    end loop;
    assert harv_rises = n_before + 1 report "(c2) no harvest" severity failure;
    while harv_falls = falls_c loop tick; end loop;
    transfer(2);
    check_image("(c2)");
    check_oracle("(c2)");
    check_log("(c2)/(g)");
    report "(c2) window " & integer'image(last_len) & " clocks, " & integer'image(log_n) & " log entries (emulator " &
           integer'image(exp_n) & "), " & integer'image(push_n) & " pushes, " & integer'image(mism) & " mismatches";

    -- ---------------- (e) aborted transfer, restarted ----------------
    pop_mode <= 3;
    snap_run <= '1';
    tick(400);
    snap_run <= '0';
    tick(30);
    transfer(3);
    check_image("(e)");
    report "(e) restart: " & integer'image(push_n) & " pushes after the abort, byte 0 = 0x" & hex(deliv(0)) &
           ", byte 0x400 = 0x" & hex(deliv(16#400#)) & ", " & integer'image(mism) & " mismatches";

    -- ---------------- (f) frame_go during a transfer ----------------
    pop_mode <= 3;
    frame0 := snap_frame;
    n_before := harv_rises;
    snap_run <= '1';
    tick(200);
    pulse_frame_go;
    tick(200);
    assert snap_harv = '0' and harv_rises = n_before report "(f) a harvest started during a transfer" severity failure;
    assert snap_frame = frame0 report "(f) frame_no changed" severity failure;
    -- let the transfer finish, then the next frame_go harvests
    loop
      tick;
      exit when push_n = N_MIRROR;
    end loop;
    tick(4);
    snap_run <= '0';
    tick(6);
    pulse_frame_go;
    wait_harvest;
    assert harv_rises = n_before + 1 report "(f) the harvest after the transfer did not run" severity failure;
    assert unsigned(snap_frame) = unsigned(frame0) + 1 report "(f) frame_no after the transfer" severity failure;
    transfer(0);
    check_image("(f)");
    report "(f) no harvest during the transfer, the next one ran: frame 0x" & hex(snap_frame);

    -- ---------------- verdict ----------------
    report "harvests " & integer'image(harv_rises) & ", every window " & integer'image(N_WINDOW) & " clocks";
    if errors = 0 then
      report "PASS";
    else
      report "FAIL: " & integer'image(errors) & " checks failed" severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture sim;
