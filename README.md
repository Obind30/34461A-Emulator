# 34461A-Emulator
This script is intended to run on a Keithly DMM6500 to emulate a Keysight 34461A. 
## Loading and using 34461A Emulation
**Configuring the Emulation Script**

There are three variables that should be configured before using the emulation script:

1) gDisplayErrors is a boolean defining wether or not errors will display to the DMM6500 screen. Default: true
2) gErrorReadback is a boolean defining wether or not errors are immedeatly send to the output queue. Default: true

These variable definitions are at the very top of the script and clearly marked.

**To load the script into non-volitile memory**
1) Save 34461AEmulation.tsp to a USB drive
2) Insert the drive into the front panel of the DMM6500
3) Navigate to the script management screen
    * **Menu>Script>Manage**
4) Transfer the script from USB to Internal Script

**To start and end 34461A Emulation**
1) To load the emulation script to the runtime enviroment run:
`Emulation34461A.run()`
This command will reset the instrument to 34461A defaults and load all the necessary structures and functions for emulation. This command must be run before emulation. Until you send `EndEmulation()` you do not need to resend this.
2) To put the instrument in an emulation state send the command:
`Engine34461A()`
After sending, the DMM6500 will only accept 34461A SCPI commands.
To get the instrument out of this state send:
`SYSTem:LOCal`
3) To send a single 34461A SCPI command send:
`Execute2400("<command>")`
4) To reset the instrument back to 34461A defaults send `ResetDefaults()` or while in emulation mode send `*RST`
5) To clean up all emulation related variables and functions, send `EndEmulation()`