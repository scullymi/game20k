// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_slim.c
 *  @brief ra_slim.c: a set loses its chunked framing and the fields nothing reads while it arrives.
 *
 *  The sets are made up, with the shape of an r=patch reply. Every reply is fed in
 *  pieces of every size, and the buffer is a heap block of exactly the capacity
 *  given, so AddressSanitizer sees a write past it. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "unity.h"
#include "ra_slim.h"

void setUp(void) {}
void tearDown(void) {}

// one pair of each unused field, first, in the middle and last in its object, an object
// with nothing else, escaped quotes, and the names as text where they stay
static const char SET[] =
  "{\"Success\":true,\"PatchData\":{\"ID\":1,\"Title\":\"T\",\"ConsoleID\":27,"
  "\"ImageIcon\":\"/i.png\",\"ImageIconURL\":\"https://x/i.png\","
  "\"RichPresencePatch\":\"Display:\\n\\\"BadgeURL\\\":x\","
  "\"Achievements\":[{\"ID\":2,\"MemAddr\":\"cond\",\"BadgeName\":\"00001\","
  "\"BadgeURL\":\"https://a/\\\"b\\\\\",\"BadgeLockedURL\":\"u\",\"Rarity\":12.5,"
  "\"RarityHardcore\":3},{\"Rarity\":1,\"ID\":3,\"Title\":\"Rarity\"},{\"BadgeURL\":\"only\"}],"
  "\"Leaderboards\":[]}}";
static const char SLIM[] =
  "{\"Success\":true,\"PatchData\":{\"ID\":1,\"Title\":\"T\",\"ConsoleID\":27,"
  "\"ImageIcon\":\"/i.png\","
  "\"RichPresencePatch\":\"Display:\\n\\\"BadgeURL\\\":x\","
  "\"Achievements\":[{\"ID\":2,\"MemAddr\":\"cond\",\"BadgeName\":\"00001\"},"
  "{\"ID\":3,\"Title\":\"Rarity\"},{}],"
  "\"Leaderboards\":[]}}";

/* Feeds in in pieces of size step into a buffer of cap bytes. Returns the result of the
   last feed, *whole what ra_slim_whole() says, *dropped the bytes left out. */
static bool run(const char *in, size_t n, unsigned step, char *buf, unsigned cap, unsigned *len,
                bool *whole, unsigned long *dropped) {
  ra_slim_t s;
  bool ok = true;
  ra_slim_init(&s);
  *len = 0;
  buf[0] = 0;
  for(size_t at = 0; at < n && ok; at += step) {
    unsigned k = (unsigned)(n - at < step ? n - at : step);
    ok = ra_slim_feed(&s, in + at, k, buf, cap, len);
  }
  *whole = ra_slim_whole(&s);
  *dropped = s.dropped;
  return ok;
}

/* in, fed in every piece size, gives want, and the buffer is NUL-terminated. */
static void check(const char *in, size_t n, const char *want, unsigned long want_dropped) {
  size_t wn = strlen(want);
  unsigned cap = (unsigned)wn + 1;
  char *buf = malloc(cap);
  TEST_ASSERT_NOT_NULL(buf);
  for(unsigned step = 1; step <= n; step++) {
    unsigned len;
    bool whole;
    unsigned long dropped;
    char msg[48];
    snprintf(msg, sizeof(msg), "pieces of %u bytes", step);
    TEST_ASSERT_TRUE_MESSAGE(run(in, n, step, buf, cap, &len, &whole, &dropped), msg);
    TEST_ASSERT_TRUE_MESSAGE(whole, msg);
    TEST_ASSERT_EQUAL_UINT_MESSAGE(wn, len, msg);
    TEST_ASSERT_EQUAL_STRING_MESSAGE(want, buf, msg);
    TEST_ASSERT_EQUAL_UINT_MESSAGE(want_dropped, dropped, msg);
  }
  free(buf);
}

/* SET in chunked framing, chunks of size bytes, one with an extension. */
static size_t chunked(const char *body, unsigned size, char *out, size_t cap) {
  size_t n = strlen(body), o = 0;
  for(size_t at = 0; at < n; at += size) {
    unsigned k = (unsigned)(n - at < size ? n - at : size);
    o += (size_t)snprintf(out + o, cap - o, at ? "%x\r\n" : "%x;ext=1\r\n", k);
    memcpy(out + o, body + at, k);
    o += k;
    o += (size_t)snprintf(out + o, cap - o, "\r\n");
  }
  o += (size_t)snprintf(out + o, cap - o, "0\r\n\r\n");
  return o;
}

static void test_set_loses_framing_and_fields(void) {
  static char in[8192];
  unsigned sizes[] = { 0, 1, 7, 64, 4096 };   // 0: plain JSON
  for(unsigned i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
    size_t n = sizes[i] ? chunked(SET, sizes[i], in, sizeof(in)) : strlen(SET);
    if(!sizes[i]) memcpy(in, SET, n);
    TEST_ASSERT_LESS_THAN(sizeof(in), n);
    check(in, n, SLIM, strlen(SET) - strlen(SLIM));
  }
}

static void test_space_around_the_pairs(void) {
  const char *in   = "{ \"A\" : 1 , \"Rarity\" : 2 , \"B\" : \"x\" }";
  const char *want = "{ \"A\" : 1 , \"B\" : \"x\" }";
  check(in, strlen(in), want, strlen(in) - strlen(want));
  in   = "{ \"Rarity\" : 2 , \"B\" : 1 }";
  want = "{  \"B\" : 1 }";
  check(in, strlen(in), want, strlen(in) - strlen(want));
}

/* A set read from the card is slimmed in its own buffer, framing included. */
static void test_in_place(void) {
  static char in[8192];
  const unsigned sizes[] = { 0, 1, 7, 64 };   // 0: plain JSON
  for(unsigned i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
    size_t n = sizes[i] ? chunked(SET, sizes[i], in, sizeof(in)) : strlen(SET);
    if(!sizes[i]) memcpy(in, SET, n);
    char *buf = malloc(n + 1);        // as the card's file in body[], one byte for the NUL
    TEST_ASSERT_NOT_NULL(buf);
    memcpy(buf, in, n);
    ra_slim_t s;
    unsigned len = 0;
    ra_slim_init(&s);
    TEST_ASSERT_TRUE(ra_slim_feed(&s, buf, (unsigned)n, buf, (unsigned)n + 1, &len));
    TEST_ASSERT_TRUE(ra_slim_whole(&s));
    TEST_ASSERT_EQUAL_STRING(SLIM, buf);
    TEST_ASSERT_EQUAL_UINT(strlen(SLIM), len);
    free(buf);
  }
}

static void test_too_small_a_buffer(void) {
  char *buf = malloc(strlen(SLIM));     // one byte short for the NUL
  unsigned len;
  bool whole;
  unsigned long dropped;
  TEST_ASSERT_FALSE(run(SET, strlen(SET), 5, buf, (unsigned)strlen(SLIM), &len, &whole, &dropped));
  TEST_ASSERT_LESS_THAN(strlen(SLIM), len);
  TEST_ASSERT_EQUAL_CHAR(0, buf[len]);
  free(buf);
}

static void test_replies_that_are_not_whole(void) {
  static char in[8192];
  char buf[2048];
  unsigned len;
  bool whole;
  unsigned long dropped;
  size_t n = chunked(SET, 64, in, sizeof(in));
  const struct { const char *in; size_t n; const char *why; } bad[] = {
    { in, n - 5, "the last chunk is missing" },
    { in, n / 2, "cut in a chunk" },
    { "x\r\n{}", 5, "no length" },
    { "2\r\n{}X0\r\n\r\n", 11, "no CR LF after a chunk" },
    { "{\"Rarity\":{\"a\":1}}", 18, "an object as the value of an unused field" },
    { "{\"Rarity\":\"open", 15, "the reply ends in a value" },
    { "FFFFFFFFF\r\n", 11, "a length no chunk has" },
  };
  for(unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
    run(bad[i].in, bad[i].n, 3, buf, sizeof(buf), &len, &whole, &dropped);
    TEST_ASSERT_FALSE_MESSAGE(whole, bad[i].why);
  }
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_set_loses_framing_and_fields);
  RUN_TEST(test_space_around_the_pairs);
  RUN_TEST(test_in_place);
  RUN_TEST(test_too_small_a_buffer);
  RUN_TEST(test_replies_that_are_not_whole);
  return UNITY_END();
}
