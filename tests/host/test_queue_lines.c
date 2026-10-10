// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_queue_lines.c
 *  @brief ra_queue.c: parse() on the lines of ra_pending.txt, card input from outside, then the queue on the RAM card.
 *
 *  ra_queue.c is included, parse() and scan() are static. Every line carries its
 *  game's hash after the mode, a line without one is malformed. The tags come from
 *  the host's fake ra_mac_tag(), deterministic over label and data. The game is
 *  what host_set_game() says. */
#include <string.h>

#include "unity.h"
#include "host_stubs.h"
#include "ra_queue.c"

void setUp(void) { host_set_game("", 0); }
void tearDown(void) {}

#define V1  "b8140b5e33c53b0f7dd3cc368951a4dd"    /* md5("galaga"), the table game of the stand-ins */
#define H2  "64d1f88b9b276aece4b0edcc25b7a434"    /* md5("pacman"), a line of another game */
#define HGALLAG "477b96da708bd170f8c2b6245dcd28e4" /* md5("gallag"), a clone set's name the table does not know */
#define H31 "64d1f88b9b276aece4b0edcc25b7a43"
#define H33 "64d1f88b9b276aece4b0edcc25b7a434a"
#define HUP "64D1F88B9B276AECE4B0EDCC25B7A434"

/** One line as it lies on the card, and what parse() must make of it. */
typedef struct {
  const char *text;      /**< the line before any tag, without newline */
  const char *label;     /**< tag the line under this label, NULL for no tag */
  const char *tag_over;  /**< the text the tag is made over, NULL for text itself */
  bool        tamper;    /**< change one character of the tag */
  bool        newline;   /**< the line ends with '\n' */
  int         want;      /**< PARSE_OK, PARSE_FORGED, PARSE_JUNK, PARSE_BAD */
  bool        hardcore;  /**< on PARSE_OK */
  const char *hash;      /**< on PARSE_OK */
} line_case_t;

static const line_case_t cases[] = {
  // with a hash after the mode, tagged under its label. Without a tag the mode does not count
  { "17 1700000000 alice h " H2, NULL,      NULL, false, true,  PARSE_OK,     false, H2 },
  { "17 1700000000 alice h " H2, "g20k-q2", NULL, false, true,  PARSE_OK,     true,  H2 },
  { "17 1700000000 alice s " H2, "g20k-q2", NULL, false, true,  PARSE_OK,     false, H2 },
  // a changed tag, a hash changed after tagging: neither verifies
  { "17 1700000000 alice h " H2, "g20k-q2", NULL,                          true,  true, PARSE_FORGED, false, "" },
  { "17 1700000000 alice h " H2, "g20k-q2", "17 1700000000 alice h " V1,   false, true, PARSE_FORGED, false, "" },
  // no hash (as older firmware wrote them, tagged or not), or a token of the wrong
  // length or case in its place: junk, nothing waits for it (a forged line would wait
  // for a device key), scan() marks it done
  { "17 1700000000 alice h",      NULL,     NULL, false, true,  PARSE_JUNK,   false, "" },
  { "17 1700000000 alice h",      "g20k-q1", NULL, false, true, PARSE_JUNK,   false, "" },
  { "17 1700000000 alice h " H31, NULL,     NULL, false, true,  PARSE_JUNK,   false, "" },
  { "17 1700000000 alice h " H33, NULL,     NULL, false, true,  PARSE_JUNK,   false, "" },
  { "17 1700000000 alice h " HUP, NULL,     NULL, false, true,  PARSE_JUNK,   false, "" },
  // a line a power cut left without its end
  { "17 1700000000 alice h " H2, "g20k-q2", NULL, false, false, PARSE_BAD,    false, "" },
};
#define N_CASES (sizeof(cases) / sizeof(cases[0]))

/* Builds the line of a case: the text, a tag when asked for, and the newline. */
static void make_line(const line_case_t *c, char *line, size_t n) {
  char tag[RA_MAC_HEX + 1];
  int len = snprintf(line, n, "%s", c->text);
  if(c->label) {
    const char *over = c->tag_over ? c->tag_over : c->text;
    TEST_ASSERT_TRUE(ra_mac_tag(c->label, over, strlen(over), tag));
    if(c->tamper) tag[10] = tag[10] == 'a' ? 'b' : 'a';
    len += snprintf(line + len, n - (size_t)len, " %s", tag);
  }
  if(c->newline) snprintf(line + len, n - (size_t)len, "\n");
}

/* Every case, and a list of those that come out wrong. */
static void test_line_table(void) {
  char wrong[2048] = "";
  unsigned bad = 0;
  for(unsigned i = 0; i < N_CASES; i++) {
    char line[RA_QUEUE_LINE_MAX], user[RA_QUEUE_USER_MAX] = "";
    ra_unlock_t u = { 0, 0, false, "" };
    make_line(&cases[i], line, sizeof(line));
    int got = parse(line, &u, user);
    bool ok = got == cases[i].want &&
              (got != PARSE_OK || (u.hardcore == cases[i].hardcore && !strcmp(u.hash, cases[i].hash) &&
                                   u.id == 17 && u.when == 1700000000ul && !strcmp(user, "alice")));
    if(!ok) {
      bad++;
      size_t n = strlen(wrong);
      snprintf(wrong + n, sizeof(wrong) - n, " [%u: got %d, hardcore %d, hash '%s']", i, got, u.hardcore, u.hash);
    }
  }
  char msg[2200];
  snprintf(msg, sizeof(msg), "%u of %u lines wrong:%s", bad, (unsigned)N_CASES, wrong);
  if(bad) TEST_FAIL_MESSAGE(msg);
  snprintf(msg, sizeof(msg), "%u of %u lines parsed as expected", (unsigned)N_CASES, (unsigned)N_CASES);
  TEST_MESSAGE(msg);
}

/* Own by hash, or by the table game the server resolved a fallback identity to. */
static void test_own_by_hash_or_resolved_id(void) {
  host_set_game(HGALLAG, 12138u);            // a fallback identity the server resolved to the table game
  TEST_ASSERT_TRUE(ra_queue_own(HGALLAG));   // its own hash
  TEST_ASSERT_TRUE(ra_queue_own(V1));        // the table game with the resolved id
  TEST_ASSERT_FALSE(ra_queue_own(H2));       // not in the table
  host_set_game(V1, 12138u);                 // a table boot
  TEST_ASSERT_FALSE(ra_queue_own(HGALLAG));  // a fallback-hash line stays foreign
  host_set_game(HGALLAG, 0);                 // a fallback identity the server has not resolved yet
  TEST_ASSERT_FALSE(ra_queue_own(V1));       // the id guard
  host_set_game("", 0);                      // no game
  TEST_ASSERT_FALSE(ra_queue_own(V1));
}

/* The queue file on the RAM card: a malformed line is marked done and skipped, a blank
   line left alone, another account's line parked, the own line is the head, a torn last
   line is marked done once it is reached, then the file goes. */
static void test_head_skips_junk_parks_other_keeps_blank(void) {
  static const char junk[] = "5 1700000000 alice h " H31 "\n", blank[] = "\n", bob[] = "9 1700000000 bob s " H2 "\n";
  const char *own = "17 1700000000 alice h " H2;
  char tag[RA_MAC_HEX + 1], file[512], back[512];
  ra_unlock_t u = { 0, 0, false, "" };
  TEST_ASSERT_TRUE(ra_mac_tag("g20k-q2", own, strlen(own), tag));
  int n = snprintf(file, sizeof(file), "%s%s%s%s %s\n21 1700000000 alice h " H2 " %s", junk, blank, bob, own, tag, tag);
  TEST_ASSERT_TRUE(host_card_new() && host_card_put("/sd/ra_pending.txt", file, (size_t)n));
  ra_queue_open("alice");
  TEST_ASSERT_EQUAL_UINT(1, ra_queue_pending());                 // only the own line counts
  TEST_ASSERT_EQUAL_INT(1, ra_queue_head(&u));
  TEST_ASSERT_TRUE(u.id == 17 && u.hardcore && !strcmp(u.hash, H2));
  long len = host_card_get("/sd/ra_pending.txt", back, sizeof(back) - 1);
  TEST_ASSERT_TRUE(len > 0); back[len] = 0;
  TEST_ASSERT_EQUAL_CHAR('#', back[0]);                           // junk marked done
  TEST_ASSERT_EQUAL_CHAR('\n', back[sizeof(junk) - 1]);           // blank line untouched
  TEST_ASSERT_EQUAL_CHAR('#', back[sizeof(junk)]);                // bob's line marked done
  TEST_ASSERT_NOT_NULL(strstr(back, "\n17 1700000000 alice h"));   // own line untouched
  len = host_card_get("/sd/ra_parked.txt", back, sizeof(back) - 1);
  TEST_ASSERT_TRUE(len > 0); back[len] = 0;
  TEST_ASSERT_EQUAL_STRING(bob, back);                            // bob's line parked, the junk is not
  TEST_ASSERT_TRUE(ra_queue_pop());                               // then the torn line is reached: all done
  TEST_ASSERT_EQUAL_INT(0, ra_queue_head(&u));
  TEST_ASSERT_FALSE(host_card_exists("/sd/ra_pending.txt"));
  TEST_ASSERT_EQUAL_UINT(0, host_sdc_depth());
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_line_table);
  RUN_TEST(test_own_by_hash_or_resolved_id);
  RUN_TEST(test_head_skips_junk_parks_other_keeps_blank);
  return UNITY_END();
}
