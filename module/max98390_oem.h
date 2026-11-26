/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __MAX98390_OEM_H
#define __MAX98390_OEM_H

struct max98390_hda_priv;
int max98390_oem_prepare(struct max98390_hda_priv *priv);
int max98390_oem_program(struct max98390_hda_priv *priv);

#endif
