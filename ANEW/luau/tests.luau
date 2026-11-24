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
local Accounts=require("./accounts")
local Thumbnail=require("./thumbnail")
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
assert(old.schemaVersion==Place.version and #old.scripts==0 and old.allowReset)
local migrated=Place.validate({schemaVersion=3,id="old-script",name="Old script",description="",spawn=p.spawn,
    objects={p.objects[1]},scripts={{part=p.objects[1].id,enabled=true,source=p.scripts[1].source}}})
assert(migrated.scripts[1].kind=="script" and migrated.scripts[1].parent==p.objects[1].id)
assert(migrated.movement==nil)

local runWorld=Place.validate({schemaVersion=Place.version,id="track",name="Track",description="",spawn={x=0,y=0,z=0},
    movement={walkSpeed=16,jumpHeight=7.2},
    scripts={},objects={{id="floor",name="Floor",kind="box",position={0,-.5,0},size={128,1,128},
        rotation={0,0,0},color="#ccd5cc",solid=true}}})
local track=Room.create(runWorld)
local runner=Room.add(track)
Room.step(track)
for _=1,60 do
    assert(Room.input(track,runner,{x=1,z=1,yaw=0,jump=0}))
    Room.step(track)
end
assert(math.abs(math.sqrt(runner.at[1]^2+runner.at[3]^2)-6.5)<1e-6,"Default movement must use the 0.4 pace.")
Room.input(track,runner,{x=0,z=0,yaw=0,jump=1})
local apex=0
for _=1,60 do Room.step(track);apex=math.max(apex,runner.at[2]) end
assert(math.abs(apex-1.46055556)<.00001 and runner.grounded,"Default jump must match the 0.4 trajectory.")
runWorld.objects[#runWorld.objects+1]={id="wall",name="Wall",kind="box",position={4,3,0},size={.10,6,8},
    rotation={0,0,0},color="#aaaaaa",solid=true}
runWorld.movement={walkSpeed=64}
local sprint=Room.create(runWorld)
local sprinter=Room.add(sprint)
for _=1,20 do Room.input(sprint,sprinter,{x=1,z=0,yaw=0,jump=0});Room.step(sprint) end
assert(sprinter.at[1]>3.6 and sprinter.at[1]<=3.650001,"Thin walls must resist fast movement.")

local function duplicate(value) return Wire.decode(Wire.encode(value)) end
local solidImage=Wire.bytes(string.char(44,145,214,255):rep(4))
runWorld.textures=Wire.array({{id="blue-tile",name="Blue tile",width=2,height=2,pixels=solidImage}})
local bareImage=Thumbnail.render(runWorld)
runWorld.objects[1].textures=Wire.array({{asset="blue-tile",face=3,mode="fit",tileU=4,tileV=4}})
local textured=Place.validate(runWorld)
assert(Thumbnail.render(textured)~=bareImage,"Map previews must show authored texture faces.")
local brokenTexture=duplicate(textured)
brokenTexture.textures[1].pixels=Wire.bytes("short")
assert(not pcall(Place.validate,brokenTexture))
p.textures[1]=textured.textures[1]
p.objects[1].textures=Wire.array({{asset="blue-tile",face=3,mode="tile",tileU=5,tileV=4}})
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
assert(not pcall(Script.compile,'Pot.onSpawn(function(player) Pot.setWalkSpeed(player, 24) end)',"local",true))
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
assert(Place.load(file).textures[1].pixels.data==solidImage.data)
Place.save(file,p)
local ports=assert(process.args[3],"Provide a test port.")
local accountDir=tmp.."/accounts"
local service=Network.serve(Store.new(root,tmp),{host="127.0.0.1",port=tonumber(ports),read="read",write="write",
    accountDir=accountDir,accountAdmin="account-admin"})
local base="http://127.0.0.1:"..ports
local stranger=Network.remote(base,"","")
assert(not pcall(stranger.list))
local studio=Network.remote(base,"read","write")
assert(#studio.list()==3 and #studio.managed()==0)
p.id="test-world"
studio.publish(p)
assert(studio.managed()[1].id==p.id)
assert(studio.published(p.id).objects[1].rotation[2]==27)
assert(studio.published(p.id).textures[1].pixels.data==solidImage.data)
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

local function accountRequest(method,path,key,body,status)
    local res=net.request({url=base..path,method=method,headers={Authorization="Bearer "..key,["Content-Type"]=Wire.mime},
        body=if body then Wire.encode(body) else nil})
    assert(res.statusCode==status,method.." "..path.." returned "..res.statusCode.." instead of "..status)
    return Wire.decode(res.body)
end
local admin="account-admin"
local firstKey,secondKey,rotatedKey=string.rep("a",64),string.rep("b",64),string.rep("c",64)
local firstAccount="/v3/accounts/maple"
local secondAccount="/v3/accounts/pine"
local own="/v3/account/me"
accountRequest("PUT",firstAccount,"write",{displayName="Maple Pilot",credential=firstKey},401)
assert(accountRequest("PUT",firstAccount,admin,{displayName="Maple Pilot",credential=firstKey},200).balance==0)
accountRequest("PUT",secondAccount,admin,{displayName="Pine Builder",credential=firstKey},409)
accountRequest("PUT",secondAccount,admin,{displayName="Pine Builder",credential=secondKey},200)
local palette={skin="#bc936d",shirt="#248ebe",pants="#233145",visor="#194039"}
assert(accountRequest("PUT",own.."/look",firstKey,palette,200).look.shirt==palette.shirt)
assert(accountRequest("GET",own,secondKey,nil,200).id=="pine")
accountRequest("GET",firstAccount,secondKey,nil,401)
local entry={operation="reward-1",delta=120}
accountRequest("POST",firstAccount.."/currency",firstKey,entry,401)
assert(accountRequest("POST",firstAccount.."/currency",admin,entry,200).balance==120)
assert(accountRequest("POST",firstAccount.."/currency",admin,entry,200).balance==120)
accountRequest("POST",firstAccount.."/currency",admin,{operation="reward-1",delta=121},409)
accountRequest("POST",firstAccount.."/currency",admin,{operation="overdraw",delta=-121},409)
assert(accountRequest("POST",firstAccount.."/currency",admin,{operation="spend-1",delta=-45},200).balance==75)
assert(accountRequest("GET",own,secondKey,nil,200).balance==0)
accountRequest("PUT",firstAccount,admin,{credential=rotatedKey},200)
accountRequest("GET",own,firstKey,nil,401)
local reopened=Accounts.new(accountDir)
assert(reopened.identify(rotatedKey)=="maple" and reopened.identify(firstKey)==nil and reopened.get("maple").balance==75)
assert(reopened.adjust("maple","reward-1",120).balance==120 and reopened.get("maple").balance==75)
assert(not pcall(Network.remote(base,"read",nil,firstKey).join,p.id))
local signedIn=Network.remote(base,"read",nil,rotatedKey).join(p.id)
receive(signedIn,function(frame)
    if frame.type~="state" then return false end
    for _,actor in ipairs(frame.players) do
        if actor.id==signedIn.welcome.id then
            assert(actor.name=="Maple Pilot" and actor.look.shirt==palette.shirt and actor.balance==nil and actor.account==nil)
            return true
        end
    end
    return false
end)
studio.remove(p.id)
studio.remove(locked.id)
assert(#studio.managed()==0)
service:stop()
print("Luau tests passed: restored movement, binary textures and previews, multiplayer spawning and resets, accounts and durable currency.")
process.exit(0)
