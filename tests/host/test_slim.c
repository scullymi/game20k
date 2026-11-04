// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_slim.c
 *  @brief ra_slim.c: a set loses its chunked framing and the fields nothing reads while it
 *         arrives, a reply that is no set only its framing, and the header that names it.
 *
 *  The sets are made up, with the shape of an r=patch reply. Every input is fed in pieces of
 *  every size, it and the buffer are heap blocks of exactly their length and capacity, so
 *  AddressSanitizer sees any read or write past the end, and state lost between two pieces
 *  shows. */
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

/* Feeds n bytes of in to s in pieces of step bytes into a buffer of cap bytes, until a feed
   fails. Returns the result of the last feed. */
static bool feed(ra_slim_t *s, const char *in, size_t n, size_t step, char *buf, unsigned cap, unsigned *len) {
  bool ok = true;
  *len = 0;
  buf[0] = 0;
  for(size_t at = 0; at < n && ok; at += step)
    ok = ra_slim_feed(s, in + at, (unsigned)(n - at < step ? n - at : step), buf, cap, len);
  return ok;
}

/* ---- a set: framing and unused fields go ---- */

/* Feeds in in pieces of size step into a buffer of cap bytes. Returns the result of the
   last feed, *whole what ra_slim_whole() says, *dropped the bytes left out. */
static bool run(const char *in, size_t n, unsigned step, char *buf, unsigned cap, unsigned *len,
                bool *whole, unsigned long *dropped) {
  ra_slim_t s;
  ra_slim_init(&s);
  bool ok = feed(&s, in, n, step, buf, cap, len);
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

/* ---- a reply that is no set: only the framing goes (keep) ---- */

/* in, n bytes of a body whose header says chunked, through ra_slim with every field kept,
   in pieces of step bytes. Returns whether it is whole, the output goes to buf (n + 1 bytes). */
static bool dechunk(const char *in, size_t n, size_t step, char *buf, unsigned *len) {
  ra_slim_t s;
  ra_slim_init(&s);
  ra_slim_framing(&s, true);
  s.keep = true;
  TEST_ASSERT_TRUE(feed(&s, in, n, step, buf, (unsigned)n + 1, len));
  return ra_slim_whole(&s);
}

/* in in one piece, the output to out (n + 1 bytes), and in every smaller piece size, which
   must give the same. Returns whether in is whole. */
static bool check_kept(const char *in, size_t n, char *out, unsigned *out_len) {
  char *copy = malloc(n ? n : 1), *buf = malloc(n + 1);
  TEST_ASSERT_TRUE(copy && buf);
  memcpy(copy, in, n);
  bool whole = dechunk(copy, n, n ? n : 1, out, out_len);
  TEST_ASSERT_EQUAL_CHAR(0, out[*out_len]);
  for(size_t step = 1; step < n; step++) {
    unsigned len;
    TEST_ASSERT_EQUAL(whole, dechunk(copy, n, step, buf, &len));
    TEST_ASSERT_EQUAL_UINT(*out_len, len);
    TEST_ASSERT_EQUAL_MEMORY(out, buf, len + 1);
  }
  free(copy);
  free(buf);
  return whole;
}

/* Whole chunked bodies, the payload each carries, and how many of its prefixes are whole:
   those from the end of the last chunk's line on. Chunk extensions, hex lengths with
   letters in either case and leading zeros, CR LF and LF alone, a trailer, an empty body. */
static const struct { const char *in, *payload; unsigned whole_prefixes; } WHOLE[] = {
  { "5;ext=1\r\n{\"Suc\r\n12\r\ncess\":true,\"x\":[1]\r\n1\r\n}\r\n0\r\nT: v\r\n\r\n", "{\"Success\":true,\"x\":[1]}", 9 },
  { "5 ; x\n{\"Suc\n00E\ncess\":true,\"x\"\n5\n:[1]}\n0;last\n\n", "{\"Success\":true,\"x\":[1]}", 2 },
  { "a\r\n0123456789\r\n0\r\n\r\n", "0123456789", 3 },
  { "0\r\n\r\n", "", 3 },
};

/* Property: every prefix of a whole body holds a beginning of the payload and is whole
   exactly from the last chunk's line on. Every byte replaced by a few values that matter
   to the framing gives the same in every piece size, whole or not. */
static void test_prefixes_and_changed_bytes(void) {
  static const char repl[] = { 0, '\r', '\n', '0', 'f', 'g', ';', ' ', (char)0xff };
  unsigned runs = 0, whole = 0, broken = 0, prefixes = 0;
  for(unsigned b = 0; b < sizeof(WHOLE) / sizeof(WHOLE[0]); b++) {
    const char *in = WHOLE[b].in, *pay = WHOLE[b].payload;
    size_t n = strlen(in), pn = strlen(pay);
    char out[128], *buf = malloc(n);
    unsigned len, w = 0;
    TEST_ASSERT_TRUE(buf && n < sizeof(out));
    for(size_t k = 0; k <= n; k++, runs++) {
      bool ok = check_kept(in, k, out, &len);
      w += ok;
      TEST_ASSERT_TRUE_MESSAGE(len <= pn && !memcmp(out, pay, len), in);
      if(ok) TEST_ASSERT_EQUAL_UINT_MESSAGE(pn, len, in);
    }
    TEST_ASSERT_EQUAL_UINT_MESSAGE(WHOLE[b].whole_prefixes, w, in);
    prefixes += w;
    for(size_t at = 0; at < n; at++)
      for(size_t r = 0; r < sizeof(repl); r++, runs++) {
        memcpy(buf, in, n);
        buf[at] = repl[r];
        if(check_kept(buf, n, out, &len)) whole++;
        else broken++;
      }
    free(buf);
  }
  // the changed bytes must have both outcomes, else the property says nothing
  TEST_ASSERT_TRUE(whole > 0 && broken > 0);
  char msg[96];
  snprintf(msg, sizeof(msg), "%u inputs: %u whole prefixes, %u changed whole, %u changed not", runs, prefixes, whole, broken);
  TEST_MESSAGE(msg);
}

/* Bodies that are not whole chunked framing although the header says chunked: plain JSON,
   an error page and other text, a space before the length, other bytes or none in place of
   the CR LF after a chunk, a length beyond the body, a length with more digits than it
   holds (2^96 + 7 must not wrap to 7). */
static void test_not_framing(void) {
  static const char *const bad[] = {
    "", "\r\n", "{\"Success\":true}", "[1,2,3]", "<!DOCTYPE html><title>403 Forbidden</title>",
    "error code: 1020", " 7\r\n{\"a\":1}\r\n0\r\n\r\n", "2\r\n{}X\r\n0\r\n\r\n", "2\r\n{}0\r\n\r\n",
    "FFFFFFF0\r\n{\"a\":1}\r\n0\r\n\r\n", "FFFFFFFFFFFFFFF0\r\n{\"a\":1}\r\n0\r\n\r\n",
    "1000000000000000000000007\r\n{\"a\":1}\r\n0\r\n\r\n",
  };
  char out[64];
  unsigned len;
  for(unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
    TEST_ASSERT_FALSE_MESSAGE(check_kept(bad[i], strlen(bad[i]), out, &len), bad[i]);
}

/* chunked only by Transfer-Encoding, case ignored, else Content-Length */
static void test_framing_from_the_header(void) {
  static const struct { const char *h; bool chunked, whole; } t[] = {
    { "HTTP/1.1 200 OK\r\ntransfer-encoding:  gzip, CHUNKED \r\nContent-Length: 9\r\n\r\n", true, true },
    { "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\nX-A: chunked\r\n\r\n", false, true },
    { "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n", false, true },
    { "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n", false, false },   // no body byte came
  };
  for(unsigned i = 0, n; i < sizeof(t) / sizeof(t[0]); i++)
    for(unsigned step = 1; step <= (n = (unsigned)strlen(t[i].h)); step++) {
      ra_net_framing_t f;
      ra_net_framing_init(&f);
      for(unsigned at = 0; at < n; at += step) ra_net_framing_feed(&f, t[i].h + at, n - at < step ? n - at : step);
      TEST_ASSERT_EQUAL_MESSAGE(t[i].chunked, f.chunked, t[i].h);
      TEST_ASSERT_EQUAL_MESSAGE(t[i].whole, ra_net_framing_whole(&f), t[i].h);
    }
  ra_slim_t s;
  char buf[8];
  unsigned len = 0;
  ra_slim_init(&s);
  ra_slim_framing(&s, false);   // the header says plain: a hex digit first is no chunk length
  TEST_ASSERT_TRUE(ra_slim_feed(&s, "1\r\n", 3, buf, sizeof(buf), &len) && ra_slim_whole(&s) && len == 3);
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_set_loses_framing_and_fields);
  RUN_TEST(test_space_around_the_pairs);
  RUN_TEST(test_in_place);
  RUN_TEST(test_too_small_a_buffer);
  RUN_TEST(test_replies_that_are_not_whole);
  RUN_TEST(test_prefixes_and_changed_bytes);
  RUN_TEST(test_not_framing);
  RUN_TEST(test_framing_from_the_header);
  return UNITY_END();
}
