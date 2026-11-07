// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_ram_mirror.c
 *  @brief The RAM mirror: which header is taken, which snapshot reaches rcheevos, what the core is told.
 *
 *  ram_mirror.c is included, its state is static. The core is a stand-in: dev[] holds what it
 *  answers on SPI target 5, the first byte after the target is the verdict it gets. */
#include <string.h>

#include "unity.h"
#include "host_stubs.h"
#include "ram_mirror.c"

#pragma GCC diagnostic ignored "-Wunused-parameter"

static unsigned char dev[RAM_MIRROR_BYTES_MAX];
static unsigned dev_pos, spi_open, tx_n;
static unsigned char told[2]; // the target and the verdict of the last transfer

void mcu_hw_spi_begin(void) {
  dev_pos = tx_n = 0;
  spi_open++;
}
void mcu_hw_spi_end(void) { spi_open--; }
unsigned char mcu_hw_spi_tx_u08(unsigned char b) {
  if(tx_n < 2) told[tx_n++] = b;
  return 0;
}
void mcu_hw_spi_txrx_block(const unsigned char *tx, unsigned char *rx, unsigned int len) {
  memcpy(rx, dev + dev_pos, len);
  dev_pos += len;
}
void mcu_hw_spi_rx_block(unsigned char *buf, unsigned int len) {
  memcpy(buf, dev + dev_pos, len);
  dev_pos += len;
}

// the rest of the firmware, counted
static unsigned frames, frame_size, prepared, resets, adopted;
static unsigned char frame_first;
static char banner_text[32];
void vTaskDelay(TickType_t ticks) {} // the probe tries again after a wait
void banner_follow_game(void) {}
void banner_login(void) {}
void banner_lboard(void) {}
void banner_step(unsigned char *hdr) {}
banner_t *banner_show_kept(const char *text, bool gold, bool new) {
  snprintf(banner_text, sizeof(banner_text), "%s", text);
  return NULL;
}
bool switch_step(void) { return false; }
void ra_events_header(unsigned char *hdr_tx) {}
void ra_events_prepare(void) { prepared++; }
void ra_events_frame(const unsigned char *ram, unsigned size) {
  frames++;
  frame_size  = size;
  frame_first = ram[0];
}
void game_set_board(unsigned char board) { adopted = board; }
void ra_patch_core_reset(void) { resets++; }
void ra_task_core_flags(unsigned char flags) {}

#define BOARD 7
#define PAGES 2
#define DATA  (PAGES * RAM_MIRROR_PAGE)
#define TAG   0x1a2b

static void header(unsigned char board, unsigned char pages, uint16_t tag) {
  memset(dev, 0, sizeof(dev));
  memcpy(dev, "RACH", 4);
  dev[4]  = RAM_MIRROR_LAYOUT;
  dev[12] = board;
  dev[13] = (unsigned char)~board;
  dev[14] = pages;
  dev[15] = (unsigned char)~pages;
  dev[16] = (unsigned char)tag;
  dev[17] = (unsigned char)(tag >> 8);
  dev[18] = (unsigned char)~dev[16];
  dev[19] = (unsigned char)~dev[17];
  dev[10] = 0xff; // reset count 0 with its complement
  dev[11] = 0xff; // no diagnostic parameters
}

/* The footer of a snapshot with this frame number, the checksum as the FPGA forms it. */
static void footer(int frame) {
  unsigned short sum = 0;
  dev[5] = (unsigned char)frame;
  dev[6] = (unsigned char)(frame >> 8);
  for(unsigned i = RAM_MIRROR_HEAD; i < RAM_MIRROR_HEAD + DATA + RAM_MIRROR_LOG; i++)
    sum = (unsigned short)(((sum << 1) | (sum >> 15)) ^ dev[i]);
  unsigned char *ftr = dev + RAM_MIRROR_HEAD + DATA + RAM_MIRROR_LOG;
  ftr[0] = dev[5];
  ftr[1] = dev[6];
  ftr[2] = ftr[3] = 0;
  ftr[4]          = (unsigned char)sum;
  ftr[5]          = (unsigned char)(sum >> 8);
  ftr[6] = ftr[7] = 0;
}

static unsigned char *ftr_of(void) { return dev + RAM_MIRROR_HEAD + DATA + RAM_MIRROR_LOG; }

/* A game that runs: the header taken, one good snapshot behind it. */
static void running(void) {
  header(BOARD, PAGES, TAG);
  TEST_ASSERT_EQUAL_UINT8(0, ram_mirror_probe());
  dev[RAM_MIRROR_HEAD] = 0x42;
  footer(1);
  ram_mirror_poll();
}

void setUp(void) {
  ram_mirror_forget();
  frames = prepared = resets = adopted = 0;
  banner_text[0]                       = 0;
  spi_open                             = 0;
}
void tearDown(void) { TEST_ASSERT_EQUAL_UINT(0, spi_open); }

static void test_probe_takes_a_good_header(void) {
  header(BOARD, PAGES, TAG);
  TEST_ASSERT_EQUAL_UINT8(0, ram_mirror_probe());
  TEST_ASSERT_EQUAL_UINT8(BOARD, ram_mirror_board);
  TEST_ASSERT_EQUAL_UINT16(TAG, ram_mirror_tag);
  TEST_ASSERT_EQUAL_UINT(BOARD, adopted);
}

static void test_no_core_of_ours(void) {
  header(BOARD, PAGES, TAG);
  dev[0] = 'X';
  TEST_ASSERT_EQUAL_UINT8(0xE1, ram_mirror_probe());
  TEST_ASSERT_EQUAL_UINT8(0, ram_mirror_board);
}

static void test_other_layout_is_refused_and_told(void) {
  header(BOARD, PAGES, TAG);
  dev[4] = RAM_MIRROR_LAYOUT - 1;
  TEST_ASSERT_EQUAL_UINT8(0xE2, ram_mirror_probe());
  TEST_ASSERT_EQUAL_STRING("SYS: CORE TOO OLD", banner_text);
  dev[4] = RAM_MIRROR_LAYOUT + 1;
  TEST_ASSERT_EQUAL_UINT8(0xE2, ram_mirror_probe());
  TEST_ASSERT_EQUAL_STRING("SYS: FIRMWARE TOO OLD", banner_text);
}

/* Each complement that does not match its byte, and the values no core has. */
static void test_broken_headers_are_refused(void) {
  static const unsigned char complement[] = { 13, 15, 18, 19 };
  for(unsigned i = 0; i < sizeof(complement); i++) {
    header(BOARD, PAGES, TAG);
    dev[complement[i]] ^= 0x01;
    TEST_ASSERT_EQUAL_UINT8_MESSAGE(0xE3, ram_mirror_probe(), "a complement that does not match");
  }
  header(0, PAGES, TAG);
  TEST_ASSERT_EQUAL_UINT8(0xE3, ram_mirror_probe());
  header(255, PAGES, TAG);
  TEST_ASSERT_EQUAL_UINT8(0xE3, ram_mirror_probe());
  header(BOARD, 0, TAG);
  TEST_ASSERT_EQUAL_UINT8(0xE3, ram_mirror_probe());
  header(BOARD, RAM_MIRROR_DATA_MAX / RAM_MIRROR_PAGE + 1, TAG);
  TEST_ASSERT_EQUAL_UINT8(0xE3, ram_mirror_probe());
  TEST_ASSERT_EQUAL_UINT8(0, ram_mirror_board);
}

/* The FPGA cannot change without a reconfiguration: another header after the first is noise. */
static void test_later_header_must_match(void) {
  running();
  header(BOARD + 1, PAGES, TAG);
  footer(2);
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(1, frames);
  TEST_ASSERT_EQUAL_UINT8(BOARD, ram_mirror_board);
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT8(0xE3, told[1]);
}

static void test_good_snapshot_reaches_rcheevos(void) {
  running();
  TEST_ASSERT_EQUAL_UINT(1, frames);
  TEST_ASSERT_EQUAL_UINT(DATA, frame_size);
  TEST_ASSERT_EQUAL_UINT8(0x42, frame_first);
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(1, frames); // the same frame number is nothing new
  TEST_ASSERT_EQUAL_UINT8(0xA5, told[1]);
  TEST_ASSERT_EQUAL_UINT8(SPI_TARGET_RAM, told[0]);
}

static void test_harvest_running_waits(void) {
  running();
  footer(2);
  dev[7] = 1;
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(1, frames);
  dev[7] = 0;
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(2, frames);
}

static void test_bad_checksum_is_no_snapshot(void) {
  running();
  footer(2);
  dev[RAM_MIRROR_HEAD + 3] ^= 0x10;
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(1, frames);
  dev[RAM_MIRROR_HEAD + 3] ^= 0x10;
  footer(3);
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT8(0xE6, told[1]); // the next transfer carries the verdict
}

static void test_torn_frame_number(void) {
  running();
  footer(2);
  ftr_of()[0] ^= 1;
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(1, frames);
  TEST_ASSERT_EQUAL_UINT8(0xE4, ram_mirror_verdict);
}

static void test_log_overflow(void) {
  running();
  footer(2);
  ftr_of()[3] = 1;
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(1, frames);
  TEST_ASSERT_EQUAL_UINT8(0xE7, ram_mirror_verdict);
}

/* An underrun with a good checksum did no harm: the snapshot counts, the core hears of it. */
static void test_underrun_keeps_the_snapshot(void) {
  running();
  footer(2);
  ftr_of()[2] = 1;
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(2, frames);
  TEST_ASSERT_EQUAL_UINT8(0xE8, ram_mirror_verdict);
}

/* The log says the last write to byte 5 was 0x77, the snapshot has another value there. An
   earlier entry for the same byte does not count, the walk goes from the end. */
static void test_oracle_catches_a_torn_snapshot(void) {
  running();
  unsigned char *log = dev + RAM_MIRROR_HEAD + DATA;
  dev[RAM_MIRROR_HEAD + 5] = 0x11;
  log[0] = 5; log[1] = 0; log[2] = 0x11;
  log[3] = 5; log[4] = 0; log[5] = 0x77;
  footer(2);
  ftr_of()[6] = 2;
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(1, frames);
  TEST_ASSERT_EQUAL_UINT8(0xE9, ram_mirror_verdict);
  // the entries the other way round: the last write is what the snapshot holds
  log[2] = 0x77;
  log[5] = 0x11;
  footer(3);
  ftr_of()[6] = 2;
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(2, frames);
  TEST_ASSERT_EQUAL_UINT8(0xA5, ram_mirror_verdict);
}

/* A new reset count is a new game for rcheevos, once. A count without its complement is noise. */
static void test_reset_count(void) {
  running();
  unsigned before = resets;
  dev[8]  = 1;
  dev[10] = (unsigned char)~1;
  footer(2);
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(before + 1, resets);
  footer(3);
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(before + 1, resets);
  dev[8] = 2; // its complement still says 1
  footer(4);
  ram_mirror_poll();
  TEST_ASSERT_EQUAL_UINT(before + 1, resets);
  TEST_ASSERT_EQUAL_UINT(4, frames);
}

/* Another core: everything of the old one goes, the board is unknown until a header comes. */
static void test_forget(void) {
  running();
  ram_mirror_forget();
  TEST_ASSERT_EQUAL_UINT8(0, ram_mirror_board);
  TEST_ASSERT_EQUAL_UINT16(0, ram_mirror_tag);
  TEST_ASSERT_EQUAL_UINT(0, adopted);
  header(BOARD + 1, PAGES, TAG + 1);
  TEST_ASSERT_EQUAL_UINT8(0, ram_mirror_probe());
  TEST_ASSERT_EQUAL_UINT8(BOARD + 1, ram_mirror_board);
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_probe_takes_a_good_header);
  RUN_TEST(test_no_core_of_ours);
  RUN_TEST(test_other_layout_is_refused_and_told);
  RUN_TEST(test_broken_headers_are_refused);
  RUN_TEST(test_later_header_must_match);
  RUN_TEST(test_good_snapshot_reaches_rcheevos);
  RUN_TEST(test_harvest_running_waits);
  RUN_TEST(test_bad_checksum_is_no_snapshot);
  RUN_TEST(test_torn_frame_number);
  RUN_TEST(test_log_overflow);
  RUN_TEST(test_underrun_keeps_the_snapshot);
  RUN_TEST(test_oracle_catches_a_torn_snapshot);
  RUN_TEST(test_reset_count);
  RUN_TEST(test_forget);
  return UNITY_END();
}
