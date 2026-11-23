local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Wire = require("./wire")
local Script = require("./scripting")

local Place = {version=3, limit=256*1024, magic="POT\0\1"}
local sequence = 0
local nonce = math.random(0,0xffffff)
local kinds = {box=true,sphere=true,cylinder=true}

function Place.id(s)
    return type(s)=="string" and #s<=64 and s:match("^[a-z0-9][a-z0-9%-]*$") ~= nil
end
function Place.color(s)
    return type(s)=="string" and s:match("^#%x%x%x%x%x%x$") ~= nil
end
function Place.number(n, lo, hi)
    return type(n)=="number" and n>=lo and n<=hi
end
function Place.serial()
    sequence += 1
    -- Unique within a live process. The native app supplies independent process identities.
    return string.format("%x-%x-%x-%x", os.time(), math.floor(os.clock()*1000), nonce, sequence)
end
local function text(s, max, required)
    local chars = type(s)=="string" and utf8.len(s)
    return chars and chars<=max and (not required or s:find("%S")) and not s:find("%c")
end
local function vector(v, lo, hi, lowY)
    return type(v)=="table" and #v==3 and Place.number(v[1],lo,hi) and
        Place.number(v[2],lowY or lo,hi) and Place.number(v[3],lo,hi)
end

function Place.validate(p)
    assert(type(p)=="table" and (p.schemaVersion == 3 or p.schemaVersion == 2 or p.schemaVersion == 1), "Unsupported Pot project version.")
    local old = p.schemaVersion
    assert(Place.id(p.id) and text(p.name,80,true) and text(p.description,400,false), "Invalid place name, ID or description.")
    assert(type(p.spawn)=="table" and vector({p.spawn.x,p.spawn.y,p.spawn.z},-250,250,-40), "Spawn is outside the place.")
    assert(type(p.objects)=="table" and #p.objects<=400, "A place has at most 400 parts.")
    local result = {
        schemaVersion=Place.version,id=p.id,name=p.name,description=p.description,
        spawn={x=p.spawn.x,y=p.spawn.y,z=p.spawn.z},objects=Wire.array(),scripts=Wire.array(),
    }
    local ids = {}
    for i,o in ipairs(p.objects) do
        assert(type(o)=="table" and Place.id(o.id) and not ids[o.id] and kinds[o.kind] and text(o.name,80,true),
            "Invalid or duplicate part at row "..i..".")
        local rotation = if old == 1 then {0,0,0} else o.rotation
        assert(vector(o.position,-250,250,-40) and vector(o.size,.1,128) and vector(rotation,-180,180), "Invalid transform for "..o.name..".")
        assert(Place.color(o.color) and type(o.solid)=="boolean", "Invalid appearance for "..o.name..".")
        ids[o.id]=true
        result.objects[i]={id=o.id,name=o.name,kind=o.kind,position=table.clone(o.position),
            size=table.clone(o.size),rotation=table.clone(rotation),color=o.color:lower(),solid=o.solid}
    end
    local scripts = if old == 3 then p.scripts else {}
    assert(type(scripts)=="table" and #scripts<=48, "A place has at most 48 scripts.")
    local used = {}
    for i,s in ipairs(scripts) do
        assert(type(s)=="table" and ids[s.part] and not used[s.part] and type(s.source)=="string"
            and #s.source<=Script.maxSource and utf8.len(s.source) and type(s.enabled)=="boolean",
            "Invalid script or multiple scripts on one part.")
        used[s.part]=true
        result.scripts[i]={part=s.part,source=s.source,enabled=s.enabled}
    end
    return result
end

function Place.wire(p)
    local canonical=Place.validate(p)
    local content=Wire.encode(canonical)
    assert(#content+#Place.magic<=Place.limit,"Place is too large. Remove some parts or scripts.")
    return canonical, content
end

function Place.programs(p)
    local result={}
    for _,s in ipairs(p.scripts) do
        if s.enabled then
            local ok, code = pcall(Script.compile,s.source)
            assert(ok, "Script on "..s.part..": "..tostring(code))
            result[s.part]=code
        end
    end
    return result
end

function Place.decode(data)
    assert(type(data)=="string" and #data<=Place.limit,"Invalid Pot file size.")
    if data:sub(1,#Place.magic)==Place.magic then
        return Place.validate(Wire.decode(data:sub(#Place.magic+1),Place.limit))
    end
    data = data:gsub("^\239\187\191", "")
    assert(data:find("^%s*{"),"Choose a .pot project file.")
    local legacy=serde.decode("json",data)
    assert(legacy.schemaVersion==1,"Unsupported legacy Pot project.")
    return Place.validate(legacy)
end

function Place.load(path)
    local info=fs.metadata(path)
    assert(info.exists and info.kind=="file" and info.size<=Place.limit,"Choose a Pot project within the size limit.")
    return Place.decode(fs.readFile(path))
end

function Place.save(path,p)
    assert(type(path)=="string" and path:lower():match("%.pot$"),"Save with a .pot filename.")
    local canonical, content=Place.wire(p)
    local tmp=path..".tmp-"..Place.serial()
    local ok, problem=pcall(function()
        fs.writeFile(tmp,Place.magic..content)
        fs.move(tmp,path,true)
    end)
    if not ok then
        if fs.isFile(tmp) then fs.removeFile(tmp) end
        error(problem,0)
    end
    return canonical
end

function Place.rotation(v)
    local x,y,z=math.rad(v[1]),math.rad(v[2]),math.rad(v[3])
    local a,b,c,d,e,f=math.cos(x),math.sin(x),math.cos(y),math.sin(y),math.cos(z),math.sin(z)
    return {{c*e,a*f+b*e*d,b*f-a*e*d},{-c*f,a*e-b*f*d,b*e+a*f*d},{d,-b*c,a*c}}
end
function Place.bounds(p)
    local r=Place.rotation(p.rotation)
    local lo,hi={},{}
    for axis=1,3 do
        local margin=(math.abs(r[1][axis])*p.size[1]+math.abs(r[2][axis])*p.size[2]+math.abs(r[3][axis])*p.size[3])*.5
        lo[axis]=p.position[axis]-margin
        hi[axis]=p.position[axis]+margin
    end
    return lo,hi
end
return Place
