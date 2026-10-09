# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
#
# Host tests of five pieces of the firmware, with Unity from the submodule external/unity:
#   make -C tests/host          build and run all, exit status 1 when one fails
#   make -C tests/host SAN=0    without AddressSanitizer and UndefinedBehaviorSanitizer
#   make -C tests/host V=1      print the compiler lines and every test line
# The tested code and FatFs with its ffconf.h come straight from the fork, the game table from
# scripts/make_fw_tables.py as in the firmware build. FreeRTOS, lwIP, the card lock and the RA
# task are stand-ins in stubs/, the SD card is a RAM disk under the real FatFs. char is
# unsigned as on the Pico.

ROOT    ?= ../..
FORK    ?= $(ROOT)/external/FPGA-Companion/src
UNITY   ?= $(ROOT)/external/unity/src
MBEDTLS ?= $(ROOT)/external/pico-sdk/lib/mbedtls
SAN     ?= 1
V       ?= 0
Q       := $(if $(filter 1,$(V)),,@)
# one build folder per flag set, so a SAN=0 build never mixes with a sanitized one
BUILD   ?= build/$(if $(filter 1,$(SAN)),san,plain)

# a missing submodule would only show as a confusing compile error
ifneq ($(MAKECMDGOALS),clean)
$(foreach f,$(FORK)/ra_net.c $(UNITY)/unity.c $(MBEDTLS)/include/mbedtls/ssl.h,\
  $(if $(wildcard $(f)),,$(error $(f) is missing, run: git submodule update --init --recursive)))
endif

COMMON := -std=gnu11 -g -O1 -funsigned-char
ifeq ($(SAN),1)
# a sanitizer finding ends the test binary with an error instead of a line of output
COMMON += -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
endif
# the firmware's include paths, the generated stand-in headers first. Of mbedTLS and rcheevos
# only the headers ra_net.c includes, nothing of them is linked
INC     := -I$(BUILD)/inc -Istubs -I$(UNITY) -I$(FORK) -I$(FORK)/fatfs/source -I$(FORK)/rp2040 \
           -I$(FORK)/rcheevos/include -I$(FORK)/rcheevos/src -I$(MBEDTLS)/include
DEFINES := -DPICO_RP2350=1 -DGAME20K_VERSION=\"host\" -DGAME20K_PLATFORM=\"host\" \
           -DMBEDTLS_CONFIG_FILE=\"game20k_mbedtls_config.h\"
# third-party code (FatFs, Unity) as it is, ours with full warnings and every stand-in declared
LIB_CFLAGS := $(COMMON) -w $(INC) $(DEFINES)
OWN_CFLAGS := $(COMMON) -Wall -Wextra -include host_stubs.h $(INC) $(DEFINES)

# the headers the fork includes by name, generated, each one only includes stubs/host_stubs.h
FORWARD := FreeRTOS.h queue.h semphr.h task.h pico/time.h lwip/sockets.h lwip/netif.h \
           lwip/tcpip.h lwip/altcp_tls.h lwip/apps/http_client.h

# A changed flag set gets a new stamp file, which every object depends on, so nothing built
# with other flags stays in use.
STAMP := $(BUILD)/flags-$(shell printf '%s\n' '$(CC) $(LIB_CFLAGS) $(OWN_CFLAGS)' | cksum | cut -d' ' -f1).stamp

LIB_SRC := $(FORK)/fatfs/source/ff.c $(FORK)/fatfs/source/ffunicode.c $(UNITY)/unity.c
OWN_SRC := stubs/host_stubs.c stubs/ramdisk.c $(FORK)/ra_net.c $(FORK)/ra_slim.c
TESTS   := test_dechunk test_slim test_ftp_guard test_queue_lines test_games test_games_file
obj      = $(BUILD)/obj/$(notdir $(1:.c=.o))
# every test links all of these, test_ftp_guard includes ftpd.c, test_queue_lines ra_queue.c,
# test_games ra_games.c and test_games_file games_file.c themselves (their functions are static)
SHARED  := $(foreach s,$(LIB_SRC) $(OWN_SRC),$(call obj,$(s)))
# the game table made from the manifests, linked into test_games. The fork's example table is
# only compiled, so a build of the fork alone does not break unseen
GEN     := $(BUILD)/gen/ra_games_data.c
EXAMPLE := $(FORK)/ra_games_example.c

.PHONY: all check build clean
all check: build
	@V=$(V) sh ./run_tests.sh $(addprefix $(BUILD)/,$(TESTS))
build: $(addprefix $(BUILD)/,$(TESTS)) $(call obj,$(EXAMPLE))
clean:
	rm -rf build

$(STAMP):
	@rm -rf $(BUILD)/inc $(BUILD)/flags-*.stamp
	@mkdir -p $(BUILD)/obj $(addprefix $(BUILD)/inc/,$(sort $(dir $(FORWARD))))
	@for h in $(FORWARD); do echo '#include "host_stubs.h"' > $(BUILD)/inc/$$h; done
	@touch $@

# object: $(1) source, $(2) flags
define object
$(call obj,$(1)): $(1) $(STAMP)
	@$(if $(Q),echo "  CC  $$<",:)
	$(Q)$$(CC) $(2) -MMD -MP -c $$< -o $$@
endef
$(foreach s,$(LIB_SRC),$(eval $(call object,$(s),$$(LIB_CFLAGS))))
$(foreach s,$(OWN_SRC) $(addsuffix .c,$(TESTS)) $(GEN) $(EXAMPLE),$(eval $(call object,$(s),$$(OWN_CFLAGS))))

# the generator runs every time and rewrites the table only when it changes
.PHONY: FORCE
$(GEN): FORCE
	@python3 $(ROOT)/scripts/make_fw_tables.py --out $(BUILD)/gen
$(BUILD)/test_games: $(call obj,$(GEN))

$(BUILD)/test_%: $(BUILD)/obj/test_%.o $(SHARED)
	@$(if $(Q),echo "  LD  $@",:)
	$(Q)$(CC) $(COMMON) $^ -o $@

-include $(wildcard $(BUILD)/obj/*.d)
