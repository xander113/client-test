-- Row-major RGBA texels shared by the desktop and the map renderer.
local Texture={maxSize=128,maxAssets=16}
Texture.faces={"All faces","Right","Left","Top","Bottom","Back","Front"}
Texture.ids={"pot-brick","pot-wood","pot-stone","pot-grid"}
local builtinNames={
    ["pot-brick"]="Brick",["pot-wood"]="Timber",["pot-stone"]="Slate",["pot-grid"]="Studio grid",
}
local builtin={}

local function noise(x,y)
    return (x*13+y*31+x*y*7)%19
end

local function texel(id,x,y,n)
    local d=noise(x,y)
    if id=="pot-brick" then
        if y%12<=1 or (x+math.floor(y/12)*12)%24<=1 then return 203,189,171,232 end
        return 156+d,86+d,66+d,234
    elseif id=="pot-wood" then
        if y%12==0 then return 112,74,44,232 end
        d=(math.floor(5*math.sin(x*.28+y*2))+x%3+y%7)
        return 162+d*2,114+d*2,64+d,238
    elseif id=="pot-stone" then
        if x%24==0 or y%24==0 then return 105,112,113,232 end
        return 149+d,159+d,161+d,230
    else
        if x==0 or y==0 then return 116,143,127,235 end
        if x==n/2 or y==n/2 then return 151,172,157,222 end
        return 214,226,217,210
    end
end

function Texture.builtinName(id) return builtinNames[id] end

function Texture.asset(scene,id)
    if builtinNames[id] then
        if not builtin[id] then
            local n=48
            local data={}
            for y=0,n-1 do
                for x=0,n-1 do data[#data+1]=string.char(texel(id,x,y,n)) end
            end
            builtin[id]={id=id,name=builtinNames[id],width=n,height=n,pixels={data=table.concat(data)}}
        end
        return builtin[id]
    end
    for _,entry in ipairs(scene.textures or {}) do if entry.id==id then return entry end end
end

function Texture.face(x,y,z)
    local ax,ay,az=math.abs(x),math.abs(y),math.abs(z)
    if ax>=ay and ax>=az then return x>=0 and 1 or 2 end
    if ay>=az then return y>=0 and 3 or 4 end
    return z>=0 and 5 or 6
end

function Texture.uv(face,v,d,layer)
    local x,y,z=v[1],v[2],v[3]
    local u,t,wide,high
    if face<=2 then
        u,t,wide,high=face==1 and -z or z,-y,d[3],d[2]
    elseif face<=4 then
        u,t,wide,high=x,face==3 and z or -z,d[1],d[3]
    else
        u,t,wide,high=face==5 and -x or x,-y,d[1],d[2]
    end
    if layer.mode=="tile" then return (u+.5)*wide/layer.tileU,(t+.5)*high/layer.tileV end
    return u+.5,t+.5
end

return Texture
