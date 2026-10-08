// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_games.c
 *  @brief ra_games.c: ra_games_by_file(), the file name that starts the core switch, and
 *         ra_games_row()/ra_games_at(), the row the restart mark keeps.
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
  TEST_ASSERT_EQUAL_UINT(11800u, id_of("mspacman.rom"));
  TEST_ASSERT_EQUAL_UINT(11919u, id_of("pacplus.rom"));
  TEST_ASSERT_EQUAL_UINT(11918u, id_of("ponpoko.rom"));
  TEST_ASSERT_EQUAL_UINT(11960u, id_of("1942.rom"));
  TEST_ASSERT_EQUAL_UINT(11961u, id_of("1943.rom"));
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
    "pacmanpuckman.rom", "galaga.zip", "mspacma.rom", "ms.rom", "1942a.rom", "194.rom",
    "1943kai.rom",
  };
  unsigned i;
  for(i = 0; i < sizeof(names) / sizeof(names[0]); i++)
    TEST_ASSERT_EQUAL_UINT_MESSAGE(0, id_of(names[i]), names[i]);
  TEST_ASSERT_NULL(ra_games_by_file(NULL));
  char msg[48];
  snprintf(msg, sizeof(msg), "%u near misses and NULL named no game", i);
  TEST_MESSAGE(msg);
}

/** The restart mark keeps the row, not the id: makaimurg shares 12149 with gng, and the
 *  id would bring back gng. Every row must come back as itself. */
static void test_row_tells_shared_ids_apart(void) {
  const ra_game_t *m = ra_games_by_file("makaimurg.rom");
  TEST_ASSERT_NOT_NULL(m);
  TEST_ASSERT_EQUAL_STRING("gng", ra_games_by_id(m->id)->set);
  TEST_ASSERT_EQUAL_PTR(m, ra_games_at(ra_games_row(m)));
  unsigned row = 0;
  for(const ra_game_t *g; (g = ra_games_at(row)) != NULL; row++)
    TEST_ASSERT_EQUAL_UINT(row, ra_games_row(g));
  TEST_ASSERT_EQUAL_UINT(GAMES_N, row);
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_by_file_names_the_set);
  RUN_TEST(test_by_file_ignores_case);
  RUN_TEST(test_by_file_near_misses);
  RUN_TEST(test_row_tells_shared_ids_apart);
  return UNITY_END();
}
