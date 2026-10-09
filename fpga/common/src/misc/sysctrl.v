// SPDX-License-Identifier: GPL-3.0-or-later
//! @file sysctrl.v
//! @brief System control for the FPGA Companion (SPI target 0), game20k variant.
//!
//! DERIVED from MiSTeryNano src/misc/sysctrl.v (Till Harbaum, MiSTle-Dev), reduced to what
//! game20k needs. About 60 lines are Till's, taken over verbatim from the 333-line sysctrl.v:
//! the SPI command state machine with its magic constants, because the Companion expects
//! exactly this protocol. The rest (generic settings, the value strobe) is ours,
//! Copyright (C) 2026 scullymi. Till's lines and ours are GPL-3.0-or-later, see
//! THIRD-PARTY.md.
//! The README in this folder names the upstream commit of sysctrl.v.
module sysctrl (
  input             clk,
  input             reset,

  input             data_in_strobe,
  input             data_in_start,
  input [7:0]       data_in,
  output reg [7:0]  data_out,

  //! Interrupts to the MCU
  output            int_out_n,
  input [7:0]       int_in,
  output reg [7:0]  int_ack,

  input [1:0]       buttons,        //!< [0] = reset button, [1] = OSD button

  output reg [1:0]  leds,
  output reg [23:0] color,

  //! values the user can set in the OSD, the ones the platform itself uses
  output reg [1:0]  system_reset,     //!< 1/3 = reset active
  output reg [1:0]  system_scanlines,
  //! game20k: volume, input test, key mapping (0 = none or all, 1..12 = HID key)
  output reg [2:0]  system_volume,
  output reg        system_inputtest,
  output reg [3:0]  system_fire_btn,
  output reg [3:0]  system_coin_btn,
  output reg [3:0]  system_start_btn,
  output reg [3:0]  system_start2_btn,
  output reg [3:0]  system_voldn_btn,
  output reg [3:0]  system_volup_btn,
  output reg [1:0]  system_screen,     //!< 0 = landscape (scaler), 1 = portrait 2x (SDRAM)
  //! game20k: every value the Companion sets (CMD 4) also goes out as one clock of
  //! cfg_we with its id and value. The game wrapper takes the ids it knows (its DIP
  //! switches) from there, so this module needs to know nothing about the game.
  output reg        cfg_we,
  output reg [7:0]  cfg_id,
  output reg [7:0]  cfg_val
);

reg [3:0] state;
reg [7:0] command;
reg [7:0] id;

wire [7:0] data_in_rev = { data_in[0], data_in[1], data_in[2], data_in[3],
                           data_in[4], data_in[5], data_in[6], data_in[7] };

reg coldboot = 1'b1;
reg sys_int = 1'b1;
reg [1:0] buttonsD, buttonsD2;
reg buttons_irq_enable;

assign int_out_n = (int_in != 8'h00 || sys_int) ? 1'b0 : 1'b1;

always @(posedge clk) begin
   if(reset) begin
      state <= 4'd0;
      leds <= 2'b00;
      color <= 24'h000000;
      buttons_irq_enable <= 1'b1;
      int_ack <= 8'h00;
      coldboot <= 1'b1;   // non-blocking like everywhere else in this block, yosys-slang refuses the mix
      sys_int <= 1'b1;
      system_reset <= 2'd0;
      system_scanlines <= 2'd0;
      system_volume <= 3'd6;        // gain 12/16
      system_inputtest <= 1'b0;
      system_fire_btn <= 4'd0;      // all buttons
      system_coin_btn <= 4'd9;      // DInput: Select
      system_start_btn <= 4'd10;    // DInput: Start
      system_start2_btn <= 4'd0;
      system_voldn_btn <= 4'd0;
      system_volup_btn <= 4'd0;
      system_screen <= 2'd0;      // landscape by default, until the user switches
      cfg_we <= 1'b0;
   end else begin
      buttonsD <= buttons;
      buttonsD2 <= buttonsD;
      int_ack <= 8'h00;
      cfg_we <= 1'b0;

      if(int_ack[0]) sys_int <= 1'b0;

      if(buttons_irq_enable) begin
        if(buttonsD2 != buttonsD) begin
            sys_int <= 1'b1;
            buttons_irq_enable <= 1'b0;
        end
      end

      if(data_in_strobe) begin
        if(data_in_start) begin
           state <= 4'd0;
           command <= data_in;
           data_out <= 8'h00;
        end else begin
            if(state != 4'd15) state <= state + 4'd1;

            // CMD 0: status
            if(command == 8'd0) begin
                if(state == 4'd0) data_out <= 8'h5c;
                if(state == 4'd1) data_out <= 8'h42;
                if(state == 4'd2) data_out <= 8'h00;   // core ID 0 = generic core
            end
            // CMD 1: LEDs
            if(command == 8'd1) begin
                if(state == 4'd0) leds <= data_in[1:0];
            end
            // CMD 2: RGB colour
            if(command == 8'd2) begin
                if(state == 4'd0) color[15: 8] <= data_in_rev;
                if(state == 4'd1) color[ 7: 0] <= data_in_rev;
                if(state == 4'd2) color[23:16] <= data_in_rev;
            end
            // CMD 3: button state
            if(command == 8'd3) begin
               data_out <= { 6'b000000, buttons };
               buttons_irq_enable <= 1'b1;
            end
            // CMD 4: set configuration value
            if(command == 8'd4) begin
                if(state == 4'd0) id <= data_in;
                if(state == 4'd1) begin
                    // game20k: the game wrapper sees every value, whatever its id
                    cfg_we  <= 1'b1;
                    cfg_id  <= id;
                    cfg_val <= data_in;
                    if(id == "R") system_reset      <= data_in[1:0];
                    if(id == "S") system_scanlines  <= data_in[1:0];
                    if(id == "V") system_volume     <= data_in[2:0];
                    if(id == "T") system_inputtest  <= data_in[0];
                    if(id == "A") system_fire_btn   <= data_in[3:0];
                    if(id == "N") system_coin_btn   <= data_in[3:0];
                    if(id == "P") system_start_btn  <= data_in[3:0];
                    if(id == "Q") system_start2_btn <= data_in[3:0];
                    if(id == "D") system_voldn_btn  <= data_in[3:0];
                    if(id == "U") system_volup_btn  <= data_in[3:0];
                    if(id == "G") system_screen     <= data_in[1:0];
                end
            end
            // CMD 5: interrupt control
            if(command == 8'd5) begin
                if(state == 4'd0) int_ack <= data_in;
                data_out <= { int_in[7:1], sys_int };
            end
            // CMD 6: interrupt source
            if(command == 8'd6) begin
                data_out <= { 5'b00000, !buttons_irq_enable, 1'b0, coldboot };
                if(state == 4'd0) coldboot <= 1'b0;
            end
            // CMD 7: port I/O (no ports)
            if(command == 8'd7) begin
               data_out <= 8'd0;
            end
            // CMD 8: read menu configuration. game20k: the core has none, the Companion holds
            // the menus of our cores. 0x00 tells it so (neither '<' nor a gzip header).
            if(command == 8'd8) begin
               data_out <= 8'd0;
            end
        end
      end
   end
end
endmodule
