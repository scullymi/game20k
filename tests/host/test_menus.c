// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_menus.c
 *  @brief menus.c: menus_pick(), the menu a boot takes, on the table make_fw_tables.py
 *         generates. Known board with its tag, board 0, a board the table lacks, another tag. */
#include "unity.h"
#include "menus.h"

void setUp(void) {}
void tearDown(void) {}

/** Every row comes back for its board and tag, a changed tag gives the basic menu. */
static void test_pick_rows(void) {
  const menus_entry_t *m;
  unsigned i;
  for(i = 0; i < menus_rows_n; i++) {
    const menus_entry_t *e = &menus_rows[i];
    TEST_ASSERT_EQUAL_INT(MENUS_FOUND, menus_pick(e->board, e->tag, NULL, &m));
    TEST_ASSERT_EQUAL_PTR(e, m);
    TEST_ASSERT_EQUAL_INT(MENUS_MISMATCH, menus_pick(e->board, (uint16_t)(e->tag ^ 1), NULL, &m));
    TEST_ASSERT_NULL(m);
  }
  TEST_ASSERT_GREATER_THAN_UINT(0, menus_rows_n);
}

/** Board 0 is no header, a board without a row is unknown, whatever the tag. */
static void test_pick_unknown(void) {
  const menus_entry_t *m = menus_rows;
  unsigned b, unknown = 0;
  TEST_ASSERT_EQUAL_INT(MENUS_NO_HEADER, menus_pick(0, menus_rows[0].tag, NULL, &m));
  TEST_ASSERT_NULL(m);
  for(b = 1; b < 256; b++)
    if(!menus_by_board((unsigned char)b, NULL)) {
      unknown++;
      TEST_ASSERT_EQUAL_INT(MENUS_NO_BOARD, menus_pick((unsigned char)b, menus_rows[0].tag, NULL, &m));
      TEST_ASSERT_NULL(m);
    }
  TEST_ASSERT_EQUAL_UINT(255 - menus_rows_n, unknown);
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_pick_rows);
  RUN_TEST(test_pick_unknown);
  return UNITY_END();
}
