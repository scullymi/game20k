-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file tb_pacman.vhd
--! @brief The Pac-Man core with pacman_mirror, wired as game_core.sv wires them, driven by
--!        a hand-assembled Z80 program.
--!
--! No game ROM is involved. The testbench does the wrapper's job in VHDL (the ena_6 divider,
--! the download port driven directly with RESET = 1, in0/in1 = FF, dipsw1 = C9, dipsw2 = FF,
--! every mod_* 0, the blankn delay and the vsync polarity), models the platform as
--! tb_mirror_unit does (FIFO, reset clock, pops, log collector), and watches the core's bus
--! through VHDL-2008 external names with an independent CPU write monitor: at the first
--! strobe cycle of every write (ena_6 and hcnt(1:0) = 00, the cycle the mirror logs) it
--! classifies the address as the FBNeo table does and updates an expected picture exp; at
--! the second strobe cycle it asserts that address and data are unchanged. Both sides count
--! a write at its first strobe cycle.
--!
--! The Z80 program: P1 fills 0x4000-0x4FFF with the low address byte; P2 writes the pattern
--! bytes of the FBNeo table (5A -> 4C00, C3 -> 4FFF, 11 -> 4000, 22 -> 47FF, i*11h -> 5060+i,
--! 01 -> 5003, 33 -> 4800 and 44 -> 4BFF into the core-only RAM); then it polls in0 bit 0 with
--! a watchdog kick until the testbench releases it into P3, the hammer loop: A to 4000, 4FFF,
--! 4C10, 5061, 5003, 4900 and the watchdog, INC A, repeat (105 T = 630 clocks, about 14
--! iterations per window). The watchdog counts vblanks regardless of c_int and would reset
--! the CPU after 255 frames, hence the kicks.
--!
--! Checks: T1 window shape (9268 clocks, one rise and one fall, the rise in the clock after
--! the P1 following frame_go, the fall two clocks after the vblank rise, frame_no + 1); T2
--! oracle (the log equals the monitor's entries one to one, none in the zero regions, both
--! strobe cycles carry the same address and data); T3 catch-up (cu_we >= 20 per window, one
--! at index 0 after its read, one at 0xFFF before its read, one at 0xC10 after its read); T4
--! the transfer after the window (6272 pushes, none in the reset clock or while full, byte k
--! = exp(k) at the end of the window, the literal FBNeo table on the first transfer, zeros
--! where FBNeo has none, snap_frame constant); T5 the header probe (8 pushes then a stall,
--! the next transfer starts at byte 0); T6 the skipped harvest (snap_run across a frame_go);
--! T7 a second window; T8 the video phase with a scaler model and an opaque sprite; T9 a
--! reset during a harvest. Ends with one line PASS, or a severity failure.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_pacman is
end entity tb_pacman;

architecture sim of tb_pacman is
  constant T         : time    := 53.872 ns;
  constant N_MIRROR  : natural := 6272;
  constant N_WINDOW  : natural := 9268;
  constant N_FRAME   : natural := 3 * 384 * 264;   -- clocks per frame
  constant BLANK_DLY : natural := 1;               -- as game_core.sv

  type byte_arr is array (natural range <>) of std_logic_vector(7 downto 0);
  type nat_arr  is array (natural range <>) of natural;

  signal clk   : std_logic := '0';
  signal done  : boolean   := false;
  signal ph    : unsigned(1 downto 0) := "00";
  signal ena_6 : std_logic;
  signal rst   : std_logic := '1';

  -- download port and inputs
  signal dn_addr : std_logic_vector(15 downto 0) := (others => '0');
  signal dn_data : std_logic_vector(7 downto 0)  := (others => '0');
  signal dn_wr   : std_logic := '0';
  signal in0     : std_logic_vector(7 downto 0) := x"FF";

  -- core outputs
  signal o_r, o_g : std_logic_vector(2 downto 0);
  signal o_b      : std_logic_vector(1 downto 0);
  signal o_hs, o_vs, o_hb, o_vb : std_logic;
  signal o_audio  : std_logic_vector(9 downto 0);

  -- core to mirror
  signal hs_address   : std_logic_vector(11 downto 0);
  signal hs_data_out  : std_logic_vector(7 downto 0);
  signal mir_sxy_addr : std_logic_vector(3 downto 0);
  signal mir_sxy_data : std_logic_vector(7 downto 0);
  signal mir_flip, mir_we_ram, mir_we_sxy, mir_we_flip, mir_frame_go : std_logic;
  signal mir_wr_addr  : std_logic_vector(11 downto 0);
  signal mir_wr_data  : std_logic_vector(7 downto 0);

  -- platform side
  signal snap_run, snap_full, snap_push, snap_harv, log_we : std_logic := '0';
  signal snap_byte, log_data : std_logic_vector(7 downto 0);
  signal snap_frame, log_addr : std_logic_vector(15 downto 0);

  -- the wrapper's video signals
  signal blankn_live, video_blankn, video_vs : std_logic;
  signal blankn_q : std_logic_vector(1 downto 0) := "00";

  -- the monitor's expected picture and its copy at the end of the window
  signal exp      : byte_arr(0 to N_MIRROR - 1) := (others => x"00");
  signal exp_snap : byte_arr(0 to N_MIRROR - 1) := (others => x"00");
  signal exp_a    : nat_arr(0 to 1023) := (others => 0);
  signal exp_d    : byte_arr(0 to 1023) := (others => x"00");
  signal exp_n    : natural := 0;
  signal pair_errors : natural := 0;

  -- platform model
  signal pop_mode : natural := 0;
  signal fifo_cnt : natural := 0;
  signal run_s    : std_logic_vector(1 downto 0) := "00";
  signal push_n   : natural := 0;
  signal push_total : natural := 0;
  signal frame_first, frame_last : std_logic_vector(15 downto 0) := (others => '0');
  signal deliv    : byte_arr(0 to N_MIRROR - 1) := (others => x"00");

  -- log collector
  signal log_a : nat_arr(0 to 1023) := (others => 0);
  signal log_d : byte_arr(0 to 1023) := (others => x"00");
  signal log_n : natural := 0;

  -- harvest monitor
  signal harv_rises, harv_falls, harv_len, last_len : natural := 0;
  signal go_to_int : natural := 0;    -- clocks from the frame_go P0 edge to the vblank rise

  -- catch-up monitor (T3), per window
  signal cu_total, cu_zero_after, cu_fff_before, cu_c10_after : natural := 0;

  -- video monitor (T8)
  signal t8_arm  : boolean := false;
  signal t8_done : boolean := false;
  signal t8_lines, t8_offset, t8_vs_low, t8_vs_to_line, t8_sprite : natural := 0;
  signal t8_errors : natural := 0;

  -- The test program, Z80 code assembled by hand (addresses in the comments).
  type prog_t is array (natural range <>) of std_logic_vector(7 downto 0);
  constant PROG : prog_t := (
    -- P1 fill: 0000 LD HL,4000h / 0003 LD (HL),L / INC HL / LD A,H / CP 50h / JR NZ,0003h
    x"21", x"00", x"40", x"75", x"23", x"7C", x"FE", x"50", x"20", x"F9",
    -- P2 patterns: 000A LD A,5Ah / LD (4C00h),A / LD A,C3h / LD (4FFFh),A
    x"3E", x"5A", x"32", x"00", x"4C", x"3E", x"C3", x"32", x"FF", x"4F",
    -- 0014 LD A,11h / LD (4000h),A / LD A,22h / LD (47FFh),A
    x"3E", x"11", x"32", x"00", x"40", x"3E", x"22", x"32", x"FF", x"47",
    -- 001E LD HL,5060h / LD B,10h / XOR A / 0024 LD (HL),A / ADD A,11h / INC HL / DJNZ 0024h
    x"21", x"60", x"50", x"06", x"10", x"AF", x"77", x"C6", x"11", x"23", x"10", x"FA",
    -- 002A LD A,01h / LD (5003h),A / LD A,33h / LD (4800h),A / LD A,44h / LD (4BFFh),A / NOP
    x"3E", x"01", x"32", x"03", x"50", x"3E", x"33", x"32", x"00", x"48", x"3E", x"44", x"32", x"FF", x"4B", x"00",
    -- poll: 003A LD A,(5000h) / LD (50C0h),A / AND 01h / JR NZ,003Ah
    x"3A", x"00", x"50", x"32", x"C0", x"50", x"E6", x"01", x"20", x"F6",
    -- P3 hammer: 0044 XOR A / 0045 LD (4000h),A / LD (4FFFh),A / LD (4C10h),A / LD (5061h),A
    x"AF", x"32", x"00", x"40", x"32", x"FF", x"4F", x"32", x"10", x"4C", x"32", x"61", x"50",
    -- 0051 LD (5003h),A / LD (4900h),A / LD (50C0h),A / INC A / JP 0045h
    x"32", x"03", x"50", x"32", x"00", x"49", x"32", x"C0", x"50", x"3C", x"C3", x"45", x"00");
  constant A_POLL   : std_logic_vector(15 downto 0) := x"0040";   -- inside the poll loop
  constant A_HAMMER : std_logic_vector(15 downto 0) := x"0045";   -- first hammer store

  -- literal FBNeo positions after P2 (mirror-map.md section 1), no tb function involved
  type chk_t is record
    ra  : natural;
    val : std_logic_vector(7 downto 0);
  end record;
  type chk_list_t is array (natural range <>) of chk_t;
  constant LIT_TABLE : chk_list_t := (
    (16#0400#, x"5A"), (16#07FF#, x"C3"), (16#1410#, x"11"), (16#140F#, x"22"),
    (16#1000#, x"00"), (16#1001#, x"11"), (16#1002#, x"22"), (16#1003#, x"33"),
    (16#1004#, x"44"), (16#1005#, x"55"), (16#1006#, x"66"), (16#1007#, x"77"),
    (16#1008#, x"88"), (16#1009#, x"99"), (16#100A#, x"AA"), (16#100B#, x"BB"),
    (16#100C#, x"CC"), (16#100D#, x"DD"), (16#100E#, x"EE"), (16#100F#, x"FF"),
    (16#1814#, x"01"),
    (16#0000#, x"00"), (16#0BFF#, x"00"), (16#0C00#, x"00"), (16#1810#, x"00"),
    (16#1815#, x"00"), (16#187F#, x"00"),
    -- from the fill: the low address byte
    (16#0401#, x"01"), (16#07FE#, x"FE"), (16#1011#, x"01"), (16#140E#, x"FE"),
    (16#1411#, x"01"), (16#180F#, x"FF"));

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

  -- ---------------- the wrapper's clock enable ----------------
  p_ph : process (clk)
  begin
    if rising_edge(clk) then
      if ph = 2 then ph <= "00"; else ph <= ph + 1; end if;
    end if;
  end process;
  ena_6 <= '1' when ph = 0 else '0';

  -- ---------------- the core, wired as game_core.sv wires it ----------------
  u_core : entity work.PACMAN
    port map (
      O_VIDEO_R => o_r, O_VIDEO_G => o_g, O_VIDEO_B => o_b,
      O_HSYNC => o_hs, O_VSYNC => o_vs, O_HBLANK => o_hb, O_VBLANK => o_vb,
      O_AUDIO => o_audio,
      in0 => in0, in1 => x"FF", dipsw1 => x"C9", dipsw2 => x"FF",
      mod_plus => '0', mod_jmpst => '0', mod_bird => '0', mod_mrtnt => '0', mod_ms => '0',
      mod_woodp => '0', mod_eeek => '0', mod_glob => '0', mod_alib => '0', mod_ponp => '0',
      mod_van => '0', mod_dshop => '0', mod_club => '0',
      flip_screen => '0', h_offset => "000", v_offset => "000",
      dn_addr => dn_addr, dn_data => dn_data, dn_wr => dn_wr,
      pause => '0',
      hs_address => hs_address, hs_data_in => x"00", hs_data_out => hs_data_out,
      hs_write_enable => '0', hs_access_read => '0', hs_access_write => '0',
      mir_sxy_addr => mir_sxy_addr, mir_sxy_data => mir_sxy_data, mir_flip => mir_flip,
      mir_we_ram => mir_we_ram, mir_we_sxy => mir_we_sxy, mir_we_flip => mir_we_flip,
      mir_wr_addr => mir_wr_addr, mir_wr_data => mir_wr_data, mir_frame_go => mir_frame_go,
      RESET => rst, CLK => clk, ENA_6 => ena_6, ENA_4 => '0', ENA_1M79 => '0');

  u_mirror : entity work.pacman_mirror
    port map (
      clk => clk, ena_6 => ena_6, reset => rst, frame_go => mir_frame_go,
      ram_addr => hs_address, ram_q => hs_data_out, sxy_addr => mir_sxy_addr, sxy_q => mir_sxy_data,
      flip => mir_flip, we_ram => mir_we_ram, we_sxy => mir_we_sxy, we_flip => mir_we_flip,
      wr_addr => mir_wr_addr, wr_data => mir_wr_data,
      snap_run => snap_run, snap_full => snap_full, snap_push => snap_push, snap_byte => snap_byte,
      snap_frame => snap_frame, snap_harv => snap_harv,
      log_we => log_we, log_addr => log_addr, log_data => log_data);

  -- the wrapper's video path
  blankn_live <= not (o_hb or o_vb);
  p_blankn : process (clk)
  begin
    if rising_edge(clk) then blankn_q <= blankn_q(0) & blankn_live; end if;
  end process;
  video_blankn <= blankn_live when BLANK_DLY = 0 else blankn_q(BLANK_DLY - 1);
  video_vs <= not o_vs;

  -- ---------------- CPU write monitor: the expected picture and log ----------------
  p_monitor : process (clk)
    alias cpu_addr     is << signal .tb_pacman.u_core.cpu_addr : std_logic_vector(15 downto 0) >>;
    alias cpu_data_out is << signal .tb_pacman.u_core.cpu_data_out : std_logic_vector(7 downto 0) >>;
    alias cpu_wr_l     is << signal .tb_pacman.u_core.cpu_wr_l : std_logic >>;
    alias cpu_mreq_l   is << signal .tb_pacman.u_core.cpu_mreq_l : std_logic >>;
    alias cpu_rfsh_l   is << signal .tb_pacman.u_core.cpu_rfsh_l : std_logic >>;
    alias hcnt         is << signal .tb_pacman.u_core.hcnt : std_logic_vector(8 downto 0) >>;
    variable wr      : boolean;
    variable a       : natural;
    variable flat    : integer;
    variable d       : std_logic_vector(7 downto 0);
    variable active  : boolean := false;
    variable a_first : std_logic_vector(15 downto 0);
    variable d_first : std_logic_vector(7 downto 0);
    variable harv_d  : std_logic := '0';
  begin
    if rising_edge(clk) then
      if snap_harv = '1' and harv_d = '0' then
        exp_n <= 0;
      end if;
      if ena_6 = '1' then
        wr := cpu_mreq_l = '0' and cpu_wr_l = '0' and cpu_rfsh_l = '1' and cpu_addr(14) = '1';
        if hcnt(1 downto 0) = "00" then
          active := wr;
          if wr then
            a_first := cpu_addr; d_first := cpu_data_out;
            a := to_integer(unsigned(cpu_addr(11 downto 0)));
            d := cpu_data_out;
            flat := -1;
            if cpu_addr(12) = '0' then
              -- the 4 KB RAM, FBNeo's regions; index 0x800-0xBFF is core-only and dropped
              if    a >= 16#C00# then flat := 16#0400# + (a - 16#C00#);
              elsif a >= 16#800# then flat := -1;
              elsif a >= 16#400# then flat := 16#1010# + (a - 16#400#);
              else                    flat := 16#1410# + a;
              end if;
            elsif cpu_addr(15 downto 4) = x"506" then
              flat := 16#1000# + to_integer(unsigned(cpu_addr(3 downto 0)));
            elsif cpu_addr(15 downto 6) = "0101000000" and cpu_addr(2 downto 0) = "011" then
              flat := 16#1814#; d := "0000000" & cpu_data_out(0);
            end if;
            if flat >= 0 then
              exp(flat) <= d;
              if snap_harv = '1' then
                exp_a(exp_n) <= flat; exp_d(exp_n) <= d; exp_n <= exp_n + 1;
              end if;
            end if;
          end if;
        elsif hcnt(1 downto 0) = "01" then
          -- the second strobe cycle: the same write, the same address and data
          if active then
            if not wr or cpu_addr /= a_first or cpu_data_out /= d_first then
              pair_errors <= pair_errors + 1;
              report "T2: the second strobe cycle differs from the first at 0x" & hex(a_first) severity error;
            end if;
          elsif wr then
            pair_errors <= pair_errors + 1;
            report "T2: a write strobe in the 01 cycle without one in the 00 cycle, 0x" & hex(cpu_addr) severity error;
          end if;
          active := false;
        end if;
      end if;
      -- the picture at the end of the window: copied at the first edge after the fall
      if harv_d = '1' and snap_harv = '0' then
        exp_snap <= exp;
      end if;
      harv_d := snap_harv;
    end if;
  end process;

  -- ---------------- platform model ----------------
  snap_full <= '1' when fifo_cnt >= 8 else '0';
  p_platform : process (clk)
    variable cnt  : natural := 0;
    variable pop  : boolean;
    variable hold : natural := 0;
    variable s1   : positive := 5;
    variable s2   : positive := 23;
    variable r    : real;
  begin
    if rising_edge(clk) then
      run_s <= run_s(0) & snap_run;
      cnt := fifo_cnt;
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
        assert snap_push = '0' report "push in the top's reset clock" severity failure;
        cnt := 0;
        push_n <= 0;
        push_total <= 0;
      elsif snap_push = '1' then
        assert snap_full = '0' report "push while full" severity failure;
        assert push_n < N_MIRROR report "more than 6272 pushes in one transfer" severity failure;
        deliv(push_n) <= snap_byte;
        if push_n = 0 then frame_first <= snap_frame; end if;
        frame_last <= snap_frame;
        push_n <= push_n + 1;
        push_total <= push_total + 1;
        cnt := cnt + 1;
      end if;
      fifo_cnt <= cnt;
    end if;
  end process;

  -- ---------------- log collector, as snap_log ----------------
  p_log : process (clk)
    variable lh_d : std_logic := '0';
  begin
    if rising_edge(clk) then
      if snap_harv = '1' and lh_d = '0' then
        log_n <= 0;
      elsif snap_harv = '1' and log_we = '1' then
        log_a(log_n) <= to_integer(unsigned(log_addr));
        log_d(log_n) <= log_data;
        log_n <= log_n + 1;
      end if;
      lh_d := snap_harv;
    end if;
  end process;

  -- ---------------- harvest monitor (T1) ----------------
  p_harv : process (clk)
    variable hm_d, fg1, fg2 : std_logic := '0';
    variable vb1, vb2, vb3  : std_logic := '0';
    variable since_go       : natural := 0;
    variable go_seen        : boolean := false;
  begin
    if rising_edge(clk) then
      -- clocks from the frame_go P0 edge to the vblank rise, independent of the mirror
      if mir_frame_go = '1' then
        go_seen := true; since_go := 0;
      elsif go_seen then
        since_go := since_go + 1;
        if o_vb = '1' and vb1 = '0' then
          go_to_int <= since_go;
          go_seen := false;
        end if;
      end if;
      if snap_harv = '1' and hm_d = '0' then
        harv_len <= 1;
        harv_rises <= harv_rises + 1;
        assert fg2 = '1' report "T1: harvest did not start in the clock after the P1 following frame_go" severity failure;
        assert ph = 2 report "T1: harvest did not start in a P2 cycle" severity failure;
      elsif snap_harv = '1' then
        harv_len <= harv_len + 1;
      elsif hm_d = '1' then
        last_len <= harv_len;
        harv_falls <= harv_falls + 1;
        assert harv_len = N_WINDOW
          report "T1: window of " & integer'image(harv_len) & " clocks, expected " & integer'image(N_WINDOW)
          severity failure;
        -- the window ended two clocks after the interrupt edge: vblank has been high for
        -- exactly two cycles before the fall edge, three at this detection edge
        assert o_vb = '1' and vb1 = '1' and vb2 = '1' and vb3 = '0'
          report "T1: the window did not end two clocks after the vblank rise" severity failure;
      end if;
      vb3 := vb2; vb2 := vb1; vb1 := o_vb;
      fg2 := fg1; fg1 := mir_frame_go; hm_d := snap_harv;
    end if;
  end process;

  -- ---------------- catch-up monitor (T3) ----------------
  p_cu : process (clk)
    alias cu_we    is << signal .tb_pacman.u_mirror.cu_we : std_logic >>;
    alias cu_addr  is << signal .tb_pacman.u_mirror.cu_addr : std_logic_vector(11 downto 0) >>;
    alias hw_we    is << signal .tb_pacman.u_mirror.hw_we : std_logic >>;
    alias hidx_d   is << signal .tb_pacman.u_mirror.hidx_d : unsigned(11 downto 0) >>;
    variable read_done : std_logic_vector(0 to 4095) := (others => '0');
    variable hm_d : std_logic := '0';
    variable a : natural;
  begin
    if rising_edge(clk) then
      if snap_harv = '1' and hm_d = '0' then
        read_done := (others => '0');
        cu_total <= 0; cu_zero_after <= 0; cu_fff_before <= 0; cu_c10_after <= 0;
      end if;
      if hw_we = '1' then
        read_done(to_integer(hidx_d)) := '1';    -- this index was read at the previous edge
      end if;
      if cu_we = '1' then
        assert snap_harv = '1' report "T3: cu_we outside the window" severity failure;
        a := to_integer(unsigned(cu_addr));
        cu_total <= cu_total + 1;
        if a = 0       and read_done(a) = '1' then cu_zero_after <= cu_zero_after + 1; end if;
        if a = 16#FFF# and read_done(a) = '0' then cu_fff_before <= cu_fff_before + 1; end if;
        if a = 16#C10# and read_done(a) = '1' then cu_c10_after <= cu_c10_after + 1; end if;
      end if;
      hm_d := snap_harv;
    end if;
  end process;

  -- ---------------- audio: silent without a sound write ----------------
  p_audio : process (clk)
    variable n : natural := 0;
  begin
    if rising_edge(clk) then
      if rst = '0' then
        if n < 100 then n := n + 1;
        else assert o_audio = "0000000000" report "audio not silent" severity failure;
        end if;
      end if;
    end if;
  end process;

  -- ---------------- video monitor (T8): the scaler's sampling on one frame ----------------
  p_video : process (clk)
    alias video_op_sel is << signal .tb_pacman.u_core.u_video.video_op_sel : std_logic >>;
    variable vs_d, bl_d, hb_d, p1 : std_logic := '0';
    variable armed, in_frame : boolean := false;
    variable sph      : natural := 0;
    variable x        : natural := 0;
    variable lines    : natural := 0;
    variable samples  : natural := 0;
    variable rgb, rgb_d1 : std_logic_vector(7 downto 0) := (others => '0');
    variable hb_cnt   : integer := -1;
    variable offset   : integer := -1;
    variable vs_low   : natural := 0;
    variable vs_cnt   : natural := 0;
    variable sprite   : natural := 0;
    variable errs     : natural := 0;
  begin
    if rising_edge(clk) then
      rgb := o_r & o_g & o_b;
      -- O_HBLANK and O_VBLANK change only at ena_6 edges: visible in the P1 cycle
      if armed and (o_hb /= hb_d or o_vb /= vs_d) then
        null;
      end if;
      if t8_arm and not armed then armed := true; in_frame := false; end if;
      if armed then
        assert not (o_hb /= hb_d) or p1 = '1' report "T8: O_HBLANK changed outside an ena_6 edge" severity failure;
        if video_vs = '0' then vs_low := vs_low + 1; end if;
        vs_cnt := vs_cnt + 1;
        if video_vs = '1' and vs_d = '0' then
          -- rising edge of the vsync pulse: the frame boundary the scaler arms on
          if in_frame then
            t8_lines <= lines; t8_vs_low <= vs_low; t8_errors <= errs; t8_sprite <= sprite;
            t8_done <= true; armed := false;
          else
            in_frame := true; lines := 0; vs_low := 0; vs_cnt := 0; sprite := 0; errs := 0;
          end if;
        end if;
        if in_frame then
          if video_blankn = '1' and bl_d = '0' then
            -- start of a visible line
            if lines = 0 then t8_vs_to_line <= vs_cnt; end if;
            if lines > 0 and samples /= 288 then
              errs := errs + 1;
              report "T8: line " & integer'image(lines - 1) & " had " & integer'image(samples) & " samples" severity error;
            end if;
            lines := lines + 1; sph := 0; x := 0; samples := 0;
          elsif video_blankn = '1' then
            if sph = 1 and x < 288 then
              -- the scaler's sample edge: the RGB register must be one clean pixel, i.e. the
              -- same value it held one clock earlier
              samples := samples + 1;
              if rgb /= rgb_d1 then
                errs := errs + 1;
                if errs <= 5 then
                  report "T8: RGB unstable at line " & integer'image(lines - 1) & " x " & integer'image(x) severity error;
                end if;
              end if;
              if video_op_sel = '1' then sprite := sprite + 1; end if;
            end if;
            if sph = 2 then sph := 0; x := x + 1; else sph := sph + 1; end if;
          end if;
          -- offset from the O_HBLANK fall to the first RGB change, per line
          if o_hb = '0' and hb_d = '1' then hb_cnt := 0;
          elsif hb_cnt >= 0 then
            hb_cnt := hb_cnt + 1;
            if rgb /= rgb_d1 then
              if offset < 0 then offset := hb_cnt; t8_offset <= hb_cnt; end if;
              if hb_cnt /= offset then
                errs := errs + 1;
                report "T8: RGB changed " & integer'image(hb_cnt) & " clocks after the O_HBLANK fall, first line said " & integer'image(offset) severity error;
              end if;
              hb_cnt := -1;
            end if;
          end if;
        end if;
      end if;
      rgb_d1 := rgb;
      vs_d := video_vs; bl_d := video_blankn; hb_d := o_hb; p1 := ena_6;
    end if;
  end process;

  -- ---------------- stimulus ----------------
  p_stim : process
    alias cpu_addr is << signal .tb_pacman.u_core.cpu_addr : std_logic_vector(15 downto 0) >>;
    alias cpu_m1_l is << signal .tb_pacman.u_core.cpu_m1_l : std_logic >>;
    alias cpu_mreq_l_s is << signal .tb_pacman.u_core.cpu_mreq_l : std_logic >>;
    alias cpu_rfsh_l_s is << signal .tb_pacman.u_core.cpu_rfsh_l : std_logic >>;
    variable errors : natural := 0;
    variable mism   : natural := 0;
    variable frame0 : std_logic_vector(15 downto 0);
    variable n_before : natural;
    variable seen   : boolean;
    variable win    : natural := 0;
    variable cu_t, cu_z, cu_f, cu_c : natural;

    procedure tick(n : natural := 1) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure at_p0 is
    begin
      loop
        wait until rising_edge(clk);
        exit when ph = 2;
      end loop;
    end procedure;

    procedure download(addr : natural; data : std_logic_vector(7 downto 0)) is
    begin
      dn_addr <= std_logic_vector(to_unsigned(addr, 16)); dn_data <= data; dn_wr <= '1';
      tick;
      dn_wr <= '0';
      tick;
    end procedure;

    procedure wait_addr(a : std_logic_vector(15 downto 0); limit : natural; what : string) is
      variable ok : boolean := false;
    begin
      for n in 0 to limit loop
        tick;
        -- an opcode fetch at that address: M1 with MREQ, not a refresh cycle, whose address
        -- {I, R} can show any low value while the program runs elsewhere
        if cpu_addr = a and cpu_m1_l = '0' and cpu_mreq_l_s = '0' and cpu_rfsh_l_s = '1' then
          ok := true; exit;
        end if;
      end loop;
      assert ok report what & ": the CPU never reached 0x" & hex(a) severity failure;
    end procedure;

    procedure wait_harvest is
      variable n : natural;
    begin
      n := harv_falls;
      loop
        exit when harv_falls /= n;
        wait until rising_edge(clk);
      end loop;
    end procedure;

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

    procedure check_image(what : string) is
      variable n : natural := 0;
    begin
      for f in 0 to N_MIRROR - 1 loop
        if deliv(f) /= exp_snap(f) then
          n := n + 1;
          if n <= 5 then
            report what & ": flat 0x" & hex(f) & " = 0x" & hex(deliv(f)) & ", expected 0x" & hex(exp_snap(f)) severity error;
          end if;
        end if;
      end loop;
      if n > 0 then errors := errors + 1; end if;
      mism := n;
      assert frame_first = frame_last report what & ": snap_frame changed during the transfer" severity failure;
      assert push_n = N_MIRROR report what & ": " & integer'image(push_n) & " pushes" severity failure;
    end procedure;

    procedure check_oracle(what : string) is
      variable hit : std_logic_vector(0 to 16#187F#) := (others => '0');
      variable n : natural := 0;
    begin
      for i in log_n - 1 downto 0 loop
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

    procedure check_log(what : string) is
    begin
      if log_n /= exp_n then
        report what & ": " & integer'image(log_n) & " log entries, the monitor counted " & integer'image(exp_n) severity error;
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
      for i in 0 to log_n - 1 loop
        assert not (log_a(i) < 16#0400# or (log_a(i) >= 16#0800# and log_a(i) < 16#1000#))
          report what & ": log entry in a zero region 0x" & hex(log_a(i)) severity failure;
      end loop;
    end procedure;

    procedure check_zeros(what : string) is
    begin
      assert deliv(16#0000#) = x"00" and deliv(16#0BFF#) = x"00" and deliv(16#0C00#) = x"00"
        report what & ": zero region not zero" severity failure;
      for f in 16#1810# to 16#1813# loop
        assert deliv(f) = x"00" report what & ": flat 0x" & hex(f) & " not zero" severity failure;
      end loop;
      for f in 16#1815# to 16#187F# loop
        assert deliv(f) = x"00" report what & ": flat 0x" & hex(f) & " not zero" severity failure;
      end loop;
    end procedure;

    -- T1..T4 on one window of the hammer loop
    procedure window_checks(what : string; mode : natural) is
    begin
      frame0 := snap_frame;
      n_before := harv_rises;
      wait_harvest;
      assert harv_rises = n_before + 1 report what & ": rises" severity failure;
      assert unsigned(snap_frame) = unsigned(frame0) + 1 report what & ": frame_no" severity failure;
      cu_t := cu_total; cu_z := cu_zero_after; cu_f := cu_fff_before; cu_c := cu_c10_after;
      transfer(mode);
      check_image(what & " T4");
      check_oracle(what & " T4");
      check_log(what & " T2");
      check_zeros(what & " T4");
      assert deliv(16#1814#) = exp_snap(16#1814#) report what & ": flip byte" severity failure;
      assert cu_t >= 20 report what & " T3: only " & integer'image(cu_t) & " catch-ups" severity failure;
      assert cu_z >= 1 report what & " T3: no catch-up at index 0 after its read" severity failure;
      assert cu_f >= 1 report what & " T3: no catch-up at index 0xFFF before its read" severity failure;
      assert cu_c >= 1 report what & " T3: no catch-up at index 0xC10 after its read" severity failure;
      report what & ": window " & integer'image(last_len) & " clocks, go->int " & integer'image(go_to_int) &
             ", log " & integer'image(log_n) & " (monitor " & integer'image(exp_n) & "), catch-ups " &
             integer'image(cu_t) & " (idx0 after " & integer'image(cu_z) & ", FFF before " & integer'image(cu_f) &
             ", C10 after " & integer'image(cu_c) & "), pushes " & integer'image(push_n) & ", mismatches " &
             integer'image(mism) & ", flip 0x" & hex(deliv(16#1814#)) & ", frame 0x" & hex(snap_frame);
    end procedure;
  begin
    -- ---------------- download: the program, then the PROMs for T8 ----------------
    tick(5);
    for i in PROG'range loop
      download(i, PROG(i));
    end loop;
    -- palette 7f: 16 distinct nonzero bytes; colour 4a: identity; char ROM: 0xA5 so that
    -- neighbouring pixels differ (2, 1, 2, 1 ...) and every sprite pixel is opaque
    for i in 0 to 15 loop
      download(16#C300# + i, std_logic_vector(to_unsigned(16#11# * (i + 1) mod 256 + (i / 15), 8)));
    end loop;
    for i in 0 to 255 loop
      download(16#C100# + i, std_logic_vector(to_unsigned(i, 8)));
    end loop;
    for i in 0 to 8191 loop
      download(16#8000# + i, x"A5");
    end loop;
    tick(10);
    rst <= '0';
    report "program loaded, reset released at " & time'image(now);

    -- ---------------- P1 and P2 run, the CPU parks in the poll loop ----------------
    wait_addr(A_POLL, 1500000, "P1/P2");
    report "CPU in the poll loop at " & time'image(now);
    tick(200);

    -- ---------------- the first window with the RAM at rest: T1, T4 literal table ----------------
    frame0 := snap_frame;
    n_before := harv_rises;
    wait_harvest;
    assert unsigned(snap_frame) = unsigned(frame0) + 1 report "first window: frame_no" severity failure;
    transfer(0);
    check_image("first T4");
    check_zeros("first T4");
    for k in LIT_TABLE'range loop
      if deliv(LIT_TABLE(k).ra) /= LIT_TABLE(k).val then
        errors := errors + 1;
        report "first T4: literal flat 0x" & hex(LIT_TABLE(k).ra) & " = 0x" & hex(deliv(LIT_TABLE(k).ra)) &
               ", expected 0x" & hex(LIT_TABLE(k).val) severity error;
      end if;
    end loop;
    report "first window: " & integer'image(last_len) & " clocks, go->int " & integer'image(go_to_int) & ", log " &
           integer'image(log_n) & ", pushes " & integer'image(push_n) & ", mismatches " & integer'image(mism) &
           ", literal table " & integer'image(LIT_TABLE'length) & " positions checked";

    -- ---------------- release the CPU into the hammer loop ----------------
    in0 <= x"FE";
    wait_addr(A_HAMMER, 200000, "P3");
    in0 <= x"FF";
    tick(2000);

    -- ---------------- T1..T4 window 1, transfer at line speed ----------------
    window_checks("window 1", 3);

    -- ---------------- T5 header probe: 20 us without a pop, then a full transfer ----------------
    wait_harvest;
    pop_mode <= 1;
    snap_run <= '1';
    tick(371);
    assert push_total = 8 report "T5: " & integer'image(push_total) & " pushes into the probe, expected 8" severity failure;
    assert snap_full = '1' report "T5: FIFO not full" severity failure;
    snap_run <= '0';
    tick(10);
    transfer(0);
    check_image("T5");
    report "T5: probe took 8 pushes and stalled, the transfer after it delivered " & integer'image(push_n) &
           " bytes, " & integer'image(mism) & " mismatches";

    -- ---------------- T6 skipped harvest: snap_run across a frame_go ----------------
    loop
      tick;
      exit when mir_frame_go = '1';
    end loop;
    tick(N_FRAME - 100);
    frame0 := snap_frame;
    n_before := harv_rises;
    pop_mode <= 1;
    snap_run <= '1';
    tick(400);
    snap_run <= '0';
    tick(N_WINDOW);
    assert harv_rises = n_before report "T6: a harvest started during the probe" severity failure;
    assert snap_frame = frame0 report "T6: frame_no changed" severity failure;
    report "T6: no harvest while snap_run covered frame_go, frame 0x" & hex(snap_frame);

    -- ---------------- T7 second window, random pops ----------------
    window_checks("window 2", 2);

    -- ---------------- T8 video phase ----------------
    t8_arm <= true;
    loop
      tick(1000);
      exit when t8_done;
    end loop;
    assert t8_lines = 224 report "T8: " & integer'image(t8_lines) & " visible lines, expected 224" severity failure;
    assert t8_vs_low = 8 * 384 * 3 report "T8: vs low for " & integer'image(t8_vs_low) & " clocks" severity failure;
    assert t8_errors = 0 report "T8: " & integer'image(t8_errors) & " sampling errors" severity failure;
    assert t8_sprite > 0 report "T8: no sprite pixel sampled" severity failure;
    report "T8: 224 lines of 288 samples, RGB changes " & integer'image(t8_offset) & " clocks after the O_HBLANK fall, vs low " &
           integer'image(t8_vs_low) & " clocks, vs rise to the first visible line " & integer'image(t8_vs_to_line) &
           " clocks, " & integer'image(t8_sprite) & " sprite samples, BLANK_DLY " & integer'image(BLANK_DLY);

    -- ---------------- T9 reset during a harvest ----------------
    n_before := harv_rises;
    loop
      tick;
      exit when harv_rises /= n_before;
    end loop;
    tick(3000);
    rst <= '1';
    wait_harvest;
    frame0 := snap_frame;
    n_before := harv_rises;
    tick(N_FRAME + 2000);
    assert harv_rises = n_before report "T9: a harvest started in reset" severity failure;
    assert snap_frame = frame0 report "T9: frame_no changed in reset" severity failure;
    rst <= '0';
    wait_harvest;
    assert harv_rises = n_before + 1 report "T9: no harvest after the reset" severity failure;
    report "T9: the window cut by the reset was " & integer'image(last_len) & " clocks, none started in reset, the next ran";

    -- ---------------- verdict ----------------
    assert pair_errors = 0 report "T2: " & integer'image(pair_errors) & " strobe pairs differed" severity failure;
    report "harvests " & integer'image(harv_rises) & ", every window " & integer'image(N_WINDOW) & " clocks, " &
           time'image(now) & " simulated";
    if errors = 0 then
      report "PASS";
    else
      report "FAIL: " & integer'image(errors) & " checks failed" severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture sim;
