-- Binary MessagePack values used by projects, sessions, and the native desktop pipe.
local Wire = { limit = 2 * 1024 * 1024, mime = "application/msgpack" }
local arrayType, bytesType = {}, {}
local pack, unpack = string.pack, string.unpack
if love then
    pack = function(fmt, ...) return love.data.pack("string", fmt, ...) end
    unpack = love.data.unpack
end
function Wire.array(items) return setmetatable(items or {}, arrayType) end
function Wire.bytes(data) return setmetatable({data = data}, bytesType) end
function Wire.isArray(items) return type(items) == "table" and getmetatable(items) == arrayType end
function Wire.isBytes(value) return type(value) == "table" and getmetatable(value) == bytesType end

local byte, char = string.byte, string.char
local function prefix(n, small, offset, eight, sixteen, thirtyTwo)
    if small and n < small then return char(offset + n) end
    if eight and n < 256 then return char(eight, n) end
    if n < 65536 then return char(sixteen) .. pack(">I2", n) end
    return char(thirtyTwo) .. pack(">I4", n)
end

local function encode(value, out, depth)
    assert(depth <= 24, "binary value nested too deeply")
    local kind = type(value)
    if kind == "nil" then out[#out+1] = "\192"
    elseif kind == "boolean" then out[#out+1] = value and "\195" or "\194"
    elseif kind == "number" then
        if value % 1 ~= 0 or value < -2147483648 or value > 4294967295 then
            out[#out+1] = "\203" .. pack(">d", value)
        elseif value >= 0 and value < 128 then out[#out+1] = char(value)
        elseif value >= -32 and value < 0 then out[#out+1] = char(256 + value)
        elseif value >= 0 and value < 256 then out[#out+1] = char(204, value)
        elseif value >= 0 and value < 65536 then out[#out+1] = "\205" .. pack(">I2", value)
        elseif value >= 0 then out[#out+1] = "\206" .. pack(">I4", value)
        else out[#out+1] = "\210" .. pack(">i4", value) end
    elseif kind == "string" then
        out[#out+1] = prefix(#value, 32, 160, 217, 218, 219)
        out[#out+1] = value
    elseif kind == "table" and Wire.isBytes(value) then
        local s = value.data
        out[#out+1] = prefix(#s, nil, nil, 196, 197, 198)
        out[#out+1] = s
    elseif kind == "table" and (Wire.isArray(value) or #value > 0) then
        out[#out+1] = prefix(#value, 16, 144, nil, 220, 221)
        for i = 1, #value do encode(value[i], out, depth+1) end
    elseif kind == "table" then
        local keys = {}
        for k in pairs(value) do
            assert(type(k) == "string", "binary map keys must be strings")
            keys[#keys+1] = k
        end
        table.sort(keys)
        out[#out+1] = prefix(#keys, 16, 128, nil, 222, 223)
        for _, k in ipairs(keys) do
            encode(k, out, depth+1)
            encode(value[k], out, depth+1)
        end
    else error("unsupported binary value", 0) end
end

function Wire.encode(value)
    local out = {}
    encode(value, out, 0)
    local data = table.concat(out)
    assert(#data <= Wire.limit, "binary packet too large")
    return data
end

local formats = {
    [202]=">f", [203]=">d", [204]=">I1", [205]=">I2", [206]=">I4",
    [207]=">I8", [208]=">i1", [209]=">i2", [210]=">i4", [211]=">i8",
}
local lengths = {
    [196]=">I1", [197]=">I2", [198]=">I4", [217]=">I1", [218]=">I2",
    [219]=">I4", [220]=">I2", [221]=">I4", [222]=">I2", [223]=">I4",
}
function Wire.decode(data, limit)
    assert(type(data) == "string" and #data <= (limit or Wire.limit), "invalid binary packet size")
    local pos, values = 1, 0
    local function read(depth)
        values = values + 1
        assert(depth <= 24 and values <= 30000, "binary packet too complex")
        local code = byte(data, pos)
        assert(code, "truncated binary packet")
        pos = pos + 1
        if code < 128 then return code end
        if code >= 224 then return code - 256 end
        if code == 192 then return nil end
        if code == 194 or code == 195 then return code == 195 end
        local format = formats[code]
        if format then
            local n
            n, pos = unpack(format, data, pos)
            return n
        end
        local n
        if lengths[code] then n, pos = unpack(lengths[code], data, pos)
        elseif code >= 160 and code <= 191 then n = code - 160
        elseif code >= 144 and code <= 159 then n = code - 144
        elseif code >= 128 and code <= 143 then n = code - 128
        else error("unsupported binary tag", 0) end
        if (code >= 160 and code <= 191) or (code >= 217 and code <= 219) or (code >= 196 and code <= 198) then
            assert(n <= #data - pos + 1, "truncated binary string")
            local result = data:sub(pos, pos+n-1)
            pos = pos+n
            if code >= 196 and code <= 198 then return Wire.bytes(result) end
            return result
        end
        assert(n <= math.min(30000, #data - pos + 1), "invalid binary container size")
        if (code >= 144 and code <= 159) or code == 220 or code == 221 then
            local result = Wire.array()
            for i = 1, n do
                local item = read(depth+1)
                assert(item ~= nil, "empty binary array element")
                result[i] = item
            end
            return result
        end
        local result = {}
        for _ = 1, n do
            local key = read(depth+1)
            assert(type(key) == "string" and result[key] == nil, "invalid binary map key")
            local item = read(depth+1)
            result[key] = item
        end
        return result
    end
    local result = read(0)
    assert(pos == #data + 1, "trailing bytes in binary packet")
    return result
end

function Wire.frame(value)
    local raw = Wire.encode(value)
    return pack(">I4", #raw) .. raw
end
function Wire.size(header)
    local n = unpack(">I4", header)
    assert(n > 0 and n <= Wire.limit, "invalid frame size")
    return n
end
return Wire
