// SPDX-License-Identifier: GPL-3.0-or-later
/*
    mcu_spi.v
 
    SPI version of MCU interface 
*/

// game20k: MODIFIED VERSION of MiSTeryNano src/misc/mcu_spi.v (Till Harbaum).
// Some changes are marked "game20k" in the text, not all: the complete list is the diff
// against the upstream commit named in the README of this folder. Till Harbaum's file is
// GPL-3.0-or-later, the game20k changes are too, Copyright (C) 2026 scullymi.

module mcu_spi (
  input        clk,
  input        reset,

  // SPI interface to MCU
  input        spi_io_ss,
  input        spi_io_clk,
  input        spi_io_din,
  output reg   spi_io_dout,

  // byte interface to the various core components
  output reg      mcu_sys_strobe, // byte strobe for system control target  
  output reg      mcu_hid_strobe, // byte strobe for HID target  
  output reg      mcu_osd_strobe, // byte strobe for OSD target
  output reg      mcu_sdc_strobe, // byte strobe for SD card target
  output reg      mcu_ram_strobe, // game20k: byte strobe for RAM mirror target (target 5)
  output       mcu_start,
  output reg   mcu_end,        // game20k: one clock after the last byte of a transaction
  input  [7:0] mcu_sys_din,
  input  [7:0] mcu_hid_din,
  input  [7:0] mcu_osd_din,
  input  [7:0] mcu_sdc_din,
  input  [7:0] mcu_ram_din,
  output [7:0] mcu_dout
);
   
// SPI runs in MODE1 
// -> idle state of data is low
// -> data is setup on rising clock edge
// -> data is read on falling clock edge

// bit/byte counter
reg [3:0] spi_cnt;

reg [7:0] spi_data_in;
reg [6:0] spi_sr_in;
reg spi_data_in_ready;

// game20k: the bytes of a transaction are counted here, where the select resets the counter
// at once, and each byte goes to the core clock with its number. The core clock does not
// reset anything with the select: a select that rises right after the last SCK edge, before
// that byte is through the two synchronizing stages, or a select high for less than one core
// clock, would lose a byte or the start of the next transaction there.
reg [1:0] spi_byte_cnt;   // complete bytes since the select fell: 0, 1, then 2 for all others
reg [1:0] spi_data_idx;   // the number of spi_data_in in its transaction, 0 is the target id

// read data on falling edge of spi clock
always @(negedge spi_io_clk or posedge spi_io_ss) begin
    if(spi_io_ss) begin
        spi_cnt <= 4'd0;
        spi_byte_cnt <= 2'd0;   // game20k
    end else begin
        // lower 3 bits cound bits, upper 8 bits count bytes
        spi_cnt <= spi_cnt + 4'd1;

        // shift bit in
        spi_sr_in <= { spi_sr_in[5:0], spi_io_din };

        // byte ready?
        if(spi_cnt[2:0] == 3'd7) begin
            // latch byte and raise ready flag
            spi_data_in <= { spi_sr_in, spi_io_din };
            spi_data_idx <= spi_byte_cnt;                                       // game20k
            if(spi_byte_cnt != 2'd2) spi_byte_cnt <= spi_byte_cnt + 2'd1;       // game20k
            spi_data_in_ready <= !spi_data_in_ready;
        end

        // Clear data ready at bit 3. If the reading side
        // runs at 32 Mhz, this will work up to 64 MHz
        // SPI clock. At higher clocks the word width must 
        // be increased.
//        if(spi_cnt[2:0] == 3'd3)
//            spi_data_in_ready <= 1'b0;
    end
end // always @ (negedge spi_io_clk or posedge spi_io_ss)
   
reg [7:0] spi_in_data;
reg [7:0] spi_target;
// game20k: the byte in spi_in_data is the first after the target id. Like the byte it stays
// until the next one, also after the transaction, so it counts only together with a strobe.
reg spi_start;
assign mcu_start = spi_start;
assign mcu_dout = spi_in_data;

// game20k: the end of a transaction for the core clock. The select rises after the last byte's
// toggle, and goes through one stage more than the toggle on its way to the strobe, so mcu_end
// comes at least two clocks after the strobe of the last byte: one of them is the reserve for
// the toggle's synchronizer resolving a clock late, which no simulation shows. A select that
// is high too briefly for the stages may go unseen: then the target id of the next transaction
// ends the open one.
reg [3:0] spi_ss_s = 4'b1111;
reg       spi_open = 1'b0;   // a byte came since the last mcu_end

always @(posedge clk) begin
   reg [1:0] spi_data_in_readyD;

   spi_data_in_readyD <= { spi_data_in_readyD[0], spi_data_in_ready };
   spi_ss_s <= { spi_ss_s[2:0], spi_io_ss };   // game20k

   mcu_sys_strobe <= 1'b0;   
   mcu_hid_strobe <= 1'b0;   
   mcu_osd_strobe <= 1'b0;   
   mcu_sdc_strobe <= 1'b0;   
   mcu_ram_strobe <= 1'b0;   
   mcu_end <= 1'b0;   // game20k
   
   begin   // game20k: no reset by the select in this clock, see spi_byte_cnt
      // parse incoming bit whenever ready toggles
      // if(spi_data_in_readyD == 2'b01) begin
      if(spi_data_in_readyD[1] ^ spi_data_in_readyD[0]) begin
	 // incoming SPI byte is now in local clock domain

	 // first byte is target id. Else send external trigger
	 if(spi_data_idx == 2'd0) begin   // game20k: the byte's number from the SPI side
           spi_target <= spi_data_in;
           if(spi_open) mcu_end <= 1'b1;   // game20k: the select between went unseen
	 end else begin      
	    if(spi_target == 8'd0) mcu_sys_strobe <= 1'b1;
	    if(spi_target == 8'd1) mcu_hid_strobe <= 1'b1;
	    if(spi_target == 8'd2) mcu_osd_strobe <= 1'b1;
	    if(spi_target == 8'd3) mcu_sdc_strobe <= 1'b1;
	    if(spi_target == 8'd5) mcu_ram_strobe <= 1'b1;
   
            spi_in_data <= spi_data_in;
	 end
	 
	 spi_start <= spi_data_idx == 2'd1;   // game20k
	 spi_open <= 1'b1;                    // game20k
      end else if(spi_open && spi_ss_s[3:2] == 2'b01) begin
	 // game20k: the select rose, its transaction is over
	 mcu_end <= 1'b1;
	 spi_open <= 1'b0;
      end
   end
end

wire [7:0] in_byte = 
	   (spi_target == 8'd0)?mcu_sys_din:
	   (spi_target == 8'd1)?mcu_hid_din:
	   (spi_target == 8'd2)?mcu_osd_din:
	   (spi_target == 8'd3)?mcu_sdc_din:
	   (spi_target == 8'd5)?mcu_ram_din:
	   8'h00;   
   
// setup data on rising edge of spi clock
always @(posedge spi_io_clk or posedge spi_io_ss) begin
    if(spi_io_ss) begin
       spi_io_dout <= 1'b0; // bl616 EN_CHIP fix
    end else begin
       spi_io_dout <= in_byte[~spi_cnt[2:0]];
    end
end

endmodule // osd_u8g2
