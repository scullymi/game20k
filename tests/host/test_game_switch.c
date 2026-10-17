// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_game_switch.c
 *  @brief A game switch within a start (ra_patch_new_game()): what comes back for the game before is not the new game's.
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
// the network: the path of the last request, never an answer
static char net_path[RA_PATH_MAX];
int ra_net_get(const char *path, char *buf, unsigned cap, ra_reply_t *reply) { snprintf(net_path, sizeof(net_path), "%s", path); return -1; }
int ra_net_get_set(const char *path, char *buf, unsigned cap, ra_reply_t *reply) { return -1; }
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

static void switch_to_b(void) { ra_patch_new_game(&b); }

/* The RA task asked the server for a's set. com_task switches to b while the reply goes to
   the card, and a second reply comes back after the switch: the card file goes to a's
   folder, neither set reaches rcheevos, the set's hardcore block holds for b. b's own
   reply passes. */
static void test_stale_set_dropped(void) {
  rc_runtime_t rt;
  memset(&rt, 0, sizeof(rt));
  make_idents();
  TEST_ASSERT_TRUE(host_card_new() && ra_patch_init());
  ra_patch_new_game(&a);
  unsigned gen_a = ra_patch_generation();
  while_tag = switch_to_b;                                 // com_task's turn between parse and write
  TEST_ASSERT_EQUAL_INT(1, ra_patch_from_server(put_set(a.id), gen_a));
  TEST_ASSERT_NOT_EQUAL(gen_a, ra_patch_generation());     // the switch came
  TEST_ASSERT_TRUE(on_card(a.id));
  TEST_ASSERT_FALSE(on_card(b.id));
  TEST_ASSERT_EQUAL_UINT(0, ra_patch_apply_pending(&rt));   // dropped, nothing activated
  TEST_ASSERT_EQUAL_UINT(0, activated);
  TEST_ASSERT_TRUE(ra_task_hardcore_blocked() & RA_HC_BLOCK_SET);
  TEST_ASSERT_EQUAL_INT(0, ra_patch_from_server(put_set(a.id), gen_a));   // a reply after the switch
  TEST_ASSERT_FALSE(on_card(b.id));
  TEST_ASSERT_EQUAL_UINT(0, ra_patch_apply_pending(&rt));
  TEST_ASSERT_EQUAL_INT(1, ra_patch_from_server(put_set(b.id), ra_patch_generation()));
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
  ra_patch_new_game(&a);
  ra_task_lboard(7, 1234);
  ra_patch_new_game(&b);
  lb_take();
  TEST_ASSERT_EQUAL_UINT(1, lb_n);
  TEST_ASSERT_EQUAL_INT(SUBMIT_RETRY, submit_lboard(&lb_ram[0]));
  TEST_ASSERT_NOT_NULL(strstr(net_path, "r=submitlbentry"));
  TEST_ASSERT_NOT_NULL(strstr(net_path, a.hash));
  TEST_ASSERT_NULL(strstr(net_path, b.hash));
}

/* A core switch (ra_patch_new_core()): the old game ends at once, and the first settle on
   the new board makes that board's game the running one. Without the switch a settle with
   no ROM keeps the game. A stream the switch cuts is left to the board, the stand-ins here
   hash no ROM. */
static void test_new_core_settles_anew(void) {
  const ra_game_t *ga = &ra_games_rows[0], *gc = NULL;
  for(unsigned i = 1; i < ra_games_rows_n && !gc; i++) if(ra_games_rows[i].board != ga->board) gc = &ra_games_rows[i];
  TEST_ASSERT_NOT_NULL_MESSAGE(gc, "the table has no two boards");
  const ra_game_t *first_a = ra_games_by_board(ga->board), *first_c = ra_games_by_board(gc->board);
  TEST_ASSERT_TRUE(host_card_new() && ra_patch_init());
  ra_patch_board(ga->board);
  ra_patch_settle();                                       // the start: the board's game, no ROM
  unsigned gen = ra_patch_generation();
  TEST_ASSERT_EQUAL_STRING(first_a->title, ra_game_title());
  ra_patch_board(gc->board);                               // no switch: the game stays
  ra_patch_settle();
  TEST_ASSERT_EQUAL_UINT(gen, ra_patch_generation());
  TEST_ASSERT_EQUAL_STRING(first_a->title, ra_game_title());
  ra_patch_board(ga->board);
  ra_patch_settle();
  ra_patch_new_core();
  TEST_ASSERT_EQUAL_UINT(gen + 1, ra_patch_generation());
  TEST_ASSERT_NULL(ra_game_title());
  TEST_ASSERT_EQUAL_UINT(0, ra_game_id());
  ra_patch_board(gc->board);
  ra_patch_settle();                                       // the new core's first settle
  TEST_ASSERT_EQUAL_UINT(gen + 2, ra_patch_generation());
  TEST_ASSERT_EQUAL_STRING(first_c->title, ra_game_title());
  TEST_ASSERT_FALSE(ra_task_hardcore_blocked() & RA_HC_BLOCK_GAME);
  TEST_ASSERT_TRUE(ra_task_hardcore_blocked() & RA_HC_BLOCK_ROM);
  ra_patch_settle();                                       // only the first one after the switch
  TEST_ASSERT_EQUAL_UINT(gen + 2, ra_patch_generation());
  TEST_ASSERT_EQUAL_UINT(0, host_sdc_depth());
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_stale_set_dropped);
  RUN_TEST(test_lboard_keeps_its_hash);
  RUN_TEST(test_new_core_settles_anew);
  return UNITY_END();
}
