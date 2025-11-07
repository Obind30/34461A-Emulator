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

--gDisplayVariables.mDisplayText1 = display.gettext(false, 1)
--gDisplayVariables.mDisplayText2 = display.gettext(false, 2)
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
local gDisplayErrors = false
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

local gRemoteCommStatus = gRemoteComm.status

-- TODO Keep placing getter/setter functions here
gAccessors.mSetMeasureFunction = makesetter(gMeasure, "func")
gAccessors.mSetMeasureRange = makesetter(gMeasure, "range")
gAccessors.mSetMeasureAutorange = makesetter(gMeasure, "autorange")
gAccessors.mSetThermistor = makesetter(gMeasure, "thermistor")
gAccessors.mSetThermocouple = makesetter(gMeasure, "thermocouple")
gAccessors.mSetDetectorBandwidth = makesetter(gMeasure, "detectorbandwidth")
gAccessors.mSetRelEnable = makesetter(gRel, "enable")
gAccessors.mSetRelLevel = makesetter(gRel, "level")
gAccessors.mSetMeasureNPLC = makesetter(gMeasure, "nplc")
gAccessors.mSetAutozeroEnable = makesetter(gMeasure.autozero, "enable")

gAccessors.mGetMeasureFunction = makegetter(gMeasure, "func")
gAccessors.mGetMeasureRange = makegetter(gMeasure, "range")
gAccessors.mGetMeasureAutorange = makegetter(gMeasure, "autorange")
gAccessors.mGetThermistor = makegetter(gMeasure, "thermistor")
gAccessors.mGetThermocouple = makegetter(gMeasure, "thermocouple")
gAccessors.mGetDetectorBandwidth = makegetter(gMeasure, "detectorbandwidth")
gAccessors.mGetRelEnable = makegetter(gRel, "enable")
gAccessors.mGetRelLevel = makegetter(gRel, "level")
gAccessors.mGetMeasureNPLC = makegetter(gMeasure, "nplc")
gAccessors.mGetAutozeroEnable = makegetter(gMeasure.autozero, "enable")

local gInstrumentAttributes =
{
    Meas_Functions =
    {
        Voltage_DC = 
        {
            shorthand = "VOLT",
            DMM_Enum = dmm.FUNC_DC_VOLTAGE
        },
        Voltage_AC = 
        {
            shorthand = "VOLT:AC",
            DMM_Enum = dmm.FUNC_AC_VOLTAGE
        },
        Current_DC = 
        {
            shorthand = "CURR",
            DMM_Enum = dmm.FUNC_DC_CURRENT
        },
        Current_AC = 
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
        Resistance_4W = 
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
    Meas_Ranges =
    {
        DCVoltage = {100e-3, 1, 10, 100, 1000},
    },
}

--============================================================================
--
-- Model specific tables
--
-- These tables store model specific range related information.
--
--============================================================================

local gOperatingBoundaries
local gSafeOperatingArea
local gRangeTable
local gPrintEnable = false

--TODO Change this to match 2600
if localnode.model == "DMM6500" then

    gOperatingBoundaries =
    {
        mMinimumCapacitanceRange = 1e-9,
        mMaximumCapacitanceRange = 100e-6,
    }

    gRangeTable =
    {
       mCapacitance = {1e-9, 10e-9, 100e-9, 1e-6, 10e-6, 100e-6},
    }

    --gSafeOperatingArea = {mVoltage = 20, mCurrent = .1}
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
    return nil, -104
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
        if lValue ~= nil then
            return lValue
        end
        lIndex = lIndex + 1
    end
    return nil, -102
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
    lParameter = lParseData.mNames[lParameter]

    if lParameter then
        return lParameter
    else
        return nil, -102
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

gParserTable.mParseAny          = {mParse = gParserTable.ParseParameterAny}
gParserTable.mParseNRf          = {mParse = gParserTable.ParseParameterNRf}
gParserTable.mParseNRfOptional  = {mParse = gParserTable.ParseParameterNRf, mOptional = true}
gParserTable.mParseDCVoltageRangeKeywords =
{
    mParse = gParserTable.ParseParameterName,
    mNames =
    {
        ["MIN"]         = 100e-3,
        ["MINIMUM"]     = 100e-3,
        ["MAX"]         = 1000,
        ["MAXIMUM"]     = 1000,
        ["DEF"]         = 1000,
        ["DEFAULT"]     = 1000,
    }
}
gParserTable.mParseDCVoltageRange =
{
    mParse = gParserTable.ParseParameterChoice,
    mData =
    {
        gParserTable.mParseNRfOptional,
        gParserTable.mParseDCVoltageRangeKeywords,
    }
}
gParserTable.mParseDCVoltageAutorangeKeywords = {
    mParse = gParserTable.ParseParameterName,
    mNames =
    {
        ["OFF"] = "OFF",
        ["ON"] = "ON",
        ["ONCE"] = "ONCE",
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
                               --gErrorQueue.Add(-170)
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
local ResetDefaults
local ResetScriptVariables
local ResetSmuSettings

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
                --gErrorQueue.Add(lError)
            end
        else
            --gErrorQueue.Add(lParseInfo.mError)
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
    ["ABORT"] =
    {
        mCommand = {},
    },
    ["CONFIGURE"] =
    {
        mQuery = {},
        ["CAPACITANCE"] =
        {
            mCommand = {},
        },
        ["CONTINUITY"] =
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
        ["DIODE"] =
        {
            mCommand = {},
        },
        ["FREQUENCY"] =
        {
            mCommand = {},
        },
        ["PERIOD"] =
        {
            mCommand = {},
        },
        ["RESISTANCE"] =
        {
            mCommand = {},
        },
        ["FRESISTANCE"] =
        {
            mCommand = {},
        },
        ["TEMPERATURE"] =
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
                ["RATIO"] =
                {
                    mCommand = {},
                },
            },
        },
    },
    ["MEASURE"] =
    {
        ["CAPACITANCE"] =
        {
            mQuery = {},
        },
        ["CONTINUITY"] =
        {
            mQuery = {},
        },
        ["CURRENT"] =
        {
            ["AC"] =
            {
                mQuery = {},
            },
            ["DC"] =
            {
                mQuery = {},
            },
        },
        ["DIODE"] =
        {
            mQuery = {},
        },
        ["FREQUENCY"] =
        {
            mCommand = {},
        },
        ["PERIOD"] =
        {
            mCommand = {},
        },
        ["RESISTANCE"] =
        {
            mCommand = {},
        },
        ["FRESISTANCE"] =
        {
            mCommand = {},
        },
        ["TEMPERATURE"] =
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
                ["RATIO"] =
                {
                    mCommand = {},
                },
            },
        },
    },
    ["SENSE"] =
    {
        ["FUNCTION"] =
        {
            ["ON"] =
            {
                mQuery = {},
                mCommand = {},
            },
        },
        ["VOLTAGE"] =
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
                ["NPLC"] =
                {
                    mQuery = {},
                    mCommand = {},
                },
                ["NULL"] =
                {
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
        },
    },
}

-- ADD ABBREVIATION ALIASES HERE
gCommandTree["ABOR"] = gCommandTree["ABORT"]
gCommandTree["CONF"] = gCommandTree["CONFIGURE"]

gCommandTree["VOLTAGE"] = gCommandTree["SENSE"]["VOLTAGE"]
gCommandTree["VOLT"] = gCommandTree["SENSE"]["VOLTAGE"]
gCommandTree["SENS"] = gCommandTree["SENSE"]
gCommandTree["SENSE"]["VOLT"] = gCommandTree["SENSE"]["VOLTAGE"]
gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANG"] = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"]

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

    -- DC VOLTAGE VARIABLES
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
        Zero_Auto
    }
}

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
-- stauts register bits. Any other mStatusBit value
-- updates the Standard Event Status Register.
--
------------------------------------------------------------------------------

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
-- [SENSe:]VOLTage:DC:RANGe {<range>|MIN|MAX|DEF}
gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"]
gCurrentRoot.mCommand.mParameters = {gParserTable.mParseDCVoltageRange}
gCurrentRoot.mCommand.mExecute = function(lParameters)
    local lMeasureRange = lParameters[1]
    -- Turn autorange off
    gAccessors.mSetMeasureAutorange(gOff)
    gStateVariables.DC_Voltage.Range_Auto = "OFF"
    -- Set the range
    if gStateVariables.Measure_Function == gInstrumentAttributes.Meas_Functions.Voltage_DC then
        gAccessors.mSetMeasureRange(lMeasureRange)
    end
    for _, lRange in ipairs(gInstrumentAttributes.Meas_Ranges.DCVoltage) do
        if gMathAbs(lMeasureRange) <= 1.10 * lRange then
            gStateVariables.DC_Voltage.Range = lRange
            return
        end
    end
end
-- [SENSe:]VOLTage:{AC|DC}:RANGe? [{MIN|MAX|DEF}]
gCurrentRoot.mQuery.mParameters = 
{
    {
        mParse = gParserTable.ParseParameterName,
        mOptional = true,
        mNames =
        {
            ["MIN"]         = 100e-3,
            ["MINIMUM"]     = 100e-3,
            ["MAX"]         = 1000,
            ["MAXIMUM"]     = 1000,
            ["DEF"]         = 1000,
            ["DEFAULT"]     = 1000,
        }
    }
}
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
--[SENSe:]VOLTage:{AC|DC}:RANGe:AUTO {OFF|ON|ONCE}
--gCurrentRoot = gCommandTree["SENSE"]["VOLTAGE"]["DC"]["RANGE"]["AUTO"]
--gCurrentRoot.mCommand.mParameters = gParserTable.mParseDCVoltageAutorangeKeywords


------------------------------------------------------------------------------
-- ResetDefaults()
-- Sets the smu to 2400 reset defaults
------------------------------------------------------------------------------

ResetScriptVariables = function()
    gStateVariables.Measure_Function = gInstrumentAttributes.Meas_Functions.Voltage_DC

    -- APPLY TO ALL MEASUREMENT FUNCTIONS

    -- DC VOLTAGE VARIABLES
    gStateVariables.DC_Voltage.Null_State = "OFF"
    gStateVariables.DC_Voltage.Null_Value = 0
    gStateVariables.DC_Voltage.Null_Value_Auto = "OFF"
    gStateVariables.DC_Voltage.Range = 1000
    gStateVariables.DC_Voltage.Range_Auto = "ON"
    gStateVariables.DC_Voltage.Aperture = 100E-3
    gStateVariables.DC_Voltage.Aperture_Enabled = "OFF"
    gStateVariables.DC_Voltage.Impedance_Auto = "OFF"
    gStateVariables.DC_Voltage.NPLC = 10
    gStateVariables.DC_Voltage.Zero_Auto = "ON"
    

end

ResetDMMSettings = function()
    reset()
    gAccessors.mSetMeasureFunction(gStateVariables.Measure_Function.DMM_Enum)
end

ResetDefaults = function ()
    ResetScriptVariables()
    ResetDMMSettings()
end

-- INITIALIZE HERE
gCurrentRoot = gCommandTree

ResetDefaults()

Engine2400()

--endscript