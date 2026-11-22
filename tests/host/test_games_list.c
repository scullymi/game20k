// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_games_list.c
 *  @brief games.c: the Games page's list from the card and a USB drive, where each line's
 *         core comes from, a file in the drive's cores folder (JTAG) or the flash ring, the
 *         start game, and the waits for a drive that mounts after the start.
 *
 *  games.c is included as a BL616 build has it (ENABLE_JTAG), its list is static. The card
 *  and the drive are RAM disks under the real FatFs, the menu table is the generated one.
 *  Whether a drive is present is mcu_hw_usb_msc_present() below. The clock starts at 0 with
 *  each test and only vTaskDelay() moves it on. */
#include <string.h>

#include "unity.h"
#include "host_stubs.h"
#define ENABLE_JTAG
#include "games.c"

static bool usb_present;                               // what mcu_hw_usb_msc_present() returns
static unsigned asked;                                 // calls of it, one per games_usb_core()
static unsigned notified;                              // MENU_EVENT_GAMES_CHANGED sent
static unsigned missing;                               // MENU_EVENT_USB_MISSING sent
bool mcu_hw_usb_msc_present(void) { asked++; return usb_present; }
void menu_notify(unsigned long msg) {
  if(msg == MENU_EVENT_GAMES_CHANGED) notified++;
  if(msg == MENU_EVENT_USB_MISSING) missing++;
}

// the clock: each wait moves it on, and the drive shows up once it reaches drive_at (0: never)
static TickType_t now, drive_at;
static unsigned delays;
TickType_t xTaskGetTickCount(void) { return now; }
void vTaskDelay(TickType_t ticks) {
  delays++;
  now += ticks;
  if(drive_at && now >= drive_at) usb_present = true;
}

// the default image of each drive and its folder, as sdc.c holds them after the ini
static const char *cwd_of[MAX_DRIVES + MAX_IMAGES], *image_of[MAX_DRIVES + MAX_IMAGES];
char *sdc_get_cwd(int drive) { return (char *)cwd_of[drive]; }
char *sdc_get_image_name(int drive) { return (char *)image_of[drive]; }

// the running core's scan of the flash, as ram_mirror.c holds it
unsigned char ram_mirror_slots[RAM_MIRROR_SLOTS];
bool ram_mirror_slots_known;

static unsigned char board_a, board_b;                 // two boards of the menu table
static const char *core_a;                             // the core folder of board_a

void setUp(void) {
  games_usb_unmount();   // games.c mounts the drive itself, the test's mount comes next
  (void)games_usb_missed();
  TEST_ASSERT_TRUE(host_card_new());
  TEST_ASSERT_TRUE(host_usb_new());
  usb_present = true;
  notified = missing = delays = 0;
  now = drive_at = 0;
  memset(cwd_of, 0, sizeof(cwd_of));
  memset(image_of, 0, sizeof(image_of));
  memset(ram_mirror_slots, 0, sizeof(ram_mirror_slots));
  ram_mirror_slots_known = false;
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

/** A board the scan of the flash does not hold and no drive has: no core. On the drive or in
    the flash it has one. */
static void test_no_core(void) {
  rom("/sd/a.rom", board_a, "Alpha");
  rom("/sd/b.rom", board_b, "Beta");
  ram_mirror_slots[0]    = board_a;
  ram_mirror_slots_known = true;
  games_read();
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_FLASH, line("Alpha").core);
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_NONE, line("Beta").core);
  ram_mirror_slots[0] = board_b;
  core_file(); // board_a's core on the drive
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_USB, games_core_of(board_a));
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_FLASH, games_core_of(board_b));
}

/** Without a scan of the flash every core counts as there, as before the scan. */
static void test_no_scan_is_flash(void) {
  rom("/sd/b.rom", board_b, "Beta");
  games_read();
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_FLASH, line("Beta").core);
  TEST_ASSERT_EQUAL_INT(GAMES_CORE_FLASH, games_core_of(board_b));
}

/* The running ROM as sdc.c holds it: Save settings makes it the start game. */
static void running(const char *dir, const char *name) {
  cwd_of[MAX_DRIVES + GAME_ROM_IMAGE]   = dir;
  image_of[MAX_DRIVES + GAME_ROM_IMAGE] = name;
}

/* The start game's line in GAMES_START_FILE, "" without one. */
static const char *start_line(void) {
  static char l[GAMES_PATH_MAX + 16];
  FIL f;
  l[0] = 0;
  if(f_open(&f, GAMES_START_FILE, FA_READ) != FR_OK) return l;
  while(f_gets(l, sizeof(l), &f) && strncmp(l, "start=", 6)) l[0] = 0;
  f_close(&f);
  l[strcspn(l, "\r\n")] = 0;
  return l;
}

/* The drive is there, but games.c has not mounted it yet: the state right after the start. */
static void drive_later(TickType_t at) {
  games_usb_unmount();
  usb_present = false;
  drive_at    = at;
}

/** Save settings with a ROM from the drive's roms folder: it is the start game, with its path. */
static void test_start_on_drive(void) {
  char name[FF_LFN_BUF + 1];
  games_footer_t ft;
  TEST_ASSERT_TRUE(host_usb_mkdir("/usb/roms"));
  rom("/usb/roms/a.rom", board_a, "Alpha");
  running("/usb/roms", "a.rom");
  games_save_start();
  TEST_ASSERT_EQUAL_STRING("start=/usb/roms/a.rom", start_line());
  TEST_ASSERT_TRUE(games_start_file(name, sizeof(name), &ft));
  TEST_ASSERT_EQUAL_STRING("a.rom", name);
  TEST_ASSERT_EQUAL_UINT8(board_a, ft.board);
  TEST_ASSERT_EQUAL_UINT(0, host_sdc_depth());
}

/** A ROM in the card's root: the line names the path, and nothing waits for a drive. */
static void test_start_on_card(void) {
  char name[FF_LFN_BUF + 1];
  games_footer_t ft;
  rom("/sd/a.rom", board_a, "Alpha");
  running("/sd", "a.rom");
  games_save_start();
  TEST_ASSERT_EQUAL_STRING("start=/sd/a.rom", start_line());
  usb_present = false;
  TEST_ASSERT_TRUE(games_start_file(name, sizeof(name), &ft));
  TEST_ASSERT_EQUAL_STRING("a.rom", name);
  TEST_ASSERT_EQUAL_UINT(0, delays);
}

/** A ROM outside the list's folders, here the drive's root, removes the start game. */
static void test_start_elsewhere(void) {
  char name[FF_LFN_BUF + 1];
  games_footer_t ft;
  rom("/sd/a.rom", board_a, "Alpha");
  running("/sd", "a.rom");
  games_save_start();
  rom("/usb/b.rom", board_b, "Beta");
  running("/usb", "b.rom");
  games_save_start();
  TEST_ASSERT_EQUAL_STRING("", start_line());
  TEST_ASSERT_FALSE(games_start_file(name, sizeof(name), &ft));
}

/** A line with a bare name or a folder the list does not read: no start game, no wait. */
static void test_start_old_or_foreign(void) {
  static const char *const lines[] = { "start=a.rom\n", "start=/sd/sub/a.rom\n", "start=/usb/a.rom\n",
                                       "start=/usb/roms/\n" };
  char name[FF_LFN_BUF + 1];
  games_footer_t ft;
  rom("/sd/a.rom", board_a, "Alpha");
  drive_later(0);
  for(unsigned i = 0; i < sizeof(lines) / sizeof(lines[0]); i++) {
    TEST_ASSERT_TRUE(host_card_put(GAMES_START_FILE, lines[i], strlen(lines[i])));
    TEST_ASSERT_FALSE_MESSAGE(games_start_file(name, sizeof(name), &ft), lines[i]);
  }
  TEST_ASSERT_EQUAL_UINT(0, delays);
}

/** At power-on the drive mounts after the start file is read: the start game waits for it. */
static void test_start_waits_for_drive(void) {
  char name[FF_LFN_BUF + 1];
  games_footer_t ft;
  TEST_ASSERT_TRUE(host_usb_mkdir("/usb/roms"));
  rom("/usb/roms/a.rom", board_a, "Alpha");
  running("/usb/roms", "a.rom");
  games_save_start();
  drive_later(2300);
  TEST_ASSERT_TRUE(games_start_file(name, sizeof(name), &ft));
  TEST_ASSERT_GREATER_OR_EQUAL_UINT32(2300, now);
  TEST_ASSERT_LESS_THAN_UINT32(GAMES_USB_WAIT_MS, now);
  TEST_ASSERT_FALSE(games_usb_missed());
  TEST_ASSERT_EQUAL_UINT(0, host_sdc_depth());
}

/** No drive by GAMES_USB_WAIT_MS after the start: no start game, and the miss is told once. */
static void test_start_drive_missing(void) {
  char name[FF_LFN_BUF + 1];
  games_footer_t ft;
  TEST_ASSERT_TRUE(host_usb_mkdir("/usb/roms"));
  rom("/usb/roms/a.rom", board_a, "Alpha");
  running("/usb/roms", "a.rom");
  games_save_start();
  drive_later(0);
  TEST_ASSERT_FALSE(games_start_file(name, sizeof(name), &ft));
  TEST_ASSERT_GREATER_OR_EQUAL_UINT32(GAMES_USB_WAIT_MS, now);
  TEST_ASSERT_LESS_THAN_UINT32(GAMES_USB_WAIT_MS + 1000, now);
  TEST_ASSERT_TRUE(games_usb_missed());
  TEST_ASSERT_FALSE(games_usb_missed());
}

/** Later than GAMES_USB_WAIT_MS after the start nothing waits: a drive not mounted by then is not
    there, and the menu is not told it came too late. */
static void test_no_wait_later(void) {
  drive_later(0);
  now = GAMES_USB_WAIT_MS + 1000;
  TEST_ASSERT_FALSE(games_usb_wait());
  TEST_ASSERT_EQUAL_UINT(0, delays);
  TEST_ASSERT_FALSE(games_usb_missed());
  // a drive mounted then is there at once
  usb_present = true;
  TEST_ASSERT_TRUE(games_usb_wait());
  TEST_ASSERT_EQUAL_UINT(0, delays);
}

/** The same name on the card and on the drive: the switch finds the card's file by the name, so
    its footer gives the board, also for a start game saved from the drive. */
static void test_start_same_name_takes_card(void) {
  char name[FF_LFN_BUF + 1];
  games_footer_t ft;
  rom("/sd/a.rom", board_a, "Alpha");
  TEST_ASSERT_TRUE(host_usb_mkdir("/usb/roms"));
  rom("/usb/roms/a.rom", board_b, "Beta");
  running("/usb/roms", "a.rom");
  games_save_start();
  TEST_ASSERT_TRUE(games_start_file(name, sizeof(name), &ft));
  TEST_ASSERT_EQUAL_UINT8(board_a, ft.board);
}

/** A start game whose folder has other case is on the drive as well and waits for it. */
static void test_start_upper_case_waits(void) {
  char name[FF_LFN_BUF + 1];
  games_footer_t ft;
  TEST_ASSERT_TRUE(host_usb_mkdir("/usb/roms"));
  rom("/usb/roms/a.rom", board_a, "Alpha");
  TEST_ASSERT_TRUE(host_card_put(GAMES_START_FILE, "start=/USB/roms/a.rom\n", 22));
  drive_later(700);
  TEST_ASSERT_TRUE(games_start_file(name, sizeof(name), &ft));
  TEST_ASSERT_GREATER_OR_EQUAL_UINT32(700, now);
}

/** A game picked from the drive after a restart that left it unmounted, as the Pico's for a core
    switch: the search waits for the drive. A game on the card is found without a wait. */
static void test_find_waits_for_drive(void) {
  char path[GAMES_PATH_MAX];
  rom("/sd/a.rom", board_a, "Alpha");
  TEST_ASSERT_TRUE(host_usb_mkdir("/usb/roms"));
  rom("/usb/roms/b.rom", board_b, "Beta");
  drive_later(1500);
  TEST_ASSERT_TRUE(games_find(games_name_crc("a.rom"), path, sizeof(path)));
  TEST_ASSERT_EQUAL_STRING("/sd/a.rom", path);
  TEST_ASSERT_EQUAL_UINT(0, delays);
  TEST_ASSERT_TRUE(games_find(games_name_crc("b.rom"), path, sizeof(path)));
  TEST_ASSERT_EQUAL_STRING("/usb/roms/b.rom", path);
  TEST_ASSERT_GREATER_OR_EQUAL_UINT32(1500, now);
  TEST_ASSERT_EQUAL_UINT(0, host_sdc_depth());
}

/** An image of the ini on the drive waits for it before the images mount, one on the card does
    not. A drive that never comes shows in the menu. */
static void test_defaults_wait(void) {
  drive_later(0);
  running("/sd", "a.rom");
  games_usb_defaults();
  TEST_ASSERT_EQUAL_UINT(0, delays);
  TEST_ASSERT_EQUAL_UINT(0, missing);
  running("/usb/roms", "a.rom");
  drive_at = 800;
  games_usb_defaults();
  TEST_ASSERT_GREATER_OR_EQUAL_UINT32(800, now);
  TEST_ASSERT_EQUAL_UINT(0, missing);
  drive_later(0);
  now = 0;
  games_usb_defaults();
  TEST_ASSERT_EQUAL_UINT(1, missing);
  // a folder only, as the file selector leaves it, has no image to wait for
  drive_later(0);
  now = 0;
  delays = 0;
  running("/usb/roms", NULL);
  games_usb_defaults();
  TEST_ASSERT_EQUAL_UINT(0, delays);
}

/** A start game on the card whose core only the drive has: the start waits for the drive, the
    core switch to it loads from there. Its core in the flash needs no wait. */
static void test_start_core_on_drive_waits(void) {
  char name[FF_LFN_BUF + 1];
  games_footer_t ft;
  rom("/sd/b.rom", board_b, "Beta");
  running("/sd", "b.rom");
  games_save_start();
  ram_mirror_slots[0]    = board_a;
  ram_mirror_slots_known = true;
  drive_later(1200);
  TEST_ASSERT_TRUE(games_start_file(name, sizeof(name), &ft));
  TEST_ASSERT_GREATER_OR_EQUAL_UINT32(1200, now);
  ram_mirror_slots[0] = board_b;
  drive_later(0);
  now = delays = 0;
  TEST_ASSERT_TRUE(games_start_file(name, sizeof(name), &ft));
  TEST_ASSERT_EQUAL_UINT(0, delays);
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
  RUN_TEST(test_no_core);
  RUN_TEST(test_no_scan_is_flash);
  RUN_TEST(test_start_on_drive);
  RUN_TEST(test_start_on_card);
  RUN_TEST(test_start_elsewhere);
  RUN_TEST(test_start_old_or_foreign);
  RUN_TEST(test_start_waits_for_drive);
  RUN_TEST(test_start_drive_missing);
  RUN_TEST(test_no_wait_later);
  RUN_TEST(test_start_same_name_takes_card);
  RUN_TEST(test_start_upper_case_waits);
  RUN_TEST(test_find_waits_for_drive);
  RUN_TEST(test_defaults_wait);
  RUN_TEST(test_start_core_on_drive_waits);
  return UNITY_END();
}
