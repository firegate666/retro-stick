# RetroStick — Technical Specification

## Overview

RetroStick is a build system that produces a single bootable USB stick containing multiple retro machine emulators powered by RetroArch. Inserting the stick into any x86-64 (Intel/AMD) PC and booting from USB presents a minimal system selector, after which the chosen machine launches directly into RetroArch — no desktop, no launcher UI. A universal hotkey (`F12`) opens the in-session overlay for disk image swapping, save states, and settings.

Disk images are managed per machine with a whitelist manifest, so only tested and approved images are included in the build.

---

## Repository Structure

```
retrostick/
├── TECH.md                        # This document
├── Makefile                       # Top-level build entrypoint
├── config/
│   └── retroarch_base.cfg         # Shared RetroArch base config (hotkeys, video, audio)
├── machines/
│   ├── c64/
│   │   ├── machine.cfg            # Machine-specific RetroArch overrides
│   │   ├── core.cfg               # Which libretro core to use
│   │   ├── whitelist.txt          # Approved disk images (one filename per line)
│   │   └── disks/                 # Drop .d64 / .t64 / .tap images here
│   ├── nes/
│   │   ├── machine.cfg
│   │   ├── core.cfg
│   │   ├── whitelist.txt
│   │   └── disks/                 # .nes images
│   ├── snes/
│   │   ├── machine.cfg
│   │   ├── core.cfg
│   │   ├── whitelist.txt
│   │   └── disks/                 # .sfc / .smc images
│   └── _template/                 # Copy this to add a new machine
│       ├── machine.cfg
│       ├── core.cfg
│       ├── whitelist.txt
│       └── disks/.gitkeep
├── boot/
│   ├── grub/
│   │   └── grub.cfg               # GRUB2 multiboot menu config (one entry per machine)
│   └── syslinux/                  # Legacy BIOS fallback bootloader config
├── scripts/
│   ├── build.sh                   # Main build orchestrator
│   ├── partition_usb.sh           # Partitions and formats the USB stick
│   ├── install_bootloader.sh      # Installs GRUB (EFI) + Syslinux (BIOS)
│   ├── fetch_retroarch.sh         # Downloads RetroArch AppImage for x86-64
│   ├── fetch_cores.sh             # Downloads required libretro cores
│   ├── apply_whitelist.sh         # Filters disk images through whitelist.txt
│   └── validate.sh                # Pre-build sanity checks
├── cache/                         # Downloaded binaries (gitignored)
│   ├── retroarch/
│   └── cores/
└── build/                         # Intermediate build artifacts (gitignored)
```

---

## USB Stick Layout

The stick uses three partitions:

| # | Label | Filesystem | Size | Purpose |
|---|-------|------------|------|---------|
| 1 | `RETROBOOT` | FAT32 | 512 MB | EFI + BIOS bootloaders, GRUB config, Linux kernel + initrd |
| 2 | `RETROROOT` | SquashFS (read-only) | ~1 GB | Minimal Linux root, RetroArch AppImage, libretro cores |
| 3 | `RETROGAMES` | exFAT | Remaining space | Disk images per machine, RetroArch configs, save states |

Partition 3 is exFAT so it is readable/writable from Windows and macOS without extra tools — useful for adding or managing images without rebuilding the stick.

---

## Boot Flow

```
Power on
  └─ UEFI/BIOS detects USB
       ├─ UEFI path → GRUB EFI (grub/grubx64.efi on RETROBOOT)
       └─ Legacy BIOS path → Syslinux MBR → GRUB
            └─ GRUB menu (5s timeout, last selection remembered)
                 └─ User selects machine (C64 / NES / SNES / ...)
                      └─ Kernel boots minimal Linux (Alpine-based initrd)
                           └─ Framebuffer or Xorg starts
                                └─ RetroArch launches with machine-specific config
                                     └─ Last played game autostarts (or file browser if first run)
```

GRUB remembers the last selection via `savedefault`, so repeat visits to the same friend default to the last machine used.

---

## Machine Configuration

Each machine lives in `machines/<name>/` and contains:

### `core.cfg`
```ini
# Which libretro core to load for this machine
CORE_NAME=vice_x64sc_libretro
CORE_URL=https://buildbot.libretro.com/nightly/linux/x86_64/latest/vice_x64sc_libretro.so.zip
```

### `machine.cfg`
RetroArch config overrides applied on top of `config/retroarch_base.cfg`:
```ini
# Example: c64/machine.cfg
video_shader_enable = true
video_shader = shaders/crt-easymode.glslp
input_player1_analog_dpad_mode = 0
system_directory = /media/RETROGAMES/machines/c64/system
savefile_directory = /media/RETROGAMES/machines/c64/saves
savestate_directory = /media/RETROGAMES/machines/c64/states
content_directory = /media/RETROGAMES/machines/c64/disks
```

### `whitelist.txt`
One filename per line. Only these images are copied to the USB stick during build:
```
# Lines starting with # are comments
Impossible Mission (1983).d64
Maniac Mansion (1987).d64
Last Ninja 2 (1988).d64
```

Images present in `disks/` but absent from `whitelist.txt` are ignored by the build.

---

## Universal Hotkeys

Configured once in `config/retroarch_base.cfg` and inherited by all machines:

| Action | Hotkey |
|--------|--------|
| Open overlay menu | `F12` |
| Swap disk image | `F12` → Disk Control |
| Save state | `F12` → Save State |
| Load state | `F12` → Load State |
| Reset machine | `F12` → Reset |
| Quit to machine selector | `F12` → Quit (returns to GRUB) |
| Toggle fullscreen | `F11` |
| Screenshot | `F8` |

Gamepad equivalent (for when keyboard is unavailable): `Select + Start` opens the overlay.

---

## Makefile Targets

```makefile
make list-machines      # Show all configured machines
make validate           # Check all whitelists, configs, and dependencies
make fetch              # Download RetroArch and all required cores
make build              # Build full USB image file (retrostick.img)
make flash DEVICE=/dev/sdX   # Write retrostick.img to USB stick
make build-and-flash DEVICE=/dev/sdX  # build + flash in one step
make add-machine NAME=amiga  # Scaffold a new machine from _template
make clean              # Remove build/ artifacts
make clean-cache        # Remove downloaded binaries from cache/
```

`make flash` requires `sudo` and will prompt for confirmation before writing. The `DEVICE` argument is the raw block device (e.g. `/dev/sdb` on Linux, `/dev/disk2` on macOS). Under WSL, use the WSL raw disk path.

---

## Build Environment

### Requirements

- Ubuntu Linux (native, VM, or WSL2 on Windows) or macOS
- Tools: `grub-pc-bin`, `grub-efi-amd64-bin`, `xorriso`, `mtools`, `dosfstools`, `squashfs-tools`, `curl`, `unzip`, `exfatprogs`
- ~8 GB free disk space for build artifacts

### WSL2 Notes

USB stick flashing from WSL2 requires the USB device to be attached via `usbipd-win`:
```powershell
# In Windows PowerShell (admin)
usbipd list
usbipd attach --wsl --busid <ID>
```
The Makefile will print this reminder if it detects a WSL environment.

### macOS Notes

`grub` tools are installed via Homebrew. The Makefile detects the OS and uses `diskutil` for device management and `dd` for flashing.

---

## Adding a New Machine

```bash
make add-machine NAME=amiga
```

This copies `machines/_template/` to `machines/amiga/`, then:

1. Edit `machines/amiga/core.cfg` — set the core name and download URL
2. Edit `machines/amiga/machine.cfg` — set system-specific RetroArch options
3. Drop disk images into `machines/amiga/disks/`
4. Add tested images to `machines/amiga/whitelist.txt`
5. Run `make validate` to confirm everything is in order
6. Run `make build` to produce the updated USB image

---

## Supported Machines (Initial)

| Machine | Core | Image formats |
|---------|------|--------------|
| Commodore 64 | `vice_x64sc_libretro` | `.d64` `.t64` `.tap` `.prg` |
| NES | `mesen_libretro` | `.nes` |
| SNES | `snes9x_libretro` | `.sfc` `.smc` |
| Game Boy / GBC | `gambatte_libretro` | `.gb` `.gbc` |
| Game Boy Advance | `mgba_libretro` | `.gba` |
| Amiga | `puae_libretro` | `.adf` `.hdf` `.lha` |
| DOS | `dosbox_pure_libretro` | `.zip` `.exe` |

More machines can be added without modifying the build system — just follow the `add-machine` flow above.

---

## Disk Image Workflow

1. Obtain a disk image and place it in `machines/<name>/disks/`
2. Test it locally using RetroArch on your dev machine
3. Once satisfied, add the filename to `machines/<name>/whitelist.txt` with a comment noting the date tested
4. Commit both the whitelist change and a note — the image file itself is gitignored

Disk images are gitignored by default (`.gitignore` covers `disks/*` but not `disks/.gitkeep`). The whitelist acts as the source of truth for what has been approved; the actual image files are managed outside of version control (e.g. a shared folder, external drive, or cloud storage).

---

## License

This project uses **GPL v3**.

RetroArch and the majority of libretro cores are GPL licensed, making GPL v3 the consistent and correct choice. It ensures that any derivative work — forks, improvements, adaptations — must remain open source under the same terms. This aligns with the retro preservation community's culture of open sharing.

When setting up the repository, add a `LICENSE` file (no extension — GitHub renders it automatically) containing the standard GPL v3 text from https://www.gnu.org/licenses/gpl-3.0.txt.

Note: The build system and configuration files are GPL v3. Disk images are not part of this repository and their licensing is the user's own responsibility.

---

## Out of Scope (for now)

- Network / multiplayer features
- Automatic ROM downloading (legal reasons)
- Windows-native build environment (WSL2 is the supported path on Windows)
- ARM build targets
- Standalone emulators (supported as a future escape hatch per machine via `machine.cfg` `EMULATOR_TYPE=standalone`)
