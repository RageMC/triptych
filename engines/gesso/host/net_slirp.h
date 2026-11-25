#ifndef HENGEVM_NET_SLIRP_H
#define HENGEVM_NET_SLIRP_H

#include "machine.h"
#include "virtio_net.h"

/* Before hv_net_attach: the Unix socket behind the guest's 10.0.2.4:80 (share.c). */
void hv_net_set_share_socket(const char *path);
/* User-mode NAT for the guest's virtio-net (see net_slirp.c). Returns 0 on success. */
int hv_net_attach(HvMachine *m, HvVirtioNet *n);
/* The same NAT for another network device: rx gets each frame for the guest (CPU thread, from
   hv_net_poll) and returns 0 if it has no room yet; the device hands the guest's frames to
   hv_net_transmit. Returns 0 on success. */
int hv_net_attach_rx(HvMachine *m, int (*rx)(void *opaque, const uint8_t *frame, uint32_t len), void *opaque);
/* CPU thread: a frame the guest sent (devices attached with hv_net_attach_rx). */
void hv_net_transmit(const uint8_t *frame, uint32_t len);
/* CPUs must be stopped. Joins the network worker before its machine is freed. */
void hv_net_detach(void);
/* CPU thread, from the board's tick: hand frames for the guest to the device. */
void hv_net_poll(void);

extern uint64_t hv_net_tx_frames, hv_net_rx_frames;

#endif
