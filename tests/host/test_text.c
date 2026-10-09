// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_text.c
 *  @brief ra_text.c: titles and descriptions that found no room beside the parsed set, filled
 *         from the set's text once it is freed, into a block that may still be too small.
 *
 *  The set is made up, with the shape of an r=patch reply. The block is a heap block of the
 *  size given, so AddressSanitizer sees a write past it. */
#include <stdlib.h>
#include <string.h>

#include "unity.h"
#include "ra_patch.h"
#include "ra_text.h"

void setUp(void) {}
void tearDown(void) {}

typedef struct { char *at; const char *end; unsigned n, id[4]; const char *t[4], *d[4]; } fill_t;
static void row(void *arg, unsigned id, const char *title, const char *desc) {
  fill_t *f = arg;
  if(f->n < 4 && ra_text_put(&f->at, f->end, title, desc, &f->t[f->n], &f->d[f->n])) f->id[f->n++] = id;
}

static char set[1024], longdesc[301];
// an escaped title and description, one longer than the menu keeps, one without an ID, a null
static unsigned fill(size_t cap, fill_t *f) {
  memset(longdesc, 'x', 300);
  snprintf(set, sizeof(set), "{\"Success\":true,\"PatchData\":{\"ID\":1,\"Achievements\":["
           "{\"ID\":10,\"Title\":\"Caf\\u00e9\",\"Description\":\"Say \\\"hi\\\"\"},"
           "{\"ID\":11,\"Title\":\"Long\",\"Description\":\"%s\"},{\"Title\":\"no id\"},"
           "{\"ID\":12,\"Title\":\"Null\",\"Description\":null}],\"Leaderboards\":[]}}", longdesc);
  memset(f, 0, sizeof(*f));
  f->at = cap ? malloc(cap) : NULL;
  f->end = f->at ? f->at + cap : NULL;
  TEST_ASSERT_TRUE(ra_text_each(set, strlen(set), row, f));
  return f->n;
}
static size_t need(void) {
  return ra_text_size("Caf\xc3\xa9", "Say \"hi\"") + ra_text_size("Long", longdesc) + ra_text_size("Null", NULL);
}

void test_block_of_the_counted_size(void) {
  fill_t f;
  char *block;
  fill(0, &f);                           // need() counts with longdesc set
  TEST_ASSERT_EQUAL_UINT(3, fill(need(), &f));
  block = (char *)f.t[0];
  TEST_ASSERT_EQUAL_UINT(10, f.id[0]); TEST_ASSERT_EQUAL_STRING("Caf\xc3\xa9", f.t[0]);
  TEST_ASSERT_EQUAL_STRING("Say \"hi\"", f.d[0]);
  TEST_ASSERT_EQUAL_UINT(RA_PATCH_DESC_MAX - 1, strlen(f.d[1]));
  TEST_ASSERT_EQUAL_UINT(12, f.id[2]); TEST_ASSERT_EQUAL_STRING("", f.d[2]);
  TEST_ASSERT_EQUAL_PTR(f.end, f.at);   // filled to the last byte
  free(block);
}

void test_block_too_small_or_none(void) {
  fill_t f;
  fill(0, &f);
  TEST_ASSERT_EQUAL_UINT(0, f.n);        // malloc found no room: nothing written
  TEST_ASSERT_EQUAL_UINT(2, fill(need() - 1, &f));
  TEST_ASSERT_EQUAL_UINT(11, f.id[1]);   // the last row does not fit and stays out
  free((char *)f.t[0]);
}

void test_no_set(void) {
  fill_t f = { 0 };
  TEST_ASSERT_FALSE(ra_text_each("{\"Success\":false}", 17, row, &f));
  TEST_ASSERT_FALSE(ra_text_each("{\"PatchData\":{\"Achievements\":", 29, row, &f));
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_block_of_the_counted_size);
  RUN_TEST(test_block_too_small_or_none);
  RUN_TEST(test_no_set);
  return UNITY_END();
}
