// SPDX-License-Identifier: GPL-2.0
// Stub Linux interfaces only. The M98W parser/programmer is included unchanged.
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
#define SHA256_DIGEST_SIZE 32
#define REGCACHE_NONE 0
#define PCI_VENDOR_ID_INTEL 0x8086
#define EPROBE_DEFER 517
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define MODULE_FIRMWARE(name)
#define dev_info(...) ((void)0)
#define dev_err(...) ((void)0)
#define dev_err_probe(dev, err, ...) (err)
struct device { int unused; };
struct regmap { int unused; };
struct regmap_config { int reg_bits, val_bits, max_register, cache_type; };
struct firmware { size_t size; const u8 *data; };
struct pci_dev { struct device dev; };
struct hdac_device { struct device dev; unsigned int vendor_id, subsystem_id; };
enum { DMI_SYS_VENDOR, DMI_PRODUCT_NAME, DMI_BOARD_NAME };
static struct device dev;
static struct regmap map;
static struct firmware fw;
static struct pci_dev pci;
static struct hdac_device codec;
static bool pci_present, codec_present;
static int model;
static int snd_hda_bus_type;
static int requests, releases;
static void (*compute_hash)(const u8 *, size_t, u8 *);
static int (*emit_write)(unsigned int, unsigned int, unsigned int);
static void (*release_action)(void *);
static void *release_arg;

static const char *dmi_get_system_info(int which)
{
    if (model == 7)
        return which == DMI_SYS_VENDOR ? "Google" : "Redrix";
    if (which == DMI_SYS_VENDOR)
        return model != 1 ? "SAMSUNG ELECTRONICS CO., LTD." : "Another vendor";
    if (which == DMI_PRODUCT_NAME)
        return model != 2 ? "960XGL" : "Another model";
    if (which == DMI_BOARD_NAME)
        return "NP960XGL-XG1BR";
    return NULL;
}
static bool dmi_match(int field, const char *s)
{
    const char *v = dmi_get_system_info(field);
    return v && strcmp(v, s) == 0;
}
static struct pci_dev *pci_get_subsys(unsigned int v, unsigned int d,
                  unsigned int sv, unsigned int sd, struct pci_dev *from)
{
    return pci_present && v == 0x8086 && d == 0x7e28 &&
        sv == 0x144d && sd == 0xc1d8 && !from ? &pci : NULL;
}
static void pci_dev_put(struct pci_dev *p) { assert(p == &pci); }
static struct device *bus_find_device(const void *bus, struct device *start,
              const void *data, int (*match)(struct device *, const void *))
{
    assert(bus == &snd_hda_bus_type && !start);
    return codec_present && match(&codec.dev, data) ? &codec.dev : NULL;
}
#define dev_to_hdac_dev(ptr) ((struct hdac_device *)(ptr))
static void put_device(struct device *p) { assert(p == &codec.dev); }
static int request_firmware_direct(const struct firmware **out,
                                   const char *name, struct device *p)
{
    assert(!strcmp(name, "max98390-galaxybook.bin") && p == &dev);
    ++requests;
    if (!fw.data)
        return -ENOENT;
    *out = &fw;
    return 0;
}
static void release_firmware(const struct firmware *f)
{
    assert(f == &fw);
    ++releases;
}
static int devm_add_action_or_reset(struct device *p, void (*action)(void *), void *arg)
{
    assert(p == &dev && !release_action);
    if (model == 8) {
        action(arg);
        return -ENOMEM;
    }
    release_action = action;
    release_arg = arg;
    return 0;
}
static void sha256(const u8 *p, size_t n, u8 *digest) { compute_hash(p, n, digest); }
static u16 get_unaligned_le16(const u8 *p) { return p[0] | ((u16)p[1] << 8); }
static u32 get_unaligned_le32(const u8 *p)
{
    return get_unaligned_le16(p) | ((u32)get_unaligned_le16(p + 2) << 16);
}
static void put_unaligned_be32(u32 v, u8 *p)
{
    p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}
static int regmap_write(struct regmap *m, unsigned int addr, unsigned int v)
{
    assert(m == &map && v < 256); return emit_write(addr, v, 1);
}
static int regmap_bulk_write(struct regmap *m, unsigned int addr, const void *data, size_t n)
{
    const u8 *p = data;
    assert(m == &map && n == 4);
    return emit_write(addr, ((u32)p[0] << 24) | ((u32)p[1] << 16) |
                      ((u32)p[2] << 8) | p[3], 4);
}
#include "max98390_oem.c"

static struct max98390_hda_priv ctx;
int bench_prepare(const u8 *data, size_t n, int index, int addr, int board,
          void (*hash_cb)(const u8 *, size_t, u8 *),
          int (*write_cb)(unsigned int, unsigned int, unsigned int))
{
    release_action = NULL;
    release_arg = NULL;
    ctx = (struct max98390_hda_priv){ .dev = &dev, .regmap = &map,
        .index = index, .i2c_addr = addr };
    fw = (struct firmware){ .data = data, .size = n };
    compute_hash = hash_cb; emit_write = write_cb;
    model = board; pci_present = board != 3; codec_present = board != 4;
    codec.vendor_id = board == 5 ? 0x10ec0299 : 0x10ec0298;
    codec.subsystem_id = board == 6 ? 0x144dc1d9 : 0x144dc1d8;
    requests = releases = 0;
    return max98390_oem_prepare(&ctx);
}
int bench_program(void) { return max98390_oem_program(&ctx); }
int bench_requests(void) { return requests; }
int bench_is_oem(void) { return ctx.oem; }
void bench_cleanup(void)
{
    if (release_action)
        release_action(release_arg);
    assert(releases == (requests && fw.data ? 1 : 0));
}
