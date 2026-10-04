# Planet Defender - MSX port

ASM      := pasmo
SRC      := src/main.asm
OUT      := build/planetdefender.rom
# PAL / 50 Hz machine (TMS9929A) — the Funvision reference is PAL, so the port
# targets 50 Hz. Override with `make run MACHINE=C-BIOS_MSX1` for a 60 Hz check.
MACHINE  := C-BIOS_MSX1_EU

.PHONY: all run headless clean check

all: $(OUT)

$(OUT): $(wildcard src/*.asm) $(wildcard assets/*.bin) | build
	$(ASM) --bin -I src $(SRC) $(OUT)
	@sz=$$(stat -c%s $(OUT)); \
	 if [ "$$sz" != "16384" ]; then echo "ERROR: $(OUT) is $$sz bytes, expected 16384"; exit 1; fi
	@echo "built $(OUT) (16384 bytes)"

build:
	@mkdir -p build

run: $(OUT)
	openmsx -machine $(MACHINE) -carta $(OUT)

# headless boot test: run ~5s of emulation, screenshot, exit
headless: $(OUT)
	openmsx -machine $(MACHINE) -carta $(OUT) \
	  -command 'after time 6 "screenshot -raw build/boot.png; exit"'
	@echo "screenshot -> build/boot.png"

check: $(OUT)
	@python3 tools/check_rom.py $(OUT)

clean:
	rm -rf build
