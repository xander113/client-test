local UI=require("ui")
local View=require("view")
local Wire=require("wire")
local G=love.graphics
local Studio={}
Studio.__index=Studio
local C=UI.colors
local shapes={box={"Box",{2,2,2},"#3eb36e"},sphere={"Sphere",{2,2,2},"#568ee0"},cylinder={"Cylinder",{2,3,2},"#dfa64e"}}
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
}
local function id()
    return ("%x-%x-%x"):format(os.time(),love.math.random(0,0xffffff),love.math.random(0,0xffffff))
end
local function clamp(a,b,c) return math.max(b,math.min(c,a)) end
local function copy(v) return Wire.decode(Wire.encode(v)) end
local function blank()
    return {schemaVersion=3,id="world-"..id(),name="Untitled world",description="",spawn={x=0,y=0,z=5},
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
    self.query,self.scroll="",0
    self.view:set(scene)
    self.view.selected=nil
    self.view:frame(nil,"perspective",true)
end

function Studio:select(value)
    self.selected=value
    self.view.selected=value
end

function Studio:checkpoint()
    local data=Wire.encode(self.scene)
    if self.history[self.index].data==data then return end
    while #self.history>self.index do self.history[#self.history]=nil end
    self.history[#self.history+1]={data=data,selected=self.selected}
    if #self.history>65 then table.remove(self.history,1) end
    self.index=#self.history
    self.view:set(self.scene)
end

function Studio:dirty() return self.history[self.index].data~=self.saved end
function Studio:undo(step)
    local n=self.index+step
    if not self.history[n] then return end
    self.index=n
    self.scene=Wire.decode(self.history[n].data)
    self.view:set(self.scene)
    self:select(self.history[n].selected or (self.view.parts[self.selected] and self.selected))
    self.status=step<0 and "Undid the last edit" or "Redid the last edit"
end

function Studio:part()
    return self.view.parts[self.selected]
end

function Studio:add(kind)
    if #self.scene.objects>=400 then self.status="The place already has 400 parts."; return end
    local spec=shapes[kind]
    local spawn=self.scene.spawn
    local near=self:part()
    local x,y,z=spawn.x+2.5,spawn.y+spec[2][2]*.5,spawn.z
    if near and near.size[1]<12 then
        x,y,z=near.position[1]+(near.size[1]+spec[2][1])*.5+.5,near.position[2],near.position[3]
    end
    local part={id=id(),name=spec[1],kind=kind,position={clamp(x,-250,250),clamp(y,-40,250),z},
        size=copy(spec[2]),rotation={0,0,0},color=spec[3],solid=true}
    self.scene.objects[#self.scene.objects+1]=part
    self:select(part.id)
    self:checkpoint()
    self.query=""
    self.scroll=math.max(0,#self.scene.objects-7)
    self.status="Added "..spec[1]
end

function Studio:delete()
    if not self.selected then return end
    for i=#self.scene.objects,1,-1 do if self.scene.objects[i].id==self.selected then table.remove(self.scene.objects,i) end end
    for i=#self.scene.scripts,1,-1 do if self.scene.scripts[i].part==self.selected then table.remove(self.scene.scripts,i) end end
    self:select(nil); self:checkpoint()
end

function Studio:duplicate()
    local part=self:part()
    if not part or #self.scene.objects>=400 then return end
    local p=copy(part)
    p.id=id()
    p.name=part.name:sub(1,70).." copy"
    local x=part.position[1]+part.size[1]+.5
    p.position[1]=clamp(x>250 and part.position[1]-part.size[1]-.5 or x,-250,250)
    self.scene.objects[#self.scene.objects+1]=p
    for _,s in ipairs(self.scene.scripts) do
        if s.part==part.id and #self.scene.scripts<48 then
            self.scene.scripts[#self.scene.scripts+1]={part=p.id,source=s.source,enabled=s.enabled}
            break
        end
    end
    self:select(p.id);self:checkpoint()
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

function Studio:scriptEditor()
    local part=self:part()
    if not part then return end
    local found
    for _,s in ipairs(self.scene.scripts) do if s.part==part.id then found=s; break end end
    self.modal={kind="script",part=part,source=found and found.source or templates.press,enabled=found==nil or found.enabled}
end

function Studio:applyScript(checkOnly)
    local m=self.modal
    if self.pending then return end
    self.pending=true
    local source=m.source
    self.backend:call("script",{source=source},function(value,err)
        self.pending=false
        if self.modal~=m then return end
        m.error,m.valid=err,value and "Ready to run in playtest." or nil
        if not value or checkOnly then return end
        local scripts=self.scene.scripts
        local updated
        for _,s in ipairs(scripts) do
            if s.part==m.part.id then s.source,s.enabled=source,m.enabled;updated=true;break end
        end
        if not updated then
            if #scripts>=48 then m.error="A world can hold up to 48 part scripts.";return end
            scripts[#scripts+1]={part=m.part.id,source=source,enabled=m.enabled}
        end
        self.modal=nil
        self.ui:blur(true)
        self:checkpoint()
        self.status="Script attached to "..m.part.name
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

function Studio:inspector(x,y,w,h,locked)
    local ui=self.ui
    local o=self:part()
    ui.rect(C.paper,x,y,w,h)
    ui.rect(C.panel,x,y,w,32)
    ui:text(o and "Part properties" or "Place properties",x+9,y+7)
    if locked then return end
    local row=y+45
    self:property("Name",o and o.name or self.scene.name,x+9,row,w-18,function(v)
        if v:match("%S") and #v<=80 then (o or self.scene).name=v;self:checkpoint() end
    end)
    row=row+51
    local vectors=o and {{"Position","position",-250,250},{"Rotation (degrees)","rotation",-180,180},{"Size","size",.1,128}}
        or {{"Spawn position","spawn",-250,250}}
    for _,field in ipairs(vectors) do
        ui:text(field[1],x+9,row,C.muted,ui.small)
        local col=(w-30)/3
        for i,axis in ipairs({"x","y","z"}) do
            local xx=x+9+(i-1)*(col+6)
            local values=o and o[field[2]] or self.scene.spawn
            local key=o and i or axis
            ui:field("value-"..field[2]..axis,("%.3g"):format(values[key]),xx,row+16,col,24,{commit=function(v)
                local number=tonumber(v)
                if number and number==number then
                    local low=(i==2 and (field[2]=="position" or field[2]=="spawn")) and -40 or field[3]
                    values[key]=clamp(number,low,field[4]);self:checkpoint()
                end
            end})
            ui:text(axis:upper(),xx+3,row+42,C.muted,ui.small)
        end
        row=row+62
    end
    if o then
        self:property("Color",o.color,x+9,row,math.max(72,w-146),function(v)
            if v:match("^#%x%x%x%x%x%x$") then o.color=v:lower();self:checkpoint() end
        end)
        ui:button(o.solid and "Solid" or "No collision",x+w-109,row+14,98,26,function()o.solid=not o.solid;self:checkpoint()end,{outline=true})
        row=row+47
        local hasScript
        for _,s in ipairs(self.scene.scripts) do if s.part==o.id then hasScript=true; break end end
        ui:button(hasScript and "Edit script" or "Add script",x+9,row,110,28,function()self:scriptEditor() end,{outline=true})
        ui:button("Copy part ID",x+125,row,103,28,function() love.system.setClipboardText(o.id); self.status="Part ID copied." end,{outline=true})
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
        {"Box",function()self:add("box")end},{"Sphere",function()self:add("sphere")end},{"Cylinder",function()self:add("cylinder")end}}
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
    local top=math.floor((H-143)*.33)
    ui.rect(C.edge,panel-5,y,5,H-143)
    ui.rect(C.paper,panel,y,self.pane,H-143)
    ui.rect(C.panel,panel,y,self.pane,31)
    ui:text("Outliner",panel+9,y+7)
    ui:button("Duplicate",W-146,y+3,78,25,not locked and self:part() and function()self:duplicate()end or nil)
    ui:button("Delete",W-64,y+3,56,25,not locked and self:part() and function()self:delete()end or nil)
    if not locked then
        ui:field("search",self.query,panel+8,y+37,self.pane-16,26,{live=function(v)self.query,self.scroll=v,0 end})
        if self.query=="" and ui.focus~="search" then ui:text("Find a part",panel+14,y+42,C.muted) end
        ui:row(self.scene.name,panel+7,y+68,self.pane-14,24,function()self:select(nil)end,not self.selected)
        local matches={}
        for _,part in ipairs(self.scene.objects) do
            if part.name:lower():find(self.query:lower(),1,true) then matches[#matches+1]=part end
        end
        local count=math.max(1,math.floor((top-94)/23))
        self.scroll=clamp(self.scroll,0,math.max(0,#matches-count))
        for i=1,count do
            local part=matches[self.scroll+i]
            if not part then break end
            ui:row("  "..part.name,panel+7,y+92+(i-1)*23,self.pane-14,22,function()self:select(part.id)end,self.selected==part.id)
        end
    end
    self:inspector(panel,y+top,self.pane,H-y-top-26,locked)
    ui.rect(C.paper,0,H-51,panel-5,25)
    ui:text(self.view.playing and "WASD move    Space jump    Drag look    E interact    Esc return"
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
    if m.kind=="script" then
        local w,h=math.min(W-38,760),math.min(H-32,590)
        local x,y=ui:modal("Script on "..m.part.name,w,h)
        ui:text("Lua / Luau",x+17,y+42,C.muted,ui.small)
        ui:button("Press example",x+110,y+36,106,28,function()ui:blur(true);m.source=templates.press end,{outline=true})
        ui:button("Touch example",x+222,y+36,108,28,function()ui:blur(true);m.source=templates.touch end,{outline=true})
        ui:button(m.enabled and "Enabled" or "Disabled",x+w-105,y+36,88,28,function()m.enabled=not m.enabled end,{outline=true})
        ui:field("script",m.source,x+15,y+70,w-30,h-175,{multi=true,limit=4096,live=function(value)m.source=value;m.error=nil;m.valid=nil end})
        ui:text("Pot.onPress    Pot.onTouch    Pot.pulse    Pot.setColor    Pot.setSolid    Pot.setVisible    Pot.after",x+15,y+h-98,C.muted,ui.small,w-30)
        ui:text(m.error or m.valid or "Use \"self\" for this part or copy a target's ID from Properties.",x+15,y+h-75,m.error and C.error or C.muted,ui.small,w-30)
        ui:button("Cancel",x+14,y+h-43,82,29,function()self.modal=nil end,{outline=true})
        ui:button("Check script",x+w-225,y+h-43,105,29,function()self:applyScript(true)end,{outline=true})
        ui:button("Apply",x+w-112,y+h-43,96,29,function()self:applyScript(false)end,{primary=true})
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
    if b==1 and self.ui:click(x,y) then return end
    if self.modal then return end
    local W=G.getWidth()
    if b==1 and y>117 and math.abs(x-(W-self.pane-3))<5 and not self.view.playing then self.resizing=true;return end
    if not self.pending then self.view:mousepressed(x,y,b) end
end
function Studio:mousemoved(x,y,dx,dy)
    if self.resizing then self.pane=clamp(G.getWidth()-x,264,430)
    else self.view:mousemoved(x,y,dx,dy) end
end
function Studio:mousereleased(x,y)
    self.resizing=false
    self.view:mousereleased(x,y)
end
function Studio:wheelmoved(dx,dy)
    if self.modal then self.modal.offset=math.max(0,(self.modal.offset or 0)-dy*2);return end
    local x,y=love.mouse.getPosition()
    if self.view:area(x,y) then self.view:wheel(dy)
    else self.scroll=math.max(0,self.scroll-dy*3) end
end
function Studio:textinput(value) self.ui:insert(value) end
function Studio:filedropped(file) self:open(file:getFilename()) end
function Studio:focus(held)
    if not held then self.view:cancel() end
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
    if self.modal then if key=="escape" then self.modal=nil end;return end
    if key=="escape" and self.view:cancel() then return end
    if key=="f5" or (self.view.playing and key=="escape") then self:play();return end
    if self.view.playing then
        if key=="space" then self.jump=self.jump+1
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
