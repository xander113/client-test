local UI=require("ui")
local View=require("view")
local Wire=require("wire")
local Menu=require("menu")
local G=love.graphics
local C=UI.colors
local Client={}
Client.__index=Client
local settingsPath="client-settings.pot-config"
local renderScales={.60,.82,1}

local function tone(first,last,length)
    local rate=22050
    local count=math.floor(length*rate)
    local data=love.sound.newSoundData(count,rate,16,1)
    local phase=0
    for i=0,count-1 do
        local t=i/count
        phase=phase+2*math.pi*(first+(last-first)*t)/rate
        data:setSample(i,math.sin(phase)*math.min(1,t*25)*(1-t)^2*.25)
    end
    return love.audio.newSource(data)
end

function Client.new(backend)
    local self=setmetatable({backend=backend,ui=UI.new(),worlds={},preview={},search="",scroll=0,status="Loading worlds…",
        mode="local",elapsed=0,jump=0,menu=Menu.new(),volume=.75,lastVolume=.75,quality=2,previewBlend=0,transition=0},Client)
    self.view=View.new(nil,nil,function(part)self:press(part)end)
    self.titleIcon=G.newImage("icon.png")
    self:loadSettings()
    if love.audio and love.sound then
        local ok,sounds=pcall(function() return {menu=tone(580,670,.10),jump=tone(370,490,.10),
            press=tone(440,615,.12),reset=tone(450,735,.20)} end)
        if ok then self.sounds=sounds end
    end
    self:reload()
    return self
end

function Client:loadSettings()
    local info=love.filesystem.getInfo(settingsPath,"file")
    if info and info.size<=128 then
        local ok,value=pcall(Wire.decode,love.filesystem.read(settingsPath),128)
        if ok and type(value)=="table" then
            if type(value.volume)=="number" and value.volume>=0 and value.volume<=1 then self.volume=value.volume end
            if type(value.lastVolume)=="number" and value.lastVolume>0 and value.lastVolume<=1 then self.lastVolume=value.lastVolume end
            if renderScales[value.quality] then self.quality=value.quality end
        end
    end
    self:setVolume(self.volume)
    self:setQuality(self.quality)
end

function Client:saveSettings()
    local ok=love.filesystem.write(settingsPath,Wire.encode({volume=self.volume,lastVolume=self.lastVolume,quality=self.quality}))
    if not ok then self.status="Settings could not be saved on this device." end
end

function Client:setVolume(value)
    self.volume=value
    if value>0 then self.lastVolume=value end
    if love.audio then love.audio.setVolume(value) end
end

function Client:setQuality(value)
    self.quality=value
    self.view.renderScale=renderScales[value]
end

function Client:resolution() return math.floor(self.view.renderScale*100+.5) end

function Client:sound(name)
    local s=self.sounds and self.sounds[name]
    if s then s:stop(); s:play() end
end

function Client:openMenu()
    self.ui:blur(false)
    self.view:cancel()
    self.menuStatus=nil
    self.menu:show(self.view.playing)
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
    if self.previewTarget~=id then self.previewTarget,self.previewBlend=id,0 end
    self.selected=id
    if self.preview[id]==nil then
        self.preview[id]=false
        self.backend:call("thumbnail",{world=id},function(image,err)
            if image and Wire.isBytes(image) then
                local data=love.filesystem.newFileData(image.data,"thumbnail.png")
                local ok,value=pcall(G.newImage,data)
                if ok then
                    self.preview[id]=value
                    if self.selected==id then self.previewBlend=0 end
                    return
                end
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
        self.menu:close()
        self.view:set(scene)
        self.view:play(true)
        self.transition=1
        self.jump,self.elapsed=0,0
        self.backend:call(online and "join" or "solo",online and {world=id} or {scene=scene},function(ok,problem)
            if ok then
                self.starting=false
                self.status=online and (self.mode=="hosted" and "Online session" or "Local session") or "Playing solo"
            elseif online then
                self:solo("Session unavailable. Playing solo.")
            else
                self.starting=false
                self.view:play(false)
                self.menu:close()
                self.status=problem
            end
        end)
    end)
end

function Client:solo(status)
    self.starting,self.resetPending=true,nil
    self.view:play(false)
    self.view:play(true)
    self.backend:call("solo",{scene=self.scene},function(ok,err)
        self.starting=false
        if not ok then self.view:play(false); self.menu:close() end
        self.status=err or status
    end)
end

function Client:stop()
    if self.starting then return end
    self.backend:call("leave",{})
    self.view:play(false)
    self.transition=1
    self.menu:close()
    self.resetPending=nil
    self.status="Ready"
end

function Client:reset()
    if self.starting or self.view.allowReset~=true or self.resetPending then return end
    self.resetPending=love.timer.getTime()+8
    self.menuStatus=nil
    self.backend:call("reset",{})
end

function Client:event(event)
    if not self.view.playing then return end
    if event.type=="sessionPlace" then
        self.scene=event.scene
        self.view:set(event.scene)
        return
    end
    if event.type=="resetResult" then
        self.resetPending=nil
        if event.ok then
            self.menu:close()
            self:sound("reset")
        else self.menuStatus=event.message or "Character reset is unavailable." end
        return
    end
    self.view:state(event)
    if event.scriptError then self.status=event.scriptError end
    if event.type=="closed" then self:solo("Session ended. Playing solo.") end
end

function Client:press(part)
    if part and not self.menu:active() then self.backend:call("press",{part=part}); self:sound("press") end
end

function Client:update(dt)
    self.menu:update(dt)
    self.transition=math.max(0,self.transition-dt*5)
    self.previewBlend=self.previewBlend+(1-self.previewBlend)*(1-math.exp(-dt*14))
    if self.resetPending and love.timer.getTime()>self.resetPending then
        self.resetPending=nil
        self.menuStatus="The session did not respond. Try resetting again."
    end
    self.view:update(dt)
    if not self.view.playing or self.starting then return end
    self.elapsed=self.elapsed+dt
    if self.elapsed<.05 then return end
    self.elapsed=0
    local key=love.keyboard.isDown
    local x,z=0,0
    if not self.menu:active() and love.window.hasFocus() then
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
    if not playing then
        ui:button("Worlds",129,7,81,30,not self.starting and function()self:reload()end or nil,{selected=true})
    end
    ui:button(playing and "Menu  Esc" or "Options",W-103,7,90,30,function()self:openMenu()end)
    ui.rect(C.panel,0,44,W,34);ui.line(C.edge,0,44,W,34)
    ui:text(playing and self.scene.name or "World library",11,52)
    ui:text(self.mode=="hosted" and "Hosted library" or "Local library",W-110,53,C.muted,ui.small)
    if playing then
        self.view:draw(0,78,W,H-127)
        if self.view.interaction then
            local part=self.view.parts[self.view.interaction]
            ui.rect(C.paper,12,H-94,240,32,4)
            ui:text("E  Activate "..(part and part.name or "part"),20,H-87)
        end
        ui.rect(C.paper,0,H-49,W,26)
        ui:text("WASD move    Space jump    Drag look    Scroll zoom    E interact    Esc menu",11,H-42,C.muted,ui.small)
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
        self.visibleWorlds=visible
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
                G.setColor(1,1,1,self.previewBlend)
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
    if self.transition>0 then ui.rect({C.paper[1],C.paper[2],C.paper[3],self.transition*.60},0,44,W,H-67) end
    self.menu:draw(self)
end

function Client:mousepressed(x,y,button)
    if self.menu:click(self,x,y,button) then return end
    if button==1 and self.ui:click(x,y) then return end
    if self.view.playing then self.view:mousepressed(x,y,button) end
end
function Client:mousereleased(x,y)
    if self.menu.drag then
        self.menu.drag=nil
        self:saveSettings()
        self:sound("menu")
    elseif not self.menu:active() then self.view:mousereleased(x,y) end
end
function Client:mousemoved(x,y,dx,dy)
    if self.menu.drag then self.menu:changeVolume(self,x)
    elseif not self.menu:active() then self.view:mousemoved(x,y,dx,dy) end
end
function Client:wheelmoved(_,dy)
    if self.menu:active() then
        if self.menu.page=="Players" then self.menu.offset=math.max(0,self.menu.offset-dy*3) end
        return
    end
    if self.view.playing then self.view:wheel(dy) else self.scroll=math.max(0,self.scroll-dy*3) end
end
function Client:textinput(value) self.ui:insert(value) end
function Client:focus(active)
    if not active then
        self.view:cancel()
        if self.menu.drag then self.menu.drag=nil;self:saveSettings() end
    end
end
function Client:keypressed(key,_,repeatKey)
    if self.menu:active() then
        if key=="escape" and not repeatKey and not self.menu.visible and self.view.playing then self:openMenu()
        elseif not repeatKey then self.menu:key(self,key) end
        return
    end
    if self.ui:key(key) or repeatKey then return end
    if self.view.playing then
        if key=="escape" then self:openMenu()
        elseif key=="space" and not self.starting then self.jump=self.jump+1;self:sound("jump")
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
            if index>self.scroll+(self.visibleWorlds or 1) then self.scroll=index-(self.visibleWorlds or 1) end
        end
    end
end
return Client
