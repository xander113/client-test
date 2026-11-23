local G=love.graphics
local utf8=require("utf8")
local UI={}
UI.__index=UI
UI.colors={
    paper={.984,.988,.980},panel={.945,.959,.939},edge={.828,.864,.828},ink={.10,.155,.12},
    muted={.31,.39,.33},green={9/255,183/255,52/255},active={.871,.947,.872},hover={.91,.938,.906},
    error={.68,.17,.14},
}
local C=UI.colors
local function inside(a,x,y) return x>=a.x and y>=a.y and x<a.x+a.w and y<a.y+a.h end
local function rect(color,x,y,w,h,r)
    G.setColor(color); G.rectangle("fill",x,y,w,h,r or 0,r or 0)
end
local function line(color,x,y,w,h,r)
    G.setColor(color);G.rectangle("line",x+.5,y+.5,w-1,h-1,r or 0,r or 0)
end

function UI.new()
    return setmetatable({font=G.newFont(13),small=G.newFont(11),title=G.newFont(19),
        mono=G.newFont("mono.ttf",13),fields={},regions={},focus=nil},UI)
end
function UI:begin()
    self.regions={}
    G.setFont(self.font)
end
function UI:clearRegions() self.regions={} end
function UI.rect(...) rect(...) end
function UI.line(...) line(...) end

function UI:text(text,x,y,color,font,w)
    text=tostring(text or "")
    G.setFont(font or self.font); G.setColor(color or C.ink)
    if w then G.printf(text,x,y,w) else G.print(text,x,y) end
end
function UI:button(text,x,y,w,h,click,options)
    options=options or {}
    local area={x=x,y=y,w=w,h=h,click=click}
    local mx,my=love.mouse.getPosition()
    local hover=inside(area,mx,my) and click
    local tone=options.primary and C.green or options.selected and C.active or hover and C.hover or options.outline and C.paper
    if tone then rect(tone,x,y,w,h,4) end
    if options.outline or options.selected then line(C.edge,x,y,w,h,4) end
    local color=not click and C.muted or options.danger and C.error or C.ink
    G.setFont(self.font); G.setColor(color)
    G.printf(text,x+4,y+math.floor((h-self.font:getHeight())*.5),w-8,"center")
    if click then self.regions[#self.regions+1]=area end
end

function UI:row(text,x,y,w,h,click,selected)
    local area={x=x,y=y,w=w,h=h,click=click}
    local mx,my=love.mouse.getPosition()
    if selected or (click and inside(area,mx,my)) then rect(selected and C.active or C.hover,x,y,w,h,3) end
    G.setScissor(x,y,w,h)
    self:text(text,x+7,y+math.floor((h-self.font:getHeight())/2))
    G.setScissor()
    if click then self.regions[#self.regions+1]=area end
end

function UI:field(id,value,x,y,w,h,options)
    options=options or {}
    local f=self.fields[id]
    if self.focus~=id or not f then
        f={value=tostring(value or ""),cursor=1,scroll=0}
        f.cursor=#f.value+1
        self.fields[id]=f
    end
    f.options=options
    local selected=self.focus==id
    local multi=options.multi
    local font=multi and self.mono or self.font
    f.font,f.w,f.h=font,w,h
    rect(C.paper,x,y,w,h,3);line(selected and C.green or C.edge,x,y,w,h,3)
    local prefix,suffix=f.value:sub(1,f.cursor-1),f.value:sub(f.cursor)
    local current=prefix:match("([^\n]*)$") or ""
    local cursorX=font:getWidth(current)
    local _,count=prefix:gsub("\n","")
    local height=font:getHeight()+3
    if multi then
        f.scroll=math.max(0,math.min(f.scroll,count*height))
        f.scroll=math.max(f.scroll,(count+1)*height-h+14)
    else f.scroll=math.max(0,cursorX-w+16) end
    local inset=multi and 34 or 6
    G.setScissor(x+3,y+3,w-6,h-6)
    if f.all then rect(C.active,x+3,y+3,w-6,h-6) end
    if multi then
        rect(C.panel,x+3,y+3,24,h-6)
        local index=0
        for text in (f.value.."\n"):gmatch("(.-)\n") do
            self:text(index+1,x+6,y+6+index*height-f.scroll,C.muted,self.small)
            self:text(text,x+inset,y+6+index*height-f.scroll,C.ink,font)
            index=index+1
        end
    else
        self:text(f.value,x+inset-f.scroll,y+math.floor((h-font:getHeight())/2),C.ink,font)
    end
    if selected and not f.all and love.timer.getTime()%1.05<.70 then
        local px=x+inset+cursorX-(multi and 0 or f.scroll)
        local py=multi and y+6+count*height-f.scroll or y+math.floor((h-font:getHeight())/2)
        rect(C.ink,px,py,1,font:getHeight())
    end
    G.setScissor()
    self.regions[#self.regions+1]={x=x,y=y,w=w,h=h,click=function(mx,my)
        if selected then
            local wanted=multi and math.max(0,math.floor((my-y-6+f.scroll)/height)) or 0
            local idx,start=0,1
            while idx<wanted do
                local br=f.value:find("\n",start,true)
                if not br then break end
                start,idx=br+1,idx+1
            end
            local finish=(f.value:find("\n",start,true) or #f.value+1)-1
            local xpos=mx-x-inset+(multi and 0 or f.scroll)
            local pos=start
            while pos<=finish do
                local nextPos=utf8.offset(f.value,2,pos) or finish+1
                if font:getWidth(f.value:sub(start,nextPos-1))>xpos then break end
                pos=nextPos
            end
            f.cursor,f.all=pos,false
        else
            self.focus=id
            f.all=not multi
        end
        love.keyboard.setTextInput(true,x,y,w,h)
    end,field=id}
end

function UI:blur(cancel)
    local id=self.focus
    self.focus=nil
    if not id then return end
    love.keyboard.setTextInput(false)
    local f=self.fields[id]
    if not cancel and f and f.options.commit then f.options.commit(f.value) end
end

function UI:click(x,y)
    for i=#self.regions,1,-1 do
        local region=self.regions[i]
        if inside(region,x,y) then
            if region.field~=self.focus then self:blur(false) end
            region.click(x,y)
            return true
        end
    end
    self:blur(false)
    return false
end

function UI:insert(text)
    local f=self.focus and self.fields[self.focus]
    if not f then return false end
    if not f.options.multi then text=text:gsub("[\r\n]"," ")
    else text=text:gsub("\r\n","\n"):gsub("\r","\n") end
    if not utf8.len(text) then return true end
    local left,right=f.value:sub(1,f.cursor-1),f.value:sub(f.cursor)
    if f.all then left,right="","" end
    if #left+#right+#text<=(f.options.limit or 320) then
        f.value,f.cursor,f.all=left..text..right,#left+#text+1,false
        if f.options.live then f.options.live(f.value) end
    end
    return true
end

function UI:key(key)
    local f=self.focus and self.fields[self.focus]
    if not f then return false end
    local cmd=love.keyboard.isDown("lctrl","rctrl","lgui","rgui")
    if cmd and key=="a" then f.all=true
    elseif cmd and key=="v" then self:insert(love.system.getClipboardText() or "")
    elseif cmd and (key=="c" or key=="x") then
        if f.all then love.system.setClipboardText(f.value); if key=="x" then self:insert("") end end
    elseif key=="escape" then self:blur(true)
    elseif (key=="return" or key=="kpenter") and not f.options.multi then self:blur(false)
    elseif key=="return" or key=="kpenter" then self:insert("\n")
    elseif key=="tab" and f.options.multi then self:insert("    ")
    elseif key=="backspace" or key=="delete" then
        if f.all then self:insert("")
        else
            local a,b=f.cursor,f.cursor
            if key=="backspace" then a=utf8.offset(f.value,-1,a) or a
            elseif b<=#f.value then b=utf8.offset(f.value,2,b) or #f.value+1 end
            f.value=f.value:sub(1,a-1)..f.value:sub(b)
            f.cursor=a
            if f.options.live then f.options.live(f.value) end
        end
    elseif key=="left" or key=="right" then
        f.all=false
        if key=="left" then f.cursor=utf8.offset(f.value,-1,f.cursor) or f.cursor
        elseif f.cursor<=#f.value then f.cursor=utf8.offset(f.value,2,f.cursor) or #f.value+1 end
    elseif key=="home" or key=="end" then
        f.all=false
        if key=="home" then f.cursor=f.cursor-#(f.value:sub(1,f.cursor-1):match("([^\n]*)$") or "")
        else f.cursor=f.value:find("\n",f.cursor,true) or #f.value+1 end
    elseif (key=="up" or key=="down") and f.options.multi then
        f.all=false
        local column=#(f.value:sub(1,f.cursor-1):match("([^\n]*)$") or "")
        local start=f.cursor-column
        if key=="up" and start>1 then
            local p=f.value:sub(1,start-2):match("([^\n]*)$") or ""
            f.cursor=start-1-#p+math.min(#p,column)
        elseif key=="down" then
            local boundary=f.value:find("\n",f.cursor,true)
            if boundary then
                local nextLine=f.value:find("\n",boundary+1,true) or #f.value+1
                f.cursor=math.min(nextLine,boundary+1+column)
            end
        end
        f.cursor=utf8.offset(f.value,0,f.cursor) or f.cursor
    end
    return true
end

function UI:modal(title,w,h)
    local W,H=G.getDimensions()
    self:clearRegions()
    rect({.10,.20,.13,.42},0,0,W,H)
    local x,y=math.floor((W-w)*.5),math.floor((H-h)*.5)
    rect(C.paper,x,y,w,h,6);line(C.edge,x,y,w,h,6)
    self:text(title,x+15,y+11,C.ink,self.title)
    return x,y
end
return UI
