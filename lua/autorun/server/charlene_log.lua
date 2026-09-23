-- log.lua

if _G.CharleneHooLog then return _G.CharleneHooLog end

---@class Log
---@field OutFile string|nil
---@field Level integer
---@field Fold boolean
---@field MaxTable integer
---@field Trace fun(...: any)
---@field Debug fun(...: any)
---@field Info fun(...: any)
---@field Warn fun(...: any)
---@field Error fun(...: any)
local log = {}

-- ============================================================
-- 级别枚举
-- ============================================================

local Level = {
    TRACE = 1,
    DEBUG = 2,
    INFO  = 3,
    WARN  = 4,
    ERROR = 5,
}

-- ============================================================
-- 配置
-- ============================================================

log.Level = Level.INFO
log.OutFile = nil -- nil = 不写文件; 相对 data/, 自动补 .txt
log.Fold = true   -- 连续相同折叠
log.MaxTable = 3  -- table 显示前几项

---@type table<integer, string>
local levelName = {
    [Level.TRACE] = "trace",
    [Level.DEBUG] = "debug",
    [Level.INFO]  = "info",
    [Level.WARN]  = "warn",
    [Level.ERROR] = "error",
}

---@type table<integer, Color>
local levelColor = {
    [Level.TRACE] = Color(140, 140, 140),
    [Level.DEBUG] = Color(100, 200, 255),
    [Level.INFO]  = Color(200, 255, 200),
    [Level.WARN]  = Color(255, 220, 100),
    [Level.ERROR] = Color(255, 100, 100),
}

local LEVEL_NAME_WIDTH = 0
for _, name in pairs(levelName) do
    if #name > LEVEL_NAME_WIDTH then
        LEVEL_NAME_WIDTH = #name
    end
end

---@param level integer
---@return string
local function formatLevelName(level)
    local name = (levelName[level] or "?"):upper()
    local pad = LEVEL_NAME_WIDTH - #name
    if pad > 0 then
        return string.rep(" ", pad) .. name
    end
    return name
end

---@return integer
local function getCurrentLevel()
    return log.Level or Level.INFO
end

-- ============================================================
-- 值格式化
-- ============================================================

---@param value number
---@return string
local function formatNumber(value)
    if value == math.floor(value) and math.abs(value) < 1e15 then
        return string.format("%d", value)
    end
    return string.format("%.3f", value)
end

---@param value table
---@return boolean
local function hasToString(value)
    local mt = getmetatable(value)
    return type(mt) == "table" and type(mt.__tostring) == "function"
end

---@type fun(value: any): string
local formatValue -- 前向声明

---@param value any
---@return string
local function briefElement(value)
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) == "table" and not hasToString(value) then return "<table>" end
    return formatValue(value)
end

formatValue = function (value)
    local valueType = type(value)
    if valueType == "Vector" then
        return string.format("Vector(%s, %s, %s)",
            formatNumber(value.x), formatNumber(value.y), formatNumber(value.z))
    end
    if valueType == "Angle" then
        return string.format("Angle(%s, %s, %s)",
            formatNumber(value.p), formatNumber(value.y), formatNumber(value.r))
    end
    if valueType == "function" then return "<function>" end
    if valueType ~= "table" then return tostring(value) end
    if hasToString(value) then return tostring(value) end

    local itemCount = 0
    for _ in pairs(value) do itemCount = itemCount + 1 end
    if itemCount == 0 then return "table[0]" end

    local parts = {}
    local arrayLength = #value
    if arrayLength == itemCount then
        local limit = math.min(itemCount, log.MaxTable)
        for index = 1, limit do
            parts[index] = briefElement(value[index])
        end
        local tailText = itemCount > limit and ", ..." or ""
        return string.format("[%s%s] (n=%d)", table.concat(parts, ", "), tailText, itemCount)
    end

    local index = 0
    for key, entryValue in pairs(value) do
        index = index + 1
        if index > log.MaxTable then break end
        local keyString = (type(key) == "string") and key or ("[" .. tostring(key) .. "]")
        parts[index] = keyString .. "=" .. briefElement(entryValue)
    end
    local tailText = itemCount > log.MaxTable and ", ..." or ""
    return string.format("{%s%s} (n=%d)", table.concat(parts, ", "), tailText, itemCount)
end

-- ============================================================
-- 时间
-- ============================================================

---@param time number
---@return string
local function formatSysTime(time)
    local totalMilliseconds = math.floor(time * 1000)
    local totalSeconds = math.floor(totalMilliseconds / 1000)
    local hours = math.floor(totalSeconds / 3600) % 24
    local minutes = math.floor(totalSeconds / 60) % 60
    local seconds = totalSeconds % 60
    return string.format("%02d:%02d:%02d.%03d",
        hours, minutes, seconds, totalMilliseconds % 1000)
end

---@param time number
---@return string
local function formatElapsedTime(time)
    local totalMilliseconds = math.floor(time * 1000)
    return string.format("%02d:%02d.%03d",
        math.floor(totalMilliseconds / 60000) % 60,
        math.floor(totalMilliseconds / 1000) % 60,
        totalMilliseconds % 1000)
end

-- ============================================================
-- 调用点 (跳过 C 函数 / 未知源, 应对 hook / timer 回调栈)
-- ============================================================

---@return string
---@return number
local function findCaller()
    if not debug or not debug.getinfo then return "?", 0 end
    for level = 4, 20 do
        local info = debug.getinfo(level, "Sl")
        if not info then break end
        local source = info.short_src or info.source
        if source and source ~= "=[C]" and source ~= "?" and source ~= "" then
            return (source:gsub("^@", "")), info.currentline or 0
        end
    end
    return "?", 0
end

-- ============================================================
-- 输出 (控制台 + 文件), 折叠在此处
-- ============================================================

local pending = nil

---@return string|nil
local function getOutfilePath()
    local path = log.OutFile
    if not path then return nil end
    if not path:lower():match("%.txt$") then
        path = path .. ".txt"
    end
    return path
end

---@param color Color
---@param head string
---@param text string
---@param count integer
local function emitLine(color, head, text, count)
    local line = head
    if count and count > 1 then
        line = line .. " " .. text .. " x" .. count
    else
        line = line .. " " .. text
    end

    MsgC(color, head)
    MsgC(Color(230, 230, 230),
        (count and count > 1) and (" " .. text .. " x" .. count .. "\n")
        or (" " .. text .. "\n"))

    local path = getOutfilePath()
    if path then file.Append(path, line .. "\n") end
end

local function flushPending()
    if not pending then return end
    local currentPending = pending
    pending = nil
    emitLine(currentPending.Color, currentPending.Head, currentPending.Text, currentPending.Count)
end

-- ============================================================
-- 日志写入公共逻辑
-- ============================================================

---@param level integer
---@param ... any
local function logAt(level, ...)
    if level < getCurrentLevel() then return end

    local color = levelColor[level]
    if not color then return end

    local count = select("#", ...)
    local parts = {}
    for index = 1, count do
        local value = select(index, ...)
        parts[index] = formatValue(value)
    end
    local text = table.concat(parts, " ")

    local source, line = findCaller()
    local head = string.format("[%s][%d][%s][%s][%s:%d]",
        formatSysTime(SysTime()),
        engine.TickCount() % 10000,
        formatElapsedTime(CurTime()),
        formatLevelName(level),
        source, line)

    if not log.Fold then
        emitLine(color, head, text, 1)
        return
    end

    local signature = levelName[level] .. "\0" .. source .. ":" .. line .. "\0" .. text
    if pending and pending.Signature == signature then
        pending.Count = pending.Count + 1
    else
        flushPending()
        pending = {
            Head = head,
            Text = text,
            Color = color,
            Signature = signature,
            Count = 1,
        }
    end
end

-- ============================================================
-- 展平各级别函数
-- ============================================================

log.Trace = function (...) logAt(Level.TRACE, ...) end
log.Debug = function (...) logAt(Level.DEBUG, ...) end
log.Info = function (...) logAt(Level.INFO, ...) end
log.Warn = function (...) logAt(Level.WARN, ...) end
log.Error = function (...) logAt(Level.ERROR, ...) end

-- 定时 flush, 让折叠计数能看到
timer.Create("CharleneHooLogAutoSave", 1.5, 0, flushPending)

_G.CharleneHooLog = log
return log
