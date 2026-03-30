# Source files (Order matters: Entities/Packages must precede Architectures)
SOURCES = vector_types.vhd \
		  processor_constants_pkg.vhd \
		  fp_sim_entities.vhd fp_sim_arch.vhd \
		  vector_reg_file.vhd swizzle_network.vhd \
		  fpu_lane.vhd alu_lane.vhd instruction_issue.vhd \
		  predicate_reg_file.vhd \
		  vector_reduction_unit.vhd  \
		  instruction_memory.vhd \
		  instruction_fetch_unit.vhd \
		  writeback_controller.vhd \

# Testbench files
TESTBENCH_SOURCES = tb_fp_sim.vhd \
					tb_vector_reg_file.vhd tb_swizzle_network.vhd \
					tb_fpu_lane.vhd tb_instruction_issue.vhd \
					tb_vector_reduction_unit.vhd \
					tb_issuer_writeback_integration.vhd \
					tb_full_execution_integration.vhd \
					tb_instruction_memory.vhd \
					tb_instruction_fetch_unit.vhd

# Testbench executable names
TESTBENCHES = tb_fp_sim tb_vector_reg_file tb_swizzle_network tb_fpu_lane \
			  tb_instruction_issue tb_issuer_writeback_integration \
			  tb_vector_reduction_unit tb_full_execution_integration \
			  tb_instruction_memory tb_instruction_fetch_unit

WAVEFORM = waveform.ghw

# Directory for build files
WORKDIR = work/

# Note: VHDL-2008 flag (-std=08) is critical for float_pkg support
BUILDFLAGS = --std=08 --workdir=$(WORKDIR)
RUNFLAGS = --ieee-asserts=disable --wave=$(WAVEFORM)

# Add work directory prefix to testbench executables
TESTBENCH_EXECS = $(addprefix $(WORKDIR), $(TESTBENCHES))

all: $(TESTBENCH_EXECS)

# Create work directory if it doesn't exist
$(WORKDIR):
	mkdir -p $(WORKDIR)

build: $(WORKDIR) $(SOURCES) $(TESTBENCH_SOURCES)
	ghdl -a $(BUILDFLAGS) $(SOURCES)
	ghdl -a $(BUILDFLAGS) $(TESTBENCH_SOURCES)

$(TESTBENCH_EXECS): build
	ghdl -e $(BUILDFLAGS) -o $@ $(notdir $@)

# Run a specific testbench by name: make test-<testbench_name>
test-%: $(WORKDIR)%
	$(WORKDIR)$* $(RUNFLAGS)

# Default test target - show available testbenches
test:
	@echo "Available testbenches:"
	@for tb in $(TESTBENCHES); do echo "  make test-$$tb"; done
	@echo ""
	@echo "Or run all tests with: make test-all"

# Run all testbenches
test-all: $(TESTBENCH_EXECS)
	@for tb in $(TESTBENCHES); do \
		echo "Running $$tb..."; \
		$(WORKDIR)$$tb $(RUNFLAGS); \
	done

view:
	gtkwave $(WAVEFORM) > /dev/null 2>&1 &

clean:
	ghdl --clean --workdir=$(WORKDIR) --std=08
	rm -rf $(WORKDIR)

.PHONY: test test-all test-% clean build view
