// SPDX-License-Identifier: GPL-2.0-or-later
// usb.c's HID report path without a guest: usb_key's boot-keyboard reports (modifier bits for 0xe0-0xe7,
// up to six keys, release, rollover) and usb_tablet's absolute x/y, buttons and wheel, read back through
// the endpoint-IN and GET_REPORT handlers the xHCI model calls.
#include "../usb.c"

int hv_knob[HV_K_COUNT];
static int wakes;
void hv_machine_wake(HvMachine *m) { (void)m; wakes++; }
void *hv_phys_ptr(HvMachine *m, uint64_t pa, uint64_t len) { (void)m; (void)pa; (void)len; return NULL; }
int hv_phys_read(HvMachine *m, uint64_t pa, void *buf, unsigned len) { (void)m; (void)pa; (void)buf; (void)len; return 0; }
int hv_phys_write(HvMachine *m, uint64_t pa, const void *buf, unsigned len) { (void)m; (void)pa; (void)buf; (void)len; return 0; }
void hv_pci_init(HvPciDev *d, uint16_t v, uint16_t dev, uint32_t c, uint16_t sv, uint16_t sid) { (void)d; (void)v; (void)dev; (void)c; (void)sv; (void)sid; }
void hv_pci_add_bar(HvPciDev *d, int bar, uint64_t size, int is64) { (void)d; (void)bar; (void)size; (void)is64; }
int hv_pcie_attach(HvPcie *p, HvPciDev *d) { (void)p; (void)d; return 0; }
void hv_pci_set_intx(HvPciDev *d, int level) { (void)d; (void)level; }
void winarm_add_poll(WinArm *b, void (*fn)(void *), void *opaque) { (void)b; (void)fn; (void)opaque; }

int hv_virtio_net_receive(HvVirtioNet *n, const uint8_t *f, uint32_t len) { (void)n; (void)f; (void)len; return 0; }

static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

/* Pops the next queued report; returns its length, or -1 when the queue is empty (the device NAKs). */
static int pop(Hid *h, uint8_t out[8]) {
    uint32_t got = 0;
    memset(out, 0xee, 8);
    if (hid_ep_in(&h->d, 1, out, 8, &got) != 0) return -1;
    return (int)got;
}

static void kbd_expect(const char *what, const uint8_t want[8]) {
    uint8_t r[8];
    int n = pop(&kbd, r);
    if (n != 8 || memcmp(r, want, 8) != 0) {
        fprintf(stderr, "FAIL keyboard %s: n=%d got %02x %02x %02x %02x %02x %02x %02x %02x\n", what, n, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
        fails++;
    }
}

static void tab_expect(const char *what, const uint8_t want[6]) {
    uint8_t r[8];
    int n = pop(&tab, r);
    if (n != 6 || memcmp(r, want, 6) != 0) {
        fprintf(stderr, "FAIL tablet %s: n=%d got %02x %02x %02x %02x %02x %02x\n", what, n, r[0], r[1], r[2], r[3], r[4], r[5]);
        fails++;
    }
}

static void keyboard_tests(void) {
    uint8_t r[8];
    usb_key(0, 1); /* usage 0 is ignored */
    CHECK(pop(&kbd, r) == -1);

    usb_key(0x04, 1); /* A down */
    kbd_expect("A down", (uint8_t[8]){0, 0, 0x04, 0, 0, 0, 0, 0});
    usb_key(0x04, 0);
    kbd_expect("A up", (uint8_t[8]){0});

    for (int i = 0; i < 8; i++) { /* each modifier is its own bit in byte 0 */
        usb_key((uint8_t)(0xe0 + i), 1);
        uint8_t want[8] = {(uint8_t)(1u << i)};
        kbd_expect("modifier down", want);
        usb_key((uint8_t)(0xe0 + i), 0);
        kbd_expect("modifier up", (uint8_t[8]){0});
    }

    usb_key(0xe0, 1); usb_key(0xe1, 1); usb_key(0x06, 1); /* Ctrl+Shift+C */
    kbd_expect("ctrl", (uint8_t[8]){0x01});
    kbd_expect("ctrl+shift", (uint8_t[8]){0x03});
    kbd_expect("ctrl+shift+c", (uint8_t[8]){0x03, 0, 0x06});
    usb_key(0xe0, 0);
    kbd_expect("ctrl up keeps shift+c", (uint8_t[8]){0x02, 0, 0x06});
    usb_key(0x06, 0); usb_key(0xe1, 0);
    kbd_expect("c up", (uint8_t[8]){0x02});
    kbd_expect("all up", (uint8_t[8]){0});

    usb_key(0x04, 1); usb_key(0x04, 1); /* a repeated down must not take a second slot */
    kbd_expect("a", (uint8_t[8]){0, 0, 0x04});
    kbd_expect("a again", (uint8_t[8]){0, 0, 0x04});
    usb_key(0x04, 0);
    kbd_expect("a up", (uint8_t[8]){0});
    usb_key(0x04, 0); /* releasing a key that is not down changes nothing */
    kbd_expect("spurious up", (uint8_t[8]){0});

    for (uint8_t k = 4; k < 10; k++) usb_key(k, 1); /* six keys: fills the report */
    for (int i = 0; i < 6; i++) pop(&kbd, r);
    usb_key(0x0a, 1); /* the seventh is dropped (the report holds six) */
    kbd_expect("seventh dropped", (uint8_t[8]){0, 0, 4, 5, 6, 7, 8, 9});
    usb_key(0x06, 0); /* releasing from the middle compacts the rest in order */
    kbd_expect("release middle", (uint8_t[8]){0, 0, 4, 5, 7, 8, 9, 0});
    for (uint8_t k = 4; k < 10; k++) usb_key(k, 0);
    for (int i = 0; i < 6; i++) pop(&kbd, r);
    CHECK(pop(&kbd, r) == -1);
    CHECK(kbd.state[0] == 0 && kbd.state[2] == 0 && kbd.state[7] == 0);

    /* GET_REPORT returns the current state */
    usb_key(0xe2, 1); usb_key(0x2a, 1);
    uint8_t s[8] = {0xa1, 1, 0, 1, 0, 0, 8, 0}, b[8] = {0};
    CHECK(hid_control(&kbd.d, s, b, 8) == 8);
    CHECK(b[0] == 0x04 && b[2] == 0x2a);
    usb_key(0xe2, 0); usb_key(0x2a, 0);
    while (pop(&kbd, r) >= 0) {}

    /* an overflowing queue overwrites the newest and never corrupts the head */
    for (int i = 0; i < HID_Q + 10; i++) usb_key(4, i & 1 ? 0 : 1);
    int n = 0;
    while (pop(&kbd, r) >= 0) n++;
    CHECK(n == HID_Q);
}

static void tablet_tests(void) {
    uint8_t r[8];
    CHECK(pop(&tab, r) == -1);
    usb_tablet(0x1234, 0x2345, 0, 0);
    tab_expect("position", (uint8_t[6]){0, 0x34, 0x12, 0x45, 0x23, 0});
    usb_tablet(32767, 32767, 7, 0);
    tab_expect("max + all buttons", (uint8_t[6]){7, 0xff, 0x7f, 0xff, 0x7f, 0});
    usb_tablet(-5, 99999, 0xff, 0); /* clamped; only the three button bits survive */
    tab_expect("clamped", (uint8_t[6]){7, 0, 0, 0xff, 0x7f, 0});
    usb_tablet(100, 200, 1, 0);
    tab_expect("left", (uint8_t[6]){1, 100, 0, 200, 0, 0});
    usb_tablet(100, 200, 2, 0);
    tab_expect("right", (uint8_t[6]){2, 100, 0, 200, 0, 0});
    usb_tablet(100, 200, 4, 0);
    tab_expect("middle", (uint8_t[6]){4, 100, 0, 200, 0, 0});
    usb_tablet(100, 200, 0, 3);
    tab_expect("wheel up", (uint8_t[6]){0, 100, 0, 200, 0, 3});
    usb_tablet(100, 200, 0, -3);
    tab_expect("wheel down", (uint8_t[6]){0, 100, 0, 200, 0, 0xfd});
    usb_tablet(100, 200, 0, 1000);
    tab_expect("wheel clamp up", (uint8_t[6]){0, 100, 0, 200, 0, 127});
    usb_tablet(100, 200, 0, -1000);
    tab_expect("wheel clamp down", (uint8_t[6]){0, 100, 0, 200, 0, 0x81});

    usb_tablet(0x0102, 0x0304, 5, 9); /* GET_REPORT: buttons and position, no wheel */
    pop(&tab, r);
    uint8_t s[8] = {0xa1, 1, 0, 1, 0, 0, 6, 0}, b[8] = {0};
    CHECK(hid_control(&tab.d, s, b, 6) == 6);
    CHECK(b[0] == 5 && b[1] == 2 && b[2] == 1 && b[3] == 4 && b[4] == 3 && b[5] == 0);
}

int main(void) {
    Usb *x = calloc(1, sizeof *x);
    g_usb = x;
    hid_init(&kbd, 1);
    hid_init(&tab, 0);
    keyboard_tests();
    tablet_tests();
    CHECK(wakes > 0);
    free(x);
    if (fails) { fprintf(stderr, "%d failure(s)\n", fails); return 1; }
    printf("hid_test: ok\n");
    return 0;
}
