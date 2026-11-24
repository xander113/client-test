local Place=require("./place")
local Script=require("./scripting")
local Wire=require("./wire")

local Room={}
local radius,height=.3,1.65
local dt=1/60
local gravity=22
local zero={x=0,z=0,yaw=0,jump=0}
local colors={"#09b734","#397db8","#a871ad","#d48650","#4b9a92","#cb6861"}

local function footprint(b,x,z)
    return x+radius>b.lo[1] and x-radius<b.hi[1] and z+radius>b.lo[3] and z-radius<b.hi[3]
end
local function vertical(b,y)
    return y+height>b.lo[2]+.001 and y<b.hi[2]-.001
end
local function stand(r,p,point,spread)
    local at=point.at
    local x,z=at[1],at[3]
    if spread and p.slot>1 then
        local angle=(p.slot-2)*2.399963
        local distance=math.min(.95,point.radius or .95)
        x,z=x+math.cos(angle)*distance,z+math.sin(angle)*distance
    end
    p.at={x,at[2],z}
    p.heading,p.life,p.spawn=point.yaw,p.life+1,point.id
    p.speed,p.grounded=0,false
    p.contacts={}
    p.received,p.interaction=-1,nil
    for _,b in ipairs(r.parts) do
        if b.solid and footprint(b,p.at[1],p.at[3]) and vertical(b,p.at[2]) then p.at[2]=math.max(p.at[2],b.hi[2]) end
    end
    r.dirty=true
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

local function spawn(r,p,spread)
    local point=r.defaultSpawn
    if not point and #r.entries>0 then point=r.entries[(p.slot-1)%#r.entries+1] end
    stand(r,p,point or r.fallback,spread)
    p.walkSpeed=r.movement.walkSpeed or 6.5
    p.jumpHeight=r.movement.jumpHeight
    p.arrivals+=1
    invoke(r,r.onSpawn,p.id)
end

local function effect(r,b,key)
    local authority=r.authority and r.authority[b.id]
    if authority and not (b.overrides and b.overrides[key]) then return authority[key] end
    return b[key]
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
        if b.overrides then b.overrides[key]=true end
        r.changed[b.id]=b
        r.dirty=true
    end
    Script.attach(code,{
        onPress=function(fn) part.press[#part.press+1]=fn end,
        onTouch=function(fn) part.touch[#part.touch+1]=fn end,
        onSpawn=function(fn) r.onSpawn[#r.onSpawn+1]=fn end,
        flag=function(key) return r.flags[key] or false end,
        isSolid=function(id) return effect(r,target(id),"solid") end,
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
            assert(not r.localOnly,"Only a Script can change collision.")
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
            update(id,"pulse",color:lower())
            b.untilTime=r.time+seconds
        end,
        spawn=function(player,id)
            assert(not r.localOnly,"Only a Script can spawn players.")
            local actor=type(player)=="string" and r.actors[player]
            local point=type(id)=="string" and r.spawnPoints[id]
            assert(actor and point,"Choose an active player and an enabled spawn point ID.")
            if r.time-actor.scriptSpawnAt<.25 then return end
            actor.scriptSpawnAt=r.time
            actor.requestedSpawn=point
        end,
        setWalkSpeed=function(id,speed)
            local actor=type(id)=="string" and r.actors[id]
            assert(not r.localOnly and actor and Place.number(speed,0,64),"Choose an active player and a WalkSpeed from 0 to 64.")
            actor.walkSpeed=speed
        end,
        setJumpHeight=function(id,jump)
            local actor=type(id)=="string" and r.actors[id]
            assert(not r.localOnly and actor and Place.number(jump,0,32),"Choose an active player and a JumpHeight from 0 to 32.")
            actor.jumpHeight=jump
        end,
        after=function(seconds,fn)
            assert(Place.number(seconds,.1,30),"Delay must be from 0.1 to 30 seconds.")
            assert(#r.timers<96,"This place has too many queued actions.")
            r.timers[#r.timers+1]={time=r.time+seconds,fn=fn}
        end,
    })
end

function Room.create(place,localOnly)
    local programs=Place.programs(place,if localOnly then "local" else "script")
    if localOnly and #programs==0 then return nil end
    local r={fallback={at={place.spawn.x,place.spawn.y,place.spawn.z},yaw=0},parts={},byId={},sensors={},actors={},flags={},flagCount=0,
        time=0,changed={},timers={},dirty=true,lowest=place.spawn.y,sequence=0,allowReset=place.allowReset~=false,
        spawnPoints={},entries={},onSpawn={},localOnly=localOnly,authority=if localOnly then {} else nil,
        movement=place.movement or {}}
    for _,object in ipairs(place.objects) do
        local lo,hi=Place.bounds(object)
        local b={id=object.id,lo=lo,hi=hi,color=object.color,solid=object.solid,visible=true,press={},touch={}}
        if localOnly then b.overrides={} end
        r.parts[#r.parts+1]=b
        r.byId[b.id]=b
        r.lowest=math.min(r.lowest,lo[2])
        if object.kind=="spawn" and object.enabled then
            local point={id=object.id,at={object.position[1],hi[2],object.position[3]},yaw=math.rad(object.rotation[2]),
                radius=math.min(object.size[1],object.size[3])*.33}
            r.entries[#r.entries+1]=point
            r.spawnPoints[point.id]=point
        end
    end
    r.defaultSpawn=r.spawnPoints[place.defaultSpawn]
    for _,program in ipairs(programs) do bind(r,r.byId[program.part],program.code) end
    for _,part in ipairs(r.parts) do
        if #part.press>0 or #part.touch>0 then r.sensors[#r.sensors+1]=part end
    end
    return r
end

function Room.add(r,avatar)
    r.sequence+=1
    local id="guest-"..Place.serial()
    local look=avatar and avatar.look
    local actor={id=id,name=avatar and avatar.displayName or ("Guest "..r.sequence),
        color=look and look.shirt or colors[(r.sequence-1)%#colors+1],look=look,
        input=zero,heading=0,jump=0,received=0,pressed=-1,resetAt=-1,scriptSpawnAt=-1,life=0,arrivals=0,slot=r.sequence}
    r.actors[id]=actor
    spawn(r,actor,true)
    return actor
end
function Room.leave(r,p) r.actors[p.id]=nil; r.dirty=true end

function Room.reset(r,p)
    if not r.allowReset then return false,"This world has character reset turned off." end
    if r.time-p.resetAt<1 then return false,"Wait a moment before resetting again." end
    p.resetAt=r.time
    p.requestedSpawn=nil
    spawn(r,p,true)
    return true
end

function Room.input(r,p,i)
    if type(i)~="table" or not (Place.number(i.x,-1,1) and Place.number(i.z,-1,1)
        and Place.number(i.yaw,-math.pi,math.pi) and Place.number(i.jump,0,4294967295) and i.jump%1==0) then return false end
    p.input,p.received=i,r.time
    return true
end
function Room.press(r,p,target)
    if not Place.id(target) then return false end
    local b=r.byId[target]
    if not p or not b or not effect(r,b,"visible") or #b.press==0 or near(p,b)>36 or r.time-p.pressed<.16 then return false end
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
        local speed=p.walkSpeed*dt/math.max(1,math.sqrt(x*x+z*z))
        horizontal(r,p,1,x*speed)
        horizontal(r,p,3,z*speed)
        p.heading=math.atan2(-x,-z)
    end
    if i.jump~=p.jump then
        if p.grounded then
            p.speed=if p.jumpHeight then math.sqrt(2*gravity*p.jumpHeight) else 8.2
        end
        p.jump=i.jump
    end
    p.speed-=gravity*dt
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
    if at[2]<math.max(-40,r.lowest-24) then spawn(r,p,true) end
end

function Room.advance(r)
    r.time+=dt
    for i=#r.timers,1,-1 do
        local due=r.timers[i]
        if due.time<=r.time then
            table.remove(r.timers,i)
            invoke(r,{due.fn})
        end
    end
    for _,b in pairs(r.changed) do
        if b.pulse and b.untilTime<=r.time then
            b.pulse=nil
            if b.overrides then b.overrides.pulse=nil end
            r.dirty=true
        end
    end
end

local function sense(r,p,serverInteraction)
    local interaction,best=nil,36
    local serverPart=r.byId[serverInteraction]
    if serverPart and effect(r,serverPart,"visible") then interaction,best=serverInteraction,near(p,serverPart) end
    for _,b in ipairs(r.sensors) do
        if #b.press>0 and effect(r,b,"visible") then
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
    r.dirty=r.dirty or interaction~=p.interaction
    p.interaction=interaction
end

function Room.step(r)
    Room.advance(r)
    for _,p in pairs(r.actors) do
        local x,y,z,yaw=p.at[1],p.at[2],p.at[3],p.heading
        if p.requestedSpawn then
            stand(r,p,p.requestedSpawn,false)
            p.requestedSpawn=nil
        end
        motion(r,p)
        sense(r,p)
        r.dirty=r.dirty or x~=p.at[1] or y~=p.at[2] or z~=p.at[3] or yaw~=p.heading
    end
end

function Room.snapshot(r)
    local players,effects=Wire.array(),Wire.array()
    for _,p in pairs(r.actors) do
        players[#players+1]={id=p.id,name=p.name,color=p.color,look=p.look,x=p.at[1],y=p.at[2],z=p.at[3],yaw=p.heading,
            life=p.life,arrivals=p.arrivals,spawn=p.spawn,interaction=p.interaction}
    end
    for _,b in pairs(r.changed) do
        effects[#effects+1]={id=b.id,color=b.color,solid=b.solid,visible=b.visible,pulse=b.pulse}
    end
    local packet={type="state",players=players,effects=effects,scriptError=r.error}
    r.error=nil
    r.dirty=false
    return packet
end

function Room.observe(r,state,id)
    r.authority={}
    for _,fx in ipairs(state.effects) do r.authority[fx.id]=fx end
    for _,actor in ipairs(state.players) do
        if actor.id==id then
            local p=r.player or {id=id,contacts={},pressed=-1}
            local arrived=not r.player or p.arrivals~=actor.arrivals
            if p.life~=actor.life then p.contacts={} end
            p.at,p.life,p.arrivals={actor.x,actor.y,actor.z},actor.life,actor.arrivals
            r.player=p
            if arrived then invoke(r,r.onSpawn,id) end
            sense(r,p,actor.interaction)
            break
        end
    end
end

function Room.present(r,state,id)
    if not r.player then return state end
    local packet=table.clone(state)
    packet.players=Wire.array(table.clone(state.players))
    for i,actor in ipairs(packet.players) do
        if actor.id==id then
            local own=table.clone(actor)
            own.interaction=r.player.interaction
            packet.players[i]=own
            break
        end
    end
    packet.effects=Wire.array()
    for _,fx in ipairs(state.effects) do
        if not r.changed[fx.id] then packet.effects[#packet.effects+1]=fx end
    end
    for _,b in pairs(r.changed) do
        packet.effects[#packet.effects+1]={id=b.id,color=effect(r,b,"color"),visible=effect(r,b,"visible"),
            solid=effect(r,b,"solid"),pulse=effect(r,b,"pulse")}
    end
    packet.scriptError=r.error or state.scriptError
    r.error=nil
    r.dirty=false
    return packet
end
return Room
