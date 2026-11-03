# Why Fire OS cannot be replaced

Short version: the hardware only runs Amazon's code, and even if it did not,
nobody has written drivers for the panel.

## The three walls

**1. A signed boot chain.** `ro.boot.verifiedbootstate=1` and `ro.secure=1` on a
`user` build. The SoC checks a signature that only Amazon holds, and the key
material is fused into the chip. There is no `fastboot flashing unlock` on Fire
TV hardware, and no vendor key to request.

**2. dm-verity.** `/proc/config.gz` shows `CONFIG_DM_VERITY=y`. `/system` and
`/vendor` are verified block by block. Writing to them — a hosts file, a deleted
system APK, a remount — fails verification and the device stops booting. This is
the documented brick path, not a rumour.

**3. No open drivers for the panel.** CoreELEC and LibreELEC support Amlogic
*set-top boxes*. A television also needs drivers for its LCD panel, backlight,
HDMI input switching and tuner. Those do not exist in the open, so even a
hypothetical unlock ends at a black screen.

## What about a root exploit?

Kernel exploits for Fire OS do turn up. What they give is a root shell until the
next reboot, which can disable the handful of packages Amazon protects. They do not
unlock the bootloader, cannot write `/system` past dm-verity, and do not survive a
reboot. Each one is tied to an exact firmware build and gets patched. The DNS
filter already blocks what those protected packages send, without the risk.

## The conclusion this repo is built on

Keep Amazon's kernel. Remove Amazon's behaviour, at four levels that Amazon does
not control: package state, app-ops, network policy, and DNS. Then put a
different launcher on top. Everything in `scripts/` is that plan.
