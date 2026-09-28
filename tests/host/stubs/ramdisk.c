// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
/** @file ramdisk.c
 *  @brief A 4 MB card in RAM under the fork's real FatFs, in place of the SD card behind the FPGA.
 *
 *  FatFs is the real one, built with the firmware's ffconf.h, only the disk below it is a
 *  stand-in. The firmware's ffconf.h leaves f_mkfs() out, so host_card_new() writes an empty
 *  FAT16 volume by hand. What this cannot show: timing, a card that loses a write it
 *  acknowledged, and anything in sdc.c itself. */
#include <string.h>

#include "ff.h"
#include "diskio.h"

#define SECTOR       512u
#define SECTORS      8192u   /* 4 MB */
#define RESERVED     1u      /* the boot sector */
#define FAT_SECTORS  32u     /* 8095 clusters of one sector, two bytes each, fit */
#define ROOT_SECTORS 32u     /* 512 root entries of 32 bytes */

static unsigned char disk[SECTORS][SECTOR];
static FATFS         volume;

static void put16(unsigned char *p, unsigned v) { p[0] = (unsigned char)v; p[1] = (unsigned char)(v >> 8); }

/* An empty FAT16 volume without a partition table, laid out as Microsoft's FAT specification
   (fatgen103) describes it: boot sector, two FATs with their two reserved entries, an empty
   root directory. */
static void format_fat16(void) {
  unsigned char *b = disk[0];
  memset(disk, 0, sizeof(disk));
  b[0] = 0xeb; b[1] = 0x3c; b[2] = 0x90;
  memcpy(b + 3, "MSDOS5.0", 8);
  put16(b + 11, SECTOR);                       // bytes per sector
  b[13] = 1;                                   // sectors per cluster
  put16(b + 14, RESERVED);                     // reserved sectors
  b[16] = 2;                                   // number of FATs
  put16(b + 17, ROOT_SECTORS * SECTOR / 32);   // root entries
  put16(b + 19, SECTORS);                      // total sectors (16 bit)
  b[21] = 0xf8;                                // fixed disk
  put16(b + 22, FAT_SECTORS);                  // sectors per FAT
  put16(b + 24, 32);                           // sectors per track
  put16(b + 26, 2);                            // heads
  b[36] = 0x80;                                // drive number
  b[38] = 0x29;                                // extended boot signature
  memcpy(b + 43, "NO NAME    FAT16   ", 19);   // volume label and file system type
  b[510] = 0x55; b[511] = 0xaa;
  // both FATs: entry 0 carries the media byte, entry 1 the end-of-chain mark
  for(unsigned f = 0; f < 2; f++) {
    unsigned char *fat = disk[RESERVED + f * FAT_SECTORS];
    fat[0] = 0xf8; fat[1] = 0xff; fat[2] = 0xff; fat[3] = 0xff;
  }
}

bool host_card_new(void) {
  f_mount(NULL, "/sd", 0);   // forget the previous card
  format_fat16();
  return f_mount(&volume, "/sd", 1) == FR_OK;
}

bool host_card_put(const char *path, const void *data, size_t len) {
  FIL f; UINT put = 0;
  if(f_open(&f, path, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK) return false;
  FRESULT r = f_write(&f, data, (UINT)len, &put);
  FRESULT c = f_close(&f);
  return r == FR_OK && c == FR_OK && put == len;
}

long host_card_get(const char *path, char *buf, size_t cap) {
  FIL f; UINT got = 0;
  if(!cap || f_open(&f, path, FA_READ) != FR_OK) return -1;
  FRESULT r = f_read(&f, buf, (UINT)(cap - 1), &got);
  f_close(&f);
  buf[got] = 0;
  return r == FR_OK ? (long)got : -1;
}

bool host_card_exists(const char *path) {
  FILINFO fi;
  return f_stat(path, &fi) == FR_OK;
}

/* ---- FatFs' disk interface (diskio.h), drive 0 is the card ------------------------------------ */

DSTATUS disk_status(BYTE pdrv) { return pdrv == 0 ? 0 : STA_NOINIT; }
DSTATUS disk_initialize(BYTE pdrv) { return disk_status(pdrv); }

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count) {
  if(pdrv || sector >= SECTORS || count > SECTORS - sector) return RES_PARERR;
  memcpy(buff, disk[sector], (size_t)count * SECTOR);
  return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count) {
  if(pdrv || sector >= SECTORS || count > SECTORS - sector) return RES_PARERR;
  memcpy(disk[sector], buff, (size_t)count * SECTOR);
  return RES_OK;
}

// sdc.c, sdc_ioctl(): CTRL_SYNC and GET_SECTOR_SIZE succeed, every other request fails
DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff) {
  if(pdrv == 0 && cmd == CTRL_SYNC) return RES_OK;
  if(pdrv == 0 && cmd == GET_SECTOR_SIZE) { *(WORD *)buff = SECTOR; return RES_OK; }
  return RES_ERROR;
}

/* FatFs' clock for file dates (ff.h, get_fattime()), a fixed day: 28 September 2026, 12:00. */
DWORD get_fattime(void) {
  return ((DWORD)(2026 - 1980) << 25) | ((DWORD)9 << 21) | ((DWORD)28 << 16) | ((DWORD)12 << 11);
}
