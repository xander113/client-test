local fs = require("@lune/fs")
local Place = require("./place")
local Wire = require("./wire")
local Demo = {}
Demo.ids={"terrace-park","dune-circuit","tidebreak"}
function Demo.load(root,id)
    local p=Place.decode(fs.readFile(root.."/samples/"..id..".pot"))
    if id=="terrace-park" then
        local function part(key,name,position,size,color)
            p.objects[#p.objects+1]={id=key,name=name,kind="box",position=position,size=size,rotation={0,0,0},color=color,solid=true}
        end
        part("garden-switch","Garden switch",{2.6,.35,11},{1,.7,1},"#efb64c")
        part("garden-gate","Garden gate",{0,1.05,8.15},{3.5,2.1,.3},"#3c9564")
        part("welcome-plate","Welcome plate",{-2.8,.07,10.1},{2.3,.14,2.1},"#497eac")
        for _,object in ipairs(p.objects) do
            if object.id:match("^walkway%-") then
                object.textures=Wire.array({{asset="pot-stone",face=3,mode="tile",tileU=2,tileV=2}})
            elseif object.id:match("^pavilion%-") then
                object.textures=Wire.array({{asset="pot-wood",face=0,mode="tile",tileU=3,tileV=3}})
            end
        end
        p.objects[#p.objects+1]={id="terrace-entry",name="Terrace entry",kind="spawn",position={0,-.06,12},
            size={2.4,.12,2.4},rotation={0,0,0},color="#88bca1",solid=false,enabled=true}
        p.defaultSpawn="terrace-entry"
        p.scripts=Wire.array({
            {id="gate-control",name="Gate control",kind="script",parent="garden-switch",enabled=true,source=[=[
-- Press E near the switch, or click it within reach.
Pot.onPress(function(player)
    if not Pot.flag("gateOpen") then
        Pot.setFlag("gateOpen", true)
        Pot.pulse("self", 1, "#ffdd73")
        Pot.setSolid("garden-gate", false)
        Pot.setVisible("garden-gate", false)
        Pot.after(4, function()
            Pot.setSolid("garden-gate", true)
            Pot.setVisible("garden-gate", true)
            Pot.setFlag("gateOpen", false)
        end)
    end
end)
]=]},
            {id="welcome-glow",name="Welcome glow",kind="script",parent="welcome-plate",enabled=true,source=[=[
Pot.onTouch(function(player: string)
    Pot.pulse("self", 2, "#8ee1ff")
end)
]=]},
            {id="arrival-glow",name="Arrival glow",kind="local",parent="terrace-entry",enabled=true,source=[=[
Pot.onSpawn(function(player)
    Pot.pulse("self", 1.5, "#b6f4c6")
end)
]=]},
        })
        p.description="Explore the terraces. Try the garden switch and step on the blue plate."
    end
    return p
end
return Demo
