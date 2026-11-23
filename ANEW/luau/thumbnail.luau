--!native
local serde=require("@lune/serde")
local task=require("@lune/task")
local Mesh=require("./geometry")
local Place=require("./place")
local WIDTH,HEIGHT=480,270
local W,H=WIDTH*2,HEIGHT*2
local light=Mesh.unit({-.4,.87,.45})
local camera=Mesh.unit({.66,.54,.74})
local forward={-camera[1],-camera[2],-camera[3]}
local right=Mesh.unit(Mesh.cross(forward,{0,1,0}))
local up=Mesh.cross(right,forward)
local lut={}
for i=0,255 do
    local t=i
    for _=1,8 do t=bit32.bxor(bit32.rshift(t,1),if t%2==1 then 0xedb88320 else 0) end
    lut[i]=t
end
local function chunk(tag,data)
    local crc=4294967295
    for i=1,#tag do crc=bit32.bxor(bit32.rshift(crc,8),lut[bit32.band(bit32.bxor(crc,tag:byte(i)),255)]) end
    for i=1,#data do crc=bit32.bxor(bit32.rshift(crc,8),lut[bit32.band(bit32.bxor(crc,data:byte(i)),255)]) end
    return string.pack(">I4",#data)..tag..data..string.pack(">I4",bit32.bnot(crc))
end
local function draw(pixels,depth,a,b,c,red,green,blue)
    local dx,dy=b[1]-a[1],b[2]-a[2]
    local ex,ey=c[1]-a[1],c[2]-a[2]
    local div=dx*ey-dy*ex
    if math.abs(div)<.0001 then return end
    local x0=math.max(0,math.floor(math.min(a[1],b[1],c[1])))
    local y0=math.max(0,math.floor(math.min(a[2],b[2],c[2])))
    local x1=math.min(W-1,math.ceil(math.max(a[1],b[1],c[1])))
    local y1=math.min(H-1,math.ceil(math.max(a[2],b[2],c[2])))
    local du,dv=ey/div,-dy/div
    local dz1,dz2=b[3]-a[3],c[3]-a[3]
    local dl1,dl2=b[4]-a[4],c[4]-a[4]
    for y=y0,y1 do
        local ox,oy=x0+.5-a[1],y+.5-a[2]
        local u,v=(ox*ey-oy*ex)/div,(dx*oy-dy*ox)/div
        for x=x0,x1 do
            if u>=-1e-6 and v>=-1e-6 and u+v<=1.000001 then
                local z=a[3]+u*dz1+v*dz2
                local i=y*W+x
                if z>buffer.readf32(depth,i*4) then
                    buffer.writef32(depth,i*4,z)
                    local shade=a[4]+u*dl1+v*dl2
                    buffer.writeu8(pixels,i*3,math.min(255,255*red*shade+9))
                    buffer.writeu8(pixels,i*3+1,math.min(255,255*green*shade+12))
                    buffer.writeu8(pixels,i*3+2,math.min(255,255*blue*shade+14))
                end
            end
            u,v=u+du,v+dv
        end
    end
end
local Thumbnail={}
function Thumbnail.render(place)
    local center={place.spawn.x,place.spawn.y,place.spawn.z}
    local minimum,maximum=table.clone(center),table.clone(center)
    local size=0
    for _,part in ipairs(place.objects) do
        local lo,hi=Place.bounds(part)
        for axis=1,3 do minimum[axis]=math.min(minimum[axis],lo[axis]); maximum[axis]=math.max(maximum[axis],hi[axis]) end
    end
    for axis=1,3 do center[axis]=(minimum[axis]+maximum[axis])*.5; size+=(maximum[axis]-minimum[axis])^2 end
    local distance=math.max(10,math.sqrt(size)*1.16)
    local eye={center[1]+camera[1]*distance,center[2]+camera[2]*distance,center[3]+camera[3]*distance}
    local pixels,depth=buffer.create(W*H*3),buffer.create(W*H*4)
    for y=0,H-1 do
        local f=y/H
        for x=0,W-1 do
            local i=(y*W+x)*3
            buffer.writeu8(pixels,i,208+35*f); buffer.writeu8(pixels,i+1,232+15*f); buffer.writeu8(pixels,i+2,249-11*f)
        end
    end
    local count=0
    for _,part in ipairs(place.objects) do
        local r,g,b=Mesh.rgb(part.color)
        local rotation=Place.rotation(part.rotation)
        local vertices={}
        local function project(v)
            if vertices[v] then return vertices[v] end
            local p=Mesh.rotate(rotation,v[1]*part.size[1],v[2]*part.size[2],v[3]*part.size[3])
            for i=1,3 do p[i]+=part.position[i]-eye[i] end
            local n=Mesh.unit(Mesh.rotate(rotation,v[4]/part.size[1],v[5]/part.size[2],v[6]/part.size[3]))
            local z=math.max(.1,Mesh.dot(p,forward))
            local s=H*1.18/z
            local o={W/2+Mesh.dot(p,right)*s,H*.51-Mesh.dot(p,up)*s,1/z,.68+.44*math.max(0,Mesh.dot(n,light)),Mesh.dot(n,camera)}
            vertices[v]=o
            return o
        end
        for _,triangle in ipairs(Mesh[part.kind]) do
            local a,v,c=project(triangle[1]),project(triangle[2]),project(triangle[3])
            if a[5]>0 or v[5]>0 or c[5]>0 then draw(pixels,depth,a,v,c,r,g,b) end
        end
        count+=1
        if count%24==0 then task.wait() end
    end
    local stride=WIDTH*3+1
    local data=buffer.create(HEIGHT*stride)
    for y=0,HEIGHT-1 do
        local previous={0,0,0}
        buffer.writeu8(data,y*stride,1)
        for x=0,WIDTH-1 do
            local src=((2*y)*W+2*x)*3
            for c=0,2 do
                local i=src+c
                local k=math.floor((buffer.readu8(pixels,i)+buffer.readu8(pixels,i+3)+buffer.readu8(pixels,i+W*3)+buffer.readu8(pixels,i+W*3+3))/4)
                buffer.writeu8(data,y*stride+1+x*3+c,(k-previous[c+1])%256)
                previous[c+1]=k
            end
        end
    end
    return "\137PNG\13\10\26\10" ..
        chunk("IHDR",string.pack(">I4I4BBBBB",WIDTH,HEIGHT,8,2,0,0,0)) ..
        chunk("IDAT",serde.compress("zlib",buffer.tostring(data)))..chunk("IEND","")
end
return Thumbnail
