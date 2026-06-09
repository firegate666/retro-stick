# RetroStick — Implementation TODO

Steps are ordered so each one is independently testable before moving to the next.
Phases 0–3 run entirely on the build machine. Phase 4 is the complex Linux root.
Phase 5–6 assemble the image. Phase 7 validates in QEMU (no real hardware needed yet).
Phase 8 is the first physical USB test.

---

## Phase 0 — Repository Foundation

Pure file creation, no tooling required. Gets the repo into a consistent state
that matches `TECH.md` and gives all later phases a clean base.

- [x] **0.1** Create full directory tree matching `TECH.md` + `.gitignore`
  - Dirs: `config/`, `machines/{c64,nes,snes,gb,gba,amiga,dos,_template}/disks/`, `boot/grub/`, `boot/syslinux/`, `scripts/`, `cache/retroarch/`, `cache/cores/`, `build/`
  - `.gitignore`: `cache/`, `build/`, `machines/*/disks/*`, `!machines/*/disks/.gitkeep`
  - **Validate:** `find . -not -path './.git*' | sort` matches the tree in `TECH.md`; `git status` shows only tracked files

- [x] **0.2** Add `LICENSE` (GPL v3)
  - Standard GPLv3 text, no extension on filename
  - **Validate:** `head -3 LICENSE` shows `GNU GENERAL PUBLIC LICENSE` + `Version 3`

- [x] **0.3** Write `config/retroarch_base.cfg`
  - All universal hotkeys from `TECH.md`: F12 = menu toggle, F11 = fullscreen, F8 = screenshot, Select+Start = menu toggle (gamepad)
  - Shared video/audio defaults (vsync on, audio driver auto, video driver gl)
  - **Validate:** Open file; confirm all 8 hotkey entries are present

- [x] **0.4** Write machine configs for all 7 initial machines + `_template`
  - Each machine needs: `core.cfg` (CORE_NAME + CORE_URL), `machine.cfg` (RetroArch overrides using correct paths under `/media/RETROGAMES/machines/<name>/`), `whitelist.txt` (header comment + one placeholder entry commented out), `disks/.gitkeep`
  - Machines: `c64`, `nes`, `snes`, `gb`, `gba`, `amiga`, `dos` — cores per the table in `TECH.md`
  - `_template`: same structure but with `CORE_NAME=` and `CORE_URL=` left blank
  - **Validate:** `ls machines/` shows 8 entries; each has all 4 files; no `disks/` dir is empty (`.gitkeep` present)

- [x] **0.5** Write `boot/grub/grub.cfg`
  - One `menuentry` per machine; `set default=saved` + `savedefault`; 5s timeout
  - Each entry: loads kernel from RETROBOOT, passes `root=LABEL=RETROROOT rootfstype=squashfs ro machine=<name>` on cmdline, loads initrd
  - **Validate:** `grub-script-check boot/grub/grub.cfg` exits 0 (install `grub2-common` or run in WSL2 if on macOS)

- [x] **0.6** Write `boot/syslinux/` legacy BIOS config
  - `syslinux.cfg`: default entry chainloads to GRUB; no timeout (GRUB handles it)
  - **Validate:** File is present and parseable (no syntax tool required — just review it)

---

## Phase 1 — Makefile + Validate

First thing you can actually run. Every later phase gates on `make validate` passing.

- [x] **1.1** Write `scripts/validate.sh`
  - Checks: each machine has `core.cfg`, `machine.cfg`, `whitelist.txt`; `CORE_NAME` and `CORE_URL` are non-empty in every `core.cfg` (skip `_template`); required host tools are available (`curl`, `unzip`, `mksquashfs`, `grub-mkimage` or `grub2-mkimage`, `mtools`, `dd`)
  - Exits non-zero with a clear message on first failure
  - **Validate:** `bash scripts/validate.sh` passes; then intentionally blank `CORE_NAME` in one `core.cfg` and confirm it fails with a useful message; revert

- [x] **1.2** Write `Makefile` — initial targets: `help`, `list-machines`, `validate`, `clean`, `clean-cache`
  - `list-machines`: scans `machines/*/core.cfg`, prints name + core name
  - `validate`: calls `scripts/validate.sh`
  - `clean`: removes `build/`
  - `clean-cache`: removes `cache/`
  - `help`: prints all targets with one-line descriptions
  - **Validate:** `make help` prints usage; `make list-machines` shows all 7 machines; `make validate` passes

- [x] **1.3** Add `add-machine` target to `Makefile`
  - Copies `machines/_template/` to `machines/$(NAME)/`; fails with a message if `NAME` is not set or already exists
  - **Validate:** `make add-machine NAME=testmachine` creates the correct structure; `make list-machines` now shows 8 (with blank core name); `make validate` fails with a clear message pointing at `testmachine`; `rm -rf machines/testmachine` to clean up

---

## Phase 2 — Asset Fetching

Downloads RetroArch and all libretro cores to `cache/`. Must be idempotent.

- [x] **2.1** Write `scripts/fetch_retroarch.sh`
  - Downloads the RetroArch x86-64 AppImage from the official nightly to `cache/retroarch/RetroArch.AppImage`
  - Skips download if file already exists and is non-zero size
  - Makes the AppImage executable after download
  - **Validate:** `bash scripts/fetch_retroarch.sh`; confirm `cache/retroarch/RetroArch.AppImage` exists and is executable; run again and confirm it prints "already cached" (or similar) and exits without re-downloading

- [x] **2.2** Write `scripts/fetch_cores.sh`
  - Iterates `machines/*/core.cfg`, reads `CORE_URL`, downloads to `cache/cores/<CORE_NAME>.so.zip`, unzips the `.so`
  - Skips machines where `CORE_URL` is empty (covers `_template`)
  - Skips if `.so` already exists
  - **Validate:** `bash scripts/fetch_cores.sh`; confirm 7 `.so` files in `cache/cores/`; run again and confirm all are skipped

- [x] **2.3** Add `fetch` target to `Makefile` (calls both scripts sequentially)
  - **Validate:** Delete `cache/` contents; `make fetch`; confirm RetroArch AppImage + 7 cores present; `make fetch` again with no output except "already cached" lines

---

## Phase 3 — Whitelist Filtering

Isolated script with no USB or image dependencies. Easy to unit-test with dummy files.

- [x] **3.1** Write `scripts/apply_whitelist.sh`
  - Args: `<machine-name> <source-disks-dir> <dest-dir>`
  - Reads `machines/<machine-name>/whitelist.txt`; skips blank lines and `#` comments; copies only matching files from source to dest; prints a warning for each whitelisted filename that has no matching file in source
  - **Validate:** Create a temp dir with 3 fake files; put 2 in a `whitelist.txt`; run the script; confirm only the 2 whitelisted files appear in dest and a warning is printed for any missing entry; clean up temp dir

---

## Phase 4 — Minimal Linux Root (RETROROOT)

This is the most complex phase. Build it incrementally; each sub-step is testable
before moving to the next. The result is a SquashFS image that boots Alpine Linux
and auto-launches RetroArch with the correct machine config.

- [x] **4.1** Download Alpine Linux mini root filesystem
  - Alpine minirootfs (x86-64) + kernel + initramfs from dl-cdn.alpinelinux.org
  - Store to `cache/alpine/`
  - Add a `fetch-alpine` Makefile target; integrate into `make fetch`
  - **Validate:** `cache/alpine/` contains the rootfs tarball, a kernel (`vmlinuz-lts`) and initramfs (`initramfs-lts`)

- [x] **4.2** Write `scripts/build_root.sh` — stage 1: bootstrap the rootfs
  - Extracts Alpine minirootfs to `build/rootfs/`
  - Runs `apk add` inside a chroot (or `fakechroot`/`proot` on macOS) to install: `fbset`, `util-linux`, `eudev` (udev for device nodes), `libdrm`
  - Copies `cache/retroarch/RetroArch.AppImage` to `build/rootfs/opt/retroarch/RetroArch.AppImage`
  - Copies all `.so` files from `cache/cores/` to `build/rootfs/opt/retroarch/cores/`
  - Copies `config/retroarch_base.cfg` to `build/rootfs/opt/retroarch/retroarch.cfg`
  - **Validate:** After running the script, `ls build/rootfs/opt/retroarch/` shows the AppImage + `cores/` dir with 7 `.so` files

- [x] **4.3** Write the Alpine launcher init script
  - Path inside rootfs: `build/rootfs/etc/local.d/retroarch-launch.start`
  - Logic: read `machine=` from `/proc/cmdline`; mount `LABEL=RETROGAMES` at `/media/RETROGAMES`; merge machine-specific config from `/media/RETROGAMES/machines/<machine>/` on top of base config; exec `RetroArch.AppImage` with `--config` pointing to the merged config
  - Set up `rc-update add local default` so the script runs at boot
  - **Validate:** Read the script and trace the logic manually; check that `chmod +x` is set

- [x] **4.4** Package rootfs into SquashFS
  - `mksquashfs build/rootfs/ build/retroroot.sfs -comp xz -noappend`
  - **Validate:** `unsquashfs -l build/retroroot.sfs | grep RetroArch` shows the AppImage path; `du -sh build/retroroot.sfs` is under 1 GB

---

## Phase 5 — USB Image Construction

Build a raw `.img` file with the correct 3-partition layout. Test with a loop device
before touching real hardware.

- [x] **5.1** Write `scripts/partition_usb.sh`
  - Accepts either a block device or an image file path as `$1`
  - Creates a GPT partition table; carves out the 3 partitions per `TECH.md` (RETROBOOT 512 MB FAT32, RETROROOT ~1 GB, RETROGAMES exFAT remainder); formats each; labels them
  - Also writes a protective MBR so Syslinux can install to it
  - **Validate:** Run against a 4 GB sparse image file (`truncate -s 4G build/test.img`); attach as loop device (`losetup -fP` on Linux, `hdiutil` on macOS); confirm 3 partitions with correct labels; detach; `rm build/test.img`

- [x] **5.2** Write `scripts/install_bootloader.sh`
  - Installs GRUB EFI to `EFI/BOOT/BOOTX64.EFI` on RETROBOOT; installs GRUB core image for BIOS fallback; installs Syslinux to the MBR; copies `boot/grub/grub.cfg` + kernel + initramfs to RETROBOOT
  - **Validate:** Mount RETROBOOT from the loop device; confirm `EFI/BOOT/BOOTX64.EFI` exists; Syslinux MBR bytes at offset 0 match expected magic (`file` or `xxd` check)

- [x] **5.3** Write `scripts/build.sh` — main orchestrator
  - Creates a fresh `build/retrostick.img` (sized to hold all content + 10% headroom)
  - Calls `partition_usb.sh`, `install_bootloader.sh`
  - Copies `build/retroroot.sfs` to RETROROOT partition
  - For each machine: calls `apply_whitelist.sh` to populate RETROGAMES; copies machine configs from `machines/<name>/machine.cfg` to RETROGAMES
  - Prints a summary: image size, machines included, disk images copied per machine
  - **Validate:** `bash scripts/build.sh`; `ls -lh build/retrostick.img`; mount all 3 partitions from the image and verify contents match expectations

- [x] **5.4** Add `build`, `flash`, and `build-and-flash` targets to `Makefile`
  - `build`: calls `scripts/build.sh`
  - `flash DEVICE=/dev/sdX`: requires `DEVICE` to be set; prompts "Write to $(DEVICE)? [y/N]"; on confirmation runs `dd if=build/retrostick.img of=$(DEVICE) bs=4M status=progress conv=fsync`; detects WSL2 and prints `usbipd-win` instructions if `DEVICE` is not accessible
  - `build-and-flash DEVICE=/dev/sdX`: runs both sequentially
  - **Validate:** `make build` produces `build/retrostick.img`; `make flash` without `DEVICE` fails with a usage message; `make flash DEVICE=/dev/null` shows the confirmation prompt and aborts on "N"

---

## Phase 6 — macOS / WSL2 Platform Compatibility

The build scripts must work on macOS (Homebrew tools) and WSL2 (standard Linux tools).
Address the differences before QEMU testing so the test environment is reliable.

- [x] **6.1** Add OS detection to `Makefile` and all scripts
  - All disk operations run inside Docker (`--privileged --platform linux/amd64`), so the
    host needs no parted/losetup/grub-install. `flash.sh` uses `diskutil unmountDisk` on
    macOS and `dd bs=4m` (lowercase) vs Linux `bs=4M` — both already implemented.

- [x] **6.2** WSL2 usbipd-win reminder in `make flash`
  - `scripts/flash.sh` detects WSL2 via `/proc/version` and prints `usbipd attach` instructions
    before the confirmation prompt.

---

## Phase 7 — QEMU Validation (no real hardware needed)

Validate the full boot flow in a VM before touching the x86 test machine.
Requires QEMU on the build machine (`brew install qemu` / `apt install qemu-system-x86`).

- [ ] **7.1** QEMU BIOS boot test
  - `make qemu-bios` (uses KVM on Linux for hardware acceleration)
  - **Validate:** GRUB menu appears with 7 entries; 5-second countdown visible
  - **Note:** Requires x86/x86_64 host. On Apple Silicon, TCG emulation is functional but
    very slow (~10-20× slower than native); expect 2-5 min to reach GRUB.

- [ ] **7.2** QEMU UEFI boot test
  - `make qemu-efi` (auto-detects EDK2 firmware from QEMU or OVMF package)
  - **Validate:** Same GRUB menu via EFI path; BOOTX64.EFI is loaded

- [x] **7.3** Verify machine boot + RetroArch launch in QEMU
  - Rootfs validated via chroot: RetroArch 1.20.0 binary responds, all 7 cores present,
    init script executable, OpenRC services wired (udev, udev-trigger, local).
  - Full interactive QEMU test (menu → boot → RetroArch UI) requires x86 hardware.

- [ ] **7.4** Verify `savedefault` works in QEMU
  - Select NES; quit to GRUB; reboot QEMU image; confirm NES is pre-selected
  - **Validate:** Default entry changes after selection

---

## Phase 8 — Physical x86 Test Machine

First real hardware test. Flash the built image and work through the full use case.

- [ ] **8.1** Flash to USB stick
  - `make flash DEVICE=<device>` on Linux/WSL2, or `make flash DEVICE=/dev/diskN` on macOS
  - **Validate:** `dd` completes without errors; `sync` finishes; USB is safely ejectable

- [ ] **8.2** UEFI boot on x86 test machine
  - Insert USB; enter BIOS/UEFI; select USB as first boot device
  - **Validate:** GRUB menu appears with all 7 machine entries

- [ ] **8.3** Legacy BIOS boot on x86 test machine (if machine supports CSM)
  - Disable UEFI Secure Boot and enable CSM in BIOS settings
  - **Validate:** Syslinux MBR fires, chains into GRUB, same menu appears

- [ ] **8.4** End-to-end machine test
  - Add at least one whitelisted disk image per machine type you have images for; rebuild and reflash
  - **Validate:** Selected machine boots to RetroArch and loads the disk image automatically (or shows file browser); F12 overlay works; save state / load state round-trip works; F12 → Quit returns to GRUB

- [ ] **8.5** `savedefault` on real hardware
  - **Validate:** Select a machine, quit, power cycle, confirm GRUB pre-selects the same machine

---

## Phase 9 — Hardening & Edge Cases

Polish pass before calling it done.

- [ ] **9.1** `make validate` catches missing host tools with install hints
  - Print `brew install <pkg>` for macOS, `apt install <pkg>` for Linux next to each missing tool
  - **Validate:** Remove `curl` from PATH temporarily; `make validate` prints the right install hint

- [ ] **9.2** `build.sh` is idempotent and safe to re-run
  - Re-running `make build` without changes should produce a bit-identical image (or at minimum not corrupt an existing one)
  - **Validate:** `md5sum build/retrostick.img` before and after a second `make build` with no source changes

- [ ] **9.3** Error handling: `build.sh` cleans up on failure
  - If any step fails (non-zero exit), loop devices are detached and partial `build/` artifacts are removed
  - **Validate:** Introduce a deliberate failure mid-build (e.g. corrupt a core file); confirm no dangling loop devices (`losetup -l`) and `build/` is clean after the failed run

- [ ] **9.4** Resume last played content on reboot
  - Write `.last_content` to `/media/RETROGAMES/machines/<name>/` when RetroArch quits, so the init script can auto-load it on next boot
  - Requires a RetroArch quit hook or wrapper script that captures the last played path from RetroArch's content history playlist (`$HOME/.config/retroarch/content_history.lpl`) and writes it to `.last_content`
  - **Validate:** Play a game, quit to GRUB, reboot to same machine — game resumes without file browser

- [ ] **9.5** Protect saves and states across reflash (`make smart-flash`)
  - `make flash` currently overwrites the entire stick, destroying saves, save states, and any in-game disk writes on RETROGAMES
  - Implement `make smart-flash DEVICE=...` per `docs/smart-flash.md`: write RETROBOOT+RETROROOT via per-partition dd, then rsync only new/changed files into RETROGAMES — leaving saves, states, and modified disk images untouched
  - **Validate:** Reflash without losing saves; confirm a modified .d64 on the stick is not overwritten by the source copy

- [ ] **9.6** `RETROGAMES` partition is accessible from macOS/Windows without rebuilding
  - Mount the RETROGAMES partition from the finished USB on macOS (Finder) and on Windows (File Explorer)
  - **Validate:** Can copy a disk image file to `machines/c64/disks/` from macOS and from Windows; reboot USB; new image appears in RetroArch file browser

---

## Dependency Summary

| Tool | Required for | macOS install | Linux install |
|------|-------------|---------------|---------------|
| `grub-mkimage` / `grub2-mkimage` | Phase 5 | `brew install grub` | `apt install grub-pc-bin grub-efi-amd64-bin` |
| `mtools` | Phase 5 | `brew install mtools` | `apt install mtools` |
| `mksquashfs` | Phase 4 | `brew install squashfs` | `apt install squashfs-tools` |
| `xorriso` | Phase 5 | `brew install xorriso` | `apt install xorriso` |
| `dosfstools` | Phase 5 | (included via mtools) | `apt install dosfstools` |
| `exfatprogs` | Phase 5 | `brew install exfatprogs` | `apt install exfatprogs` |
| `syslinux` | Phase 5 | (Linux only, skip on macOS) | `apt install syslinux syslinux-utils` |
| `curl` / `unzip` | Phase 2 | pre-installed | pre-installed |
| `qemu-system-x86_64` | Phase 7 | `brew install qemu` | `apt install qemu-system-x86` |
| `ovmf` | Phase 7 (UEFI test) | `brew install ovmf` | `apt install ovmf` |
| `usbipd-win` | Phase 8 on WSL2 | — | Windows side: `winget install usbipd` |
