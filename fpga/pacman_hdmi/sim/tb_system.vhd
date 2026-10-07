-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
--! @file tb_system.vhd
--! @brief The Pac-Man core (pacman.vhd) with a real ROM set, run for a number of frames,
--!        every EVERY-th frame written out for the comparison with MAME (run_system_sim.sh).
--!
--! The testbench does the wrapper's job as game_core.sv does it: the ena_6 divider, the
--! download port with RESET = 1 at the dn addresses of the game folder, dipsw1 = C9 and
--! dipsw2 = FF, every mod_* 0 but mod_jr = MOD_JR, the blankn delay (BLANK_DLY = 1) and the
--! scaler's sample phase (the third clock of a pixel, as tb_pacman.vhd T8 measures it).
--!
--! Files, all in DIR (written by run_system_sim.sh):
--!   dn.txt      one download write per line, "AAAA DD" in hex, in the order of the ROM file
--!   prog.txt    with MOD_JR = 1: Jr.'s program as the CPU sees it, 40960 bytes one per line
--!               (CPU 0x0000-0x3FFF, then 0x8000-0xDFFF)
--!   inputs.txt  "F IN0 IN1" per line, F the frame from which the two bytes hold (decimal,
--!               ascending), the bytes active low in hex
--! Out: DIR/frames/fNNNN.ppm (P6, 288 x 224, the core raster unrotated, the colours at the
--! levels of MAME's resistor network) and one report line per 100 frames.
--!
--! Jr.'s program comes through jr_rom_* from a model of rom_slots: one word of four bytes is
--! held, a ROM access outside it misses and is answered after 3 to 12 clocks, one miss in 16
--! after 20 to 60. While jr_rom_ok is 0 the data bus carries FF, so a byte taken without ok
--! would show up as RST 38 in the picture. Counted: clocks and CPU clock enables (T states)
--! with the CPU held by jr_rom_wait_l, the misses and the longest wait. LAT = 0 leaves the
--! model out (jr_rom_ok always 1), the control run for the effect of the waits on the game.
--!
--! Diagnostics for Jr.: every change of latch2 (palette and colour table bank, background
--! priority, char and sprite bank) is reported with its frame, every 100 frames the pixels at
--! which a sprite met a nonzero tile colour while the background priority was set and how
--! many of them got the tile, and DUMP_F writes that frame's priority map (p_dump).
--!
--! A frame ends at the rising edge of O_VBLANK, the interrupt edge. Inputs change there:
--! frame k ends, the inputs for frame k + 1 apply, so the interrupt that follows reads them,
--! as mame_ref.lua sets them in MAME's frame_done callback.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_system is
  generic (
    MOD_JR : natural := 0;          --!< 1: Jr. Pac-Man
    FRAMES : natural := 100;        --!< frames from the reset release
    EVERY  : positive := 1;         --!< write every EVERY-th frame
    SEED   : positive := 1;         --!< seed of the latency model
    LAT    : natural := 1;          --!< 0: Jr.'s program answers at once, no waits
    DUMP_F : natural := 0;          --!< frame of the priority map (0: none)
    DIR    : string := "."          --!< in- and output directory
  );
end entity tb_system;

architecture sim of tb_system is
  constant T         : time    := 53.872 ns;
  constant W         : natural := 288;
  constant H         : natural := 224;
  constant BLANK_DLY : natural := 1;               -- as game_core.sv

  type byte_arr is array (natural range <>) of std_logic_vector(7 downto 0);
  type nat_vec  is array (natural range <>) of natural;
  type char_file is file of character;

  signal clk   : std_logic := '0';
  signal done  : boolean   := false;
  signal ph    : unsigned(1 downto 0) := "00";
  signal ena_6 : std_logic;
  signal rst   : std_logic := '1';
  signal mjr   : std_logic := '0';

  signal dn_addr : std_logic_vector(15 downto 0) := (others => '0');
  signal dn_data : std_logic_vector(7 downto 0)  := (others => '0');
  signal dn_wr   : std_logic := '0';
  signal in0, in1 : std_logic_vector(7 downto 0) := x"FF";

  signal o_r, o_g : std_logic_vector(2 downto 0);
  signal o_b      : std_logic_vector(1 downto 0);
  signal o_hs, o_vs, o_hb, o_vb : std_logic;
  signal o_audio  : std_logic_vector(9 downto 0);

  signal jr_addr : std_logic_vector(15 downto 0);
  signal jr_cs   : std_logic;
  signal jr_din  : std_logic_vector(7 downto 0);
  signal jr_ok   : std_logic;

  signal blankn_live, video_blankn : std_logic;
  signal blankn_q : std_logic_vector(1 downto 0) := "00";

  -- Jr.'s program and the slot model
  signal prog     : byte_arr(0 to 40959) := (others => x"00");
  signal slot_tag : std_logic_vector(15 downto 2) := (others => '0');
  signal slot_ok  : boolean := false;

  signal frame : natural := 0;      -- frames ended since the reset release

  function hex(v : std_logic_vector) return string is
  begin
    return to_hstring(v);
  end function;

  -- four decimal digits, for the file names
  function dec4(n : natural) return string is
    constant s : string := integer'image(10000 + n mod 10000);
  begin
    return s(2 to 5);
  end function;

  -- CPU address to the program array: 0x0000-0x3FFF, then 0x8000-0xDFFF without the gap
  function prog_index(a : std_logic_vector(15 downto 0)) return natural is
    variable n : natural := to_integer(unsigned(a));
  begin
    if n >= 16#8000# then return n - 16#4000#; end if;
    return n;
  end function;

  -- the program's CPU ranges, decided from the address alone (jr_rom_cs settles a delta later)
  function is_rom(a : std_logic_vector(15 downto 0)) return boolean is
  begin
    return a(15 downto 14) = "00" or (a(15) = '1' and a(15 downto 13) /= "111");
  end function;

  -- MAME's levels for the 1k/470/220 network (red, green) and the 470/220 one (blue)
  function lvl3(v : std_logic_vector(2 downto 0)) return natural is
    constant L : nat_vec := (0, 33, 71, 104, 151, 184, 222, 255);
  begin
    return L(to_integer(unsigned(v)));
  end function;
  function lvl2(v : std_logic_vector(1 downto 0)) return natural is
    constant L : nat_vec := (0, 81, 174, 255);
  begin
    return L(to_integer(unsigned(v)));
  end function;
begin
  clk <= not clk after T / 2 when not done;
  mjr <= '1' when MOD_JR = 1 else '0';

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
      in0 => in0, in1 => in1, dipsw1 => x"C9", dipsw2 => x"FF",
      mod_plus => '0', mod_jmpst => '0', mod_bird => '0', mod_mrtnt => '0', mod_ms => '0',
      mod_woodp => '0', mod_eeek => '0', mod_glob => '0', mod_alib => '0', mod_ponp => '0',
      mod_van => '0', mod_dshop => '0', mod_club => '0',
      flip_screen => '0', h_offset => "000", v_offset => "000",
      mod_jr => mjr, jr_rom_addr => jr_addr, jr_rom_cs => jr_cs, jr_rom_din => jr_din,
      jr_rom_ok => jr_ok,
      dn_addr => dn_addr, dn_data => dn_data, dn_wr => dn_wr,
      pause => '0',
      hs_address => x"000", hs_data_in => x"00", hs_data_out => open,
      hs_write_enable => '0', hs_access_read => '0', hs_access_write => '0',
      mir_sxy_addr => x"0", mir_sxy_data => open, mir_flip => open,
      mir_we_ram => open, mir_we_sxy => open, mir_we_flip => open,
      mir_wr_addr => open, mir_wr_data => open, mir_frame_go => open,
      RESET => rst, CLK => clk, ENA_6 => ena_6, ENA_4 => '0', ENA_1M79 => '0');

  -- the wrapper's video path
  blankn_live <= not (o_hb or o_vb);
  p_blankn : process (clk)
  begin
    if rising_edge(clk) then blankn_q <= blankn_q(0) & blankn_live; end if;
  end process;
  video_blankn <= blankn_live when BLANK_DLY = 0 else blankn_q(BLANK_DLY - 1);

  -- ---------------- Jr.'s program ROM: a one-word slot with a random latency ----------------
  -- both from the same jr_addr: a condition on jr_ok would see the new address with the old ok
  jr_ok  <= '1' when LAT = 0 or (slot_ok and slot_tag = jr_addr(15 downto 2)) else '0';
  jr_din <= prog(prog_index(jr_addr)) when (LAT = 0 and is_rom(jr_addr)) or
                                           (slot_ok and slot_tag = jr_addr(15 downto 2)) else x"FF";

  p_slot : process (clk)
    variable s1       : positive := SEED;
    variable s2       : positive := SEED + 7919;
    variable r        : real;
    variable left     : natural := 0;
    variable busy     : boolean := false;
    variable tag      : std_logic_vector(15 downto 2);
  begin
    if rising_edge(clk) then
      if busy then
        -- the read in flight ends: the slot holds the new word
        if left <= 1 then
          busy := false; slot_tag <= tag; slot_ok <= true;
        else
          left := left - 1;
        end if;
      elsif jr_cs = '1' and not (slot_ok and slot_tag = jr_addr(15 downto 2)) then
        -- a miss: 3 to 12 clocks, one in 16 from 20 to 60
        uniform(s1, s2, r);
        if r < 1.0 / 16.0 then
          uniform(s1, s2, r);
          left := 20 + integer(trunc(r * 41.0));
        else
          uniform(s1, s2, r);
          left := 3 + integer(trunc(r * 10.0));
        end if;
        tag := jr_addr(15 downto 2); busy := true; slot_ok <= false;
      end if;
    end if;
  end process;

  -- ---------------- wait counters (external names into the core) ----------------
  p_wait : process (clk)
    alias wait_l is << signal .tb_system.u_core.jr_rom_wait_l : std_logic >>;
    alias hcnt   is << signal .tb_system.u_core.hcnt : std_logic_vector(8 downto 0) >>;
    variable clocks, tstates, misses, run, longest : natural := 0;
    variable ok_d : std_logic := '1';
    variable fr_d : natural := 0;
  begin
    if rising_edge(clk) then
      if wait_l = '0' then
        clocks := clocks + 1; run := run + 1;
        if ena_6 = '1' and hcnt(0) = '1' then tstates := tstates + 1; end if;
        if run > longest then longest := run; end if;
      else
        run := 0;
      end if;
      if jr_cs = '1' and jr_ok = '0' and ok_d = '1' then misses := misses + 1; end if;
      ok_d := jr_ok or not jr_cs;
      if frame /= fr_d and (frame mod 100 = 0 or frame = FRAMES) then
        report "waits after frame " & integer'image(frame) & ": " & integer'image(tstates) &
               " CPU T states (" & integer'image(clocks) & " clocks) held by jr_rom_ok, longest " &
               integer'image(longest) & " clocks, " & integer'image(misses) & " slot misses";
      end if;
      fr_d := frame;
    end if;
  end process;

  -- ---------------- Jr.'s latch2 (palette and colour table bank, priority, char and sprite bank) ----------------
  p_latch2 : process (clk)
    alias latch2 is << signal .tb_system.u_core.jr_latch2 : std_logic_vector(7 downto 0) >>;
    variable d : std_logic_vector(7 downto 0) := x"00";
  begin
    if rising_edge(clk) then
      if MOD_JR = 1 and latch2 /= d then
        report "frame " & integer'image(frame) & ": latch2 " & hex(d) & " -> " & hex(latch2);
        d := latch2;
      end if;
    end if;
  end process;

  -- ---------------- Jr.'s background priority: who wins where a sprite meets a tile pixel ----------------
  -- Counted at ena_6 on the visible line while latch2 bit 3 (bgpriority) is set: sprite and
  -- tile colour both nonzero, and of those the pixels that got the tile's colour. MAME draws the
  -- tile layer again over the sprites there (pen 0 transparent).
  p_prio : process (clk)
    alias op_sel is << signal .tb_system.u_core.u_video.video_op_sel : std_logic >>;
    alias lut_4a is << signal .tb_system.u_core.u_video.lut_4a : std_logic_vector(7 downto 0) >>;
    alias shp    is << signal .tb_system.u_core.u_video.shift_op : std_logic_vector(1 downto 0) >>;
    alias fcol   is << signal .tb_system.u_core.u_video.final_col : std_logic_vector(4 downto 0) >>;
    alias bgp    is << signal .tb_system.u_core.jr_bgpriority : std_logic >>;
    variable both, tile, pen0, fr_d : natural := 0;
  begin
    if rising_edge(clk) then
      if MOD_JR = 1 and ena_6 = '1' and bgp = '1' and blankn_live = '1' and op_sel = '1' then
        if lut_4a(3 downto 0) /= "0000" then
          both := both + 1;
          if fcol(3 downto 0) = lut_4a(3 downto 0) then tile := tile + 1; end if;
        end if;
        if shp /= "00" then pen0 := pen0 + 1; end if;
      end if;
      if MOD_JR = 1 and frame /= fr_d and frame mod 100 = 0 then
        report "priority after frame " & integer'image(frame) & ": " & integer'image(both) &
               " sprite pixels on a nonzero tile colour, " & integer'image(tile) & " of them tile, " &
               integer'image(pen0) & " sprite pixels on a nonzero tile pen";
      end if;
      fr_d := frame;
    end if;
  end process;

  -- ---------------- priority map of frame DUMP_F ----------------
  -- One byte per pixel at ena_6 on the visible part of the line (the core's own blanking, so a
  -- few pixels ahead of the PPM): 64 tile colour nonzero, 128 sprite present, 255 both and
  -- the tile chosen, 192 both and the sprite chosen. DIR/prio_NNNN.pgm, 288 x 224.
  p_dump : process (clk)
    alias op_sel is << signal .tb_system.u_core.u_video.video_op_sel : std_logic >>;
    alias lut_4a is << signal .tb_system.u_core.u_video.lut_4a : std_logic_vector(7 downto 0) >>;
    alias fcol   is << signal .tb_system.u_core.u_video.final_col : std_logic_vector(4 downto 0) >>;
    variable map_b : byte_arr(0 to W * H - 1);
    variable x, y  : integer := -1;
    variable hb_d, vb_d : std_logic := '1';
    variable v     : natural;
    file f         : char_file;
    variable st    : file_open_status;
    constant HDR   : string := "P5" & LF & "288 224" & LF & "255" & LF;
  begin
    if rising_edge(clk) and DUMP_F > 0 and ena_6 = '1' then
      if o_vb = '0' and vb_d = '1' then y := -1; end if;
      if o_hb = '0' and hb_d = '1' and o_vb = '0' then y := y + 1; x := 0; end if;
      if o_hb = '0' and o_vb = '0' and x >= 0 and x < W and y >= 0 and y < H then
        v := 0;
        if lut_4a(3 downto 0) /= "0000" then v := 64; end if;
        if op_sel = '1' then v := v + 128; end if;
        if v = 192 and fcol(3 downto 0) = lut_4a(3 downto 0) then v := 255; end if;
        map_b(y * W + x) := std_logic_vector(to_unsigned(v, 8));
        x := x + 1;
      end if;
      if o_vb = '1' and vb_d = '0' and frame = DUMP_F then
        file_open(st, f, DIR & "/prio_" & dec4(frame) & ".pgm", write_mode);
        for i in HDR'range loop write(f, HDR(i)); end loop;
        for i in map_b'range loop write(f, character'val(to_integer(unsigned(map_b(i))))); end loop;
        file_close(f);
        report "priority map of frame " & integer'image(frame) & " written";
      end if;
      hb_d := o_hb; vb_d := o_vb;
    end if;
  end process;

  -- ---------------- inputs from inputs.txt, applied at the end of a frame ----------------
  p_inputs : process
    file f     : text;
    variable l : line;
    variable st : file_open_status;
    variable nf : integer := -1;
    variable n0, n1 : std_logic_vector(7 downto 0) := x"FF";
    variable good : boolean;
    procedure next_line is
    begin
      nf := -1;
      while not endfile(f) loop
        readline(f, l);
        if l'length > 0 then
          read(l, nf, good);
          if good then hread(l, n0); hread(l, n1); exit; end if;
          nf := -1;
        end if;
      end loop;
    end procedure;
  begin
    file_open(st, f, DIR & "/inputs.txt", read_mode);
    if st /= open_ok then
      report "no inputs.txt, attract mode only";
      wait;
    end if;
    next_line;
    loop
      -- 'frame' frames have ended: the inputs of frame number 'frame' (0-based) apply now
      while nf >= 0 and nf <= frame loop
        in0 <= n0; in1 <= n1;
        next_line;
      end loop;
      exit when nf < 0;
      wait on frame;
    end loop;
    wait;
  end process;

  -- ---------------- frames: sample as the scaler does, write every EVERY-th ----------------
  p_frames : process (clk)
    variable pix   : byte_arr(0 to W * H - 1);
    variable bl_d, vb_d : std_logic := '0';
    variable sph, x, y, samples : natural := 0;
    variable errs  : natural := 0;
    variable vis   : boolean := false;
    variable rgb   : std_logic_vector(7 downto 0);
    file f         : char_file;
    variable st    : file_open_status;
    variable name  : line;
    variable c     : std_logic_vector(7 downto 0);
    constant HDR   : string := "P6" & LF & "288 224" & LF & "255" & LF;
    variable lines : natural := 0;
  begin
    if rising_edge(clk) then
      rgb := o_b & o_g & o_r;
      if rst = '1' then
        lines := 0; vis := false;
      else
        if video_blankn = '1' and bl_d = '0' then
          -- start of a visible line
          if vis and samples /= W then
            errs := errs + 1;
            if errs <= 5 then
              report "frame " & integer'image(frame) & " line " & integer'image(lines - 1) & ": " &
                     integer'image(samples) & " samples" severity error;
            end if;
          end if;
          vis := true; sph := 0; x := 0; samples := 0; lines := lines + 1;
        elsif video_blankn = '1' and vis then
          if sph = 1 and x < W and lines <= H then
            pix((lines - 1) * W + x) := rgb;
            samples := samples + 1;
          end if;
          if sph = 2 then sph := 0; x := x + 1; else sph := sph + 1; end if;
        end if;
        if o_vb = '1' and vb_d = '0' then
          -- the end of a frame: write it, count it
          if lines /= H and frame > 0 then
            errs := errs + 1;
            report "frame " & integer'image(frame) & ": " & integer'image(lines) & " visible lines" severity error;
          end if;
          if frame mod EVERY = 0 and lines = H then
            write(name, DIR & "/frames/f" & dec4(frame) & ".ppm");
            file_open(st, f, name.all, write_mode);
            assert st = open_ok report "cannot write " & name.all severity failure;
            deallocate(name);
            for i in HDR'range loop write(f, HDR(i)); end loop;
            for i in pix'range loop
              c := pix(i);
              write(f, character'val(lvl3(c(2 downto 0))));
              write(f, character'val(lvl3(c(5 downto 3))));
              write(f, character'val(lvl2(c(7 downto 6))));
            end loop;
            file_close(f);
          end if;
          if frame mod 100 = 0 then
            report "frame " & integer'image(frame) & " at " & time'image(now) &
                   ", sampling errors " & integer'image(errs);
          end if;
          frame <= frame + 1;
          lines := 0; vis := false;
        end if;
      end if;
      bl_d := video_blankn; vb_d := o_vb;
    end if;
  end process;

  -- ---------------- download, reset, run ----------------
  p_main : process
    file f      : text;
    variable l  : line;
    variable a  : std_logic_vector(15 downto 0);
    variable d  : std_logic_vector(7 downto 0);
    variable n  : natural := 0;
    variable st : file_open_status;
    variable p  : byte_arr(0 to 40959) := (others => x"00");
  begin
    rst <= '1';
    for i in 1 to 5 loop wait until rising_edge(clk); end loop;
    file_open(st, f, DIR & "/dn.txt", read_mode);
    assert st = open_ok report "cannot read " & DIR & "/dn.txt" severity failure;
    while not endfile(f) loop
      readline(f, l);
      next when l'length = 0;
      hread(l, a); hread(l, d);
      dn_addr <= a; dn_data <= d; dn_wr <= '1';
      wait until rising_edge(clk);
      dn_wr <= '0';
      wait until rising_edge(clk);
      n := n + 1;
    end loop;
    file_close(f);
    dn_addr <= x"0000";
    report "download: " & integer'image(n) & " writes";
    if MOD_JR = 1 then
      file_open(st, f, DIR & "/prog.txt", read_mode);
      assert st = open_ok report "cannot read " & DIR & "/prog.txt" severity failure;
      for i in p'range loop
        readline(f, l); hread(l, d); p(i) := d;
      end loop;
      file_close(f);
      prog <= p;
      report "program: 40960 bytes, 0x0000 = " & hex(p(0)) & hex(p(1)) & hex(p(2));
    end if;
    for i in 1 to 300 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    report "reset released at " & time'image(now);
    wait until frame = FRAMES;
    for i in 1 to 3 loop wait until rising_edge(clk); end loop;
    report "END " & integer'image(FRAMES) & " frames";
    done <= true;
    wait;
  end process;
end architecture sim;
