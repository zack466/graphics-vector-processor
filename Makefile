SOURCES = types.vhd util.vhd sdram.vhd reg.vhd vector_reg.vhd ray_sphere_intersect.vhd core.vhd core_alu.vhd fpu.vhd
TESTBENCH_SOURCES = ray_sphere_intersect_tb.vhd core_alu_tb.vhd sdram_tb.vhd fpu_tb.vhd
TESTBENCHES = ray_sphere_intersect_tb core_alu_tb sdram_agent_tb sdram_host_tb FloatAddSub_tb FloatMul_tb FPU_tb
WAVEFORM = waveform.ghw

BUILDFLAGS = --std=08
RUNFLAGS = --ieee-asserts=disable --wave=$(WAVEFORM)

all: $(TESTBENCHES)

build: $(SOURCES) $(TESTBENCH_SOURCES)
	ghdl -a $(BUILDFLAGS) $(SOURCES)
	ghdl -a $(BUILDFLAGS) $(TESTBENCH_SOURCES)

$(TESTBENCHES): build
	ghdl -e $(BUILDFLAGS) $@

# Run a specific testbench by name: make test-<testbench_name>
test-%: %
	./$* $(RUNFLAGS)

# Default test target - show available testbenches
test:
	@echo "Available testbenches:"
	@for tb in $(TESTBENCHES); do echo "  make test-$$tb"; done
	@echo ""
	@echo "Or run all tests with: make test-all"

# Run all testbenches
test-all: $(TESTBENCHES)
	@for tb in $(TESTBENCHES); do \
		echo "Running $$tb..."; \
		./$$tb $(RUNFLAGS); \
	done

view:
	gtkwave $(WAVEFORM) > /dev/null 2>&1 &

clean:
	rm -rf *.cf *.o

.PHONY: test test-all test-% clean build view
