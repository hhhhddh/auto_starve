-- Outbound JSON must be strict: the game's save-data encoder also accepts
-- values/escapes that encoding/json on the relay cannot consume.
local M = {}
M.null = {}
local array_mt = {}

function M.array(value)
    return setmetatable(value or {}, array_mt)
end

local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        if char == '"' then return '\\"' end
        if char == '\\' then return '\\\\' end
        return string.format("\\u%04x", string.byte(char))
    end) .. '"'
end

local function utf8(code)
    if code < 128 then
        -- Lua decimal escapes also protect quotes, backslashes and controls.
        return string.format("\\%03d", code)
    elseif code < 2048 then
        return string.char(192 + math.floor(code / 64), 128 + code % 64)
    elseif code < 65536 then
        return string.char(224 + math.floor(code / 4096),
            128 + math.floor(code / 64) % 64, 128 + code % 64)
    end
    return string.char(240 + math.floor(code / 262144), 128 + math.floor(code / 4096) % 64,
        128 + math.floor(code / 64) % 64, 128 + code % 64)
end

-- DST's JSON4Lua evaluates string literals with Lua 5.1 loadstring. Translate
-- JSON Unicode escapes before handing them over, without touching literal
-- backslash-u text (e.g. "\\\\u1234") or treating escaped quotes as delimiters.
function M.decode(text, game_decode)
    local pieces, position, copied, in_string = {}, 1, 1, false
    local function hex(at)
        local digits = text:sub(at, at + 3)
        assert(#digits == 4 and digits:match("^[0-9a-fA-F]+$"), "无效 Unicode 转义")
        return tonumber(digits, 16)
    end
    while position <= #text do
        local at = text:find('["\\]', position)
        if at == nil then break end
        local char = text:sub(at, at)
        if char == '"' then
            in_string = not in_string
            position = at + 1
        elseif in_string and text:sub(at + 1, at + 1) == "u" then
            local code, after = hex(at + 2), at + 6
            if code >= 55296 and code <= 56319 then
                assert(text:sub(after, after + 1) == "\\u", "缺少 Unicode 低代理项")
                local low = hex(after + 2)
                assert(low >= 56320 and low <= 57343, "无效 Unicode 低代理项")
                code = 65536 + (code - 55296) * 1024 + low - 56320
                after = after + 6
            else
                assert(code < 56320 or code > 57343, "孤立的 Unicode 低代理项")
            end
            pieces[#pieces + 1] = text:sub(copied, at - 1)
            pieces[#pieces + 1] = utf8(code)
            position, copied = after, after
        else
            position = at + (in_string and 2 or 1)
        end
    end
    pieces[#pieces + 1] = text:sub(copied)
    return game_decode(table.concat(pieces))
end

function M.encode(value, limit)
    local pieces, bytes, ancestors = {}, 0, {}
    local function emit(piece)
        bytes = bytes + #piece
        if bytes > (limit or 65536) then
            error("结果超过请求体大小限制", 0)
        end
        pieces[#pieces + 1] = piece
    end
    local encode
    encode = function(item, depth)
        if item == nil or item == M.null then
            emit("null")
            return
        end
        local kind = type(item)
        if kind == "boolean" then
            emit(item and "true" or "false")
        elseif kind == "number" then
            if item ~= item or item == math.huge or item == -math.huge then
                error("结果包含非有限数字", 0)
            end
            emit(string.format("%.17g", item))
        elseif kind == "string" then
            if #item > (limit or 65536) then error("结果字符串过长", 0) end
            emit(quote(item))
        elseif kind == "table" then
            if depth > 32 or ancestors[item] then
                error("结果嵌套过深或存在循环引用", 0)
            end
            ancestors[item] = true
            local count, max_index, numeric = 0, 0, true
            for key in next, item do
                count = count + 1
                if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                    numeric = false
                else
                    max_index = math.max(max_index, key)
                end
                if count > (limit or 65536) then error("结果包含过多字段", 0) end
            end
            local array = getmetatable(item) == array_mt or (count > 0 and numeric and max_index == count)
            if array then
                if count ~= max_index or not numeric then error("结果数组索引不连续", 0) end
                emit("[")
                for i = 1, max_index do
                    if i > 1 then emit(",") end
                    encode(rawget(item, i), depth + 1)
                end
                emit("]")
            else
                emit("{")
                local first = true
                for key, child in next, item do
                    if type(key) ~= "string" then error("结果对象的键必须为字符串", 0) end
                    if not first then emit(",") end
                    first = false
                    emit(quote(key))
                    emit(":")
                    encode(child, depth + 1)
                end
                emit("}")
            end
            ancestors[item] = nil
        else
            error("结果包含不能转换为 JSON 的类型：" .. kind, 0)
        end
    end
    encode(value, 0)
    return table.concat(pieces)
end

return M
