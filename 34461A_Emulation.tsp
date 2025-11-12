--loadandrunscript 34461AEmulation

-- model/digio support
-- TODO simplify this, not needed now
local gModelSupport =
{
    ["DMM6500"] = {mFeatureDigio = true}
}

-- TODO May not need an array for this
local gDisplayVariables = {}
gDisplayVariables.mDisplayScreen = display.SCREEN_HOME
display.changescreen(display.SCREEN_USER_SWIPE)

-- Loading Message
display.clear()
if gModelSupport[localnode.model] then
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

local FwRev = localnode.version
local gAutoRunEnable = false
local gInitialized = false
local gDisplayErrors = true
local gErrorReadback = true
local gCommandTree
local gErrorQueue = {}

--[[BUFFER VARIABLES FOR MEASUREMENTS]]
--local gCurrentBuffer
--local gVoltageBuffer
--local gSMCurrentBuffer
--local gSMVoltageBuffer

-- Setter and getter functions 
local gAccessors = {}
local gRemoteComm = ki.remotecomm

local NullFunction = function () end

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

local gResponseValues =
{
    [true]  = "1",
    [false] = "0",
    [1]     = "1",
    [0]     = "0",
}

local gNonProgMnemonic  = "[^%a%d_]"
local gNonWhitespace    = "[^%s]"

local gNan = 9.91e37
local gInf = 9.90e37
local gEpsilon = 5e-7

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
-- Local variables used for better performance
--
--============================================================================

local gAscii = format.ASCII
local gMathAbs = math.abs
local gTypeDcl = gRemoteComm.types.DCL

local Print = gRemoteComm.partialprint

-- TODO Keep placing local variables here as needed
local gMeasure = dmm.measure
local gOn = dmm.ON
local gOff = dmm.OFF
local gRel = gMeasure.rel
-- USER MUST ENTER THIS
local gPLC = 60

local gRemoteCommStatus = gRemoteComm.status

-- TODO Keep placing getter/setter functions here
gAccessors.mSetMeasureFunction      = makesetter(gMeasure, "func")
gAccessors.mSetMeasureRange         = makesetter(gMeasure, "range")
gAccessors.mSetMeasureAutorange     = makesetter(gMeasure, "autorange")
gAccessors.mSetMeasureCount         = makesetter(gMeasure, "count")
gAccessors.mSetThermistor           = makesetter(gMeasure, "thermistor")
gAccessors.mSetThermocouple         = makesetter(gMeasure, "thermocouple")
gAccessors.mSetDetectorBandwidth    = makesetter(gMeasure, "detectorbandwidth")
gAccessors.mSetRelEnable            = makesetter(gRel, "enable")
gAccessors.mSetRelLevel             = makesetter(gRel, "level")
gAccessors.mSetMeasureNPLC          = makesetter(gMeasure, "nplc")
gAccessors.mSetAutozeroEnable       = makesetter(gMeasure.autozero, "enable")

gAccessors.mGetMeasureFunction      = makegetter(gMeasure, "func")
gAccessors.mGetMeasureRange         = makegetter(gMeasure, "range")
gAccessors.mGetMeasureAutorange     = makegetter(gMeasure, "autorange")
gAccessors.mGetMeasureCount         = makegetter(gMeasure, "count")
gAccessors.mGetThermistor           = makegetter(gMeasure, "thermistor")
gAccessors.mGetThermocouple         = makegetter(gMeasure, "thermocouple")
gAccessors.mGetDetectorBandwidth    = makegetter(gMeasure, "detectorbandwidth")
gAccessors.mGetRelEnable            = makegetter(gRel, "enable")
gAccessors.mGetRelLevel             = makegetter(gRel, "level")
gAccessors.mGetMeasureNPLC          = makegetter(gMeasure, "nplc")
gAccessors.mGetAutozeroEnable       = makegetter(gMeasure.autozero, "enable")

--============================================================================
--
-- Model specific tables
--
-- These tables store model specific range related information.
--
--============================================================================

local gPrintEnable = false

local gInstrumentAttributes =
{
    Meas_Functions =
    {
        DC_Voltage = 
        {
            shorthand = "VOLT",
            DMM_Enum = dmm.FUNC_DC_VOLTAGE
        },
        AC_Voltage = 
        {
            shorthand = "VOLT:AC",
            DMM_Enum = dmm.FUNC_AC_VOLTAGE
        },
        DC_Current = 
        {
            shorthand = "CURR",
            DMM_Enum = dmm.FUNC_DC_CURRENT
        },
        AC_Current = 
        {
            shorthand = "CURR:AC",
            DMM_Enum = dmm.FUNC_AC_CURRENT
        },
        Temperature = 
        {
            shorthand = "TEMP",
            DMM_Enum = dmm.FUNC_TEMPERATURE
        },
        Resistance = 
        {
            shorthand = "RES",
            DMM_Enum = dmm.FUNC_RESISTANCE
        },
        FW_Resistance = 
        {
            shorthand = "FRES",
            DMM_Enum = dmm.FUNC_4W_RESISTANCE
        },
        Diode = 
        {
            shorthand = "DIOD",
            DMM_Enum = dmm.FUNC_DIODE
        },
        Capacitance = 
        {
            shorthand = "CAP",
            DMM_Enum = dmm.FUNC_CAPACITANCE
        },
        Continuity = 
        {
            shorthand = "CONT",
            DMM_Enum = dmm.FUNC_CONTINUITY
        },
        Frequency = 
        {
            shorthand = "FREQ",
            DMM_Enum = dmm.FUNC_ACV_FREQUENCY
        },
        Period = 
        {
            shorthand = "PER",
            DMM_Enum = dmm.FUNC_ACV_PERIOD
        },
        Ratio = 
        {
            shorthand = "VOLT:RAT",
            DMM_Enum = dmm.FUNC_DCV_RATIO
        },
    },
    OnOff =
    {
        ON = {
            DMM_Enum = dmm.ON,
            shorthand = 1,
        },
        OFF = {
            DMM_Enum = dmm.OFF,
            shorthand = 0,
        },
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
}

local gRangeTable =
{
    DC_Voltage      = {100e-3, 1, 10, 100, 1000},
    AC_Voltage      = {100e-3, 1, 10, 100, 750},
    DC_Current      = {10e-6, 100e-6, 1e-3, 10e-3, 100e-3, 1, 3, 10},
    AC_Current      = {1e-3, 10e-3, 100e-3, 1, 3, 10},
    Resistance      = {10, 100, 1e3, 10e3, 100e3, 1e6, 10e6, 100e6},
    FW_Resistance   = {1, 10, 100, 1e3, 10e3, 100e3, 1e6, 10e6, 100e6},
    Continuity      = {1e3},
    Diode           = {10},
    Capacitance     = {1e-9, 10e-9, 100e-9, 1e-6, 10e-6, 100e-6, 1e-3},
}

local gOperatingBoundaries =
{
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
    General =
    {
        Nplc =
        {
            -- NPLC handled better on 6500, defaults from 34461
            max = 12,
            def = 10,
            min = 0.0005
        }
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

local gStateVariables = 
{
    Measure_Function,

    -- APPLIES TO ALL MEASUREMENT FUNCTIONS (pg. 243 manual)
    
    -- AC Input Filter          20Hz
    -- Autozero                 OFF when NPLC < 1; ON otherwise
    -- Range                    AUTO
    -- Samples per Trigger      1
    -- Trigger Count            1
    -- Trigger Delay            Automatic
    -- Trigger Source           Immediate
    -- Trigger Slope            NEGative
    -- Math Functions           Disabled, Other parameters unchanged
    -- Per-function Null State  Disabled

    -- DC VOLTAGE/RATIO VARIABLES
    DC_Voltage = 
    {
        Null_State,
        Null_Value,
        Null_Value_Auto,
        Range,
        Range_Auto,
        Aperture,
        Aperture_Enabled,
        Impedance_Auto,
        NPLC,
        Zero_Auto,
    },
    AC_Voltage =
    {
        Bandwidth,
        Null_State,
        Null_Value,
        Null_Value_Auto,
        Range,
        Range_Auto,
    },
}

------------------------------------------------------------------------------
-- ResetDefaults()
-- Sets the smu to 2400 reset defaults
------------------------------------------------------------------------------

local gResetFunctionVariables = {
    -- APPLY TO ALL MEASUREMENT FUNCTIONS
    ResetDCVoltage = function()
        -- DC VOLTAGE VARIABLES
        gStateVariables.DC_Voltage.Null_State       = gInstrumentAttributes.OnOff.OFF
        gStateVariables.DC_Voltage.Null_Value       = 0
        gStateVariables.DC_Voltage.Null_Value_Auto  = gInstrumentAttributes.OnOff.OFF
        gStateVariables.DC_Voltage.Range            = 1000
        gStateVariables.DC_Voltage.Range_Auto       = gInstrumentAttributes.OnOff.ON
        gStateVariables.DC_Voltage.Aperture         = 100E-3
        gStateVariables.DC_Voltage.Aperture_Enabled = gInstrumentAttributes.OnOff.OFF
        gStateVariables.DC_Voltage.Impedance_Auto   = gInstrumentAttributes.OnOff.OFF
        gStateVariables.DC_Voltage.NPLC             = 10
        gStateVariables.DC_Voltage.Zero_Auto        = gInstrumentAttributes.OnOff.ON
    end,
    ResetACVoltage = function()
        -- AC VOLTAGE VARIABLES
        gStateVariables.AC_Voltage.Bandwidth        = gInstrumentAttributes.Detector_Bandwidth.HZ30
        gStateVariables.AC_Voltage.Null_State       = gInstrumentAttributes.OnOff.OFF
        gStateVariables.AC_Voltage.Null_Value       = 0
        gStateVariables.AC_Voltage.Null_Value_Auto  = gInstrumentAttributes.OnOff.OFF
        gStateVariables.AC_Voltage.Range            = 10
        gStateVariables.AC_Voltage.Range_Auto       = gInstrumentAttributes.OnOff.ON
    end,
}

local ResetScriptVariables = function()
        gStateVariables.Measure_Function = gInstrumentAttributes.Meas_Functions.DC_Voltage
        gResetFunctionVariables.ResetDCVoltage()
        gResetFunctionVariables.ResetACVoltage()
end

local gSetFunctionAttributes = 
{
    SetDCVoltage = function()
        gAccessors.mSetRelEnable(gStateVariables.DC_Voltage.Null_State.DMM_Enum)
        gAccessors.mSetRelLevel(gStateVariables.DC_Voltage.Null_Value)
        gAccessors.mSetMeasureRange(gStateVariables.DC_Voltage.Range)
        gAccessors.mSetMeasureAutorange(gStateVariables.DC_Voltage.Range_Auto.DMM_Enum)
        gAccessors.mSetMeasureNPLC(gStateVariables.DC_Voltage.NPLC)
        gAccessors.mSetAutozeroEnable(gStateVariables.DC_Voltage.Zero_Auto.DMM_Enum)
    end,
    SetACVoltage = function()
        gAccessors.mSetDetectorBandwidth(gStateVariables.AC_Voltage.Bandwidth.DMM_Enum)
        gAccessors.mSetRelEnable(gStateVariables.AC_Voltage.Null_State.DMM_Enum)
        gAccessors.mSetRelLevel(gStateVariables.AC_Voltage.Null_Value)
        gAccessors.mSetMeasureRange(gStateVariables.AC_Voltage.Range)
        gAccessors.mSetMeasureAutorange(gStateVariables.AC_Voltage.Range_Auto.DMM_Enum)
    end,
}

local ResetDMMSettings = function()
    reset()
    gAccessors.mSetMeasureFunction(gStateVariables.Measure_Function.DMM_Enum)
    gSetFunctionAttributes.SetDCVoltage()
end

ResetDefaults = function ()
    ResetScriptVariables()
    ResetDMMSettings()
end

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
        mCommand    Execution structure for command (if not a path)
        mQuery      Execution structure for query (if not a path)

    Command Element:
        mExecute    Execution function.
        mParameters Array of parameter elements for parameters.

    Parameter Element:
        mOptional   True if parameter is optional. False or nil if not.
        mDefault    Default value.
        mParse      Parser function.

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
        if lError then
            return nil, lError
        end
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
gParserTable.mParseVoltageAutoOnceKeywords = 
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseBooleanKeywords,
        {
            mParse = gParserTable.ParseParameterName,
            mNames = {["ONCE"] = "ONCE"}
        }
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
gParserTable.mParseBandwidthKeywords =
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
gParserTable.mParseBandwidth =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRf,
        gParserTable.mParseBandwidthKeywords
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
--  Initialize2400
--
--  Prepare the instrument hardware for 2400 emulation. This function must
--  be called before using Execute2400 or after changing the hardware state
--  between invokations of Engine2400.
--
------------------------------------------------------------------------------

Initialize2400 = function ()
    gInitialized = true
    reset()
    --ResetSmuSettings()
    format.byteorder = format.NORMAL
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
--  Execute2400
--
--  Execute a 2400 SCPI command string.
--
------------------------------------------------------------------------------

Execute2400 = function (lCommandMessage)
    if type(lCommandMessage) == "string" then
        AddMessage(lCommandMessage, gRemoteComm.types.MESSAGE, 0)
        GetNextCommand()
        ExecuteMessage()
    else
        print("$DIAG$ Can only execute a string message")
    end
end

------------------------------------------------------------------------------
--
--  Engine2400
--
--  Intercept command interface communication and process commands as 2400
--  SCPI command messages.
--
------------------------------------------------------------------------------
local UpdateStatusModel

Engine2400 = function ()
    if not gInitialized then
        Initialize2400()
    end
    -- override status register
    --RemoteCommStatus.override = 175
    gEngineMode = true
    --display.screen = display.SMUA
    gRemoteComm.intercept = gRemoteComm.ALL
    gOrigin = nil
    GetNewMessage = GetFirstCommandMessage
    while true do
        GetNewMessage()
        if gParserState.mNextMessage then
            GetNextCommand()
            ExecuteMessage()
        else
            -- Update status model here.
            --UpdateStatusModel()
            delay(0.0003)
        end
        --collectgarbage()
    end
    gRemoteComm.intercept = gRemoteComm.DISABLE
    gEngineMode = false
end


--SKIPPED A BUNCH OF FUNCTIONS


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
    ["*IDN"] = {mCommand = {}},
    ["*RST"] = {mCommand = {}},
    ["ABORT"] =
    {
        mCommand = {},
    },
    ["CONFIGURE"] =
    {
        mQuery = {},
        ["AC"] =
        {
            mCommand = {},
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
    },
    ["SENSE"] =
    {
        
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
}

-- ADD ABBREVIATION ALIASES HERE
gCommandTree["ABOR"]                                    = gCommandTree["ABORT"]
gCommandTree["CONF"]                                    = gCommandTree["CONFIGURE"]
gCommandTree["CONFIGURE"]["VOLTAGE"]["DC"]              = gCommandTree["CONFIGURE"]["DC"]
gCommandTree["CONFIGURE"]["VOLTAGE"]["AC"]              = gCommandTree["CONFIGURE"]["AC"]
gCommandTree["CONFIGURE"]["VOLT"]                       = gCommandTree["CONFIGURE"]["VOLTAGE"]
gCommandTree["CONFIGURE"]["VOLT"]                       = gCommandTree["CONFIGURE"]["VOLTAGE"]
gCommandTree["CONFIGURE"]["RAT"]                        = gCommandTree["CONFIGURE"]["RATIO"]
gCommandTree["CONFIGURE"]["DC"]["RATIO"]                = gCommandTree["CONFIGURE"]["RATIO"]
gCommandTree["CONFIGURE"]["DC"]["RAT"]                  = gCommandTree["CONFIGURE"]["RATIO"]
gCommandTree["CONFIGURE"]["VOLTAGE"]["RATIO"]           = gCommandTree["CONFIGURE"]["RATIO"]
gCommandTree["CONFIGURE"]["VOLTAGE"]["RAT"]             = gCommandTree["CONFIGURE"]["RATIO"]

gCommandTree["SENS"]                                    = gCommandTree["SENSE"]
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

------------------------------------------------------------------------------
 -- Global variable declarations
 --[[
        These variables are global to the Persona2400 script but are
        local outside the script
 --]]
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- General utility functions
--[[
    These functions are used at various places in the script
--]]
-----------------------------------------------------------------------------

------------------------------------------------------------------------------
-- Print functions
--
-- These functions are used to format and print data
--
-----------------------------------------------------------------------------
local FormatNumber = function (lNumber, signed)
    if signed then
        return string.format("+%E", lNumber)
    end
    return string.format("%E", lNumber)
end

-- ADD COMMAND FUNCTIONALITY HERE
local gCurrentRoot

gCurrentRoot = gCommandTree["*IDN"]
gCurrentRoot.mCommand.mExecute = function()
    print(
        string.format(
            "KEITHLEY INSTRUMENTS,MODEL DMM6500,%s,%s",
            --"Keysight Technologies,34461A,%s,%s\n",
            localnode.serialno,
            localnode.version
        )
    )
end
gCurrentRoot = gCommandTree["*RST"]
gCurrentRoot.mCommand.mExecute = function()
    ResetDefaults()
end
-- ABORt
-- PLACEHOLDER TO EXIT SCRIPT
gCurrentRoot = gCommandTree["ABORT"]
gCurrentRoot.mCommand.mExecute = function ()
    exit()
end

-- CONFigure?
gCurrentRoot = gCommandTree["CONFIGURE"]
gCurrentRoot.mQuery.mExecute = function()
    -- RESOLUTION NOT SUPPORTED CURRENTLY
    local lCurrentRange = gAccessors.mGetMeasureRange()
    print(
        string.format(
            "%s %s,%s", 
            gStateVariables.Measure_Function.shorthand, 
            FormatNumber(lCurrentRange, true),
            "nil"
        )
    )
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
    gStateVariables.Measure_Function = gInstrumentAttributes.Meas_Functions.AC_Voltage
    gAccessors.mSetMeasureFunction(gStateVariables.Measure_Function.DMM_Enum)
    gResetFunctionVariables.ResetACVoltage()
    gSetFunctionAttributes.SetACVoltage()
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
    gStateVariables.Measure_Function = gInstrumentAttributes.Meas_Functions.DC_Voltage
    gAccessors.mSetMeasureFunction(gStateVariables.Measure_Function.DMM_Enum)
    gResetFunctionVariables.ResetDCVoltage()
    gSetFunctionAttributes.SetDCVoltage()
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
    gStateVariables.Measure_Function = gInstrumentAttributes.Meas_Functions.Ratio
    gAccessors.mSetMeasureFunction(gStateVariables.Measure_Function.DMM_Enum)
    gResetFunctionVariables.ResetDCVoltage()
    gSetFunctionAttributes.SetDCVoltage()
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

-- [SENSe:]VOLTage:DC:NULL[:STATe] {ON|1|OFF|0}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lNullState = lParameters[1]
    if lNullState == true then
        gStateVariables.DC_Voltage.Null_State = gInstrumentAttributes.OnOff.ON
    elseif lNullState == false then
        gStateVariables.DC_Voltage.Null_State = gInstrumentAttributes.OnOff.OFF
    end
    if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.DC_Voltage 
    or gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.Ratio then
        gAccessors.mSetRelEnable(gStateVariables.DC_Voltage.Null_State.shorthand)
    end
end
-- [SENSe:]VOLTage:DC:NULL[:STATe]?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gStateVariables.DC_Voltage.Null_State.shorthand
        )
    )
end
gCurrentRoot["STATE"].mCommand = gCurrentRoot.mCommand
gCurrentRoot["STATE"].mQuery = gCurrentRoot.mQuery
--[SENSe:]VOLTage:DC:NULL:VALue {<value>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["NULL"]["VALUE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseDCVNullValue}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local relLevel = lParameters[1]
    if relLevel <= gOperatingBoundaries.DC_Voltage.Null.max and
       relLevel >= gOperatingBoundaries.DC_Voltage.Null.min then
        gStateVariables.DC_Voltage.Null_Value = relLevel
        if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.DC_Voltage 
        or gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.Ratio then
            gAccessors.mSetRelLevel(relLevel)
        end
    else
        gErrorQueue.Add(-222)
    end    
end
--[SENSe:]VOLTage:DC:NULL:VALue? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseDCVNullValueKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintNullValue = lParameters[1]
    if lPrintNullValue == nil then
        lPrintNullValue = gStateVariables.DC_Voltage.Null_Value
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
    if lParameters[1] == true then
        gStateVariables.DC_Voltage.Null_Value_Auto = gInstrumentAttributes.OnOff.ON
    elseif lParameters[1] == false then
        gStateVariables.DC_Voltage.Null_Value_Auto = gInstrumentAttributes.OnOff.OFF
    end
end
-- [SENSe:]VOLTage:DC:NULL:VALue:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gStateVariables.DC_Voltage.Null_Value_Auto.shorthand
        )
    )
end
-- [SENSe:]VOLTage:DC:RANGe {<range>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseDCVoltageRange}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lMeasureRange = lParameters[1]
    if gMathAbs(lMeasureRange) <= 1.10 * lMeasureRange then
        -- Turn autorange off
        gStateVariables.DC_Voltage.Range_Auto = gInstrumentAttributes.OnOff.OFF
        -- Set the range
        if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.DC_Voltage 
        or gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.Ratio then
            gAccessors.mSetMeasureAutorange(gOff)
            gAccessors.mSetMeasureRange(lMeasureRange)
        end
        for _, lRange in ipairs(gRangeTable.DC_Voltage) do
            if gMathAbs(lMeasureRange) <= 1.10 * lRange then
                gStateVariables.DC_Voltage.Range = lRange
                return
            end
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
        lPrintRange = gStateVariables.DC_Voltage.Range
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintRange, true)
        )
    )
end
--[SENSe:]VOLTage:DC:RANGe:AUTO {OFF|ON|ONCE}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseVoltageAutoOnceKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lAutorangeSetter = gAccessors.mSetMeasureAutorange
    local lAutorange = lParameters[1]
    if lAutorange == "ONCE" then
        lAutorangeSetter(gInstrumentAttributes.OnOff.ON.shorthand)
        --TAKE MEASUREMENT
        local lMeasCount = gAccessors.mGetMeasureCount()
        local lMeasFunc = gAccessors.mGetMeasureFunction()
        gAccessors.mSetMeasureCount(1)
        gAccessors.mSetMeasureFunction(gInstrumentAttributes.Meas_Functions.DC_Voltage.DMM_Enum)
        gMeasure.read()
        gStateVariables.DC_Voltage.Range = gAccessors.mGetMeasureRange()
        gAccessors.mSetMeasureCount(lMeasCount)
        gAccessors.mSetMeasureFunction(lMeasFunc)
        lAutorange = false
    end
    if lAutorange == true then
        gStateVariables.DC_Voltage.Range_Auto = gInstrumentAttributes.OnOff.ON
    elseif lAutorange == false then
        gStateVariables.DC_Voltage.Range_Auto = gInstrumentAttributes.OnOff.OFF
    end
    if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.DC_Voltage 
    or gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.Ratio then
        lAutorangeSetter(gStateVariables.DC_Voltage.Range_Auto.DMM_Enum)
    end
end
--[SENSe:]VOLTage:DC:RANGe:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gStateVariables.DC_Voltage.Range_Auto.shorthand
        )
    )
end
--[SENSe:]VOLTage[:DC]:NPLC {<PLC>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["NPLC"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseNPLC}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lNPLC = lParameters[1]
    if lNPLC <= gOperatingBoundaries.General.Nplc.max 
    and lNPLC >= gOperatingBoundaries.General.Nplc.min then
        gStateVariables.DC_Voltage.NPLC = lNPLC
        if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.DC_Voltage 
        or gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.Ratio then
            gAccessors.mSetMeasureNPLC(lNPLC)
        end
    else
        gErrorQueue.Add(-222)
    end
end
--[SENSe:]VOLTage[:DC]:NPLC? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseNPLCKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lNPLC = lParameters[1]
    if lParameters[1] == nil then
        lNPLC = gStateVariables.DC_Voltage.NPLC
    end
    print(
        string.format(
            "%s",
            FormatNumber(lNPLC, true)
        )
    )
end
--[SENSe:]VOLTage[:DC]:ZERO:AUTO {OFF|ON|ONCE}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["ZERO"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseVoltageAutoOnceKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lAutoZero = lParameters[1]
    if lAutoZero == true then
        gStateVariables.DC_Voltage.Zero_Auto = gInstrumentAttributes.OnOff.ON
    elseif lAutoZero == false then
        gStateVariables.DC_Voltage.Zero_Auto = gInstrumentAttributes.OnOff.OFF
    elseif lAutoZero == "ONCE" then
        if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.DC_Voltage then
            gMeasure.autozero.once()
        end
        gStateVariables.DC_Voltage.Zero_Auto = gInstrumentAttributes.OnOff.OFF
    end
    if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.DC_Voltage 
    or gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.Ratio then
        gAccessors.mSetAutozeroEnable(gStateVariables.DC_Voltage.Zero_Auto.DMM_Enum)
    end
end
--[SENSe:]VOLTage[:DC]:ZERO:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gStateVariables.DC_Voltage.Zero_Auto.shorthand
        )
    )
end

--[SENSe:]VOLTage:AC:BANDwidth {<filter>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["BANDWIDTH"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBandwidth}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lDetectorBandwidth = lParameters[1]
    if lDetectorBandwidth > 300000 
    or lDetectorBandwidth < gOperatingBoundaries.AC_Voltage.Bandwidth.min then
        gErrorQueue.Add(-222)
        return
    end
    if lDetectorBandwidth >= 300 then
        gStateVariables.AC_Voltage.Bandwidth = gInstrumentAttributes.Detector_Bandwidth.HZ300
    elseif lDetectorBandwidth >= 30 then
        gStateVariables.AC_Voltage.Bandwidth = gInstrumentAttributes.Detector_Bandwidth.HZ30
    elseif lDetectorBandwidth >= 3 then
        gStateVariables.AC_Voltage.Bandwidth = gInstrumentAttributes.Detector_Bandwidth.HZ3
    end
    if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.AC_Voltage then
        gAccessors.mSetDetectorBandwidth(gStateVariables.AC_Voltage.Bandwidth.DMM_Enum)
    end
end
--[SENSe:]VOLTage:AC:BANDwidth? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseBandwidthKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lBandwidth = lParameters[1]
    if lParameters[1] == nil then
        lBandwidth = gStateVariables.AC_Voltage.Bandwidth
    end
    print(
        string.format(
            "%s",
            FormatNumber(lBandwidth.shorthand, true)
        )
    )
end
-- [SENSe:]VOLTage:AC:NULL[:STATe] {ON|1|OFF|0}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseBooleanKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lNullState = lParameters[1]
    if lNullState == true then
        gStateVariables.AC_Voltage.Null_State = gInstrumentAttributes.OnOff.ON
    elseif lNullState == false then
        gStateVariables.AC_Voltage.Null_State = gInstrumentAttributes.OnOff.OFF
    end
    if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.AC_Voltage then
        gAccessors.mSetRelEnable(gStateVariables.AC_Voltage.Null_State.shorthand)
    end
end
-- [SENSe:]VOLTage:AC:NULL[:STATe]?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gStateVariables.AC_Voltage.Null_State.shorthand
        )
    )
end
gCurrentRoot["STATE"].mCommand = gCurrentRoot.mCommand
gCurrentRoot["STATE"].mQuery = gCurrentRoot.mQuery
--[SENSe:]VOLTage:AC:NULL:VALue {<value>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["NULL"]["VALUE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseACVNullValue}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local relLevel = lParameters[1]
    if relLevel <= gOperatingBoundaries.AC_Voltage.Null.max and
       relLevel >= gOperatingBoundaries.AC_Voltage.Null.min then
        gStateVariables.AC_Voltage.Null_Value = relLevel
        if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.AC_Voltage then
            gAccessors.mSetRelLevel(relLevel)
        end
    else
        gErrorQueue.Add(-222)
    end
end
--[SENSe:]VOLTage:AC:NULL:VALue? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = {gParserTable.mParseACVNullValueKeywords}
gCurrentRoot.mQuery.mExecute = function(lParameters)
    local lPrintNullValue = lParameters[1]
    if lPrintNullValue == nil then
        lPrintNullValue = gStateVariables.AC_Voltage.Null_Value
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
    if lParameters[1] == true then
        gStateVariables.AC_Voltage.Null_Value_Auto = gInstrumentAttributes.OnOff.ON
    elseif lParameters[1] == false then
        gStateVariables.AC_Voltage.Null_Value_Auto = gInstrumentAttributes.OnOff.OFF
    end
end
-- [SENSe:]VOLTage:AC:NULL:VALue:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gStateVariables.AC_Voltage.Null_Value_Auto.shorthand
        )
    )
end
-- [SENSe:]VOLTage:AC:RANGe {<range>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["RANGE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseACVoltageRange}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lMeasureRange = lParameters[1]
    if gMathAbs(lMeasureRange) <= 1.10 * lMeasureRange then
        -- Turn autorange off
        gStateVariables.AC_Voltage.Range_Auto = gInstrumentAttributes.OnOff.OFF
        -- Set the range
        if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.AC_Voltage then
            gAccessors.mSetMeasureAutorange(gOff)
            gAccessors.mSetMeasureRange(lMeasureRange)
        end
        for _, lRange in ipairs(gRangeTable.AC_Voltage) do
            if gMathAbs(lMeasureRange) <= 1.10 * lRange then
                gStateVariables.AC_Voltage.Range = lRange
                return
            end
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
        lPrintRange = gStateVariables.AC_Voltage.Range
    end
    print(
        string.format(
            "%s",
            FormatNumber(lPrintRange, true)
        )
    )
end
--[SENSe:]VOLTage:AC:RANGe:AUTO {OFF|ON|ONCE}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["AC"]["RANGE"]["AUTO"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseVoltageAutoOnceKeywords}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lAutorangeSetter = gAccessors.mSetMeasureAutorange
    local lAutorange = lParameters[1]
    if lAutorange == "ONCE" then
        lAutorangeSetter(gInstrumentAttributes.OnOff.ON.shorthand)
        --TAKE MEASUREMENT
        local lMeasCount = gAccessors.mGetMeasureCount()
        local lMeasFunc = gAccessors.mGetMeasureFunction()
        gAccessors.mSetMeasureCount(1)
        gAccessors.mSetMeasureFunction(gInstrumentAttributes.Meas_Functions.AC_Voltage.DMM_Enum)
        gMeasure.read()
        gStateVariables.AC_Voltage.Range = gAccessors.mGetMeasureRange()
        gAccessors.mSetMeasureCount(lMeasCount)
        gAccessors.mSetMeasureFunction(lMeasFunc)
        lAutorange = false
    end
    if lAutorange == true then
        gStateVariables.AC_Voltage.Range_Auto = gInstrumentAttributes.OnOff.ON
    elseif lAutorange == false then
        gStateVariables.AC_Voltage.Range_Auto = gInstrumentAttributes.OnOff.OFF
    end
    if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.AC_Voltage then
        lAutorangeSetter(gStateVariables.AC_Voltage.Range_Auto.DMM_Enum)
    end
end
--[SENSe:]VOLTage:AC:RANGe:AUTO?
gCurrentRoot.mQuery.mExecute = function()
    print(
        string.format(
            "%s",
            gStateVariables.AC_Voltage.Range_Auto.shorthand
        )
    )
end

-- INITIALIZE HERE
gCurrentRoot = gCommandTree

ResetDefaults()

Engine2400()

--endscript