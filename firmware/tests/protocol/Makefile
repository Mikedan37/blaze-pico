CC ?= cc
CFLAGS ?= -std=c99 -O1 -g -Wall -Wextra -Wpedantic -Werror -Wconversion -Wshadow -Wcast-qual -Wstrict-prototypes
SANITIZE ?= -fsanitize=address,undefined -fno-omit-frame-pointer

FW := ../..
INCLUDES := -I$(FW)/protocol -I$(FW)/third_party/blazebinary -I$(FW)/third_party/blazetransport
SOURCES := $(FW)/protocol/blaze_serial.c $(FW)/protocol/pico_command.c \
           $(FW)/third_party/blazebinary/blaze_binary.c $(FW)/third_party/blazetransport/blaze_transport.c
BUILD := build

.PHONY: all test clean

all: $(BUILD)/test_protocol

$(BUILD)/test_protocol: $(SOURCES) test_protocol.c $(wildcard $(FW)/protocol/*.h $(FW)/third_party/*/*.h)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SANITIZE) $(INCLUDES) $(SOURCES) test_protocol.c -o $@

test: $(BUILD)/test_protocol
	$(BUILD)/test_protocol golden_frames.txt

clean:
	rm -rf $(BUILD)
