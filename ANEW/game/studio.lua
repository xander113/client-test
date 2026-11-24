local UI=require("ui")
local View=require("view")
local Wire=require("wire")
local Hierarchy=require("hierarchy")
local Physics=require("physics")
local Surface=require("surface")
local G=love.graphics
local Studio={}
Studio.__index=Studio
local C=UI.colors
local shapes={box={"Box",{2,2,2},"#3eb36e"},sphere={"Sphere",{2,2,2},"#568ee0"},
    cylinder={"Cylinder",{2,3,2},"#dfa64e"},spawn={"Spawn Point",{3,.15,3},"#83bd9b"}}
local scriptNames={script="Script",["local"]="Local Script"}
local words={translate="Move",rotate="Rotate",scale="Scale",select="Select"}
local templates={
    press=[=[-- Press E or click this part while nearby.
Pot.onPress(function(player)
    Pot.pulse("self", 1, "#ffda6a")
    Pot.setColor("self", "#09b734")
end)
]=],
    touch=[=[-- Runs when a player first touches this part.
Pot.onTouch(function(player: string)
    Pot.pulse("self", 2, "#91e4ff")
end)
]=],
    spawn=[=[-- Runs when this player joins or respawns.
Pot.onSpawn(function(player)
    Pot.setFlag("playerArrived", true)
end)
]=],
}
local function id()
    return ("%x-%x-%x"):format(os.time(),love.math.random(0,0xffffff),love.math.random(0,0xffffff))
end
local function clamp(a,b,c) return math.max(b,math.min(c,a)) end
local function copy(v) return Wire.decode(Wire.encode(v)) end
local function blank()
    return {schemaVersion=5,id="world-"..id(),name="Untitled world",description="",spawn={x=0,y=0,z=5},allowReset=true,
        textures=Wire.array(),movement={walkSpeed=Physics.walkSpeed,jumpHeight=Physics.jumpHeight},
        objects=Wire.array({{id="ground",name="Ground",kind="box",position={0,-.5,0},rotation={0,0,0},size={34,1,34},
            color="#91bfa0",solid=true}}),scripts=Wire.array()}
end

function Studio.new(backend)
    local self=setmetatable({backend=backend,ui=UI.new(),status="Opening Studio…",pane=304,query="",scroll=0,
        elapsed=0,jump=0,mode="local",pending=false},Studio)
    self.view=View.new(function() self:checkpoint(); self.status="Part updated" end,
        function(id) self:select(id) end,function(part) self:press(part) end)
    self.titleIcon=G.newImage("icon.png")
    love.filesystem.createDirectory("Projects")
    self:set( blank() )
    self:call("mode",{},function(value) self.mode=value end)
    self:call("sample",{},function(scene)
        if not self:dirty() and not self.file and self.scene.name=="Untitled world" then
            scene.id="world-"..id()
            scene.name="Terrace Workshop"
            self:set(scene)
            self.status="Select a part or playtest the scripted switch."
        end
    end)
    return self
end

function Studio:call(action,params,done)
    self.backend:call(action,params,function(value,err)
        if err then self.status=err; if self.modal then self.modal.error=err end
        elseif done then done(value) end
    end)
end

function Studio:set(scene,filename)
    self.scene,self.file=scene,filename
    self.scene.scripts=self.scene.scripts or Wire.array()
    self.selected=nil
    self.history={{data=Wire.encode(scene)}}
    self.index=1
    self.saved=self.history[1].data
    self.query,self.scroll,self.collapsed="",0,{}
    self:refresh()
    self.view.selected=nil
    self.view:frame(nil,"perspective",true)
end

function Studio:refresh()
    self.nodes,self.children=Hierarchy.index(self.scene)
    self.view:set(self.scene)
    self.view.selected=self.view.parts[self.selected] and self.selected or nil
end

function Studio:select(value,reveal)
    self.selected=value
    self.view.selected=self.view.parts[value] and value or nil
    if reveal~=false and value then
        local node=self.nodes[value]
        while node and node.parent do
            self.collapsed[node.parent]=nil
            node=self.nodes[node.parent]
        end
        self.reveal=value
    end
end

function Studio:checkpoint()
    local data=Wire.encode(self.scene)
    if self.history[self.index].data==data then return end
    while #self.history>self.index do self.history[#self.history]=nil end
    self.history[#self.history+1]={data=data,selected=self.selected}
    if #self.history>65 then table.remove(self.history,1) end
    self.index=#self.history
    self:refresh()
end

function Studio:dirty() return self.history[self.index].data~=self.saved end
function Studio:undo(step)
    local n=self.index+step
    if not self.history[n] then return end
    self.index=n
    self.scene=Wire.decode(self.history[n].data)
    self:refresh()
    local v=self.history[n].selected or self.selected
    self:select(self.nodes[v] and v or nil)
    self.status=step<0 and "Undid the last edit" or "Redid the last edit"
end

function Studio:part()
    return self.view.parts[self.selected]
end

function Studio:add(kind,parent)
    if #self.scene.objects>=400 then self.status="The place already has 400 parts."; return end
    local spec=shapes[kind]
    local spawn=self.scene.spawn
    local near=self.view.parts[parent or self.selected]
    local x,y,z=spawn.x+2.5,spawn.y+spec[2][2]*.5,spawn.z
    if kind=="spawn" then
        y=spawn.y+spec[2][2]*.5
        if near then
            x,y,z=near.position[1],near.position[2]+(near.size[2]+spec[2][2])*.5,near.position[3]
        end
    elseif near and near.size[1]<12 then
        x,y,z=near.position[1]+(near.size[1]+spec[2][1])*.5+.5,near.position[2],near.position[3]
    end
    local part={id=id(),name=spec[1],kind=kind,position={clamp(x,-250,250),clamp(y,-40,250),z},
        size=copy(spec[2]),rotation={0,0,0},color=spec[3],solid=kind~="spawn",enabled=kind=="spawn" and true or nil,parent=parent}
    if not Hierarchy.canParent(self.nodes,part,parent) then self.status="This item is nested too deeply.";return end
    self.scene.objects[#self.scene.objects+1]=part
    self.selected=part.id
    self:checkpoint()
    self.query=""
    self:select(part.id)
    self.status="Added "..spec[1]
end

function Studio:addScript(kind,parent)
    if #self.scene.scripts>=48 then self.status="A world can hold up to 48 scripts.";return end
    local node={id=id(),name=scriptNames[kind],kind=kind,parent=parent,enabled=true}
    if not Hierarchy.canParent(self.nodes,node,parent) then self.status="This item is nested too deeply.";return end
    node.source=Hierarchy.owner(self.nodes,node) and templates.press or templates.spawn
    self.scene.scripts[#self.scene.scripts+1]=node
    self.selected=node.id
    self.query=""
    self:checkpoint()
    self:select(node.id)
    self:scriptEditor(node)
end

function Studio:delete()
    if not self.selected then return end
    local node=self.nodes[self.selected]
    local gone={[self.selected]=true}
    for _,entry in ipairs(Hierarchy.branch(self.children,self.selected)) do gone[entry.node.id]=true end
    for _,items in ipairs({self.scene.objects,self.scene.scripts}) do
        for i=#items,1,-1 do if gone[items[i].id] then table.remove(items,i) end end
    end
    if gone[self.scene.defaultSpawn] then self.scene.defaultSpawn=nil end
    self:select(node.parent); self:checkpoint()
    self.status="Deleted "..node.name
end

function Studio:duplicate()
    local node=self.nodes[self.selected]
    if not node then return end
    local branch=Hierarchy.branch(self.children,node.id)
    table.insert(branch,1,{node=node})
    local ids,parts,scripts={},0,0
    local shiftLow,shiftHigh=-500,500
    for _,entry in ipairs(branch) do
        local current=entry.node
        ids[current.id]=id()
        if Hierarchy.isScript(current) then scripts=scripts+1
        else
            parts=parts+1
            shiftLow=math.max(shiftLow,-250-current.position[1])
            shiftHigh=math.min(shiftHigh,250-current.position[1])
        end
    end
    if #self.scene.objects+parts>400 or #self.scene.scripts+scripts>48 then
        self.status="Duplicating this branch would exceed the world limits."
        return
    end
    local dx=node.size and math.min(node.size[1]+.5,8) or 0
    dx=clamp(dx>shiftHigh and -dx or dx,shiftLow,shiftHigh)
    for _,entry in ipairs(branch) do
        local twin=copy(entry.node)
        twin.id=ids[twin.id]
        twin.parent=ids[twin.parent] or twin.parent
        if entry.node==node and #node.name<=75 then twin.name=node.name.." copy" end
        local list=Hierarchy.isScript(twin) and self.scene.scripts or self.scene.objects
        if twin.position then twin.position[1]=twin.position[1]+dx end
        list[#list+1]=twin
    end
    self.selected=ids[node.id]
    self:checkpoint()
    self:select(self.selected)
    self.status="Duplicated "..node.name
end

function Studio:moveNode(node,parent)
    local possible,depth=Hierarchy.canParent(self.nodes,node,parent)
    if possible then
        for _,entry in ipairs(Hierarchy.branch(self.children,node.id)) do
            if entry.depth+depth>Hierarchy.maxDepth then possible=false;break end
        end
    end
    if not possible then self.status="Choose a parent outside this branch with enough room for its children.";return false end
    node.parent=parent
    self:checkpoint()
    self:select(node.id)
    local target=parent and self.nodes[parent].name or "Workspace"
    self.status="Moved "..node.name.." to "..target
    return true
end

function Studio:confirmDiscard(action)
    if self:dirty() then self.modal={kind="discard",action=action} else action() end
end

function Studio:savePath()
    return love.filesystem.getSaveDirectory().."/Projects/"..self.scene.name:gsub("[^%w _%-]","_")..".pot"
end

function Studio:save(path,after)
    if self.pending then return end
    if not path then
        self.modal={kind="save",path=self.file or self:savePath(),after=after}
        return
    end
    if not path:lower():match("%.pot$") then path=path..".pot" end
    self.pending=true
    local snapshot=Wire.encode(self.scene)
    self.backend:call("save",{path=path,scene=self.scene},function(value,err)
        self.pending=false
        if not value then
            self.status=err
            if self.modal then self.modal.error=err end
            return
        end
        self.saved,self.file=snapshot,path
        self.modal=nil
        self.status="Saved "..self.scene.name
        if after then after() end
    end)
end

function Studio:open(path)
    self:confirmDiscard(function()
        if not path then self.modal={kind="open",path="",offset=0};return end
        self:call("open",{path=path},function(value)
            self.modal=nil
            self:set(value,path:lower():match("%.pot$") and path or nil)
            self.status="Opened "..value.name
        end)
    end)
end

function Studio:publish()
    if self.pending then return end
    self.pending=true
    self.backend:call("publish",{scene=self.scene},function(value,err)
        self.pending=false
        self.status=err or ("Published "..self.scene.name.." to the "..(self.mode=="hosted" and "hosted" or "local").." library.")
    end)
end

function Studio:library()
    self.modal={kind="published",worlds={},offset=0,loading=true}
    local m=self.modal
    self.backend:call("published",{},function(value,err)
        if self.modal==m then m.worlds,m.error,m.loading=value or {},err,false end
    end)
end

function Studio:scriptEditor(node)
    self.modal={kind="script",node=node,part=Hierarchy.owner(self.nodes,node),source=node.source,enabled=node.enabled}
end

function Studio:applyScript(checkOnly)
    local m=self.modal
    if self.pending then return end
    self.pending=true
    local source=m.source
    self.backend:call("script",{source=source,kind=m.node.kind,hasPart=m.part~=nil},function(value,err)
        self.pending=false
        if self.modal~=m then return end
        m.error,m.valid=err,value and "Ready to run in playtest." or nil
        if not value or checkOnly then return end
        m.node.source,m.node.enabled=source,m.enabled
        self.modal=nil
        self.ui:blur(true)
        self:checkpoint()
        self.status="Updated "..m.node.name
    end)
end

function Studio:play()
    if self.pending then return end
    if self.view.playing then
        self.backend:call("leave",{})
        self.view:play(false)
        self.status="Returned to editing"
        return
    end
    if self.view.drag then self.view:cancel() end
    self.pending=true
    self.elapsed,self.jump=0,0
    self.view:play(true)
    self.backend:call("playtest",{scene=self.scene},function(value,err)
        self.pending=false
        if err then self.view:play(false) end
        self.status=err or "Playtesting from the current spawn"
    end)
end

function Studio:event(e)
    if self.view.playing then
        self.view:state(e)
        if e.scriptError then self.status=e.scriptError end
        if e.type=="resetResult" then self.status=e.ok and "Character reset" or e.message end
    end
end

function Studio:press(part)
    if part then self.backend:call("press",{part=part}) end
end

local function moveInput(view,jump)
    local key=love.keyboard.isDown
    return {x=(key("d","right") and 1 or 0)-(key("a","left") and 1 or 0),
        z=(key("w","up") and 1 or 0)-(key("s","down") and 1 or 0),
        yaw=math.atan2(math.sin(view.yaw),math.cos(view.yaw)),jump=jump}
end

function Studio:update(dt)
    self.view:update(dt)
    if self.view.playing and not self.pending and love.window.hasFocus() then
        self.elapsed=self.elapsed+dt
        if self.elapsed>=.05 then
            self.backend:call("input",{input=moveInput(self.view,self.jump)})
            self.elapsed=0
        end
    end
end

function Studio:property(label,value,x,y,w,commit)
    self.ui:text(label,x,y-1,C.muted,self.ui.small)
    self.ui:field("property-"..label,value,x,y+14,w,26,{commit=commit})
end

function Studio:explorer(x,y,w,h,locked)
    local ui=self.ui
    ui.rect(C.paper,x,y,w,h)
    ui.rect(C.panel,x,y,w,32)
    ui:text("Explorer",x+9,y+8)
    ui:button("+ Add",x+w-199,y+3,60,26,not locked and function()
        self.modal={kind="add",node=self.nodes[self.selected]}
    end or nil,{outline=true})
    ui:button("Duplicate",x+w-135,y+3,74,26,not locked and self.selected and function() self:duplicate() end or nil)
    ui:button("Delete",x+w-59,y+3,54,26,not locked and self.selected and function() self:delete() end or nil)
    self.explorerRows={}
    self.explorerBottom=y+h
    if locked then return end
    ui:field("search",self.query,x+8,y+37,w-16,26,{live=function(v)self.query,self.scroll=v,0 end})
    if self.query=="" and ui.focus~="search" then ui:text("Find in Explorer",x+14,y+42,C.muted) end
    local rootY=y+66
    ui:row("Workspace",x+7,rootY,w-15,23,function()self:select(nil)end,not self.selected)
    self.explorerRows[1]={x=x+7,y=rootY,w=w-15,h=23}
    local query=self.query:lower()
    local visible={}
    if query~="" then
        for _,node in pairs(self.nodes) do
            local name=node.name:lower()
            local kind=(scriptNames[node.kind] or shapes[node.kind][1]):lower()
            if name:find(query,1,true) or kind:find(query,1,true) then
                local ancestor=node
                while ancestor do
                    visible[ancestor.id]=true
                    ancestor=self.nodes[ancestor.parent]
                end
            end
        end
    end
    local rows={}
    local function walk(parent,depth)
        for _,node in ipairs(self.children[parent] or {}) do
            if query=="" or visible[node.id] then
                rows[#rows+1]={node=node,depth=depth}
                if query~="" or not self.collapsed[node.id] then walk(node.id,depth+1) end
            end
        end
    end
    walk("",0)
    local count=math.max(1,math.floor((h-91)/23))
    if self.reveal then
        for i,row in ipairs(rows) do
            if row.node.id==self.reveal then
                if i<=self.scroll then self.scroll=i-1 end
                if i>self.scroll+count then self.scroll=i-count end
                break
            end
        end
        self.reveal=nil
    end
    self.scroll=clamp(self.scroll,0,math.max(0,#rows-count))
    local offset=math.floor(self.scroll)
    for i=1,count do
        local entry=rows[offset+i]
        if not entry then break end
        local node=entry.node
        local yy=y+90+(i-1)*23
        local indent=math.min(8,entry.depth)*13
        local left=x+7+indent
        local rect={id=node.id,x=x+7,y=yy,w=w-18,h=22,label=left+19}
        self.explorerRows[#self.explorerRows+1]=rect
        ui:row("",rect.x,yy,rect.w,rect.h,function()self:select(node.id,false)end,self.selected==node.id)
        if self.children[node.id] and query=="" then
            ui:button("",left,yy,19,22,function()
                self.collapsed[node.id]=not self.collapsed[node.id]
            end)
            G.setColor(C.muted)
            if self.collapsed[node.id] then G.polygon("fill",left+7,yy+7,left+12,yy+11,left+7,yy+15)
            else G.polygon("fill",left+6,yy+9,left+14,yy+9,left+10,yy+14) end
        end
        local marker=node.kind=="local" and "LS" or node.kind=="script" and "S" or node.kind=="spawn" and "SP"
        if marker then ui:text(marker,left+20,yy+5,C.muted,ui.small)
        else ui.line(C.muted,left+22,yy+7,8,8,1) end
        G.setScissor(left+42,yy,math.max(0,x+w-14-(left+42)),22)
        ui:text(node.name,left+42,yy+3,node.enabled==false and C.muted or C.ink)
        G.setScissor()
    end
    if #rows>count then
        local dy=(h-96)*offset/#rows
        ui.rect(C.edge,x+w-7,y+92+dy,3,math.max(12,(h-96)*count/#rows),1)
    end
    if self.dragNode and self.dragNode.active then
        local mx,my=love.mouse.getPosition()
        local target=self:explorerHit(mx,my)
        local node=self.nodes[self.dragNode.id]
        if target and node and Hierarchy.canParent(self.nodes,node,target.id) then
            ui.line(C.green,target.x,target.y,target.w,target.h,3)
        end
    end
end

function Studio:explorerHit(x,y)
    for _,row in ipairs(self.explorerRows or {}) do
        if x>=row.x and x<row.x+row.w and y>=row.y and y<row.y+row.h then return row end
    end
end

function Studio:inspector(x,y,w,h,locked)
    local ui=self.ui
    local o=self:part()
    local node=self.nodes[self.selected]
    local script=node and not o and node
    local title=script and scriptNames[script.kind] or o and (o.kind=="spawn" and "Spawn Point" or "Part properties") or "World settings"
    ui.rect(C.paper,x,y,w,h)
    ui.rect(C.panel,x,y,w,32)
    ui:text(title,x+9,y+7)
    if locked then return end
    if node then
        ui:button("Move to…",x+w-81,y+3,73,25,function()self.modal={kind="move",node=node,offset=0}end)
    end
    local row=y+39
    self:property("Name",node and node.name or self.scene.name,x+9,row,w-18,function(v)
        if v:match("%S") and #v<=80 and not v:find("%c") then (node or self.scene).name=v;self:checkpoint() end
    end)
    row=row+47
    if script then
        ui:button("Edit source",x+9,row,104,30,function()self:scriptEditor(script)end,{primary=true})
        ui:button(script.enabled and "Enabled" or "Disabled",x+121,row,99,30,function()
            script.enabled=not script.enabled; self:checkpoint()
        end,{outline=true})
        local parent=self.nodes[script.parent]
        ui:text("Parent   "..(parent and parent.name or "Workspace"),x+9,row+47,C.muted,ui.small,w-18)
        return
    end
    local vectors=o and {{"Position","position",-250,250},{"Rotation (degrees)","rotation",-180,180},{"Size","size",.1,128}}
        or {{"Fallback spawn position","spawn",-250,250}}
    for _,field in ipairs(vectors) do
        ui:text(field[1],x+9,row,C.muted,ui.small)
        ui:text("X / Y / Z",x+w-57,row,C.muted,ui.small)
        local col=(w-30)/3
        for i,axis in ipairs({"x","y","z"}) do
            local xx=x+9+(i-1)*(col+6)
            local values=o and o[field[2]] or self.scene.spawn
            local key=o and i or axis
            ui:field("value-"..field[2]..axis,("%.3g"):format(values[key]),xx,row+15,col,23,{commit=function(v)
                local number=tonumber(v)
                if number and number==number then
                    local low=(i==2 and (field[2]=="position" or field[2]=="spawn")) and -40 or field[3]
                    values[key]=clamp(number,low,field[4]);self:checkpoint()
                end
            end})
        end
        row=row+48
    end
    if o then
        if o.kind=="spawn" then
            ui:button(o.enabled and "Spawn enabled" or "Spawn disabled",x+9,row,115,26,function()
                o.enabled=not o.enabled
                if not o.enabled and self.scene.defaultSpawn==o.id then self.scene.defaultSpawn=nil end
                self:checkpoint()
            end,{outline=true})
            local preferred=self.scene.defaultSpawn==o.id
            ui:button(preferred and "Default spawn" or "Make default",x+130,row,113,26,o.enabled and function()
                if preferred then self.scene.defaultSpawn=nil else self.scene.defaultSpawn=o.id end
                self:checkpoint()
            end or nil,{selected=preferred,outline=true})
            row=row+33
        else
            self:property("Color",o.color,x+9,row,math.max(72,w-146),function(v)
                if v:match("^#%x%x%x%x%x%x$") then o.color=v:lower();self:checkpoint() end
            end)
            ui:button(o.solid and "Solid" or "No collision",x+w-109,row+14,98,26,function()o.solid=not o.solid;self:checkpoint()end,{outline=true})
            row=row+46
        end
        local first
        for _,child in ipairs(self.children[o.id] or {}) do if Hierarchy.isScript(child) then first=child;break end end
        ui:button(first and "Edit script" or "Add Script",x+9,row,110,28,function()
            if first then self:select(first.id);self:scriptEditor(first) else self:addScript("script",o.id) end
        end,{outline=true})
        ui:button("Copy part ID",x+125,row,103,28,function() love.system.setClipboardText(o.id); self.status="Part ID copied." end,{outline=true})
        row=row+34
        ui:button("Textures…",x+9,row,110,27,function()self.modal=Surface.new(o,self.scene,id)end,{outline=true})
        local assigned=#(o.textures or {})
        if assigned>0 then ui:text(assigned==1 and "1 texture layer" or (assigned.." texture layers"),x+125,row+7,C.muted,ui.small) end
    else
        local allowed=self.scene.allowReset
        ui:text("Character reset",x+9,row,C.muted,ui.small)
        ui:button(allowed and "Allowed" or "Disabled",x+9,row+16,104,28,function()
            self.scene.allowReset=not allowed
            self:checkpoint()
        end,{outline=true})
        row=row+62
        local preferred=self.nodes[self.scene.defaultSpawn]
        ui:text(preferred and ("Default spawn   "..preferred.name) or "Spawn selection   Automatic",x+9,row,C.muted,ui.small,w-18)
        row=row+32
        local movement=self.scene.movement
        local cell=(w-30)/2
        self:property("WalkSpeed",tostring(movement.walkSpeed),x+9,row,cell,function(value)
            local speed=tonumber(value)
            if speed and speed==speed then movement.walkSpeed=clamp(speed,0,Physics.maxSpeed);self:checkpoint() end
        end)
        self:property("JumpHeight",tostring(movement.jumpHeight),x+21+cell,row,cell,function(value)
            local jump=tonumber(value)
            if jump and jump==jump then movement.jumpHeight=clamp(jump,0,Physics.maxJump);self:checkpoint() end
        end)
    end
end

function Studio:draw()
    local ui=self.ui
    ui:begin()
    local W,H=G.getDimensions()
    local locked=self.pending or self.view.playing
    local panel=W-self.pane
    ui.rect(C.paper,0,0,W,43)
    G.setColor(1,1,1);G.draw(self.titleIcon,11,8,0,27/self.titleIcon:getWidth())
    ui:text("Pot Studio",45,13,C.ink)
    G.setScissor(136,0,W-460,44)
    ui:text(self.scene.name..(self:dirty() and "  *" or ""),136,13,C.muted)
    G.setScissor()
    ui:button("Published",W-313,7,92,29,not locked and function() self:library() end or nil,{outline=true})
    ui:button("Publish",W-214,7,84,29,not locked and function()self:publish()end or nil,{outline=true})
    ui:button(self.view.playing and "Stop" or "Playtest",W-122,7,110,29,not self.pending and function()self:play()end or nil,{primary=true})
    ui.rect(C.panel,0,43,W,37)
    ui.line(C.edge,0,43,W,37)
    local x=8
    local buttons={{"New",function()self:confirmDiscard(function()self:set(blank())end)end},
        {"Open",function()self:open()end},{"Save",function()self:save(self.file)end},{"Save as",function()self:save(nil)end},
        {"Undo",function()self:undo(-1)end},{"Redo",function()self:undo(1)end},
        {"Box",function()self:add("box")end},{"Sphere",function()self:add("sphere")end},{"Cylinder",function()self:add("cylinder")end},{"Spawn Point",function()self:add("spawn")end}}
    for _,b in ipairs(buttons) do
        local width=ui.font:getWidth(b[1])+19
        ui:button(b[1],x,47,width,28,not locked and b[2] or nil)
        x=x+width+3
    end
    ui.rect(C.paper,0,80,W,37)
    x=8
    for _,tool in ipairs({"select","translate","rotate","scale"}) do
        ui:button(words[tool],x,84,65,28,not locked and function()self.view.tool=tool end or nil,{selected=self.view.tool==tool})
        x=x+70
    end
    x=x+4
    ui:button(self.view.localAxes and "Local axes" or "World axes",x,84,86,28,not locked and function()self.view.localAxes=not self.view.localAxes end or nil,{outline=true})
    x=x+90
    ui:button(self.view.snap and "Snap "..self.view.snap or "Snap off",x,84,77,28,not locked and function()
        if not self.view.snap then self.view.snap=.25
        elseif self.view.snap==.25 then self.view.snap=.5
        elseif self.view.snap==.5 then self.view.snap=1
        else self.view.snap=false end
    end or nil,{outline=true})
    x=x+81
    ui:button(self.view.angle and self.view.angle.." deg" or "Free angle",x,84,75,28,not locked and function()
        if self.view.angle==15 then self.view.angle=30 elseif self.view.angle==30 then self.view.angle=false else self.view.angle=15 end
    end or nil,{outline=true})

    self.view:draw(0,117,panel-5,H-168)
    if not self.view.playing then
        ui.rect(C.paper,9,126,226,31,4)
        ui:button("Frame",11,128,52,27,function()self.view:frame(self.selected)end)
        local vx=66
        for _,name in ipairs({"top","front","right"}) do
            ui:button(name:sub(1,1):upper()..name:sub(2),vx,128,52,27,function()self.view:frame(self.selected,name)end)
            vx=vx+56
        end
    elseif self.view.interaction then
        local part=self.view.parts[self.view.interaction]
        ui.rect(C.paper,12,H-100,240,32,4)
        ui:text("E  Activate "..(part and part.name or "part"),20,H-92)
    end
    local y=117
    local top=math.min(math.floor((H-143)*.41),H-143-340)
    ui.rect(C.edge,panel-5,y,5,H-143)
    self:explorer(panel,y,self.pane,top,locked)
    self:inspector(panel,y+top,self.pane,H-y-top-26,locked)
    ui.rect(C.paper,0,H-51,panel-5,25)
    local reset=self.view.allowReset and "    F6 reset" or ""
    ui:text(self.view.playing and ("WASD move    Space jump    Drag look    E interact"..reset.."    Esc return")
        or "Q select  W move  E rotate  R scale  F frame    Right drag to fly    Scroll to zoom",10,H-46,C.muted,ui.small)
    ui.rect(C.panel,0,H-26,W,26)
    ui.line(C.edge,0,H-26,W,26)
    ui:text(self.status,9,H-21,C.muted,ui.small,W-150)
    ui:text(self.mode=="hosted" and "Hosted library" or "Local library",W-110,H-21,C.muted,ui.small)
    if self.modal then self:drawModal() end
end

function Studio:drawModal()
    local ui,m=self.ui,self.modal
    local W,H=G.getDimensions()
    if m.kind=="texture" then m:draw(self)
    elseif m.kind=="textureRemove" then Surface.removeDialog(self,m)
    elseif m.kind=="script" then
        local w,h=math.min(W-38,760),math.min(H-32,590)
        local x,y=ui:modal("Edit "..scriptNames[m.node.kind].." · "..m.node.name,w,h)
        ui:text("Lua / Luau",x+17,y+42,C.muted,ui.small)
        ui:button("Press example",x+110,y+36,106,28,m.part and function()ui:blur(true);m.source=templates.press end or nil,{outline=true})
        ui:button("Touch example",x+222,y+36,108,28,m.part and function()ui:blur(true);m.source=templates.touch end or nil,{outline=true})
        ui:button("Spawn example",x+336,y+36,112,28,function()ui:blur(true);m.source=templates.spawn end,{outline=true})
        ui:button(m.enabled and "Enabled" or "Disabled",x+w-105,y+36,88,28,function()m.enabled=not m.enabled end,{outline=true})
        ui:field("script",m.source,x+15,y+70,w-30,h-175,{multi=true,limit=4096,live=function(value)m.source=value;m.error=nil;m.valid=nil end})
        local api=m.node.kind=="local" and "Pot.onSpawn    Pot.onPress    Pot.onTouch    Pot.pulse    Pot.setColor    Pot.after"
            or "Pot.onSpawn    Pot.spawn    Pot.onPress    Pot.onTouch    Pot.pulse    Pot.setSolid    Pot.after"
        ui:text(api,x+15,y+h-98,C.muted,ui.small,w-30)
        local help=m.part and 'Use "self" for '..m.part.name.." or copy a target's ID from Properties."
            or "Use a part ID to target objects from Workspace."
        ui:text(m.error or m.valid or help,x+15,y+h-75,m.error and C.error or C.muted,ui.small,w-30)
        ui:button("Cancel",x+14,y+h-43,82,29,function()self.modal=nil end,{outline=true})
        ui:button("Check script",x+w-225,y+h-43,105,29,function()self:applyScript(true)end,{outline=true})
        ui:button("Apply",x+w-112,y+h-43,96,29,function()self:applyScript(false)end,{primary=true})
    elseif m.kind=="add" then
        local hasParts=not m.node or not Hierarchy.isScript(m.node)
        local h=hasParts and 222 or 132
        local x,y=ui:modal("Add to "..(m.node and m.node.name or "Workspace"),390,h)
        local parent=m.node and m.node.id
        local row=y+51
        if hasParts then
            for i,kind in ipairs({"box","sphere","cylinder","spawn"}) do
                local bx=x+15+((i-1)%2)*184
                local by=row+math.floor((i-1)/2)*37
                ui:button(shapes[kind][1],bx,by,176,31,function() self.modal=nil; self:add(kind,parent) end,{outline=true})
            end
            row=row+83
        end
        ui:button("Script",x+15,row,176,31,function() self.modal=nil; self:addScript("script",parent) end,{outline=true})
        ui:button("Local Script",x+199,row,176,31,function() self.modal=nil; self:addScript("local",parent) end,{outline=true})
        ui:button("Cancel",x+298,y+h-38,77,26,function()self.modal=nil end)
    elseif m.kind=="move" then
        local w,h=460,math.min(448,H-70)
        local x,y=ui:modal("Move "..m.node.name,w,h)
        ui:text("Choose a new parent",x+15,y+45,C.muted,ui.small)
        local choices={{name="Workspace",depth=0}}
        for _,entry in ipairs(Hierarchy.branch(self.children,"")) do
            if Hierarchy.canParent(self.nodes,m.node,entry.node.id) then
                choices[#choices+1]={name=entry.node.name,id=entry.node.id,depth=entry.depth}
            end
        end
        local count=math.floor((h-121)/25)
        local max=math.max(0,#choices-count)
        m.offset=clamp(m.offset,0,max)
        for i=1,count do
            local choice=choices[math.floor(m.offset)+i]
            if not choice then break end
            local label=string.rep("  ",math.min(choice.depth,8))..choice.name
            ui:row(label,x+13,y+69+(i-1)*25,w-26,24,function()
                if self:moveNode(m.node,choice.id) then self.modal=nil else m.error=self.status end
            end,choice.id==m.node.parent)
        end
        if m.error then ui:text(m.error,x+15,y+h-55,C.error,ui.small,w-30) end
        if max>0 then
            ui:button("Up",x+15,y+h-35,38,25,function()m.offset=math.max(0,m.offset-4)end,{outline=true})
            ui:button("Down",x+59,y+h-35,49,25,function()m.offset=math.min(max,m.offset+4)end,{outline=true})
        end
        ui:button("Cancel",x+w-98,y+h-37,83,27,function()self.modal=nil end,{outline=true})
    elseif m.kind=="published" then
        local w,h=560,math.min(450,H-60)
        local x,y=ui:modal("Published worlds",w,h)
        local title=m.loading and "Loading…" or #m.worlds==0 and "Publish a place to add it here." or "Open a published copy or remove it from the library."
        ui:text(m.error or title,x+15,y+44,m.error and C.error or C.muted,ui.small,w-30)
        local count=math.floor((h-118)/34)
        local offset=clamp(m.offset,0,math.max(0,#m.worlds-count))
        for i=1,count do
            local entry=m.worlds[offset+i]
            if not entry then break end
            local row=y+72+(i-1)*34
            ui:row(entry.name,x+13,row,w-208,31,nil)
            ui:button("Open",x+w-186,row,72,27,function()
                self:confirmDiscard(function()
                    self:call("openPublished",{world=entry.id},function(p)self:set(p);self.modal=nil;self.status="Opened published "..p.name end)
                end)
            end,{outline=true})
            ui:button("Unpublish",x+w-106,row,88,27,function() self.modal={kind="unpublish",world=entry} end,{outline=true,danger=true})
        end
        ui:button("Close",x+w-97,y+h-42,82,29,function()self.modal=nil end,{outline=true})
    elseif m.kind=="unpublish" or m.kind=="discard" then
        local title=m.kind=="discard" and "Save your changes?" or "Unpublish "..m.world.name.."?"
        local x,y=ui:modal(title,470,151)
        ui:text(m.error or (m.kind=="discard" and "Save this project or discard the changes." or "This removes the place from the playable library."),x+16,y+49,C.muted,ui.small,438)
        ui:button("Cancel",x+15,y+105,90,30,function() self.modal=nil end,{outline=true})
        if m.kind=="discard" then
            ui:button("Discard",x+264,y+105,90,30,function() self.modal=nil;m.action() end,{outline=true,danger=true})
            ui:button("Save",x+364,y+105,90,30,function() self:save(self.file,m.action) end,{primary=true})
        else
            ui:button("Unpublish",x+354,y+105,100,30,function()
                self:call("unpublish",{world=m.world.id},function() self.status="Unpublished "..m.world.name;self:library() end)
            end,{outline=true,danger=true})
        end
    else
        local saving=m.kind=="save"
        local w,h=600,saving and 174 or 356
        local x,y=ui:modal(saving and "Save project" or "Open project",w,h)
        ui:text(saving and "Save as a binary .pot file." or "Enter a project path or select a recent file. You can also drop a project onto the editor.",x+15,y+43,C.muted,ui.small,w-30)
        ui:field("path",m.path,x+15,y+70,w-30,30,{limit=4096,live=function(v)m.path=v end})
        if not saving then
            local index=0
            for _,name in ipairs(love.filesystem.getDirectoryItems("Projects")) do
                if name:lower():match("%.pot$") and index<6 then
                    ui:row(name,x+15,y+111+index*25,w-30,24,function()m.path=love.filesystem.getSaveDirectory().."/Projects/"..name end,m.path:sub(-#name)==name)
                    index=index+1
                end
            end
        end
        if m.error then ui:text(m.error,x+15,y+h-66,C.error,ui.small,w-30) end
        ui:button("Cancel",x+15,y+h-41,90,29,function()self.modal=nil end,{outline=true})
        ui:button(saving and "Save" or "Open",x+w-108,y+h-41,92,29,m.path~="" and function()
            if saving then self:save(m.path,m.after)
            else self:call("open",{path=m.path},function(value)
                self.modal=nil
                self:set(value,m.path:lower():match("%.pot$") and m.path or nil)
                self.status="Opened "..value.name
            end) end
        end or nil,{primary=true})
    end
end

function Studio:mousepressed(x,y,b)
    if b==1 then
        local row=not self.modal and self:explorerHit(x,y)
        if self.ui:click(x,y) then
            if row and row.id and self.selected==row.id and x>=row.label then self.dragNode={id=row.id,x=x,y=y} end
            return
        end
    end
    if self.modal then return end
    local W=G.getWidth()
    if b==1 and y>117 and math.abs(x-(W-self.pane-3))<5 and not self.view.playing then self.resizing=true;return end
    if not self.pending then self.view:mousepressed(x,y,b) end
end
function Studio:mousemoved(x,y,dx,dy)
    if self.resizing then self.pane=clamp(G.getWidth()-x,264,430)
    elseif self.dragNode then
        if math.abs(self.dragNode.x-x)+math.abs(self.dragNode.y-y)>7 then self.dragNode.active=true end
    else self.view:mousemoved(x,y,dx,dy) end
end
function Studio:mousereleased(x,y)
    self.resizing=false
    if self.dragNode then
        local drag=self.dragNode
        self.dragNode=nil
        local target=drag.active and self:explorerHit(x,y)
        if target and target.id~=drag.id then self:moveNode(self.nodes[drag.id],target.id) end
        return
    end
    self.view:mousereleased(x,y)
end
function Studio:wheelmoved(dx,dy)
    if self.modal then self.modal.offset=math.max(0,(self.modal.offset or 0)-dy*2);return end
    local x,y=love.mouse.getPosition()
    if self.view:area(x,y) then self.view:wheel(dy)
    elseif y>=117 and y<self.explorerBottom then self.scroll=math.max(0,self.scroll-dy*3) end
end
function Studio:textinput(value) self.ui:insert(value) end
function Studio:filedropped(file)
    local path=file:getFilename()
    if path:lower():match("%.png$") then
        if self.pending or self.view.playing then return end
        local part=self:part()
        if not part then self.status="Select a part before dropping a texture.";return end
        if not self.modal then self.modal=Surface.new(part,self.scene,id) end
        if self.modal.kind=="texture" then self.modal:import(self,path) end
    else self:open(path) end
end
function Studio:focus(held)
    if not held then self.dragNode=nil; self.view:cancel() end
end
function Studio:keypressed(key,_,repeatKey)
    local command=love.keyboard.isDown("lctrl","rctrl","lgui","rgui")
    if command and not repeatKey and (key=="s" or key=="o") and not self.modal and not self.view.playing then
        self.ui:blur(false)
        if key=="s" then self:save(not love.keyboard.isDown("lshift","rshift") and self.file or nil)
        else self:open() end
        return
    end
    if self.ui:key(key) or repeatKey then return end
    if self.modal then
        if key=="escape" then
            if self.modal.kind=="texture" or self.modal.kind=="textureRemove" then self:refresh() end
            self.modal=nil
        end
        return
    end
    if key=="escape" and self.dragNode then self.dragNode=nil;return end
    if key=="escape" and self.view:cancel() then return end
    if key=="f5" or (self.view.playing and key=="escape") then self:play();return end
    if self.view.playing then
        if key=="space" then self.jump=self.jump+1
        elseif key=="f6" and self.view.allowReset then self.backend:call("reset",{})
        elseif key=="e" then self:press(self.view.interaction) end
        return
    end
    if command then
        if key=="z" then self:undo(love.keyboard.isDown("lshift","rshift") and 1 or -1)
        elseif key=="y" then self:undo(1)
        elseif key=="d" then self:duplicate() end
        return
    end
    local tools={q="select",w="translate",e="rotate",r="scale"}
    if self.view.drag and self.view.drag.button==2 then return end
    if tools[key] then self.view.tool=tools[key]
    elseif key=="f" then self.view:frame(self.selected)
    elseif key=="delete" or key=="backspace" then self:delete() end
end
function Studio:quit()
    if self.allowQuit or not self:dirty() then return false end
    self:confirmDiscard(function()self.allowQuit=true;love.event.quit()end)
    return true
end
return Studio
