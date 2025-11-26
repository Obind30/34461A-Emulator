--loadandrunscript Emulation34461A

--============================================================================
--
-- GLOBAL FUNCTIONS ACCESSIBLE BY USER
--
-- 1) ResetDefaults()
--      Reset DMM6500 to 34461A defaults
-- 2) Initialize34461A()
--      Reset DMM6500 to 34461A defaults and prepare for emulation
-- 3) Execute34461A
-- 4) Engine34461A
--      
--
-- MAJOR STRUCTURES TO BE AWARE OF
-- gCommandTree
-- gAccessors
-- gStateVariables
--============================================================================

--============================================================================
--
-- USER MUTABLE VARIABLES
--
-- These variables are intended to be changed by the user
--
--============================================================================

reset()

local gPLC = 60                 -- Power Line Frequency
local gDisplayErrors = true     -- Display errors to screen
local gErrorReadback = false    -- Send errors back when they occur

--============================================================================
--
-- Loading screen
--
--============================================================================

local gDisplayVariables = {}
gDisplayVariables.mDisplayScreen = display.SCREEN_HOME
display.changescreen(display.SCREEN_USER_SWIPE)

-- Loading Message
display.clear()
if localnode.model == "DMM6500" then
	display.settext(display.TEXT1, "Init 34461A mode")
    display.settext(display.TEXT2, "Please Wait...")
	delay(50e-3)
else    
    display.settext(display.TEXT1, "Model not supported")
    display.settext(display.TEXT2, "Script requires DMM6500")
    delay(2)
	display.changescreen(gDisplayVariables.mDisplayScreen)
	exit()
end

--============================================================================
--
-- Major structures and variables to be used throughout script
--
--============================================================================

local NullFunction = function () end

local gDEVMODE = true

local gInitialized = false      -- Has instrument been initialized
local gCommandTree              -- This structure will all commands including their paths and execution functions
local gErrorQueue = {}          -- This is the errorqueue structure
local gTriggerModel = {}
gTriggerModel.EndTriggerModel = NullFunction
local quesStatus    = {}
local operStatus    = {}
local standardEvent = {}

local StatusModel   = {SetCondition = NullFunction}

local gAccessors = {}               -- Setter and getter functions 
local gRemoteComm = ki.remotecomm   -- Internal command that recieves instrument communication
local gAbort = false

--[[BUFFER VARIABLES FOR MEASUREMENTS]]
-- Initialize the reading buffer as described in 34461A manual
local gReadingMemory =
{
    bufferSize = 10000,
    readingBuffer = nil,
    lastRemoved = -1,       -- Timestamp of the last buffer reading to be removed
    units = "VDC"           -- Buffer reading units
}
gReadingMemory.readingBuffer = buffer.make(gReadingMemory.bufferSize, buffer.STYLE_STANDARD)
gReadingMemory.readingBuffer.fillmode = buffer.FILL_CONTINUOUS

-- Byte representation of commonly used characters
local gCharCodes =
{
    mB              = string.byte([[B]]),
    mBracketLeft    = string.byte("["),
    mBracketRight   = string.byte("]"),
    mC              = string.byte([[C]]),
    mCaret          = string.byte([[^]]),
    mColon          = string.byte([[:]]),
    mComma          = string.byte([[,]]),
    mDoubleQuote    = string.byte([["]]),
    mDot            = string.byte([[.]]),
    mH              = string.byte([[H]]),
    mHash           = string.byte([[#]]),
    mMinus          = string.byte([[-]]),
    mNewLine        = string.byte("\n"),
    mNine           = string.byte([[9]]),
    mOne            = string.byte([[1]]),
    mParenLeft      = string.byte([[(]]),
    mParenRight     = string.byte([[)]]),
    mPlus           = string.byte([[+]]),
    mQ              = string.byte([[Q]]),
    mQuestion       = string.byte([[?]]),
    mR              = string.byte([[R]]),
    mSemicolon      = string.byte([[;]]),
    mSingleQuote    = string.byte([[']]),
    mSlash          = string.byte([[/]]),
    mStar           = string.byte([[*]]),
    mT              = string.byte([[T]]),
    mV              = string.byte([[V]]),
    mZero           = string.byte([[0]]),
}

-- Useful parser strings
local gNonProgMnemonic  = "[^%a%d_]"
local gNonWhitespace    = "[^%s]"

-- Special commands, not currently implemented
local gSpecialCommands =
{
    ["$Empty"] =
    {
        mCommand = {mPriority = true},
    },
    ["ABORT"] =
    {
        mCommand = {mPriority = true},
    },
    ["*TRG"] =
    {
        mCommand = {mPriority = true},
    },
    [gRemoteComm.types.DCL] =
    {
        mCommand = {mPriority = true},
    },
    [gRemoteComm.types.TRIGGER] =
    {
    },
    [gRemoteComm.types.SETLOCKOUT] =
    {
        mCommand = {},
    },
    [gRemoteComm.types.RESETLOCKOUT] =
    {
        mCommand = {},
    },
    -- gRemoteComm.types.GOTOLOCAL
    -- gRemoteComm.types.GOTOREMOTE
}
gSpecialCommands["$Empty"].mCommand.mExecute = NullFunction

--============================================================================
--
-- Performance enhancing variables for quick access
--
--============================================================================

local gMathAbs      = math.abs
local gTypeDcl      = gRemoteComm.types.DCL
local Print         = gRemoteComm.partialprint
local gMeasure      = dmm.measure
local gRel          = gMeasure.rel
local gTM           = trigger.model
local gTriggerTimer = trigger.timer[1]

local gNan = 9.91e37
local gInf = 9.90e37
local gEpsilon = 5e-7

local gLastMeasurement =
{
    value = gNan,
    index = 1,
    -- Make sure to update this accordingly
    units = "VDC",
}

-- Getter and setter functions increase performance
gAccessors.mSetMeasureFunction      = makesetter(gMeasure, "func")
gAccessors.mSetMeasureRange         = makesetter(gMeasure, "range")
gAccessors.mSetMeasureAutorange     = makesetter(gMeasure, "autorange")
gAccessors.mSetMeasureCount         = makesetter(gMeasure, "count")
gAccessors.mSetMeasureAutodelay     = makesetter(gMeasure, "autodelay")
gAccessors.mSetDetectorBandwidth    = makesetter(gMeasure, "detectorbandwidth")
gAccessors.mSetRelEnable            = makesetter(gRel, "enable")
gAccessors.mSetRelLevel             = makesetter(gRel, "level")
gAccessors.mSetMeasureNPLC          = makesetter(gMeasure, "nplc")
gAccessors.mSetAutozeroEnable       = makesetter(gMeasure.autozero, "enable")
gAccessors.mSetExtinSlope           = makesetter(trigger.extin, "edge")

gAccessors.mGetMeasureFunction      = makegetter(gMeasure, "func")
gAccessors.mGetMeasureRange         = makegetter(gMeasure, "range")
gAccessors.mGetMeasureAutorange     = makegetter(gMeasure, "autorange")
gAccessors.mGetMeasureCount         = makegetter(gMeasure, "count")
gAccessors.mGetMeasureAutodelay     = makegetter(gMeasure, "autodelay")
gAccessors.mGetDetectorBandwidth    = makegetter(gMeasure, "detectorbandwidth")
gAccessors.mGetRelEnable            = makegetter(gRel, "enable")
gAccessors.mGetRelLevel             = makegetter(gRel, "level")
gAccessors.mGetMeasureNPLC          = makegetter(gMeasure, "nplc")
gAccessors.mGetAutozeroEnable       = makegetter(gMeasure.autozero, "enable")
gAccessors.mGetExtinSlope           = makegetter(trigger.extin, "edge")
gAccessors.mGetTerminals            = makegetter(dmm, "terminals")

gAccessors.mSetTriggerTimerCount    = makesetter(gTriggerTimer, "count")
gAccessors.mSetTriggerTimerStimulus = makesetter(gTriggerTimer.start, "stimulus")
gAccessors.mSetTriggerTimerDelay    = makesetter(gTriggerTimer, "delay")
gAccessors.mSetTriggerTimerEnable   = makesetter(gTriggerTimer, "enable")

gAccessors.mGetStatusCondition      = makegetter(status, "condition")
gAccessors.mGetStatusStandardEvent  = makegetter(status.standard, "event")

--============================================================================
--
-- Model specific tables
--
-- These tables store model specific range related information and the state
-- variables of the emulated instrument.
--
--============================================================================

local gPrintEnable = false

local gRangeTable =
{
    DC_Voltage      = {100e-3, 1, 10, 100, 1000},
    AC_Voltage      = {100e-3, 1, 10, 100, 750},
    DC_Current      = {10e-6, 100e-6, 1e-3, 10e-3, 100e-3, 1, 3, 10},   --
    AC_Current      = {1e-3, 10e-3, 100e-3, 1, 3, 10},                  --
    Resistance      = {10, 100, 1e3, 10e3, 100e3, 1e6, 10e6, 100e6},
    FResistance     = {1, 10, 100, 1e3, 10e3, 100e3, 1e6, 10e6, 100e6},
    Continuity      = {1e3},
    Diode           = {10},
    Capacitance     = {1e-9, 10e-9, 100e-9, 1e-6, 10e-6, 100e-6, 1e-3},
}

local gOperatingBoundaries =
{
    AC_Current =
    {
        Range =
        {
            -- Min lower than 34461 but max higher, default same as 34461
            max = 10,   --
            def = 1,
            min = 1e-3
        },
        Null =
        {
            -- Max/min limited by 6500
            max = 10,   --
            def = 0,
            min = -10   --
        },
        Bandwidth =
        {
            -- These match 6500 not 34461
            max = 300,
            def = 30,
            min = 3
        },
    },
    DC_Current =
    {
        Range =
        {
            -- Range better on 6500, default same as 34461
            max = 10,   --
            def = 1,
            min = 10e-6
        },
        Null =
        {
            -- Max/min limited by 6500
            max = 10,   --
            def = 0,
            min = -10   --
        },
    },
    AC_Voltage =
    {
        Range =
        {
            -- Max limited by 6500, default same as 34461
            max = 750,
            def = 10,
            min = 100e-3
        },
        Null =
        {
            -- Max/min limited by 6500
            max = 750,
            def = 0,
            min = -750
        },
        Bandwidth =
        {
            -- These match 6500 not 34461
            max = 300,
            def = 30,
            min = 3
        },
    },
    DC_Voltage =
    {
        Range =
        {
            -- Values fully compatible, default same as 34461
            max = 1000,
            def = 1000,
            min = 100e-3
        },
        Null =
        {
            -- Max/min limited by 6500
            max = 1000,
            def = 0,
            min = -1000
        },
    },
    Resistance = {
        Range =
        {
            -- Values fully compatible, default same as 34461
            max = 100e6,
            def = 1000,
            min = 10
        },
        Null =
        {
            -- Max/min better than 34461
            max = 1e8,
            def = 0,
            min = -1e8
        },
    },
    FResistance = {
        Range =
        {
            -- Values fully compatible, default same as 34461
            max = 100e6,
            def = 1000,
            min = 1
        },
        Null =
        {
            -- Max/min better than 34461
            max = 1e8,
            def = 0,
            min = -1e8
        },
    },
    General =
    {
        Nplc =
        {
            -- NPLC handled better on 6500, defaults from 34461
            max = 12,
            def = 10,
            min = 0.0005
        },
        Sample_Count =
        {
            max = 1000000,
            def = 1,
            min = 1,
        },
        Trigger_Count =
        {
            max = 1000000,
            def = 1,
            min = 1,
        },
        Trigger_Delay =
        {
            max = 3600,
            def = 1,
            min = 0,
        },
    },
}
if gPLC == 60 then
    gOperatingBoundaries.General.Nplc = 
    {
        max = 15,
        def = 10,
        min = 0.0005
    }
end

local gInstrumentState = 
{
    Measure_Function =
    {
        value = nil,
        valueParent = nil,
        getter = gAccessors.mGetMeasureFunction,
        setter = gAccessors.mSetMeasureFunction,
    },

    General = 
    {
        Data_Event_Threshold =
        {
            value = nil,
            valueParent = nil,
            getter = nil,
            setter = nil,
        },
        Sample_Count =
        {
            value = nil,
            valueParent = nil,
            -- Sample count handled in trigger model instead
            getter = nil,
            setter = nil,
        },
        Trigger_Count = 
        {
            value = nil,
            valueParent = nil,
            getter = nil,
            setter = nil,
        },
        Trigger_Delay_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureAutodelay,
            setter = gAccessors.mSetMeasureAutodelay,
        },
        Trigger_Delay =
        {
            value = nil,
            valueParent = nil,
            -- Delay handled in trigger model
            getter = nil,
            setter = nil,
        },
        Trigger_Slope =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetExtinSlope,
            setter = gAccessors.mSetExtinSlope,
        },
        Trigger_Source =
        {
            value = nil,
            valueParent = nil,
            getter = nil,
            setter = nil,
        },
    },

    -- APPLIES TO ALL MEASUREMENT FUNCTIONS (pg. 243 manual)
    
    -- AC Input Filter          20Hz
    -- Autozero                 OFF when NPLC < 1; ON otherwise
    -- Range                    AUTO
    -- Samples per Trigger      1
    -- Trigger Count            1
    -- Trigger Delay            Automatic
    -- Trigger Source           Immediate
    -- Trigger Slope            NEGative
    -- * Math Functions           Disabled, Other parameters unchanged
    -- * Per-function Null State  Disabled

    AC_Current =
    {
        Bandwidth =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetDetectorBandwidth,
            setter = gAccessors.mSetDetectorBandwidth,
        },
        Null_State = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelEnable,
            setter = gAccessors.mSetRelEnable,
        },
        Null_Value = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelLevel,
            setter = gAccessors.mSetRelLevel,
        },
        Null_Value_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = nil,
            setter = nil,
        },
        Range =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureRange,
            setter = gAccessors.mSetMeasureRange,
        },
        Range_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureAutorange,
            setter = gAccessors.mSetMeasureAutorange,
        },
    },
    DC_Current =
    {
        Null_State = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelEnable,
            setter = gAccessors.mSetRelEnable,
        },
        Null_Value = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelLevel,
            setter = gAccessors.mSetRelLevel,
        },
        Null_Value_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = nil,
            setter = nil,
        },
        Range =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureRange,
            setter = gAccessors.mSetMeasureRange,
        },
        Range_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureAutorange,
            setter = gAccessors.mSetMeasureAutorange,
        },
        NPLC =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureNPLC,
            setter = gAccessors.mSetMeasureNPLC,
        },
        Zero_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetAutozeroEnable,
            setter = gAccessors.mSetAutozeroEnable,
        },
    },
    AC_Voltage =
    {
        Bandwidth =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetDetectorBandwidth,
            setter = gAccessors.mSetDetectorBandwidth,
        },
        Null_State = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelEnable,
            setter = gAccessors.mSetRelEnable,
        },
        Null_Value = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelLevel,
            setter = gAccessors.mSetRelLevel,
        },
        Null_Value_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = nil,
            setter = nil,
        },
        Range =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureRange,
            setter = gAccessors.mSetMeasureRange,
        },
        Range_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureAutorange,
            setter = gAccessors.mSetMeasureAutorange,
        },
    },
    DC_Voltage = 
    {
        Null_State = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelEnable,
            setter = gAccessors.mSetRelEnable,
        },
        Null_Value = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelLevel,
            setter = gAccessors.mSetRelLevel,
        },
        Null_Value_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = nil,
            setter = nil,
        },
        Range =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureRange,
            setter = gAccessors.mSetMeasureRange,
        },
        Range_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureAutorange,
            setter = gAccessors.mSetMeasureAutorange,
        },
        NPLC =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureNPLC,
            setter = gAccessors.mSetMeasureNPLC,
        },
        Zero_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetAutozeroEnable,
            setter = gAccessors.mSetAutozeroEnable,
        },
    },
    Resistance =
    {
        Null_State = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelEnable,
            setter = gAccessors.mSetRelEnable,
        },
        Null_Value = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelLevel,
            setter = gAccessors.mSetRelLevel,
        },
        Null_Value_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = nil,
            setter = nil,
        },
        Range =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureRange,
            setter = gAccessors.mSetMeasureRange,
        },
        Range_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureAutorange,
            setter = gAccessors.mSetMeasureAutorange,
        },
        NPLC =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureNPLC,
            setter = gAccessors.mSetMeasureNPLC,
        },
        Zero_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetAutozeroEnable,
            setter = gAccessors.mSetAutozeroEnable,
        },
    },
    FResistance =
    {
        Null_State = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelEnable,
            setter = gAccessors.mSetRelEnable,
        },
        Null_Value = 
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetRelLevel,
            setter = gAccessors.mSetRelLevel,
        },
        Null_Value_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = nil,
            setter = nil,
        },
        Range =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureRange,
            setter = gAccessors.mSetMeasureRange,
        },
        Range_Auto =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureAutorange,
            setter = gAccessors.mSetMeasureAutorange,
        },
        NPLC =
        {
            value = nil,
            valueParent = nil,
            getter = gAccessors.mGetMeasureNPLC,
            setter = gAccessors.mSetMeasureNPLC,
        },
    },
}
-- These attributes are shared between 2W and 4W resistance
gInstrumentState.FResistance.Null_State         = gInstrumentState.Resistance.Null_State
gInstrumentState.FResistance.Null_Value         = gInstrumentState.Resistance.Null_Value
gInstrumentState.FResistance.Null_Value_Auto    = gInstrumentState.Resistance.Null_Value_Auto
gInstrumentState.FResistance.Range_Auto         = gInstrumentState.Resistance.Range_Auto
gInstrumentState.FResistance.NPLC               = gInstrumentState.Resistance.NPLC

local gInstrumentAttributes =
{
    Meas_Functions =
    {
        DC_Voltage = 
        {
            shorthand = "VOLT",
            DMM_Enum = dmm.FUNC_DC_VOLTAGE,
            stateVariables = gInstrumentState.DC_Voltage,
            units = "VDC",
        },
        AC_Voltage = 
        {
            shorthand = "VOLT:AC",
            DMM_Enum = dmm.FUNC_AC_VOLTAGE,
            stateVariables = gInstrumentState.AC_Voltage,
            units = "VAC",
        },
        DC_Current = 
        {
            shorthand = "CURR",
            DMM_Enum = dmm.FUNC_DC_CURRENT,
            stateVariables = gInstrumentState.DC_Current,
            units = "ADC"
        },
        AC_Current = 
        {
            shorthand = "CURR:AC",
            DMM_Enum = dmm.FUNC_AC_CURRENT,
            stateVariables = gInstrumentState.AC_Current,
            units = "AAC"
        },
        Temperature = 
        {
            shorthand = "TEMP",
            DMM_Enum = dmm.FUNC_TEMPERATURE,
            stateVariables = nil,
        },
        Resistance = 
        {
            shorthand = "RES",
            DMM_Enum = dmm.FUNC_RESISTANCE,
            stateVariables = gInstrumentState.Resistance,
            units = "OHM",
        },
        FResistance = 
        {
            shorthand = "FRES",
            DMM_Enum = dmm.FUNC_4W_RESISTANCE,
            stateVariables = gInstrumentState.FResistance,
            units = "OHM",
        },
        Diode = 
        {
            shorthand = "DIOD",
            DMM_Enum = dmm.FUNC_DIODE,
            stateVariables = nil,
        },
        Capacitance = 
        {
            shorthand = "CAP",
            DMM_Enum = dmm.FUNC_CAPACITANCE,
            stateVariables = nil,
        },
        Continuity = 
        {
            shorthand = "CONT",
            DMM_Enum = dmm.FUNC_CONTINUITY,
            stateVariables = nil,
        },
        Frequency = 
        {
            shorthand = "FREQ",
            DMM_Enum = dmm.FUNC_ACV_FREQUENCY,
            stateVariables = nil,
        },
        Period = 
        {
            shorthand = "PER",
            DMM_Enum = dmm.FUNC_ACV_PERIOD,
            stateVariables = nil,
        },
        Ratio = 
        {
            shorthand = "VOLT:RAT",
            DMM_Enum = dmm.FUNC_DCV_RATIO,
            stateVariables = gInstrumentState.DC_Voltage,
        },
    },
    OnOff =
    {
        ON = 
        {
            DMM_Enum = dmm.ON,
            shorthand = 1,
        },
        OFF = 
        {
            DMM_Enum = dmm.OFF,
            shorthand = 0,
        },
    },
    Auto_Delay =
    {
        ON = 
        {
            DMM_Enum = dmm.DELAY_ON,
            shorthand = 1,
        },
        OFF = 
        {
            DMM_Enum = dmm.DELAY_OFF,
            shorthand = 0,
        }
    },
    Detector_Bandwidth =
    {
        HZ3 = 
        {
            DMM_Enum = dmm.DETECTBW_3HZ,
            shorthand = 3,
        },
        HZ30 = 
        {
            DMM_Enum = dmm.DETECTBW_30HZ,
            shorthand = 30,
        },
        HZ300 = 
        {
            DMM_Enum = dmm.DETECTBW_300HZ,
            shorthand = 300,
        },
    },
    Trigger_Slope =
    {
        Positive =
        {
            DMM_Enum = trigger.EDGE_RISING,
            shorthand = "POS",
        },
        Negative =
        {
            DMM_Enum = trigger.EDGE_FALLING,
            shorthand = "NEG",
        },
    }
}

gInstrumentState.Measure_Function.valueParent           = gInstrumentAttributes.Meas_Functions

gInstrumentState.General.Trigger_Delay_Auto.valueParent = gInstrumentAttributes.Auto_Delay
gInstrumentState.General.Trigger_Slope.valueParent      = gInstrumentAttributes.Trigger_Slope

gInstrumentState.AC_Current.Bandwidth.valueParent       = gInstrumentAttributes.Detector_Bandwidth
gInstrumentState.AC_Current.Null_State.valueParent      = gInstrumentAttributes.OnOff
gInstrumentState.AC_Current.Null_Value_Auto.valueParent = gInstrumentAttributes.OnOff
gInstrumentState.AC_Current.Range_Auto.valueParent      = gInstrumentAttributes.OnOff

gInstrumentState.DC_Current.Null_State.valueParent      = gInstrumentAttributes.OnOff
gInstrumentState.DC_Current.Null_Value_Auto.valueParent = gInstrumentAttributes.OnOff
gInstrumentState.DC_Current.Range_Auto.valueParent      = gInstrumentAttributes.OnOff
gInstrumentState.DC_Current.Zero_Auto.valueParent       = gInstrumentAttributes.OnOff

gInstrumentState.AC_Voltage.Bandwidth.valueParent       = gInstrumentAttributes.Detector_Bandwidth
gInstrumentState.AC_Voltage.Null_State.valueParent      = gInstrumentAttributes.OnOff
gInstrumentState.AC_Voltage.Null_Value_Auto.valueParent = gInstrumentAttributes.OnOff
gInstrumentState.AC_Voltage.Range_Auto.valueParent      = gInstrumentAttributes.OnOff

gInstrumentState.DC_Voltage.Null_State.valueParent      = gInstrumentAttributes.OnOff
gInstrumentState.DC_Voltage.Null_Value_Auto.valueParent = gInstrumentAttributes.OnOff
gInstrumentState.DC_Voltage.Range_Auto.valueParent      = gInstrumentAttributes.OnOff
gInstrumentState.DC_Voltage.Zero_Auto.valueParent       = gInstrumentAttributes.OnOff

gInstrumentState.Resistance.Null_State.valueParent      = gInstrumentAttributes.OnOff
gInstrumentState.Resistance.Null_Value_Auto.valueParent = gInstrumentAttributes.OnOff
gInstrumentState.Resistance.Range_Auto.valueParent      = gInstrumentAttributes.OnOff
gInstrumentState.Resistance.Zero_Auto.valueParent       = gInstrumentAttributes.OnOff

--============================================================================
--
-- Reset Functions
--
--============================================================================

------------------------------------------------------------------------------
--
--  CheckTerminals
--
--  Check if front or rear terminals are being used and adjust instrument
--  attributes accordingly.
--
------------------------------------------------------------------------------

local CheckTerminals = function()
    local lActiveTerminals = gAccessors.mGetTerminals()
    if lActiveTerminals == dmm.TERMINALS_FRONT then
        gRangeTable.DC_Current = {10e-6, 100e-6, 1e-3, 10e-3, 100e-3, 1, 3}
        gRangeTable.AC_Current = {1e-3, 10e-3, 100e-3, 1, 3}
        gOperatingBoundaries.AC_Current.Range.max = 3
        gOperatingBoundaries.DC_Current.Range.max = 3
        gOperatingBoundaries.AC_Current.Null.max = 3
        gOperatingBoundaries.DC_Current.Null.max = 3
        gOperatingBoundaries.AC_Current.Null.min = -3
        gOperatingBoundaries.DC_Current.Null.min = -3
        if gInstrumentState.AC_Current.Range.value and
        gInstrumentState.AC_Current.Range.value > gOperatingBoundaries.AC_Current.Range.max then
            gInstrumentState.AC_Current.Range.value = gOperatingBoundaries.AC_Current.Range.max
        end
        if gInstrumentState.DC_Current.Range.value and 
        gInstrumentState.DC_Current.Range.value > gOperatingBoundaries.DC_Current.Range.max then
            gInstrumentState.DC_Current.Range.value = gOperatingBoundaries.DC_Current.Range.max
        end
        if gInstrumentState.AC_Current.Null_Value.value
        and gInstrumentState.AC_Current.Null_Value.value > gOperatingBoundaries.AC_Current.Null.max then
            gInstrumentState.AC_Current.Null_Value.value = gOperatingBoundaries.AC_Current.Null.max
        end
        if gInstrumentState.DC_Current.Null_Value.value and
        gInstrumentState.DC_Current.Null_Value.value > gOperatingBoundaries.DC_Current.Null.max then
            gInstrumentState.DC_Current.Null_Value.value = gOperatingBoundaries.DC_Current.Null.max
        end
        if gInstrumentState.AC_Current.Null_Value.value and
        gInstrumentState.AC_Current.Null_Value.value < gOperatingBoundaries.AC_Current.Null.min then
            gInstrumentState.AC_Current.Null_Value.value = gOperatingBoundaries.AC_Current.Null.min
        end
        if gInstrumentState.DC_Current.Null_Value.value and
        gInstrumentState.DC_Current.Null_Value.value < gOperatingBoundaries.DC_Current.Null.min then
            gInstrumentState.DC_Current.Null_Value.value = gOperatingBoundaries.DC_Current.Null.min
        end
        if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.AC_Current then
            gAccessors.mSetRelLevel(gInstrumentState.AC_Current.Null_Value.value)
            gAccessors.mSetMeasureRange(gInstrumentState.AC_Current.Range.value)
        elseif gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.DC_Current then
            gAccessors.mSetRelLevel(gInstrumentState.DC_Current.Null_Value.value)
            gAccessors.mSetMeasureRange(gInstrumentState.DC_Current.Range.value)
        end
        return 3
    else
        gRangeTable.DC_Current = {10e-6, 100e-6, 1e-3, 10e-3, 100e-3, 1, 3, 10}
        gRangeTable.AC_Current = {1e-3, 10e-3, 100e-3, 1, 3, 10}
        gOperatingBoundaries.AC_Current.Range.max = 10
        gOperatingBoundaries.DC_Current.Range.max = 10
        gOperatingBoundaries.AC_Current.Null.max = 10
        gOperatingBoundaries.DC_Current.Null.max = 10
        gOperatingBoundaries.AC_Current.Null.min = -10
        gOperatingBoundaries.DC_Current.Null.min = -10
        return 10
    end
end

------------------------------------------------------------------------------
--
--  gResetFunctionVariables
--
--  An array containing variable reset functions for each mesurement function
--
------------------------------------------------------------------------------

local gResetFunctionVariables = {
    -- APPLY TO ALL MEASUREMENT FUNCTIONS
    ResetGeneral = function()
        gInstrumentState.General.Data_Event_Threshold.value = 1
        gInstrumentState.General.Sample_Count.value         = 1
        gInstrumentState.General.Trigger_Count.value        = 1
        gInstrumentState.General.Trigger_Delay_Auto.value   = gInstrumentAttributes.Auto_Delay.ON
        gInstrumentState.General.Trigger_Delay.value        = 1
        gInstrumentState.General.Trigger_Slope.value        = gInstrumentAttributes.Trigger_Slope.Negative
        gInstrumentState.General.Trigger_Source.value       = "IMM"
    end,
    ResetACCurrent = function()
        -- AC CURRENT VARIABLES
        gInstrumentState.AC_Current.Bandwidth.value         = gInstrumentAttributes.Detector_Bandwidth.HZ30
        gInstrumentState.AC_Current.Null_State.value        = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.AC_Current.Null_Value.value        = 0
        gInstrumentState.AC_Current.Null_Value_Auto.value   = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.AC_Current.Range.value             = 1
        gInstrumentState.AC_Current.Range_Auto.value        = gInstrumentAttributes.OnOff.ON
        CheckTerminals()
    end,
    ResetDCCurrent = function()
        -- DC CURRENT VARIABLES
        gInstrumentState.DC_Current.Null_State.value        = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.DC_Current.Null_Value.value        = 0
        gInstrumentState.DC_Current.Null_Value_Auto.value   = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.DC_Current.Range.value             = 1
        gInstrumentState.DC_Current.Range_Auto.value        = gInstrumentAttributes.OnOff.ON
        gInstrumentState.DC_Current.NPLC.value              = 10
        gInstrumentState.DC_Current.Zero_Auto.value         = gInstrumentAttributes.OnOff.ON
        CheckTerminals()
    end,
    ResetACVoltage = function()
        -- AC VOLTAGE VARIABLES
        gInstrumentState.AC_Voltage.Bandwidth.value         = gInstrumentAttributes.Detector_Bandwidth.HZ30
        gInstrumentState.AC_Voltage.Null_State.value        = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.AC_Voltage.Null_Value.value        = 0
        gInstrumentState.AC_Voltage.Null_Value_Auto.value   = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.AC_Voltage.Range.value             = 10
        gInstrumentState.AC_Voltage.Range_Auto.value        = gInstrumentAttributes.OnOff.ON
    end,
    ResetDCVoltage = function()
        -- DC VOLTAGE VARIABLES
        gInstrumentState.DC_Voltage.Null_State.value        = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.DC_Voltage.Null_Value.value        = 0
        gInstrumentState.DC_Voltage.Null_Value_Auto.value   = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.DC_Voltage.Range.value             = 1000
        gInstrumentState.DC_Voltage.Range_Auto.value        = gInstrumentAttributes.OnOff.ON
        gInstrumentState.DC_Voltage.NPLC.value              = 10
        gInstrumentState.DC_Voltage.Zero_Auto.value         = gInstrumentAttributes.OnOff.ON
    end,
    ResetResistance = function()
        -- RESISTANCE VARIABLES
        gInstrumentState.Resistance.Null_State.value        = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.Resistance.Null_Value.value        = 0
        gInstrumentState.Resistance.Null_Value_Auto.value   = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.Resistance.Range.value             = 1000
        gInstrumentState.Resistance.Range_Auto.value        = gInstrumentAttributes.OnOff.ON
        gInstrumentState.Resistance.NPLC.value              = 10
        gInstrumentState.Resistance.Zero_Auto.value         = gInstrumentAttributes.OnOff.ON
    end,
    ResetFResistance = function()
        -- FRESISTANCE VARIABLES
        gInstrumentState.FResistance.Null_State.value        = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.FResistance.Null_Value.value        = 0
        gInstrumentState.FResistance.Null_Value_Auto.value   = gInstrumentAttributes.OnOff.OFF
        gInstrumentState.FResistance.Range.value             = 1000
        gInstrumentState.FResistance.Range_Auto.value        = gInstrumentAttributes.OnOff.ON
        gInstrumentState.FResistance.NPLC.value              = 10
    end,
}

------------------------------------------------------------------------------
--
--  ResetScriptVariables
--
--  Reset all script variables to 34461A defaults
--
------------------------------------------------------------------------------

local ResetScriptVariables = function()
        gInstrumentState.Measure_Function.value = gInstrumentAttributes.Meas_Functions.DC_Voltage
        gResetFunctionVariables.ResetGeneral()
        gResetFunctionVariables.ResetDCCurrent()
        gResetFunctionVariables.ResetACCurrent()
        gResetFunctionVariables.ResetDCVoltage()
        gResetFunctionVariables.ResetACVoltage()
        gResetFunctionVariables.ResetResistance()
        gResetFunctionVariables.ResetFResistance()
end

------------------------------------------------------------------------------
--
--  gSetFunctionAttributes
--
--  An array containing functions to set the actual DMM 6500 state to 
--  34461A defaults for each function
--
------------------------------------------------------------------------------

local gSetFunctionAttributes = 
{
    SetGeneral = function()
        gAccessors.mSetMeasureAutodelay(gInstrumentState.General.Trigger_Delay_Auto.value.DMM_Enum)
        gAccessors.mSetExtinSlope(gInstrumentState.General.Trigger_Slope.value.DMM_Enum)
    end,
    SetACCurrent = function()
        gAccessors.mSetDetectorBandwidth(gInstrumentState.AC_Current.Bandwidth.value.DMM_Enum)
        gAccessors.mSetRelEnable(gInstrumentState.AC_Current.Null_State.value.DMM_Enum)
        gAccessors.mSetRelLevel(gInstrumentState.AC_Current.Null_Value.value)
        gAccessors.mSetMeasureRange(gInstrumentState.AC_Current.Range.value)
        gAccessors.mSetMeasureAutorange(gInstrumentState.AC_Current.Range_Auto.value.DMM_Enum)
    end,
    SetDCCurrent = function()
        gAccessors.mSetRelEnable(gInstrumentState.DC_Current.Null_State.value.DMM_Enum)
        gAccessors.mSetRelLevel(gInstrumentState.DC_Current.Null_Value.value)
        gAccessors.mSetMeasureRange(gInstrumentState.DC_Current.Range.value)
        gAccessors.mSetMeasureAutorange(gInstrumentState.DC_Current.Range_Auto.value.DMM_Enum)
        gAccessors.mSetMeasureNPLC(gInstrumentState.DC_Current.NPLC.value)
        gAccessors.mSetAutozeroEnable(gInstrumentState.DC_Current.Zero_Auto.value.DMM_Enum)
    end,
    SetACVoltage = function()
        gAccessors.mSetDetectorBandwidth(gInstrumentState.AC_Voltage.Bandwidth.value.DMM_Enum)
        gAccessors.mSetRelEnable(gInstrumentState.AC_Voltage.Null_State.value.DMM_Enum)
        gAccessors.mSetRelLevel(gInstrumentState.AC_Voltage.Null_Value.value)
        gAccessors.mSetMeasureRange(gInstrumentState.AC_Voltage.Range.value)
        gAccessors.mSetMeasureAutorange(gInstrumentState.AC_Voltage.Range_Auto.value.DMM_Enum)
    end,
    SetDCVoltage = function()
        gAccessors.mSetRelEnable(gInstrumentState.DC_Voltage.Null_State.value.DMM_Enum)
        gAccessors.mSetRelLevel(gInstrumentState.DC_Voltage.Null_Value.value)
        gAccessors.mSetMeasureRange(gInstrumentState.DC_Voltage.Range.value)
        gAccessors.mSetMeasureAutorange(gInstrumentState.DC_Voltage.Range_Auto.value.DMM_Enum)
        gAccessors.mSetMeasureNPLC(gInstrumentState.DC_Voltage.NPLC.value)
        gAccessors.mSetAutozeroEnable(gInstrumentState.DC_Voltage.Zero_Auto.value.DMM_Enum)
    end,
    SetResistance = function()
        gAccessors.mSetRelEnable(gInstrumentState.Resistance.Null_State.value.DMM_Enum)
        gAccessors.mSetRelLevel(gInstrumentState.Resistance.Null_Value.value)
        gAccessors.mSetMeasureRange(gInstrumentState.Resistance.Range.value)
        gAccessors.mSetMeasureAutorange(gInstrumentState.Resistance.Range_Auto.value.DMM_Enum)
        gAccessors.mSetMeasureNPLC(gInstrumentState.Resistance.NPLC.value)
        gAccessors.mSetAutozeroEnable(gInstrumentState.Resistance.Zero_Auto.value.DMM_Enum)
    end,
    SetFResistance = function()
        gAccessors.mSetRelEnable(gInstrumentState.FResistance.Null_State.value.DMM_Enum)
        gAccessors.mSetRelLevel(gInstrumentState.FResistance.Null_Value.value)
        gAccessors.mSetMeasureRange(gInstrumentState.FResistance.Range.value)
        gAccessors.mSetMeasureAutorange(gInstrumentState.FResistance.Range_Auto.value.DMM_Enum)
        gAccessors.mSetMeasureNPLC(gInstrumentState.FResistance.NPLC.value)
    end,
}

------------------------------------------------------------------------------
--
--  ResetDMMSettings
--
--  Reset the DMM 6500 state to 34461A defaults
--
------------------------------------------------------------------------------

local ResetDMMSettings = function()
    reset()
    gAccessors.mSetMeasureFunction(gInstrumentAttributes.Meas_Functions.DC_Voltage.DMM_Enum)
    gSetFunctionAttributes.SetGeneral()
    gSetFunctionAttributes.SetDCVoltage()
end

------------------------------------------------------------------------------
--
--  gReadingMemory.reset
--
--  Reset the reading buffer to default settings
--
------------------------------------------------------------------------------

gReadingMemory.reset = function()
    gReadingMemory.readingBuffer.clear()
    gReadingMemory.lastRemoved = -1
    gReadingMemory.units = gInstrumentState.Measure_Function.value.units
    StatusModel.SetCondition(operStatus, 9)
end

------------------------------------------------------------------------------
--
--  ResetDefaults
--
--  Reset the DMM 6500 and script variables to 34461A defaults
--
------------------------------------------------------------------------------

ResetDefaults = function ()
    ResetScriptVariables()
    ResetDMMSettings()
    gReadingMemory.reset()
end

ResetScriptVariables()

--============================================================================
--
--  Parsers and input managment
--
--============================================================================

local gOrigin
local gEngineMode = false
local gParserState = {}
local gCurrentRoot

--[[

    Data Structures.

    Command Table

    The main parser data structure, the command table, is a hierarchical tree
    based structure that directly reflects the command structure of the
    simulated SCPI instrument.  At each level, an element could be a
    non-terminal (path) element or a terminal command.  For terminal commands,
    there can be a command form and/or a query form.  The command might also
    take parameters.  The following generic structures are used to hold the
    command tables:

    Header Element:
        (mPath)     Header Element sub-tree (for path, when next char is a :)
                    (This member is implied. For efficiency, its members are
                    stored directly at this level. See comment below.)
        mCommand    Command element for a command (if not a path)
        mQuery      Command element for a query (if not a path)

    Command Element:
        mExecute    Execution function.
        mParameters Array of parameter elements for parameters.

    Parameter Element:
        mOptional   True if parameter is optional. False or nil if not.
        mDefault    Default value.
        mParse      Parser function.
        
    Certain mParse parser functions require additional attributes in the 
    parameter element. For example, gParserTable.ParseParameterName requres 
    mNames which lists the possible names and their values. 
    gParserTable.ParseParameterChoice requres mData to list the parameter 
    choices that can be used, a single parameter that can be a number or 
    keyword is a common use.

    For SCPI based instruments, command path strings are not case sensitive.
    We can utilize this to simplify building the command table structures.
    Instead of creating an explicit mPath member, we can simply encode all
    the sub-tree elements with upper case keys and put them directly in the
    table of the parent command element. Observe that all member names start
    with a lower case "m" and will not conflict with any child element keys.


    ParseInfo

        This structure holds a partially parsed command. The parameters have
        been extracted as raw strings but have note been checked or decoded.

        mCommandNode The command element from the command tree.
        mCommand    The mQuery or mCommand element from the command node.
        mParameters Array of parameter strings (partially parsed).
        mError      (When there is an error) The error code detected while
                    parsing the command, or a table of error codes.

    Parser State

        This structure maintains the input and parser state.

        mCurrentText        The text of the current unparsed (or partially parsed) data.
        mCurrentTextUpper   An upper case copy of mCurrentText.
        mCurrentPosition    The byte position of where the parser will resume.
        mNextMessage        The next unparsed record in the record chain.
        mLastMessage        The last record in the record chain.
        mNextCommand        A ParseInfo table for the next command to process.
        mPartialMessage     An accumulator for a sequence of partial messages.

    Each message record has the following fields:

        mType           The message type
        mMessage        The text of the message
        mNext           Reference to next record if there is one
        mCount          The count of messages received from firmware
--]]

------------------------------------------------------------------------------
--
--  AddMessage
--
--  Add a message to the Parser input queue.
--
------------------------------------------------------------------------------

local AddMessage = function (lMessage, lType, lCount)
    local lNewRecord = {mType = lType, mMessage = lMessage, mCount = lCount}
    if gParserState.mLastMessage then
        gParserState.mLastMessage.mNext = lNewRecord
    else
        gParserState.mNextMessage = lNewRecord
    end
    gParserState.mLastMessage = lNewRecord
end

------------------------------------------------------------------------------
--
--  GetNewMessage
--
--  Get a new command interface message and add it to the parser input queue.
--  The first message will decide the command interface origin to use. Once
--  a command interface is chosen, only messages from that command interface
--  will be used. All other interfaces will be ignored.
--
------------------------------------------------------------------------------

local GetNewMessage

local GetCommandMessage = function ()
    local lMessage
    local lType
    local lOrigin

    lMessage, lType, lOrigin = gRemoteComm.getmessage()
    if lOrigin == gOrigin then
        if lType == gTypeDcl then
            -- Clear all messages and commands ahead of the DCL.
            gParserState.mLastMessage = nil
            gParserState.mPartialMessage = nil
            gParserState.mCurrentText = nil
            gParserState.mNextCommand = nil
            gPrintEnable = false
        end
        AddMessage(lMessage, lType, 1)
    end
end

local GetFirstCommandMessage = function ()
    local lMessage
    local lType
    local lOrigin

    lMessage, lType, lOrigin = gRemoteComm.getmessage()
    if lMessage then
        gRemoteComm.output = lOrigin
        gOrigin = lOrigin
        AddMessage(lMessage, lType, 1)
        GetNewMessage = GetCommandMessage
    end
end

GetNewMessage = GetFirstCommandMessage

------------------------------------------------------------------------------
--
--  ParseBlockLength
--
--  This function determines the end of a block data parameter. It will
--  return the position of the last character in the block data element. If
--  there is an error, it will return the starting position.
--
------------------------------------------------------------------------------

local ParseBlockLength = function (lText, lStart)
    local lCharCode = string.byte(lText, lStart)
    local lCount

    if lCharCode == gCharCodes.mZero then
        return string.len(lText) - lStart
    else
        local lLength = 0

        -- Get length of count field
        lCount = lCharCode - gCharCodes.mZero
        if lStart + 1 + lCount > string.len(lText) then
            -- Not enough data for length field
            return lStart
        end
        for lIndex = lStart + 1, lStart + lCount do
            lCharCode = string.byte(lText, lIndex)
            if lCharCode >= gCharCodes.mZero and lCharCode <= gCharCodes.mNine then
                lLength = lLength * 10 + lCharCode - gCharCodes.mZero
            else
                -- Bad length field
                return lStart
            end
        end
        if lStart + lCount + lLength > string.len(lText) then
            -- Not enough data
            return lStart
        end
        return lStart + lCount + lLength
    end
end

------------------------------------------------------------------------------
--
--  ParseExpression
--
--  Parse a 488.2 expression. This function will extract an expression
--  parameter including the parenthesis. The character at lStart should be the
--  left parenthesis.
--
------------------------------------------------------------------------------

local ParseExpression = function (lText, lStart)
    local lLength = string.len(lText)
    local lIndex = lStart + 1
    local lIndex2
    local lNesting = 1

    while lNesting > 0 and lIndex <= lLength do
        lIndex2 = string.find(lText, "[()]", lIndex) or lLength + 1
        if lIndex2 > lLength then
            return "", lIndex2
        end
        if string.byte(lText, lIndex2) == gCharCodes.mParenLeft then
            lNesting = lNesting + 1
        else
            lNesting = lNesting - 1
        end
        lIndex = lIndex2 + 1
    end
    return string.sub(lText, lStart, lIndex2), lIndex2 + 1
end

------------------------------------------------------------------------------
--
--  ParseString
--
--  Parse a 488.2 string.  This function will extract a string parameter
--  including all nested quotes.  The character at lStart must be the
--  delimiter to use.
--
------------------------------------------------------------------------------

local ParseString = function (lText, lStart)
    local lLength = string.len(lText)
    local lQuote = string.sub(lText, lStart, lStart)
    local lPattern = "[%"..lQuote.."]"
    local lIndex = lStart + 1
    local lIndex2
    local lQuoteCode = string.byte(lQuote)

    while lIndex <= lLength do
        lIndex2 = string.find(lText, lPattern, lIndex) or lLength + 1
        if string.byte(lText, lIndex2 + 1) ~= lQuoteCode then
            break
        end
        lIndex = lIndex2 + 2
    end
    if string.byte(lText, lIndex2) ~= lQuoteCode then
        return "", lStart
    end
    return string.sub(lText, lStart, lIndex2), lIndex2 + 1
end

------------------------------------------------------------------------------
--
-- ParseNRf
--
-- Parse an NRf number. If a valid NRf number is found, this function returns
-- the index of the first character after the number. If a valid NRf number
-- not found, it returns the start index.
--
-- After parsing, the text parsed can be passed to tonumber() for conversion
-- after removing any intermediate whitespace.
--
------------------------------------------------------------------------------

local ParseNRf = function (lText, lStart)
    local lCharCode
    local lIndex = lStart
    local lIndex2
    local lIndex3

    -- Skip leading sign
    lCharCode = string.byte(lText, lIndex)
    if lCharCode == gCharCodes.mPlus or lCharCode == gCharCodes.mMinus then
        lIndex = lIndex + 1
    end

    -- Parse mantissa
    lIndex2, lIndex3 = string.find(lText, "^%d*", lIndex)
    if lIndex2 then
        -- There were leading digits. Look for optional dot and optional
        -- digits that follow.
        lIndex = lIndex3 + 1
        lCharCode = string.byte(lText, lIndex)
        if lCharCode == gCharCodes.mDot then
            lIndex = lIndex + 1
            lIndex2, lIndex3 = string.find(lText, "^%d*", lIndex)
            if lIndex2 then
                lIndex = lIndex3 + 1
            end
        end
    else
        -- There were no leading digits. We must now see a dot and one or
        -- more digits.
        lIndex2, lIndex3 = string.find(lText, "^[.]%d+", lIndex)
        if lIndex2 then
            lIndex = lIndex3 + 1
        else
            -- Not a valid number
            return lStart
        end
    end

    -- Parse exponent
    lIndex2, lIndex3 = string.find(lText, "^%s*[Ee]", lIndex)
    if lIndex2 then
        -- There is an exponent
        lIndex = lIndex3 + 1
        lIndex2, lIndex3 = string.find(lText, "^%s*[+-]?%d+", lIndex)
        if lIndex2 then
            lIndex = lIndex3 + 1
        else
            -- Invalid exponent
            return lStart
        end
    end

    -- A valid number was found
    return lIndex
end

--============================================================================
--
-- Parser Tables
--
--============================================================================

local gParserTable = {}

------------------------------------------------------------------------------
--
-- ParseParameterAny
--
-- Accept an exact copy of the parameter. This parser function is intended
-- to be used as a place holder until a real parser function can be
-- implemented for the parameter.
--
------------------------------------------------------------------------------

gParserTable.ParseParameterAny = function (lParameter)
    return lParameter
end

------------------------------------------------------------------------------
--
--  ParseParameterBlockData
--
--  Parse a 488.2 block data string.
--
------------------------------------------------------------------------------

gParserTable.ParseParameterBlockData = function (lParameter)
    local lCharCode = string.byte(lParameter)

    if lCharCode == gCharCodes.mHash then
        lCharCode = string.byte(lParameter, 2)
        return string.sub(lParameter, 3 + lCharCode - gCharCodes.mZero)
    else
        return nil, -104
    end
end

------------------------------------------------------------------------------
--
-- ParseParameterBoolean
--
------------------------------------------------------------------------------

gParserTable.ParseParameterBoolean = function (lParameter)
    local lIndex
    local lLength

    lLength = string.len(lParameter)
    lIndex = ParseNRf(lParameter, 1)

    if lIndex > 1 then
        -- This is a numeric value
        local lValue, lIndex2

        lValue, lIndex2 = string.find(lParameter, "^%s*$", lIndex)
        if lIndex2 ~= lLength then
            return nil, -120
        end
        lParameter = string.gsub(lParameter, " ", "")
        lValue = tonumber(lParameter)
        if lValue >= 0.5 or lValue < -0.5 then
            return true
        end
        return false
    end
    if lParameter == "ON" then
        return true
    elseif lParameter == "OFF" then
        return false
    end
    return nil, -224
end

------------------------------------------------------------------------------
--
-- ParseParameterChoice
--
------------------------------------------------------------------------------

gParserTable.ParseParameterChoice = function (lParameter, lParseData)
    local lValue, lError
    local lIndex

    lParseData = lParseData.mData
    lIndex = 1
    while lParseData[lIndex] do
        lValue, lError = lParseData[lIndex].mParse(lParameter, lParseData[lIndex])
        -- if lError then
        --     return nil, lError
        -- end
        if lValue ~= nil then
            return lValue
        end
        lIndex = lIndex + 1
    end
    return nil, -224
end

------------------------------------------------------------------------------
--
-- ParseParameterExpression
--
------------------------------------------------------------------------------

gParserTable.ParseParameterExpression = function (lParameter)
    if string.byte(lParameter, 1) ~= gCharCodes.mParenLeft then
        return nil, -104
    end
    return lParameter
end

------------------------------------------------------------------------------
--
-- ParseParameterName
--
------------------------------------------------------------------------------

gParserTable.ParseParameterName = function (lParameter, lParseData)
    local lParameterKey = lParseData.mNames[lParameter]

    if lParameterKey then
        return lParameterKey
    else
        local lCharCode = string.byte(lParameter, 1)
        if lCharCode >= gCharCodes.mZero and lCharCode <= gCharCodes.mNine then
            -- If Parameter is wrong type, only accounting for number, others should eventually be accounted for (expression etc.)
            return nil, -108
        else
            return nil, -224
        end
    end
end

------------------------------------------------------------------------------
--
-- ParseParameterNameString
--
------------------------------------------------------------------------------

gParserTable.ParseParameterNameString = function (lParameter, lParseData)
    local lError

    lParameter, lError = gParserTable.ParseParameterString(lParameter)
    if lParameter then
        lParameter = lParseData.mNames[string.upper(lParameter)]

        if lParameter then
            return lParameter
        else
            return nil, -150
        end
    else
        return nil, lError
    end
end

------------------------------------------------------------------------------
--
-- ParseParameterNDN
--
-- This parser will accept an NDN or an NRf. If the number is NRf, it will
-- be converted to an integer.
--
------------------------------------------------------------------------------

gParserTable.ParseParameterNDN = function (lParameter)
    local lCharCode

    lCharCode = string.byte(lParameter, 1)
    if lCharCode == gCharCodes.mHash then
        lCharCode = string.byte(lParameter, 2)
        lParameter = string.sub(lParameter, 3)
        if lCharCode == gCharCodes.mH then
            return tonumber(lParameter, 16) or 0
        elseif lCharCode == gCharCodes.mQ then
            return tonumber(lParameter, 8) or 0
        elseif lCharCode == gCharCodes.mB then
            return tonumber(lParameter, 2) or 0
        else
            return nil, -104
        end
    end
    return gParserTable.ParseParameterIntegerNRf(lParameter)
end

------------------------------------------------------------------------------
--
-- ParseParameterNRf
--
-- This parser will accept an NRf number. This does not include INF. If the
-- parameter is accepted, it is converted to a number.
--
------------------------------------------------------------------------------

gParserTable.ParseParameterNRf = function (lParameter)
    local lIndex = ParseNRf(lParameter, 1)
    if lIndex > string.len(lParameter) then
        lParameter = string.gsub(lParameter, " ", "")
        return tonumber(lParameter)
    end
    if lIndex > 1 then
        return nil, -102
    else
        return nil, -104
    end
end

------------------------------------------------------------------------------
--
-- ParseParameterIntegerNRf
--
-- This parser will accept an NRf number and convert it to an integer.
--
------------------------------------------------------------------------------

gParserTable.ParseParameterIntegerNRf = function (lParameter)
    local lValue, lError

    lValue, lError = gParserTable.ParseParameterNRf(lParameter)
    if lValue then
        if lValue < 0 then
            lValue = math.ceil(lValue - 0.5)
        else
            lValue = math.floor(lValue + 0.5)
        end
    end
    return lValue, lError
end

------------------------------------------------------------------------------
--
-- ParseParameterNumList
--
------------------------------------------------------------------------------

gParserTable.ParseParameterNumList = function (lParameter)
    local lList = {}
    local lCount
    local lCharCode
    local lLength = string.len(lParameter) - 1
    local lIndex
    local lIndex2
    local lIndex3
    local lText
    local lError

    lCharCode = string.byte(lParameter, 1)
    if lCharCode ~= gCharCodes.mParenLeft then
        return nil, -104
    end
    -- We don't need to verify the last parenthesis because the expression
    -- parser will guarantee they are matched and there is nothing after the
    -- last one.

    -- Break the list into raw text pairs
    lCount = 0
    lIndex2, lIndex3 = string.find(lParameter, "^ *", 2)
    lIndex = lIndex3 + 1
    while lIndex < lLength do
        lIndex2, lIndex3 = string.find(lParameter, " *, *", lIndex)
        if not lIndex2 then
            lIndex2 = string.find(lParameter, " *[)]$", lIndex)
            lIndex3 = lLength
        end
        if lIndex2 == lIndex then
            -- Empty entry
            return nil, -121
        end
        lText = string.sub(lParameter, lIndex, lIndex2 - 1)
        lIndex = lIndex3 + 1

        lIndex2 = string.find(lText, ":", 1)
        lCount = lCount + 2
        if lIndex2 then
            lList[lCount - 1] = string.sub(lText, 1, lIndex2 - 1)
            lList[lCount] = string.sub(lText, lIndex2 + 1)
        else
            lList[lCount - 1] = lText
            lList[lCount] = lText
        end
    end

    lIndex = 1
    while lIndex <= lCount do
        lList[lIndex], lError = gParserTable.ParseParameterIntegerNRf(lList[lIndex])
        if lError then
            return nil, -260
        end
        lIndex = lIndex + 1
    end

    return lList
end

------------------------------------------------------------------------------
--
-- ParseParameterString
--
------------------------------------------------------------------------------

gParserTable.ParseParameterString = function (lParameter)
    local lCharCode

    lCharCode = string.byte(lParameter, 1)
    if lCharCode == gCharCodes.mSingleQuote then
        lParameter = string.gsub(string.sub(lParameter, 2, -2), [['']], [[']])
    elseif lCharCode == gCharCodes.mDoubleQuote then
        lParameter = string.gsub(string.sub(lParameter, 2, -2), [[""]], [["]])
    else
        return nil, -104
    end
    return lParameter
end

------------------------------------------------------------------------------
--
-- Reusable parameter tables
--
------------------------------------------------------------------------------

gParserTable.mParseAny          = {mParse = gParserTable.ParseParameterAny, mOptional = true}
gParserTable.mParseNRf          = {mParse = gParserTable.ParseParameterNRf}
gParserTable.mParseNRfOptional  = {mParse = gParserTable.ParseParameterNRf, mOptional = true}
gParserTable.mParseBooleanKeywords = {mParse = gParserTable.ParseParameterBoolean}
gParserTable.mParseInteger      = {mParse = gParserTable.ParseParameterIntegerNRf}

gParserTable.mParseDCVoltageRangeKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.DC_Voltage.Range.min,
        ["MINIMUM"]     = gOperatingBoundaries.DC_Voltage.Range.min,
        ["MAX"]         = gOperatingBoundaries.DC_Voltage.Range.max,
        ["MAXIMUM"]     = gOperatingBoundaries.DC_Voltage.Range.max,
        ["DEF"]         = gOperatingBoundaries.DC_Voltage.Range.def,
        ["DEFAULT"]     = gOperatingBoundaries.DC_Voltage.Range.def,
    }
}
gParserTable.mParseDCVoltageRange =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseDCVoltageRangeKeywords,
    }
}
gParserTable.mParseAutoOnceKeywords = 
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        {
            mParse = gParserTable.ParseParameterName,
            mOptional = true,
            mNames = {["ONCE"] = "ONCE"}
        },
        gParserTable.mParseBooleanKeywords,
    }
}
gParserTable.mParseACVoltageRangeKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.AC_Voltage.Range.min,
        ["MINIMUM"]     = gOperatingBoundaries.AC_Voltage.Range.min,
        ["MAX"]         = gOperatingBoundaries.AC_Voltage.Range.max,
        ["MAXIMUM"]     = gOperatingBoundaries.AC_Voltage.Range.max,
        ["DEF"]         = gOperatingBoundaries.AC_Voltage.Range.def,
        ["DEFAULT"]     = gOperatingBoundaries.AC_Voltage.Range.def,
    }
}
gParserTable.mParseACVoltageRange =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseACVoltageRangeKeywords,
    }
}
gParserTable.mParseDCVNullValueKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.DC_Voltage.Null.min,
        ["MINIMUM"]     = gOperatingBoundaries.DC_Voltage.Null.min,
        ["MAX"]         = gOperatingBoundaries.DC_Voltage.Null.max,
        ["MAXIMUM"]     = gOperatingBoundaries.DC_Voltage.Null.max,
        ["DEF"]         = gOperatingBoundaries.DC_Voltage.Null.def,
        ["DEFAULT"]     = gOperatingBoundaries.DC_Voltage.Null.def,
    }
}
gParserTable.mParseDCVNullValue =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseDCVNullValueKeywords,
    }
}
gParserTable.mParseACVNullValueKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.AC_Voltage.Null.min,
        ["MINIMUM"]     = gOperatingBoundaries.AC_Voltage.Null.min,
        ["MAX"]         = gOperatingBoundaries.AC_Voltage.Null.max,
        ["MAXIMUM"]     = gOperatingBoundaries.AC_Voltage.Null.max,
        ["DEF"]         = gOperatingBoundaries.AC_Voltage.Null.def,
        ["DEFAULT"]     = gOperatingBoundaries.AC_Voltage.Null.def,
    }
}
gParserTable.mParseACVNullValue =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseACVNullValueKeywords,
    }
}
gParserTable.mParseNPLCKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.General.Nplc.min,
        ["MINIMUM"]     = gOperatingBoundaries.General.Nplc.min,
        ["MAX"]         = gOperatingBoundaries.General.Nplc.max,
        ["MAXIMUM"]     = gOperatingBoundaries.General.Nplc.max,
        ["DEF"]         = gOperatingBoundaries.General.Nplc.def,
        ["DEFAULT"]     = gOperatingBoundaries.General.Nplc.def,
    }
}
gParserTable.mParseNPLC =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseNPLCKeywords,
    }
}
gParserTable.mParseACVBandwidthKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.AC_Voltage.Bandwidth.min,
        ["MINIMUM"]     = gOperatingBoundaries.AC_Voltage.Bandwidth.min,
        ["MAX"]         = gOperatingBoundaries.AC_Voltage.Bandwidth.max,
        ["MAXIMUM"]     = gOperatingBoundaries.AC_Voltage.Bandwidth.max,
        ["DEF"]         = gOperatingBoundaries.AC_Voltage.Bandwidth.def,
        ["DEFAULT"]     = gOperatingBoundaries.AC_Voltage.Bandwidth.def,
    }
}
gParserTable.mParseACVBandwidth =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseACVBandwidthKeywords
    }
}
gParserTable.mParseSampleCountKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.General.Sample_Count.min,
        ["MINIMUM"]     = gOperatingBoundaries.General.Sample_Count.min,
        ["MAX"]         = gOperatingBoundaries.General.Sample_Count.max,
        ["MAXIMUM"]     = gOperatingBoundaries.General.Sample_Count.max,
        ["DEF"]         = gOperatingBoundaries.General.Sample_Count.def,
        ["DEFAULT"]     = gOperatingBoundaries.General.Sample_Count.def,
    }
}
gParserTable.mParseSampleCount =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseInteger,
        gParserTable.mParseSampleCountKeywords
    }
}
gParserTable.mParseTriggerDelayKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.General.Trigger_Delay.min,
        ["MINIMUM"]     = gOperatingBoundaries.General.Trigger_Delay.min,
        ["MAX"]         = gOperatingBoundaries.General.Trigger_Delay.max,
        ["MAXIMUM"]     = gOperatingBoundaries.General.Trigger_Delay.max,
        ["DEF"]         = gOperatingBoundaries.General.Trigger_Delay.def,
        ["DEFAULT"]     = gOperatingBoundaries.General.Trigger_Delay.def,
    }
}
gParserTable.mParseTriggerDelay =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseTriggerDelayKeywords
    }
}
gParserTable.mParseTriggerCountKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.General.Trigger_Count.min,
        ["MINIMUM"]     = gOperatingBoundaries.General.Trigger_Count.min,
        ["MAX"]         = gOperatingBoundaries.General.Trigger_Count.max,
        ["MAXIMUM"]     = gOperatingBoundaries.General.Trigger_Count.max,
        ["DEF"]         = gOperatingBoundaries.General.Trigger_Count.def,
        ["DEFAULT"]     = gOperatingBoundaries.General.Trigger_Count.def,
        ["INF"]         = gInf,
        ["INFINITY"]    = gInf,
    }
}
gParserTable.mParseTriggerCount =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseTriggerCountKeywords
    }
}
gParserTable.mParseResNullValueKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.Resistance.Null.min,
        ["MINIMUM"]     = gOperatingBoundaries.Resistance.Null.min,
        ["MAX"]         = gOperatingBoundaries.Resistance.Null.max,
        ["MAXIMUM"]     = gOperatingBoundaries.Resistance.Null.max,
        ["DEF"]         = gOperatingBoundaries.Resistance.Null.def,
        ["DEFAULT"]     = gOperatingBoundaries.Resistance.Null.def,
    }
}
gParserTable.mParseResNullValue =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseResNullValueKeywords,
    }
}
gParserTable.mParseResRangeKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.Resistance.Range.min,
        ["MINIMUM"]     = gOperatingBoundaries.Resistance.Range.min,
        ["MAX"]         = gOperatingBoundaries.Resistance.Range.max,
        ["MAXIMUM"]     = gOperatingBoundaries.Resistance.Range.max,
        ["DEF"]         = gOperatingBoundaries.Resistance.Range.def,
        ["DEFAULT"]     = gOperatingBoundaries.Resistance.Range.def,
    }
}
gParserTable.mParseResRange =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseResRangeKeywords,
    }
}
gParserTable.mParseFResRangeKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.FResistance.Range.min,
        ["MINIMUM"]     = gOperatingBoundaries.FResistance.Range.min,
        ["MAX"]         = gOperatingBoundaries.FResistance.Range.max,
        ["MAXIMUM"]     = gOperatingBoundaries.FResistance.Range.max,
        ["DEF"]         = gOperatingBoundaries.FResistance.Range.def,
        ["DEFAULT"]     = gOperatingBoundaries.FResistance.Range.def,
    }
}
gParserTable.mParseFResRange =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseFResRangeKeywords,
    }
}
gParserTable.mParseDCCNullValueKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.DC_Current.Null.min,
        ["MINIMUM"]     = gOperatingBoundaries.DC_Current.Null.min,
        ["MAX"]         = gOperatingBoundaries.DC_Current.Null.max,
        ["MAXIMUM"]     = gOperatingBoundaries.DC_Current.Null.max,
        ["DEF"]         = gOperatingBoundaries.DC_Current.Null.def,
        ["DEFAULT"]     = gOperatingBoundaries.DC_Current.Null.def,
    }
}
gParserTable.mParseDCCNullValue =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseDCCNullValueKeywords,
    }
}
gParserTable.mParseDCCRangeKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.DC_Current.Range.min,
        ["MINIMUM"]     = gOperatingBoundaries.DC_Current.Range.min,
        ["MAX"]         = gOperatingBoundaries.DC_Current.Range.max,
        ["MAXIMUM"]     = gOperatingBoundaries.DC_Current.Range.max,
        ["DEF"]         = gOperatingBoundaries.DC_Current.Range.def,
        ["DEFAULT"]     = gOperatingBoundaries.DC_Current.Range.def,
    }
}
gParserTable.mParseDCCRange =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseDCCRangeKeywords,
    }
}
gParserTable.mParseACCNullValueKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.AC_Current.Null.min,
        ["MINIMUM"]     = gOperatingBoundaries.AC_Current.Null.min,
        ["MAX"]         = gOperatingBoundaries.AC_Current.Null.max,
        ["MAXIMUM"]     = gOperatingBoundaries.AC_Current.Null.max,
        ["DEF"]         = gOperatingBoundaries.AC_Current.Null.def,
        ["DEFAULT"]     = gOperatingBoundaries.AC_Current.Null.def,
    }
}
gParserTable.mParseACCNullValue =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseACCNullValueKeywords,
    }
}
gParserTable.mParseACCRangeKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.AC_Current.Range.min,
        ["MINIMUM"]     = gOperatingBoundaries.AC_Current.Range.min,
        ["MAX"]         = gOperatingBoundaries.AC_Current.Range.max,
        ["MAXIMUM"]     = gOperatingBoundaries.AC_Current.Range.max,
        ["DEF"]         = gOperatingBoundaries.AC_Current.Range.def,
        ["DEFAULT"]     = gOperatingBoundaries.AC_Current.Range.def,
    }
}
gParserTable.mParseACCRange =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseACCRangeKeywords,
    }
}
gParserTable.mParseACCBandwidthKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mOptional = true,
    mNames =
    {
        ["MIN"]         = gOperatingBoundaries.AC_Current.Bandwidth.min,
        ["MINIMUM"]     = gOperatingBoundaries.AC_Current.Bandwidth.min,
        ["MAX"]         = gOperatingBoundaries.AC_Current.Bandwidth.max,
        ["MAXIMUM"]     = gOperatingBoundaries.AC_Current.Bandwidth.max,
        ["DEF"]         = gOperatingBoundaries.AC_Current.Bandwidth.def,
        ["DEFAULT"]     = gOperatingBoundaries.AC_Current.Bandwidth.def,
    }
}
gParserTable.mParseACCBandwidth =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseACCBandwidthKeywords
    }
}

------------------------------------------------------------------------------
--
--  Parse4882
--
--  Parse a 488.2 command.  This function will break a command down into
--  component parts.  It will return a structure with the component parts
--  and the number of characters from the input string that were used.
--
--  The parsed command is stored in a ParseInfo structure:
--
------------------------------------------------------------------------------

Parse4882 = function (lTextMixedCase, lText, lStart)
    local lCommand = {}
    local lCommandNode
    local lLength = string.len(lText)
    local lCharCode
    local lIndex
    local lIndex2
    local lIndex3
    local lCount
    local lHeader

    -- This routine requires that there is no leading whitespace ahead of the
    -- command to parse. Replace the initialization of lIndex with the
    -- commented out initialization to have this routine skip the leading
    -- whitespace. It is not done now for better efficiency.
    lIndex = lStart
    -- Skip leading whitespace.
    -- lIndex = string.find(lText, lNonWhitespace, lStart) or (lLength + 1)

    -- Parse headers
    -- Determine root of command
    lCharCode = string.byte(lText, lIndex)
    if lCharCode == gCharCodes.mColon then
        -- Command rooted at top of hierarchy.
        gCurrentRoot = gCommandTree
        lIndex = lIndex + 1
        lCharCode = string.byte(lText, lIndex)
    end
    if lCharCode == gCharCodes.mStar then
        -- Command is a common command.
        lIndex2 = string.find(lText, gNonProgMnemonic, lIndex + 1) or lLength + 1
        lHeader = string.sub(lText, lIndex, lIndex2 - 1)
        gCurrentRoot = gCommandTree
        lCommandNode = gCommandTree[lHeader]
        if lCommandNode then
            lIndex = lIndex2
        else
            -- Unrecognized header (could not find a match)
            lCommand.mError = -113
            lIndex = lLength + 1
        end
    else
        lCommandNode = gCurrentRoot
        while lIndex <= lLength do
            lIndex2 = string.find(lText, gNonProgMnemonic, lIndex) or lLength + 1
            lHeader = string.sub(lText, lIndex, lIndex2 - 1)
            if lCommandNode[lHeader] then
                gCurrentRoot = lCommandNode
                lCommandNode = lCommandNode[lHeader]

                lCharCode = string.byte(lText, lIndex2)
                if lCharCode ~= gCharCodes.mColon then
                    lIndex = lIndex2
                    break
                else
                    lIndex = lIndex2 + 1
                end
            else
                if lCommandNode == gCurrentRoot and string.len(lHeader) == 0 then
                    -- Empty command. Ignore it.
                    lCommandNode = gSpecialCommands["$Empty"]
                else
                    -- Unrecognized header (could not find a match)
                    lCommand.mError = -113
                    lIndex = lLength + 1
                end
                break
            end
        end
    end
    if lCommandNode then
        lCommand.mCommandNode = lCommandNode
        lCharCode = string.byte(lText, lIndex)
        if lCharCode == gCharCodes.mQuestion then
            -- This is a query
            lCommand.mCommand = lCommandNode.mQuery
            lIndex = lIndex + 1
            lCharCode = string.byte(lText, lIndex)
        else
            lCommand.mCommand = lCommandNode.mCommand
        end
        -- Here we expect a whitespace character, a semicolon, or the end of string
        -- to be at the parse index.
        if lIndex <= lLength and lCharCode ~= gCharCodes.mSemicolon then
            if string.find(lText, "^%s", lIndex) ~= lIndex then
                -- ERROR! invalid <PROGRAM HEADER SEPARATOR>
                lCommand.mError = -111
                lIndex = lLength + 1
            end
        end

        -- Parse parameters
        lCount = 0
        lCommand.mParameters = {}
        while lIndex <= lLength do
            -- Skip leading whitespace
            lIndex = string.find(lText, gNonWhitespace, lIndex) or lLength + 1
            if lIndex <= lLength then
                lCharCode = string.byte(lText, lIndex)
                if lCharCode == gCharCodes.mSemicolon then
                    -- End of command found
                    lIndex2, lIndex3 = string.find(lText, ";%s*", lIndex)
                    lIndex = lIndex3 + 1
                    break
                end

                -- This must be a parameter
                lCount = lCount + 1
                if lCharCode == gCharCodes.mSingleQuote or lCharCode == gCharCodes.mDoubleQuote then
                    lCommand.mParameters[lCount], lIndex = ParseString(lTextMixedCase, lIndex)
                    if lIndex <= lLength then
                        lIndex2, lIndex3 = string.find(lText, "^%s*[,;]", lIndex)
                        if lIndex2 then
                            -- Skip whitespace and point to comma or semicolon
                            lIndex = lIndex3
                        else
                            lIndex2, lIndex3 = string.find(lText, "^%s*$", lIndex)
                            if not lIndex2 then
                                -- Text after string (or parse error in string)
                                lCommand.mError = -150
                                break
                            end
                            lIndex = lLength + 1
                        end
                    end
                elseif lCharCode == gCharCodes.mHash then
                    lCharCode = string.byte(lText, lIndex + 1)
                    if lCharCode == gCharCodes.mH then
                        -- Hexadecimal encoding
                        lIndex2, lIndex3 = string.find(lText, "^%x*", lIndex + 2)
                        if lIndex2 then
                            lCommand.mParameters[lCount] = string.sub(lText, lIndex, lIndex3)
                            lIndex = lIndex3 + 1
                        else
                            lCommand.mError = -102
                            break
                        end
                    elseif lCharCode == gCharCodes.mB then
                        -- Binary encoding
                        lIndex2, lIndex3 = string.find(lText, "^[01]*", lIndex + 2)
                        if lIndex2 then
                            lCommand.mParameters[lCount] = string.sub(lText, lIndex, lIndex3)
                            lIndex = lIndex3 + 1
                        else
                            lCommand.mError = -102
                            break
                        end
                    elseif lCharCode == gCharCodes.mQ then
                        -- Octal encoding
                        lIndex2, lIndex3 = string.find(lText, "^[01234567]*", lIndex + 2)
                        if lIndex2 then
                            lCommand.mParameters[lCount] = string.sub(lText, lIndex, lIndex3)
                            lIndex = lIndex3 + 1
                        else
                            lCommand.mError = -102
                            break
                        end
                    elseif lCharCode == gCharCodes.mZero then
                        -- Indefinite length arbitrary block data
                        if gParserState.mLastChar == gCharCodes.mNewLine then
                            -- Don't include the terminating linefeed
                            lCommand.mParameters[lCount] = string.sub(lTextMixedCase, lIndex, -2)
                        else
                            lCommand.mParameters[lCount] = string.sub(lTextMixedCase, lIndex)
                        end
                        lIndex = lLength + 1
                        break
                    elseif lCharCode >= gCharCodes.mOne and lCharCode <= gCharCodes.mNine then
                        -- Definite length arbitrary block data
                        lIndex2 = ParseBlockLength(lText, lIndex + 1)
                        if lIndex2 > lIndex + 1 then
                            lCommand.mParameters[lCount] = string.sub(lTextMixedCase, lIndex, lIndex2)
                            lIndex = lIndex2 + 1
                        else
                            lCommand.mError = -102
                            break
                        end
                        if lIndex <= lLength then
                            lIndex2, lIndex3 = string.find(lText, "^%s*[,;]", lIndex)
                            if lIndex2 then
                                -- Skip whitespace and point to comma or semicolon
                                lIndex = lIndex3
                            else
                                lIndex2, lIndex3 = string.find(lText, "^%s*$", lIndex)
                                if not lIndex2 then
                                    -- more data after block data
                                    lCommand.mError = -160
                                end
                                lIndex = lLength + 1
                            end
                        end
                    else
                        -- Invalid (either bad code or end of string after #)
                        lCommand.mError = -102
                        break
                    end
                elseif lCharCode == gCharCodes.mParenLeft then
                    -- Expression data
                    lCommand.mParameters[lCount], lIndex = ParseExpression(lText, lIndex)
                    if lIndex <= lLength then
                        lIndex2, lIndex3 = string.find(lText, "^%s*[,;]", lIndex)
                        if lIndex2 then
                            -- Skip whitespace and point to comma or semicolon
                            lIndex = lIndex3
                        else
                            lIndex2, lIndex3 = string.find(lText, "^%s*$", lIndex)
                            if not lIndex2 then
                               gErrorQueue.Add(-170)
                            end
                            lIndex = lLength + 1
                        end
                    end
                else
                    lIndex2, lIndex3, lCommand.mParameters[lCount] = string.find(lText, "([^,;]-)%s*[,;]", lIndex)
                    if lIndex2 then
                        lIndex = lIndex3
                    else
                        lIndex2, lIndex3, lCommand.mParameters[lCount] = string.find(lText, "(.-)%s*$", lIndex)
                        lIndex = lLength + 1
                    end
                end
                if lIndex <= lLength then
                    lCharCode = string.byte(lText, lIndex)
                    if lCharCode == gCharCodes.mComma then
                        lIndex = lIndex + 1
                    end
                end
            end
        end
    end

    return lCommand, lIndex - lStart
end

------------------------------------------------------------------------------
--
--  ParseNextMessage
--
--  Fully parse the next command in the current command message. It will
--  return the next command. It will return nil if there are no more commands
--  in the current message. If there are parse errors, the mParseInfo.mError
--  member will be set to the error code of the error.
--
--  This function will update the current position based on the number of
--  characters used. If all the characters are used, the position will be one
--  past the end of the string.
--
------------------------------------------------------------------------------

local ParseNextCommand = function ()
    local lParseInfo
    local lCount
    local lCommand
    local lExpectedParameters

    lParseInfo, lCount = Parse4882(gParserState.mCurrentText, gParserState.mCurrentTextUpper, gParserState.mCurrentPosition)
    gParserState.mCurrentPosition = gParserState.mCurrentPosition + lCount
    if gParserState.mCurrentPosition > string.len(gParserState.mCurrentText) then
        gParserState.mCurrentText = nil
    end
    if lParseInfo then
        if lParseInfo.mError then
            gParserState.mCurrentText = nil
        else
            lCommand = lParseInfo.mCommand
            if lCommand then
                -- Iterate over the parameters array and match parameters
                -- to parser functions.
                lExpectedParameters = lCommand.mParameters
                if lExpectedParameters then
                    local lActualParameters = lParseInfo.mParameters
                    local lIndex = 1
                    local lError
                    local lExpected
                    local lActual

                    lExpected = lExpectedParameters[lIndex]
                    while lExpected do
                        lActual = lActualParameters[lIndex]
                        if lActual then
                            -- Check parameter
                            lActualParameters[lIndex], lError = lExpected.mParse(lActual, lExpected)
                            if lError then
                                lParseInfo.mError = lError
                                break
                            end
                        else
                            if lExpected.mOptional then
                                if lExpected.mDefault then
                                    -- Use default
                                    lActualParameters[lIndex] = lExpected.mDefault
                                else
                                    -- Stop scanning when remaining parameters
                                    -- are missing and have no default.
                                    break
                                end
                            else
                                -- Missing parameter
                                lParseInfo.mError = -109
                                break
                            end
                        end
                        lIndex = lIndex + 1
                        lExpected = lExpectedParameters[lIndex]
                    end
                    if lActualParameters[lIndex] and not lError then
                        -- Too many parameters
                        lParseInfo.mError = -108
                    end
                else
                    -- No parameters were expected
                    if lParseInfo.mParameters[1] then
                        lParseInfo.mError = -108
                    end
                end
            else
                -- Query/Command mismatch
                lParseInfo.mError = -113
            end
        end
    end

    return lParseInfo
end

------------------------------------------------------------------------------
--
--  GetNextCommand
--
--  Load the next command from the message queue. This could be a decoded
--  message or the next command from a parsable message.
--
------------------------------------------------------------------------------

local GetNextCommand = function ()
    local lMessage
    local lText

    if gParserState.mCurrentText then
        gParserState.mNextCommand = ParseNextCommand()
        return
    end

    -- Make sure previous message was properly terminated.
    -- Instrument not recognizing this
    -- gRemoteComm.terminatemessage()

    if gParserState.mNextMessage then
        lMessage = gParserState.mNextMessage

        -- Remove current message from queue
        gParserState.mNextMessage = lMessage.mNext
        if not gParserState.mNextMessage then
            gParserState.mLastMessage = nil
        end

        -- Decode the message
        if lMessage.mType == gRemoteComm.types.MESSAGE then
            lText = lMessage.mMessage
            if gParserState.mPartialMessage then
                lText = gParserState.mPartialMessage .. lText
                gParserState.mPartialMessage = nil
            end
            -- Replace all control characters with spaces (Note: this may not work
            -- for products that accept/expect control characters in quoted strings.)
            gParserState.mLastChar = string.byte(lText, -1)
            lText = string.gsub(lText, "%c", " ")
            gParserState.mCurrentText = lText
            lText = string.upper(lText)
            gParserState.mCurrentTextUpper = lText
            -- For efficiency, leading/trailing whitespace is removed here rather than
            -- in the parse routine.
            gParserState.mCurrentPosition = string.find(lText, gNonWhitespace, 1) or (string.len(lText) + 1)

            gCurrentRoot = gCommandTree
            gParserState.mNextCommand = ParseNextCommand()
        elseif gSpecialCommands[lMessage.mType] then
            local lCommand = {}            
            lCommand.mCommandNode = gSpecialCommands[lMessage.mType]
            lCommand.mCommand = gSpecialCommands[lMessage.mType].mCommand

            gParserState.mNextCommand = lCommand
        elseif lMessage.mType == gRemoteComm.types.PARTIAL_MESSAGE then
            if gParserState.mPartialMessage then
                gParserState.mPartialMessage = gParserState.mPartialMessage .. lMessage.mMessage
            else
                gParserState.mPartialMessage = lMessage.mMessage
            end
        end
        -- Handle TRUNCATED_MESSAGE
    end
end

--============================================================================
--
--  Execution functions
--
--============================================================================
------------------------------------------------------------------------------
-- script initialization functions
--[[
    These functions are used to initialize and setup the script
--]]
-----------------------------------------------------------------------------

local Init = {}

------------------------------------------------------------------------------
--
--  Initialize34461A
--
--  Prepare the instrument hardware for 34461A emulation. This function must
--  be called before using Execute34461A or after changing the hardware state
--  between invokations of Engine34461A.
--
------------------------------------------------------------------------------

Initialize34461A = function ()
    gInitialized = true
    --reset()
    ResetDefaults()
    format.byteorder = format.NORMAL
    localnode.prompts = localnode.DISABLE
    localnode.prompts4882 = localnode.DISABLE
end

------------------------------------------------------------------------------
--
--  ExecuteCommand
--
--  Execute a command or log the parser error for the command if there was
--  one.
--
------------------------------------------------------------------------------

local ExecuteCommand  = function (lParseInfo)
    if lParseInfo.mError then
        if type(lParseInfo.mError) == "table" then
            for lIndex, lError in ipairs(lParseInfo.mError) do
                gErrorQueue.Add(lError)
            end
        else
            gErrorQueue.Add(lParseInfo.mError)
        end
    elseif lParseInfo.mCommand then
        lParseInfo.mCommand.mExecute(lParseInfo.mParameters)
    end
    
    --gRemoteComm.terminateunit()
end

------------------------------------------------------------------------------
--
--  PriorityExecute
--
--  Peek ahead for the next command and execute it if it has priority (one
--  designed to run while a sweep is in progress).
--
------------------------------------------------------------------------------

local PriorityExecute = function ()

    if gEngineMode then
        GetNewMessage()
    end

    if gPrintEnable or gParserState.mNextCommand then
        -- The only time this will be true is if a previous call to this
        -- function found a non-priority command that it did not execute.
        return
    end
        
    GetNextCommand()
    if gParserState.mNextCommand then
        local lCommand = gParserState.mNextCommand

        if lCommand.mError or lCommand.mCommand.mPriority then
            gParserState.mNextCommand = nil
            ExecuteCommand(lCommand)
        end
    end
end

------------------------------------------------------------------------------
--
--  ExecuteMessage
--
--  Execute the next SCPI command string in the parser queue.
--
------------------------------------------------------------------------------

local ExecuteMessage = function ()
    local lCommand

    while gParserState.mNextCommand or gParserState.mCurrentText do
        if gParserState.mNextCommand then
            lCommand = gParserState.mNextCommand
            gParserState.mNextCommand = nil
        else
            lCommand = ParseNextCommand()
        end

        if lCommand then
            ExecuteCommand(lCommand)
        end
    end
    --gRemoteComm.terminatemessage()
end

------------------------------------------------------------------------------
--
--  ScanUpdatedValues
--
--  Check the DMM settings and update local variables
--
------------------------------------------------------------------------------

local ScanUpdatedValues = function()
    -- Get the current measure function
    local lMeasFunc = gInstrumentState.Measure_Function.getter()
    -- If the measure function variable doesn't match, make it
    if gInstrumentState.Measure_Function.value.DMM_Enum ~= lMeasFunc then
        for lKey, lValue in pairs(gInstrumentAttributes.Meas_Functions) do
            if lValue.DMM_Enum == lMeasFunc then
                gInstrumentState.Measure_Function.value = lValue
            end
        end
    end
    -- Iterate through the measure function's state variables and
    -- make them match the current configuration
    lMeasFunc = gInstrumentState.Measure_Function
    for lKey, lValue in pairs(lMeasFunc.value.stateVariables) do
        if lValue.getter then
            local lCurrentValue = lValue.getter()
            -- If the value has enumerations, iterate through those and set appropriately
            if lValue.valueParent then
                for _, pValue in pairs(lValue.valueParent) do
                    if lCurrentValue == pValue.DMM_Enum 
                    or lCurrentValue == pValue.shorthand then
                        lValue.value = pValue
                        break
                    end
                end
            else
                lValue.value = lCurrentValue
            end
        end
    end
end

------------------------------------------------------------------------------
--
--  Execute34461A
--
--  Execute a 34461A SCPI command string.
--
------------------------------------------------------------------------------

Execute34461A = function (lCommandMessage)
    if type(lCommandMessage) == "string" then
        ScanUpdatedValues()
        AddMessage(lCommandMessage, gRemoteComm.types.MESSAGE, 0)
        GetNextCommand()
        ExecuteMessage()
    else
        print("$DIAG$ Can only execute a string message")
    end
end

------------------------------------------------------------------------------
--
--  Engine34461A
--
--  Intercept command interface communication and process commands as 34461A
--  SCPI command messages.
--
------------------------------------------------------------------------------
local UpdateStatusModel

Engine34461A = function ()
    if not gInitialized then
        Initialize34461A()
    end
    ScanUpdatedValues()
    -- override status register
    --RemoteCommStatus.override = 175
    gEngineMode = true
    gRemoteComm.intercept = gRemoteComm.ALL
    gOrigin = nil

    local lLastTMState = gTM.state()
    local lTMState = lLastTMState

    GetNewMessage = GetFirstCommandMessage
    while true do
        GetNewMessage()
        if gParserState.mNextMessage then
            GetNextCommand()
            ExecuteMessage()
        else
            -- Update status model here.
            UpdateStatusModel()
            -- Check if measurements have completed
            lTMState = gTM.state()
            if lTMState == trigger.STATE_IDLE and lTMState ~= lLastTMState then
                gTriggerModel.EndTriggerModel()
            end
            lLastTMState = lTMState
            delay(0.0003)
        end
        if gDEVMODE and eventlog.getcount() > 0 then
            print(eventlog.next())
        end
        --collectgarbage()
    end
    gRemoteComm.intercept = gRemoteComm.DISABLE
    gEngineMode = false
end

------------------------------------------------------------------------------
--
--  EndEmulation()
--
--  Sets all globals to nil and collects garbage, then exits the script.
--
------------------------------------------------------------------------------

function EndEmulation()
    ResetDefaults = nil
    Parse4882 = nil
    Initialize34461A = nil
    Execute34461A = nil
    Engine34461A = nil
    collectgarbage()
    exit()
end

--============================================================================
--
--  Utility functions
--
--============================================================================

-- Status model registers
quesStatus        = {mCondition = 0, mEvent = 0, mEventEnable = 0, mSummary = 4}
operStatus        = {mCondition = 0, mEvent = 0, mEventEnable = 0, mSummary = 8}
standardEvent     = {                mEvent = 0, mEventEnable = 0, mSummary = 6}

StatusModel       = {mStatus = 0, mEventEnable = 0}

StatusModel.SetCondition = function (lRegister, lBit)
    local lCondition = bit.set(lRegister.mCondition, lBit)
    if lCondition ~= lRegister.mCondition then
        lRegister.mCondition = lCondition
        StatusModel.SetEvent(lRegister, lBit)
    end
end

StatusModel.ClearCondition = function (lRegister, lBit)
    lRegister.mCondition = bit.clear(lRegister.mCondition, lBit)
end

StatusModel.SetEvent = function (lRegister, lBit)
    local lEvent = bit.set(lRegister.mEvent, lBit)
    if lEvent ~= lRegister.mEvent then
        lRegister.mEvent = lEvent
        if bit.bitand(lEvent, lRegister.mEventEnable) > 0 then
            StatusModel.SetSummary(lRegister.mSummary)
        end
    end
end

StatusModel.SetEvents = function (lRegister, lMask)
    local lEvent = bit.bitor(lRegister.mEvent, lMask)
    if lEvent ~= lRegister.mEvent then
        lRegister.mEvent = lEvent
        if bit.bitand(lEvent, lRegister.mEventEnable) > 0 then
            StatusModel.SetSummary(lRegister.mSummary)
        end
    end
end

StatusModel.ClearEvent = function (lRegister)
    lRegister.mEvent = 0
    StatusModel.ClearSummary(lRegister.mSummary)
end

StatusModel.SetEnable = function (lRegister, lValue)
    lRegister.mEventEnable = lValue
    if lRegister.mEvent then
        if bit.bitand(lRegister.mEvent, lRegister.mEventEnable) > 0 then
            StatusModel.SetSummary(lRegister.mSummary)
        else
            StatusModel.ClearSummary(lRegister.mSummary)
        end
    else
        lRegister.mEventEnable = bit.clear(lRegister.mEventEnable, 7)
    end
end

StatusModel.SetSummary = function (lBit)
    local lStatus = bit.set(StatusModel.mStatus, lBit)
    if lStatus ~= StatusModel.mStatus then
        StatusModel.mStatus = lStatus
        -- Set the RQS
        if bit.bitand(StatusModel.mEventEnable, lStatus) > 0 then
            StatusModel.mStatus = bit.set(StatusModel.mStatus, 7)
        end
        --gRemoteCommStatus.condition = lStatus
    end
end

StatusModel.ClearSummary = function (lBit)
    local lStatus = bit.clear(StatusModel.mStatus, lBit)
    if lStatus ~= StatusModel.mStatus then
        StatusModel.mStatus = lStatus
        if bit.bitand(StatusModel.mStatus, StatusModel.mEventEnable) == 0 then
            StatusModel.mStatus = bit.clear(StatusModel.mStatus, 7)
        end
        --gRemoteCommStatus.condition = lStatus
    end
end

------------------------------------------------------------------------------
--
--  UpdateStatusModel
--
------------------------------------------------------------------------------

UpdateStatusModel = function ()
    local lStatusCondition = gAccessors.mGetStatusCondition()
    -- Update the Error available bit
    if bit.bitand(lStatusCondition, 4) > 0 then
        StatusModel.SetSummary(4)
    end
    -- Update the output buffer bit
    if bit.bitand(lStatusCondition, 16) > 0 then
        StatusModel.SetCondition(16)
    end
    -- Update Reading memory threshold 
    if gReadingMemory.readingBuffer.n >= gInstrumentState.General.Data_Event_Threshold.value then
        StatusModel.SetCondition(operStatus, 10)
    else
        StatusModel.ClearCondition(operStatus, 10)
    end

    -- Update Standard Event Register
    -- (OPC (Bit 0), QYE (Bit 2), PON (Bit 7) bits are directly read from 6500 status model)
    local lEvents
    lEvents = gAccessors.mGetStatusStandardEvent()
    if lEvents > 0 then
        StatusModel.SetEvents(standardEvent, bit.bitand(lEvents, 133))
    end
end

------------------------------------------------------------------------------
--
--  WaitForEvent
--
--  Process command input (so we can look for triggers and aborts) while
--  waiting for an event. This function takes a function argument that must
--  return true when the event is detected. This function will loop until the
--  given function returns true.
--
------------------------------------------------------------------------------

local WaitForEvent = function (lCheck)
    while true do
        PriorityExecute()
        if lCheck() then
            return
        end
        UpdateStatusModel()
    end
end

--============================================================================
--
-- Command Tables
--
-- This table holds the SCPI command tree. First the command hierarchy is
-- defined for the long command forms. Short forms and optional elements
-- are then defined. Finally, the functions that implement the commands are
-- defined last.
--
--============================================================================

gCommandTree = 
{
    ["*IDN"] = {mQuery = {}},
    ["*CLS"] = {mCommand = {}},
    ["*ESE"] = {mCommand = {}, mQuery = {}},
    ["*ESR"] = {mQuery = {}},
    ["*PSC"] = {mQuery = {}},
    ["*RST"] = {mCommand = {}},
    ["*SRE"] = {mCommand = {}, mQuery = {}},
    ["*STB"] = {mQuery = {}},
    ["ABORT"] =
    {
        mCommand = {mPriority = true},
    },
    ["CONFIGURE"] =
    {
        mQuery = {},
        ["AC"] =
        {
            mCommand = {},
        },
        ["CURRENT"] =
        {
            ["AC"] =
            {
                mCommand = {},
            },
            ["DC"] =
            {
                mCommand = {},
            },
        },
        ["DC"] =
        {
            mCommand = {},
        },
        ["RATIO"] =
        {
            mCommand = {},
        },
        ["VOLTAGE"] =
        {
            ["AC"] =
            {
                mCommand = {},
            },
            ["DC"] =
            {
                mCommand = {},
            },
        },
        ["RESISTANCE"] =
        {
            mCommand = {},
        },
        ["FRESISTANCE"] =
        {
            mCommand = {},
        },
    },
    ["DATA"] = 
    {
        ["LAST"] =
        {
            mQuery = {},
        },
        ["POINTS"] =
        {
            mQuery = {},
            ["EVENT"] =
            {
                ["THRESHOLD"] =
                {
                    mCommand = {},
                    mQuery = {},
                },
            },
        },
        ["REMOVE"] =
        {
            mQuery = {},
        },
    },
    ["DEV"] = 
    {
        ["EXIT"] =
        {
            mCommand = {},
        }
    },
    ["FETCH"] =
    {
        mQuery = {},
    },
    ["INITIATE"] =
    {
        mCommand = {},
        ["IMMEDIATE"] =
        {
            mCommand = {},
        },
    },
    ["R"] =
    {
        mQuery = {}
    },
    ["READ"] = 
    {
        mQuery = {},
    },
    ["SAMPLE"] =
    {
        ["COUNT"] =
        {
            mCommand = {},
            mQuery = {},
        },
    },
    ["SENSE"] =
    {
        ["CURRENT"] =
        {       
            ["AC"] =
            {
                ["BANDWIDTH"] =
                {
                    mQuery = {},
                    mCommand = {},
                },
                ["NULL"] =
                {
                    mQuery = {},
                    mCommand = {},
                    ["STATE"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                    ["VALUE"] =
                    {
                        mQuery = {},
                        mCommand = {},
                        ["AUTO"] =
                        {
                            mQuery = {},
                            mCommand = {},
                        },
                    },
                },  
                ["RANGE"] =
                {
                    mQuery = {},
                    mCommand = {},
                    ["AUTO"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                },
                ["TERMINALS"] =
                {
                    mQuery = {},
                },
            },
            ["DC"] =
            {
                ["NPLC"] =
                {
                    mCommand = {},
                    mQuery = {},
                },
                ["NULL"] =
                {
                    mQuery = {},
                    mCommand = {},
                    ["STATE"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                    ["VALUE"] =
                    {
                        mQuery = {},
                        mCommand = {},
                        ["AUTO"] =
                        {
                            mQuery = {},
                            mCommand = {},
                        },
                    },
                },
                ["RANGE"] =
                {
                    mQuery = {},
                    mCommand = {},
                    ["AUTO"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                },
                ["TERMINALS"] =
                {
                    mQuery = {},
                },
                ["ZERO"] =
                {
                    ["AUTO"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                },
            },
        },
        ["FRESISTANCE"] =
        {
            ["NPLC"] = 
            {
                mQuery = {},
                mCommand = {},
            },
            ["NULL"] =
            {
                mQuery = {},
                mCommand = {},
                ["STATE"] =
                {
                    mQuery = {},
                    mCommand = {},
                },
                ["VALUE"] =
                {
                    mQuery = {},
                    mCommand = {},
                    ["AUTO"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                },
            },
            ["RANGE"] =
            {
                mQuery = {},
                mCommand = {},
                ["AUTO"] =
                {
                    mQuery = {},
                    mCommand = {},
                },
            },
        },
        ["FUNCTION"] =
        {
            ["ON"] =
            {
                mCommand = {},
                mQuery = {},
            },
        },
        ["RESISTANCE"] =
        {
            ["NPLC"] = 
            {
                mQuery = {},
                mCommand = {},
            },
            ["NULL"] =
            {
                mQuery = {},
                mCommand = {},
                ["STATE"] =
                {
                    mQuery = {},
                    mCommand = {},
                },
                ["VALUE"] =
                {
                    mQuery = {},
                    mCommand = {},
                    ["AUTO"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                },
            },
            ["RANGE"] =
            {
                mQuery = {},
                mCommand = {},
                ["AUTO"] =
                {
                    mQuery = {},
                    mCommand = {},
                },
            },
            ["ZERO"] =
            {
                ["AUTO"] =
                {
                    mQuery = {},
                    mCommand = {}
                }
            },
        },
        ["VOLTAGE"] =
        {
            ["NPLC"] =
            {
                mQuery = {},
                mCommand = {},
            },
            ["AC"] =
            {
                ["BANDWIDTH"] =
                {
                    mQuery = {},
                    mCommand = {},
                },
                ["NULL"] =
                {
                    mQuery = {},
                    mCommand = {},
                    ["STATE"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                    ["VALUE"] =
                    {
                        mQuery = {},
                        mCommand = {},
                        ["AUTO"] =
                        {
                            mQuery = {},
                            mCommand = {},
                        },
                    },
                },  
                ["RANGE"] =
                {
                    mQuery = {},
                    mCommand = {},
                    ["AUTO"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                },
            },
            ["DC"] =
            {
                ["NULL"] =
                {
                    mQuery = {},
                    mCommand = {},
                    ["STATE"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                    ["VALUE"] =
                    {
                        mQuery = {},
                        mCommand = {},
                        ["AUTO"] =
                        {
                            mQuery = {},
                            mCommand = {},
                        },
                    },
                },
                ["RANGE"] =
                {
                    mQuery = {},
                    mCommand = {},
                    ["AUTO"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                },
                ["ZERO"] =
                {
                    ["AUTO"] =
                    {
                        mQuery = {},
                        mCommand = {},
                    },
                },
            },
            ["ZERO"] =
            {
                ["AUTO"] =
                {
                    mQuery = {},
                    mCommand = {},
                },
            },
        },
    },
    ["STATUS"] =
    {
        ["OPERATION"] =
        {
            mQuery = {},
            ["CONDITION"] =
            {
                mQuery = {},
            },
            ["ENABLE"] =
            {
                mCommand = {},
                mQuery = {},
            },
            ["EVENT"] =
            {
                mQuery = {},
            },
        },
        ["PRESET"] =
        {
            mCommand = {},
        },
        ["QUESTIONABLE"] =
        {
            mQuery = {},
            ["CONDITION"] =
            {
                mQuery = {},
            },
            ["ENABLE"] =
            {
                mCommand = {},
                mQuery = {},
            },
            ["EVENT"] =
            {
                mQuery = {},
            },
        }
    },
    ["TRIGGER"] =
    {
        ["COUNT"] =
        {
            mQuery = {},
            mCommand = {},
        },
        ["DELAY"] =
        {
            mQuery = {},
            mCommand = {},
            ["AUTO"] =
            {
                mQuery = {},
                mCommand = {},
            },
        },
        ["SLOPE"] =
        {
            mQuery = {},
            mCommand = {},
        },
        ["SOURCE"] =
        {
            mQuery = {},
            mCommand = {},
        },
    },
}

-- ADD ABBREVIATION ALIASES HERE
gCommandTree["DEV"]["EXT"]                              = gCommandTree["DEV"]["EXIT"]
gCommandTree["ABOR"]                                    = gCommandTree["ABORT"]
gCommandTree["CONF"]                                    = gCommandTree["CONFIGURE"]
gCommandTree["FET"]                                     = gCommandTree["FETCH"]
gCommandTree["INIT"]                                    = gCommandTree["INITIATE"]
gCommandTree["INITIATE"]["IMMEDIATE"].mQuery            = gCommandTree["INITIATE"].mQuery
gCommandTree["INITIATE"]["IMMEDIATE"].mCommand          = gCommandTree["INITIATE"].mCommand
gCommandTree["INITIATE"]["IMM"]                         = gCommandTree["INITIATE"]["IMMEDIATE"]

gCommandTree["CONFIGURE"]["VOLTAGE"]["DC"]              = gCommandTree["CONFIGURE"]["DC"]
gCommandTree["CONFIGURE"]["VOLTAGE"]["AC"]              = gCommandTree["CONFIGURE"]["AC"]
gCommandTree["CONFIGURE"]["VOLT"]                       = gCommandTree["CONFIGURE"]["VOLTAGE"]

gCommandTree["CONFIGURE"]["RAT"]                        = gCommandTree["CONFIGURE"]["RATIO"]
gCommandTree["CONFIGURE"]["DC"]["RATIO"]                = gCommandTree["CONFIGURE"]["RATIO"]
gCommandTree["CONFIGURE"]["DC"]["RAT"]                  = gCommandTree["CONFIGURE"]["RATIO"]
gCommandTree["CONFIGURE"]["VOLTAGE"]["RATIO"]           = gCommandTree["CONFIGURE"]["RATIO"]
gCommandTree["CONFIGURE"]["VOLTAGE"]["RAT"]             = gCommandTree["CONFIGURE"]["RATIO"]
gCommandTree["CONFIGURE"]["CURR"]                       = gCommandTree["CONFIGURE"]["CURRENT"]

gCommandTree["CONFIGURE"]["RES"]                        = gCommandTree["CONFIGURE"]["RESISTANCE"]
gCommandTree["CONFIGURE"]["FRES"]                       = gCommandTree["CONFIGURE"]["FRESISTANCE"]

gCommandTree["SAMP"]                                    = gCommandTree["SAMPLE"]
gCommandTree["SAMPLE"]["COUN"]                          = gCommandTree["SAMPLE"]["COUNT"]

gCommandTree["SENS"]                                    = gCommandTree["SENSE"]

gCommandTree["FUNCTION"]                                = gCommandTree["SENSE"]["FUNCTION"]
gCommandTree["FUNC"]                                    = gCommandTree["SENSE"]["FUNCTION"]

gCommandTree["CURRENT"]                                 = gCommandTree["SENSE"]["CURRENT"]
gCommandTree["CURR"]                                    = gCommandTree["SENSE"]["CURRENT"]
gCommandTree["SENSE"]["CURR"]                           = gCommandTree["SENSE"]["CURRENT"]
gCommandTree["SENSE"]["CURRENT"]["DC"]["RANG"]          = gCommandTree["SENSE"]["CURRENT"]["DC"]["RANGE"]
gCommandTree["SENSE"]["CURRENT"]["AC"]["RANG"]          = gCommandTree["SENSE"]["CURRENT"]["AC"]["RANGE"]
gCommandTree["SENSE"]["CURRENT"]["AC"]["BAND"]          = gCommandTree["SENSE"]["CURRENT"]["AC"]["BANDWIDTH"]
gCommandTree["SENSE"]["CURRENT"]["DC"]["NULL"]["STAT"]  = gCommandTree["SENSE"]["CURRENT"]["DC"]["NULL"]["STATE"]
gCommandTree["SENSE"]["CURRENT"]["AC"]["NULL"]["STAT"]  = gCommandTree["SENSE"]["CURRENT"]["AC"]["NULL"]["STATE"]
gCommandTree["SENSE"]["CURRENT"]["DC"]["NULL"]["VAL"]   = gCommandTree["SENSE"]["CURRENT"]["DC"]["NULL"]["VALUE"]
gCommandTree["SENSE"]["CURRENT"]["AC"]["NULL"]["VAL"]   = gCommandTree["SENSE"]["CURRENT"]["AC"]["NULL"]["VALUE"]
gCommandTree["SENSE"]["CURRENT"]["NPLC"]                = gCommandTree["SENSE"]["CURRENT"]["DC"]["NPLC"]
gCommandTree["SENSE"]["CURRENT"]["ZERO"]                = gCommandTree["SENSE"]["CURRENT"]["DC"]["ZERO"]
gCommandTree["SENSE"]["CURRENT"]["AC"]["NULL"].mCommand = gCommandTree["SENSE"]["CURRENT"]["AC"]["NULL"]["STATE"].mCommand
gCommandTree["SENSE"]["CURRENT"]["AC"]["NULL"].mQuery   = gCommandTree["SENSE"]["CURRENT"]["AC"]["NULL"]["STATE"].mQuery
gCommandTree["SENSE"]["CURRENT"]["DC"]["NULL"].mCommand = gCommandTree["SENSE"]["CURRENT"]["DC"]["NULL"]["STATE"].mCommand
gCommandTree["SENSE"]["CURRENT"]["DC"]["NULL"].mQuery   = gCommandTree["SENSE"]["CURRENT"]["DC"]["NULL"]["STATE"].mQuery
gCommandTree["SENSE"]["CURRENT"]["DC"]["TERM"]          = gCommandTree["SENSE"]["CURRENT"]["DC"]["TERMINALS"]
gCommandTree["SENSE"]["CURRENT"]["AC"]["TERM"]          = gCommandTree["SENSE"]["CURRENT"]["AC"]["TERMINALS"]

gCommandTree["SENSE"]["FUNC"]                           = gCommandTree["SENSE"]["FUNCTION"]
gCommandTree["SENSE"]["FUNCTION"].mCommand              = gCommandTree["SENSE"]["FUNCTION"]["ON"].mCommand
gCommandTree["SENSE"]["FUNCTION"].mQuery                = gCommandTree["SENSE"]["FUNCTION"]["ON"].mQuery

gCommandTree["RESISTANCE"]                              = gCommandTree["SENSE"]["RESISTANCE"]
gCommandTree["RES"]                                     = gCommandTree["SENSE"]["RESISTANCE"]
gCommandTree["SENSE"]["RES"]                            = gCommandTree["SENSE"]["RESISTANCE"]
gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["STAT"]     = gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["STATE"]
gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["VAL"]      = gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["VALUE"]
gCommandTree["SENSE"]["RESISTANCE"]["NULL"].mCommand    = gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["STATE"].mCommand
gCommandTree["SENSE"]["RESISTANCE"]["NULL"].mQuery      = gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["STATE"].mQuery
gCommandTree["SENSE"]["RESISTANCE"]["RANG"]             = gCommandTree["SENSE"]["RESISTANCE"]["RANGE"]

gCommandTree["SENSE"]["FRESISTANCE"]["NPLC"]            = gCommandTree["SENSE"]["RESISTANCE"]["NPLC"] 
gCommandTree["SENSE"]["FRESISTANCE"]["NULL"]["STATE"]   = gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["STATE"]
gCommandTree["SENSE"]["FRESISTANCE"]["NULL"]["VALUE"]   = gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["VALUE"]
gCommandTree["SENSE"]["FRESISTANCE"]["NULL"]["VALUE"]["AUTO"]   = gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["VALUE"]["AUTO"]
gCommandTree["SENSE"]["FRESISTANCE"]["RANGE"]["AUTO"]   = gCommandTree["SENSE"]["RESISTANCE"]["RANGE"]["AUTO"]

gCommandTree["FRESISTANCE"]                             = gCommandTree["SENSE"]["FRESISTANCE"]
gCommandTree["FRES"]                                    = gCommandTree["SENSE"]["FRESISTANCE"]
gCommandTree["SENSE"]["FRES"]                           = gCommandTree["SENSE"]["FRESISTANCE"]
gCommandTree["SENSE"]["FRESISTANCE"]["NULL"]["STAT"]    = gCommandTree["SENSE"]["FRESISTANCE"]["NULL"]["STATE"]
gCommandTree["SENSE"]["FRESISTANCE"]["NULL"]["VAL"]     = gCommandTree["SENSE"]["FRESISTANCE"]["NULL"]["VALUE"]
gCommandTree["SENSE"]["FRESISTANCE"]["NULL"].mCommand   = gCommandTree["SENSE"]["FRESISTANCE"]["NULL"]["STATE"].mCommand
gCommandTree["SENSE"]["FRESISTANCE"]["NULL"].mQuery     = gCommandTree["SENSE"]["FRESISTANCE"]["NULL"]["STATE"].mQuery
gCommandTree["SENSE"]["FRESISTANCE"]["RANG"]            = gCommandTree["SENSE"]["FRESISTANCE"]["RANGE"]

gCommandTree["VOLTAGE"]                                 = gCommandTree["SENSE"]["VOLTAGE"]
gCommandTree["VOLT"]                                    = gCommandTree["SENSE"]["VOLTAGE"]
gCommandTree["SENSE"]["VOLT"]                           = gCommandTree["SENSE"]["VOLTAGE"]
gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANG"]          = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"]
gCommandTree["SENSE"]["VOLTAGE"]["AC"]["RANG"]          = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["RANGE"]
gCommandTree["SENSE"]["VOLTAGE"]["AC"]["BAND"]          = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["BANDWIDTH"]
gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"]["STAT"]  = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"]["STATE"]
gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"]["STAT"]  = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"]["STATE"]
gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"]["VAL"]   = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"]["VALUE"]
gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"]["VAL"]   = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"]["VALUE"]
gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NPLC"]          = gCommandTree["SENSE"]["VOLTAGE"]["NPLC"]
gCommandTree["SENSE"]["VOLTAGE"]["DC"]["ZERO"]["AUTO"]  = gCommandTree["SENSE"]["VOLTAGE"]["ZERO"]["AUTO"]
gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"].mCommand = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"]["STATE"].mCommand
gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"].mQuery   = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"]["STATE"].mQuery
gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"].mCommand = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"]["STATE"].mCommand
gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"].mQuery   = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"]["STATE"].mQuery

gCommandTree["DATA"]["POIN"]                            = gCommandTree["DATA"]["POINTS"]
gCommandTree["DATA"]["POINTS"]["EVEN"]                  = gCommandTree["DATA"]["POINTS"]["EVENT"]
gCommandTree["DATA"]["POINTS"]["EVENT"]["THR"]          = gCommandTree["DATA"]["POINTS"]["EVENT"]["THRESHOLD"]
gCommandTree["DATA"]["REM"]                             = gCommandTree["DATA"]["REMOVE"]

gCommandTree["STAT"]                                    = gCommandTree["STATUS"]
gCommandTree["STATUS"]["OPER"]                          = gCommandTree["STATUS"]["OPERATION"]
gCommandTree["STATUS"]["OPERATION"]["COND"]             = gCommandTree["STATUS"]["OPERATION"]["CONDITION"]
gCommandTree["STATUS"]["OPERATION"]["ENAB"]             = gCommandTree["STATUS"]["OPERATION"]["ENABLE"]
gCommandTree["STATUS"]["OPERATION"]["EVEN"]             = gCommandTree["STATUS"]["OPERATION"]["EVENT"]
gCommandTree["STATUS"]["OPERATION"].mQuery              = gCommandTree["STATUS"]["OPERATION"]["EVENT"].mQuery
gCommandTree["STATUS"]["PRE"]                           = gCommandTree["STATUS"]["PRESET"]
gCommandTree["STATUS"]["QUES"]                          = gCommandTree["STATUS"]["QUESTIONABLE"]
gCommandTree["STATUS"]["QUESTIONABLE"]["COND"]          = gCommandTree["STATUS"]["QUESTIONABLE"]["CONDITION"]
gCommandTree["STATUS"]["QUESTIONABLE"]["ENAB"]          = gCommandTree["STATUS"]["QUESTIONABLE"]["ENABLE"]
gCommandTree["STATUS"]["QUESTIONABLE"]["EVEN"]          = gCommandTree["STATUS"]["QUESTIONABLE"]["EVENT"]
gCommandTree["STATUS"]["QUESTIONABLE"].mQuery           = gCommandTree["STATUS"]["QUESTIONABLE"]["EVENT"].mQuery

gCommandTree["TRIG"]                                    = gCommandTree["TRIGGER"]
gCommandTree["TRIGGER"]["COUN"]                         = gCommandTree["TRIGGER"]["COUNT"]
gCommandTree["TRIGGER"]["DEL"]                          = gCommandTree["TRIGGER"]["DELAY"]
gCommandTree["TRIGGER"]["SLOP"]                         = gCommandTree["TRIGGER"]["SLOPE"]
gCommandTree["TRIGGER"]["SOUR"]                         = gCommandTree["TRIGGER"]["SOURCE"]

-- DEV function
if gDEVMODE then
    gPrintCMDTree = function(printString, tree)
        local fptr = file.open("/usb1/Command_Tree.txt", file.MODE_APPEND)
        for key, value in pairs(tree) do
            if key == "mCommand" or key == "mQuery" then
                file.write(
                    fptr,
                    string.format(
                    "%s:%s\n",
                    printString,
                    key
                    )
                )
            else
                gPrintCMDTree(
                    string.format(
                        "%s:%s",
                        printString,
                        key
                    ),
                    tree[key]
                )  
            end
        end
        file.close(fptr)
    end
    --gPrintCMDTree("", gCommandTree)
    --print("DONE")
    --exit()
end

--============================================================================
--
-- Error Queue
--
-- The lErrors table contain Error number and Error Message of
-- status and error messages, state of the error(Enabled/Disabled)
--
-- The functions below assist in adding the errors to the error queue
-- and print the error codes and messages
--
-- mStatusBit = 15 is a dummy value and does not effect any
-- status register bits. Any other mStatusBit value
-- updates the Standard Event Status Register.
--
------------------------------------------------------------------------------

local lErrors =
{
    -- Error Events
    [-440] = {mState = true, mCode = "-440", mStatusBit = 2, mMessage = '-440,"Query UNTERMINATED after indefinite response"' },
    [-430] = {mState = true, mCode = "-430", mStatusBit = 2, mMessage = '-430,"Query DEADLOCKED"' },
    [-420] = {mState = true, mCode = "-420", mStatusBit = 2, mMessage = '-420,"Query UNTERMINATED"' },
    [-410] = {mState = true, mCode = "-410", mStatusBit = 2, mMessage = '-410,"Query INTERRUPTED"' },
    [-363] = {mState = true, mCode = "-363", mStatusBit = 3, mMessage = '-363,"Input buffer overrun"' },
    [-362] = {mState = true, mCode = "-362", mStatusBit = 3, mMessage = '-362,"Framing error in program message"' },
    [-361] = {mState = true, mCode = "-361", mStatusBit = 3, mMessage = '-361,"Parity error in program message"' },
    [-360] = {mState = true, mCode = "-360", mStatusBit = 3, mMessage = '-360,"Communications error"' },
    [-350] = {mState = true, mCode = "-350", mStatusBit = 3, mMessage = '-350,"Queue overflow"' },

    [-330] = {mState = true, mCode = "-330", mStatusBit = 3, mMessage = '-330,"Self-test failed"' },
    [-314] = {mState = true, mCode = "-314", mStatusBit = 3, mMessage = '-314,"Save/recall memory lost"' },
    [-315] = {mState = true, mCode = "-315", mStatusBit = 3, mMessage = '-315,"Configuration memory lost"' },
    [-285] = {mState = true, mCode = "-285", mStatusBit = 4, mMessage = '-285,"Program syntax error"' },
    [-284] = {mState = true, mCode = "-284", mStatusBit = 4, mMessage = '-284,"Program currently running"' },
    [-282] = {mState = true, mCode = "-282", mStatusBit = 4, mMessage = '-282,"Illegal program name"' },
    [-281] = {mState = true, mCode = "-281", mStatusBit = 4, mMessage = '-281,"Cannot create program"' },
    [-260] = {mState = true, mCode = "-260", mStatusBit = 4, mMessage = '-260,"Expression error"' },
    [-241] = {mState = true, mCode = "-241", mStatusBit = 4, mMessage = '-241,"Hardware missing"' },
    [-230] = {mState = true, mCode = "-230", mStatusBit = 4, mMessage = '-230,"Data corrupt or stale"' },

    [-225] = {mState = true, mCode = "-225", mStatusBit = 4, mMessage = '-225,"Out of memory"' },
    [-224] = {mState = true, mCode = "-224", mStatusBit = 4, mMessage = '-224,"Illegal parameter value"' },
    [-223] = {mState = true, mCode = "-223", mStatusBit = 4, mMessage = '-223,"Too much data"' },
    [-222] = {mState = true, mCode = "-222", mStatusBit = 4, mMessage = '-222,"Data out of range"' }, --* Changed to match 34461
    [-221] = {mState = true, mCode = "-221", mStatusBit = 4, mMessage = '-221,"Settings conflict"' },
    [-220] = {mState = true, mCode = "-220", mStatusBit = 4, mMessage = '-220,"Parameter error"' },

    [-215] = {mState = true, mCode = "-215", mStatusBit = 4, mMessage = '-215,"Arm deadlock"' },
    [-214] = {mState = true, mCode = "-214", mStatusBit = 4, mMessage = '-214,"Trigger deadlock"' },
    [-213] = {mState = true, mCode = "-213", mStatusBit = 4, mMessage = '-213,"Init ignored"' },
    [-212] = {mState = true, mCode = "-212", mStatusBit = 4, mMessage = '-212,"Arm ignored"' },
    [-211] = {mState = true, mCode = "-211", mStatusBit = 4, mMessage = '-211,"Trigger ignored"' },
    [-210] = {mState = true, mCode = "-210", mStatusBit = 4, mMessage = '-210,"Trigger error"' },
    [-202] = {mState = true, mCode = "-202", mStatusBit = 4, mMessage = '-202,"Settings lost due to rtl"' },
    [-201] = {mState = true, mCode = "-201", mStatusBit = 4, mMessage = '-201,"Invalid while in local"' },
    [-200] = {mState = true, mCode = "-200", mStatusBit = 4, mMessage = '-200,"Execution error"' },
    [-178] = {mState = true, mCode = "-178", mStatusBit = 5, mMessage = '-178,"Expression data not allowed"' },
    [-171] = {mState = true, mCode = "-171", mStatusBit = 5, mMessage = '-171,"Invalid expression"' },
    [-170] = {mState = true, mCode = "-170", mStatusBit = 5, mMessage = '-170,"Expression error"' },
    [-168] = {mState = true, mCode = "-168", mStatusBit = 5, mMessage = '-168,"Block data not allowed"' },
    [-161] = {mState = true, mCode = "-161", mStatusBit = 5, mMessage = '-161,"Invalid block data"' },
    [-160] = {mState = true, mCode = "-160", mStatusBit = 5, mMessage = '-160,"Block data error"' },                --
    [-158] = {mState = true, mCode = "-158", mStatusBit = 5, mMessage = '-158,"String data not allowed"' },
    [-154] = {mState = true, mCode = "-154", mStatusBit = 5, mMessage = '-154,"String too long"' },
    [-151] = {mState = true, mCode = "-151", mStatusBit = 5, mMessage = '-151,"Invalid string data"' },
    [-150] = {mState = true, mCode = "-150", mStatusBit = 5, mMessage = '-150,"String data error"' },               --
    [-148] = {mState = true, mCode = "-148", mStatusBit = 5, mMessage = '-148,"Character data not allowed"' },

    [-144] = {mState = true, mCode = "-144", mStatusBit = 5, mMessage = '-144,"Character data too long"' },
    [-141] = {mState = true, mCode = "-141", mStatusBit = 5, mMessage = '-141,"Invalid character data"' },
    [-140] = {mState = true, mCode = "-140", mStatusBit = 5, mMessage = '-140,"Character data error"' },
    [-128] = {mState = true, mCode = "-128", mStatusBit = 5, mMessage = '-128,"Numeric data not allowed"' },
    [-124] = {mState = true, mCode = "-124", mStatusBit = 5, mMessage = '-124,"Too many digits"' },

    [-123] = {mState = true, mCode = "-123", mStatusBit = 5, mMessage = '-123,"Exponent too large"' },
    [-121] = {mState = true, mCode = "-121", mStatusBit = 5, mMessage = '-121,"Invalid character in number"' },
    [-120] = {mState = true, mCode = "-120", mStatusBit = 5, mMessage = '-120,"Numeric data error"' },
    [-114] = {mState = true, mCode = "-114", mStatusBit = 5, mMessage = '-114,"Header suffix out of range"' },
    [-113] = {mState = true, mCode = "-113", mStatusBit = 5, mMessage = '-113,"Undefined header"' },                --

    [-112] = {mState = true, mCode = "-112", mStatusBit = 5, mMessage = '-112,"Program mnemonic too long"' },
    [-111] = {mState = true, mCode = "-111", mStatusBit = 5, mMessage = '-111,"Header separator error"' },          --
    [-110] = {mState = true, mCode = "-110", mStatusBit = 5, mMessage = '-110,"Command header error"' },
    [-109] = {mState = true, mCode = "-109", mStatusBit = 5, mMessage = '-109,"Missing parameter"' },               --
    [-108] = {mState = true, mCode = "-108", mStatusBit = 5, mMessage = '-108,"Parameter not allowed"' },           --

    [-105] = {mState = true, mCode = "-105", mStatusBit = 5, mMessage = '-105,"GET not allowed"' },
    [-104] = {mState = true, mCode = "-104", mStatusBit = 5, mMessage = '-104,"Data type error"' },
    [-103] = {mState = true, mCode = "-103", mStatusBit = 5, mMessage = '-103,"Invalid separator"' },
    [-102] = {mState = true, mCode = "-102", mStatusBit = 5, mMessage = '-102,"Syntax error"' },                    --
    [-101] = {mState = true, mCode = "-101", mStatusBit = 5, mMessage = '-101,"Invalid character"' },
    [-100] = {mState = true, mCode = "-100", mStatusBit = 5, mMessage = '-100,"Command error"' },

    -- Status Events
    -- Measurement events:
    [0]   = {mState = false, mCode = "0", mStatusBit = 15, mMessage = '0,"No error"' },
    [100] = {mState = false, mCode = "100", mStatusBit = 15, mMessage = '100,"Limit 1 failed"' },
    [101] = {mState = false, mCode = "101", mStatusBit = 15, mMessage = '101,"Low limit 2 failed"' },
    [102] = {mState = false, mCode = "102", mStatusBit = 15, mMessage = '102,"High limit 2 failed"' },
    [103] = {mState = false, mCode = "103", mStatusBit = 15, mMessage = '103,"Low limit 3 failed"' },
    [104] = {mState = false, mCode = "104", mStatusBit = 15, mMessage = '104,"High limit 3 failed"' },
    [105] = {mState = false, mCode = "105", mStatusBit = 15, mMessage = '105,"Active limit tests passed"' },
    [106] = {mState = false, mCode = "106", mStatusBit = 15, mMessage = '106,"Reading available"' },
    [107] = {mState = false, mCode = "107", mStatusBit = 15, mMessage = '107,"Reading overflow"' },
    [108] = {mState = false, mCode = "108", mStatusBit = 15, mMessage = '108,"Buffer available"' },
    [109] = {mState = false, mCode = "109", mStatusBit = 15, mMessage = '109,"Buffer full"' },
    [110] = {mState = false, mCode = "110", mStatusBit = 15, mMessage = '110,"Limit 4 failed"' },
    [111] = {mState = false, mCode = "111", mStatusBit = 15, mMessage = '111,"OUTPUT enable asserted"' },
    [112] = {mState = false, mCode = "112", mStatusBit = 15, mMessage = '112,"Temperature limit exceeded"' },
    [113] = {mState = false, mCode = "113", mStatusBit = 15, mMessage = '113,"Voltage limit exceeded"' },
    [114] = {mState = false, mCode = "114", mStatusBit = 15, mMessage = '114,"Source in compliance"' },

    -- Standard events:
    [200] = {mState = false, mCode = "200", mStatusBit = 15, mMessage = '200,"Operation complete"' },

    -- Operation events:
    [300] = {mState = false, mCode = "300", mStatusBit = 15, mMessage = '300,"Device calibrating"' },
    [303] = {mState = false, mCode = "303", mStatusBit = 15, mMessage = '303,"Device sweeping"' },
    [305] = {mState = false, mCode = "305", mStatusBit = 15, mMessage = '305,"Waiting in trigger layer"' },
    [306] = {mState = false, mCode = "306", mStatusBit = 15, mMessage = '306,"Waiting in arm layer"' },
    [310] = {mState = false, mCode = "310", mStatusBit = 15, mMessage = '310,"Entering idle layer"' },

    -- Questionable events:
    [408] = {mState = false, mCode = "408", mStatusBit = 15, mMessage = '408,"Questionable Calibration"' },
    [414] = {mState = false, mCode = "414", mStatusBit = 15, mMessage = '414,"Command Warning"' },

    -- Error Events
    -- Calibration errors:
    [500] = {mState = true, mCode = "500", mStatusBit = 3, mMessage = '500,"Date of calibration not set"' },
    [501] = {mState = true, mCode = "501", mStatusBit = 3, mMessage = '501,"Next date of calibration not set"' },
    [502] = {mState = true, mCode = "502", mStatusBit = 3, mMessage = '502,"Calibration data invalid"' },
    [503] = {mState = true, mCode = "503", mStatusBit = 3, mMessage = '503,"DAC calibration overflow"' },
    [504] = {mState = true, mCode = "504", mStatusBit = 3, mMessage = '504,"DAC calibration underflow"' },
    [505] = {mState = true, mCode = "505", mStatusBit = 3, mMessage = '505,"Source offset data invalid"' },
    [506] = {mState = true, mCode = "506", mStatusBit = 3, mMessage = '506,"Source gain data invalid"' },
    [507] = {mState = true, mCode = "507", mStatusBit = 3, mMessage = '507,"Measurement offset data invalid"' },
    [508] = {mState = true, mCode = "508", mStatusBit = 3, mMessage = '508,"Measurement gain data invalid"' },
    [509] = {mState = true, mCode = "509", mStatusBit = 3, mMessage = '509,"Not permitted with cal locked"' },
    [510] = {mState = true, mCode = "510", mStatusBit = 3, mMessage = '510,"Not permitted with cal un-locked"' },

    -- Lost data errors:
    [601] = {mState = true, mCode = "601", mStatusBit = 3, mMessage = '601,"Reading buffer data lost"' },
    [602] = {mState = true, mCode = "602", mStatusBit = 3, mMessage = '602,"GPIB address lost"' },
    [603] = {mState = true, mCode = "603", mStatusBit = 3, mMessage = '603,"Power-on state lost"' },
    [604] = {mState = true, mCode = "604", mStatusBit = 3, mMessage = '604,"DC calibration data lost"' },
    [605] = {mState = true, mCode = "605", mStatusBit = 3, mMessage = '605,"Calibration dates lost"' },
    [606] = {mState = true, mCode = "606", mStatusBit = 3, mMessage = '606,"GPIB communication language lost"' },

    -- Communication errors:
    [700] = {mState = true, mCode = "700", mStatusBit = 3, mMessage = '700,"Invalid system communication"' },
    [701] = {mState = true, mCode = "701", mStatusBit = 3, mMessage = '701,"ASCII only with RS-232"' },
    [702] = {mState = true, mCode = "702", mStatusBit = 3, mMessage = '702,"Preamp Timeout"' },

    -- Additional command execution errors:
    [800] = {mState = true, mCode = "800", mStatusBit = 4, mMessage = '800,"Illegal with storage active"' },
    [801] = {mState = true, mCode = "801", mStatusBit = 4, mMessage = '801,"Insufficient vector data"' },
    [802] = {mState = true, mCode = "802", mStatusBit = 4, mMessage = '802,"OUTPUT blocked by output enable"' },
    [803] = {mState = true, mCode = "803", mStatusBit = 4, mMessage = '803,"Not permitted with OUTPUT off"' },
    [804] = {mState = true, mCode = "804", mStatusBit = 4, mMessage = '804,"Expression list full"' },
    [805] = {mState = true, mCode = "805", mStatusBit = 4, mMessage = '805,"Undefined expression exists"' },
    [806] = {mState = true, mCode = "806", mStatusBit = 4, mMessage = '806,"Expression not found"' },
    [807] = {mState = true, mCode = "807", mStatusBit = 4, mMessage = '807,"Definition not allowed"' },
    [808] = {mState = true, mCode = "808", mStatusBit = 4, mMessage = '808,"Expression cannot be deleted"' },
    [809] = {mState = true, mCode = "809", mStatusBit = 4, mMessage = '809,"Source memory location revised"' },
    [810] = {mState = true, mCode = "810", mStatusBit = 4, mMessage = '810,"OUTPUT blocked by Over Temp"' },
    [811] = {mState = true, mCode = "811", mStatusBit = 4, mMessage = '811,"Not an operator or number"' },
    [812] = {mState = true, mCode = "812", mStatusBit = 4, mMessage = '812,"Mismatched parenthesis"' },
    [813] = {mState = true, mCode = "813", mStatusBit = 4, mMessage = '813,"Not a number of data handle"' },
    [814] = {mState = true, mCode = "814", mStatusBit = 4, mMessage = '814,"Mismatched brackets"' },
    [815] = {mState = true, mCode = "815", mStatusBit = 4, mMessage = '815,"Too many parenthesis"' },
    [816] = {mState = true, mCode = "816", mStatusBit = 4, mMessage = '816,"Entire expression not parsed"' },
    [817] = {mState = true, mCode = "817", mStatusBit = 4, mMessage = '817,"Unknown token"' },
    [818] = {mState = true, mCode = "818", mStatusBit = 4, mMessage = '818,"Error parsing mantissa"' },
    [819] = {mState = true, mCode = "819", mStatusBit = 4, mMessage = '819,"Error parsing exponent"' },
    [820] = {mState = true, mCode = "820", mStatusBit = 4, mMessage = '820,"Error parsing value"' },
    [821] = {mState = true, mCode = "821", mStatusBit = 4, mMessage = '821,"Invalid data handle index"' },
    [822] = {mState = true, mCode = "822", mStatusBit = 4, mMessage = '822,"Too small for sense range"' },
    [823] = {mState = true, mCode = "823", mStatusBit = 4, mMessage = '823,"Invalid with source read-back on"' },
    [824] = {mState = true, mCode = "824", mStatusBit = 4, mMessage = '824,"Cannot exceed compliance range"' },
    [825] = {mState = true, mCode = "825", mStatusBit = 4, mMessage = '825,"Invalid with auto-ohms on"' },
    [826] = {mState = true, mCode = "826", mStatusBit = 4, mMessage = '826,"Attempt to exceed power limit"' },
    [827] = {mState = true, mCode = "827", mStatusBit = 4, mMessage = '827,"Invalid with ohms guard on"' },
    [828] = {mState = true, mCode = "828", mStatusBit = 4, mMessage = '828,"Invalid on 1 amp range"' },
    [829] = {mState = true, mCode = "829", mStatusBit = 4, mMessage = '829,"Invalid on 1kV range"' },
    [830] = {mState = true, mCode = "830", mStatusBit = 4, mMessage = '830,"Invalid with INF ARM:COUNT"' },
    [831] = {mState = true, mCode = "831", mStatusBit = 4, mMessage = '831,"Invalid in Pulse Mode"' },
    [900] = {mState = true, mCode = "900", mStatusBit = 3, mMessage = '900,"Internal System Error"' }
}

------------------------------------------------------------------------------
--
-- gErrorQueue.Add
--
-- Put an error into the error queue.
--
------------------------------------------------------------------------------

gErrorQueue.Add = function (lErrorNumber)
    local lError = lErrors[lErrorNumber]
       
    --if lError.mStatusBit ~= 15 then
    --    StatusModel.SetEvent(standardStatus, lError.mStatusBit + 1)
    --end

    if lError.mState then
        local lCount = table.getn(gErrorQueue)

        if lCount < 64 then
            table.insert(gErrorQueue, lError)
            --StatusModel.SetSummary(3)
        elseif lCount == 64 then
            table.insert(gErrorQueue, lErrors[-350])
        end    
        -- Display Error Message on Front Panel and Beep
        if gDisplayErrors then
            if gErrorQueue.lDisplay then
                display.delete(gErrorQueue.lDisplay)
            end
            gErrorQueue.lDisplay = display.prompt(
                display.BUTTONS_OK,
                lError.mMessage
            )
            beeper.beep(0.15, 340)
        end
        if gErrorReadback then
            print(lError.mMessage)
        end
    end
end

--[[
    ReadErrorQueue prints the errors from the error queue
    if the queue is empty '0,"No error"' is printed
--]]
gErrorQueue.ReadError = function ()
    local lCount = table.getn(gErrorQueue)
    
    if lCount == 0 then
        Print('0,"No error"')
    else
        Print(gErrorQueue[1].mMessage)
        table.remove(gErrorQueue, 1)
        if lCount == 1 then
            --StatusModel.ClearSummary(3)
        end
    end
end

--[[
    ReadErrorCode prints the error codes from the error queue
    if the queue is empty '0' is printed
--]]
gErrorQueue.ReadErrorCode = function ()
    local lCount = table.getn(gErrorQueue)
    
    if lCount == 0 then
        Print('0')
    else
        Print(gErrorQueue[1].mCode)
        table.remove(gErrorQueue, 1)
        if lCount == 1 then
            --StatusModel.ClearSummary(3)
        end
    end
end

--[[
    ErrorCount prints the number of errors in the queue
--]]
gErrorQueue.ErrorCount = function ()
    Print(tostring(table.getn(gErrorQueue)))
end

--[[
    ReadErrorAll prints all the errors from the error queue
    and clears the error queue.
    if the queue is empty '0,"No error"' is printed
--]]
gErrorQueue.ReadErrorAll = function ()
    if table.getn(gErrorQueue) == 0 then
        Print('0,"No error"')
    else
        for i = 1, table.getn(gErrorQueue) do
            if i > 1 then
                Print(',')
            end
            Print(gErrorQueue[1].mMessage)
            table.remove(gErrorQueue, 1)
        end
        --StatusModel.ClearSummary(3)
    end
end

--[[
    ReadErrorCodeAll prints all the error codes from the error queue
    and clears the error queue.
    if the queue is empty '0' is printed
--]]
gErrorQueue.ReadErrorCodeAll = function ()
    if table.getn(gErrorQueue) == 0 then
        Print('0')
    else
        for i = 1, table.getn(gErrorQueue) do
            if i > 1 then
                Print(',')
            end
            Print(gErrorQueue[1].mCode)
            table.remove(gErrorQueue, 1)
        end
        StatusModel.ClearSummary(3)
    end
end

--[[
    Clear removes all the errors from the error queue
--]]
gErrorQueue.Clear = function ()
    if table.getn(gErrorQueue) == 0 then
        return
    else
        for i = 1, table.getn(gErrorQueue) do
            table.remove(gErrorQueue, 1)
        end
        --StatusModel.ClearSummary(3)
    end
end

--[[
    DisableAllErrorEvents disables all the error and statue events
--]]
gErrorQueue.DisableAllErrorEvents = function ()
    for k, v in pairs(lErrors) do
        lErrors[k].mState = false
    end
end

--[[
    ChangeErrorEventState sets the state of the error events in lErrors table
--]]
gErrorQueue.ChangeErrorEventState = function (lStart, lStop, lState)
    -- if start index is greater than end index swap them
    if lStart > lStop then
       local tempStart = lStart
       lStart = lStop
       lStop = tempStart
    end

    -- Set the state
    for k = lStart, lStop do
        if lErrors[k] then
            lErrors[k].mState = lState
        end
    end
end

--[[
    EnableErrorEvents enables the spcecified list of error and statue events
    and disables the rest
--]]
gErrorQueue.EnableErrorEvents = function (lEventNumList)
    gErrorQueue.DisableAllErrorEvents()
    for k = 1, table.getn(lEventNumList), 2 do
        gErrorQueue.ChangeErrorEventState(lEventNumList[k], lEventNumList[k+1], true)
    end
end

--[[
    DisableErrorEvents disable the spcecified list of error and statue events
--]]
gErrorQueue.DisableErrorEvents = function (lEventNumList)
    --if table.getn(lEventNumList) then
        for k = 1, table.getn(lEventNumList), 2 do
            gErrorQueue.ChangeErrorEventState(lEventNumList[k], lEventNumList[k+1], false)
        end
    --end
end

--[[
    PrintErrorEvents prints the list Enabled/Disabled error and statue events
--]]
gErrorQueue.PrintErrorEvents = function (lState)
    local lAddToPrintQue = true
    local lStart, lEnd
    local lCount = 0
    local lComma = false
    
    Print("(")
    for i = -440, 900 do
        if lErrors[i] then
            if lErrors[i].mState == lState then
                if lAddToPrintQue then
                    lStart = lErrors[i].mCode
                    lAddToPrintQue = false
                end
                lEnd = lErrors[i].mCode
                lCount = lCount + 1
            else
                if lAddToPrintQue == false then
                    if lCount > 1 then
                        if lComma then
                            Print(",")
                        end
                        if tonumber(lStart) >= 0 then
                           Print("+")
                        end
                        Print(lStart)
                        Print(":")
                        if tonumber(lEnd) >= 0 then
                           Print("+")
                        end
                        Print(lEnd)
                        lComma = true
                        lCount = 0
                        lAddToPrintQue = true
                    else
                        if lComma then
                            Print(",")
                        end
                        if tonumber(lEnd) >= 0 then
                           Print("+")
                        end
                        Print(lEnd)
                        lComma = true
                        lCount = 0
                        lAddToPrintQue = true
                    end
                end
            end
        end
    end
    if lCount > 1 then
        if lComma then
            Print(",")
        end
        if tonumber(lStart) >= 0 then
           Print("+")
        end
        Print(lStart)
        Print(":")
        if tonumber(lEnd) >= 0 then
           Print("+")
        end
        Print(lEnd)
    elseif lCount == 1 then
        if lComma then
            Print(",")
        end
        if tonumber(lEnd) >= 0 then
           Print("+")
        end
        Print(lEnd)
    end
    Print(")")
end

--============================================================================
--
-- Measurement Trigger Model
--
--============================================================================

local gTriggerModel = {
    tmInitialized = false
}

------------------------------------------------------------------------------
--
--  InitializeTM
--
--  Load the measurement trigger model with user specified settings
--
------------------------------------------------------------------------------

gTriggerModel.InitializeTM = function()
    -- Trigger Delay Timer
    gTriggerTimer.clear()
    gAccessors.mSetTriggerTimerCount(1)
    -- Stimulus is the trigger model event
    gAccessors.mSetTriggerTimerStimulus(trigger.EVENT_NOTIFY1)
    -- 0 if autodelay
    if gInstrumentState.General.Trigger_Delay_Auto.value.shorthand ~= 1 then
        gAccessors.mSetTriggerTimerDelay(gInstrumentState.General.Trigger_Delay.value)
    end
    gAccessors.mSetTriggerTimerEnable(trigger.ON)

    gTM.load("Empty")
    if gInstrumentState.General.Trigger_Source.value == "EXT" then
        gTM.setblock(1, trigger.BLOCK_WAIT, trigger.EVENT_EXTERNAL, trigger.CLEAR_ENTER)
    elseif gInstrumentState.General.Trigger_Source.value == "IMM" then
        gTM.setblock(1, trigger.BLOCK_NOP)
    end
    if gInstrumentState.General.Trigger_Delay_Auto.value.shorthand ~= 1 then
        -- Notify trigger delay timer to start
        gTM.setblock(2, trigger.BLOCK_NOTIFY, trigger.EVENT_NOTIFY1)
        -- Wait for trigger delay timer
        gTM.setblock(3, trigger.BLOCK_WAIT, trigger.EVENT_TIMER1)
    else
        gTM.setblock(2, trigger.BLOCK_NOP)
        gTM.setblock(3, trigger.BLOCK_NOP)
    end

    -- Take measurement
    gTM.setblock(4, trigger.BLOCK_MEASURE_DIGITIZE, gReadingMemory.readingBuffer, 1)
    
    -- Loop back to notify
    gTM.setblock(5, trigger.BLOCK_BRANCH_COUNTER, gInstrumentState.General.Sample_Count.value, 2)
    -- Loop back to wait
    gTM.setblock(6, trigger.BLOCK_BRANCH_COUNTER, gInstrumentState.General.Trigger_Count.value, 1)

    gTriggerModel.tmInitialized = true
end

------------------------------------------------------------------------------
--
--  InitiateMeasurements
--
--  Initiate a new set of measurements
--
------------------------------------------------------------------------------

gTriggerModel.InitiateMeasurements = function()
    if not gTriggerModel.tmInitialized then
        gTriggerModel.InitializeTM()
    end
    StatusModel.ClearCondition(operStatus, 9)
    gLastMeasurement.index = 1
    gLastMeasurement.value = gNan
    gLastMeasurement.units = gInstrumentState.Measure_Function.value.units
    local lCurrentStateVars = gInstrumentState.Measure_Function.value.stateVariables
    if lCurrentStateVars and lCurrentStateVars.Null_Value_Auto.value then
        lCurrentStateVars.Null_State.value = gInstrumentAttributes.OnOff.ON
        gRel.acquire()
    end
    gTM.initiate()
end

------------------------------------------------------------------------------
--
--  EndTriggerModel
--
--  When the trigger model is completed
--
------------------------------------------------------------------------------

gTriggerModel.EndTriggerModel = function()
    -- Store the last measurement for DATA:LAST?
    gLastMeasurement.index = gReadingMemory.readingBuffer.endindex
    if gLastMeasurement.index == 0 then gLastMeasurement.value = gNan
    else gLastMeasurement.value = gReadingMemory.readingBuffer[gLastMeasurement.index] end
end

------------------------------------------------------------------------------
-- Print functions
--
-- These functions are used to format and print data
--
-----------------------------------------------------------------------------
local FormatNumber = function (lNumber, signed)
    if signed and lNumber >= 0 then
        return string.format("+%E", lNumber)
    end
    return string.format("%E", lNumber)
end

local FormatBuffer = function (lStart, lCount, remove)
    local lBuffer = gReadingMemory.readingBuffer

    -- print(lStart)
    local lFormatString = FormatNumber(lBuffer.readings[lStart], true)
    for i=1, lCount-1 do
        lFormatString = lFormatString .. "," .. FormatNumber(lBuffer.readings[math.mod(lStart+(i-1), gReadingMemory.bufferSize)+1], true)
        --Printing timestamps to ensure continuity
        --print(gReadingMemory.readingBuffer.relativetimestamps[math.mod(lStart+(i-1), gReadingMemory.bufferSize)+1])
        --print(math.mod(lStart+(i-1), gReadingMemory.bufferSize)+1)
    end
    if remove then
        --print(math.mod(lStart+(lCount-1-1), gReadingMemory.bufferSize)+1)
        gReadingMemory.lastRemoved = lBuffer.relativetimestamps[math.mod(lStart+(lCount-1-1), gReadingMemory.bufferSize)+1]
        --print(gReadingMemory.lastRemoved)
    end
    return lFormatString
end

local FormatBlockLength = function(lString)
    local lBlockLength = string.format("%d", string.len(lString))
    local lNumLength = string.format("%d", string.len(lBlockLength))
    return string.format("#%s%s%s", lNumLength, lBlockLength, lString)
end

local ChangeMeasFunction = function(measFunction)
    local lInstMeasFunc = gInstrumentState.Measure_Function
    lInstMeasFunc.value = measFunction
    lInstMeasFunc.setter(lInstMeasFunc.value.DMM_Enum)
    CheckTerminals()
    -- Iterate through measurement attibutes, checking and setting them
    for lIndex, lValue in pairs(lInstMeasFunc.value.stateVariables) do
        if lValue.setter then
            if type(lValue.value) == "number" then
                lValue.setter(lValue.value)
            else
                lValue.setter(lValue.value.DMM_Enum)
            end
        end
    end
end

--============================================================================
--
-- SCPI Command Definitions
--
-- This section is where the command tables are populated and command
-- implemenation function are defined.
--
--============================================================================

------------------------------------------------------------------------------
--
-- Common Commands
--
-----------------------------------------------------------------------------

-- *IDN?
gCurrentRoot = gCommandTree["*IDN"]
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            --"KEITHLEY INSTRUMENTS,MODEL DMM6500,%s,%s",
            "Keysight Technologies,34461A,%s,%s\n",
            localnode.serialno,
            localnode.version
        )
    )
end
-- *CLS
gCurrentRoot = gCommandTree["*CLS"]
gCurrentRoot.mCommand.mExecute = function()
    StatusModel.ClearEvent(quesStatus)
    StatusModel.ClearEvent(operStatus)
    StatusModel.ClearEvent(standardEvent)
    gErrorQueue.Clear()
end
-- *ESE <enable_value>
gCurrentRoot = gCommandTree["*ESE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseInteger}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lEventEnable = lParameters[1]
    if lEventEnable >= 0 and lEventEnable <= 256 then
        StatusModel.SetEnable(standardEvent, lEventEnable)
    else
        gErrorQueue.Add(-222)
    end
end
-- *ESE?
gCurrentRoot.mQuery.mExecute = function()
    print(standardEvent.mEventEnable)
end
-- *ESR?
gCurrentRoot = gCommandTree["*ESR"]
gCurrentRoot.mQuery.mExecute = function()
    print(standardEvent.mEvent)
    StatusModel.ClearEvent(standardEvent)
end
-- *PSC?
gCurrentRoot = gCommandTree["*PSC"]
gCurrentRoot.mQuery.mExecute = function()
    print(0)
end
-- *SRE <enable_value>
gCurrentRoot = gCommandTree["*SRE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseInteger}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lEventEnable = lParameters[1]
    if lEventEnable >= 0 and lEventEnable <= 256 then
        StatusModel.SetEnable(StatusModel, lEventEnable)
    else
        gErrorQueue.Add(-222)
    end
end
-- *SRE?
gCurrentRoot.mQuery.mExecute = function()
    print(StatusModel.mEventEnable)
end
-- *STB?
gCurrentRoot = gCommandTree["*STB"]
gCurrentRoot.mQuery.mExecute = function()
    print(StatusModel.mStatus)
end
-- *RST
gCurrentRoot = gCommandTree["*RST"]
gCurrentRoot.mCommand.mExecute = function()
    -- Reset to 34461A defaults
    ResetDefaults()
end
-- ABORt
gCurrentRoot = gCommandTree["ABORT"]
gCurrentRoot.mCommand.mExecute = function()
    gTM.abort()
    gAbort = true
    -- Find some way to break waitcompletes and waiting for measurements
end
-- INITiate[:IMMediate]
gCurrentRoot = gCommandTree["INITIATE"]
gCurrentRoot.mCommand.mExecute = function()
    gReadingMemory.reset()
    gTriggerModel.InitiateMeasurements()
end
-- R? [<max_readings>]
gCurrentRoot = gCommandTree["R"]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseNRfOptional}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    if lParameters[1] >= 1 and lParameters[1] <= 2000000 then
        local lMaxReadings = gReadingMemory.bufferSize
        if lParameters[1] then
            lMaxReadings = lParameters[1]
        end

        local lStart = gReadingMemory.readingBuffer.startindex
        if lStart == 0 then
            return
        end
        while gReadingMemory.readingBuffer.relativetimestamps[lStart] <= gReadingMemory.lastRemoved do
            lStart = math.mod(lStart, gReadingMemory.bufferSize)+1
            if lStart == gReadingMemory.readingBuffer.startindex then
                return
            end
        end

        local lDataAvailable = gReadingMemory.readingBuffer.endindex - lStart + 1
        if lDataAvailable == 0 then 
            lDataAvailable = gReadingMemory.bufferSize
        end

        print(FormatBlockLength(FormatBuffer(lStart, math.min(lMaxReadings,lDataAvailable), true)))
    else
        gErrorQueue.Add(-222)
    end
end
-- READ?
gCurrentRoot = gCommandTree["READ"]
gCurrentRoot.mQuery.mExecute = function()
    gReadingMemory.reset()
    gTriggerModel.InitiateMeasurements()
    waitcomplete() -- May need to change to only wait for trigger model
    print(FormatBuffer(gReadingMemory.readingBuffer.startindex, gReadingMemory.readingBuffer.n, true))
end
-- FETch?
gCurrentRoot = gCommandTree["FETCH"]
gCurrentRoot.mQuery.mExecute = function()
    waitcomplete() -- May need to change to only wait for trigger model
    local lStart = gReadingMemory.readingBuffer.startindex
    while gReadingMemory.readingBuffer.relativetimestamps[lStart] <= gReadingMemory.lastRemoved do
        print(gReadingMemory.readingBuffer.relativetimestamps[lStart], gReadingMemory.lastRemoved)
        lStart = math.mod(lStart, gReadingMemory.bufferSize)+1
        if lStart == gReadingMemory.readingBuffer.startindex then
            return
        end
    end
    print(FormatBuffer(lStart, gReadingMemory.readingBuffer.n, false))
end
-- DEV:EXIT
-- DEV Command to exit program
gCurrentRoot = gCommandTree["DEV"]["EXIT"]
gCurrentRoot.mCommand.mExecute = function()
    gTM.abort()
    EndEmulation()
end

------------------------------------------------------------------------------
--
-- CONFigure subsystem
--
-----------------------------------------------------------------------------

-- CONFigure?
gCurrentRoot = gCommandTree["CONFIGURE"]
gCurrentRoot.mQuery.mExecute = function()
    -- RESOLUTION NOT SUPPORTED CURRENTLY
    -- Query measure function, range, and resolution
    local lCurrentRange = gAccessors.mGetMeasureRange()
    print(
        string.format(
            "%s %s,%s", 
            gInstrumentState.Measure_Function.value.shorthand, 
            FormatNumber(lCurrentRange, true),
            "nil"
        )
    )
end
-- CONFigure:CURRent:AC [{<range>|AUTO|MIN|MAX|DEF} [, {<resolution>|MIN|MAX|DEF}]]
gCurrentRoot = gCommandTree["CONFIGURE"]["CURRENT"]["AC"]
gCurrentRoot.mCommand.mParameters =
{
    {
        mParse = gParserTable.ParseParameterChoice,
        mOptional = true,
        mData =
        {
            gParserTable.mParseNRf,
            {
                mParse = gParserTable.ParseParameterName,
                mOptional = true,
                mNames =
                {
                    ["MIN"]         = gOperatingBoundaries.AC_Current.Range.min,
                    ["MINIMUM"]     = gOperatingBoundaries.AC_Current.Range.min,
                    ["MAX"]         = gOperatingBoundaries.AC_Current.Range.max,
                    ["MAXIMUM"]     = gOperatingBoundaries.AC_Current.Range.max,
                    ["DEF"]         = gOperatingBoundaries.AC_Current.Range.def,
                    ["DEFAULT"]     = gOperatingBoundaries.AC_Current.Range.def,
                    ["AUTO"]        = "AUTO"
                }
            }
        }
    },
    gParserTable.mParseAny
}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lMeasFunc = gInstrumentState.Measure_Function
    lMeasFunc.value = gInstrumentAttributes.Meas_Functions.AC_Current
    lMeasFunc.setter(lMeasFunc.value.DMM_Enum)
    -- Reset to AC measurement defaults
    gResetFunctionVariables.ResetGeneral()
    gSetFunctionAttributes.SetGeneral()
    gResetFunctionVariables.ResetACCurrent()
    gSetFunctionAttributes.SetACCurrent()
    gReadingMemory.reset()
    -- Set the measure range
    local lMeasureRange = lParameters[1]
    if lMeasureRange then
        if lMeasureRange == "AUTO" then
            gCommandTree["SENSE"]["CURRENT"]["AC"]["RANGE"]["AUTO"].mCommand.mExecute({"ON"})
        elseif lMeasureRange <= gOperatingBoundaries.AC_Current.Range.max
        and    lMeasureRange >= gOperatingBoundaries.AC_Current.Range.min then
            gCommandTree["SENSE"]["CURRENT"]["AC"]["RANGE"].mCommand.mExecute({lMeasureRange})
        else
            gErrorQueue.Add(-222)
        end
    end
end
-- CONFigure:CURRent:DC [{<range>|AUTO|MIN|MAX|DEF} [, {<resolution>|MIN|MAX|DEF}]]
gCurrentRoot = gCommandTree["CONFIGURE"]["CURRENT"]["DC"]
gCurrentRoot.mCommand.mParameters =
{
    {
        mParse = gParserTable.ParseParameterChoice,
        mOptional = true,
        mData =
        {
            gParserTable.mParseNRf,
            {
                mParse = gParserTable.ParseParameterName,
                mOptional = true,
                mNames =
                {
                    ["MIN"]         = gOperatingBoundaries.DC_Current.Range.min,
                    ["MINIMUM"]     = gOperatingBoundaries.DC_Current.Range.min,
                    ["MAX"]         = gOperatingBoundaries.DC_Current.Range.max,
                    ["MAXIMUM"]     = gOperatingBoundaries.DC_Current.Range.max,
                    ["DEF"]         = gOperatingBoundaries.DC_Current.Range.def,
                    ["DEFAULT"]     = gOperatingBoundaries.DC_Current.Range.def,
                    ["AUTO"]        = "AUTO"
                }
            }
        }
    },
    gParserTable.mParseAny
}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lMeasFunc = gInstrumentState.Measure_Function
    lMeasFunc.value = gInstrumentAttributes.Meas_Functions.DC_Current
    lMeasFunc.setter(lMeasFunc.value.DMM_Enum)
    -- Reset to AC measurement defaults
    gResetFunctionVariables.ResetGeneral()
    gSetFunctionAttributes.SetGeneral()
    gResetFunctionVariables.ResetDCCurrent()
    gSetFunctionAttributes.SetDCCurrent()
    gReadingMemory.reset()
    -- Set the measure range
    local lMeasureRange = lParameters[1]
    if lMeasureRange then
        if lMeasureRange == "AUTO" then
            gCommandTree["SENSE"]["CURRENT"]["DC"]["RANGE"]["AUTO"].mCommand.mExecute({"ON"})
        elseif lMeasureRange <= gOperatingBoundaries.DC_Current.Range.max
        and    lMeasureRange >= gOperatingBoundaries.DC_Current.Range.min then
            gCommandTree["SENSE"]["CURRENT"]["DC"]["RANGE"].mCommand.mExecute({lMeasureRange})
        else
            gErrorQueue.Add(-222)
        end
    end
end
-- CONFigure:FRESistance [{<range>|AUTO|MIN|MAX|DEF} [, {<resolution>|MIN|MAX|DEF}]]
gCurrentRoot = gCommandTree["CONFIGURE"]["FRESISTANCE"]
gCurrentRoot.mCommand.mParameters =
{
    {
        mParse = gParserTable.ParseParameterChoice,
        mOptional = true,
        mData =
        {
            gParserTable.mParseNRf,
            {
                mParse = gParserTable.ParseParameterName,
                mOptional = true,
                mNames =
                {
                    ["MIN"]         = gOperatingBoundaries.FResistance.Range.min,
                    ["MINIMUM"]     = gOperatingBoundaries.FResistance.Range.min,
                    ["MAX"]         = gOperatingBoundaries.FResistance.Range.max,
                    ["MAXIMUM"]     = gOperatingBoundaries.FResistance.Range.max,
                    ["DEF"]         = gOperatingBoundaries.FResistance.Range.def,
                    ["DEFAULT"]     = gOperatingBoundaries.FResistance.Range.def,
                    ["AUTO"]        = "AUTO"
                }
            }
        }
    },
    gParserTable.mParseAny
}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lMeasFunc = gInstrumentState.Measure_Function
    lMeasFunc.value = gInstrumentAttributes.Meas_Functions.FResistance
    lMeasFunc.setter(lMeasFunc.value.DMM_Enum)
    -- Reset to Resistance defaults
    gResetFunctionVariables.ResetGeneral()
    gSetFunctionAttributes.SetGeneral()
    gResetFunctionVariables.ResetFResistance()
    gSetFunctionAttributes.SetFResistance()
    gReadingMemory.reset()
    -- Set the measure range
    local lMeasureRange = lParameters[1]
    if lMeasureRange then
        if lMeasureRange == "AUTO" then
            gCommandTree["SENSE"]["FRESISTANCE"]["RANGE"]["AUTO"].mCommand.mExecute({"ON"})
        elseif lMeasureRange <= gOperatingBoundaries.FResistance.Range.max
        and    lMeasureRange >= gOperatingBoundaries.FResistance.Range.min then
            gCommandTree["SENSE"]["FRESISTANCE"]["RANGE"].mCommand.mExecute({lMeasureRange})
        else
            gErrorQueue.Add(-222)
        end
    end
end
-- CONFigure:RESistance [{<range>|AUTO|MIN|MAX|DEF} [, {<resolution>|MIN|MAX|DEF}]]
gCurrentRoot = gCommandTree["CONFIGURE"]["RESISTANCE"]
gCurrentRoot.mCommand.mParameters =
{
    {
        mParse = gParserTable.ParseParameterChoice,
        mOptional = true,
        mData =
        {
            gParserTable.mParseNRf,
            {
                mParse = gParserTable.ParseParameterName,
                mOptional = true,
                mNames =
                {
                    ["MIN"]         = gOperatingBoundaries.Resistance.Range.min,
                    ["MINIMUM"]     = gOperatingBoundaries.Resistance.Range.min,
                    ["MAX"]         = gOperatingBoundaries.Resistance.Range.max,
                    ["MAXIMUM"]     = gOperatingBoundaries.Resistance.Range.max,
                    ["DEF"]         = gOperatingBoundaries.Resistance.Range.def,
                    ["DEFAULT"]     = gOperatingBoundaries.Resistance.Range.def,
                    ["AUTO"]        = "AUTO"
                }
            }
        }
    },
    gParserTable.mParseAny
}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lMeasFunc = gInstrumentState.Measure_Function
    lMeasFunc.value = gInstrumentAttributes.Meas_Functions.Resistance
    lMeasFunc.setter(lMeasFunc.value.DMM_Enum)
    -- Reset to Resistance defaults
    gResetFunctionVariables.ResetGeneral()
    gSetFunctionAttributes.SetGeneral()
    gResetFunctionVariables.ResetResistance()
    gSetFunctionAttributes.SetResistance()
    gReadingMemory.reset()
    -- Set the measure range
    local lMeasureRange = lParameters[1]
    if lMeasureRange then
        if lMeasureRange == "AUTO" then
            gCommandTree["SENSE"]["RESISTANCE"]["RANGE"]["AUTO"].mCommand.mExecute({"ON"})
        elseif lMeasureRange <= gOperatingBoundaries.Resistance.Range.max
        and    lMeasureRange >= gOperatingBoundaries.Resistance.Range.min then
            gCommandTree["SENSE"]["RESISTANCE"]["RANGE"].mCommand.mExecute({lMeasureRange})
        else
            gErrorQueue.Add(-222)
        end
    end
end
-- CONFigure[:VOLTage]:AC [{<range>|AUTO|MIN|MAX|DEF}[, {<resolution>|MIN|MAX|DEF}]]
gCurrentRoot = gCommandTree["CONFIGURE"]["AC"]
gCurrentRoot.mCommand.mParameters =
{
    {
        mParse = gParserTable.ParseParameterChoice,
        mOptional = true,
        mData =
        {
            gParserTable.mParseNRf,
            {
                mParse = gParserTable.ParseParameterName,
                mOptional = true,
                mNames =
                {
                    ["MIN"]         = gOperatingBoundaries.AC_Voltage.Range.min,
                    ["MINIMUM"]     = gOperatingBoundaries.AC_Voltage.Range.min,
                    ["MAX"]         = gOperatingBoundaries.AC_Voltage.Range.max,
                    ["MAXIMUM"]     = gOperatingBoundaries.AC_Voltage.Range.max,
                    ["DEF"]         = gOperatingBoundaries.AC_Voltage.Range.def,
                    ["DEFAULT"]     = gOperatingBoundaries.AC_Voltage.Range.def,
                    ["AUTO"]        = "AUTO"
                }
            }
        }
    },
    gParserTable.mParseAny
}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lMeasFunc = gInstrumentState.Measure_Function
    lMeasFunc.value = gInstrumentAttributes.Meas_Functions.AC_Voltage
    lMeasFunc.setter(lMeasFunc.value.DMM_Enum)
    -- Reset to AC measurement defaults
    gResetFunctionVariables.ResetGeneral()
    gSetFunctionAttributes.SetGeneral()
    gResetFunctionVariables.ResetACVoltage()
    gSetFunctionAttributes.SetACVoltage()
    gReadingMemory.reset()
    -- Set the measure range
    local lMeasureRange = lParameters[1]
    if lMeasureRange then
        if lMeasureRange == "AUTO" then
            gCommandTree["SENSE"]["VOLTAGE"]["AC"]["RANGE"]["AUTO"].mCommand.mExecute({"ON"})
        elseif lMeasureRange <= gOperatingBoundaries.AC_Voltage.Range.max
        and    lMeasureRange >= gOperatingBoundaries.AC_Voltage.Range.min then
            gCommandTree["SENSE"]["VOLTAGE"]["AC"]["RANGE"].mCommand.mExecute({lMeasureRange})
        else
            gErrorQueue.Add(-222)
        end
    end
end
-- CONFigure[:VOLTage]:DC [{<range>|AUTO|MIN|MAX|DEF}[, {<resolution>|MIN|MAX|DEF}]]
gCurrentRoot = gCommandTree["CONFIGURE"]["DC"]
gCurrentRoot.mCommand.mParameters =
{
    {
        mParse = gParserTable.ParseParameterChoice,
        mOptional = true,
        mData =
        {
            gParserTable.mParseNRf,
            {
                mParse = gParserTable.ParseParameterName,
                mOptional = true,
                mNames =
                {
                    ["MIN"]         = gOperatingBoundaries.DC_Voltage.Range.min,
                    ["MINIMUM"]     = gOperatingBoundaries.DC_Voltage.Range.min,
                    ["MAX"]         = gOperatingBoundaries.DC_Voltage.Range.max,
                    ["MAXIMUM"]     = gOperatingBoundaries.DC_Voltage.Range.max,
                    ["DEF"]         = gOperatingBoundaries.DC_Voltage.Range.def,
                    ["DEFAULT"]     = gOperatingBoundaries.DC_Voltage.Range.def,
                    ["AUTO"]        = "AUTO"
                }
            }
        }
    },
    gParserTable.mParseAny
}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lMeasFunc = gInstrumentState.Measure_Function
    lMeasFunc.value = gInstrumentAttributes.Meas_Functions.DC_Voltage
    lMeasFunc.setter(lMeasFunc.value.DMM_Enum)
    -- Reset to DC measurement defaults
    gResetFunctionVariables.ResetGeneral()
    gSetFunctionAttributes.SetGeneral()
    gResetFunctionVariables.ResetDCVoltage()
    gSetFunctionAttributes.SetDCVoltage()
    gReadingMemory.reset()
    -- Set the measure range
    local lMeasureRange = lParameters[1]
    if lMeasureRange then
        if lMeasureRange == "AUTO" then
            gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"]["AUTO"].mCommand.mExecute({"ON"})
        elseif lMeasureRange <= gOperatingBoundaries.DC_Voltage.Range.max
        and    lMeasureRange >= gOperatingBoundaries.DC_Voltage.Range.min then
            gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"].mCommand.mExecute({lMeasureRange})
        else
            gErrorQueue.Add(-222)
        end
    end
end
-- CONFigure[:VOLTage][:DC]:RATio [{<range>|AUTO|MIN|MAX|DEF}[, {<resolution>|MIN|MAX|DEF}]]
gCurrentRoot = gCommandTree["CONFIGURE"]["DC"]["RATIO"]
gCurrentRoot.mCommand.mParameters =
{
    {
        mParse = gParserTable.ParseParameterChoice,
        mOptional = true,
        mData =
        {
            gParserTable.mParseNRf,
            {
                mParse = gParserTable.ParseParameterName,
                mOptional = true,
                mNames =
                {
                    ["MIN"]         = gOperatingBoundaries.DC_Voltage.Range.min,
                    ["MINIMUM"]     = gOperatingBoundaries.DC_Voltage.Range.min,
                    ["MAX"]         = gOperatingBoundaries.DC_Voltage.Range.max,
                    ["MAXIMUM"]     = gOperatingBoundaries.DC_Voltage.Range.max,
                    ["DEF"]         = gOperatingBoundaries.DC_Voltage.Range.def,
                    ["DEFAULT"]     = gOperatingBoundaries.DC_Voltage.Range.def,
                    ["AUTO"]        = "AUTO"
                }
            }
        }
    },
    gParserTable.mParseAny
}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lMeasFunc = gInstrumentState.Measure_Function
    lMeasFunc.value = gInstrumentAttributes.Meas_Functions.Ratio
    lMeasFunc.setter(lMeasFunc.value.DMM_Enum)
    -- Reset to DC measurement defaults
    gResetFunctionVariables.ResetGeneral()
    gSetFunctionAttributes.SetGeneral()
    gResetFunctionVariables.ResetDCVoltage()
    gSetFunctionAttributes.SetDCVoltage()
    gReadingMemory.reset()
    -- Set the measure range
    local lMeasureRange = lParameters[1]
    if lMeasureRange then
        if lMeasureRange == "AUTO" then
            gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"]["AUTO"].mCommand.mExecute({"ON"})
        elseif lMeasureRange <= gOperatingBoundaries.DC_Voltage.Range.max
        and    lMeasureRange >= gOperatingBoundaries.DC_Voltage.Range.min then
            gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"].mCommand.mExecute({lMeasureRange})
        else
            gErrorQueue.Add(-222)
        end
    end
end

------------------------------------------------------------------------------
--
-- DATA subsystem
--
-----------------------------------------------------------------------------

-- DATA:LAST?
gCurrentRoot = gCommandTree["DATA"]["LAST"]
gCurrentRoot.mQuery.mExecute = function()
    if trigger.model.state() == trigger.STATE_RUNNING then
        print(
            string.format(
                "%s %s",
                FormatNumber(gReadingMemory.readingBuffer[gReadingMemory.readingBuffer.endindex],true),
                gLastMeasurement.units
            )
        )
    else
        print(
            string.format(
                "%s %s",
                FormatNumber(gLastMeasurement.value,true),
                gLastMeasurement.units
            )
        )
    end
end
-- DATA:POINts?
gCurrentRoot = gCommandTree["DATA"]["POINTS"]
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            FormatNumber(gReadingMemory.readingBuffer.n,true)
        )
    )
end
-- DATA:POINts:EVENt:THReshold <count>
gCurrentRoot = gCommandTree["DATA"]["POINTS"]["EVENT"]["THRESHOLD"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseInteger}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lPoints = lParameters[1]
    if lPoints >= 1 and lPoints <= gReadingMemory.bufferSize then
        gInstrumentState.General.Data_Event_Threshold.value = lPoints
    else
        gErrorQueue.Add(-222)
    end
end
-- DATA:POINts:EVENt:THReshold?
gCurrentRoot.mQuery.mExecute = function()
    print(gInstrumentState.General.Data_Event_Threshold.value)
end
-- DATA:REMove? <num_readings> [,WAIT]
gCurrentRoot = gCommandTree["DATA"]["REMOVE"]
gCurrentRoot.mQuery.mParameters =
{
    gParserTable.mParseNRf,
    {
        mParse = gParserTable.ParseParameterName,
        mOptional = true,
        mNames =
        {
            ["WAIT"] = "WAIT"
        }
    }
}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lNumReadings = lParameters[1]
    local lWait = lParameters[2] == "WAIT"
    local lStart = gReadingMemory.readingBuffer.startindex
    -- Check that there is data in buffer
    if lStart == 0 then
        gErrorQueue.Add(-222)
        return
    end
    if lNumReadings <= gReadingMemory.bufferSize then
        if lWait then
            -- Calculate the readings available and the number of removed data points
            local lReadingsAvail = gReadingMemory.readingBuffer.n
            local lRemovedPoints = 0
            -- While timestamp is less than the last removed timestamp
            while gReadingMemory.readingBuffer.relativetimestamps[lStart] <= gReadingMemory.lastRemoved do
                lStart = math.mod(lStart, gReadingMemory.bufferSize)+1
                lRemovedPoints = lRemovedPoints+1
                -- If all data points are removed
                if lStart == gReadingMemory.readingBuffer.startindex then
                    return
                end
            end
            lReadingsAvail = gReadingMemory.readingBuffer.n - lRemovedPoints
            -- Wait for readings to accumulate
            while lReadingsAvail < lNumReadings do
                -- Check for priority commands
                PriorityExecute()
                if gAbort then gAbort = false return end
                -- Calculate the readings available and the number of removed data points
                lReadingsAvail = gReadingMemory.readingBuffer.n
                lRemovedPoints = 0
                -- While timestamp is less than the last removed timestamp
                while gReadingMemory.readingBuffer.relativetimestamps[lStart] <= gReadingMemory.lastRemoved do
                    lStart = math.mod(lStart, gReadingMemory.bufferSize)+1
                    lRemovedPoints = lRemovedPoints+1
                    -- If all data points are removed
                    if lStart == gReadingMemory.readingBuffer.startindex then
                        return
                    end
                end
                lReadingsAvail = gReadingMemory.readingBuffer.n - lRemovedPoints
                -- Check that trigger model isn't idle
                if gTM.state() ~= trigger.STATE_RUNNING and gTM.state() ~= trigger.STATE_WAITING and lReadingsAvail < lNumReadings then
                    return
                end
                UpdateStatusModel()
                delay(1e-3)
            end
        else
            -- Calculate the readings available, not counting deleted readings
            local lReadingsAvail = gReadingMemory.readingBuffer.n
            -- While the current index is deleted
            while gReadingMemory.readingBuffer.relativetimestamps[lStart] <= gReadingMemory.lastRemoved do
                -- Increment Start index, decrement available readings
                lStart = math.mod(lStart, gReadingMemory.bufferSize)+1
                lReadingsAvail = lReadingsAvail-1
                -- If there are no non-removed readings
                if lStart == gReadingMemory.readingBuffer.startindex then
                    gErrorQueue.Add(-222)
                    return
                end
            end
            if lNumReadings > lReadingsAvail then
                gErrorQueue.Add(-222) -- Change to appropriate number
                return
            end
        end
        -- lStartIndex = gReadingMemory.readingBuffer.startindex
        print(FormatBuffer(lStart,lNumReadings, true))
    else
        gErrorQueue.Add(-222)
    end
end

------------------------------------------------------------------------------
--
-- SAMPle subsystem
--
-----------------------------------------------------------------------------

-- SAMPle:COUNt {<count>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SAMPLE"]["COUNT"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseSampleCount}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    if lParameters[1] >= gOperatingBoundaries.General.Sample_Count.min
    and lParameters[1] <= gOperatingBoundaries.General.Sample_Count.max then
        gInstrumentState.General.Sample_Count.value = lParameters[1]
        gTriggerModel.tmInitialized = false
    else
        gErrorQueue.Add(-222)
    end
end
-- SAMPle:COUNt? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseSampleCountKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local sampleCount = lParameters[1]
    if sampleCount == nil then
        sampleCount = gInstrumentState.General.Sample_Count.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(sampleCount, true)
        )
    )
end

------------------------------------------------------------------------------
--
-- [SENSe:]CURRent:AC subsystem
--
-----------------------------------------------------------------------------

-- [SENSe:]CURRent:AC:BANDwidth {<filter>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["AC"]["BANDWIDTH"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseACCBandwidth}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lDetectorBandwidth = lParameters[1]
    if lDetectorBandwidth > 300000
    or lDetectorBandwidth < gOperatingBoundaries.AC_Current.Bandwidth.min then
        gErrorQueue.Add(-222)
        return
    end
    if lDetectorBandwidth >= 300 then
        gInstrumentState.AC_Current.Bandwidth.value = gInstrumentAttributes.Detector_Bandwidth.HZ300
    elseif lDetectorBandwidth >= 30 then
        gInstrumentState.AC_Current.Bandwidth.value = gInstrumentAttributes.Detector_Bandwidth.HZ30
    elseif lDetectorBandwidth >= 3 then
        gInstrumentState.AC_Current.Bandwidth.value = gInstrumentAttributes.Detector_Bandwidth.HZ3
    end
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.AC_Current then
        gInstrumentState.AC_Current.Bandwidth.setter(gInstrumentState.AC_Current.Bandwidth.value.DMM_Enum)
    end
end
-- [SENSe:]CURRent:AC:BANDwidth? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseACCBandwidthKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lBandwidth = lParameters[1]
    if lParameters[1] == nil then
        lBandwidth = gInstrumentState.AC_Current.Bandwidth.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lBandwidth.shorthand, true)
        )
    )
end
-- [SENSe:]CURRent:AC:NULL[:STATe] {ON|1|OFF|0}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["AC"]["NULL"]["STATE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lNullState = lParameters[1]
    -- Update null state variable
    if lNullState == true then
        gInstrumentState.AC_Current.Null_State.value = gInstrumentAttributes.OnOff.ON
    elseif lNullState == false then
        gInstrumentState.AC_Current.Null_State.value = gInstrumentAttributes.OnOff.OFF
    end
    -- Set null state if active function
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.AC_Current then
        gInstrumentState.AC_Current.Null_State.setter(gInstrumentState.AC_Current.Null_State.value.shorthand)
    end
end
-- [SENSe:]CURRent:AC:NULL[:STATe]?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.AC_Current.Null_State.value.shorthand
        )
    )
end
-- [SENSe:]CURRent:AC:NULL:VALue {<value>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["AC"]["NULL"]["VALUE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseACCNullValue}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    CheckTerminals()
    local relLevel = lParameters[1]
    local lMeasFunc = gInstrumentState.Measure_Function
    local lNullVal  = gInstrumentState.AC_Current.Null_Value
    if relLevel <= gOperatingBoundaries.AC_Current.Null.max and
       relLevel >= gOperatingBoundaries.AC_Current.Null.min then
        lNullVal.value = relLevel
        if lMeasFunc.value == gInstrumentAttributes.Meas_Functions.AC_Current then
            lNullVal.setter(relLevel)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]CURRent:AC:NULL:VALue? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseACCNullValueKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintNullValue = lParameters[1]
    CheckTerminals()
    if lPrintNullValue == nil then
        lPrintNullValue = gInstrumentState.AC_Current.Null_Value.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintNullValue, true)
        )
    )
end
-- [SENSe:]CURRent:AC:NULL:VALue:AUTO {ON|1|OFF|0}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["AC"]["NULL"]["VALUE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    if lParameters[1] == true then
        gInstrumentState.AC_Current.Null_Value_Auto.value = gInstrumentAttributes.OnOff.ON
    elseif lParameters[1] == false then
        gInstrumentState.AC_Current.Null_Value_Auto.value = gInstrumentAttributes.OnOff.OFF
    end
end
-- [SENSe:]CURRent:AC:NULL:VALue:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.AC_Current.Null_Value_Auto.value.shorthand
        )
    )
end
-- [SENSe:]CURRent:AC:RANGe {<range>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["AC"]["RANGE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseACCRange}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    CheckTerminals()
    local lMeasureRange = lParameters[1]
    local lInstAutorange = gInstrumentState.AC_Current.Range_Auto
    local lInstRange = gInstrumentState.AC_Current.Range
    if gMathAbs(lMeasureRange) <= 1.10 * gOperatingBoundaries.AC_Current.Range.max then
        -- Turn autorange off
        lInstAutorange.value = gInstrumentAttributes.OnOff.OFF
        -- Find the appropriate range and set there
        for _, lRange in ipairs(gRangeTable.AC_Current) do
            if gMathAbs(lMeasureRange) <= 1.10 * lRange then
                lInstRange.value = lRange
                break
            end
        end
        if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.AC_Current then
            lInstAutorange.setter(lInstAutorange.value.DMM_Enum)
            gAccessors.mSetMeasureRange(lInstRange.value)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]CURRent:AC:RANGe? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseACCRangeKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintRange = lParameters[1]
    CheckTerminals()
    if lPrintRange == nil then
        lPrintRange = gInstrumentState.AC_Current.Range.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintRange, true)
        )
    )
end
-- [SENSe:]CURRent:AC:RANGe:AUTO {OFF|ON|ONCE}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["AC"]["RANGE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseAutoOnceKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lAutorange = lParameters[1]
    local lInstAutorange = gInstrumentState.AC_Current.Range_Auto
    if lAutorange == "ONCE" then
        -- Turn autorange on
        lInstAutorange.setter(gInstrumentAttributes.OnOff.ON.shorthand)
        -- Store some measurement parameters to reset
        local lMeasCount = gAccessors.mGetMeasureCount()
        local lMeasFunc = gAccessors.mGetMeasureFunction()
        -- Take a single measurement to set
        gAccessors.mSetMeasureCount(1)
        gAccessors.mSetMeasureFunction(gInstrumentAttributes.Meas_Functions.AC_Current.DMM_Enum)
        gMeasure.read()
        gInstrumentState.AC_Current.Range.value = gAccessors.mGetMeasureRange()
        gAccessors.mSetMeasureCount(lMeasCount)
        gAccessors.mSetMeasureFunction(lMeasFunc)
        lAutorange = false
    end
    if lAutorange == true then
        lInstAutorange.value = gInstrumentAttributes.OnOff.ON
    elseif lAutorange == false then
        lInstAutorange.value = gInstrumentAttributes.OnOff.OFF
    end
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.AC_Current then
        lInstAutorange.setter(lInstAutorange.value.DMM_Enum)
    end
end
-- [SENSe:]CURRent:AC:RANGe:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.AC_Current.Range_Auto.value.shorthand
        )
    )
end
-- [SENSe:]CURRent:AC:TERMinals?
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["AC"]["TERMINALS"]
gCurrentRoot.mQuery.mExecute = function()
    print(
        CheckTerminals()
    )
end

------------------------------------------------------------------------------
--
-- [SENSe:]CURRent:DC subsystem
--
-----------------------------------------------------------------------------

-- [SENSe:]CURRent:DC:NULL[:STATe] {ON|1|OFF|0}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["DC"]["NULL"]["STATE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    -- Update null state variable
    local lNullState = lParameters[1]
    if lNullState == true then
        gInstrumentState.DC_Current.Null_State.value = gInstrumentAttributes.OnOff.ON
    elseif lNullState == false then
        gInstrumentState.DC_Current.Null_State.value = gInstrumentAttributes.OnOff.OFF
    end
    -- Set null state if active function
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.DC_Current then
        gInstrumentState.DC_Current.Null_State.setter(gInstrumentState.DC_Current.Null_State.value.shorthand)
    end
end
-- [SENSe:]CURRent:DC:NULL[:STATe]?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.DC_Current.Null_State.value.shorthand
        )
    )
end
--[SENSe:]CURRent:DC:NULL:VALue {<value>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["DC"]["NULL"]["VALUE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseDCCNullValue}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    CheckTerminals()
    local relLevel  = lParameters[1]
    local lMeasFunc = gInstrumentState.Measure_Function
    local lNullVal  = gInstrumentState.DC_Current.Null_Value
    if relLevel <= gOperatingBoundaries.DC_Current.Null.max and
       relLevel >= gOperatingBoundaries.DC_Current.Null.min then
        lNullVal.value = relLevel
        if lMeasFunc.value == gInstrumentAttributes.Meas_Functions.DC_Current then
            lNullVal.setter(relLevel)
        end
    else
        gErrorQueue.Add(-222)
    end    
end
-- [SENSe:]CURRent:DC:NULL:VALue? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseDCCNullValueKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintNullValue = lParameters[1]
    CheckTerminals()
    if lPrintNullValue == nil then
        lPrintNullValue = gInstrumentState.DC_Current.Null_Value.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintNullValue, true)
        )
    )
end
-- [SENSe:]CURRent:DC:NULL:VALue:AUTO {ON|1|OFF|0}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["DC"]["NULL"]["VALUE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    if lParameters[1] == true then
        gInstrumentState.DC_Current.Null_Value_Auto.value = gInstrumentAttributes.OnOff.ON
    elseif lParameters[1] == false then
        gInstrumentState.DC_Current.Null_Value_Auto.value = gInstrumentAttributes.OnOff.OFF
    end
end
-- [SENSe:]CURRent:DC:NULL:VALue:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.DC_Current.Null_Value_Auto.value.shorthand
        )
    )
end
-- [SENSe:]CURRent:DC:RANGe {<range>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["DC"]["RANGE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseDCCRange}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    CheckTerminals()
    local lMeasureRange = lParameters[1]
    local lInstAutorange = gInstrumentState.DC_Current.Range_Auto
    local lInstRange = gInstrumentState.DC_Current.Range
    if gMathAbs(lMeasureRange) <= 1.10 * gOperatingBoundaries.DC_Current.Range.max then
        -- Turn autorange off
        lInstAutorange.value = gInstrumentAttributes.OnOff.OFF
        -- Find the appropriate range and set there
        for _, lRange in ipairs(gRangeTable.DC_Current) do
            if gMathAbs(lMeasureRange) <= 1.10 * lRange then
                lInstRange.value = lRange
                break
            end
        end
        if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.DC_Current then
            lInstAutorange.setter(lInstAutorange.value.DMM_Enum)
            lInstRange.setter(lInstRange.value)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]CURRent:DC:RANGe? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseDCCRangeKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintRange = lParameters[1]
    CheckTerminals()
    if lPrintRange == nil then
        lPrintRange = gInstrumentState.DC_Current.Range.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintRange, true)
        )
    )
end
-- [SENSe:]CURRent:DC:RANGe:AUTO {OFF|ON|ONCE}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["DC"]["RANGE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseAutoOnceKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lAutorange = lParameters[1]
    local lInstAutorange = gInstrumentState.DC_Current.Range_Auto
    if lAutorange == "ONCE" then
        -- Turn autorange on
        lInstAutorange.setter(gInstrumentAttributes.OnOff.ON.shorthand)
        -- Store some measurement parameters to reset
        local lMeasCount = gAccessors.mGetMeasureCount()
        local lMeasFunc = gAccessors.mGetMeasureFunction()
        -- Take a single measurement to set
        gAccessors.mSetMeasureCount(1)
        gAccessors.mSetMeasureFunction(gInstrumentAttributes.Meas_Functions.DC_Current.DMM_Enum)
        gMeasure.read()
        gInstrumentState.DC_Current.Range.value = gAccessors.mGetMeasureRange()
        gAccessors.mSetMeasureCount(lMeasCount)
        gAccessors.mSetMeasureFunction(lMeasFunc)
        lAutorange = false
    end
    if lAutorange == true then
        lInstAutorange.value = gInstrumentAttributes.OnOff.ON
    elseif lAutorange == false then
        lInstAutorange.value = gInstrumentAttributes.OnOff.OFF
    end
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.DC_Current then
        lInstAutorange.setter(lInstAutorange.value.DMM_Enum)
    end
end
-- [SENSe:]CURRent:DC:RANGe:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.DC_Current.Range_Auto.value.shorthand
        )
    )
end
-- [SENSe:]CURRent[:DC]:NPLC {<PLC>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["NPLC"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseNPLC}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lNPLC = lParameters[1]
    if lNPLC <= gOperatingBoundaries.General.Nplc.max 
    and lNPLC >= gOperatingBoundaries.General.Nplc.min then
        gInstrumentState.DC_Current.NPLC.value = lNPLC
        if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.DC_Current then
            gInstrumentState.DC_Current.NPLC.setter(lNPLC)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]CURRent[:DC]:NPLC? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseNPLCKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lNPLC = lParameters[1]
    if lParameters[1] == nil then
        lNPLC = gInstrumentState.DC_Current.NPLC.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lNPLC, true)
        )
    )
end
-- [SENSe:]CURRent:DC:TERMinals?
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["DC"]["TERMINALS"]
gCurrentRoot.mQuery.mExecute = function()
    print(
        CheckTerminals()
    )
end
-- [SENSe:]CURRent[:DC]:ZERO:AUTO {OFF|ON|ONCE}
gCurrentRoot = gCommandTree["SENSE"]["CURRENT"]["ZERO"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseAutoOnceKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lAutoZero = lParameters[1]
    local lInstZeroAuto = gInstrumentState.DC_Current.Zero_Auto
    local lInstFunction = gInstrumentState.Measure_Function
    if lAutoZero == true then
        lInstZeroAuto.value = gInstrumentAttributes.OnOff.ON
    elseif lAutoZero == false then
        lInstZeroAuto.value = gInstrumentAttributes.OnOff.OFF
    elseif lAutoZero == "ONCE" then
        if lInstFunction.value == gInstrumentAttributes.Meas_Functions.DC_Current then
            gMeasure.autozero.once()
        end
        lInstZeroAuto.value = gInstrumentAttributes.OnOff.OFF
    end
    if lInstFunction.value == gInstrumentAttributes.Meas_Functions.DC_Current then
        lInstZeroAuto.setter(lInstZeroAuto.value.DMM_Enum)
    end
end
-- [SENSe:]CURRent[:DC]:ZERO:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.DC_Current.Zero_Auto.value.shorthand
        )
    )
end

------------------------------------------------------------------------------
--
-- [SENSe:]FRESistance subsystem
--
-----------------------------------------------------------------------------

-- [SENSe:]FRESistance:RANGe {<range>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["FRESISTANCE"]["RANGE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseFResRange}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lMeasureRange = lParameters[1]
    local lInstAutorange = gInstrumentState.FResistance.Range_Auto
    local lInstRange = gInstrumentState.FResistance.Range
    if gMathAbs(lMeasureRange) <= 1.10 * gOperatingBoundaries.FResistance.Range.max then
        -- Turn autorange off
        lInstAutorange.value = gInstrumentAttributes.OnOff.OFF
        -- Find the appropriate range and set there
        for _, lRange in ipairs(gRangeTable.FResistance) do
            if gMathAbs(lMeasureRange) <= 1.10 * lRange then
                lInstRange.value = lRange
                break
            end
        end
        if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.FResistance then
            lInstAutorange.setter(lInstAutorange.value.DMM_Enum)
            gAccessors.mSetMeasureRange(lInstRange.value)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]FRESistance:RANGe? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseFResRangeKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintRange = lParameters[1]
    if lPrintRange == nil then
        lPrintRange = gInstrumentState.FResistance.Range.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintRange, true)
        )
    )
end

------------------------------------------------------------------------------
--
-- [SENSe:]FUNCtion subsystem
--
-----------------------------------------------------------------------------

-- [SENSe:]FUNCtion[:ON] "<function>"
gCurrentRoot = gCommandTree["SENSE"]["FUNCTION"]["ON"]
gCurrentRoot.mCommand.mParameters = 
{
    {
        mParse = gParserTable.ParseParameterNameString,
        mNames =
        {
            ["CAPACITANCE"]     = gInstrumentAttributes.Meas_Functions.Capacitance,
            ["CAP"]             = gInstrumentAttributes.Meas_Functions.Capacitance,
            
            ["CONTINUITY"]      = gInstrumentAttributes.Meas_Functions.Continuity,
            ["CONT"]            = gInstrumentAttributes.Meas_Functions.Continuity,
            
            ["CURRENT:AC"]      = gInstrumentAttributes.Meas_Functions.AC_Current,
            ["CURR:AC"]         = gInstrumentAttributes.Meas_Functions.AC_Current,
            
            ["CURRENT:DC"]      = gInstrumentAttributes.Meas_Functions.DC_Current,
            ["CURR:DC"]         = gInstrumentAttributes.Meas_Functions.DC_Current,
            ["CURRENT"]         = gInstrumentAttributes.Meas_Functions.DC_Current,
            ["CURR"]            = gInstrumentAttributes.Meas_Functions.DC_Current,
            
            ["DIODE"]           = gInstrumentAttributes.Meas_Functions.DIODE,
            ["DIOD"]            = gInstrumentAttributes.Meas_Functions.DIODE,

            ["FREQUENCY"]       = gInstrumentAttributes.Meas_Functions.Frequency,
            ["FREQ"]            = gInstrumentAttributes.Meas_Functions.Frequency,

            ["FRESISTANCE"]     = gInstrumentAttributes.Meas_Functions.FResistance,
            ["FRES"]            = gInstrumentAttributes.Meas_Functions.FResistance,

            ["PERIOD"]          = gInstrumentAttributes.Meas_Functions.Period,
            ["PER"]             = gInstrumentAttributes.Meas_Functions.Period,

            ["RESISTANCE"]      = gInstrumentAttributes.Meas_Functions.Resistance,
            ["RES"]             = gInstrumentAttributes.Meas_Functions.Resistance,

            ["TEMPERATURE"]     = gInstrumentAttributes.Meas_Functions.Temperature,
            ["TEMP"]            = gInstrumentAttributes.Meas_Functions.Temperature,

            ["VOLTAGE:AC"]      = gInstrumentAttributes.Meas_Functions.AC_Voltage,
            ["VOLT:AC"]         = gInstrumentAttributes.Meas_Functions.AC_Voltage,

            ["VOLTAGE:DC"]      = gInstrumentAttributes.Meas_Functions.DC_Voltage,
            ["VOLT:DC"]         = gInstrumentAttributes.Meas_Functions.DC_Voltage,
            ["VOLTAGE"]         = gInstrumentAttributes.Meas_Functions.DC_Voltage,
            ["VOLT"]            = gInstrumentAttributes.Meas_Functions.DC_Voltage,

            ["VOLTAGE:DC:RATIO"]    = gInstrumentAttributes.Meas_Functions.Ratio,
            ["VOLT:DC:RATIO"]       = gInstrumentAttributes.Meas_Functions.Ratio,
            ["VOLTAGE:RATIO"]       = gInstrumentAttributes.Meas_Functions.Ratio,
            ["VOLT:RATIO"]          = gInstrumentAttributes.Meas_Functions.Ratio,
            ["VOLTAGE:DC:RAT"]      = gInstrumentAttributes.Meas_Functions.Ratio,
            ["VOLT:DC:RAT"]         = gInstrumentAttributes.Meas_Functions.Ratio,
            ["VOLTAGE:RAT"]         = gInstrumentAttributes.Meas_Functions.Ratio,
            ["VOLT:RAT"]            = gInstrumentAttributes.Meas_Functions.Ratio,
        }
    }
}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lFunction = lParameters[1]
    gReadingMemory.reset()
    -- Set instrument to function configuration
    ChangeMeasFunction(lFunction)
end
-- [SENSe:]FUNCtion[:ON]?
gCurrentRoot.mQuery.mExecute = function()
    print(
        gInstrumentState.Measure_Function.value.shorthand
    )
end

------------------------------------------------------------------------------
--
-- [SENSe:]RESistance subsystem
--
-----------------------------------------------------------------------------

-- [SENSe:]:RESistance:NPLC {<PLCs>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["RESISTANCE"]["NPLC"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseNPLC}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lNPLC = lParameters[1]
    if lNPLC <= gOperatingBoundaries.General.Nplc.max 
    and lNPLC >= gOperatingBoundaries.General.Nplc.min then
        gInstrumentState.Resistance.NPLC.value = lNPLC
        if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.Resistance or
        gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.FResistancethen then
            gInstrumentState.Resistance.NPLC.setter(lNPLC)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]RESistance:NPLC? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseNPLCKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lNPLC = lParameters[1]
    if lParameters[1] == nil then
        lNPLC = gInstrumentState.Resistance.NPLC.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lNPLC, true)
        )
    )
end
-- [SENSe:]RESistance:NULL[:STATe] {OFF|ON}
gCurrentRoot = gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["STATE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lNullState = lParameters[1]
    -- Update null state variable
    if lNullState == true then
        gInstrumentState.Resistance.Null_State.value = gInstrumentAttributes.OnOff.ON
    elseif lNullState == false then
        gInstrumentState.Resistance.Null_State.value = gInstrumentAttributes.OnOff.OFF
    end
    -- Set null state if active function
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.Resistance or
    gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.FResistance then
        gInstrumentState.Resistance.Null_State.setter(gInstrumentState.Resistance.Null_State.value.shorthand)
    end
end
-- [SENSe:]RESistance:NULL[:STATe]?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.Resistance.Null_State.value.shorthand
        )
    )
end
-- [SENSe:]RESistance:NULL:VALue {<value>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["VALUE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseResNullValue}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local relLevel = lParameters[1]
    local lMeasFunc = gInstrumentState.Measure_Function
    local lNullVal  = gInstrumentState.Resistance.Null_Value
    if relLevel <= gOperatingBoundaries.Resistance.Null.max and
       relLevel >= gOperatingBoundaries.Resistance.Null.min then
        lNullVal.value = relLevel
        if lMeasFunc.value == gInstrumentAttributes.Meas_Functions.Resistance or
        lMeasFunc.value == gInstrumentAttributes.Meas_Functions.FResistance then
            lNullVal.setter(relLevel)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]RESistance:NULL:VALue? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseResNullValueKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintNullValue = lParameters[1]
    if lPrintNullValue == nil then
        lPrintNullValue = gInstrumentState.Resistance.Null_Value.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintNullValue, true)
        )
    )
end
-- [SENSe:]RESistance:NULL:VALue:AUTO {OFF|ON}
gCurrentRoot = gCommandTree["SENSE"]["RESISTANCE"]["NULL"]["VALUE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    if lParameters[1] == true then
        gInstrumentState.Resistance.Null_Value_Auto.value = gInstrumentAttributes.OnOff.ON
    elseif lParameters[1] == false then
        gInstrumentState.Resistance.Null_Value_Auto.value = gInstrumentAttributes.OnOff.OFF
    end
end
-- [SENSe:]RESistance:NULL:VALue:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.Resistance.Null_Value_Auto.value.shorthand
        )
    )
end
-- This is unique to 2W
-- [SENSe:]RESistance:RANGe {<range>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["RESISTANCE"]["RANGE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseResRange}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lMeasureRange = lParameters[1]
    local lInstAutorange = gInstrumentState.Resistance.Range_Auto
    local lInstRange = gInstrumentState.Resistance.Range
    if gMathAbs(lMeasureRange) <= 1.10 * gOperatingBoundaries.Resistance.Range.max then
        -- Turn autorange off
        lInstAutorange.value = gInstrumentAttributes.OnOff.OFF
        -- Find the appropriate range and set there
        for _, lRange in ipairs(gRangeTable.Resistance) do
            if gMathAbs(lMeasureRange) <= 1.10 * lRange then
                lInstRange.value = lRange
                break
            end
        end
        if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.Resistance then
            lInstAutorange.setter(lInstAutorange.value.DMM_Enum)
            gAccessors.mSetMeasureRange(lInstRange.value)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]RESistance:RANGe? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseResRangeKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintRange = lParameters[1]
    if lPrintRange == nil then
        lPrintRange = gInstrumentState.Resistance.Range.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintRange, true)
        )
    )
end
-- [SENSe:]RESistance:RANGe:AUTO {OFF|ON|ONCE}
gCurrentRoot = gCommandTree["SENSE"]["RESISTANCE"]["RANGE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseAutoOnceKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lAutorange = lParameters[1]
    local lInstAutorange = gInstrumentState.Resistance.Range_Auto
    if lAutorange == "ONCE" then
        -- Turn autorange on
        lInstAutorange.setter(gInstrumentAttributes.OnOff.ON.shorthand)
        -- Store some measurement parameters to reset
        local lMeasCount = gAccessors.mGetMeasureCount()
        local lMeasFunc = gAccessors.mGetMeasureFunction()
        -- Take a single measurement to set
        gAccessors.mSetMeasureCount(1)
        gAccessors.mSetMeasureFunction(gInstrumentAttributes.Meas_Functions.Resistance.DMM_Enum)
        gMeasure.read()
        gInstrumentState.Resistance.Range.value = gAccessors.mGetMeasureRange()
        gAccessors.mSetMeasureCount(lMeasCount)
        gAccessors.mSetMeasureFunction(lMeasFunc)
        lAutorange = false
    end
    if lAutorange == true then
        lInstAutorange.value = gInstrumentAttributes.OnOff.ON
    elseif lAutorange == false then
        lInstAutorange.value = gInstrumentAttributes.OnOff.OFF
    end
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.Resistance or
    gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.FResistance then
        lInstAutorange.setter(lInstAutorange.value.DMM_Enum)
    end
end
-- [SENSe:]RESistance:RANGe:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.Resistance.Range_Auto.value.shorthand
        )
    )
end
-- This is unique to 2W
-- [SENSe:]RESistance:ZERO:AUTO {OFF|ON|ONCE}
gCurrentRoot = gCommandTree["SENSE"]["RESISTANCE"]["ZERO"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseAutoOnceKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lAutoZero = lParameters[1]
    local lInstZeroAuto = gInstrumentState.Resistance.Zero_Auto
    local lInstFunction = gInstrumentState.Measure_Function
    if lAutoZero == true then
        lInstZeroAuto.value = gInstrumentAttributes.OnOff.ON
    elseif lAutoZero == false then
        lInstZeroAuto.value = gInstrumentAttributes.OnOff.OFF
    elseif lAutoZero == "ONCE" then
        if lInstFunction.value == gInstrumentAttributes.Meas_Functions.Resistance then
            gMeasure.autozero.once()
        end
        lInstZeroAuto.value = gInstrumentAttributes.OnOff.OFF
    end
    if lInstFunction.value == gInstrumentAttributes.Meas_Functions.Resistance then
        lInstZeroAuto.setter(lInstZeroAuto.value.DMM_Enum)
    end
end
-- [SENSe:]RESistance:ZERO:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.DC_Voltage.Zero_Auto.value.shorthand
        )
    )
end

------------------------------------------------------------------------------
--
-- [SENSe:]VOLTage:AC subsystem
--
-----------------------------------------------------------------------------

-- [SENSe:]VOLTage:AC:BANDwidth {<filter>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["BANDWIDTH"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseACVBandwidth}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lDetectorBandwidth = lParameters[1]
    if lDetectorBandwidth > 300000
    or lDetectorBandwidth < gOperatingBoundaries.AC_Voltage.Bandwidth.min then
        gErrorQueue.Add(-222)
        return
    end
    if lDetectorBandwidth >= 300 then
        gInstrumentState.AC_Voltage.Bandwidth.value = gInstrumentAttributes.Detector_Bandwidth.HZ300
    elseif lDetectorBandwidth >= 30 then
        gInstrumentState.AC_Voltage.Bandwidth.value = gInstrumentAttributes.Detector_Bandwidth.HZ30
    elseif lDetectorBandwidth >= 3 then
        gInstrumentState.AC_Voltage.Bandwidth.value = gInstrumentAttributes.Detector_Bandwidth.HZ3
    end
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.AC_Voltage then
        gInstrumentState.AC_Voltage.Bandwidth.setter(gInstrumentState.AC_Voltage.Bandwidth.value.DMM_Enum)
    end
end
-- [SENSe:]VOLTage:AC:BANDwidth? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseACVBandwidthKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lBandwidth = lParameters[1]
    if lParameters[1] == nil then
        lBandwidth = gInstrumentState.AC_Voltage.Bandwidth.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lBandwidth.shorthand, true)
        )
    )
end
-- [SENSe:]VOLTage:AC:NULL[:STATe] {ON|1|OFF|0}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"]["STATE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lNullState = lParameters[1]
    -- Update null state variable
    if lNullState == true then
        gInstrumentState.AC_Voltage.Null_State.value = gInstrumentAttributes.OnOff.ON
    elseif lNullState == false then
        gInstrumentState.AC_Voltage.Null_State.value = gInstrumentAttributes.OnOff.OFF
    end
    -- Set null state if active function
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.AC_Voltage then
        gInstrumentState.AC_Voltage.Null_State.setter(gInstrumentState.AC_Voltage.Null_State.value.shorthand)
    end
end
-- [SENSe:]VOLTage:AC:NULL[:STATe]?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.AC_Voltage.Null_State.value.shorthand
        )
    )
end
-- [SENSe:]VOLTage:AC:NULL:VALue {<value>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"]["VALUE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseACVNullValue}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local relLevel = lParameters[1]
    local lMeasFunc = gInstrumentState.Measure_Function
    local lNullVal  = gInstrumentState.AC_Voltage.Null_Value
    if relLevel <= gOperatingBoundaries.AC_Voltage.Null.max and
       relLevel >= gOperatingBoundaries.AC_Voltage.Null.min then
        lNullVal.value = relLevel
        if lMeasFunc.value == gInstrumentAttributes.Meas_Functions.AC_Voltage then
            lNullVal.setter(relLevel)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]VOLTage:AC:NULL:VALue? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseACVNullValueKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintNullValue = lParameters[1]
    if lPrintNullValue == nil then
        lPrintNullValue = gInstrumentState.AC_Voltage.Null_Value.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintNullValue, true)
        )
    )
end
-- [SENSe:]VOLTage:AC:NULL:VALue:AUTO {ON|1|OFF|0}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"]["VALUE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    if lParameters[1] == true then
        gInstrumentState.AC_Voltage.Null_Value_Auto.value = gInstrumentAttributes.OnOff.ON
    elseif lParameters[1] == false then
        gInstrumentState.AC_Voltage.Null_Value_Auto.value = gInstrumentAttributes.OnOff.OFF
    end
end
-- [SENSe:]VOLTage:AC:NULL:VALue:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.AC_Voltage.Null_Value_Auto.value.shorthand
        )
    )
end
-- [SENSe:]VOLTage:AC:RANGe {<range>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["RANGE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseACVoltageRange}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lMeasureRange = lParameters[1]
    local lInstAutorange = gInstrumentState.AC_Voltage.Range_Auto
    local lInstRange = gInstrumentState.AC_Voltage.Range
    if gMathAbs(lMeasureRange) <= 1.10 * gOperatingBoundaries.AC_Voltage.Range.max then
        -- Turn autorange off
        lInstAutorange.value = gInstrumentAttributes.OnOff.OFF
        -- Find the appropriate range and set there
        for _, lRange in ipairs(gRangeTable.AC_Voltage) do
            if gMathAbs(lMeasureRange) <= 1.10 * lRange then
                lInstRange.value = lRange
                break
            end
        end
        if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.AC_Voltage then
            lInstAutorange.setter(lInstAutorange.value.DMM_Enum)
            gAccessors.mSetMeasureRange(lInstRange.value)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]VOLTage:AC:RANGe? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseACVoltageRangeKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintRange = lParameters[1]
    if lPrintRange == nil then
        lPrintRange = gInstrumentState.AC_Voltage.Range.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintRange, true)
        )
    )
end
-- [SENSe:]VOLTage:AC:RANGe:AUTO {OFF|ON|ONCE}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["RANGE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseAutoOnceKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lAutorange = lParameters[1]
    local lInstAutorange = gInstrumentState.AC_Voltage.Range_Auto
    if lAutorange == "ONCE" then
        -- Turn autorange on
        lInstAutorange.setter(gInstrumentAttributes.OnOff.ON.shorthand)
        -- Store some measurement parameters to reset
        local lMeasCount = gAccessors.mGetMeasureCount()
        local lMeasFunc = gAccessors.mGetMeasureFunction()
        -- Take a single measurement to set
        gAccessors.mSetMeasureCount(1)
        gAccessors.mSetMeasureFunction(gInstrumentAttributes.Meas_Functions.AC_Voltage.DMM_Enum)
        gMeasure.read()
        gInstrumentState.AC_Voltage.Range.value = gAccessors.mGetMeasureRange()
        gAccessors.mSetMeasureCount(lMeasCount)
        gAccessors.mSetMeasureFunction(lMeasFunc)
        lAutorange = false
    end
    if lAutorange == true then
        lInstAutorange.value = gInstrumentAttributes.OnOff.ON
    elseif lAutorange == false then
        lInstAutorange.value = gInstrumentAttributes.OnOff.OFF
    end
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.AC_Voltage then
        lInstAutorange.setter(lInstAutorange.value.DMM_Enum)
    end
end
-- [SENSe:]VOLTage:AC:RANGe:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.AC_Voltage.Range_Auto.value.shorthand
        )
    )
end

------------------------------------------------------------------------------
--
-- [SENSe:]VOLTage:DC subsystem
--
-----------------------------------------------------------------------------

-- [SENSe:]VOLTage:DC:NULL[:STATe] {ON|1|OFF|0}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"]["STATE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    -- Update null state variable
    local lNullState = lParameters[1]
    if lNullState == true then
        gInstrumentState.DC_Voltage.Null_State.value = gInstrumentAttributes.OnOff.ON
    elseif lNullState == false then
        gInstrumentState.DC_Voltage.Null_State.value = gInstrumentAttributes.OnOff.OFF
    end
    -- Set null state if active function
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.DC_Voltage 
    or gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.Ratio then
        gInstrumentState.DC_Voltage.Null_State.setter(gInstrumentState.DC_Voltage.Null_State.value.shorthand)
    end
end
-- [SENSe:]VOLTage:DC:NULL[:STATe]?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.DC_Voltage.Null_State.value.shorthand
        )
    )
end
--[SENSe:]VOLTage:DC:NULL:VALue {<value>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"]["VALUE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseDCVNullValue}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local relLevel  = lParameters[1]
    local lMeasFunc = gInstrumentState.Measure_Function
    local lNullVal  = gInstrumentState.DC_Voltage.Null_Value
    if relLevel <= gOperatingBoundaries.DC_Voltage.Null.max and
       relLevel >= gOperatingBoundaries.DC_Voltage.Null.min then
        lNullVal.value = relLevel
        if lMeasFunc.value == gInstrumentAttributes.Meas_Functions.DC_Voltage 
        or lMeasFunc.value == gInstrumentAttributes.Meas_Functions.Ratio then
            lNullVal.setter(relLevel)
        end
    else
        gErrorQueue.Add(-222)
    end    
end
-- [SENSe:]VOLTage:DC:NULL:VALue? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseDCVNullValueKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintNullValue = lParameters[1]
    if lPrintNullValue == nil then
        lPrintNullValue = gInstrumentState.DC_Voltage.Null_Value.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintNullValue, true)
        )
    )
end
-- [SENSe:]VOLTage:DC:NULL:VALue:AUTO {ON|1|OFF|0}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"]["VALUE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    if lParameters[1] == true then
        gInstrumentState.DC_Voltage.Null_Value_Auto.value = gInstrumentAttributes.OnOff.ON
    elseif lParameters[1] == false then
        gInstrumentState.DC_Voltage.Null_Value_Auto.value = gInstrumentAttributes.OnOff.OFF
    end
end
-- [SENSe:]VOLTage:DC:NULL:VALue:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.DC_Voltage.Null_Value_Auto.value.shorthand
        )
    )
end
-- [SENSe:]VOLTage:DC:RANGe {<range>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseDCVoltageRange}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lMeasureRange = lParameters[1]
    local lInstAutorange = gInstrumentState.DC_Voltage.Range_Auto
    local lInstRange = gInstrumentState.DC_Voltage.Range
    if gMathAbs(lMeasureRange) <= 1.10 * gOperatingBoundaries.DC_Voltage.Range.max then
        -- Turn autorange off
        lInstAutorange.value = gInstrumentAttributes.OnOff.OFF
        -- Find the appropriate range and set there
        for _, lRange in ipairs(gRangeTable.DC_Voltage) do
            if gMathAbs(lMeasureRange) <= 1.10 * lRange then
                lInstRange.value = lRange
                break
            end
        end
        if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.DC_Voltage 
        or gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.Ratio then
            lInstAutorange.setter(lInstAutorange.value.DMM_Enum)
            lInstRange.setter(lInstRange.value)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]VOLTage:DC:RANGe? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseDCVoltageRangeKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintRange = lParameters[1]
    if lPrintRange == nil then
        lPrintRange = gInstrumentState.DC_Voltage.Range.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintRange, true)
        )
    )
end
-- [SENSe:]VOLTage:DC:RANGe:AUTO {OFF|ON|ONCE}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseAutoOnceKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lAutorange = lParameters[1]
    local lInstAutorange = gInstrumentState.DC_Voltage.Range_Auto
    if lAutorange == "ONCE" then
        -- Turn autorange on
        lInstAutorange.setter(gInstrumentAttributes.OnOff.ON.shorthand)
        -- Store some measurement parameters to reset
        local lMeasCount = gAccessors.mGetMeasureCount()
        local lMeasFunc = gAccessors.mGetMeasureFunction()
        -- Take a single measurement to set
        gAccessors.mSetMeasureCount(1)
        gAccessors.mSetMeasureFunction(gInstrumentAttributes.Meas_Functions.DC_Voltage.DMM_Enum)
        gMeasure.read()
        gInstrumentState.DC_Voltage.Range.value = gAccessors.mGetMeasureRange()
        gAccessors.mSetMeasureCount(lMeasCount)
        gAccessors.mSetMeasureFunction(lMeasFunc)
        lAutorange = false
    end
    if lAutorange == true then
        lInstAutorange.value = gInstrumentAttributes.OnOff.ON
    elseif lAutorange == false then
        lInstAutorange.value = gInstrumentAttributes.OnOff.OFF
    end
    if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.DC_Voltage 
    or gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.Ratio then
        lInstAutorange.setter(lInstAutorange.value.DMM_Enum)
    end
end
-- [SENSe:]VOLTage:DC:RANGe:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.DC_Voltage.Range_Auto.value.shorthand
        )
    )
end
-- [SENSe:]VOLTage[:DC]:NPLC {<PLC>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["NPLC"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseNPLC}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lNPLC = lParameters[1]
    if lNPLC <= gOperatingBoundaries.General.Nplc.max 
    and lNPLC >= gOperatingBoundaries.General.Nplc.min then
        gInstrumentState.DC_Voltage.NPLC.value = lNPLC
        if gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.DC_Voltage 
        or gInstrumentState.Measure_Function.value == gInstrumentAttributes.Meas_Functions.Ratio then
            gInstrumentState.DC_Voltage.NPLC.setter(lNPLC)
        end
    else
        gErrorQueue.Add(-222)
    end
end
-- [SENSe:]VOLTage[:DC]:NPLC? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseNPLCKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lNPLC = lParameters[1]
    if lParameters[1] == nil then
        lNPLC = gInstrumentState.DC_Voltage.NPLC.value
    end
    print(
        string.format(
            "%s",
            FormatNumber(lNPLC, true)
        )
    )
end
-- [SENSe:]VOLTage[:DC]:ZERO:AUTO {OFF|ON|ONCE}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["ZERO"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseAutoOnceKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lAutoZero = lParameters[1]
    local lInstZeroAuto = gInstrumentState.DC_Voltage.Zero_Auto
    local lInstFunction = gInstrumentState.Measure_Function
    if lAutoZero == true then
        lInstZeroAuto.value = gInstrumentAttributes.OnOff.ON
    elseif lAutoZero == false then
        lInstZeroAuto.value = gInstrumentAttributes.OnOff.OFF
    elseif lAutoZero == "ONCE" then
        if lInstFunction.value == gInstrumentAttributes.Meas_Functions.DC_Voltage 
        or lInstFunction.value == gInstrumentAttributes.Meas_Functions.Ratio then
            gMeasure.autozero.once()
        end
        lInstZeroAuto.value = gInstrumentAttributes.OnOff.OFF
    end
    if lInstFunction.value == gInstrumentAttributes.Meas_Functions.DC_Voltage 
    or lInstFunction.value == gInstrumentAttributes.Meas_Functions.Ratio then
        lInstZeroAuto.setter(lInstZeroAuto.value.DMM_Enum)
    end
end
-- [SENSe:]VOLTage[:DC]:ZERO:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.DC_Voltage.Zero_Auto.value.shorthand
        )
    )
end

------------------------------------------------------------------------------
--
-- STATus subsystem
--
-----------------------------------------------------------------------------

--STATus:OPERation:CONDition?
gCurrentRoot = gCommandTree["STATUS"]["OPERATION"]["CONDITION"]
gCurrentRoot.mQuery.mExecute = function()
    print(operStatus.mCondition)
end
--STATus:OPERation:ENABle <enable_value>
gCurrentRoot = gCommandTree["STATUS"]["OPERATION"]["ENABLE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseInteger}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lEventEnable = lParameters[1]
    if lEventEnable >= 0 and lEventEnable <= 32768 then
        StatusModel.SetEnable(operStatus, lEventEnable)
    else
        gErrorQueue.Add(-222)
    end
end
--STATus:OPERation:ENABle?
gCurrentRoot.mQuery.mExecute = function()
    print(operStatus.mEventEnable)
end
--STATus:OPERation[:EVENt]?
gCurrentRoot = gCommandTree["STATUS"]["OPERATION"]["EVENT"]
gCurrentRoot.mQuery.mExecute = function()
    print(operStatus.mEvent)
    StatusModel.ClearEvent(operStatus)
end
--STATus:PRESet
gCurrentRoot = gCommandTree["STATUS"]["PRESET"]
gCurrentRoot.mCommand.mExecute = function()
    quesStatus.mEventEnable = 0
    operStatus.mEventEnable = 0
end
--STATus:QUEStionable:CONDition?
gCurrentRoot = gCommandTree["STATUS"]["QUESTIONABLE"]["CONDITION"]
gCurrentRoot.mQuery.mExecute = function()
    print(quesStatus.mCondition)
end
--STATus:QUEStionable:ENABle <enable_value>
gCurrentRoot = gCommandTree["STATUS"]["QUESTIONABLE"]["ENABLE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseInteger}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lEventEnable = lParameters[1]
    if lEventEnable >= 0 and lEventEnable <= 32768 then
        StatusModel.SetEnable(quesStatus, lEventEnable)
    end
end
--STATus:QUEStionable:ENABle?
gCurrentRoot.mQuery.mExecute = function()
    print(quesStatus.mEventEnable)
end
--STATus:QUEStionable[:EVENt]?
gCurrentRoot = gCommandTree["STATUS"]["QUESTIONABLE"]["ENABLE"]
gCurrentRoot.mQuery.mExecute = function()
    print(quesStatus.mEvent)
    StatusModel.ClearEvent(quesStatus)
end

------------------------------------------------------------------------------
--
-- TRIGger subsystem
--
-----------------------------------------------------------------------------

-- TRIGger:COUNt {<count>|MIN|MAX|DEF|INFinity}
gCurrentRoot = gCommandTree["TRIGGER"]["COUNT"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseTriggerCount}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lTriggerCount = lParameters[1]
    if lTriggerCount <= gOperatingBoundaries.General.Trigger_Count.max
    and lTriggerCount >= gOperatingBoundaries.General.Trigger_Count.min then
        gInstrumentState.General.Trigger_Count.value = lTriggerCount
        gTriggerModel.tmInitialized = false
    else
        gErrorQueue.Add(-222)
    end
end
-- TRIGger:COUNt? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = 
{
    {
        mParse = gParserTable.ParseParameterName,
        mOptional = true,
        mNames =
        {
            ["MIN"]         = gOperatingBoundaries.General.Trigger_Count.min,
            ["MINIMUM"]     = gOperatingBoundaries.General.Trigger_Count.min,
            ["MAX"]         = gOperatingBoundaries.General.Trigger_Count.max,
            ["MAXIMUM"]     = gOperatingBoundaries.General.Trigger_Count.max,
            ["DEF"]         = gOperatingBoundaries.General.Trigger_Count.def,
            ["DEFAULT"]     = gOperatingBoundaries.General.Trigger_Count.def,
        }
    }
}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lDelay = lParameters[1]
    if lDelay == nil then
        lDelay = gInstrumentState.General.Trigger_Count.value
    end
    print(FormatNumber(lDelay, true))
end
-- TRIGger:DELay {<seconds>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["TRIGGER"]["DELAY"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseTriggerDelay}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lDelay = lParameters[1]
    if lDelay <= gOperatingBoundaries.General.Trigger_Delay.max
    and lDelay >= gOperatingBoundaries.General.Trigger_Delay.min then
        gInstrumentState.General.Trigger_Delay_Auto.value = gInstrumentAttributes.Auto_Delay.OFF
        gInstrumentState.General.Trigger_Delay_Auto.setter(gInstrumentState.General.Trigger_Delay_Auto.value.DMM_Enum)
        gInstrumentState.General.Trigger_Delay.value = lDelay
        gTriggerModel.tmInitialized = false
    else
        gErrorQueue.Add(-222)
    end
end
-- TRIGger:DELay? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseTriggerDelayKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lDelay = lParameters[1]
    if lDelay == nil then
        lDelay = gInstrumentState.General.Trigger_Delay.value
    end
    print(FormatNumber(lDelay, true))
end
-- TRIGger:DELay:AUTO {OFF|ON}
gCurrentRoot = gCommandTree["TRIGGER"]["DELAY"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lDelayAuto = lParameters[1]
    if lDelayAuto == true then
        gInstrumentState.General.Trigger_Delay_Auto.value = gInstrumentAttributes.Auto_Delay.ON
    else
        gInstrumentState.General.Trigger_Delay_Auto.value = gInstrumentAttributes.Auto_Delay.OFF
    end
    gInstrumentState.General.Trigger_Delay_Auto.setter(gInstrumentState.General.Trigger_Delay_Auto.value.DMM_Enum)
    gTriggerModel.tmInitialized = false
end
-- TRIGger:DELay:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gInstrumentState.General.Trigger_Delay_Auto.value.shorthand
        )
    )
end
--TRIGger:SLOPe {POSitive|NEGative}
gCurrentRoot = gCommandTree["TRIGGER"]["SLOPE"]
gCurrentRoot.mCommand.mParameters = 
{
    {
        mParse = gParserTable.ParseParameterName,
        mNames =
        {
            ["POS"]         = "POS",
            ["POSITIVE"]    = "POS",
            ["NEG"]         = "NEG",
            ["NEGATIVE"]    = "NEG",
        }
    }
}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lSlope = lParameters[1]
    if lSlope == "POS" then
        gInstrumentState.General.Trigger_Slope.value = gInstrumentAttributes.Trigger_Slope.Positive
    else
        gInstrumentState.General.Trigger_Slope.value = gInstrumentAttributes.Trigger_Slope.Negative
    end
    gInstrumentState.General.Trigger_Slope.setter(gInstrumentState.General.Trigger_Slope.value.DMM_Enum)
end
--TRIGger:SLOPe?
gCurrentRoot.mQuery.mExecute = function()
    print(gInstrumentState.General.Trigger_Slope.value.shorthand)
end
--TRIGger:SOURce {IMMediate|EXTernal|BUS|INTernal}
gCurrentRoot = gCommandTree["TRIGGER"]["SOURCE"]
gCurrentRoot.mCommand.mParameters = 
{
    {
        mParse = gParserTable.ParseParameterName,
        mNames =
        {
            ["IMM"]         = "IMM",
            ["IMMEDIATE"]   = "IMM",
            ["EXT"]         = "EXT",
            ["EXTERNAL"]    = "EXT",
            ["BUS"]         = "BUS",
            ["INTERNAL"]    = "INT",
            ["INT"]         = "INT",
        }
    }
}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    gReadingMemory.reset()
    local lSource = lParameters[1]
    gInstrumentState.General.Trigger_Source.value = lSource
    gTriggerModel.tmInitialized = false
end
--TRIGger:SOURce?
gCurrentRoot.mQuery.mExecute = function(lParameters)
    print(gInstrumentState.General.Trigger_Source.value)
end

-- INITIALIZE HERE
gCurrentRoot = gCommandTree

Initialize34461A()

-- display.prompt(
--     display.BUTTONS_OK,
--     "Instrument emulation initialized"
-- )
-- beeper.beep(0.15, 680)

Engine34461A()

--endscript