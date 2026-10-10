// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file host_stubs.h
 *  @brief Every host stand-in in one header: debugf(), FreeRTOS, lwIP sockets, and what the
 *  tests set and read in them. The stand-ins for the fork's own ra_mac, ra_state
 *  and ra_patch calls keep their real headers, see host_stubs.c. mbedTLS' digest only
 *  as far as ra_patch.c names it.
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
typedef uint32_t StackType_t;
typedef struct host_queue *QueueHandle_t;
typedef struct host_queue *QueueSetHandle_t;
typedef struct host_queue *QueueSetMemberHandle_t;
typedef struct host_queue *SemaphoreHandle_t;
typedef struct host_task *TaskHandle_t;
typedef void (*TaskFunction_t)(void *);
#define pdFALSE ((BaseType_t)0)
#define pdTRUE  ((BaseType_t)1)
#define pdFAIL  pdFALSE
#define pdPASS  pdTRUE
#define pdMS_TO_TICKS(ms)    ((TickType_t)(ms))   /* configTICK_RATE_HZ 1000 */
#define configTICK_RATE_HZ   1000
#define configMAX_PRIORITIES 32
#define portMAX_DELAY        ((TickType_t)0xffffffffu)
#define taskENTER_CRITICAL() do { } while(0)       /* one thread, nothing to keep out */
#define taskEXIT_CRITICAL()  do { } while(0)

typedef struct { _Alignas(8) unsigned char opaque[80]; } StaticQueue_t;   /* the port's control block, here the model's */
typedef struct { unsigned char opaque[96]; } StaticTask_t;
QueueHandle_t xQueueCreate(UBaseType_t len, UBaseType_t size);
QueueHandle_t xQueueCreateStatic(UBaseType_t len, UBaseType_t size, uint8_t *storage, StaticQueue_t *ctl);
BaseType_t xQueueSend(QueueHandle_t q, const void *item, TickType_t wait);
BaseType_t xQueueReceive(QueueHandle_t q, void *item, TickType_t wait);
UBaseType_t uxQueueMessagesWaiting(QueueHandle_t q);
QueueSetHandle_t xQueueCreateSet(UBaseType_t len);
BaseType_t xQueueAddToSet(QueueSetMemberHandle_t member, QueueSetHandle_t set);
QueueSetMemberHandle_t xQueueSelectFromSet(QueueSetHandle_t set, TickType_t wait);
SemaphoreHandle_t xSemaphoreCreateBinary(void);
BaseType_t xSemaphoreGive(SemaphoreHandle_t s);
BaseType_t xSemaphoreTake(SemaphoreHandle_t s, TickType_t wait);
TaskHandle_t xTaskCreateStatic(TaskFunction_t fn, const char *name, uint32_t stack_words, void *arg,
                               UBaseType_t prio, StackType_t *stack, StaticTask_t *tcb);
TickType_t xTaskGetTickCount(void);
BaseType_t xTaskCreate(TaskFunction_t fn, const char *name, uint32_t stack_words, void *arg,
                       UBaseType_t prio, TaskHandle_t *handle);
void vTaskDelete(TaskHandle_t t);
void vTaskDelay(TickType_t ticks);

/* ---- mbedTLS: the ROM digest of ra_patch.c, no tested path streams a ROM ------------------- */

typedef struct { int unused; } mbedtls_sha256_context;
void mbedtls_sha256_init(mbedtls_sha256_context *ctx);
int  mbedtls_sha256_starts(mbedtls_sha256_context *ctx, int is224);
int  mbedtls_sha256_update(mbedtls_sha256_context *ctx, const unsigned char *data, size_t len);
int  mbedtls_sha256_finish(mbedtls_sha256_context *ctx, unsigned char out[32]);
void mbedtls_sha256_free(mbedtls_sha256_context *ctx);

/* ---- lwIP: sockets for the FTP control connection ---------------------------------------- */

typedef uint32_t u32_t;
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

/* ---- what the tests set and read ----------------------------------------------------------- */

unsigned host_sdc_depth(void);                           /**< sdc_lock() held right now, 0 or 1 */
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
