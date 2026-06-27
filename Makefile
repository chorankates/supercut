RUBY ?= ruby
SCRIPT := supercut.rb

# Defaults (override with: make MAP=... OUTPUT=... <target>)
MAP ?= maps/testing-smaller_mba.json
OUTPUT ?= output.mp4
CREDITS_OUTPUT ?= credits-preview.mp4
CREDITS_STYLE ?= scroll   # pages | scroll
CREDITS_TXT ?= credits.txt
LINES ?= 60
SCROLL_SPEED ?= 80
INPUT ?= input.mp4
ROTATION ?= 180

.PHONY: help compile compile-scroll credits-preview credits-preview-scroll credits-preview-pages \
	credits-preview-synth credits-preview-scroll-synth credits-preview-pages-synth credits-txt rotate

help:
	@echo "Supercut Make targets"
	@echo ""
	@echo "Variables (override via make VAR=value target):"
	@echo "  MAP=$(MAP)"
	@echo "  OUTPUT=$(OUTPUT)"
	@echo "  CREDITS_OUTPUT=$(CREDITS_OUTPUT)"
	@echo "  CREDITS_STYLE=$(CREDITS_STYLE)   # pages | scroll"
	@echo "  CREDITS_TXT=$(CREDITS_TXT)       # output path for credits-txt target"
	@echo "  LINES=$(LINES)                  # synthetic preview lines"
	@echo "  SCROLL_SPEED=$(SCROLL_SPEED)    # pixels/sec for scrolling credits"
	@echo "  INPUT=$(INPUT)                  # input file for rotate"
	@echo "  ROTATION=$(ROTATION)            # rotation angle in degrees"
	@echo ""
	@echo "Targets:"
	@echo "  make compile                # Compile full supercut with default credits style (scroll)"
	@echo "  make compile-pages         # Compile full supercut with pages credits"
	@echo "  make credits-preview        # Credits-only preview (CREDITS_STYLE pages|scroll)"
	@echo "  make credits-preview-pages  # Credits-only preview (pages)"
	@echo "  make credits-preview-scroll # Credits-only preview (scroll)"
	@echo "  make credits-preview-synth  # Credits-only preview with synthetic lines (CREDITS_STYLE)"
	@echo "  make credits-preview-scroll-synth  # Credits-only preview synthetic (scroll)"
	@echo "  make credits-preview-pages-synth   # Credits-only preview synthetic (pages)"
	@echo "  make credits-txt            # Build credits text file from MAP for debugging (output: CREDITS_TXT)"
	@echo "  make rotate                 # Rotate video INPUT by ROTATION degrees (default 180)"

compile:
	$(RUBY) $(SCRIPT) $(MAP) $(OUTPUT)

compile-pages:
	SUPERCUT_CREDITS_STYLE=pages $(RUBY) $(SCRIPT) $(MAP) $(OUTPUT)

credits-preview:
	SUPERCUT_CREDITS_PREVIEW=1 SUPERCUT_CREDITS_STYLE=$(CREDITS_STYLE) SUPERCUT_SCROLL_SPEED=$(SCROLL_SPEED) \
	$(RUBY) $(SCRIPT) $(MAP) $(CREDITS_OUTPUT)

credits-preview-scroll:
	SUPERCUT_CREDITS_PREVIEW=1 SUPERCUT_CREDITS_STYLE=scroll SUPERCUT_SCROLL_SPEED=$(SCROLL_SPEED) \
	$(RUBY) $(SCRIPT) $(MAP) $(CREDITS_OUTPUT)

credits-preview-pages:
	SUPERCUT_CREDITS_PREVIEW=1 SUPERCUT_CREDITS_STYLE=pages \
	$(RUBY) $(SCRIPT) $(MAP) $(CREDITS_OUTPUT)

credits-preview-synth:
	SUPERCUT_CREDITS_PREVIEW=1 SUPERCUT_SYNTHETIC_CREDITS=1 SUPERCUT_CREDITS_PREVIEW_LINES=$(LINES) \
	SUPERCUT_CREDITS_STYLE=$(CREDITS_STYLE) SUPERCUT_SCROLL_SPEED=$(SCROLL_SPEED) \
	$(RUBY) $(SCRIPT) $(MAP) $(CREDITS_OUTPUT)

credits-preview-scroll-synth:
	SUPERCUT_CREDITS_PREVIEW=1 SUPERCUT_SYNTHETIC_CREDITS=1 SUPERCUT_CREDITS_PREVIEW_LINES=$(LINES) \
	SUPERCUT_CREDITS_STYLE=scroll SUPERCUT_SCROLL_SPEED=$(SCROLL_SPEED) \
	$(RUBY) $(SCRIPT) $(MAP) $(CREDITS_OUTPUT)

credits-preview-pages-synth:
	SUPERCUT_CREDITS_PREVIEW=1 SUPERCUT_SYNTHETIC_CREDITS=1 SUPERCUT_CREDITS_PREVIEW_LINES=$(LINES) \
	SUPERCUT_CREDITS_STYLE=pages \
	$(RUBY) $(SCRIPT) $(MAP) $(CREDITS_OUTPUT)

credits-txt:
	SUPERCUT_CREDITS_TXT=$(CREDITS_TXT) $(RUBY) $(SCRIPT) $(MAP) /dev/null

rotate:
	ffmpeg -i $(INPUT) -vf "rotate=$(ROTATION)*PI/180" $(OUTPUT)


