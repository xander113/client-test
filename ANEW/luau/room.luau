local Place=require("./place")
local Script=require("./scripting")
local Wire=require("./wire")

local Room={}
local radius,height=.3,1.65
local dt=1/60
local zero={x=0,z=0,yaw=0,jump=0}
local colors={"#09b734","#397db8","#a871ad","#d48650","#4b9a92","#cb6861"}

local function footprint(b,x,z)
    return x+radius>b.lo[1] and x-radius<b.hi[1] and z+radius>b.lo[3] and z-radius<b.hi[3]
end
local function vertical(b,y)
    return y+height>b.lo[2]+.001 and y<b.hi[2]-.001
end
local function reset(r,p)
    p.at={r.spawn.x,r.spawn.y,r.spawn.z}
    p.speed,p.grounded=0,false
    p.contacts={}
    for _,b in ipairs(r.parts) do
        if b.solid and footprint(b,p.at[1],p.at[3]) and vertical(b,p.at[2]) then p.at[2]=math.max(p.at[2],b.hi[2]) end
    end
end
local function near(p,b)
    local q={p.at[1],p.at[2]+height*.65,p.at[3]}
    local distance=0
    for i=1,3 do
        local d=q[i]-math.clamp(q[i],b.lo[i],b.hi[i]); distance+=d*d
    end
    return distance
end

local function report(r,message)
    r.error=tostring(message):sub(1,240)
    r.dirty=true
end
local function invoke(r,callbacks,actor)
    for _,fn in ipairs(callbacks) do
        local ok,err=pcall(fn,actor)
        if not ok then report(r,err) end
    end
end

local function bind(r,part,code)
    local function target(id)
        local b=if id=="self" then part else r.byId[id]
        assert(b,"No part has that ID.")
        return b
    end
    local function update(id,key,value)
        local b=target(id)
        b[key]=value
        r.changed[b.id]=b
        r.dirty=true
    end
    Script.attach(code,{
        onPress=function(fn) part.press[#part.press+1]=fn end,
        onTouch=function(fn) part.touch[#part.touch+1]=fn end,
        flag=function(key) return r.flags[key] or false end,
        isSolid=function(id) return target(id).solid end,
        setFlag=function(key,value)
            assert(type(key)=="string" and #key<=40 and type(value)=="boolean","Write a named boolean flag.")
            if r.flags[key]==nil then
                assert(r.flagCount<64,"This place has too many flags.")
                r.flagCount+=1
            end
            r.flags[key]=value
        end,
        setColor=function(id,color)
            assert(Place.color(color),"Use a #rrggbb color.")
            update(id,"color",color:lower())
        end,
        setSolid=function(id,value)
            assert(type(value)=="boolean","Solidity must be true or false.")
            update(id,"solid",value)
        end,
        setVisible=function(id,value)
            assert(type(value)=="boolean","Visibility must be true or false.")
            update(id,"visible",value)
        end,
        pulse=function(id,seconds,color)
            assert(Place.number(seconds,.1,15) and Place.color(color),"Use a pulse from 0.1 to 15 seconds and a #rrggbb color.")
            local b=target(id)
            b.pulse=color:lower()
            b.untilTime=r.time+seconds
            r.changed[b.id]=b
            r.dirty=true
        end,
        after=function(seconds,fn)
            assert(Place.number(seconds,.1,30),"Delay must be from 0.1 to 30 seconds.")
            assert(#r.timers<96,"This place has too many queued actions.")
            r.timers[#r.timers+1]={time=r.time+seconds,fn=fn}
        end,
    })
end

function Room.create(place)
    local r={spawn=place.spawn,parts={},byId={},sensors={},actors={},flags={},flagCount=0,
        time=0,changed={},timers={},dirty=true,lowest=place.spawn.y,sequence=0}
    for _,object in ipairs(place.objects) do
        local lo,hi=Place.bounds(object)
        local b={id=object.id,lo=lo,hi=hi,color=object.color,solid=object.solid,visible=true,press={},touch={}}
        r.parts[#r.parts+1]=b
        r.byId[b.id]=b
        r.lowest=math.min(r.lowest,lo[2])
    end
    for id,code in pairs(Place.programs(place)) do
        local b=r.byId[id]
        bind(r,b,code)
        r.sensors[#r.sensors+1]=b
    end
    return r
end

function Room.add(r)
    r.sequence+=1
    local id="guest-"..Place.serial()
    local actor={id=id,name="Guest "..r.sequence,color=colors[(r.sequence-1)%#colors+1],
        input=zero,heading=0,jump=0,received=0,pressed=-1}
    reset(r,actor)
    r.actors[id]=actor
    r.dirty=true
    return actor
end
function Room.leave(r,p) r.actors[p.id]=nil; r.dirty=true end

function Room.input(r,p,i)
    if type(i)~="table" or not (Place.number(i.x,-1,1) and Place.number(i.z,-1,1)
        and Place.number(i.yaw,-math.pi,math.pi) and Place.number(i.jump,0,4294967295) and i.jump%1==0) then return false end
    p.input,p.received=i,r.time
    return true
end
function Room.press(r,p,target)
    if not Place.id(target) then return false end
    local b=r.byId[target]
    if not b or not b.visible or #b.press==0 or near(p,b)>36 or r.time-p.pressed<.16 then return false end
    p.pressed=r.time
    invoke(r,b.press,p.id)
    return true
end

local function horizontal(r,p,axis,d)
    if d==0 then return end
    local at=p.at
    local before=at[axis]
    at[axis]=math.clamp(before+d,-320+radius,320-radius)
    local other=4-axis
    for _,b in ipairs(r.parts) do
        if b.solid and vertical(b,at[2]) and at[other]+radius>b.lo[other] and at[other]-radius<b.hi[other] then
            local edge=if d>0 then b.lo[axis]-radius else b.hi[axis]+radius
            if (d>0 and before<=edge and at[axis]>edge) or (d<0 and before>=edge and at[axis]<edge) then
                local top=b.hi[2]
                local climb=p.grounded and top-at[2]<=.25
                if climb then
                    for _,ob in ipairs(r.parts) do
                        if ob.solid and vertical(ob,top) and footprint(ob,at[1],at[3]) then climb=false; break end
                    end
                end
                if climb then at[2]=top else at[axis]=edge end
            end
        end
    end
end
local function motion(r,p)
    local i=p.input
    if r.time-p.received<=.6 and (i.x~=0 or i.z~=0) then
        local s,c=math.sin(i.yaw),math.cos(i.yaw)
        local x,z=i.x*c-i.z*s,-i.x*s-i.z*c
        local speed=6.5*dt/math.max(1,math.sqrt(x*x+z*z))
        horizontal(r,p,1,x*speed)
        horizontal(r,p,3,z*speed)
        p.heading=math.atan2(-x,-z)
    end
    if i.jump~=p.jump then
        if p.grounded then p.speed=8.2 end
        p.jump=i.jump
    end
    p.speed-=22*dt
    local at=p.at
    local step=at[2]+p.speed*dt
    local target=step
    p.grounded=false
    for _,b in ipairs(r.parts) do
        if b.solid and footprint(b,at[1],at[3]) then
            if p.speed<=0 and at[2]>=b.hi[2]-.001 and target<=b.hi[2] then target=b.hi[2]; p.grounded=true
            elseif p.speed>0 and at[2]+height<=b.lo[2] and target+height>=b.lo[2] then target=b.lo[2]-height end
        end
    end
    if p.grounded or (p.speed>0 and target<step) then p.speed=0 end
    at[2]=target
    if at[2]<math.max(-40,r.lowest-24) then reset(r,p) end
end

function Room.step(r)
    r.time+=dt
    for i=#r.timers,1,-1 do
        local due=r.timers[i]
        if due.time<=r.time then
            table.remove(r.timers,i)
            invoke(r,{due.fn})
        end
    end
    for _,b in pairs(r.changed) do
        if b.pulse and b.untilTime<=r.time then b.pulse=nil; r.dirty=true end
    end
    for _,p in pairs(r.actors) do
        local x,y,z,yaw=p.at[1],p.at[2],p.at[3],p.heading
        motion(r,p)
        local interaction,best=nil,36
        for _,b in ipairs(r.sensors) do
            if #b.press>0 and b.visible then
                local distance=near(p,b)
                if distance<best then interaction,best=b.id,distance end
            end
            if #b.touch>0 then
                local touching=footprint(b,p.at[1],p.at[3]) and
                    p.at[2]<=b.hi[2]+.05 and p.at[2]+height>=b.lo[2]-.05
                if touching and not p.contacts[b.id] then invoke(r,b.touch,p.id) end
                p.contacts[b.id]=touching
            end
        end
        r.dirty=r.dirty or x~=p.at[1] or y~=p.at[2] or z~=p.at[3] or yaw~=p.heading or interaction~=p.interaction
        p.interaction=interaction
    end
end

function Room.snapshot(r)
    local players,effects=Wire.array(),Wire.array()
    for _,p in pairs(r.actors) do
        players[#players+1]={id=p.id,name=p.name,color=p.color,x=p.at[1],y=p.at[2],z=p.at[3],yaw=p.heading,interaction=p.interaction}
    end
    for _,b in pairs(r.changed) do
        effects[#effects+1]={id=b.id,color=b.color,solid=b.solid,visible=b.visible,pulse=b.pulse}
    end
    local packet={type="state",players=players,effects=effects,scriptError=r.error}
    r.error=nil
    r.dirty=false
    return packet
end
return Room
