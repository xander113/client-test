local UI=require("ui")
local View=require("view")
local Wire=require("wire")
local G=love.graphics
local C=UI.colors
local Client={}
Client.__index=Client

function Client.new(backend)
    local self=setmetatable({backend=backend,ui=UI.new(),worlds={},preview={},search="",scroll=0,status="Loading worlds…",
        mode="local",elapsed=0,jump=0,selection=nil},Client)
    self.view=View.new(nil,nil,function(part)self:press(part)end)
    self.titleIcon=G.newImage("icon.png")
    self:reload()
    return self
end

function Client:reload()
    if self.loading then return end
    self.loading=true
    self.backend:call("mode",{},function(mode)self.mode=mode or "local" end)
    self.backend:call("worlds",{},function(items,err)
        self.loading=false
        if not items then self.status=err; return end
        self.worlds,self.preview=items,{}
        self.status=#items>0 and "Ready" or "There are no published worlds."
        self.selected=self:current() and self.selected or items[1] and items[1].id
        if self.selected then self:select(self.selected) end
    end)
end
function Client:current()
    for _,entry in ipairs(self.worlds) do if entry.id==self.selected then return entry end end
end
function Client:select(id)
    self.selected=id
    if not self.preview[id] then
        self.preview[id]=false
        self.backend:call("thumbnail",{world=id},function(image,err)
            if image and Wire.isBytes(image) then
                local data=love.filesystem.newFileData(image.data,"thumbnail.png")
                local ok,value=pcall(G.newImage,data)
                if ok then self.preview[id]=value;return end
            end
            if self.selected==id and err then self.status=err end
        end)
    end
end
function Client:start(online)
    if not self.selected or self.starting or self.view.playing then return end
    self.starting=true
    local id=self.selected
    self.status="Opening world…"
    self.backend:call("load",{world=id},function(scene,err)
        if not scene then self.starting=false;self.status=err;return end
        self.scene=scene
        self.view:set(scene)
        self.view:play(true)
        self.jump,self.elapsed=0,0
        self.online=online
        self.backend:call(online and "join" or "solo",{world=id},function(ok,error)
            if ok then
                self.starting=false
                self.status=online and "Session joined" or "Playing solo"
            elseif online then
                self.online=false
                self.backend:call("solo",{world=id},function(value,retry)
                    self.starting=false
                    if not value then self.view:play(false) end
                    self.status=retry or "Session unavailable. Playing solo."
                end)
            else
                self.starting=false
                self.view:play(false)
                self.status=error
            end
        end)
    end)
end
function Client:stop()
    if self.starting then return end
    self.backend:call("leave",{})
    self.view:play(false)
    self.status="Ready"
end
function Client:event(event)
    if not self.view.playing then return end
    self.view:state(event)
    if event.scriptError then self.status=event.scriptError end
    if event.type=="closed" then
        self.online=false
        self.backend:call("solo",{world=self.selected},function(ok,err)
            if not ok then self.view:play(false) end
            self.status=err or "Session ended. Playing solo."
        end)
    end
end
function Client:press(part)
    if part then self.backend:call("press",{part=part}) end
end
function Client:update(dt)
    self.view:update(dt)
    if not self.view.playing or self.starting then return end
    self.elapsed=self.elapsed+dt
    if self.elapsed<.05 then return end
    self.elapsed=0
    local key=love.keyboard.isDown
    local x,z=0,0
    if not self.help and love.window.hasFocus() then
        x=(key("d","right") and 1 or 0)-(key("a","left") and 1 or 0)
        z=(key("w","up") and 1 or 0)-(key("s","down") and 1 or 0)
    end
    local yaw=self.view.yaw
    self.backend:call("input",{input={x=x,z=z,yaw=math.atan2(math.sin(yaw),math.cos(yaw)),jump=self.jump}})
end

function Client:draw()
    local ui=self.ui
    ui:begin()
    local W,H=G.getDimensions()
    local playing=self.view.playing
    ui.rect(C.paper,0,0,W,44)
    ui.line(C.edge,0,0,W,44)
    G.setColor(1,1,1);G.draw(self.titleIcon,11,8,0,27/self.titleIcon:getWidth())
    ui:text("Pot Client",45,13)
    ui:button("Worlds",129,7,81,30,not self.starting and function()
        if playing then self:stop() else self:reload() end
    end or nil,{selected=not playing})
    ui:button("Controls",W-103,7,90,30,function()self.help=true end)
    ui.rect(C.panel,0,44,W,34);ui.line(C.edge,0,44,W,34)
    ui:text(playing and self.scene.name or "World library",11,52)
    ui:text(self.mode=="hosted" and "Hosted library" or "Local library",W-110,53,C.muted,ui.small)
    if playing then
        local side=self.online and 171 or 0
        self.view:draw(0,78,W-side,H-127)
        if self.view.interaction then
            local part=self.view.parts[self.view.interaction]
            ui.rect(C.paper,12,H-94,240,32,4)
            ui:text("E  Activate "..(part and part.name or "part"),20,H-87)
        end
        if self.online then
            ui.rect(C.paper,W-side,78,side,H-127)
            ui:text("Players",W-side+9,88)
            local y=114
            for _,actor in pairs(self.view.actors) do
                ui:row(actor.name,W-side+5,y,side-10,23,nil,false)
                y=y+24
            end
        end
        ui.rect(C.paper,0,H-49,W,26)
        ui:text("WASD move    Space jump    Drag look    Scroll zoom    E interact    Esc leave",11,H-42,C.muted,ui.small)
    else
        local side=234
        ui.rect(C.panel,0,78,side,H-101)
        ui.line(C.edge,0,78,side,H-101)
        ui:field("world-search",self.search,8,87,side-16,27,{live=function(v)self.search=v; self.scroll=0 end})
        if self.search=="" and ui.focus~="world-search" then ui:text("Find a world",15,93,C.muted) end
        local items={}
        for _,item in ipairs(self.worlds) do
            if item.name:lower():find(self.search:lower(),1,true) then items[#items+1]=item end
        end
        self.filtered=items
        local visible=math.floor((H-151)/32)
        self.scroll=math.max(0,math.min(self.scroll,math.max(0,#items-visible)))
        for i=1,visible do
            local item=items[self.scroll+i]
            if not item then break end
            ui:row(item.name,7,121+(i-1)*32,side-14,30,function() self:select(item.id) end,item.id==self.selected)
        end
        local entry=self:current()
        if entry then
            local image=self.preview[entry.id]
            local height=H-232
            ui.rect({.88,.93,.95},side,78,W-side,height)
            if image then
                local scale=math.min((W-side)/image:getWidth(),height/image:getHeight())
                G.setColor(1,1,1)
                G.draw(image,side+(W-side-image:getWidth()*scale)/2,78+(height-image:getHeight()*scale)/2,0,scale)
            end
            local y=H-148
            ui:text(entry.name,side+17,y,C.ink,ui.title)
            ui:text(entry.description,side+17,y+31,C.muted,ui.font,W-side-35)
            ui:button("Play solo",side+17,H-65,94,32,not self.starting and function()self:start(false)end or nil,{primary=true})
            ui:button(self.mode=="hosted" and "Join online" or "Join local",side+119,H-65,105,32,
                not self.starting and function()self:start(true)end or nil,{outline=true})
        else
            ui:text(self.loading and "Loading worlds…" or self.status,side+15,101,C.muted,ui.font,W-side-30)
            if not self.loading then ui:button("Refresh",side+15,150,90,29,function()self:reload()end,{outline=true}) end
        end
    end
    ui.rect(C.panel,0,H-23,W,23);ui.line(C.edge,0,H-23,W,23)
    ui:text(self.status,10,H-18,C.muted,ui.small,W-20)
    if self.help then
        local x,y=ui:modal("Controls",380,217)
        ui:text("WASD or arrows     Move\nSpace                 Jump\nMouse drag          Look\nE                       Interact with nearby parts\nEsc                    Leave the world",x+15,y+45,C.muted,ui.font,347)
        ui:button("Close",x+276,y+173,90,29,function()self.help=false end,{outline=true})
    end
end
function Client:mousepressed(x,y,button)
    if button==1 and self.ui:click(x,y) then return end
    if not self.help and self.view.playing then self.view:mousepressed(x,y,button) end
end
function Client:mousereleased(x,y) self.view:mousereleased(x,y) end
function Client:mousemoved(x,y,dx,dy) self.view:mousemoved(x,y,dx,dy) end
function Client:wheelmoved(_,dy)
    if self.help then return end
    if self.view.playing then self.view:wheel(dy) else self.scroll=math.max(0,self.scroll-dy*3) end
end
function Client:textinput(value) self.ui:insert(value) end
function Client:focus(active) if not active then self.view:cancel() end end
function Client:keypressed(key,_,repeatKey)
    if self.ui:key(key) or repeatKey then return end
    if self.help then if key=="escape" then self.help=false end; return end
    if self.view.playing then
        if key=="escape" then self:stop()
        elseif key=="space" then self.jump=self.jump+1
        elseif key=="e" then self:press(self.view.interaction) end
    elseif key=="return" then self:start(false)
    elseif key=="up" or key=="down" then
        local items=self.filtered or self.worlds
        local index=1
        for i,item in ipairs(items) do if item.id==self.selected then index=i;break end end
        index=math.min(#items,math.max(1,index+(key=="up" and -1 or 1)))
        if items[index] then
            self:select(items[index].id)
            if index<=self.scroll then self.scroll=index-1 end
        end
    end
end
return Client
