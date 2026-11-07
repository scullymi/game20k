// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_game_switch.c
 *  @brief A game switch within a start (game_new()): what comes back for the game before is not the new game's.
 *
 *  ra_task.c is included, its leaderboard list is static. ra_patch.c, ra_queue.c and
 *  ra_games.c with the generated table are linked as they are, rcheevos' parser too.
 *  Its runtime, the network and the device key are stand-ins below: the runtime counts
 *  activations, a request only records its path, and com_task's turn in the middle of a
 *  card write comes while the set's tag is made. */
#include <string.h>

#include "unity.h"
#include "host_stubs.h"
#include "ra_task.c"

// the stand-ins keep the real signatures and ignore most of their parameters
#pragma GCC diagnostic ignored "-Wunused-parameter"

// rcheevos' runtime: activations are counted, nothing runs
static unsigned activated;
int rc_runtime_activate_achievement(rc_runtime_t *rt, uint32_t id, const char *memaddr, void *L, int i) { activated++; return RC_OK; }
void rc_runtime_deactivate_achievement(rc_runtime_t *rt, uint32_t id) {}
int rc_runtime_activate_lboard(rc_runtime_t *rt, uint32_t id, const char *memaddr, void *L, int i) { activated++; return RC_OK; }
void rc_runtime_deactivate_lboard(rc_runtime_t *rt, uint32_t id) {}
int rc_runtime_activate_richpresence(rc_runtime_t *rt, const char *script, void *L, int i) { return RC_OK; }
void rc_runtime_reset(rc_runtime_t *rt) {}
struct rc_trigger_t *rc_runtime_get_achievement(const rc_runtime_t *rt, uint32_t id) { return NULL; }
int rc_parse_format(const char *format) { return 0; }   // leaderboard formats, these sets have none
uint32_t getFreeHeap(void) { return 0; }
// the network: the path of the last request, never an answer. A switch set here comes
// while the next request runs, as com_task's turn during a request of seconds
static char net_path[RA_PATH_MAX];
static void (*while_request)(void);
int ra_net_get(const char *path, char *buf, unsigned cap, ra_reply_t *reply) {
  void (*fn)(void) = while_request;
  while_request = NULL;
  snprintf(net_path, sizeof(net_path), "%s", path);
  if(fn) fn();
  return -1;
}
static void (*while_set)(void);
static unsigned net_sets;           // set requests made
int ra_net_get_set(const char *path, char *buf, unsigned cap, ra_reply_t *reply) {
  void (*fn)(void) = while_set;
  while_set = NULL;
  net_sets++;
  if(fn) fn();
  return -1;
}
bool ra_net_init(QueueSetHandle_t set, void (*fn)(QueueSetMemberHandle_t m)) { return false; }
const char *ra_user_agent(void) { return "host"; }
// no device key for the set's tag, but a task switch while it is tried: card_write() makes
// the tag first, so a switch here lands between the parse and the write. No config, no core,
// no state file
static void (*while_tag)(void);
bool ra_mac_tag2(const char *label, const void *h, size_t hl, const void *d, size_t l, char *hex) {
  void (*fn)(void) = while_tag;
  while_tag = NULL;
  if(fn) fn();
  return false;
}
bool ra_mac_check2(const char *label, const void *h, size_t hl, const void *d, size_t l, const char *hex) { return false; }
ra_mac_state_t ra_mac_state(void) { return RA_MAC_PRESENT; }
const char *ra_mac_error(void) { return ""; }
char *inifile_config_get_str(char *section, char *name) { return NULL; }
void sys_set_val(char id, int8_t value) {}
bool ra_state_replace(bool hardcore, const uint32_t *ids, unsigned n) { return false; }
void ra_state_save(unsigned id) {}
void ra_state_load(const char *user, unsigned id) {}

// mbedTLS: the digest of a stream is what the test streams, the first 32 bytes of it
static unsigned char streamed[32];
void mbedtls_sha256_init(mbedtls_sha256_context *ctx) {}
int mbedtls_sha256_starts(mbedtls_sha256_context *ctx, int is224) { memset(streamed, 0, 32); return 0; }
int mbedtls_sha256_update(mbedtls_sha256_context *ctx, const unsigned char *data, size_t len) {
  memcpy(streamed, data, len < 32 ? len : 32);
  return 0;
}
int mbedtls_sha256_finish(mbedtls_sha256_context *ctx, unsigned char out[32]) { memcpy(out, streamed, 32); return 0; }
void mbedtls_sha256_free(mbedtls_sha256_context *ctx) {}

void setUp(void) {}
void tearDown(void) {}

// two table games with ids of their own, as settle hands them over for a known ROM
static ra_ident_t a, b;
static void make_idents(void) {
  const ra_game_t *ga = &ra_games_rows[0], *gb = NULL;
  for(unsigned i = 1; i < ra_games_rows_n && !gb; i++) if(ra_games_rows[i].id != ga->id) gb = &ra_games_rows[i];
  TEST_ASSERT_NOT_NULL_MESSAGE(gb, "the table has no two games with different ids");
  a = (ra_ident_t){ ga, ga->id, "", "test", true, true };
  b = (ra_ident_t){ gb, gb->id, "", "test", true, true };
  snprintf(a.hash, sizeof(a.hash), "%s", ga->hash);
  snprintf(b.hash, sizeof(b.hash), "%s", gb->hash);
}

/* The server's reply to r=patch for game id, one achievement, in ra_patch's buffer. */
static unsigned put_set(unsigned id) {
  unsigned cap;
  char *body = ra_patch_body(&cap);   // first: the order in which arguments are read is not fixed
  int n = snprintf(body, cap, "{\"Success\":true,\"PatchData\":{\"ID\":%u,\"Title\":\"T\","
                   "\"ConsoleID\":27,\"ImageIcon\":\"\",\"RichPresencePatch\":\"\",\"Achievements\":[{\"ID\":1,"
                   "\"Title\":\"t\",\"Description\":\"d\",\"Flags\":3,\"Points\":5,\"MemAddr\":\"0xH0000=1\","
                   "\"Author\":\"x\",\"BadgeName\":\"0\",\"Created\":1,\"Modified\":1}],\"Leaderboards\":[]}}", id);
  return (unsigned)n;
}

static bool on_card(unsigned id) {
  char path[RA_GAMES_PATH_MAX];
  return ra_games_path(id, RA_GAMES_SET_FILE, path, sizeof(path)) && host_card_exists(path);
}

static void switch_to_b(void) { game_new(&b); }

/* The RA task asked the server for a's set. com_task switches to b while the reply goes to
   the card, and a second reply comes back after the switch: the card file goes to a's
   folder, neither set reaches rcheevos, the set's hardcore block holds for b. b's own
   reply passes. */
static void test_stale_set_dropped(void) {
  rc_runtime_t rt;
  memset(&rt, 0, sizeof(rt));
  make_idents();
  TEST_ASSERT_TRUE(host_card_new() && ra_patch_init());
  game_new(&a);
  unsigned gen_a = game_generation();
  while_tag = switch_to_b;                                 // com_task's turn between parse and write
  TEST_ASSERT_EQUAL_INT(1, ra_patch_from_server(put_set(a.id), gen_a));
  TEST_ASSERT_NOT_EQUAL(gen_a, game_generation());     // the switch came
  TEST_ASSERT_TRUE(on_card(a.id));
  TEST_ASSERT_FALSE(on_card(b.id));
  TEST_ASSERT_EQUAL_UINT(0, ra_patch_apply_pending(&rt));   // dropped, nothing activated
  TEST_ASSERT_EQUAL_UINT(0, activated);
  TEST_ASSERT_TRUE(ra_task_hardcore_blocked() & RA_HC_BLOCK_SET);
  TEST_ASSERT_EQUAL_INT(0, ra_patch_from_server(put_set(a.id), gen_a));   // a reply after the switch
  TEST_ASSERT_FALSE(on_card(b.id));
  TEST_ASSERT_EQUAL_UINT(0, ra_patch_apply_pending(&rt));
  TEST_ASSERT_EQUAL_INT(1, ra_patch_from_server(put_set(b.id), game_generation()));
  TEST_ASSERT_TRUE(on_card(b.id));
  TEST_ASSERT_EQUAL_UINT(RA_PATCH_NEW_SET, ra_patch_apply_pending(&rt));
  TEST_ASSERT_EQUAL_UINT(1, activated);
  TEST_ASSERT_FALSE(ra_task_hardcore_blocked() & RA_HC_BLOCK_SET);
  TEST_ASSERT_EQUAL_UINT(0, host_sdc_depth());
}

/* A leaderboard result reached in a, taken by the RA task after the switch to b, goes out
   with a's hash. */
static void test_lboard_keeps_its_hash(void) {
  make_idents();
  TEST_ASSERT_TRUE(ra_patch_init());
  lb_queue = xQueueCreateStatic(RA_LB_QUEUE, sizeof(lb_entry_t), lb_queue_mem, &lb_queue_ctl);
  account = true;
  user = "alice";
  token = "token";
  game_new(&a);
  ra_task_lboard(7, 1234);
  game_new(&b);
  lb_take();
  TEST_ASSERT_EQUAL_UINT(1, lb_n);
  TEST_ASSERT_EQUAL_INT(SUBMIT_RETRY, submit_lboard(&lb_ram[0]));
  TEST_ASSERT_NOT_NULL(strstr(net_path, "r=submitlbentry"));
  TEST_ASSERT_NOT_NULL(strstr(net_path, a.hash));
  TEST_ASSERT_NULL(strstr(net_path, b.hash));
}

/* a's round on the server, com_task switches to b during one of its requests (while_request,
   while_set). ra_net_get() handles the events meanwhile and takes the wake-up with it, so the
   round has to see the switch itself and end, not sleep until the next ping. The stand-in of
   xQueueSelectFromSet() stops the test when the round waits. */
static void serve_a(void) {
  make_idents();
  TEST_ASSERT_TRUE(host_card_new() && ra_patch_init());
  account = true;
  user = "alice";
  token = "token";
  game_new(&a);
  game_now(&game);
  playing = session = true;
  lb_n = 0;                                                // nothing left from the test before
  net_sets = 0;
  next_ping = xTaskGetTickCount() + pdMS_TO_TICKS(RA_PING_EVERY);   // no ping due
  serve();
  account = playing = session = false;                     // nothing left for the next test
  user = token = NULL;
}

/* During the lists: the round ends before a's set is asked for, which would hold b's card set. */
static void test_switch_during_lists_ends_round(void) {
  while_request = switch_to_b;
  serve_a();
  TEST_ASSERT_NULL(while_request);                         // the switch came during a request
  TEST_ASSERT_TRUE(game_moved());
  TEST_ASSERT_EQUAL_UINT(0, net_sets);
}

/* During the set: the round ends instead of sleeping. */
static void test_switch_during_set_ends_round(void) {
  while_set = switch_to_b;
  serve_a();
  TEST_ASSERT_NULL(while_set);
  TEST_ASSERT_TRUE(game_moved());
  TEST_ASSERT_EQUAL_UINT(1, net_sets);
}

/* The mode banner waits for ra_patch_set_pending(): from the switch until com_task took the
   card set, or until the read found none. */
static void test_set_pending_until_taken(void) {
  rc_runtime_t rt;
  memset(&rt, 0, sizeof(rt));
  make_idents();
  TEST_ASSERT_TRUE(host_card_new() && ra_patch_init());
  game_new(&a);
  TEST_ASSERT_TRUE(ra_patch_set_pending());
  TEST_ASSERT_FALSE(ra_patch_set_again());                 // no set on the card
  TEST_ASSERT_FALSE(ra_patch_set_pending());
  TEST_ASSERT_EQUAL_INT(1, ra_patch_from_server(put_set(a.id), game_generation()));
  ra_patch_apply_pending(&rt);                             // now the card has a's set
  game_new(&b);
  game_new(&a);
  TEST_ASSERT_TRUE(ra_patch_set_pending());
  ra_patch_set_again();                                    // read and handed over, false without a device key
  TEST_ASSERT_TRUE(ra_patch_set_pending());                // not taken yet
  TEST_ASSERT_EQUAL_UINT(RA_PATCH_NEW_SET, ra_patch_apply_pending(&rt) & RA_PATCH_NEW_SET);
  TEST_ASSERT_FALSE(ra_patch_set_pending());
}

/* A core switch (game_new_core()): the old game ends at once, and the first settle on
   the new board makes that board's game the running one. Without the switch a settle with
   no ROM keeps the game. A stream the switch cuts is left to the board, the stand-ins here
   hash no ROM. */
static void test_new_core_settles_anew(void) {
  const ra_game_t *ga = &ra_games_rows[0], *gc = NULL;
  for(unsigned i = 1; i < ra_games_rows_n && !gc; i++) if(ra_games_rows[i].board != ga->board) gc = &ra_games_rows[i];
  TEST_ASSERT_NOT_NULL_MESSAGE(gc, "the table has no two boards");
  const ra_game_t *first_a = ra_games_by_board(ga->board), *first_c = ra_games_by_board(gc->board);
  TEST_ASSERT_TRUE(host_card_new() && ra_patch_init());
  game_new_core();                                     // the first settle ran, see test_first_settle()
  game_set_board(ga->board);
  game_settle();                                       // the board's game, no ROM
  unsigned gen = game_generation();
  TEST_ASSERT_EQUAL_STRING(first_a->title, game_title());
  game_set_board(gc->board);                               // no switch: the game stays
  game_settle();
  TEST_ASSERT_EQUAL_UINT(gen, game_generation());
  TEST_ASSERT_EQUAL_STRING(first_a->title, game_title());
  game_set_board(ga->board);
  game_settle();
  game_new_core();
  TEST_ASSERT_EQUAL_UINT(gen + 1, game_generation());
  TEST_ASSERT_NULL(game_title());
  TEST_ASSERT_EQUAL_UINT(0, game_id());
  game_set_board(gc->board);
  game_settle();                                       // the new core's first settle
  TEST_ASSERT_EQUAL_UINT(gen + 2, game_generation());
  TEST_ASSERT_EQUAL_STRING(first_c->title, game_title());
  TEST_ASSERT_FALSE(ra_task_hardcore_blocked() & RA_HC_BLOCK_GAME);
  TEST_ASSERT_TRUE(ra_task_hardcore_blocked() & RA_HC_BLOCK_ROM);
  game_settle();                                       // only the first one after the switch
  TEST_ASSERT_EQUAL_UINT(gen + 2, game_generation());
  TEST_ASSERT_EQUAL_UINT(0, host_sdc_depth());
}

#define NO_BOARD 200 // a board the table does not have

/* Three games with ROMs of the table: two of one board with ids of their own, one of another. */
static const ra_game_t *g_one, *g_two, *g_far;
static void make_games(void) {
  g_one = g_two = g_far = NULL;
  for(unsigned i = 0; i < ra_games_rows_n && !g_two; i++) {
    const ra_game_t *g = &ra_games_rows[i];
    g_one = g;
    for(unsigned j = 0; j < ra_games_rows_n && !g_two; j++) {
      const ra_game_t *h = &ra_games_rows[j];
      if(h->board == g->board && h->id != g->id && h->rom_n && g->rom_n) g_two = h;
    }
  }
  TEST_ASSERT_NOT_NULL_MESSAGE(g_two, "the table has no board with two games");
  for(unsigned i = 0; i < ra_games_rows_n && !g_far; i++)
    if(ra_games_rows[i].board != g_one->board && ra_games_rows[i].rom_n) g_far = &ra_games_rows[i];
  TEST_ASSERT_NOT_NULL_MESSAGE(g_far, "the table has no second board with a ROM");
}

/* A whole stream: its digest is sha, the footer names want. True when it counts as damaged. */
static bool stream(const char *name, const unsigned char *sha, const unsigned char *want) {
  game_rom_start(name);
  game_rom_data(sha, 32);
  bool damaged = game_rom_end(want);
  game_settle();   // as sdc.c does once it gave the lock back
  return damaged;
}

static bool blocked(unsigned bit) { return (ra_task_hardcore_blocked() & bit) != 0; }

/* g_one runs on its core, as after a core switch with its own ROM. */
static void run_g_one(void) {
  make_games();
  TEST_ASSERT_TRUE(host_card_new() && ra_patch_init());
  game_new_core();
  game_set_board(g_one->board);
  TEST_ASSERT_FALSE(stream("one.rom", g_one->roms[0].sha, g_one->roms[0].sha));
}

/* The ROM of the game: it is the game, and the ROM and the board let hardcore through. */
static void test_settle_known_rom(void) {
  run_g_one();
  TEST_ASSERT_EQUAL_STRING(g_one->title, game_title());
  TEST_ASSERT_EQUAL_UINT(g_one->id, game_id());
  TEST_ASSERT_FALSE(blocked(RA_HC_BLOCK_ROM));
  TEST_ASSERT_FALSE(blocked(RA_HC_BLOCK_GAME));
  TEST_ASSERT_TRUE(game_settled());
}

/* While a ROM streams nothing is known of it: hardcore stays off until the digest is in. */
static void test_stream_blocks_until_its_end(void) {
  run_g_one();
  game_rom_start("one.rom");
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_ROM));
  TEST_ASSERT_TRUE(game_rom_pending());
  game_rom_data(g_one->roms[0].sha, 32);
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_ROM));
  TEST_ASSERT_FALSE(game_rom_end(g_one->roms[0].sha));
  TEST_ASSERT_FALSE(game_rom_pending());
  game_settle();
  TEST_ASSERT_FALSE(blocked(RA_HC_BLOCK_ROM));
}

/* The ROM of another game of this board: that game runs in place, with a new generation. */
static void test_settle_other_game_of_the_board(void) {
  run_g_one();
  unsigned gen = game_generation();
  TEST_ASSERT_FALSE(stream("two.rom", g_two->roms[0].sha, g_two->roms[0].sha));
  TEST_ASSERT_EQUAL_UINT(gen + 1, game_generation());
  TEST_ASSERT_EQUAL_STRING(g_two->title, game_title());
  TEST_ASSERT_EQUAL_UINT(g_two->id, game_id());
  TEST_ASSERT_FALSE(blocked(RA_HC_BLOCK_ROM));
  TEST_ASSERT_FALSE(blocked(RA_HC_BLOCK_GAME));
}

/* The ROM of a game of another board runs on this core: the game stays, nothing counts in
   hardcore, and with the game's own ROM back all is as before. */
static void test_settle_rom_of_another_board(void) {
  run_g_one();
  unsigned gen = game_generation();
  TEST_ASSERT_FALSE(stream("far.rom", g_far->roms[0].sha, g_far->roms[0].sha));
  TEST_ASSERT_EQUAL_UINT(gen, game_generation());
  TEST_ASSERT_EQUAL_STRING(g_one->title, game_title());
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_ROM));
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_GAME));
  TEST_ASSERT_FALSE(stream("one.rom", g_one->roms[0].sha, g_one->roms[0].sha));
  TEST_ASSERT_EQUAL_UINT(gen, game_generation());
  TEST_ASSERT_FALSE(blocked(RA_HC_BLOCK_ROM));
  TEST_ASSERT_FALSE(blocked(RA_HC_BLOCK_GAME));
}

/* A file the table does not know keeps the game and hardcore off. */
static void test_settle_unknown_file(void) {
  static const unsigned char unknown[32] = { 0xde, 0xad, 0xbe, 0xef };
  run_g_one();
  unsigned gen = game_generation();
  TEST_ASSERT_FALSE(stream("mine.rom", unknown, unknown));
  TEST_ASSERT_EQUAL_UINT(gen, game_generation());
  TEST_ASSERT_EQUAL_STRING(g_one->title, game_title());
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_ROM));
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_GAME));
}

/* A content that is not what its footer names is damaged, whatever its name says: no game
   comes of it, not even the board's, and hardcore stays off. */
static void test_settle_damaged_rom(void) {
  static const unsigned char other[32] = { 1 };
  run_g_one();
  TEST_ASSERT_TRUE(stream("one.rom", g_one->roms[0].sha, other));
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_ROM));
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_GAME));
  game_new_core();
  game_set_board(g_one->board);
  TEST_ASSERT_TRUE(stream("one.rom", g_one->roms[0].sha, other));
  TEST_ASSERT_NULL(game_title());
  TEST_ASSERT_EQUAL_UINT(0, game_id());
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_ROM));
}

/* An ejected ROM: the game stays for the core keeps running it, hardcore goes off. */
static void test_rom_gone_blocks(void) {
  run_g_one();
  game_rom_gone();
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_ROM));
  TEST_ASSERT_EQUAL_STRING(g_one->title, game_title());
}

/* The first settle of the start, once per run of this program, so it comes first: neither the
   ROM nor the board is known, and both blocks stay. */
static void test_first_settle(void) {
  static const unsigned char unknown[32] = { 0xde, 0xad };
  TEST_ASSERT_NULL_MESSAGE(ra_games_by_board(NO_BOARD), "the table has this board");
  TEST_ASSERT_TRUE(host_card_new() && ra_patch_init());
  game_set_board(NO_BOARD);
  TEST_ASSERT_FALSE(stream("mine.rom", unknown, unknown));
  TEST_ASSERT_TRUE(game_settled());
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_ROM));
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_GAME));
}

/* Another game in place: its set is not proven yet, whatever the game before had earned. */
static void test_new_game_needs_its_set(void) {
  run_g_one();
  ra_task_hardcore_block(RA_HC_BLOCK_SET, false);
  TEST_ASSERT_FALSE(stream("two.rom", g_two->roms[0].sha, g_two->roms[0].sha));
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_SET));
}

/* After a core switch the ROM of a game of another board is no game of this core. */
static void test_new_core_with_a_rom_of_another_board(void) {
  make_games();
  TEST_ASSERT_TRUE(host_card_new() && ra_patch_init());
  game_new_core();
  game_set_board(g_one->board);
  TEST_ASSERT_FALSE(stream("far.rom", g_far->roms[0].sha, g_far->roms[0].sha));
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_GAME));
}

/* The set is off while the ROM of another game runs, and a new game starts without that. */
static void test_foreign_rom(void) {
  run_g_one();
  TEST_ASSERT_FALSE(ra_patch_foreign_rom());
  TEST_ASSERT_FALSE(stream("far.rom", g_far->roms[0].sha, g_far->roms[0].sha));
  TEST_ASSERT_TRUE(ra_patch_foreign_rom());
  TEST_ASSERT_FALSE(stream("one.rom", g_one->roms[0].sha, g_one->roms[0].sha));
  TEST_ASSERT_FALSE(ra_patch_foreign_rom());
  TEST_ASSERT_FALSE(stream("far.rom", g_far->roms[0].sha, g_far->roms[0].sha));
  TEST_ASSERT_FALSE(stream("two.rom", g_two->roms[0].sha, g_two->roms[0].sha));
  TEST_ASSERT_FALSE(ra_patch_foreign_rom());
}

/* The server's id differs from the table's: hardcore stays off with the game's own ROM too, the
   next game starts clean. */
static void test_wrong_table_id(void) {
  run_g_one();
  ra_patch_resolved(game_generation(), g_one->id + 1);
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_GAME));
  TEST_ASSERT_FALSE(stream("one.rom", g_one->roms[0].sha, g_one->roms[0].sha));
  TEST_ASSERT_TRUE(blocked(RA_HC_BLOCK_GAME));
  TEST_ASSERT_FALSE(stream("two.rom", g_two->roms[0].sha, g_two->roms[0].sha));
  TEST_ASSERT_FALSE(blocked(RA_HC_BLOCK_GAME));
  TEST_ASSERT_FALSE(stream("two.rom", g_two->roms[0].sha, g_two->roms[0].sha));
  TEST_ASSERT_FALSE(blocked(RA_HC_BLOCK_GAME));
}

/* A fallback identity gets its id from the server, an answer for the game before does nothing,
   and the id goes with the game. */
static void test_fallback_identity(void) {
  static const unsigned char unknown[32] = { 0xca, 0xfe };
  TEST_ASSERT_TRUE(host_card_new() && ra_patch_init());
  game_new_core();
  game_set_board(NO_BOARD);
  TEST_ASSERT_FALSE(stream("mine.rom", unknown, unknown));
  unsigned gen = game_generation();
  TEST_ASSERT_EQUAL_UINT(0, game_id());
  ra_patch_resolved(gen - 1, 999);
  TEST_ASSERT_EQUAL_UINT(0, game_id());
  ra_patch_resolved(gen, 999);
  TEST_ASSERT_EQUAL_UINT(999, game_id());
  game_new_core();
  TEST_ASSERT_EQUAL_UINT(0, game_id());
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_first_settle);
  RUN_TEST(test_stale_set_dropped);
  RUN_TEST(test_lboard_keeps_its_hash);
  RUN_TEST(test_switch_during_lists_ends_round);
  RUN_TEST(test_switch_during_set_ends_round);
  RUN_TEST(test_set_pending_until_taken);
  RUN_TEST(test_new_core_settles_anew);
  RUN_TEST(test_settle_known_rom);
  RUN_TEST(test_stream_blocks_until_its_end);
  RUN_TEST(test_settle_other_game_of_the_board);
  RUN_TEST(test_settle_rom_of_another_board);
  RUN_TEST(test_settle_unknown_file);
  RUN_TEST(test_settle_damaged_rom);
  RUN_TEST(test_rom_gone_blocks);
  RUN_TEST(test_new_game_needs_its_set);
  RUN_TEST(test_new_core_with_a_rom_of_another_board);
  RUN_TEST(test_foreign_rom);
  RUN_TEST(test_wrong_table_id);
  RUN_TEST(test_fallback_identity);
  return UNITY_END();
}
