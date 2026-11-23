local UI=require("ui")
local G=love.graphics
local C=UI.colors
local Menu={}
Menu.__index=Menu
local tabs={"Players","Settings","Controls"}
local qualityLabels={"Low","Balanced","High"}

function Menu.new()
    return setmetatable({amount=0,row=0,offset=0,body=1},Menu)
end

function Menu:show(playing)
    self.visible=true
    self:tab(playing and "Players" or "Settings",true)
end

function Menu:close()
    self.visible,self.confirm,self.drag=false,nil,nil
end

function Menu:active()
    return self.visible or self.amount>0
end

function Menu:tab(name,instant)
    self.page,self.confirm,self.offset=name,nil,0
    if not instant then self.body=0 end
    for i,label in ipairs(tabs) do
        if name==label then
            self.column=i-1
            if instant then self.row=self.column end
            break
        end
    end
end

function Menu:update(dt)
    local ease=1-math.exp(-dt*21)
    local target=self.visible and 1 or 0
    self.amount=self.amount+(target-self.amount)*ease
    if math.abs(target-self.amount)<.004 then self.amount=target end
    self.row=self.row+((self.column or 0)-self.row)*ease
    self.body=self.body+(1-self.body)*ease
end

function Menu:changeVolume(app,x)
    local slider=self.drag
    local v=math.max(0,math.min(1,(x-slider.x)/slider.w))
    app:setVolume(math.floor(v*20+.5)/20)
end

function Menu:settings(app,x,y,w)
    local ui=app.ui
    ui:text("Volume",x,y,C.ink,ui.title)
    local percentage=tostring(math.floor(app.volume*100+.5)).."%"
    ui:text(percentage,x+w-ui.font:getWidth(percentage),y+5)
    local ty=y+48
    ui.rect(C.edge,x,ty,w,5,2)
    ui.rect(C.green,x,ty,w*app.volume,5,2)
    G.setColor(C.green); G.circle("fill",x+w*app.volume,ty+2.5,8)
    self.slider={x=x,y=ty-13,w=w,h=32}
    ui:button(app.volume>0 and "Mute" or "Unmute",x,ty+21,76,27,function()
        app:setVolume(app.volume>0 and 0 or app.lastVolume)
        app:saveSettings()
        app:sound("menu")
    end,{outline=true})
    local gy=y+142
    ui:text("Graphics quality",x,gy,C.ink,ui.title)
    local bw=(w-12)/3
    for i,label in ipairs(qualityLabels) do
        ui:button(label,x+(bw+6)*(i-1),gy+37,bw,34,function()
            app:setQuality(i)
            app:saveSettings()
        end,{selected=i==app.quality,outline=true})
    end
    ui:text(tostring(app:resolution()).."% world render resolution",x,gy+84,C.muted,ui.small)
end

function Menu:players(app,x,y,w,h)
    local ui=app.ui
    local roster={}
    for id,actor in pairs(app.view.actors) do
        roster[#roster+1]={id=id,name=actor.name,color=actor.color}
    end
    local selfId=app.view.localID
    table.sort(roster,function(a,b)
        if a.id==selfId or b.id==selfId then return a.id==selfId end
        if a.name==b.name then return a.id<b.id end
        return a.name<b.name
    end)
    ui:text(#roster==1 and "1 player" or (#roster.." players"),x,y,C.muted,ui.small)
    local rows=math.max(1,math.floor((h-24)/37))
    local max=math.max(0,#roster-rows)
    self.offset=math.max(0,math.min(max,self.offset))
    local top=y+25
    for i=1,rows do
        local player=roster[self.offset+i]
        if not player then break end
        local row=top+(i-1)*37
        ui.rect(player.id==selfId and C.active or C.panel,x,row,w,33,4)
        local color=tonumber(player.color:sub(2),16)
        G.setColor(math.floor(color/65536)/255,math.floor(color/256)%256/255,color%256/255)
        G.rectangle("fill",x+10,row+9,15,15,3)
        ui:text(player.name,x+33,row+8)
        if player.id==selfId then ui:text("You",x+w-34,row+8,C.muted,ui.small) end
    end
    if max>0 then
        ui:button("Up",x+w-88,y-7,36,24,function() self.offset=math.max(0,self.offset-1) end,{outline=true})
        ui:button("Down",x+w-48,y-7,48,24,function() self.offset=math.min(max,self.offset+1) end,{outline=true})
    end
end

function Menu:controls(app,x,y)
    local keys={{"WASD or arrows","Move"},{"Space","Jump"},{"Mouse drag","Look around"},
        {"Scroll","Zoom"},{"E or click","Interact"},{"Esc","Open or close the world menu"}}
    for i,row in ipairs(keys) do
        local yy=y+(i-1)*30
        app.ui:text(row[1],x,yy,C.ink)
        app.ui:text(row[2],x+116,yy,C.muted)
    end
end

function Menu:draw(app)
    if not self:active() then return end
    local ui=app.ui
    local W,H=G.getDimensions()
    local w=math.min(384,W)
    local x=W-math.floor(w*self.amount+.5)
    local contentX,contentW=x+21,w-42
    ui:clearRegions()
    self.slider=nil
    ui.rect({.07,.15,.11,.26*self.amount},0,0,W,H)
    ui.rect({.07,.15,.11,.10*self.amount},x-5,0,5,H)
    ui.rect(C.paper,x,0,w,H)
    ui:text(app.view.playing and "World menu" or "Options",contentX,19,C.ink,ui.title)
    ui:button(app.view.playing and "Resume" or "Close",x+w-103,16,81,33,function() self:close() end,{outline=true})

    local tabY=72
    local tabW=contentW/3
    for i,name in ipairs(tabs) do
        ui:button(name,contentX+(i-1)*tabW,tabY,tabW-2,35,
            (name~="Players" or app.view.playing) and function() self:tab(name) end or nil)
    end
    ui.rect(C.edge,contentX,tabY+36,contentW,1)
    ui.rect(C.green,contentX+self.row*tabW,tabY+35,tabW-2,3,1)
    local y=129+math.floor((1-self.body)*8)

    if self.page=="Players" then self:players(app,contentX,y,contentW,H-y-152)
    elseif self.page=="Settings" then self:settings(app,contentX,y,contentW)
    else self:controls(app,contentX,y) end

    if app.view.playing then
        local footer=H-123
        local half=(contentW-8)/2
        ui.rect(C.panel,x,footer,w,123)
        ui.rect(C.edge,x,footer,w,1)
        if self.confirm then
            local reset=self.confirm=="reset"
            ui:text(reset and "Reset your character?" or "Leave this world?",contentX,footer+14)
            ui:button("Cancel",contentX,footer+60,half,38,function() self.confirm=nil end,{outline=true})
            ui:button(reset and "Reset" or "Leave",contentX+half+8,footer+60,half,38,function()
                self.confirm=nil
                if reset then app:reset() else app:stop() end
            end,{primary=reset,danger=not reset,outline=not reset})
        else
            local allow=app.view.allowReset
            local status=app.resetPending and "Resetting your character…" or app.menuStatus
            if not status and allow==false then status="This world has character reset turned off." end
            if not status and allow==nil and not app.starting then status="Character reset is unavailable in this session." end
            if status then ui:text(status,contentX,footer+13,C.muted,ui.small,contentW) end
            ui:button("Reset character",contentX,footer+60,half,38,
                allow and not app.starting and not app.resetPending and function() self.confirm="reset" end or nil,{outline=true})
            ui:button("Leave world",contentX+half+8,footer+60,half,38,
                not app.starting and function() self.confirm="leave" end or nil,{outline=true,danger=true})
        end
    end
    if not self.visible then ui:clearRegions() end
end

function Menu:click(app,x,y,b)
    if not self:active() then return false end
    if b==1 and self.visible then
        local s=self.slider
        if self.page=="Settings" and s and x>=s.x-8 and x<=s.x+s.w+8 and y>=s.y and y<=s.y+s.h then
            self.drag=s
            self:changeVolume(app,x)
        elseif not app.ui:click(x,y) and x<love.graphics.getWidth()-math.min(384,love.graphics.getWidth())*self.amount then
            self:close()
        end
    end
    return true
end

function Menu:key(app,key)
    if not self:active() then return false end
    if key=="escape" then
        if self.confirm then self.confirm=nil else self:close() end
    elseif self.visible and self.page=="Settings" and (key=="left" or key=="right") then
        app:setVolume(math.max(0,math.min(1,app.volume+(key=="left" and -.05 or .05))))
        app:saveSettings()
        app:sound("menu")
    end
    return true
end

return Menu
