// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file host_stubs.c
 *  @brief The host stand-ins for debugf(), FreeRTOS, lwIP sockets, the card lock, the RA task,
 *  the device key, the unlocked state and the game.
 *
 *  Each one models only what ftpd.c and ra_queue.c rely on. A call that no tested
 *  path should make stops the test through host_fail(), so a stand-in never answers something
 *  it does not model. The sockets model one FTP control connection, HOST_FTP_CTL, as a script
 *  of input bytes and a transcript of what the server sent. */
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "sdc.h"
#include "ra_task.h"
#include "ra_mac.h"
#include "ra_state.h"
#include "ra_patch.h"
#include "games.h"

// the stand-ins below keep the real signatures and ignore most of their parameters
#pragma GCC diagnostic ignored "-Wunused-parameter"

/* Stops the test: a stand-in was asked for something it does not model. */
static void host_fail(const char *what) {
  fprintf(stderr, "HOST STUB: %s\n", what);
  fflush(stderr);
  abort();
}

// debug.h prints each line with printf, here only with HOST_LOG set, so a passing run is quiet
void host_log(const char *fmt, ...) {
  va_list ap;
  if(!getenv("HOST_LOG")) return;
  va_start(ap, fmt);
  printf("  log: ");
  vprintf(fmt, ap);
  va_end(ap);
  printf("\n");
}

/* ---- FreeRTOS: no tested path sends to a queue or takes from one --------------------------- */

// a static queue gets its control block as the handle, ra_queue_init() only checks for NULL
QueueHandle_t xQueueCreateStatic(UBaseType_t len, UBaseType_t size, uint8_t *storage, StaticQueue_t *ctl) { return (QueueHandle_t)ctl; }
BaseType_t xQueueSend(QueueHandle_t q, const void *item, TickType_t wait) { host_fail("xQueueSend() is not modelled"); return pdFAIL; }
BaseType_t xQueueReceive(QueueHandle_t q, void *item, TickType_t wait) { host_fail("xQueueReceive() is not modelled"); return pdFAIL; }
UBaseType_t uxQueueMessagesWaiting(QueueHandle_t q) { (void)q; return 0; }
// task.h: xTaskCreate() may fail for want of memory. Here it always does, so a caller that
// starts a task takes its error path
BaseType_t xTaskCreate(TaskFunction_t fn, const char *name, uint32_t stack_words, void *arg,
                       UBaseType_t prio, TaskHandle_t *handle) {
  if(handle) *handle = NULL;
  return pdFAIL;
}
void vTaskDelete(TaskHandle_t t) { host_fail("vTaskDelete() is not modelled"); }
void vTaskDelay(TickType_t ticks) { host_fail("vTaskDelay(): a tested path waits"); }

/* ---- lwIP sockets: the FTP control connection, no data connection ------------------------- */

struct netif *netif_default;
static const char *script;      // what the client sends, one byte per lwip_recv()
static size_t      script_at;
static char        transcript[16 * 1024];
static size_t      transcript_len;

void host_ftp_script(const char *input) { script = input; script_at = transcript_len = 0; transcript[0] = 0; }
const char *host_ftp_transcript(void) { return transcript; }

// sockets.h, BSD semantics: recv() returns 0 once the peer has closed, send() the bytes it took
ssize_t lwip_recv(int s, void *mem, size_t len, int flags) {
  if(s != HOST_FTP_CTL || !script || !len) return -1;
  if(!script[script_at]) return 0;
  *(char *)mem = script[script_at++];
  return 1;
}

ssize_t lwip_send(int s, const void *dataptr, size_t size, int flags) {
  if(s != HOST_FTP_CTL) return -1;
  if(transcript_len + size >= sizeof(transcript)) host_fail("lwip_send() beyond the transcript");
  memcpy(transcript + transcript_len, dataptr, size);
  transcript_len += size;
  transcript[transcript_len] = 0;
  return (ssize_t)size;
}

int lwip_socket(int domain, int type, int protocol) { return -1; }
int lwip_bind(int s, const struct sockaddr *name, socklen_t namelen) { return -1; }
int lwip_listen(int s, int backlog) { return -1; }
int lwip_accept(int s, struct sockaddr *addr, socklen_t *addrlen) { return -1; }
int lwip_getsockname(int s, struct sockaddr *name, socklen_t *namelen) { return -1; }
int lwip_setsockopt(int s, int level, int optname, const void *optval, socklen_t optlen) { return -1; }
int lwip_close(int s) { return 0; }

/* ---- card lock and mounted images (sdc.c), the mode (ra_task.c) --------------------------- */

// sdc.c: sdc_lock() takes a FreeRTOS mutex that is not recursive, a second take from the same
// task never returns. Here that stops the test instead.
static unsigned sdc_depth;

void sdc_lock(void) { if(sdc_depth++) host_fail("sdc_lock() while it is held: on the Pico this never returns"); }
void sdc_unlock(void) { if(!sdc_depth--) host_fail("sdc_unlock() without sdc_lock()"); }
unsigned host_sdc_depth(void) { return sdc_depth; }

// sdc.c: the file name of a drive's mounted image and its directory. No test mounts one
char *sdc_get_image_name(int drive) { (void)drive; return NULL; }
char *sdc_get_cwd(int drive) { (void)drive; return NULL; }

// ra_task.c: the mode the FTP guard asks for
bool host_hardcore;
bool ra_task_hardcore(void) { return host_hardcore; }

/* ---- device key (ra_mac.c), unlocked state (ra_state.c), the game (ra_patch.c) ----------- */

// ra_mac.c: a fake tag, deterministic over label and data (FNV-1a, spread over the 64 hex
// digits), so a tag made under one label never checks out under another. No key, no HMAC.
bool ra_mac_ready(void) { return true; }
bool ra_mac_tag(const char *label, const void *data, size_t len, char *hex) {
  uint32_t h = 2166136261u;
  for(const unsigned char *p = (const unsigned char *)label; *p; p++) h = (h ^ *p) * 16777619u;
  h = (h ^ 0xffu) * 16777619u;   // a byte no label holds, so label and data cannot slide into each other
  for(size_t i = 0; i < len; i++) h = (h ^ ((const unsigned char *)data)[i]) * 16777619u;
  for(unsigned i = 0; i < RA_MAC_HEX / 8; i++) {
    snprintf(hex + 8 * i, 9, "%08x", (unsigned)h);
    h = (h ^ i) * 16777619u;
  }
  return true;
}
bool ra_mac_check(const char *label, const void *data, size_t len, const char *hex) {
  char want[RA_MAC_HEX + 1];
  return ra_mac_tag(label, data, len, want) && strcmp(want, hex) == 0;
}
// ra_state.c: the account has nothing unlocked. ra_patch.c: the game is what host_set_game()
// set, by default none; the ROM in the core is the game's. ra_games.c: a table of one row,
// Galaga, compared without case as the real lookup does. Weak, so test_games, which includes
// the real ra_games.c, links that one.
void ra_state_add(unsigned id, bool hardcore) {}
bool ra_state_known(unsigned id) { return false; }
bool ra_state_softcore_only(unsigned id) { return false; }
static const ra_game_t host_table[] = { { "galaga", "Galaga", 12138u, "b8140b5e33c53b0f7dd3cc368951a4dd", 1, NULL, 0, NULL, 0 } };
static char     host_hash[RA_GAMES_HASH_LEN + 1] = "";
static unsigned host_id;
void host_set_game(const char *hash, unsigned id) { snprintf(host_hash, sizeof(host_hash), "%s", hash ? hash : ""); host_id = id; }
const char *ra_game_hash(void) { return host_hash; }
unsigned ra_game_id(void) { return host_id; }
__attribute__((weak)) const ra_game_t *ra_games_by_hash(const char *hex) {
  for(unsigned i = 0; hex && i < sizeof(host_table) / sizeof(host_table[0]); i++)
    if(!strcasecmp(host_table[i].hash, hex)) return &host_table[i];
  return NULL;
}
bool ra_patch_foreign_rom(void) { return false; }
// games.c: ftpd.c tells it of a changed ROM file, nothing here lists games
void games_changed(const char *name) { (void)name; }
