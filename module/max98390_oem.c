// SPDX-License-Identifier: GPL-2.0
/* Samsung 960XGL / 144d:c1d8: M98W v1 from ADIAmpDriver 1.0.0.44.
 * Format and register sequence: Andycodeman/samsung-galaxy-book-linux-fixes,
 * c04a8bb58500792117eec20f619e4c4b2de484f5, speaker-fix/.
 * No vendor coefficients are distributed with the driver.
 */
#include <crypto/sha2.h>
#include <linux/delay.h>
#include <linux/dmi.h>
#include <linux/firmware.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/unaligned.h>
#include <sound/hdaudio.h>
#include "max98390_hda.h"
#include "max98390_oem.h"
#include "max98390_regs.h"

#define OEM_FW "max98390-galaxybook.bin"
#define OEM_SIZE 1522

static const u8 oem_sha256[SHA256_DIGEST_SIZE] = {
	0xa7, 0x04, 0xdc, 0xca, 0x7f, 0xb7, 0x40, 0x77,
	0x96, 0x16, 0x82, 0x6d, 0xca, 0xd3, 0xf4, 0xe1,
	0x95, 0xfb, 0xc5, 0x1a, 0xf0, 0xb5, 0x9b, 0xc9,
	0x43, 0xdf, 0xb5, 0xa0, 0x0b, 0xad, 0x7e, 0x68,
};

static int samsung_codec(struct device *dev, const void *unused)
{
	struct hdac_device *codec = dev_to_hdac_dev(dev);

	return codec->vendor_id == 0x10ec0298 && codec->subsystem_id == 0x144dc1d8;
}

static void put_fw(void *ptr)
{
	release_firmware(ptr);
}

static int parse_oem(struct max98390_hda_priv *priv, const struct firmware *fw)
{
	static const unsigned int regs[] = {35, 35, 17, 17}, dsm[] = {95, 40};
	const u8 *p, *end, *selected_regs = NULL, *selected_dsm = NULL;
	unsigned int i, j, addr, n, idx = priv->index, pair = idx / 2;
	u8 digest[SHA256_DIGEST_SIZE];

	if (idx >= ARRAY_SIZE(regs) || fw->size != OEM_SIZE)
		return -EINVAL;
	sha256(fw->data, fw->size, digest);
	if (memcmp(digest, oem_sha256, sizeof(digest)))
		return -EBADMSG;
	p = fw->data;
	end = p + fw->size;
	if (memcmp(p, "M98W", 4) || get_unaligned_le16(p + 4) != 1 ||
	    get_unaligned_le16(p + 6) != ARRAY_SIZE(regs))
		return -EINVAL;
	p += 8;
	for (i = 0; i < ARRAY_SIZE(regs); i++) {
		if (end - p < 2 || (n = get_unaligned_le16(p)) != regs[i])
			return -EINVAL;
		p += 2;
		if (end - p < n * 4)
			return -EINVAL;
		if (i == idx)
			selected_regs = p;
		for (j = 0; j < n; j++, p += 4) {
			addr = get_unaligned_le16(p);
			if (get_unaligned_le16(p + 2) > 0xff || addr < 0x2012 ||
			    addr > MAX98390_R23E1_DSP_GLOBAL_EN || addr == MAX98390_R203A_AMP_EN ||
			    ((addr == MAX98390_R23E1_DSP_GLOBAL_EN) != (j == n - 1)))
				return -EINVAL;
		}
	}
	if (end - p < 2 || get_unaligned_le16(p) != ARRAY_SIZE(dsm))
		return -EINVAL;
	p += 2;
	for (i = 0; i < ARRAY_SIZE(dsm); i++) {
		if (end - p < 2 || (n = get_unaligned_le16(p)) != dsm[i])
			return -EINVAL;
		p += 2;
		if (end - p < n * 8)
			return -EINVAL;
		if (i == pair)
			selected_dsm = p;
		for (j = 0; j < n; j++, p += 8) {
			addr = get_unaligned_le16(p);
			if (get_unaligned_le16(p + 2) || (addr & 3) ||
			    addr < 0x2100 || addr > 0x22dc)
				return -EINVAL;
		}
	}
	if (end - p != 4 || memcmp(p, "\x00\x00\x01\x01", 4))
		return -EINVAL;
	priv->oem_regs = selected_regs;
	priv->oem_nregs = regs[idx];
	priv->oem_dsm = selected_dsm;
	priv->oem_ndsm = dsm[pair];
	return 0;
}

int max98390_oem_prepare(struct max98390_hda_priv *priv)
{
	static const int amp_address[] = {0x38, 0x39, 0x3c, 0x3d};
	const struct firmware *fw;
	struct pci_dev *audio;
	struct device *codec;
	int ret;

	/* Redrix coefficients are not a substitute for Samsung speaker protection. */
	if (dmi_match(DMI_SYS_VENDOR, "Google") && dmi_match(DMI_PRODUCT_NAME, "Redrix"))
		return 0;
	if (!dmi_match(DMI_SYS_VENDOR, "SAMSUNG ELECTRONICS CO., LTD.") ||
	    !dmi_match(DMI_PRODUCT_NAME, "960XGL"))
		return dev_err_probe(priv->dev, -ENODEV, "no validated speaker profile for this model\n");
	if (priv->index < 0 || priv->index >= (int)ARRAY_SIZE(amp_address) ||
	    amp_address[priv->index] != priv->i2c_addr)
		return dev_err_probe(priv->dev, -EINVAL, "unexpected amp address/index\n");
	audio = pci_get_subsys(PCI_VENDOR_ID_INTEL, 0x7e28, 0x144d, 0xc1d8, NULL);
	if (!audio)
		return dev_err_probe(priv->dev, -ENODEV, "unsupported Samsung audio subsystem\n");
	pci_dev_put(audio);
	codec = bus_find_device(&snd_hda_bus_type, NULL, NULL, samsung_codec);
	if (!codec)
		return dev_err_probe(priv->dev, -EPROBE_DEFER, "waiting for Samsung c1d8 ALC298 codec\n");
	put_device(codec);
	ret = request_firmware_direct(&fw, OEM_FW, priv->dev);
	if (ret)
		return dev_err_probe(priv->dev, ret, "Samsung speaker profile %s unavailable; amps left off\n", OEM_FW);
	ret = parse_oem(priv, fw);
	if (ret) {
		release_firmware(fw);
		return dev_err_probe(priv->dev, ret, "Samsung speaker profile not authentic or malformed; amps left off\n");
	}
	ret = devm_add_action_or_reset(priv->dev, put_fw, (void *)fw);
	if (!ret)
		priv->oem = true;
	return ret;
}

int max98390_oem_program(struct max98390_hda_priv *priv)
{
	const u8 *p;
	u8 data[4];
	unsigned int i;
	int ret;

	if (!priv->oem || !priv->oem_regs || !priv->oem_dsm)
		return -EINVAL;
	/* The final register in each table is DSP enable. Do not enable the
	 * DSP or the speaker with partially loaded coefficients. The caller
	 * already turned global, amp and DSP off, in that order.
	 */
	for (i = 0, p = priv->oem_regs; i + 1 < priv->oem_nregs; i++, p += 4) {
		ret = regmap_write(priv->regmap, get_unaligned_le16(p), get_unaligned_le16(p + 2));
		if (ret)
			return ret;
	}
	for (i = 0, p = priv->oem_dsm; i < priv->oem_ndsm; i++, p += 8) {
		put_unaligned_be32(get_unaligned_le32(p + 4), data);
		ret = regmap_bulk_write(priv->regmap, get_unaligned_le16(p), data, sizeof(data));
		if (ret)
			return ret;
	}
	ret = regmap_write(priv->regmap, MAX98390_R23E1_DSP_GLOBAL_EN, 1);
	if (!ret)
		ret = regmap_write(priv->regmap, MAX98390_R203A_AMP_EN, 0x81);
	if (!ret)
		ret = regmap_write(priv->regmap, MAX98390_R23FF_GLOBAL_EN, 1);
	return ret;
}

MODULE_FIRMWARE(OEM_FW);
