# winvm (Mac development build of the winarm board). Needs Henge's objects:
.DEFAULT_GOAL := all
#   make -C ../../engines/gesso build/hengevm
H = ../../engines/gesso
CC = clang
CFLAGS = -std=c11 -Wall -Wextra -O2 -g -I. -I$(H)/core -I$(H)/host -I$(H)/devices
B = build
# TPM 2.0: libtpms + OpenSSL's libcrypto, both static (scripts/build-libtpms.sh builds libtpms).
# Without build/libtpms/install the board builds with no TPM and --tpm is refused.
TPMLIB = $(B)/libtpms/install
OSSL = $(shell brew --prefix openssl@3 2>/dev/null)
ifneq ($(wildcard $(TPMLIB)/lib/libtpms.a),)
CFLAGS += -DWINVM_LIBTPMS -I$(TPMLIB)/include
LIBS = $(TPMLIB)/lib/libtpms.a $(OSSL)/lib/libcrypto.a
endif
# Network (--net): Henge's libslirp NAT (host/net_slirp.c, dns_proxy.c) behind usb.c's CDC NCM adapter.
SLIRP_PC = PKG_CONFIG_PATH=$(shell brew --prefix libslirp 2>/dev/null)/lib/pkgconfig:$(shell brew --prefix glib 2>/dev/null)/lib/pkgconfig
SLIRP_CFLAGS = $(shell $(SLIRP_PC) pkg-config --cflags slirp 2>/dev/null)
SLIRP_LIBS = $(shell $(SLIRP_PC) pkg-config --libs slirp 2>/dev/null)
ifneq ($(SLIRP_LIBS),)
CFLAGS += -DWINVM_NET $(SLIRP_CFLAGS)
NETOBJ = $(B)/net_slirp.o $(B)/dns_proxy.o
LIBS += $(SLIRP_LIBS)
endif
$(B)/net_slirp.o: $(H)/host/net_slirp.c $(H)/host/*.h
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -w -c $< -o $@
$(B)/dns_proxy.o: $(H)/host/dns_proxy.c $(H)/host/*.h
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -w -c $< -o $@
all: $(B)/winvm
# TPM test: tpm.c's TIS registers against the real libtpms + libcrypto (needs scripts/build-libtpms.sh).
test: $(B)/tpm_test $(B)/blank_test $(B)/ncm_test $(B)/hid_test $(B)/restart_test
	$(B)/tpm_test $(B)
	$(B)/blank_test $(B)
	$(B)/ncm_test
	$(B)/hid_test
	$(B)/restart_test $(B)
$(B)/blank_test: tests/blank_test.c usb.h $(H)/host/disk.c
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -o $@ tests/blank_test.c $(H)/host/disk.c
$(B)/hid_test: tests/hid_test.c usb.c *.h $(H)/host/disk.c $(NETOBJ)
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -Wno-unused-function -o $@ tests/hid_test.c $(H)/host/disk.c $(NETOBJ) $(LIBS)
$(B)/ncm_test: tests/ncm_test.c ncm.h $(NETOBJ)
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -o $@ tests/ncm_test.c $(NETOBJ) $(SLIRP_LIBS)
$(B)/tpm_test: tests/tpm_test.c tpm.c *.h
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -Wno-unused-function -o $@ tests/tpm_test.c $(LIBS)
.PHONY: test
BOARD = winarm.c fwcfg.c pflash.c fdt.c acpi.c stubs.c $(wildcard nvme.c usb.c usb_storage.c hid.c tpm.c)
SRC = $(BOARD) winvm_main.c hvf.c
HOST = ../../app/WinVMHost/winvm_host.c
HOST_HEADER = ../../app/Triptych/Bridge/winvm_host.h
HB = $(H)/build-w
HOBJ = $(addprefix $(HB)/,classify.o operands.o translate.o dispatch.o mmu.o memop.o exception.o sysreg.o machine.o \
       jit_region.o enter.o disk.o gicv3.o timer.o pl011.o pl031.o pl061.o pcie.o xhci.o virtio.o virtio_net.o)
# Henge's objects for this board: 4 KB TLB pages (Windows and EDK2 map 4 KB; the default 16 KB entries send every such access down the slow path).
HOBJ_NAMES = classify.o operands.o translate.o dispatch.o mmu.o memop.o exception.o sysreg.o machine.o jit_region.o enter.o disk.o gicv3.o timer.o pl011.o pl031.o pl061.o pcie.o xhci.o virtio.o virtio_net.o
$(HOBJ): $(wildcard $(H)/core/*.[ch] $(H)/host/*.[ch] $(H)/devices/*.[ch])
	$(MAKE) -C $(H) B=build-w CFLAGS="-std=c11 -Wall -Wextra -O2 -g -Icore -Ihost -Idevices -DHV_TLB_PAGE_BITS=12" $(addprefix build-w/,$(HOBJ_NAMES))

dsdt_aml.h: dsdt.asl
	@mkdir -p $(B)
	iasl -vi -p $(B)/dsdt dsdt.asl >/dev/null
	xxd -i -n dsdt_aml $(B)/dsdt.aml > $@

ssdt_tpm_aml.h: ssdt_tpm.asl
	@mkdir -p $(B)
	iasl -vi -p $(B)/ssdt_tpm ssdt_tpm.asl >/dev/null
	xxd -i -n ssdt_tpm_aml $(B)/ssdt_tpm.aml > $@

$(B)/restart_test: tests/restart_test.c $(HOST) $(HOST_HEADER) $(BOARD) *.h dsdt_aml.h ssdt_tpm_aml.h $(HOBJ) $(NETOBJ) $(wildcard $(TPMLIB)/lib/libtpms.a)
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -o $@ tests/restart_test.c $(HOST) $(BOARD) $(HOBJ) $(NETOBJ) $(LIBS)

$(B)/winvm: $(SRC) *.h dsdt_aml.h ssdt_tpm_aml.h $(HOBJ) $(NETOBJ) $(wildcard $(TPMLIB)/lib/libtpms.a)
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(HOBJ) $(NETOBJ) $(LIBS) -framework CoreFoundation -framework Hypervisor
	codesign -f -s - --entitlements $(H)/host/hvf_ref.entitlements $@ 2>/dev/null || codesign -f -s - $@
clean:
	rm -rf $(B)
.PHONY: clean
