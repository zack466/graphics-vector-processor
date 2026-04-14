# ============================================================================
# run_gpu.tcl - Full System Initialization and Shader Loader
# ============================================================================
# Usage in System Console: 
#   source run_gpu.tcl
# Ensure your compiled shader is named "program.hex" in the same directory.
# ============================================================================

set hex_filename "program.hex"

# ============================================================================
# 1. Base Addresses (Verify these match your Platform Designer / Qsys map!)
# ============================================================================
set GPU_BASE       0x00000000
set VIP_CTRL_BASE  0x00010000 

# GPU Register Offsets (Byte addresses)
set REG_CTRL       [expr {$GPU_BASE + 0x00}]
set REG_STATUS     [expr {$GPU_BASE + 0x04}]
set REG_DIMENSIONS [expr {$GPU_BASE + 0x08}]
set REG_FB_0       [expr {$GPU_BASE + 0x10}]
set REG_FB_1       [expr {$GPU_BASE + 0x14}]
set IMEM_BASE [expr {$GPU_BASE + 0x2000}]

# ============================================================================
# 2. Open JTAG Master Connection
# ============================================================================
set master_paths [get_service_paths master]
if {[llength $master_paths] == 0} {
    puts "ERROR: No JTAG master found. Is the DE10-Nano plugged in and programmed?"
    return
}
set jtag_master [lindex $master_paths 0]
open_service master $jtag_master
puts "SUCCESS: Opened JTAG Master ($jtag_master)"

# ============================================================================
# 3. Halt System & Configure Resolution
# ============================================================================
puts "Configuring GPU and Framebuffers..."

# Halt GPU (Write 0 to Control)
master_write_32 $jtag_master $REG_CTRL 0x00000000

# Set Dimensions: Width 640 (0x0280), Height 480 (0x01E0) -> 0x028001E0
master_write_32 $jtag_master $REG_DIMENSIONS 0x028001E0

# Set Framebuffer Page Numbers in DDR3.
# The GPU stores fb_base_addr as the UPPER 16 bits of the DDR3 byte address.
# pixel_addr = (fb_base_addr << 16) + pixel_offset
# So the CSR holds a page number (each page = 65536 bytes).
# FB0 = page 0 → 0x00000000.  FB1 = page 32 → 0x00200000 (2MB, clears 640×480×4=1.17MB).
master_write_32 $jtag_master $REG_FB_0 0x00000000
master_write_32 $jtag_master $REG_FB_1 0x00000020

# ============================================================================
# 4. Load Shader Program (.hex) into IMEM
# ============================================================================
if {![file exists $hex_filename]} {
    puts "ERROR: Could not find $hex_filename! Please assemble your code first."
    close_service master $jtag_master
    return
}

puts "Loading instructions from $hex_filename into IMEM..."
set fp [open $hex_filename r]
set offset 0
set instr_count 0

while {[gets $fp line] >= 0} {
    set line [string trim $line]
    
    # Skip empty lines
    if {$line eq ""} { continue }
    
    # Write the 32-bit hex value to the current IMEM offset
    # Prefixing with "0x" ensures Tcl treats it as a hex literal
    master_write_32 $jtag_master [expr {$IMEM_BASE + $offset}] "0x$line"
    
    incr offset 4
    incr instr_count
}
close $fp
puts "SUCCESS: Loaded $instr_count instructions into IMEM."

# ============================================================================
# 5. Start the Altera VIP Framebuffer
# ============================================================================
puts "Starting Altera VIP Frame Reader..."
# Write 1 to Register 0 (Offset 0x00) to assert the "Go" bit
master_write_32 $jtag_master $VIP_CTRL_BASE 0x00000001

# ============================================================================
# 6. Kickoff the GPU Rendering Loop
# ============================================================================
puts "Triggering GPU Execution Loop..."

# Control Register Layout:
# Bit 0: SW Start
# Bit 1: Auto-swap on VSYNC enable
# Bit 2: IRQ enable (leaving 0)

# We write 0x03 to enable auto-swap (2) and trigger the first start (1)
master_write_32 $jtag_master $REG_CTRL 0x00000003

# Clear the start bit so we don't accidentally re-trigger it. 
# The hardware swap FSM will handle all future triggers.
master_write_32 $jtag_master $REG_CTRL 0x00000002

puts "==========================================================="
puts "SYSTEM RUNNING! Your GPU is now rendering to the HDMI port."
puts "==========================================================="

# Clean up JTAG connection
close_service master $jtag_master
