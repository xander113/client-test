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
local root=assert(process.args[1],"Provide the absolute luau directory.")
local sample=Demo.load(root,"terrace-park")
local p, bytes=Place.wire(sample)
assert(#p.scripts==2 and #Wire.decode(bytes).objects==#p.objects)
local r=Room.create(p)
local guest=Room.add(r)
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
assert(old.schemaVersion==3 and #old.scripts==0)
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
local image=studio.preview(p.id)
assert(image:sub(1,8)=="\137PNG\13\10\26\10")
fs.writeFile(tmp.."/preview.png",image)
local a,b=studio.join(p.id),studio.join(p.id)
assert(a.welcome.id~=b.welcome.id)
a.socket:send(Wire.encode({type="press",part="garden-switch"}),true)
local sawGate=false
for _=1,25 do
    local state=Wire.decode(Network.within(2,function()return b.socket:next()end))
    for _,fx in ipairs(state.effects) do
        if fx.id=="garden-gate" and fx.visible==false and #state.players==2 then sawGate=true end
    end
    if sawGate then break end
end
assert(sawGate,"Scripted effects must replicate between players.")
studio.remove(p.id)
assert(#studio.managed()==0)
service:stop()
print("Luau tests passed: bounded scripts, touch, timer, binary migration, authenticated publishing, map PNG and two-player effects.")
process.exit(0)
