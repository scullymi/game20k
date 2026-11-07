// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_banner.c
 *  @brief The banner: how a text fits, the queue, what goes to the core, which mode the player is told.
 *
 *  banner.c is included, its state is static. The RA task and the game are stand-ins. */
#include <string.h>

#include "unity.h"
#include "host_stubs.h"
#include "banner.c"

#pragma GCC diagnostic ignored "-Wunused-parameter"

// the clock and the rest of the firmware
static TickType_t now_ticks = 1000;
TickType_t xTaskGetTickCount(void) { return now_ticks; }

static unsigned generation, blocked_bits;
static ra_task_state_t task_state = RA_TASK_LOGGED_IN;
static bool hardcore, wanted = true, due, rom_pending, set_pending, new_core, dips_ok = true;
static const char *server_warning;
unsigned game_generation(void) { return generation; }
ra_task_state_t ra_task_state(void) { return task_state; }
bool ra_task_hardcore(void) { return hardcore; }
bool ra_task_hardcore_wanted(void) { return wanted; }
bool ra_task_hardcore_due(void) { return due; }
unsigned ra_task_hardcore_blocked(void) { return blocked_bits; }
bool game_rom_pending(void) { return rom_pending; }
bool ra_patch_set_pending(void) { return set_pending; }
bool game_new_core_pending(void) { return new_core; }
unsigned game_id(void) { return 1; }
const char *game_hash(void) { return "abc"; }
bool menu_dips_as_expected(void) { return dips_ok; }
char *inifile_config_get_str(char *section, char *name) { return "scullymi"; }
bool ra_task_lboard_result(unsigned *seen, ra_lboard_result_t *out) { return false; }
bool ra_patch_warning(char *out, size_t size) {
  if(!server_warning) return false;
  if(out) snprintf(out, size, "%s", server_warning);
  return true;
}

static void expect_text(const char *want, const banner_t *b) {
  char text[BANNER_LEN + 1];
  snprintf(text, sizeof(text), "%-*s", BANNER_LEN, want);
  TEST_ASSERT_EQUAL_MEMORY(text, b->text, BANNER_LEN);
}

/* Nothing queued, nothing shown. */
void setUp(void) {
  banner_n = 0;
  banner_live = banner_pending = banner_mode_due = banner_progress_due = false;
  banner_pos = 0;
  blocked_bits = 0;
  task_state = RA_TASK_LOGGED_IN;
  hardcore = false;
  wanted = true;
  due = rom_pending = set_pending = new_core = false;
  dips_ok = true;
  server_warning = NULL;
}
void tearDown(void) {}

static void test_fill_fits_the_font(void) {
  banner_t b;
  banner_fill(&b, "Ab-1:x!.Z", false, false, 1);
  expect_text("AB-1:X!.Z", &b);
  banner_fill(&b, "a_b%c", false, false, 1);
  expect_text("A B C", &b);
}

/* A longer text ends at a word when one ends in the last third, else where the line ends. */
static void test_fill_cuts_at_a_word(void) {
  banner_t b;
  banner_fill(&b, "BOSS GALAGA WIPEOUT WITHOUT A SINGLE LOSS", false, false, 1);
  expect_text("BOSS GALAGA WIPEOUT", &b);
  banner_fill(&b, "ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEF", false, false, 1);
  TEST_ASSERT_EQUAL_MEMORY("ABCDEFGHIJKLMNOPQRSTUVWX", b.text, BANNER_LEN);
}

static void test_queue_holds_four(void) {
  for(int i = 0; i < BANNER_QUEUE; i++) TEST_ASSERT_NOT_NULL(banner_show("X", false, false));
  TEST_ASSERT_NULL(banner_show("ONE TOO MANY", false, false));
  TEST_ASSERT_EQUAL_UINT(BANNER_QUEUE, banner_n);
}

/* One character per poll, the show flag only once the whole text is in the core. */
static void test_step_sends_then_shows(void) {
  unsigned char hdr[8];
  banner_show("HELLO", true, true);
  for(unsigned i = 0; i < BANNER_LEN; i++) {
    banner_step(hdr);
    TEST_ASSERT_EQUAL_UINT8(i, hdr[6] & 0x1f);
    TEST_ASSERT_EQUAL_UINT8(0x60, hdr[6] & 0xe0); // gold, green, not shown yet
    TEST_ASSERT_EQUAL_UINT8(i < 5 ? "HELLO"[i] : ' ', hdr[7]);
  }
  banner_step(hdr);
  TEST_ASSERT_EQUAL_UINT8(0x80, hdr[6] & 0x80);
}

/* A banner ends after its time, the next one follows. */
static void test_next_banner_after_its_time(void) {
  unsigned char hdr[8];
  banner_show("ONE", false, false);
  banner_show("TWO", false, false);
  for(unsigned i = 0; i <= BANNER_LEN; i++) banner_step(hdr);
  TEST_ASSERT_TRUE(banner_live);
  expect_text("ONE", &banner);
  now_ticks += pdMS_TO_TICKS(BANNER_MS);
  banner_step(hdr);
  expect_text("TWO", &banner);
}

/* Progress waits for every other banner and only the newest counts, % reads PCT. */
static void test_progress_only_when_nothing_waits(void) {
  unsigned char hdr[8];
  banner_show("FIRST", false, false);
  banner_show_progress("3/5", "OLD", false);
  banner_show_progress("37%", "TITLE", false);
  banner_step(hdr);
  expect_text("FIRST", &banner);
  for(unsigned i = 0; i < BANNER_LEN; i++) banner_step(hdr);
  now_ticks += pdMS_TO_TICKS(BANNER_MS);
  banner_step(hdr);
  expect_text("37 PCT TITLE", &banner);
}

/* Another game: its banners go, one about the account stays, also when it shows. */
static void test_game_change_clears_but_keeps_the_account(void) {
  banner_show("GAME", false, false);
  banner_show_kept("ACCOUNT", false, false);
  banner_show_progress("1/2", "GAME", false);
  generation++;
  banner_follow_game();
  TEST_ASSERT_EQUAL_UINT(1, banner_n);
  expect_text("ACCOUNT", &banner_q[0]);
  TEST_ASSERT_FALSE(banner_progress_due);
  // shown already
  unsigned char hdr[8];
  for(unsigned i = 0; i <= BANNER_LEN; i++) banner_step(hdr);
  TEST_ASSERT_TRUE(banner_live);
  generation++;
  banner_follow_game();
  TEST_ASSERT_TRUE(banner_live);
}

/* The mode banner of a game start with the blocks as given. */
static const char *mode_text(unsigned block) {
  static char text[BANNER_LEN + 1];
  setUp();
  blocked_bits = block;
  banner_login(); // the account's banner, if any
  banner_n = 0;
  banner_ask_mode();
  banner_login();
  if(!banner_n) return "";
  snprintf(text, sizeof(text), "%.*s", BANNER_LEN, banner_q[0].text);
  for(int i = BANNER_LEN - 1; i >= 0 && text[i] == ' '; i--) text[i] = 0;
  return text;
}

/* Softcore names the reason, the most telling one first: a wrong game also explains an unknown ROM. */
static void test_softcore_names_its_reason(void) {
  TEST_ASSERT_EQUAL_STRING("RA: SOFTCORE TEST CORE", mode_text(RA_HC_BLOCK_CORE | RA_HC_BLOCK_ROM));
  TEST_ASSERT_EQUAL_STRING("RA: SOFTCORE CONFIG.XML", mode_text(RA_HC_BLOCK_XML));
  TEST_ASSERT_EQUAL_STRING("RA: SOFTCORE MISMATCH", mode_text(RA_HC_BLOCK_MENU));
  TEST_ASSERT_EQUAL_STRING("RA: SOFTCORE KEY ERROR", mode_text(RA_HC_BLOCK_KEY));
  TEST_ASSERT_EQUAL_STRING("RA: SOFTCORE SET TOO BIG", mode_text(RA_HC_BLOCK_SIZE));
  TEST_ASSERT_EQUAL_STRING("RA: SOFTCORE WRONG GAME", mode_text(RA_HC_BLOCK_GAME | RA_HC_BLOCK_ROM));
  TEST_ASSERT_EQUAL_STRING("RA: SOFTCORE ROM UNKNOWN", mode_text(RA_HC_BLOCK_ROM));
  TEST_ASSERT_EQUAL_STRING("RA: SOFTCORE TILL ONLINE", mode_text(RA_HC_BLOCK_SET));
}

/* The mode is not told too early: a stream, a set still read, hardcore not yet applied. */
static void test_mode_waits(void) {
  rom_pending = true;
  banner_ask_mode();
  banner_login();
  unsigned n = banner_n;
  TEST_ASSERT_TRUE(banner_mode_due);
  rom_pending = false;
  set_pending = true;
  banner_login();
  TEST_ASSERT_TRUE(banner_mode_due);
  set_pending = false;
  due = true;
  banner_login();
  TEST_ASSERT_TRUE(banner_mode_due);
  due = false;
  banner_login();
  TEST_ASSERT_FALSE(banner_mode_due);
  TEST_ASSERT_EQUAL_UINT(n + 1, banner_n);
}

/* In hardcore the server's warning follows the mode, and a DIP switch the set does not expect. */
static void test_hardcore_with_warning_and_dip(void) {
  hardcore = true;
  server_warning = "UNKNOWN EMULATOR";
  dips_ok = false;
  banner_login();
  banner_n = 0;
  banner_ask_mode();
  banner_login();
  TEST_ASSERT_EQUAL_UINT(3, banner_n);
  expect_text("RA: HARDCORE", &banner_q[0]);
  expect_text("RA: UNKNOWN EMULATOR", &banner_q[1]);
  expect_text(BANNER_DIP, &banner_q[2]);
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_fill_fits_the_font);
  RUN_TEST(test_fill_cuts_at_a_word);
  RUN_TEST(test_queue_holds_four);
  RUN_TEST(test_step_sends_then_shows);
  RUN_TEST(test_next_banner_after_its_time);
  RUN_TEST(test_progress_only_when_nothing_waits);
  RUN_TEST(test_game_change_clears_but_keeps_the_account);
  RUN_TEST(test_softcore_names_its_reason);
  RUN_TEST(test_mode_waits);
  RUN_TEST(test_hardcore_with_warning_and_dip);
  return UNITY_END();
}
