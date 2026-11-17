// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_games_list.c
 *  @brief games.c: the Games page's list from the card and a USB drive, and where each line's
 *         core comes from, a file in the drive's cores folder (JTAG) or the flash ring.
 *
 *  games.c is included as a BL616 build has it (ENABLE_JTAG), its list is static. The card
 *  and the drive are RAM disks under the real FatFs, the menu table is the generated one.
 *  Whether a drive is present is mcu_hw_usb_msc_present() below. */
#include <string.h>

#include "unity.h"
#include "host_stubs.h"
#define ENABLE_JTAG
#include "games.c"

static bool usb_present;                               // what mcu_hw_usb_msc_present() returns
static unsigned asked;                                 // calls of it, one per games_usb_core()
static unsigned notified;                              // MENU_EVENT_GAMES_CHANGED sent
bool mcu_hw_usb_msc_present(void) { asked++; return usb_present; }
void menu_notify(unsigned long msg) { if(msg == MENU_EVENT_GAMES_CHANGED) notified++; }

static unsigned char board_a, board_b;                 // two boards of the menu table
static const char *core_a;                             // the core folder of board_a

void setUp(void) {
  TEST_ASSERT_TRUE(host_card_new());
  TEST_ASSERT_TRUE(host_usb_new());
  usb_present = true;
  notified    = 0;
  board_a     = menus_rows[0].board;
  core_a      = menus_rows[0].core;
  for(unsigned i = 1; i < menus_rows_n && !board_b; i++)
    if(menus_rows[i].board != board_a) board_b = menus_rows[i].board;
  TEST_ASSERT_NOT_EQUAL(0, board_b);
}
void tearDown(void) {}

static void put32(unsigned char *p, uint32_t v) {
  for(int i = 0; i < 4; i++) p[i] = (unsigned char)(v >> (8 * i));
}

/* A ROM file as scripts/make_rom.py writes it: some content, then the footer (games_file.c),
   on the card or, for a path in /usb, on the drive. */
static void rom(const char *path, unsigned char board, const char *title) {
  unsigned char f[16 + GAMES_FOOTER_SIZE] = { 0 };
  unsigned char *ft = f + 16;
  TEST_ASSERT_LESS_OR_EQUAL_size_t(GAMES_TITLE_MAX, strlen(title));   // the field's size
  memcpy(ft, "G20K", 4);
  ft[4] = GAMES_FOOTER_VERSION;
  ft[5] = board;
  put32(ft + 8, 16);
  memcpy(ft + 28, title, strlen(title));
  put32(ft + 124, games_crc32(ft, 124));
  TEST_ASSERT_TRUE(strncmp(path, "/usb/", 5) ? host_card_put(path, f, sizeof(f)) : host_usb_put(path, f, sizeof(f)));
}

/* The bitstream of board_a's core in the drive's cores folder. */
static void core_file(void) {
  char path[64];
  snprintf(path, sizeof(path), "/usb/cores/%s.bin", core_a);
  host_usb_mkdir("/usb/cores");   // false when it is there already
  TEST_ASSERT_TRUE(host_usb_put(path, "bitstream", 9));
}

/* The line with this title, fails the test when there is none. */
static games_item_t line(const char *title) {
  games_item_t it;
  for(unsigned i = 0; games_item(i, &it); i++)
    if(!strcmp(it.title, title)) return it;
  TEST_FAIL_MESSAGE(title);
  return it;
}

/** A board whose core is on the drive is USB, another one is flash. */
static void test_core_on_drive_is_usb(void) {
  rom("/sd/a.rom", board_a, "Alpha");
  rom("/sd/b.rom", board_b, "Beta");
  core_file();
  games_read();
  TEST_ASSERT_EQUAL_UINT(2, games_count());
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_USB, line("Alpha").core);
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_FLASH, line("Beta").core);
  TEST_ASSERT_EQUAL_UINT(0, host_sdc_depth());
}

/** Two games of one board: both lines are USB, not only the first one read. */
static void test_same_board_same_source(void) {
  rom("/sd/a.rom", board_a, "Alpha");
  rom("/sd/c.rom", board_a, "Gamma");
  core_file();
  asked = 0;
  games_read();
  TEST_ASSERT_EQUAL_UINT(1, asked);   // the drive once for the board, not once per game
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_USB, line("Alpha").core);
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_USB, line("Gamma").core);
}

/** Without a drive every core is flash, also when the file system still answers. */
static void test_no_drive_is_flash(void) {
  rom("/sd/a.rom", board_a, "Alpha");
  core_file();
  usb_present = false;
  games_read();
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_FLASH, line("Alpha").core);
  // pulled: /usb is gone as well
  host_usb_remove();
  games_read();
  TEST_ASSERT_EQUAL_UINT(1, games_count());
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_FLASH, line("Alpha").core);
}

/** A drive without a cores folder lists its ROMs, their cores come from the flash. */
static void test_drive_without_cores(void) {
  TEST_ASSERT_TRUE(host_usb_mkdir("/usb/roms"));
  rom("/usb/roms/a.rom", board_a, "Alpha");
  games_read();
  TEST_ASSERT_EQUAL_UINT(1, games_count());
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_FLASH, line("Alpha").core);
}

/** A name on the card and on the drive is one line, the drive's other ROMs join it. */
static void test_drive_roms_join(void) {
  rom("/sd/a.rom", board_a, "Alpha");
  TEST_ASSERT_TRUE(host_usb_mkdir("/usb/roms"));
  rom("/usb/roms/a.rom", board_a, "Alpha");
  rom("/usb/roms/b.rom", board_b, "Beta");
  core_file();
  games_read();
  TEST_ASSERT_EQUAL_UINT(2, games_count());
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_USB, line("Alpha").core);
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_FLASH, line("Beta").core);
}

/** The path a core switch loads from, false without a drive, a row or the file. */
static void test_usb_core_path(void) {
  char path[GAMES_PATH_MAX], want[GAMES_PATH_MAX];
  TEST_ASSERT_FALSE(games_usb_core(board_a, path, sizeof(path)));   // no file yet
  core_file();
  snprintf(want, sizeof(want), "/usb/cores/%s.bin", core_a);
  TEST_ASSERT_TRUE(games_usb_core(board_a, path, sizeof(path)));
  TEST_ASSERT_EQUAL_STRING(want, path);
  TEST_ASSERT_FALSE(games_usb_core(board_b, path, sizeof(path)));   // its core is not there
  TEST_ASSERT_FALSE(games_usb_core(0, path, sizeof(path)));         // no board
  TEST_ASSERT_FALSE(games_usb_core(board_a, path, 8));              // the path does not fit
  usb_present = false;
  TEST_ASSERT_FALSE(games_usb_core(board_a, path, sizeof(path)));
}

/** A drive plugged in or pulled reads the list again: the page learns of it once. */
static void test_drive_change_rereads(void) {
  rom("/sd/a.rom", board_a, "Alpha");
  games_read();
  TEST_ASSERT_FALSE(games_stale());
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_FLASH, line("Alpha").core);
  core_file();
  games_changed(NULL);   // what the mount of a drive calls
  games_changed(NULL);
  TEST_ASSERT_TRUE(games_stale());
  TEST_ASSERT_EQUAL_UINT(1, notified);
  games_read();
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_USB, line("Alpha").core);
}

/** The stand-in drive is read only for the firmware as sdc.c makes the real one. */
static void test_drive_is_read_only(void) {
  TEST_ASSERT_FALSE(host_card_put("/usb/x.txt", "x", 1));
  TEST_ASSERT_NOT_EQUAL(FR_OK, f_mkdir("/usb/cores"));
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_core_on_drive_is_usb);
  RUN_TEST(test_same_board_same_source);
  RUN_TEST(test_no_drive_is_flash);
  RUN_TEST(test_drive_without_cores);
  RUN_TEST(test_drive_roms_join);
  RUN_TEST(test_usb_core_path);
  RUN_TEST(test_drive_change_rereads);
  RUN_TEST(test_drive_is_read_only);
  return UNITY_END();
}
