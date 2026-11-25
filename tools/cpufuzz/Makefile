HENGE ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../../engines/gesso)
CC = clang
CFLAGS = -std=c11 -Wall -Wextra -O2 -g -I. -I$(HENGE)/core -I$(HENGE)/host -I$(HENGE)/devices

CORE_NAMES = classify operands translate dispatch mmu memop exception sysreg machine
HOST_NAMES = jit_region disk
FUZZ_SRCS = gen.c main.c ref_run.c henge_run.c

B16 = build-16k
B4  = build-4k

HOBJ_16 = $(addprefix $(B16)/henge/,$(addsuffix .o,$(CORE_NAMES) $(HOST_NAMES) enter))
HOBJ_4  = $(addprefix $(B4)/henge/,$(addsuffix .o,$(CORE_NAMES) $(HOST_NAMES) enter))

FOBJ_16 = $(B16)/gen.o $(B16)/main.o $(B16)/ref_run.o $(B16)/henge_run.o $(B16)/ref_trampoline.o
FOBJ_4  = $(B4)/gen.o  $(B4)/main.o  $(B4)/ref_run.o  $(B4)/henge_run.o  $(B4)/ref_trampoline.o

all: $(B16)/cpufuzz-16k $(B4)/cpufuzz-4k

$(B16) $(B16)/henge $(B4) $(B4)/henge:
	@mkdir -p $@

# 16 KB TLB build (default HV_TLB_PAGE_BITS=14)
$(B16)/henge/mmu.o: $(HENGE)/core/mmu.c | $(B16)/henge
	$(CC) $(CFLAGS) -mgeneral-regs-only -c $< -o $@
$(B16)/henge/%.o: $(HENGE)/core/%.c | $(B16)/henge
	$(CC) $(CFLAGS) -c $< -o $@
$(B16)/henge/%.o: $(HENGE)/host/%.c | $(B16)/henge
	$(CC) $(CFLAGS) -c $< -o $@
$(B16)/henge/enter.o: $(HENGE)/host/enter.S | $(B16)/henge
	$(CC) -c $< -o $@
$(B16)/%.o: %.c fuzz.h | $(B16)
	$(CC) $(CFLAGS) -c $< -o $@
$(B16)/ref_trampoline.o: ref_trampoline.S | $(B16)
	$(CC) -c $< -o $@
$(B16)/cpufuzz-16k: $(FOBJ_16) $(HOBJ_16)
	$(CC) $(CFLAGS) $^ -o $@
	codesign -f -s - $@

# 4 KB TLB build (-DHV_TLB_PAGE_BITS=12, matching engines/winvm)
CFLAGS4 = $(CFLAGS) -DHV_TLB_PAGE_BITS=12
$(B4)/henge/mmu.o: $(HENGE)/core/mmu.c | $(B4)/henge
	$(CC) $(CFLAGS4) -mgeneral-regs-only -c $< -o $@
$(B4)/henge/%.o: $(HENGE)/core/%.c | $(B4)/henge
	$(CC) $(CFLAGS4) -c $< -o $@
$(B4)/henge/%.o: $(HENGE)/host/%.c | $(B4)/henge
	$(CC) $(CFLAGS4) -c $< -o $@
$(B4)/henge/enter.o: $(HENGE)/host/enter.S | $(B4)/henge
	$(CC) -DHV_TLB_PAGE_BITS=12 -c $< -o $@
$(B4)/%.o: %.c fuzz.h | $(B4)
	$(CC) $(CFLAGS4) -c $< -o $@
$(B4)/ref_trampoline.o: ref_trampoline.S | $(B4)
	$(CC) -c $< -o $@
$(B4)/cpufuzz-4k: $(FOBJ_4) $(HOBJ_4)
	$(CC) $(CFLAGS4) $^ -o $@
	codesign -f -s - $@

clean:
	rm -rf $(B16) $(B4)

.PHONY: all clean
