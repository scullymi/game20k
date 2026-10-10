// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file test_ftp_guard.c
 *  @brief The FTP write protection in hardcore from ftpd.c: protected_path(), resolve() and the commands that use them.
 *
 *  ftpd.c is included, its functions are static. The card is a RAM disk under
 *  the fork's real FatFs, which serves as the oracle: every name that FatFs
 *  resolves to a protected file must be refused. */
#include <stdio.h>
#include <string.h>

#include "unity.h"
#include "host_stubs.h"
#include "ftpd.c"

/** A file of the card the guard must protect in hardcore, with a size of its own. */
typedef struct {
  const char *name;
  unsigned    size;
} root_file_t;

static const root_file_t protected_files[] = {
  { "config.ini",          101 },
  { "ra_patch.json",       102 },
  { "ra_patch.mac",        103 },
  { "ra_pending.txt",      104 },
  { "ra_parked.txt",       105 },
  { "ra_unlocked.txt",     106 },
  { "ra/12138/patch.json", 107 },   // a per-game file below the folder ra
};
#define N_PROTECTED (sizeof(protected_files) / sizeof(protected_files[0]))

static ftps_t sess;   // static: its transfer buffer is 4 KB

/* The content of a test file: its name, padded to size with dots. */
static void content_of(const char *name, unsigned size, char *out) {
  memset(out, '.', size);
  memcpy(out, name, strlen(name));
  out[size] = 0;
}

/* A fresh card: the protected files in the root and in ra/12138, a free file, a
   folder "sub" holding a harmless config.ini of its own. */
void setUp(void) {
  char buf[256];
  TEST_ASSERT_TRUE(host_card_new());
  TEST_ASSERT_EQUAL(FR_OK, f_mkdir("/sd/ra"));
  TEST_ASSERT_EQUAL(FR_OK, f_mkdir("/sd/ra/12138"));
  for(unsigned i = 0; i < N_PROTECTED; i++) {
    char path[64];
    snprintf(path, sizeof(path), "/sd/%s", protected_files[i].name);
    content_of(protected_files[i].name, protected_files[i].size, buf);
    TEST_ASSERT_TRUE(host_card_put(path, buf, protected_files[i].size));
  }
  content_of("readme.txt", 50, buf);
  TEST_ASSERT_TRUE(host_card_put("/sd/readme.txt", buf, 50));
  TEST_ASSERT_EQUAL(FR_OK, f_mkdir("/sd/sub"));
  content_of("sub/config.ini", 201, buf);
  TEST_ASSERT_TRUE(host_card_put("/sd/sub/config.ini", buf, 201));
  host_hardcore = true;
  memset(&sess, 0, sizeof(sess));
  sess.ctl  = HOST_FTP_CTL;
  sess.pasv = -1;
}

void tearDown(void) {
  TEST_ASSERT_EQUAL_UINT_MESSAGE(0, host_sdc_depth(), "the card lock is still held");
}

/* A path with its control bytes and high bytes written as \xNN, for messages. */
static const char *printable(const char *s) {
  static char out[4][512];
  static unsigned next;
  char *o = out[next++ % 4];
  size_t n = 0;
  for(; *s && n + 5 < sizeof(out[0]); s++) {
    unsigned char c = (unsigned char)*s;
    if(c < 0x20 || c >= 0x7f) n += (size_t)snprintf(o + n, 5, "\\x%02x", c);
    else o[n++] = (char)c;
  }
  o[n] = 0;
  return o;
}

/* ---- protected_path() ------------------------------------------------------ */

/** A path as the commands hand it over (after resolve()) and whether hardcore protects it. */
typedef struct {
  const char *path;
  bool        protect;
} guard_case_t;

static const guard_case_t guard_cases[] = {
  // the files themselves, in any case
  { "config.ini", true },         { "CONFIG.INI", true },        { "Config.Ini", true },
  { "ra_patch.json", true },      { "RA_PATCH.JSON", true },     { "Ra_Pending.txt", true },
  { "ra_parked.txt", true },      { "ra_unlocked.txt", true },   { "ra_patch.mac", true },
  { "ra_", true },                { "ra_x", true },              { "RA_PAT~1.JSO", true },
  // FatFs drops trailing dots and spaces
  { "config.ini.", true },        { "config.ini..", true },      { "config.ini ", true },
  { "config.ini . .", true },     { "CONFIG.INI. ", true },      { "ra_x.", true },
  // FatFs splits at a backslash, e.g. "\ra_x" is ra_x in the root
  { "\\ra_x", true },             { "\\config.ini", true },      { "sub\\..\\config.ini", true },
  { "x\\y", true },
  // FatFs ends the path at a control byte, "config.ini<TAB>" is config.ini
  { "config.ini\t", true },       { "config.ini\x01", true },    { "config.ini\x1f", true },
  { "ra\x01_x", true },           { "\x1b", true },
  // other names in the root
  { "readme.txt", false },        { "config.in", false },        { "config.inix", false },
  { "config.ini2", false },       { "xconfig.ini", false },      { "config", false },
  { "config.ini.bak", false },    { "configXini", false },       { "r_a", false },
  { "rax", false },               { "_ra_x", false },            { " config.ini", false },
  { "config.ini\x7f", false },    { "", false },
  // the folder ra with the per-game files, alone or with anything below it
  { "ra", true },                 { "RA", true },                { "ra.", true },
  { "ra/", true },                { "ra/12138/patch.json", true }, { "RA/12138/unlocked.txt", true },
  // below the root, other files of the same names
  { "sub/config.ini", false },    { "sub/ra_x", false },         { "ra_dir/x", false },
  { "rax/x", false },
};
#define N_GUARD (sizeof(guard_cases) / sizeof(guard_cases[0]))

/* Every case, and a list of those that come out wrong. */
static void check_guard_table(bool hardcore) {
  char wrong[2048] = "";
  unsigned bad = 0;
  host_hardcore = hardcore;
  for(unsigned i = 0; i < N_GUARD; i++) {
    bool want = hardcore && guard_cases[i].protect;
    if(protected_path(guard_cases[i].path) != want) {
      bad++;
      size_t n = strlen(wrong);
      snprintf(wrong + n, sizeof(wrong) - n, " '%s'->%d", printable(guard_cases[i].path), !want);
    }
  }
  char msg[2200];
  snprintf(msg, sizeof(msg), "%u of %u cases wrong:%s", bad, (unsigned)N_GUARD, wrong);
  if(bad) TEST_FAIL_MESSAGE(msg);
  snprintf(msg, sizeof(msg), "%u of %u cases right", (unsigned)N_GUARD, (unsigned)N_GUARD);
  TEST_MESSAGE(msg);
}

static void test_guard_table_hardcore(void) { check_guard_table(true); }
static void test_guard_table_softcore_protects_nothing(void) { check_guard_table(false); }

/* ---- resolve() --------------------------------------------------------------- */

/** An FTP argument in a working directory, and what resolve() makes of it. */
typedef struct {
  const char *cwd, *arg;
  bool        ok;
  const char *out;
} resolve_case_t;

static const resolve_case_t resolve_cases[] = {
  { "",    "config.ini",          true, "config.ini" },
  { "",    "/config.ini",         true, "config.ini" },
  { "",    "//config.ini",        true, "config.ini" },
  { "",    "./config.ini",        true, "config.ini" },
  { "",    "config.ini/",         true, "config.ini" },
  { "",    "config.ini/.",        true, "config.ini" },
  { "",    "sub/../config.ini",   true, "config.ini" },
  { "",    "../config.ini",       true, "config.ini" },   // ".." at the root stays at the root
  { "",    "../../../ra_x",       true, "ra_x" },
  { "",    "",                    true, "" },
  { "",    "/",                   true, "" },
  { "",    ".",                   true, "" },
  { "",    "..",                  true, "" },
  { "sub", "config.ini",          true, "sub/config.ini" },
  { "sub", "../config.ini",       true, "config.ini" },
  { "sub", "/ra_patch.json",      true, "ra_patch.json" },
  { "sub", "./x/../y",            true, "sub/y" },
  { "a/b", "../../ra_x",          true, "ra_x" },
  { "a/b", "..",                  true, "a" },
  { "",    "sub\\..\\config.ini", true, "sub\\..\\config.ini" },   // resolve() knows only '/'
  { "",    "a//b///c",            true, "a/b/c" },
};
#define N_RESOLVE (sizeof(resolve_cases) / sizeof(resolve_cases[0]))

static void test_resolve_table(void) {
  char out[CWD_MAX], wrong[2048] = "";
  unsigned bad = 0;
  for(unsigned i = 0; i < N_RESOLVE; i++) {
    const resolve_case_t *c = &resolve_cases[i];
    snprintf(sess.cwd, sizeof(sess.cwd), "%s", c->cwd);
    memset(out, 'X', sizeof(out));
    bool ok = resolve(&sess, c->arg, out, sizeof(out));
    if(ok != c->ok || (ok && strcmp(out, c->out))) {
      bad++;
      size_t n = strlen(wrong);
      snprintf(wrong + n, sizeof(wrong) - n, " [%s + %s -> %d '%s']", c->cwd, c->arg, ok, ok ? out : "");
    }
  }
  char msg[2200];
  snprintf(msg, sizeof(msg), "%u of %u cases wrong:%s", bad, (unsigned)N_RESOLVE, wrong);
  if(bad) TEST_FAIL_MESSAGE(msg);
}

/* What does not fit is refused: a component of CWD_MAX characters, or a result
   that leaves no room for a separator and the NUL (resolve() keeps two bytes spare,
   so in a buffer of CWD_MAX the longest name has CWD_MAX - 2 characters). */
static void test_resolve_refuses_what_does_not_fit(void) {
  char out[CWD_MAX], arg[CWD_MAX * 2];
  sess.cwd[0] = 0;
  memset(arg, 'a', CWD_MAX - 1);
  arg[CWD_MAX - 1] = 0;
  TEST_ASSERT_FALSE(resolve(&sess, arg, out, sizeof(out)));
  memset(arg, 'a', CWD_MAX - 2);
  arg[CWD_MAX - 2] = 0;
  TEST_ASSERT_TRUE(resolve(&sess, arg, out, sizeof(out)));
  TEST_ASSERT_EQUAL_size_t(CWD_MAX - 2, strlen(out));
  memset(arg, 'a', CWD_MAX);
  arg[CWD_MAX] = 0;
  TEST_ASSERT_FALSE(resolve(&sess, arg, out, sizeof(out)));
  // two components that fit alone but not together
  memset(arg, 'b', 100);
  arg[100] = '/';
  memset(arg + 101, 'c', 100);
  arg[201] = 0;
  TEST_ASSERT_FALSE(resolve(&sess, arg, out, sizeof(out)));
}

/* ---- the oracle: whatever FatFs finds as a protected file is refused ----------- */

/* The protected file fi is, by its size, or NULL. The size and not the name: after
   f_stat() FatFs reports the name as it was asked for, so a file reached by its 8.3
   name comes back under that name. Every file on the test card has a size of its own. */
static const root_file_t *protected_file(const FILINFO *fi) {
  if(fi->fattrib & AM_DIR) return NULL;
  for(unsigned i = 0; i < N_PROTECTED; i++)
    if(fi->fsize == protected_files[i].size) return &protected_files[i];
  return NULL;
}

static unsigned oracle_candidates, oracle_resolved, oracle_hits;

/* One FTP argument in the current working directory, as the commands treat it. */
static void oracle(const char *arg) {
  char path[CWD_MAX], full[FPATH_MAX];
  FILINFO fi;
  oracle_candidates++;
  if(!resolve(&sess, arg, path, sizeof(path))) return;   // "550 Bad path."
  oracle_resolved++;
  full_path(path, full, sizeof(full));
  const root_file_t *hit = f_stat(full, &fi) == FR_OK ? protected_file(&fi) : NULL;
  if(!hit) return;
  oracle_hits++;
  if(!protected_path(path)) {
    char msg[600];
    snprintf(msg, sizeof(msg), "cwd '%s', argument '%s' reaches %s but is not protected",
             sess.cwd, printable(arg), hit->name);
    TEST_FAIL_MESSAGE(msg);
  }
}

/* The name with every byte 1..255 put in front, appended and put in at each position. */
static void oracle_variants(const char *name) {
  char s[CWD_MAX];
  size_t len = strlen(name);
  oracle(name);
  for(unsigned c = 1; c < 256; c++) {
    snprintf(s, sizeof(s), "%c%s", (char)c, name);   oracle(s);
    snprintf(s, sizeof(s), "%s%c", name, (char)c);   oracle(s);
    for(size_t k = 1; k < len; k++) {
      snprintf(s, sizeof(s), "%.*s%c%s", (int)k, name, (char)c, name + k);
      oracle(s);
    }
  }
  // what FatFs strips at the end, two at a time, and path forms around the name
  static const char *const tails[] = { "..", ". ", " .", "  ", ".\t", " \x01", "./", "/.", "/", "\\", "/..", "\\." };
  static const char *const heads[] = { "/", "./", "//", "\\", "sub/../", "sub\\..\\", "../", "./././", "/sub/../" };
  for(size_t i = 0; i < sizeof(tails) / sizeof(tails[0]); i++) {
    snprintf(s, sizeof(s), "%s%s", name, tails[i]);
    oracle(s);
  }
  for(size_t i = 0; i < sizeof(heads) / sizeof(heads[0]); i++) {
    snprintf(s, sizeof(s), "%s%s", heads[i], name);
    oracle(s);
  }
}

/* Every protected name, its short 8.3 name and a case variant, from the root and
   from "sub", through resolve() and FatFs. */
static void test_fatfs_oracle(void) {
  static const char *const cwds[] = { "", "sub" };
  oracle_candidates = oracle_resolved = oracle_hits = 0;
  for(size_t w = 0; w < sizeof(cwds) / sizeof(cwds[0]); w++) {
    snprintf(sess.cwd, sizeof(sess.cwd), "%s", cwds[w]);
    for(unsigned i = 0; i < N_PROTECTED; i++) {
      char path[64], upper[64];
      FILINFO fi;
      const char *name = protected_files[i].name;
      snprintf(path, sizeof(path), "/sd/%s", name);
      TEST_ASSERT_EQUAL(FR_OK, f_stat(path, &fi));
      for(size_t k = 0; name[k] && k < sizeof(upper) - 1; k++) upper[k] = (char)toupper((unsigned char)name[k]);
      upper[strlen(name)] = 0;
      oracle_variants(name);
      oracle_variants(upper);
      if(strcmp(fi.altname, upper)) oracle_variants(fi.altname);   // the 8.3 name, when it differs
    }
  }
  // the sweep must have reached the files, else it proved nothing, and an 8.3 name
  // must count as a hit, else the identification above is blind to it
  TEST_ASSERT_TRUE(oracle_hits > 100);
  FILINFO fi;
  unsigned before = oracle_hits;
  TEST_ASSERT_EQUAL(FR_OK, f_stat("/sd/ra_patch.json", &fi));
  TEST_ASSERT_TRUE(strlen(fi.altname) > 0 && strcmp(fi.altname, "RA_PATCH.JSON"));
  sess.cwd[0] = 0;
  oracle(fi.altname);
  TEST_ASSERT_EQUAL_UINT_MESSAGE(before + 1, oracle_hits, fi.altname);
  char msg[160];
  snprintf(msg, sizeof(msg), "%u arguments, %u resolved, %u reached a protected file, all %u refused",
           oracle_candidates, oracle_resolved, oracle_hits, oracle_hits);
  TEST_MESSAGE(msg);
}

/* ---- the commands ---------------------------------------------------------------- */

/* Runs a control session with these commands and returns what the server sent. */
static const char *session_run(const char *commands) {
  host_ftp_script(commands);
  session(&sess);
  TEST_ASSERT_EQUAL_UINT_MESSAGE(0, host_sdc_depth(), "the card lock is still held after the session");
  return host_ftp_transcript();
}

/* True when the file still has the content setUp() gave it. */
static bool unchanged(const char *name, unsigned size) {
  char want[256], got[256], path[64];
  snprintf(path, sizeof(path), "/sd/%s", name);
  content_of(name, size, want);
  return host_card_get(path, got, sizeof(got)) == (long)size && !memcmp(want, got, size);
}

static bool all_protected_unchanged(void) {
  for(unsigned i = 0; i < N_PROTECTED; i++)
    if(!unchanged(protected_files[i].name, protected_files[i].size)) return false;
  return true;
}

/* Counts the replies "550 Write protected in hardcore mode." in a transcript. */
static unsigned refusals(const char *t) {
  unsigned n = 0;
  for(const char *p = t; (p = strstr(p, "550 Write protected in hardcore mode.")); p++) n++;
  return n;
}

/* Every writing command against protected files, also by the paths FatFs maps onto
   them: a backslash ("\ra_x"), a trailing dot or space, a control byte, and RMD,
   which removes files too. The folder ra as well: STOR, MKD and DELE below it, RMD
   and RNFR of it, RNTO into it. */
static const char write_attempts[] =
  "STOR config.ini\r\n"
  "STOR ra_patch.json\r\n"
  "STOR \\ra_x\r\n"
  "STOR config.ini.\r\n"
  "STOR config.ini \r\n"
  "STOR config.ini\t\r\n"
  "STOR /CONFIG.INI\r\n"
  "STOR sub/../ra_pending.txt\r\n"
  "STOR ra/12138/patch.json\r\n"
  "DELE config.ini\r\n"
  "DELE RA_PATCH.MAC\r\n"
  "DELE ra_parked.txt.\r\n"
  "RMD config.ini\r\n"
  "RMD ra\r\n"
  "XRMD ra_unlocked.txt\r\n"
  "MKD ra_new\r\n"
  "XMKD config.ini.\r\n"
  "RNFR readme.txt\r\nRNTO config.ini\r\n"
  "RNFR ra_patch.json\r\nRNTO stolen.json\r\n"
  "RNFR readme.txt\r\nRNTO \\ra_x\r\n"
  "RNFR ra\r\nRNTO rb\r\n"
  "MKD ra/x\r\n"
  "DELE ra/12138/patch.json\r\n"
  "RNFR readme.txt\r\nRNTO ra/x\r\n";
#define WRITE_ATTEMPTS 24   /* commands above that must be refused */

static void test_hardcore_refuses_every_writing_command(void) {
  const char *t = session_run(write_attempts);
  TEST_ASSERT_EQUAL_UINT_MESSAGE(WRITE_ATTEMPTS, refusals(t), t);
  TEST_ASSERT_TRUE_MESSAGE(all_protected_unchanged(), "a protected file changed");
  TEST_ASSERT_FALSE(host_card_exists("/sd/ra_new"));
  TEST_ASSERT_FALSE(host_card_exists("/sd/stolen.json"));
  TEST_ASSERT_FALSE(host_card_exists("/sd/rb"));
  TEST_ASSERT_FALSE(host_card_exists("/sd/ra/x"));
  TEST_ASSERT_TRUE(host_card_exists("/sd/ra/12138/patch.json"));
  TEST_ASSERT_TRUE(unchanged("readme.txt", 50));
}

/* The same commands in softcore are not refused by the guard: the files change. */
static void test_softcore_lets_them_through(void) {
  host_hardcore = false;
  const char *t = session_run("DELE config.ini\r\nMKD ra_new\r\nRNFR ra_patch.json\r\nRNTO moved.json\r\n");
  TEST_ASSERT_EQUAL_UINT_MESSAGE(0, refusals(t), t);
  TEST_ASSERT_NOT_NULL(strstr(t, "250 Deleted."));
  TEST_ASSERT_NOT_NULL(strstr(t, "257 \"/ra_new\" created."));
  TEST_ASSERT_NOT_NULL(strstr(t, "250 Renamed."));
  TEST_ASSERT_FALSE(host_card_exists("/sd/config.ini"));
  TEST_ASSERT_TRUE(host_card_exists("/sd/moved.json"));
}

/* Reading stays possible in hardcore, and writing elsewhere too. */
static void test_hardcore_reads_and_writes_elsewhere(void) {
  const char *t = session_run("SIZE config.ini\r\nSIZE ra_patch.json\r\nDELE readme.txt\r\n"
                              "STOR sub/config.ini\r\n");
  TEST_ASSERT_NOT_NULL_MESSAGE(strstr(t, "213 101\r\n"), t);
  TEST_ASSERT_NOT_NULL_MESSAGE(strstr(t, "213 102\r\n"), t);
  TEST_ASSERT_NOT_NULL_MESSAGE(strstr(t, "250 Deleted."), t);
  // STOR gets past the guard and then finds no data connection
  TEST_ASSERT_NOT_NULL_MESSAGE(strstr(t, "150 Opening data connection.\r\n425 No data connection."), t);
  TEST_ASSERT_EQUAL_UINT(0, refusals(t));
}

/* REST applies to the next transfer only, also when that one is refused: a fresh
   STOR after a refused one must create its file from the start, not open an existing
   one at the old offset (FA_OPEN_EXISTING fails for a new file, "550 Cannot create"). */
static void test_refused_transfer_drops_rest(void) {
  const char *t = session_run("REST 10\r\nSTOR config.ini\r\nSTOR sub/new.bin\r\n");
  TEST_ASSERT_EQUAL_UINT_MESSAGE(1, refusals(t), t);
  TEST_ASSERT_NOT_NULL_MESSAGE(strstr(t, "150 Opening data connection.\r\n425 No data connection."), t);
  TEST_ASSERT_TRUE(host_card_exists("/sd/sub/new.bin"));
  TEST_ASSERT_TRUE(unchanged("config.ini", 101));
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_guard_table_hardcore);
  RUN_TEST(test_guard_table_softcore_protects_nothing);
  RUN_TEST(test_resolve_table);
  RUN_TEST(test_resolve_refuses_what_does_not_fit);
  RUN_TEST(test_fatfs_oracle);
  RUN_TEST(test_hardcore_refuses_every_writing_command);
  RUN_TEST(test_softcore_lets_them_through);
  RUN_TEST(test_hardcore_reads_and_writes_elsewhere);
  RUN_TEST(test_refused_transfer_drops_rest);
  return UNITY_END();
}
