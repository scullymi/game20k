// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file host_stubs.h
 *  @brief Every host stand-in in one header: debugf(), FreeRTOS, the pico-sdk clock, lwIP,
 *  and what the tests set and read in them. The stand-ins for the fork's own ra_mac, ra_state
 *  and ra_patch calls keep their real headers, see host_stubs.c.
 *
 *  The Makefile passes this file with -include to the fork files, the stand-ins and the tests,
 *  and generates the headers the fork includes by name (FORWARD there), which only include
 *  this file. Defining DEBUG_H keeps the fork's debug.h out, its include guard then skips it.
 *  Types and signatures follow the FreeRTOS RP2350 port and lwIP 2.2 as the firmware builds
 *  them, only as far as the tested code uses them. */
#ifndef HOST_STUBS_H
#define HOST_STUBS_H
#define DEBUG_H

#include <ctype.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/** @brief debug.h: one log line, printf-style, printed only when the environment has HOST_LOG. */
void host_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#define debugf(x, ...) host_log(x, ##__VA_ARGS__)

/* ---- FreeRTOS: one thread, nothing blocks, no task starts ---------------------------------- */

typedef long BaseType_t;
typedef unsigned long UBaseType_t;
typedef uint32_t TickType_t;                 /* configTICK_TYPE_WIDTH_IN_BITS 32 */
typedef struct host_queue *QueueHandle_t, *SemaphoreHandle_t, *QueueSetHandle_t, *QueueSetMemberHandle_t;
typedef struct host_task *TaskHandle_t;
typedef void (*TaskFunction_t)(void *);
#define pdFALSE ((BaseType_t)0)
#define pdTRUE  ((BaseType_t)1)
#define pdFAIL  pdFALSE
#define pdPASS  pdTRUE
#define pdMS_TO_TICKS(ms)    ((TickType_t)(ms))   /* configTICK_RATE_HZ 1000 */
#define configMAX_PRIORITIES 32

typedef struct { unsigned char opaque[80]; } StaticQueue_t;   /* the port's control block, never read here */
QueueHandle_t xQueueCreate(UBaseType_t len, UBaseType_t size);
QueueHandle_t xQueueCreateStatic(UBaseType_t len, UBaseType_t size, uint8_t *storage, StaticQueue_t *ctl);
BaseType_t xQueueSend(QueueHandle_t q, const void *item, TickType_t wait);
BaseType_t xQueueReceive(QueueHandle_t q, void *item, TickType_t wait);
BaseType_t xQueueAddToSet(QueueSetMemberHandle_t member, QueueSetHandle_t set);
QueueSetMemberHandle_t xQueueSelectFromSet(QueueSetHandle_t set, TickType_t wait);
SemaphoreHandle_t xSemaphoreCreateBinary(void);
BaseType_t xSemaphoreGive(SemaphoreHandle_t s);
BaseType_t xSemaphoreTake(SemaphoreHandle_t s, TickType_t wait);
BaseType_t xTaskCreate(TaskFunction_t fn, const char *name, uint32_t stack_words, void *arg,
                       UBaseType_t prio, TaskHandle_t *handle);
void vTaskDelete(TaskHandle_t t);
void vTaskDelay(TickType_t ticks);
TickType_t xTaskGetTickCount(void);

/* ---- pico/time.h: a clock that stands at 0 ------------------------------------------------- */

typedef uint64_t absolute_time_t;
static inline absolute_time_t get_absolute_time(void) { return 0; }
static inline uint64_t to_us_since_boot(absolute_time_t t) { return t; }
static inline int64_t absolute_time_diff_us(absolute_time_t from, absolute_time_t to) { return (int64_t)(to - from); }

/* ---- lwIP: sockets for the FTP control connection, HTTP, altcp and pbuf (not modelled) ------ */

typedef uint8_t u8_t;
typedef uint16_t u16_t;
typedef uint32_t u32_t;
typedef int8_t err_t;
#define ERR_OK    0
#define ERR_MEM  -1
#define LOCK_TCPIP_CORE()   do { } while(0)
#define UNLOCK_TCPIP_CORE() do { } while(0)
#define lwip_ntohs(x) ntohs(x)
#define PP_HTONL(x)   htonl(x)
#define PP_HTONS(x)   htons(x)

int lwip_socket(int domain, int type, int protocol);
int lwip_bind(int s, const struct sockaddr *name, socklen_t namelen);
int lwip_listen(int s, int backlog);
int lwip_accept(int s, struct sockaddr *addr, socklen_t *addrlen);
int lwip_getsockname(int s, struct sockaddr *name, socklen_t *namelen);
int lwip_setsockopt(int s, int level, int optname, const void *optval, socklen_t optlen);
ssize_t lwip_send(int s, const void *dataptr, size_t size, int flags);
ssize_t lwip_recv(int s, void *mem, size_t len, int flags);
int lwip_close(int s);

typedef struct ip4_addr { u32_t addr; } ip4_addr_t;
struct netif { ip4_addr_t ip_addr; };
extern struct netif *netif_default;          /* NULL: no interface on the host */
#define netif_ip4_addr(n) ((const ip4_addr_t *)&(n)->ip_addr)

struct altcp_pcb;
struct altcp_tls_config;
struct pbuf { struct pbuf *next; void *payload; u16_t tot_len; u16_t len; };
typedef struct altcp_pcb *(*altcp_new_fn)(void *arg, u8_t ip_type);
typedef struct altcp_allocator_s { altcp_new_fn alloc; void *arg; } altcp_allocator_t;
typedef err_t (*altcp_recv_fn)(void *arg, struct altcp_pcb *conn, struct pbuf *p, err_t err);
struct altcp_tls_config *altcp_tls_create_config_client(const u8_t *cert, size_t cert_len);
struct altcp_pcb *altcp_tls_alloc(void *arg, u8_t ip_type);
void *altcp_tls_context(struct altcp_pcb *conn);
void altcp_abort(struct altcp_pcb *conn);
void altcp_recved(struct altcp_pcb *conn, u16_t len);
u16_t pbuf_copy_partial(const struct pbuf *p, void *dataptr, u16_t len, u16_t offset);
u8_t pbuf_free(struct pbuf *p);

typedef enum ehttpc_result {
  HTTPC_RESULT_OK, HTTPC_RESULT_ERR_UNKNOWN, HTTPC_RESULT_ERR_CONNECT, HTTPC_RESULT_ERR_HOSTNAME,
  HTTPC_RESULT_ERR_CLOSED, HTTPC_RESULT_ERR_TIMEOUT, HTTPC_RESULT_ERR_SVR_RESP, HTTPC_RESULT_ERR_MEM,
  HTTPC_RESULT_LOCAL_ABORT, HTTPC_RESULT_ERR_CONTENT_LEN
} httpc_result_t;
typedef struct _httpc_state httpc_state_t;
typedef void (*httpc_result_fn)(void *arg, httpc_result_t result, u32_t rx_content_len, u32_t srv_res, err_t err);
typedef err_t (*httpc_headers_done_fn)(httpc_state_t *connection, void *arg, struct pbuf *hdr,
                                       u16_t hdr_len, u32_t content_len);
typedef struct _httpc_connection {
  struct { u32_t addr; } proxy_addr; u16_t proxy_port; u8_t use_proxy;
  altcp_allocator_t *altcp_allocator; httpc_result_fn result_fn; httpc_headers_done_fn headers_done_fn;
} httpc_connection_t;
err_t httpc_get_file_dns(const char *server_name, u16_t port, const char *uri,
                         const httpc_connection_t *settings, altcp_recv_fn recv_fn,
                         void *callback_arg, httpc_state_t **connection);

/* ---- what the tests set and read ----------------------------------------------------------- */

unsigned host_sdc_depth(void);                           /**< sdc_lock() held right now, 0 or 1 */
void host_sdc_set_image(int drive, const char *cwd, const char *name);   /**< NULL name: none */
extern bool host_hardcore;                               /**< what ra_task_hardcore() returns */
void host_set_game(const char *hash, unsigned id);      /**< what ra_game_hash() and ra_game_id() return, "" and 0 for no game */
#define HOST_FTP_CTL 7                                   /**< the modelled control connection */
void host_ftp_script(const char *input);    /**< bytes lwip_recv() hands out, then 0 (closed) */
const char *host_ftp_transcript(void);      /**< what lwip_send() got since host_ftp_script() */
bool host_card_new(void);                   /**< a new, empty 4 MB FAT16 card mounted at /sd */
bool host_card_put(const char *path, const void *data, size_t len);   /**< a whole file */
long host_card_get(const char *path, char *buf, size_t cap);          /**< length or -1 */
bool host_card_exists(const char *path);

#endif /* HOST_STUBS_H */
