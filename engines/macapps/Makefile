CC ?= cc
AR ?= ar
CFLAGS ?= -O2 -Wall -Wextra -Werror=implicit-function-declaration
LIB_CFLAGS := $(CFLAGS) -std=c11

BUILD_DIR := build
OBJ_DIR := $(BUILD_DIR)/obj

ZLIB_DIR := third_party/zlib
BZIP2_DIR := third_party/bzip2
LZFSE_DIR := third_party/lzfse
XZ_DIR := third_party/xz-embedded

ZLIB_SRCS := \
	$(ZLIB_DIR)/adler32.c \
	$(ZLIB_DIR)/crc32.c \
	$(ZLIB_DIR)/inffast.c \
	$(ZLIB_DIR)/inflate.c \
	$(ZLIB_DIR)/inftrees.c \
	$(ZLIB_DIR)/zutil.c

BZIP2_SRCS := \
	$(BZIP2_DIR)/blocksort.c \
	$(BZIP2_DIR)/bzlib.c \
	$(BZIP2_DIR)/compress.c \
	$(BZIP2_DIR)/crctable.c \
	$(BZIP2_DIR)/decompress.c \
	$(BZIP2_DIR)/huffman.c \
	$(BZIP2_DIR)/randtable.c

LZFSE_SRCS := \
	$(LZFSE_DIR)/lzfse_decode.c \
	$(LZFSE_DIR)/lzfse_decode_base.c \
	$(LZFSE_DIR)/lzfse_fse.c \
	$(LZFSE_DIR)/lzvn_decode_base.c

XZ_SRCS := \
	$(XZ_DIR)/xz_crc32.c \
	$(XZ_DIR)/xz_crc64.c \
	$(XZ_DIR)/xz_dec_bcj.c \
	$(XZ_DIR)/xz_dec_lzma2.c \
	$(XZ_DIR)/xz_dec_stream.c \
	$(XZ_DIR)/xz_sha256.c

DMG_LIB_SRCS := \
	dmg/stream.c \
	dmg/codecs.c \
	dmg/xml_plist.c \
	dmg/udif.c \
	dmg/hfsplus.c \
	dmg/apfs.c \
	dmg/pkg.c \
	dmg/zip.c \
	dmg/macpkg.c

CLI_SRCS := dmg/macpkg_cli.c

ZLIB_OBJS := $(patsubst $(ZLIB_DIR)/%.c,$(OBJ_DIR)/zlib_%.o,$(ZLIB_SRCS))
BZIP2_OBJS := $(patsubst $(BZIP2_DIR)/%.c,$(OBJ_DIR)/bzip2_%.o,$(BZIP2_SRCS))
LZFSE_OBJS := $(patsubst $(LZFSE_DIR)/%.c,$(OBJ_DIR)/lzfse_%.o,$(LZFSE_SRCS))
XZ_OBJS := $(patsubst $(XZ_DIR)/%.c,$(OBJ_DIR)/xz_%.o,$(XZ_SRCS))
DMG_LIB_OBJS := $(patsubst dmg/%.c,$(OBJ_DIR)/dmg_%.o,$(DMG_LIB_SRCS))
CLI_OBJS := $(patsubst dmg/%.c,$(OBJ_DIR)/cli_%.o,$(CLI_SRCS))

LIB_OBJS := $(DMG_LIB_OBJS) $(ZLIB_OBJS) $(BZIP2_OBJS) $(LZFSE_OBJS) $(XZ_OBJS)

ZLIB_CPPFLAGS := -DZ_SOLO -DZ_PREFIX -I$(ZLIB_DIR)
BZIP2_CPPFLAGS := -DBZ_NO_STDIO -I$(BZIP2_DIR)
LZFSE_CPPFLAGS := -I$(LZFSE_DIR)
XZ_CPPFLAGS := -DXZ_USE_CRC64 -DXZ_USE_SHA256 -DXZ_DEC_ANY_CHECK -DXZ_DEC_CONCATENATED \
	-DXZ_DEC_X86 -DXZ_DEC_ARM -DXZ_DEC_ARMTHUMB -DXZ_DEC_ARM64 \
	-DXZ_DEC_RISCV -DXZ_DEC_POWERPC -DXZ_DEC_IA64 -DXZ_DEC_SPARC -I$(XZ_DIR)
DMG_CPPFLAGS := -DZ_SOLO -DZ_PREFIX -DXZ_USE_CRC64 -Idmg -I$(ZLIB_DIR) -I$(BZIP2_DIR) -I$(LZFSE_DIR) -I$(XZ_DIR)

.PHONY: all clean

all: $(BUILD_DIR)/libmacpkg.a $(BUILD_DIR)/macpkg

$(OBJ_DIR):
	@mkdir -p $(OBJ_DIR)

$(OBJ_DIR)/zlib_%.o: $(ZLIB_DIR)/%.c | $(OBJ_DIR)
	$(CC) $(LIB_CFLAGS) $(ZLIB_CPPFLAGS) -c $< -o $@

$(OBJ_DIR)/bzip2_%.o: $(BZIP2_DIR)/%.c | $(OBJ_DIR)
	$(CC) $(LIB_CFLAGS) $(BZIP2_CPPFLAGS) -c $< -o $@

$(OBJ_DIR)/lzfse_%.o: $(LZFSE_DIR)/%.c | $(OBJ_DIR)
	$(CC) $(LIB_CFLAGS) $(LZFSE_CPPFLAGS) -c $< -o $@

$(OBJ_DIR)/xz_%.o: $(XZ_DIR)/%.c | $(OBJ_DIR)
	$(CC) $(LIB_CFLAGS) $(XZ_CPPFLAGS) -c $< -o $@

$(OBJ_DIR)/dmg_%.o: dmg/%.c dmg/macpkg.h dmg/macpkg_internal.h | $(OBJ_DIR)
	$(CC) $(LIB_CFLAGS) $(DMG_CPPFLAGS) -c $< -o $@

$(OBJ_DIR)/cli_%.o: dmg/%.c dmg/macpkg.h | $(OBJ_DIR)
	$(CC) $(LIB_CFLAGS) -Idmg -c $< -o $@

$(BUILD_DIR)/libmacpkg.a: $(LIB_OBJS)
	$(AR) rcs $@ $(LIB_OBJS)

$(BUILD_DIR)/macpkg: $(CLI_OBJS) $(BUILD_DIR)/libmacpkg.a
	$(CC) $(LIB_CFLAGS) $(LDFLAGS) -o $@ $(CLI_OBJS) $(BUILD_DIR)/libmacpkg.a

clean:
	rm -rf $(BUILD_DIR)
