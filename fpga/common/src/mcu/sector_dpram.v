//Copyright (C)2014-2023 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//Tool Version: V1.9.9
//Part Number: GW2AR-LV18QN88C8/I7
//Device: GW2AR-18
//Device Version: C
//Created Time: Tue Jan  2 16:32:52 2024
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! -----------------------------------------------------------------------------------------
//! @file sector_dpram.v
//! @brief Dual-port 512x8 block memory for one SD card sector.
//!
//! One side belongs to the SD card reader, the other to the Companion or the core.
//!
//! The module is output of the Gowin IP generator, the instantiation of the DPB primitive
//! with its parameters, with Gowin's header above. It comes from MiSTeryNano at c8e4601,
//! src/tang/nano20k/gowin_dpb/sector_dpram.v. game20k added the default_nettype line, wire
//! in the port declarations and these comments, Copyright (C) 2026 scullymi. The file
//! carries no SPDX tag because it is not ours alone, see THIRD-PARTY.md.
//! -----------------------------------------------------------------------------------------

module sector_dpram (douta, doutb, clka, ocea, cea, reseta, wrea, clkb, oceb, ceb, resetb, wreb, ada, dina, adb, dinb);

output wire [7:0] douta;
output wire [7:0] doutb;
input wire clka;
input wire ocea;
input wire cea;
input wire reseta;
input wire wrea;
input wire clkb;
input wire oceb;
input wire ceb;
input wire resetb;
input wire wreb;
input wire [8:0] ada;
input wire [7:0] dina;
input wire [8:0] adb;
input wire [7:0] dinb;

wire [7:0] dpb_inst_0_douta_w;
wire [7:0] dpb_inst_0_doutb_w;
wire gw_gnd;

assign gw_gnd = 1'b0;

DPB dpb_inst_0 (
    .DOA({dpb_inst_0_douta_w[7:0],douta[7:0]}),
    .DOB({dpb_inst_0_doutb_w[7:0],doutb[7:0]}),
    .CLKA(clka),
    .OCEA(ocea),
    .CEA(cea),
    .RESETA(reseta),
    .WREA(wrea),
    .CLKB(clkb),
    .OCEB(oceb),
    .CEB(ceb),
    .RESETB(resetb),
    .WREB(wreb),
    .BLKSELA({gw_gnd,gw_gnd,gw_gnd}),
    .BLKSELB({gw_gnd,gw_gnd,gw_gnd}),
    .ADA({gw_gnd,gw_gnd,ada[8:0],gw_gnd,gw_gnd,gw_gnd}),
    .DIA({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,dina[7:0]}),
    .ADB({gw_gnd,gw_gnd,adb[8:0],gw_gnd,gw_gnd,gw_gnd}),
    .DIB({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,dinb[7:0]})
);

defparam dpb_inst_0.READ_MODE0 = 1'b0;
defparam dpb_inst_0.READ_MODE1 = 1'b0;
defparam dpb_inst_0.WRITE_MODE0 = 2'b00;
defparam dpb_inst_0.WRITE_MODE1 = 2'b00;
defparam dpb_inst_0.BIT_WIDTH_0 = 8;
defparam dpb_inst_0.BIT_WIDTH_1 = 8;
defparam dpb_inst_0.BLK_SEL_0 = 3'b000;
defparam dpb_inst_0.BLK_SEL_1 = 3'b000;
defparam dpb_inst_0.RESET_MODE = "SYNC";

endmodule //sector_dpram

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
