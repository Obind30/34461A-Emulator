# 34461A-Emulator
This script is intended to run on a Keithly DMM6500 to emulate a Keysight 34461A. 
## Currently Unsupported Features
* Resolution control
    * The DMM6500 does not allow exact resolution control as the 34461A does. This could be done by reverse engineering the effects on integration time and measurement ranges. 
* Secondary functions
    * The DMM6500 secondary functions are display only. This could be emulated by quickly changing measurement functions to and from the secondary measurement.