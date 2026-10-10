// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_games_file.c
 *  @brief games_file.c: the footer of a ROM file and the order of the Games page.
 *
 *  games_file.c is included as it is. The reference footer comes from scripts/make_rom.py
 *  footer() at build time (see the Makefile) for 1000 bytes of the counter 0, 1, ... 255, 0, ...
 *  as content, set "testset", title "A Test Game", board 3, screen 2: the firmware must
 *  accept exactly what the script writes. A file on the RAM disk under the real FatFs
 *  shows that games_footer_read() leaves the file position where it was. */
#include <stdlib.h>
#include <string.h>

#include "unity.h"
#include "host_stubs.h"
#include "games_file.c"

void setUp(void) {}
void tearDown(void) {}

#define CONTENT 1000u   // content size of the reference footer

#include "games_footer_ref.h"

/* The reference with byte at changed to value and, when crc is set, a CRC-32 that fits again. */
static void variant(unsigned char *buf, unsigned at, unsigned char value, bool crc) {
  memcpy(buf, ref, sizeof(ref));
  buf[at] = value;
  if(crc) {
    uint32_t c = games_crc32(buf, 124);
    for(int i = 0; i < 4; i++) buf[124 + i] = (unsigned char)(c >> (8 * i));
  }
}

static void test_valid_footer(void) {
  games_footer_t ft;
  TEST_ASSERT_TRUE(games_footer_parse(ref, CONTENT + GAMES_FOOTER_SIZE, &ft));
  TEST_ASSERT_EQUAL_UINT8(3, ft.board);
  TEST_ASSERT_EQUAL_UINT8(2, ft.screen);
  TEST_ASSERT_EQUAL_UINT32(CONTENT, ft.content);
  TEST_ASSERT_EQUAL_STRING("testset", ft.set);
  TEST_ASSERT_EQUAL_STRING("A Test Game", ft.title);
  TEST_ASSERT_EQUAL_MEMORY(ref + 76, ft.sha, 32);
}

static void test_full_fields_end_with_nul(void) {
  // a set of 16 and a title of 48 characters fill their fields without a NUL
  unsigned char buf[GAMES_FOOTER_SIZE];
  games_footer_t ft;
  memcpy(buf, ref, sizeof(ref));
  memset(buf + 12, 'S', 16);
  memset(buf + 28, 'T', 48);
  uint32_t c = games_crc32(buf, 124);
  for(int i = 0; i < 4; i++) buf[124 + i] = (unsigned char)(c >> (8 * i));
  TEST_ASSERT_TRUE(games_footer_parse(buf, CONTENT + GAMES_FOOTER_SIZE, &ft));
  TEST_ASSERT_EQUAL_size_t(16, strlen(ft.set));
  TEST_ASSERT_EQUAL_size_t(48, strlen(ft.title));
}

static void test_bad_magic(void) {
  unsigned char buf[GAMES_FOOTER_SIZE];
  games_footer_t ft;
  // with a CRC that fits: the magic itself must be checked
  variant(buf, 0, 'g', true);
  TEST_ASSERT_FALSE(games_footer_parse(buf, CONTENT + GAMES_FOOTER_SIZE, &ft));
  variant(buf, 3, 'X', true);
  TEST_ASSERT_FALSE(games_footer_parse(buf, CONTENT + GAMES_FOOTER_SIZE, &ft));
  // another version is another layout
  variant(buf, 4, 2, true);
  TEST_ASSERT_FALSE(games_footer_parse(buf, CONTENT + GAMES_FOOTER_SIZE, &ft));
}

static void test_bad_crc(void) {
  unsigned char buf[GAMES_FOOTER_SIZE];
  games_footer_t ft;
  unsigned refused = 0;
  // any one byte of 0 to 123 changed without a new CRC, and the CRC itself changed
  for(unsigned at = 0; at < GAMES_FOOTER_SIZE; at++) {
    variant(buf, at, (unsigned char)(ref[at] ^ 0x01), false);
    if(!games_footer_parse(buf, CONTENT + GAMES_FOOTER_SIZE, &ft)) refused++;
  }
  TEST_ASSERT_EQUAL_UINT(GAMES_FOOTER_SIZE, refused);
  char msg[48];
  snprintf(msg, sizeof(msg), "%u of %u one-bit changes refused", refused, GAMES_FOOTER_SIZE);
  TEST_MESSAGE(msg);
}

static void test_size_mismatch(void) {
  games_footer_t ft;
  // a file cut or extended by one byte, the footer alone, a file shorter than a footer
  TEST_ASSERT_FALSE(games_footer_parse(ref, CONTENT + GAMES_FOOTER_SIZE - 1, &ft));
  TEST_ASSERT_FALSE(games_footer_parse(ref, CONTENT + GAMES_FOOTER_SIZE + 1, &ft));
  TEST_ASSERT_FALSE(games_footer_parse(ref, GAMES_FOOTER_SIZE, &ft));
  TEST_ASSERT_FALSE(games_footer_parse(ref, GAMES_FOOTER_SIZE - 1, &ft));
  TEST_ASSERT_FALSE(games_footer_parse(ref, 0, &ft));
}

/* Writes a file of the reference content with tail behind it. */
static bool put_rom(const char *path, const unsigned char *tail, size_t tail_len) {
  size_t n = CONTENT + tail_len;
  unsigned char *buf = malloc(n);
  bool ok;
  for(unsigned i = 0; i < CONTENT; i++) buf[i] = (unsigned char)i;
  memcpy(buf + CONTENT, tail, tail_len);
  ok = host_card_put(path, buf, n);
  free(buf);
  return ok;
}

static void test_footer_read_on_card(void) {
  FIL f;
  games_footer_t ft;
  unsigned char b[4];
  UINT n;
  TEST_ASSERT_TRUE(host_card_new());
  TEST_ASSERT_TRUE(put_rom("/sd/test.rom", ref, sizeof(ref)));
  TEST_ASSERT_TRUE(put_rom("/sd/old.rom", ref, 64));   // no footer: content plus half a footer
  TEST_ASSERT_TRUE(host_card_put("/sd/tiny.rom", "G20K", 4));

  TEST_ASSERT_EQUAL(FR_OK, f_open(&f, "/sd/test.rom", FA_READ));
  // from the middle of the file: the position is the same afterwards
  TEST_ASSERT_EQUAL(FR_OK, f_lseek(&f, 600));
  TEST_ASSERT_TRUE(games_footer_read(&f, &ft));
  TEST_ASSERT_EQUAL_UINT32(CONTENT, ft.content);
  TEST_ASSERT_EQUAL_STRING("A Test Game", ft.title);
  TEST_ASSERT_EQUAL_UINT32(600, f_tell(&f));
  TEST_ASSERT_EQUAL(FR_OK, f_read(&f, b, sizeof(b), &n));
  TEST_ASSERT_EQUAL_UINT8(600 & 0xff, b[0]);
  f_close(&f);

  TEST_ASSERT_EQUAL(FR_OK, f_open(&f, "/sd/old.rom", FA_READ));
  TEST_ASSERT_FALSE(games_footer_read(&f, &ft));
  TEST_ASSERT_EQUAL_UINT32(0, f_tell(&f));
  f_close(&f);

  TEST_ASSERT_EQUAL(FR_OK, f_open(&f, "/sd/tiny.rom", FA_READ));
  TEST_ASSERT_FALSE(games_footer_read(&f, &ft));
  f_close(&f);
}

static int cmp(const void *a, const void *b) {
  const char *const *x = a, *const *y = b;
  return games_order(x[0], x[1], y[0], y[1]);
}

static void test_order_by_title(void) {
  // title, file name: shuffled, then sorted as the page shows them
  const char *rows[][2] = {
    { "Pac-Man (speedup)", "pacmanf.rom" }, { "galaga", "zz.rom" },  { "1943", "1943.rom" },
    { "Ms. Pac-Man", "mspacman.rom" },      { "Galaga", "galaga.rom" }, { "1942", "1942.rom" },
    { "Pac-Man", "pacman.rom" },            { "Dig Dug", "digdug.rom" }, { "Galaga", "galaga2.rom" },
  };
  const char *want[] = { "1942.rom", "1943.rom", "digdug.rom", "galaga.rom", "galaga2.rom", "zz.rom",
                         "mspacman.rom", "pacman.rom", "pacmanf.rom" };
  size_t n = sizeof(rows) / sizeof(rows[0]);
  qsort(rows, n, sizeof(rows[0]), cmp);
  for(size_t i = 0; i < n; i++) TEST_ASSERT_EQUAL_STRING(want[i], rows[i][1]);
  // case does not count for the title, the name breaks a tie
  TEST_ASSERT_TRUE(games_order("galaga", "a.rom", "GALAGA", "b.rom") < 0);
  TEST_ASSERT_TRUE(games_order("Galaga", "b.rom", "galaga", "a.rom") > 0);
  TEST_ASSERT_EQUAL_INT(0, games_order("Galaga", "a.rom", "Galaga", "a.rom"));
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_valid_footer);
  RUN_TEST(test_full_fields_end_with_nul);
  RUN_TEST(test_bad_magic);
  RUN_TEST(test_bad_crc);
  RUN_TEST(test_size_mismatch);
  RUN_TEST(test_footer_read_on_card);
  RUN_TEST(test_order_by_title);
  return UNITY_END();
}
