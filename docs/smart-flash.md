# Smart Flash — Technical Concept

## Problem

`make flash` writes the full `retrostick.img` to the USB stick with `dd`, which
overwrites every partition including `RETROGAMES` (P4). This destroys:

- Save states (`machines/<name>/states/`)
- Battery saves (`machines/<name>/saves/`)
- In-game disk writes — e.g. a `.d64` the C64 wrote to during play is replaced
  by the clean source copy from `machines/<name>/disks/`

A full reflash is required every time the bootloader, kernel, rootfs, or any
machine config changes. Without save preservation, the stick is not practical
for ongoing use.

---

## Approach: Per-Partition Write + rsync

Instead of flashing the full image, `make smart-flash` does two targeted steps:

### Step 1 — Write system partitions (always)

Write P1 (BIOSBOOT), P2 (RETROBOOT), and P3 (RETROROOT) directly from the
built image using per-partition `dd` with byte offsets. These partitions contain
no user data and must always reflect the latest build.

Partition offsets are fixed by `partition_usb.sh`:

| Partition | Start | Size |
|---|---|---|
| P1 BIOSBOOT | 1 MiB | 1 MiB |
| P2 RETROBOOT | 2 MiB | 512 MiB |
| P3 RETROROOT | 514 MiB | 1536 MiB |
| P4 RETROGAMES | 2050 MiB | remainder |

Extracting a partition from the image by offset:

```bash
# Read P2 (RETROBOOT) out of retrostick.img and write to the device's P2
dd if=build/retrostick.img \
   of=/dev/sdX2 \
   bs=1M \
   skip=2 \        # skip=offset_MiB
   count=512 \     # count=size_MiB
   conv=fsync
```

On macOS use `/dev/rdiskNsY` and `bs=1m` (lowercase).

### Step 2 — Sync RETROGAMES (checksum-aware)

Mount the RETROGAMES partition from the stick, then use `rsync` to sync only
files that are new or unchanged relative to the stick:

```bash
rsync \
  --checksum \        # compare by content, not timestamp
  --update \          # skip files newer on the destination
  --recursive \
  --delete-excluded \ # remove files no longer in source (e.g. delisted games)
  --exclude='saves/'  \   # never touch saves
  --exclude='states/' \   # never touch save states
  --exclude='.last_content' \
  build/staging/      \   # source: whitelisted disk images + machine configs
  /mnt/retrogames/        # destination: mounted RETROGAMES on the stick
```

#### What this means for disk images

| Scenario | Result |
|---|---|
| Disk image unchanged in repo | Checksum matches stick — skipped |
| Disk image updated in repo (new version) | Checksum differs — overwritten |
| Disk image written to in-game on stick | Checksum differs from source — `--update` keeps the stick's newer version |
| Disk image removed from whitelist | `--delete-excluded` removes it from stick |

The `--update` flag is the key: rsync skips the destination file if it is
**newer** than the source. Since in-game writes update the file's mtime on the
stick, a played-on `.d64` will be preserved. A freshly whitelisted `.d64` that
has never been touched on the stick will be copied normally.

> **Edge case:** if you update a disk image in the repo (e.g. a bug-fixed `.d64`)
> and the stick also has a modified copy, `--update` will keep the stick's version.
> Use `make flash` (full overwrite) to force-replace in that case.

---

## Makefile targets

```makefile
# Smart reflash — preserves RETROGAMES user data
smart-flash:
    @bash scripts/smart_flash.sh "$(DEVICE)"

# Full overwrite — use when you need a guaranteed clean state
flash:
    @bash scripts/flash.sh "$(DEVICE)"
```

---

## Script outline: `scripts/smart_flash.sh`

```
1. Validate: retrostick.img exists, DEVICE set or selector shown
2. Confirm: warn user this will update system partitions
3. Unmount all partitions on DEVICE (diskutil / umount)
4. Write P1 via dd (offset 1 MiB, size 1 MiB)
5. Write P2 via dd (offset 2 MiB, size 512 MiB)
6. Write P3 via dd (offset 514 MiB, size 1536 MiB)
7. Mount P4 (RETROGAMES) from DEVICE
8. rsync build/staging/ → /mnt/retrogames/
   with --checksum --update --exclude saves/ --exclude states/
9. Unmount P4
10. sync
```

`build/staging/` is already produced by `build.sh` (step 6: apply whitelists).
`smart_flash.sh` can reuse it directly — no rebuild needed if the image is
current.

---

## macOS notes

- Use `/dev/rdiskN` (raw device) for dd writes — significantly faster than
  `/dev/diskN`
- Partition devices are `/dev/rdiskNsY` (e.g. `/dev/rdisk2s3` for P3)
- `rsync` is pre-installed on macOS; the flags above are all supported
- Mount P4 with `mount -t exfat /dev/diskNs4 /tmp/retrogames`

## Linux / WSL2 notes

- Partition devices are `/dev/sdXN` (e.g. `/dev/sdb3` for P3)
- `rsync` available via `apt install rsync`
- Mount P4 with `mount -t exfat /dev/sdX4 /mnt/retrogames`
- WSL2: device must be attached via `usbipd` before running
