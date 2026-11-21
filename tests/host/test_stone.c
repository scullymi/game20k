// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_stone.c
 *  @brief The stepping stone: which slot a board jumps to, how many hops the ring takes, and the
 *  jump address written into the 0xD2 command while the bitstream streams by. */
#include <string.h>

#include "unity.h"
#include "host_stubs.h"
#include "stone.c"

void setUp(void) {}
void tearDown(void) {}

// the flash of the singleboard image: slots 1 to 8 hold the boards 1 2 3 6 7 8 9 5
static const unsigned char flash[RAM_MIRROR_SLOTS] = {1, 2, 3, 6, 7, 8, 9, 5};

static void test_slot_of_a_board(void) {
  TEST_ASSERT_EQUAL_INT(0, stone_slot(flash, true, 1));
  TEST_ASSERT_EQUAL_INT(6, stone_slot(flash, true, 9));
  TEST_ASSERT_EQUAL_INT(7, stone_slot(flash, true, 5));
}

static void test_no_slot(void) {
  TEST_ASSERT_EQUAL_INT(STONE_NONE, stone_slot(flash, true, 4));
  // without a scan nothing is known, not even the boards that are there
  TEST_ASSERT_EQUAL_INT(STONE_NONE, stone_slot(flash, false, 1));
  // 0 (empty) and 255 (no tag) are no boards
  const unsigned char holes[RAM_MIRROR_SLOTS] = {1, 0, 255, 2, 0, 0, 0, 0};
  TEST_ASSERT_EQUAL_INT(STONE_NONE, stone_slot(holes, true, 0));
  TEST_ASSERT_EQUAL_INT(STONE_NONE, stone_slot(holes, true, 255));
  TEST_ASSERT_EQUAL_INT(3, stone_slot(holes, true, 2));
}

static void test_first_slot_wins(void) {
  const unsigned char twice[RAM_MIRROR_SLOTS] = {1, 2, 9, 3, 9, 0, 0, 0};
  TEST_ASSERT_EQUAL_INT(2, stone_slot(twice, true, 9));
}

static void test_hops_forward_and_around(void) {
  TEST_ASSERT_EQUAL_INT(1, stone_hops(flash, true, 1, 2));
  TEST_ASSERT_EQUAL_INT(6, stone_hops(flash, true, 1, 9));
  // from the last slot around to the first: one hop
  TEST_ASSERT_EQUAL_INT(1, stone_hops(flash, true, 5, 1));
  TEST_ASSERT_EQUAL_INT(7, stone_hops(flash, true, 2, 1));
  TEST_ASSERT_EQUAL_INT(0, stone_hops(flash, true, 3, 3));
}

static void test_hops_in_a_shorter_ring(void) {
  // three cores: the third points back to the first, the empty slots are not part of the ring
  const unsigned char three[RAM_MIRROR_SLOTS] = {1, 2, 9, 0, 0, 0, 0, 0};
  TEST_ASSERT_EQUAL_INT(1, stone_hops(three, true, 9, 1));
  TEST_ASSERT_EQUAL_INT(2, stone_hops(three, true, 2, 1));
  // a core without a tag at the end is part of the ring all the same
  const unsigned char untagged[RAM_MIRROR_SLOTS] = {1, 2, 9, 255, 0, 0, 0, 0};
  TEST_ASSERT_EQUAL_INT(2, stone_hops(untagged, true, 9, 1));
}

static void test_no_hops(void) {
  TEST_ASSERT_EQUAL_INT(STONE_NONE, stone_hops(flash, true, 1, 4));
  TEST_ASSERT_EQUAL_INT(STONE_NONE, stone_hops(flash, true, 4, 1));
  TEST_ASSERT_EQUAL_INT(STONE_NONE, stone_hops(flash, false, 1, 2));
}

// a stand-in for the head of a bitstream: the 0xD2 command at 52 as gowin_pack writes it
#define AT 52
static unsigned char bits[128];
static void fresh_bits(void) {
  memset(bits, 0xaa, sizeof(bits));
  const unsigned char d2[8] = {0xd2, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00};
  memcpy(bits + AT, d2, sizeof(d2));
}

static void test_patch_in_one_block(void) {
  fresh_bits();
  stone_patch(bits, sizeof(bits), 0, AT, 0x600000);
  const unsigned char want[8] = {0xd2, 0x00, 0xff, 0xff, 0x00, 0x60, 0x00, 0x00};
  TEST_ASSERT_EQUAL_HEX8_ARRAY(want, bits + AT, 8);
  TEST_ASSERT_EQUAL_HEX8(0xaa, bits[AT - 1]);
  TEST_ASSERT_EQUAL_HEX8(0xaa, bits[AT + 8]);
}

static void test_patch_across_blocks(void) {
  // the bitstream in blocks of 1 to 16 bytes, the address bytes often fall into two of them
  for(size_t len = 1; len <= 16; len++) {
    fresh_bits();
    for(size_t pos = 0; pos < sizeof(bits); pos += len) {
      size_t n = pos + len > sizeof(bits) ? sizeof(bits) - pos : len;
      stone_patch(bits + pos, n, pos, AT, 0x12345678);
    }
    const unsigned char want[8] = {0xd2, 0x00, 0xff, 0xff, 0x12, 0x34, 0x56, 0x78};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(want, bits + AT, 8);
    TEST_ASSERT_EQUAL_HEX8(0xaa, bits[AT + 8]);
  }
}

static void test_patch_leaves_other_blocks(void) {
  fresh_bits();
  stone_patch(bits, AT, 0, AT, 0x600000);               // ends before the command
  stone_patch(bits + AT + 8, 20, AT + 8, AT, 0x600000); // starts after it
  const unsigned char want[8] = {0xd2, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00};
  TEST_ASSERT_EQUAL_HEX8_ARRAY(want, bits + AT, 8);
}

static void test_patch_stays_inside_the_block(void) {
  // a block that ends right before the address and one that starts within it
  fresh_bits();
  stone_patch(bits, AT + 4, 0, AT, 0x12345678);
  TEST_ASSERT_EQUAL_HEX8(0x00, bits[AT + 4]);
  stone_patch(bits + AT + 6, 1, AT + 6, AT, 0x12345678);
  const unsigned char want[4] = {0x00, 0x00, 0x56, 0x00};
  TEST_ASSERT_EQUAL_HEX8_ARRAY(want, bits + AT + 4, 4);
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_slot_of_a_board);
  RUN_TEST(test_no_slot);
  RUN_TEST(test_first_slot_wins);
  RUN_TEST(test_hops_forward_and_around);
  RUN_TEST(test_hops_in_a_shorter_ring);
  RUN_TEST(test_no_hops);
  RUN_TEST(test_patch_in_one_block);
  RUN_TEST(test_patch_across_blocks);
  RUN_TEST(test_patch_leaves_other_blocks);
  RUN_TEST(test_patch_stays_inside_the_block);
  return UNITY_END();
}
