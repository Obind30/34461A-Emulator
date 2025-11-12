# 34461A-Emulator
This script is intended to run on a Keithly DMM6500 to emulate a Keysight 34461A. 
## Loading and using 34461A Emulation
**To load the script into internal memory
1) Save 34461A_Emulation.tsp to a USB drive
2) Plug the drive into the front panel of the DMM6500
3) Navigate to the script management screen
    * **Menu>Script>Manage**
4) Transfer the script from USB to Internal Script

**To start and end 34461A Emulation**
1) To initialize an emulation session send the command
`34461A_Emulation.run()`
This run command will load all the nessescaray structures and functions for emulation. This command must be run before emulation, however until you send 
`EndEmulation()` you do not need to resend this.
2) To put the instrument in an emulation state run the command:
`Engine2400()`
After running, the DMM6500 will accept SCPI commands as if is is a 34461A.
To get the instrument out of this state send:
`abort`
3) To send a single 34461A SCPI command send:
`Execute2400("<command>")`

## Currently Unsupported Features
* Resolution control
    * The DMM6500 does not allow exact resolution control as the 34461A does. This could be done by reverse engineering the effects on integration time and measurement ranges. 
* Secondary functions
    * The DMM6500 secondary functions are display only. This could be emulated by quickly changing measurement functions to and from the secondary measurement.