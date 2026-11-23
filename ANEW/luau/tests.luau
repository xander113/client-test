local fs=require("@lune/fs")
local net=require("@lune/net")
local task=require("@lune/task")
local process=require("@lune/process")
local Demo=require("./demo")
local Place=require("./place")
local Room=require("./room")
local Wire=require("./wire")
local Script=require("./scripting")
local Store=require("./store")
local Network=require("./network")
local Hierarchy=require("./hierarchy")
local root=assert(process.args[1],"Provide the absolute luau directory.")
local sample=Demo.load(root,"terrace-park")
local p, bytes=Place.wire(sample)
assert(#p.scripts==3 and #Wire.decode(bytes).objects==#p.objects)
local r=Room.create(p)
local guest=Room.add(r)
assert(guest.spawn=="terrace-entry" and p.allowReset and guest.arrivals==1)
assert(Room.reset(r,guest) and not Room.reset(r,guest) and guest.arrivals==2)
assert(Room.press(r,guest,"garden-switch") and not r.byId["garden-gate"].solid)
for _=1,250 do Room.step(r) end
assert(r.byId["garden-gate"].solid and r.byId["garden-gate"].visible)
guest.at={-2.8,.14,10.1}
Room.step(r)
assert(r.byId["welcome-plate"].pulse=="#8ee1ff")
for _,bad in ipairs({
    "Pot.onPress(function() while true do end end)",
    "Pot.onPress(function() local x = require(\"@lune/fs\") end)",
    "Pot.onTouch(function() Pot.setVisible(\"x\", _G) end)",
    "Pot.onPress(function() Pot.onTouch(function() end) end)",
    "Pot.onTouch(function() local x = {1, 2} end)",
}) do assert(not pcall(Script.compile,bad)) end
local old=Place.decode('{"schemaVersion":1,"id":"old","name":"Old","description":"","spawn":{"x":0,"y":0,"z":0},"objects":[]}')
assert(old.schemaVersion==4 and #old.scripts==0 and old.allowReset)
local migrated=Place.validate({schemaVersion=3,id="old-script",name="Old script",description="",spawn=p.spawn,
    objects={p.objects[1]},scripts={{part=p.objects[1].id,enabled=true,source=p.scripts[1].source}}})
assert(migrated.scripts[1].kind=="script" and migrated.scripts[1].parent==p.objects[1].id)

local function duplicate(value) return Wire.decode(Wire.encode(value)) end
local point=duplicate(p.objects[#p.objects])
point.id,point.name,point.position,point.rotation="upper-spawn","Upper spawn",{4,3,9},{0,90,0}
point.parent=p.objects[1].id
p.objects[#p.objects+1]=point
p.scripts[3].parent="gate-control"
p.scripts[3].source='Pot.onPress(function() Pot.setColor("self", "#aabbee") end)'
p.scripts[#p.scripts+1]={id="gate-spawn",parent="gate-control",name="Gate spawn",enabled=true,kind="script",
    source='Pot.onPress(function(player) Pot.spawn(player, "upper-spawn") end)'}
p.scripts[#p.scripts+1]={id="spawn-flag",name="Spawn flag",enabled=true,kind="script",
    source='Pot.onSpawn(function(player) Pot.setFlag("arrived", true) end)'}
p=Place.validate(p)
local nodes=Hierarchy.index(p)
assert(Hierarchy.owner(nodes,nodes["arrival-glow"]).id=="garden-switch")
assert(not Hierarchy.canParent(nodes,nodes["gate-control"],"gate-spawn"))
local cycle=duplicate(p)
cycle.scripts[1].parent="gate-spawn"
assert(not pcall(Place.validate,cycle))
assert(not pcall(Script.compile,p.scripts[4].source,"local",true))
assert(not pcall(Script.compile,'Pot.onSpawn(function() Pot.setSolid("self", false) end)',"local",true))
assert(not pcall(Script.compile,p.scripts[3].source,"local",false))

local authority=Room.create(p)
local aLocal,bLocal=Room.create(p,true),Room.create(p,true)
local first,second=Room.add(authority),Room.add(authority)
assert(authority.flags.arrived and first.at[1]~=second.at[1])
local initial=Room.snapshot(authority)
Room.observe(aLocal,initial,first.id)
Room.observe(bLocal,initial,second.id)
assert(Room.press(aLocal,aLocal.player,"garden-switch"))
assert(Room.present(aLocal,initial,first.id).effects[1].color=="#aabbee")
assert(#Room.present(bLocal,initial,second.id).effects==0 and #initial.effects==0)
assert(Room.press(authority,first,"garden-switch"))
Room.step(authority)
assert(first.spawn=="upper-spawn" and first.at[1]==4 and first.life==2 and first.arrivals==1)
assert(second.spawn=="terrace-entry" and second.life==1)
local tmp=assert(process.args[2],"Provide a writable temporary directory.")
fs.writeDir(tmp)
local file=tmp.."/Rotated project.pot"
p.objects[1].rotation[2]=27
Place.save(file,p)
assert(Place.load(file).objects[1].rotation[2]==27)
Place.save(file,p)
local ports=assert(process.args[3],"Provide a test port.")
local service=Network.serve(Store.new(root,tmp),{host="127.0.0.1",port=tonumber(ports),read="read",write="write"})
local base="http://127.0.0.1:"..ports
local stranger=Network.remote(base,"","")
assert(not pcall(stranger.list))
local studio=Network.remote(base,"read","write")
assert(#studio.list()==3 and #studio.managed()==0)
p.id="test-world"
studio.publish(p)
assert(studio.managed()[1].id==p.id)
assert(studio.published(p.id).objects[1].rotation[2]==27)
local spawns=studio.spawns(p.id)
assert(spawns.allowReset and spawns.defaultSpawn=="terrace-entry" and #spawns.points==2)
assert(not pcall(stranger.spawns,p.id))
local image=studio.preview(p.id)
assert(image:sub(1,8)=="\137PNG\13\10\26\10")
fs.writeFile(tmp.."/preview.png",image)
local a,b=studio.join(p.id),studio.join(p.id)
assert(a.welcome.id~=b.welcome.id)
assert(a.welcome.allowReset and b.welcome.allowReset)
a.socket:send(Wire.encode({type="press",part="garden-switch"}),true)
local sawGate=false
for _=1,25 do
    local state=Wire.decode(Network.within(2,function()return b.socket:next()end))
    for _,fx in ipairs(state.effects) do
        if fx.id=="garden-gate" and fx.visible==false and #state.players==2 then
            for _,actor in ipairs(state.players) do
                if actor.id==a.welcome.id and actor.spawn=="upper-spawn" then sawGate=true end
            end
        end
    end
    if sawGate then break end
end
assert(sawGate,"Scripted effects must replicate between players.")
local function receive(peer,predicate)
    for _=1,35 do
        local frame=Wire.decode(Network.within(2,function()return peer.socket:next()end))
        if predicate(frame) then return frame end
    end
    error("The expected session packet did not arrive.")
end
local function sendReset(peer)
    peer.socket:send(Wire.encode({type="reset",player=b.welcome.id}),true)
    return receive(peer,function(frame)return frame.type=="resetResult"end)
end
assert(sendReset(a).ok)
receive(b,function(frame)
    if frame.type~="state" then return false end
    local arrived,unchanged=false,false
    for _,actor in ipairs(frame.players) do
        if actor.id==a.welcome.id and actor.life==3 and actor.spawn=="terrace-entry" then arrived=true end
        if actor.id==b.welcome.id and actor.life==1 then unchanged=true end
    end
    return arrived and unchanged
end)
local locked=duplicate(p)
locked.id,locked.allowReset="locked-spawn",false
studio.publish(locked)
assert(studio.spawns(locked.id).allowReset==false)
local disallowed=studio.join(locked.id)
assert(disallowed.welcome.allowReset==false and not sendReset(disallowed).ok)
studio.remove(p.id)
studio.remove(locked.id)
assert(#studio.managed()==0)
service:stop()
print("Luau tests passed: migrations, nested scripts, local effect isolation, spawn points and scripting, authenticated publishing, thumbnails, and multiplayer reset policy.")
process.exit(0)
