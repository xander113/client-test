-- Validate a deliberately small Lua/Luau grammar before compiling it in a Pot-only environment.
local luau = require("@lune/luau")

local Script = { maxSource = 4096 }
local binary = {
    ["or"]=1, ["and"]=2, ["=="]=3, ["~="]=3, ["<"]=3, [">"]=3, ["<="]=3, [">="]=3,
    ["+"]=4, ["-"]=4, ["*"]=5, ["/"]=5, ["%"]=5,
}
local reserved = {}
for v in ("and break do else elseif end export false for function if in local nil not or repeat return then true type until while Pot"):gmatch("%S+") do
    reserved[v] = true
end
local arity = {setColor=2, setSolid=2, setVisible=2, pulse=3, setFlag=2, flag=1, isSolid=1, spawn=2}
local readable = {flag=true, isSolid=true}
local tags = {boolean=true, number=true, string=true}
local events = {onPress=true,onTouch=true,onSpawn=true}

local function lex(source)
    assert(type(source) == "string" and #source <= Script.maxSource, "Scripts are limited to 4 KB.")
    local tokens, pos, line = {}, 1, 1
    while pos <= #source do
        local c = source:sub(pos,pos)
        if c == "\n" then pos += 1; line += 1
        elseif c == " " or c == "\t" or c == "\r" then pos += 1
        elseif source:sub(pos,pos+1) == "--" then
            pos = source:find("\n",pos+2,true) or #source+1
        else
            local kind, value
            if c == '"' or c == "'" then
                local start = pos
                pos += 1
                while pos <= #source and source:sub(pos,pos) ~= c do
                    local s = source:sub(pos,pos)
                    assert(s:byte() >= 32, "Line "..line..": use a separate quoted string on one line.")
                    if s == "\\" then
                        pos += 1
                        assert(source:sub(pos,pos):match([=[^[\\"'nt]$]=]), "Line "..line..": unsupported escape.")
                    end
                    pos += 1
                end
                assert(pos <= #source, "Line "..line..": missing closing quote.")
                value, kind = source:sub(start,pos), "literal"
                pos += 1
            else
                value = source:match("^[%a_][%w_]*",pos)
                if value then kind = "word"
                else
                    value = source:match("^%d+%.?%d*",pos)
                    if value then kind = "literal"
                    else
                        local double = source:sub(pos,pos+1)
                        value = ({["=="]=true,["~="]=true,["<="]=true,[">="]=true})[double] and double or c
                        assert(value ~= c or c:match("^[.,:;()%+%-%*/%%<>=]$"), "Line "..line..": unsupported character.")
                        kind = "token"
                    end
                end
                pos += #value
            end
            tokens[#tokens+1] = {text = value, kind = kind, line = line}
            assert(#tokens <= 900, "This script has too many statements.")
        end
    end
    tokens[#tokens+1] = {text = "<eof>", line = line}
    return tokens
end

function Script.compile(source,kind,hasPart)
    local tokens, at, nesting = lex(source), 1, 0
    local function peek() return tokens[at].text end
    local function check(ok, message)
        if not ok then error("Line "..tokens[at].line..": "..message, 0) end
    end
    local function take(text)
        check(peek() == text, "expected '"..text.."'.")
        at += 1
    end
    local function enter()
        nesting += 1
        check(nesting <= 14, "expressions or callbacks are nested too far.")
    end
    local function leave() nesting -= 1 end
    local function identifier()
        local token = tokens[at]
        check(token.kind == "word" and not reserved[token.text], "expected a local name.")
        at += 1
        if peek() == ":" then
            take(":")
            check(tags[peek()], "use a number, string or boolean type.")
            at += 1
        end
        return token.text
    end
    local expression, block
    local function args(scope, name)
        take("(")
        for i = 1, arity[name] do
            if i > 1 then take(",") end
            expression(scope, 1)
        end
        take(")")
    end
    expression = function(scope, minimum)
        enter()
        local first = peek()
        if first == "not" or first == "-" then
            at += 1
            expression(scope, 6)
        elseif first == "(" then
            take("("); expression(scope, 1); take(")")
        elseif first == "Pot" then
            take("Pot"); take(".")
            local call = peek()
            check(readable[call], "use Pot.flag or Pot.isSolid in expressions.")
            at += 1
            args(scope, call)
        else
            check(tokens[at].kind == "literal" or first == "true" or first == "false" or first == "nil" or scope[first],
                "use a literal, local, Pot.flag or Pot.isSolid.")
            at += 1
        end
        while (binary[peek()] or 0) >= minimum do
            local priority = binary[peek()]
            at += 1
            expression(scope, priority+1)
        end
        leave()
    end
    local function callback(scope, actor)
        take("function"); take("(")
        local locals = table.clone(scope)
        if actor and peek() ~= ")" then locals[identifier()] = true end
        take(")")
        block(locals)
        take("end")
    end
    block = function(scope)
        enter()
        while peek() ~= "end" and peek() ~= "else" do
            local first = peek()
            if first == "local" then
                take("local")
                local name = identifier()
                take("=")
                expression(scope,1)
                scope[name] = true
            elseif first == "if" then
                take("if"); expression(scope,1); take("then")
                block(table.clone(scope))
                if peek() == "else" then take("else"); block(table.clone(scope)) end
                take("end")
            elseif first == "Pot" then
                take("Pot"); take(".")
                local name = peek()
                check((arity[name] and not readable[name]) or name == "after", "this Pot action is unavailable.")
                check(kind~="local" or (name~="setSolid" and name~="spawn"),"this action requires a Script running on the server.")
                at += 1
                if name == "after" then
                    take("("); expression(scope,1); take(","); callback(scope,false); take(")")
                else args(scope,name) end
            else
                check(false, "use a Pot action, local or if. Loops and general code are unavailable.")
            end
            if peek() == ";" then take(";") end
        end
        leave()
    end
    while peek() ~= "<eof>" do
        take("Pot"); take(".")
        check(events[peek()], "start with Pot.onPress, Pot.onTouch or Pot.onSpawn.")
        check(hasPart~=false or peek()=="onSpawn", "press and touch callbacks require a part ancestor.")
        at += 1
        take("("); callback({}, true); take(")")
        if peek() == ";" then take(";") end
    end

    -- Reassemble screened tokens. The compiler never receives comments or unparsed bytes.
    local clean = {}
    for i=1,#tokens-1 do clean[i]=tokens[i].text end
    return luau.compile(table.concat(clean," "))
end

function Script.attach(code, api)
    local fn = luau.load(code, {environment = {Pot = table.freeze(api)}, injectGlobals=false, debugName="Pot script"})
    fn()
end
return Script
