// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_games.c
 *  @brief ra_games.c: ra_games_by_file(), the file name that starts the core switch,
 *         ra_games_row()/ra_games_at(), the row the restart mark keeps, and
 *         ra_games_select(), the game a boot plays.
 *
 *  ra_games.c is included as it is, with rcheevos' md5 for ra_games_name_hash(), and
 *  links the table that scripts/make_fw_tables.py makes from the manifests, as the
 *  firmware does. The tests check the lookups on every row, not the rows themselves:
 *  those the generator checks against the manifests and menus. A ROM file picked in the menu switches the core when it is the set name of a
 *  game of another board plus ".rom", case ignored. A near miss must name no game:
 *  it streams to the running core as before. The rules of ra_games_select() decide
 *  hardcore, they are checked on every row of the table. */
#include <ctype.h>
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

/** Every row comes back by its file name, also in capitals: FAT keeps the case the card
 *  writer chose, an 8.3 name often in capitals. */
static void test_by_file_names_the_set(void) {
  const ra_game_t *g;
  char name[40];
  unsigned row, i;
  for(row = 0; (g = ra_games_at(row)) != NULL; row++) {
    snprintf(name, sizeof(name), "%s.rom", g->set);
    TEST_ASSERT_EQUAL_PTR_MESSAGE(g, ra_games_by_file(name), name);
    for(i = 0; name[i]; i++) name[i] = (char)toupper(name[i]);
    TEST_ASSERT_EQUAL_PTR_MESSAGE(g, ra_games_by_file(name), name);
  }
  TEST_ASSERT_GREATER_THAN_UINT(0, row);
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
  const ra_game_t *g;
  unsigned row = 0, shared = 0;
  for(; (g = ra_games_at(row)) != NULL; row++) {
    TEST_ASSERT_EQUAL_UINT(row, ra_games_row(g));
    shared += ra_games_by_id(g->id) != g;   // an earlier row has the id
  }
  TEST_ASSERT_EQUAL_UINT(ra_games_rows_n, row);
  TEST_ASSERT_GREATER_THAN_UINT(0, shared);
}

/* ---- ra_games_select(): the game of a boot ---- */

static const unsigned char no_file[32];   /**< zeros, the digest of no file */

/** A board other than b, which need not exist. */
static unsigned char other_board(unsigned char b) {
  return b == 1 ? 2 : 1;
}

/** out names game g (NULL for none), played on this board or not, with this label. The
 *  server is asked for a table game only where it is played. */
static void expect(const ra_ident_t *out, const ra_game_t *g, bool played, const char *label,
                   const char *msg) {
  TEST_ASSERT_EQUAL_PTR_MESSAGE(g, out->game, msg);
  TEST_ASSERT_EQUAL_MESSAGE(played, out->board_ok, msg);
  TEST_ASSERT_EQUAL_STRING_MESSAGE(label, out->rom_label, msg);
  TEST_ASSERT_EQUAL_UINT_MESSAGE(g && played ? g->id : 0, out->id, msg);
  TEST_ASSERT_EQUAL_STRING_MESSAGE(g && played ? g->hash : "", out->hash, msg);
}

/** Rule 1: a known digest names its game, whatever the file is called. On another board
 *  the game shows, the ROM counts as known, but nothing is played. */
static void test_select_digest(void) {
  const ra_game_t *g;
  unsigned row, j, n = 0;
  ra_ident_t out;
  for(row = 0; (g = ra_games_at(row)) != NULL; row++)
    for(j = 0; j < g->rom_n; j++, n++) {
      const ra_game_t *named = ra_games_at(row ? 0 : 1);   // the name of another game
      ra_games_select(g->board, g->roms[j].sha, named ? named->hash : NULL, false, &out);
      expect(&out, g, true, g->roms[j].label, g->set);
      TEST_ASSERT_TRUE_MESSAGE(out.rom_ok, g->set);
      ra_games_select(other_board(g->board), g->roms[j].sha, NULL, false, &out);
      expect(&out, g, false, g->roms[j].label, g->set);
      TEST_ASSERT_TRUE_MESSAGE(out.rom_ok, g->set);
    }
  TEST_ASSERT_GREATER_THAN_UINT(0, n);
  char msg[48];
  snprintf(msg, sizeof(msg), "%u digests of %u games", n, row);
  TEST_MESSAGE(msg);
}

/** Rule 2: without a known digest the name of a table game plays that game, softcore
 *  only (rom_ok false), and only on its board. */
static void test_select_name(void) {
  const ra_game_t *g;
  unsigned row;
  ra_ident_t out;
  for(row = 0; (g = ra_games_at(row)) != NULL; row++) {
    ra_games_select(g->board, no_file, g->hash, false, &out);
    expect(&out, g, true, "ROM unknown", g->set);
    TEST_ASSERT_FALSE_MESSAGE(out.rom_ok, g->set);
    ra_games_select(g->board, NULL, g->hash, true, &out);
    expect(&out, g, true, "ROM not checked", g->set);
    ra_games_select(other_board(g->board), no_file, g->hash, false, &out);
    expect(&out, g, false, "ROM unknown", g->set);
  }
  TEST_ASSERT_GREATER_THAN_UINT(0, row);
}

/** Rule 2, any other name: a fallback identity the server resolves. Hardcore needs a board
 *  the table knows, so ra_patch_resolved() can hold the server to that board's games. */
static void test_select_fallback_identity(void) {
  static const char name[] = "0123456789abcdef0123456789abcdef";   // md5 of no table set
  unsigned b, known = 0, unknown = 0;
  ra_ident_t out;
  TEST_ASSERT_NULL(ra_games_by_hash(name));
  for(b = 1; b <= 254; b++) {
    if(ra_games_by_board(b)) known = b;
    else unknown = b;
  }
  TEST_ASSERT_NOT_EQUAL_UINT(0, known);
  TEST_ASSERT_NOT_EQUAL_UINT(0, unknown);
  for(b = 0; b < 3; b++) {
    unsigned char board = b == 0 ? 0 : b == 1 ? known : unknown;
    ra_games_select(board, no_file, name, false, &out);
    TEST_ASSERT_NULL(out.game);
    TEST_ASSERT_EQUAL_STRING(name, out.hash);
    TEST_ASSERT_EQUAL_UINT(0, out.id);
    TEST_ASSERT_FALSE(out.rom_ok);
    TEST_ASSERT_EQUAL(b == 1, out.board_ok);
  }
}

/** Rule 3: nothing streamed, the board's first game shows with "no ROM". An unknown digest
 *  without a name counts as nothing. */
static void test_select_no_name(void) {
  unsigned b, shown = 0;
  ra_ident_t out;
  char msg[48];
  for(b = 0; b < 256; b++) {
    const ra_game_t *g = ra_games_by_board(b);
    snprintf(msg, sizeof(msg), "board %u", b);
    ra_games_select(b, NULL, NULL, false, &out);
    expect(&out, g, g != NULL, "no ROM", msg);
    ra_games_select(b, no_file, NULL, false, &out);
    expect(&out, g, g != NULL, "no ROM", msg);
    TEST_ASSERT_FALSE_MESSAGE(out.rom_ok, msg);
    shown += g != NULL;
  }
  TEST_ASSERT_GREATER_THAN_UINT(0, shown);
  snprintf(msg, sizeof(msg), "%u of 256 boards show a game without a ROM", shown);
  TEST_MESSAGE(msg);
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_by_file_names_the_set);
  RUN_TEST(test_by_file_near_misses);
  RUN_TEST(test_row_tells_shared_ids_apart);
  RUN_TEST(test_select_digest);
  RUN_TEST(test_select_name);
  RUN_TEST(test_select_fallback_identity);
  RUN_TEST(test_select_no_name);
  return UNITY_END();
}
