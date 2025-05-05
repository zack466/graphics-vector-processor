SOURCES = types.vhd ray_sphere_intersect.vhd
TESTBENCHES = ray_sphere_intersect_tb.vhd
WAVEFORM = waveform.ghw

BUILDFLAGS = --std=08
# BUILDFLAGS =
RUNFLAGS = --ieee-asserts=disable --wave=$(WAVEFORM)

all: $(basename $(TESTBENCHES))

build: $(SOURCES) $(TESTBENCHES)
	ghdl -a $(BUILDFLAGS) $(SOURCES)
	ghdl -a $(BUILDFLAGS) $(TESTBENCHES)

$(basename $(TESTBENCHES)): build $(TESTBENCHES)
	ghdl -e $(BUILDFLAGS) $@

view:
	gtkwave $(WAVEFORM)

clean:
	rm -rf *.cf

.PHONY: test clean build view
