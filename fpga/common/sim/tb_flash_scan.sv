// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file tb_flash_scan.sv
//! @brief flash_scan.sv against a model of the flash that answers command 0x03.
//!
//! Each round fills the slots at random with one of the cases below, resets the scanner and
//! compares board[] with what the case expects:
//!   - an erased slot, with and without a stale tag at its end, or with a5 and c3 apart in
//!     its head (0),
//!   - a bitstream with a valid tag (the tag's board), its sync word at the usual offset or
//!     in the last two head bytes,
//!   - a bitstream without a tag, with one wrong magic byte, a wrong complement, or board 0
//!     or 255 in the tag (255).
//! The model checks the command byte and the mode 0 timing it relies on, the bench checks
//! that the pins are released after the scan. Ends with PASS or $fatal, after a minimum
//! count of each case.

module tb_flash_scan;
    localparam int SLOTS = 8, SLOT_BYTES = 'h100000, ROUNDS = 40;
    localparam int NCASE = 9;

    logic clk = 0, reset = 1;
    always #10 clk = ~clk;

    wire       oe, cs_n, sck, mosi;
    logic      miso = 0;
    wire [7:0] board [SLOTS];
    wire       done;

    flash_scan #(.SLOTS(SLOTS), .SLOT_BYTES(SLOT_BYTES)) dut (
        .clk(clk), .reset(reset), .oe(oe), .cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso),
        .board(board), .done(done)
    );

    // ---------------- the flash's content per slot ----------------
    int        kind [SLOTS];    // case number, see expect_of()
    logic [7:0] id  [SLOTS];    // the board id the case writes

    // 0 erased, 1 erased with a stale tag, 2 tagged, 3 tagged with the sync word late,
    // 4 no tag, 5 one magic byte wrong, 6 complement wrong, 7 board 0 or 255 in the tag,
    // 8 leftovers in the head, a5 and c3 apart, and a valid tag
    function automatic logic [7:0] expect_of(input int s);
        case (kind[s])
            0, 1, 8: return 8'h00;
            2, 3:    return id[s];
            default: return 8'hFF;
        endcase
    endfunction

    function automatic logic [7:0] tag_byte(input int s, input int i);
        logic [63:0] magic = "G20KCORE";
        if (i < 8) return (kind[s] == 5 && i == 3) ? 8'h00 : magic[63 - 8 * i -: 8];
        if (i == 8) return id[s];
        if (i == 9) return kind[s] == 6 ? id[s] : ~id[s];
        return 8'hFF;
    endfunction

    function automatic logic [7:0] mem(input int a);
        int s = a / SLOT_BYTES, o = a % SLOT_BYTES;
        bit has_bs = kind[s] >= 2 && kind[s] <= 7, has_tag = kind[s] != 0 && kind[s] != 4;
        int sync_at = kind[s] == 3 ? 30 : 22;
        if (kind[s] == 8 && o == 10) return 8'hA5;
        if (kind[s] == 8 && (o == 9 || o == 20)) return 8'hC3;
        if (has_bs && o == sync_at) return 8'hA5;
        if (has_bs && o == sync_at + 1) return 8'hC3;
        if (has_bs && o >= 32 && o < 64) return 8'(a * 7);       // bitstream bytes after the head
        if (has_tag && o >= SLOT_BYTES - 16) return tag_byte(s, o - (SLOT_BYTES - 16));
        return 8'hFF;
    endfunction

    // ---------------- the flash: 0x03, mode 0 ----------------
    int       fcnt;
    logic [31:0] fcmd;
    int       reads;
    always @(negedge cs_n) begin fcnt = 0; fcmd = 0; end
    always @(posedge sck) if (!cs_n) begin
        if (fcnt < 32) fcmd = {fcmd[30:0], mosi};
        if (fcnt == 31 && fcmd[31:24] != 8'h03) $fatal(1, "command %02x, not 03", fcmd[31:24]);
        fcnt++;
    end
    int fa;
    always @(negedge sck) if (!cs_n && fcnt >= 32) begin
        fa = int'(fcmd[23:0]) + (fcnt - 32) / 8;
        miso <= mem(fa)[7 - (fcnt - 32) % 8];
    end
    always @(posedge cs_n) if (fcnt > 0) reads++;

    // xorshift32
    int unsigned rs = 32'h1234_5678;
    function automatic int unsigned rnd(input int unsigned range);
        rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5;
        return rs % range;
    endfunction

    int seen [NCASE];
    initial begin
        for (int r = 0; r < ROUNDS; r++) begin
            for (int s = 0; s < SLOTS; s++) begin
                // the first rounds go through every case in order, the rest at random
                kind[s] = (r * SLOTS + s < NCASE) ? r * SLOTS + s : int'(rnd(NCASE));
                id[s]   = kind[s] == 7 ? (rnd(2) ? 8'h00 : 8'hFF) : 8'(1 + rnd(254));
                seen[kind[s]]++;
            end
            reads = 0;
            reset = 1;
            repeat (3) @(posedge clk);
            reset = 0;
            fork
                wait (done);
                begin repeat (200000) @(posedge clk); $fatal(1, "round %0d: no done", r); end
            join_any
            disable fork;
            @(posedge clk);
            if (oe) $fatal(1, "round %0d: pins still driven after the scan", r);
            if (reads != 2 * SLOTS) $fatal(1, "round %0d: %0d reads, not %0d", r, reads, 2 * SLOTS);
            for (int s = 0; s < SLOTS; s++)
                if (board[s] !== expect_of(s))
                    $fatal(1, "round %0d slot %0d case %0d: board %02x, expected %02x", r, s, kind[s],
                           board[s], expect_of(s));
        end
        for (int c = 0; c < NCASE; c++)
            if (seen[c] < 10) $fatal(1, "case %0d only %0d times", c, seen[c]);
        $display("%0d rounds of %0d slots", ROUNDS, SLOTS);
        $display("PASS");
        $finish;
    end
endmodule
