# =============================================================================
# load_and_run.tcl
# Loads a program into the graphics vector processor's IMEM via JTAG,
# sets uniforms, and starts frame generation.
#
# Usage (from System Console):
#   % source load_and_run.tcl
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration: adjust to match your Platform Designer address map
# -----------------------------------------------------------------------------
set BASE_ADDR      0x00000000   ;# Base of top.avs_host as seen by JTAG master

# Register offsets within the avs_host slave
set REG_CONTROL    0x000        ;# [0]=pause_req, [1]=step_req
set REG_STATUS     0x004        ;# [0]=paused, [1]=running
set REG_FRAME_W    0x008
set REG_FRAME_H    0x00C
set REG_TIME_MS    0x010
set IMEM_BASE      0x400        ;# IMEM programming window starts here

# Frame dimensions
set FRAME_W        640
set FRAME_H        480

# Program to load (hex strings; one 32-bit word per line)
set program {
0x3BDC0003
0x3FC40003
0x43C80003
0x47CC0003
0x3BDDC000
0x3BC44000
0x3BC88000
0x3BCCC000
0x3C000004
0x7D11E804
0x17CCC000
0x17D9C400
0x37D98000
0x3BD98000
0x0FC18400
0x0BD5C000
0x27D04800
0x07D55400
0x0BD54400
0x17D55000
0x07D99800
0x0BD98800
0x17D99000
0x3C000004
0x7D028004
0x0FD54000
0x0FD98000
0x07D54C00
0x07D54C00
0x3C000004
0x7D11E804
0x07D54000
0x07D98000
0x37D54000
0x37D98000
0x3BD54000
0x3BD98000
0x07E15800
0x3C000004
0x7D000004
0x17E60000
0x37E64000
0x3BE64000
0x0FE64000
0x0BE22400
0x3C000004
0x7D0C6404
0x0FE20000
0x3C000004
0x7D093004
0x07E20000
0x3C0000A4
0x7D0DFCA4
0x486A0000
0x48AA0000
0x492A0000
0x37EA8000
0xF8000006
0xFC028006
}

# -----------------------------------------------------------------------------
# Find and open the JTAG master service
# -----------------------------------------------------------------------------
set masters [get_service_paths master]
if {[llength $masters] == 0} {
    error "No JTAG master found. Is the board programmed and plugged in?"
}
if {[llength $masters] > 1} {
    puts "Warning: found [llength $masters] masters; using the first."
    puts "Available masters:"
    foreach m $masters { puts "  $m" }
}
set m [lindex $masters 0]
puts "Using master: $m"

# Claim the service (required before any read/write)
set claim [claim_service master $m load_and_run]

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
proc w32 {offset value} {
    global claim BASE_ADDR
    master_write_32 $claim [expr {$BASE_ADDR + $offset}] $value
}

proc r32 {offset} {
    global claim BASE_ADDR
    return [master_read_32 $claim [expr {$BASE_ADDR + $offset}] 1]
}

# -----------------------------------------------------------------------------
# 1. Pause the processor before loading
#    CONTROL bit[0] = pause_req (self-clearing pulse; latches into 'paused')
# -----------------------------------------------------------------------------
puts "Pausing processor..."
w32 $REG_CONTROL 0x1
after 10   ;# small delay to let the pulse propagate

set status [r32 $REG_STATUS]
puts [format "  status = 0x%08x (paused=%d)" $status [expr {$status & 0x1}]]

# -----------------------------------------------------------------------------
# 2. Reset time counter to zero
#    Writing to TIME_MS triggers the override (time_ovr_en pulse)
# -----------------------------------------------------------------------------
puts "Resetting time counter..."
w32 $REG_TIME_MS 0

# -----------------------------------------------------------------------------
# 3. Set frame dimensions
# -----------------------------------------------------------------------------
puts "Setting frame dimensions: ${FRAME_W}x${FRAME_H}"
w32 $REG_FRAME_W $FRAME_W
w32 $REG_FRAME_H $FRAME_H

# -----------------------------------------------------------------------------
# 4. Load program into IMEM
# -----------------------------------------------------------------------------
puts "Loading [llength $program] instruction(s) into IMEM..."
set i 0
foreach inst $program {
    set addr [expr {$IMEM_BASE + ($i * 4)}]
    w32 $addr $inst
    puts [format "  IMEM\[%3d\] @ 0x%03x = %s" $i $addr $inst]
    incr i
}

# -----------------------------------------------------------------------------
# 5. (Optional) Verify a couple of uniform writes by reading back
# -----------------------------------------------------------------------------
set rb_w [r32 $REG_FRAME_W]
set rb_h [r32 $REG_FRAME_H]
puts [format "Readback: frame_w=%d, frame_h=%d" [expr {$rb_w & 0xFFFF}] [expr {$rb_h & 0xFFFF}]]

# -----------------------------------------------------------------------------
# 6. Unpause — resume free-running frame generation
#    Writing 0x0 to CONTROL drops pause_req. But pause_req only *sets* paused;
#    to clear it we use the button-toggle behavior from hardware. Since the
#    JTAG side only has pause_req (assert), clearing requires either KEY[0]
#    press or a small tweak to top_level. See notes below.
# -----------------------------------------------------------------------------
puts "Ready. Press KEY\[0\] to unpause and start free-running,"
puts "or KEY\[1\] to step through frames one at a time."

# 6. Unpause and start
# puts "Unpausing..."
# w32 $REG_CONTROL 0x2   ;# bit[1] = resume
# after 10
# set status [r32 $REG_STATUS]
# puts [format "  status = 0x%08x (paused=%d)" $status [expr {$status & 0x1}]]
# puts "Running."

# Clean up
close_service master $claim
puts "Done."
