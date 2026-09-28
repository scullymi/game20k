// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file host_stubs.c
 *  @brief The host stand-ins for debugf(), FreeRTOS, lwIP, one mbedTLS call, the card lock
 *  and the RA task.
 *
 *  Each one models only what ftpd.c and ra_net.c rely on. A call that no tested path should
 *  make stops the test through host_fail(), so a stand-in never answers something it does not
 *  model. The sockets model one FTP control connection, HOST_FTP_CTL, as a script of input
 *  bytes and a transcript of what the server sent. */
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "mbedtls/ssl.h"
#include "sdc.h"
#include "ra_task.h"

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

/* ---- FreeRTOS: the tests reach ra_net.c only through ra_net_dechunk(), which uses none ---- */

QueueHandle_t xQueueCreate(UBaseType_t len, UBaseType_t size) { host_fail("xQueueCreate() is not modelled"); return NULL; }
BaseType_t xQueueSend(QueueHandle_t q, const void *item, TickType_t wait) { host_fail("xQueueSend() is not modelled"); return pdFAIL; }
BaseType_t xQueueReceive(QueueHandle_t q, void *item, TickType_t wait) { host_fail("xQueueReceive() is not modelled"); return pdFAIL; }
BaseType_t xQueueAddToSet(QueueSetMemberHandle_t m, QueueSetHandle_t set) { host_fail("xQueueAddToSet() is not modelled"); return pdFAIL; }
QueueSetMemberHandle_t xQueueSelectFromSet(QueueSetHandle_t set, TickType_t wait) { host_fail("xQueueSelectFromSet() is not modelled"); return NULL; }
SemaphoreHandle_t xSemaphoreCreateBinary(void) { host_fail("xSemaphoreCreateBinary() is not modelled"); return NULL; }
BaseType_t xSemaphoreGive(SemaphoreHandle_t s) { host_fail("xSemaphoreGive() is not modelled"); return pdFAIL; }
BaseType_t xSemaphoreTake(SemaphoreHandle_t s, TickType_t wait) { host_fail("xSemaphoreTake() is not modelled"); return pdFAIL; }
// task.h: xTaskCreate() may fail for want of memory. Here it always does, so a caller that
// starts a task takes its error path
BaseType_t xTaskCreate(TaskFunction_t fn, const char *name, uint32_t stack_words, void *arg,
                       UBaseType_t prio, TaskHandle_t *handle) {
  if(handle) *handle = NULL;
  return pdFAIL;
}
void vTaskDelete(TaskHandle_t t) { host_fail("vTaskDelete() is not modelled"); }
void vTaskDelay(TickType_t ticks) { host_fail("vTaskDelay(): a tested path waits"); }
TickType_t xTaskGetTickCount(void) { return 0; }

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

/* ---- HTTP client, altcp, pbuf, TLS: the network is not modelled --------------------------- */

struct altcp_tls_config *altcp_tls_create_config_client(const u8_t *cert, size_t cert_len) { host_fail("altcp_tls_create_config_client() is not modelled"); return NULL; }
struct altcp_pcb *altcp_tls_alloc(void *arg, u8_t ip_type) { host_fail("altcp_tls_alloc() is not modelled"); return NULL; }
void *altcp_tls_context(struct altcp_pcb *conn) { host_fail("altcp_tls_context() is not modelled"); return NULL; }
void altcp_abort(struct altcp_pcb *conn) { host_fail("altcp_abort() is not modelled"); }
void altcp_recved(struct altcp_pcb *conn, u16_t len) { host_fail("altcp_recved() is not modelled"); }
u16_t pbuf_copy_partial(const struct pbuf *p, void *dataptr, u16_t len, u16_t offset) { host_fail("pbuf_copy_partial() is not modelled"); return 0; }
u8_t pbuf_free(struct pbuf *p) { host_fail("pbuf_free() is not modelled"); return 0; }
err_t httpc_get_file_dns(const char *server_name, u16_t port, const char *uri, const httpc_connection_t *settings,
                         altcp_recv_fn recv_fn, void *callback_arg, httpc_state_t **connection) {
  host_fail("httpc_get_file_dns() is not modelled");
  return ERR_MEM;
}
int mbedtls_ssl_set_hostname(mbedtls_ssl_context *ssl, const char *hostname) { host_fail("mbedtls_ssl_set_hostname() is not modelled"); return -1; }

/* ---- card lock and mounted images (sdc.c), the mode (ra_task.c) --------------------------- */

// sdc.c: sdc_lock() takes a FreeRTOS mutex that is not recursive, a second take from the same
// task never returns. Here that stops the test instead.
static unsigned sdc_depth;
static char     image_cwd[MAX_DRIVES + MAX_IMAGES][64];
static char     image_name[MAX_DRIVES + MAX_IMAGES][64];
static bool     image_set[MAX_DRIVES + MAX_IMAGES];

void sdc_lock(void) { if(sdc_depth++) host_fail("sdc_lock() while it is held: on the Pico this never returns"); }
void sdc_unlock(void) { if(!sdc_depth--) host_fail("sdc_unlock() without sdc_lock()"); }
unsigned host_sdc_depth(void) { return sdc_depth; }

void host_sdc_set_image(int drive, const char *cwd, const char *name) {
  if(drive < 0 || drive >= MAX_DRIVES + MAX_IMAGES) host_fail("host_sdc_set_image(): no such drive");
  image_set[drive] = name != NULL;
  snprintf(image_name[drive], sizeof(image_name[drive]), "%s", name ? name : "");
  snprintf(image_cwd[drive], sizeof(image_cwd[drive]), "%s", cwd ? cwd : "");
}

// sdc.c: the file name of a drive's mounted image and its directory, NULL when it has none
#define HAS_IMAGE(d) ((d) >= 0 && (d) < MAX_DRIVES + MAX_IMAGES && image_set[d])
char *sdc_get_image_name(int drive) { return HAS_IMAGE(drive) ? image_name[drive] : NULL; }
char *sdc_get_cwd(int drive) { return HAS_IMAGE(drive) && image_cwd[drive][0] ? image_cwd[drive] : NULL; }

// ra_task.c: the mode the FTP guard asks for
bool host_hardcore;
bool ra_task_hardcore(void) { return host_hardcore; }
