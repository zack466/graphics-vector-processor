# Notes
- Device:
  - Intel Cyclone® V SE 5CSEBA6U23I7  device (110K LEs, 112 DSP blocks)
    - [Cyclone V Datasheets](https://www.intel.com/content/www/us/en/support/programmable/support-resources/devices/cyclone-v-support.html)
    - [Avalon MM Spec](https://www.cs.columbia.edu/~sedwards/classes/2011/4840/mnl_avalon_spec.pdf)

# Connecting to FPGA
  - running ARM Linux
    - had to resize linux partition (original USB not partitioned correctly)
    - need to allocate memory as shown [here](https://github.com/zangman/de10-nano/blob/master/docs/FPGA-SDRAM-Communication_-Avalon-MM-Host-Master-Component-Part-3.md)
    - enable sdram register by writing to memory like [this](https://github.com/zangman/de10-nano/issues/37)
  - serial:
    - connect to computer on UART port, serial tty (using PuTTY or equivalent)
  - network:
    - connect to internet using ethernet port
    - ssh in on local network

# Quartus
- hellhole

# How to load FPGA module
- [guide](https://github.com/zangman/de10-nano/blob/master/docs/Flash-FPGA-from-HPS-running-Linux.md)
- In Quartus: build to `.sof` and convert to `.rbf` file, copy over to Linux
- create device tree overlay (`.dtso` file)
- compile device tree overlay to `.dtbo` file with `dtc`
- copy `.dtbo` and `.rbf` to `/lib/firmware`
- mount the configfs to get access to the device tree
- create a new folder in the overlays folder (`/config/device-tree/overlays/<name>`)
- pass name of device tree binary into path: (`echo -n "<name>.dtbo" > /config/device-tree/overlays/<name>/path`)
- check if applied: `cat /config/device-tree/overlays/<name>/status`
- to update: `rmdir /config/device-tree/overlays/<name>`

- I need to try this: https://github.com/robseb/rsyocto
