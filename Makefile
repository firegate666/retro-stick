SHELL := /bin/bash

.PHONY: help list-machines validate \
        fetch fetch-retroarch fetch-cores fetch-alpine \
        build-root build flash build-and-flash \
        qemu-bios qemu-efi \
        add-machine clean clean-cache

# ── Help ──────────────────────────────────────────────────────────────────────

help:
	@echo "RetroStick build system"
	@echo ""
	@echo "  make list-machines               List all configured machines"
	@echo "  make validate                    Check configs and host tools"
	@echo "  make fetch                       Download RetroArch, cores, and Alpine image"
	@echo "  make build-root                  Build Alpine rootfs via Docker"
	@echo "  make build                       Build retrostick.img"
	@echo "  make flash DEVICE=/dev/sdX       Write image to USB stick"
	@echo "  make build-and-flash DEVICE=..   Build then flash in one step"
	@echo "  make add-machine NAME=<name>     Scaffold a new machine from _template"
	@echo "  make qemu-bios                   Boot retrostick.img in QEMU (legacy BIOS)"
	@echo "  make qemu-efi                    Boot retrostick.img in QEMU (UEFI via EDK2)"
	@echo "  make clean                       Remove build/ artifacts"
	@echo "  make clean-cache                 Remove downloaded binaries from cache/"

# ── List machines ─────────────────────────────────────────────────────────────

list-machines:
	@echo "Configured machines:"
	@for cfg in machines/*/core.cfg; do \
		machine=$$(basename $$(dirname $$cfg)); \
		[[ "$$machine" == "_template" ]] && continue; \
		core=$$(grep '^CORE_NAME=' $$cfg | cut -d= -f2); \
		printf "  %-12s %s\n" "$$machine" "$$core"; \
	done

# ── Validate ──────────────────────────────────────────────────────────────────

validate:
	@bash scripts/validate.sh

# ── Add machine ───────────────────────────────────────────────────────────────

add-machine:
	@test -n "$(NAME)" || { echo "Usage: make add-machine NAME=<name>"; exit 1; }
	@test ! -d "machines/$(NAME)" || { echo "Error: machines/$(NAME) already exists"; exit 1; }
	@cp -r machines/_template "machines/$(NAME)"
	@sed "s/<MACHINE>/$(NAME)/g" machines/_template/machine.cfg   > "machines/$(NAME)/machine.cfg"
	@sed "s/<MACHINE>/$(NAME)/g" machines/_template/whitelist.txt > "machines/$(NAME)/whitelist.txt"
	@echo "Created machines/$(NAME)"
	@echo "Next steps:"
	@echo "  1. Edit machines/$(NAME)/core.cfg  — set CORE_NAME and CORE_URL"
	@echo "  2. Edit machines/$(NAME)/machine.cfg — set RetroArch overrides"
	@echo "  3. Run: make validate"

# ── Fetch ─────────────────────────────────────────────────────────────────────

fetch: fetch-retroarch fetch-cores fetch-alpine

fetch-retroarch:
	@bash scripts/fetch_retroarch.sh

fetch-cores:
	@bash scripts/fetch_cores.sh

fetch-alpine:
	docker pull --platform linux/amd64 alpine:latest

# ── Rootfs ────────────────────────────────────────────────────────────────────

build-root:
	@bash scripts/build_root.sh

# ── Build ─────────────────────────────────────────────────────────────────────

build:
	@bash scripts/build.sh

# ── Flash ─────────────────────────────────────────────────────────────────────

flash:
	@test -n "$(DEVICE)" || { echo "Usage: make flash DEVICE=/dev/sdX"; exit 1; }
	@bash scripts/flash.sh "$(DEVICE)"

build-and-flash:
	@test -n "$(DEVICE)" || { echo "Usage: make build-and-flash DEVICE=/dev/sdX"; exit 1; }
	@$(MAKE) build
	@$(MAKE) flash DEVICE="$(DEVICE)"

# ── QEMU boot tests ───────────────────────────────────────────────────────────
#
# These targets are intended for x86/x86_64 host machines where QEMU can use
# hardware acceleration (KVM on Linux, HVF on Intel Mac).
# On Apple Silicon the same commands work but emulation will be slow (TCG only).

QEMU        := qemu-system-x86_64
QEMU_COMMON := -m 1024 -drive file=build/retrostick.img,format=raw,if=ide \
               -boot order=c -no-reboot

# Detect KVM availability
QEMU_ACCEL  := $(shell [ -w /dev/kvm ] && echo "-accel kvm" || echo "")

# EDK2 x86_64 UEFI firmware — check common paths
OVMF        := $(firstword $(wildcard \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/ovmf/OVMF.fd \
    /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd))

qemu-bios:
	@test -f build/retrostick.img || { echo "Run 'make build' first."; exit 1; }
	$(QEMU) $(QEMU_COMMON) $(QEMU_ACCEL)

qemu-efi:
	@test -f build/retrostick.img || { echo "Run 'make build' first."; exit 1; }
	@test -n "$(OVMF)" || { echo "OVMF firmware not found. Install: apt install ovmf / brew install qemu"; exit 1; }
	@cp $(OVMF) /tmp/ovmf-vars.fd
	$(QEMU) $(QEMU_COMMON) $(QEMU_ACCEL) \
	    -drive if=pflash,format=raw,readonly=on,file=$(OVMF) \
	    -drive if=pflash,format=raw,file=/tmp/ovmf-vars.fd

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -rf build/

clean-cache:
	rm -rf cache/retroarch cache/cores cache/alpine
