-- log.lua

if _G._CharleneHooLog then return _G._CharleneHooLog end

---@class Log
---@field OutFile string|nil
---@field Level integer
---@field Fold boolean
---@field MaxTable integer
---@field Levels table<string, integer>
---@field Trace fun(...: any)
---@field Debug fun(...: any)
---@field Info fun(...: any)
---@field Warn fun(...: any)
---@field Error fun(...: any)
local log = {}

-- ============================================================
-- 级别定义表：索引即级别，顺序即语义
--   Name  - 驼峰名，用于动态挂载 log.Trace / log.Debug / ...
--   Color - 控制台颜色
--   Label - 预计算的对齐后显示名（控制台输出用）
-- 顺序不可乱动，log.Level 直接与索引比较
-- ============================================================

---@class LevelDef
---@field Name string
---@field Color Color
---@field Label string

---@type LevelDef[]
local levelDefs = {
    { Name = "Trace", Color = Color(140, 140, 140), Label = "" },  -- 1
    { Name = "Debug", Color = Color(100, 200, 255), Label = "" },  -- 2
    { Name = "Info",  Color = Color(200, 255, 200), Label = "" },  -- 3
    { Name = "Warn",  Color = Color(255, 220, 100), Label = "" },  -- 4
    { Name = "Error", Color = Color(255, 100, 100), Label = "" },  -- 5
}

-- 第一趟：大写名暂存到 Label，同时求最大宽度
local maxNameWidth = 0
for level = 1, #levelDefs do
    local def = levelDefs[level]
    def.Label = def.Name:upper()
    if #def.Label > maxNameWidth then
        maxNameWidth = #def.Label
    end
end

-- 第二趟：原地左填充到统一宽度
for level = 1, #levelDefs do
    local def = levelDefs[level]
    def.Label = string.rep(" ", maxNameWidth - #def.Label) .. def.Label
end

-- ============================================================
-- 配置
-- ============================================================

log.Level = 3     -- 默认 Info（= levelDefs[3]）；也可写 log.Level = log.Levels.Info
log.OutFile = nil -- nil = 不写文件; 相对 data/, 自动补 .txt
log.Fold = true   -- 连续相同折叠
log.MaxTable = 3  -- table 显示前几项

-- 从 levelDefs 反向生成 名字 → 索引，避免手写第二份常量
log.Levels = {}
for level = 1, #levelDefs do
    log.Levels[levelDefs[level].Name] = level
end

---@return integer
local function getCurrentLevel()
    return log.Level or log.Levels.Info
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
-- 时间：统一格式 MM:SS.mmm
--   SysTime 与 CurTime 共用，区别仅在时间源
--   小时位模掉（debug 窗口 < 1 小时，回绕无歧义）
-- ============================================================

---@param seconds number
---@return string
local function formatTime(seconds)
    local totalMilliseconds = math.floor(seconds * 1000)
    local totalSeconds = math.floor(totalMilliseconds / 1000)
    return string.format("%02d:%02d.%03d",
        math.floor(totalSeconds / 60) % 60, -- 分钟：模 60 → 2 位
        totalSeconds % 60,                  -- 秒：  模 60 → 2 位
        totalMilliseconds % 1000)           -- 毫秒：模 1000 → 3 位
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

    local def = levelDefs[level]
    if not def then return end
    local color = def.Color

    local count = select("#", ...)
    local parts = {}
    for index = 1, count do
        local value = select(index, ...)
        parts[index] = formatValue(value)
    end
    local text = table.concat(parts, " ")

    local source, line = findCaller()
    local head = string.format("[%s][%05d][%s][%s][%s:%d]",
        formatTime(SysTime()),
        engine.TickCount() % 100000, -- 66 tick/s 下覆盖 ≈ 25 分钟
        formatTime(CurTime()),
        def.Label,
        source, line)

    if not log.Fold then
        emitLine(color, head, text, 1)
        return
    end

    -- 用 def.Name（驼峰）作签名，天然按级别隔离
    local signature = def.Name .. "\0" .. source .. ":" .. line .. "\0" .. text
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
-- 动态挂载各级别函数：log.Trace / log.Debug / log.Info / log.Warn / log.Error
-- ============================================================

for level = 1, #levelDefs do
    local def = levelDefs[level]
    log[def.Name] = function (...) logAt(level, ...) end
end

-- 定时 flush, 让折叠计数能看到
timer.Create("CharleneHooLogAutoSave", 1.5, 0, flushPending)

_G._CharleneHooLog = log
return log
