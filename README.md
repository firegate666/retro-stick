# RetroStick

A build system that produces a single bootable USB stick running multiple retro machine emulators via RetroArch. Insert the stick into any x86-64 PC, boot from USB, pick a machine, and play — no desktop, no launcher, no installation.

GRUB remembers the last machine selected, so next boot goes straight back to where you left off.

---

## Supported machines

| Machine | Core | Disk image formats |
|---|---|---|
| Commodore 64 | vice_x64sc | `.d64` `.t64` `.tap` `.prg` |
| NES | mesen | `.nes` |
| SNES | snes9x | `.sfc` `.smc` |
| Game Boy / GBC | gambatte | `.gb` `.gbc` |
| Game Boy Advance | mGBA | `.gba` |
| Amiga | PUAE | `.adf` `.hdf` `.lha` |
| DOS | DOSBox Pure | `.zip` `.exe` |

More machines can be added without modifying the build system — see [Adding a machine](#adding-a-machine).

---

## How it works

The USB stick has four partitions:

| # | Label | Filesystem | Size | Contents |
|---|---|---|---|---|
| 1 | — | BIOS Boot | 1 MB | GRUB BIOS embedding area |
| 2 | `RETROBOOT` | FAT32 | 512 MB | GRUB (UEFI + BIOS), kernel, initramfs |
| 3 | `RETROROOT` | SquashFS (read-only) | ~1.5 GB | Alpine Linux root, RetroArch, libretro cores |
| 4 | `RETROGAMES` | exFAT | Remaining space | Disk images, save states, configs per machine |

`RETROGAMES` is exFAT so you can add or remove disk images from Windows, macOS, or Linux without rebuilding.

**Boot flow:**

```
UEFI → GRUB EFI (BOOTX64.EFI)        Legacy BIOS → GRUB BIOS (embedded in P1)
                    └─ GRUB menu (5 s timeout, last selection remembered)
                         └─ Alpine Linux boots from SquashFS (read-only)
                              └─ Init mounts RETROGAMES, merges machine config
                                   └─ RetroArch launches — file browser or last game
```

---

## Prerequisites

All disk operations (partitioning, GRUB install, SquashFS) run inside Docker containers, so the host needs very little.

**Required on all platforms:**
- [Docker](https://www.docker.com/products/docker-desktop/) — used for all image build steps
- `make`, `curl` — build orchestration and asset downloads

### macOS

```bash
# Homebrew (https://brew.sh) must be installed
brew install make curl
# Docker Desktop: https://www.docker.com/products/docker-desktop/
```

### Linux (Debian / Ubuntu)

```bash
sudo apt update
sudo apt install make curl unzip docker.io
sudo usermod -aG docker $USER   # log out and back in after this
```

### Windows (WSL2)

1. Install WSL2: open PowerShell as Administrator and run:
   ```powershell
   wsl --install
   ```
2. Open the Ubuntu terminal that was installed, then follow the **Linux** steps above inside it.
3. Install Docker Desktop for Windows with the WSL2 backend enabled: https://www.docker.com/products/docker-desktop/
4. For USB flashing, install `usbipd-win` to expose the USB stick to WSL2:
   ```powershell
   winget install usbipd
   ```

---

## Full build and flash walkthrough

### 1 — Clone the repository

```bash
git clone https://github.com/your-org/retro-stick.git
cd retro-stick
```

### 2 — Validate your setup

Checks that all machine configs are present and reports any missing fields:

```bash
make validate
```

### 3 — Fetch assets

Downloads RetroArch and all libretro cores into `cache/`. Safe to re-run — already-cached files are skipped.

```bash
make fetch
```

This requires an internet connection (~500 MB total download).

### 4 — Add disk images

Place disk images for each machine in the corresponding `machines/<name>/disks/` directory, then add the filename to `machines/<name>/whitelist.txt`. Only whitelisted images are included in the build.

```
machines/c64/disks/Impossible Mission (1983).d64
machines/nes/disks/Super Mario Bros (1985).nes
```

`whitelist.txt` example:
```
# Tested and approved images
Impossible Mission (1983).d64
Maniac Mansion (1987).d64
```

Disk images are gitignored — the whitelist is the only thing committed.

### 5 — Build the image

Produces `build/retrostick.img` (~4 GB). Requires Docker running.

```bash
make build
```

### 6 — Flash to USB

#### macOS

```bash
make flash
```

A selector lists connected USB drives. Pick the number for your stick and confirm.
Or pass the device directly: `make flash DEVICE=/dev/disk2`

#### Linux

```bash
make flash
```

Same selector — pick your drive. Or: `make flash DEVICE=/dev/sdb`

#### Windows (WSL2)

First attach the USB stick to WSL2 from PowerShell (Admin):

```powershell
usbipd list
usbipd attach --wsl --busid <BUSID>
```

Then in WSL2:

```bash
make flash
# or: make flash DEVICE=/dev/sdb
```

The Makefile will print the `usbipd` instructions automatically if it detects WSL2 and no device is accessible.

### 7 — Done

Eject the USB stick and insert it into any x86-64 PC. Set USB as the first boot device in BIOS/UEFI and power on. The GRUB menu appears after ~3 seconds.

---

## Build and flash in one step

```bash
make build-and-flash DEVICE=/dev/sdX
```

---

## Adding a machine

```bash
make add-machine NAME=megadrive
```

This scaffolds `machines/megadrive/` from `_template`. Then:

1. Set `CORE_NAME` and `CORE_URL` in `machines/megadrive/core.cfg`
2. Set RetroArch overrides in `machines/megadrive/machine.cfg`
3. Drop disk images into `machines/megadrive/disks/`
4. Add tested filenames to `machines/megadrive/whitelist.txt`
5. `make validate` — confirm no errors
6. `make build` — rebuild the image

---

## Universal hotkeys

Configured in `config/retroarch_base.cfg` and shared by all machines:

| Action | Key | Gamepad |
|---|---|---|
| Open overlay menu | `F12` | `Select + Start` |
| Toggle fullscreen | `F11` | — |
| Screenshot | `F8` | — |
| Quit to GRUB menu | `F12` → Quit | — |

---

## Makefile reference

```
make list-machines               List all configured machines
make validate                    Check configs and required fields
make fetch                       Download RetroArch, cores, and Alpine
make build-root                  Build Alpine rootfs (via Docker)
make build                       Build retrostick.img
make flash                       Write image to USB (interactive drive selector)
make flash DEVICE=/dev/sdX       Write image to a specific device
make build-and-flash DEVICE=..   Build then flash in one step
make add-machine NAME=<name>     Scaffold a new machine from _template
make qemu-bios                   Boot retrostick.img in QEMU (legacy BIOS)
make qemu-efi                    Boot retrostick.img in QEMU (UEFI)
make clean                       Remove build/ artifacts
make clean-cache                 Remove downloaded binaries from cache/
```

---

## License

GPL v3 — see [LICENSE](LICENSE).

Disk images are not part of this repository. Their licensing is the user's responsibility.
