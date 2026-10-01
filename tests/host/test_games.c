// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_games.c
 *  @brief ra_games.c: ra_games_by_file(), the file name that starts the core switch.
 *
 *  ra_games.c is included as it is, with rcheevos' md5 for ra_games_name_hash().
 *  A ROM file picked in the menu switches the core when it is the set name of a
 *  game of another board plus ".rom", case ignored. A near miss must name no game:
 *  it streams to the running core as before. */
#include <string.h>

#include "unity.h"
#include "host_stubs.h"
#include "rcheevos/src/rhash/md5.c"
#include "ra_games.c"

void setUp(void) {}
void tearDown(void) {}

/** The id of the game the file names, 0 for none. */
static unsigned id_of(const char *name) {
  const ra_game_t *g = ra_games_by_file(name);
  return g ? g->id : 0;
}

static void test_by_file_names_the_set(void) {
  TEST_ASSERT_EQUAL_UINT(12138u, id_of("galaga.rom"));
  TEST_ASSERT_EQUAL_UINT(12192u, id_of("pacman.rom"));
  TEST_ASSERT_EQUAL_UINT(24933u, id_of("puckman.rom"));
}

static void test_by_file_ignores_case(void) {
  // FAT keeps the case the card writer chose, an 8.3 name often in capitals
  TEST_ASSERT_EQUAL_UINT(12138u, id_of("GALAGA.ROM"));
  TEST_ASSERT_EQUAL_UINT(24933u, id_of("PuckMan.Rom"));
}

static void test_by_file_near_misses(void) {
  static const char *const names[] = {
    "galaga", "galaga.", "galaga.ro", "galaga.rom.bak", "galaga.romx", "galag.rom",
    "galagax.rom", "xgalaga.rom", " galaga.rom", "galaga .rom", ".rom", "", "pac.rom",
    "pacmanpuckman.rom", "galaga.zip",
  };
  unsigned i;
  for(i = 0; i < sizeof(names) / sizeof(names[0]); i++)
    TEST_ASSERT_EQUAL_UINT_MESSAGE(0, id_of(names[i]), names[i]);
  TEST_ASSERT_NULL(ra_games_by_file(NULL));
  char msg[48];
  snprintf(msg, sizeof(msg), "%u near misses and NULL named no game", i);
  TEST_MESSAGE(msg);
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_by_file_names_the_set);
  RUN_TEST(test_by_file_ignores_case);
  RUN_TEST(test_by_file_near_misses);
  return UNITY_END();
}
