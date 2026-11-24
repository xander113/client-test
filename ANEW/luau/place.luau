local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Wire = require("./wire")
local Script = require("./scripting")
local Hierarchy = require("./hierarchy")
local Texture = require("./texture")

local Place = {version=5, limit=1536*1024, magic="POT\0\1"}
local sequence = 0
local nonce = math.random(0,0xffffff)
local kinds = {box=true,sphere=true,cylinder=true,spawn=true}

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
function Place.text(s, max, required)
    local chars = type(s)=="string" and utf8.len(s)
    return chars and chars<=max and (not required or s:find("%S")) and not s:find("%c")
end
local text=Place.text
local function vector(v, lo, hi, lowY)
    return type(v)=="table" and #v==3 and Place.number(v[1],lo,hi) and
        Place.number(v[2],lowY or lo,hi) and Place.number(v[3],lo,hi)
end

function Place.validate(p)
    assert(type(p)=="table" and Place.number(p.schemaVersion,1,Place.version) and p.schemaVersion%1==0,
        "Unsupported Pot project version.")
    local old = p.schemaVersion
    assert(Place.id(p.id) and text(p.name,80,true) and text(p.description,400,false), "Invalid place name, ID or description.")
    assert(type(p.spawn)=="table" and vector({p.spawn.x,p.spawn.y,p.spawn.z},-250,250,-40), "Spawn is outside the place.")
    assert(type(p.objects)=="table" and #p.objects<=400, "A place has at most 400 parts.")
    assert(old<4 or p.allowReset==nil or type(p.allowReset)=="boolean", "Invalid character reset policy.")
    local movement=if old>=5 then p.movement else nil
    assert(movement==nil or type(movement)=="table", "Invalid movement settings.")
    local speed,jump=movement and movement.walkSpeed,movement and movement.jumpHeight
    assert((speed==nil or Place.number(speed,0,64)) and (jump==nil or Place.number(jump,0,32)), "Invalid WalkSpeed or JumpHeight.")
    if speed==16 then speed=nil end
    if jump==7.2 then jump=nil end
    local result = {
        schemaVersion=Place.version,id=p.id,name=p.name,description=p.description,
        spawn={x=p.spawn.x,y=p.spawn.y,z=p.spawn.z}, allowReset=old<4 or p.allowReset~=false,
        objects=Wire.array(),scripts=Wire.array(),textures=Wire.array(),
        movement=if speed~=nil or jump~=nil then {walkSpeed=speed,jumpHeight=jump} else nil,
    }
    local assets=if old>=5 and p.textures~=nil then p.textures else {}
    assert(type(assets)=="table" and #assets<=Texture.maxAssets,"A world can keep up to "..Texture.maxAssets.." imported textures.")
    local known={}
    for _,asset in ipairs(assets) do
        assert(type(asset)=="table" and Place.id(asset.id) and text(asset.name,64,true) and not known[asset.id]
            and not Texture.builtinName(asset.id),"Invalid or duplicate texture asset.")
        local w,h=asset.width,asset.height
        assert(Place.number(w,1,Texture.maxSize) and Place.number(h,1,Texture.maxSize) and w%1==0 and h%1==0
            and Wire.isBytes(asset.pixels) and type(asset.pixels.data)=="string" and #asset.pixels.data==w*h*4,
            "Invalid texture pixels for "..asset.name..".")
        known[asset.id]=true
        result.textures[#result.textures+1]={id=asset.id,name=asset.name,width=w,height=h,pixels=asset.pixels}
    end
    local ids = {}
    for i,o in ipairs(p.objects) do
        assert(type(o)=="table" and Place.id(o.id) and not ids[o.id] and kinds[o.kind] and text(o.name,80,true),
            "Invalid or duplicate part at row "..i..".")
        local rotation = if old == 1 then {0,0,0} else o.rotation
        assert(vector(o.position,-250,250,-40) and vector(o.size,.1,128) and vector(rotation,-180,180), "Invalid transform for "..o.name..".")
        assert(Place.color(o.color) and type(o.solid)=="boolean", "Invalid appearance for "..o.name..".")
        ids[o.id]=true
        assert(old<4 or o.parent==nil or Place.id(o.parent),"Invalid part parent.")
        assert(o.kind~="spawn" or (old>=4 and type(o.enabled)=="boolean"),"Invalid spawn point.")
        local part={id=o.id,name=o.name,kind=o.kind,position=table.clone(o.position),
            size=table.clone(o.size),rotation=table.clone(rotation),color=o.color:lower(),solid=o.solid,
            parent=if old>=4 then o.parent else nil,enabled=if o.kind=="spawn" then o.enabled else nil}
        if old>=5 and o.textures~=nil then
            assert(type(o.textures)=="table" and #o.textures<=#Texture.faces,"Invalid part textures.")
            local seen={}
            part.textures=Wire.array()
            for _,layer in ipairs(o.textures) do
                assert(type(layer)=="table" and Place.number(layer.face,0,#Texture.faces-1) and layer.face%1==0
                    and not seen[layer.face] and Place.id(layer.asset) and (known[layer.asset] or Texture.builtinName(layer.asset))
                    and (layer.mode=="tile" or layer.mode=="fit") and Place.number(layer.tileU,.25,128)
                    and Place.number(layer.tileV,.25,128),"Invalid texture layer on "..o.name..".")
                seen[layer.face]=true
                part.textures[#part.textures+1]={face=layer.face,asset=layer.asset,mode=layer.mode,tileU=layer.tileU,tileV=layer.tileV}
            end
            table.sort(part.textures,function(a,b)return a.face<b.face end)
        end
        result.objects[i]=part
    end
    local scripts = if old>=3 then p.scripts else {}
    assert(type(scripts)=="table" and #scripts<=48, "A place has at most 48 scripts.")
    for i,s in ipairs(scripts) do
        assert(type(s)=="table" and type(s.source)=="string"
            and #s.source<=Script.maxSource and utf8.len(s.source) and type(s.enabled)=="boolean",
            "Invalid script at row "..i..".")
        local id,name,kind,parent=s.id,s.name,s.kind,s.parent
        if old==3 then
            assert(Place.id(s.part) and ids[s.part],"Invalid script part.")
            id,name,kind,parent="script-"..i,"Script","script",s.part
            while ids[id] do id..="-s" end
        end
        assert(Place.id(id) and not ids[id] and text(name,80,true) and (kind=="script" or kind=="local")
            and (parent==nil or Place.id(parent)),"Invalid script name, ID, type or parent.")
        ids[id]=true
        result.scripts[i]={id=id,name=name,kind=kind,parent=parent,source=s.source,enabled=s.enabled}
    end
    local nodes=Hierarchy.index(result)
    for _,node in pairs(nodes) do
        assert(Hierarchy.canParent(nodes,node,node.parent),"Invalid hierarchy at "..node.name..". A parent must exist and cannot be a descendant.")
    end
    if old>=4 and p.defaultSpawn~=nil then
        local spawn=Place.id(p.defaultSpawn) and nodes[p.defaultSpawn]
        assert(spawn and spawn.kind=="spawn" and spawn.enabled,"Default spawn must be an enabled spawn point.")
        result.defaultSpawn=p.defaultSpawn
    end
    return result
end

function Place.wire(p)
    local canonical=Place.validate(p)
    local content=Wire.encode(canonical)
    assert(#content+#Place.magic<=Place.limit,"Place is too large. Remove unused textures, parts or scripts.")
    return canonical, content
end

function Place.programs(p,kind)
    local result={}
    local nodes=Hierarchy.index(p)
    for _,s in ipairs(p.scripts) do
        if s.enabled and (not kind or kind==s.kind) then
            local owner=Hierarchy.owner(nodes,s)
            local ok,code=pcall(Script.compile,s.source,s.kind,owner~=nil)
            assert(ok,s.name..": "..tostring(code))
            result[#result+1]={part=owner and owner.id,code=code}
        end
    end
    return result
end

function Place.spawnInfo(p)
    local points=Wire.array()
    for _,part in ipairs(p.objects) do
        if part.kind=="spawn" then
            points[#points+1]={id=part.id,name=part.name,enabled=part.enabled,position=part.position,yaw=part.rotation[2]}
        end
    end
    return {allowReset=p.allowReset,defaultSpawn=p.defaultSpawn,fallback=p.spawn,points=points}
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
