// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_xml.c
 *  @brief The XML stream parser of the menus: the callbacks it makes for elements, attributes,
 *  entities and skipped elements, and how often it takes memory from the heap. */
#include <stdio.h>
#include <string.h>

#include "unity.h"
#include "host_stubs.h"

// the parser's heap calls are counted: a name or a value must not cost one call per character
static int allocs;
static void *counted_malloc(size_t size) {
  allocs++;
  return pvPortMalloc(size);
}
#define pvPortMalloc counted_malloc
#include "xml.c"
#undef pvPortMalloc

// what the callbacks saw, one line per call; a start callback that names "skip" asks to skip
static char seen[4096];

int xml_element_start_cb(char *name) {
  snprintf(seen + strlen(seen), sizeof(seen) - strlen(seen), "<%s>", name);
  return strcmp(name, "skip") == 0;
}
void xml_element_end_cb(void) { snprintf(seen + strlen(seen), sizeof(seen) - strlen(seen), "</>"); }
void xml_attribute_cb(char *name, char *value) {
  snprintf(seen + strlen(seen), sizeof(seen) - strlen(seen), "[%s=%s]", name, value ? value : "(null)");
}

static void parse_n(const char *text, size_t len) {
  seen[0] = '\0';
  xml_init();
  while(len--) xml_parse(*text++);
}
static void parse(const char *text) { parse_n(text, strlen(text)); }

void setUp(void) { allocs = 0; }
void tearDown(void) {}

static void test_elements_and_attributes(void) {
  parse("<?xml version=\"1.0\"?><!-- c --><config name=\"Galaga\" version='2'><menu label=\"A\">"
        "<button label=\"B\"/></menu></config>");
  TEST_ASSERT_EQUAL_STRING("<config>[name=Galaga][version=2]<menu>[label=A]<button>[label=B]</></></>",
                           seen);
}

static void test_white_space(void) {
  parse("<a\n\tx = \"1\"\r\n y='2' ><b/ ></a >");
  TEST_ASSERT_EQUAL_STRING("<a>[x=1][y=2]<b></></>", seen);
}

static void test_entities(void) {
  // in values only, any case, also next to each other. The end is checked after each character,
  // so "&amp;amp;" ends as "&"
  parse("<a v=\"x &amp; y &lt;&GT; &Amp;amp;\"/>");
  TEST_ASSERT_EQUAL_STRING("<a>[v=x & y <> &]</>", seen);
}

static void test_empty_value(void) {
  // an empty value reaches the callback as NULL
  parse("<a v=\"\" w=''/>");
  TEST_ASSERT_EQUAL_STRING("<a>[v=(null)][w=(null)]</>", seen);
}

static void test_skipped_element(void) {
  // a start callback that does not want an element gets nothing of it, nested ones included
  parse("<a><skip x=\"1\"><b y=\"2\"/><c></c></skip><d z=\"3\"/></a>");
  TEST_ASSERT_EQUAL_STRING("<a><skip><d>[z=3]</></>", seen);
}

static void test_long_name_and_value(void) {
  char text[600], value[401];
  memset(value, 'v', 400);
  value[400] = '\0';
  snprintf(text, sizeof(text), "<an_element_name_of_some_length attribute_name=\"%s\"/>", value);
  parse(text);
  char want[600];
  snprintf(want, sizeof(want), "<an_element_name_of_some_length>[attribute_name=%s]</>", value);
  TEST_ASSERT_EQUAL_STRING(want, seen);
  // a few heap calls for growing buffers, not one per character
  TEST_ASSERT_LESS_THAN_INT(40, allocs);
}

static void test_nul_chars(void) {
  // a NUL char in a name or a value is dropped, also as the first char of a name
  static const char text[] = "<a\0b x=\"1\0" "2\"/><\0c/>";
  parse_n(text, sizeof(text) - 1);
  TEST_ASSERT_EQUAL_STRING("<ab>[x=12]</><c></>", seen);
}

static void test_parse_again(void) {
  // the next menu parses from the start, nothing of a value the last one broke off is left
  parse("<a x=\"abc");
  parse("<b y=\"2\"/>");
  TEST_ASSERT_EQUAL_STRING("<b>[y=2]</>", seen);
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_elements_and_attributes);
  RUN_TEST(test_white_space);
  RUN_TEST(test_entities);
  RUN_TEST(test_empty_value);
  RUN_TEST(test_skipped_element);
  RUN_TEST(test_long_name_and_value);
  RUN_TEST(test_nul_chars);
  RUN_TEST(test_parse_again);
  return UNITY_END();
}
