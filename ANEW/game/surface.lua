local UI=require("ui")
local Texture=require("texture")
local Wire=require("wire")
local utf8=require("utf8")
local G=love.graphics
local C=UI.colors
local Surface={}
Surface.__index=Surface

function Surface.new(part,scene,makeID)
    local faces,assets={},Wire.array()
    for _,layer in ipairs(part.textures or {}) do
        faces[layer.face]={face=layer.face,asset=layer.asset,mode=layer.mode,tileU=layer.tileU,tileV=layer.tileV}
    end
    for _,asset in ipairs(scene.textures or {}) do assets[#assets+1]=asset end
    return setmetatable({kind="texture",part=part,faces=faces,assets=assets,face=0,offset=0,path="",makeID=makeID},Surface)
end

function Surface:choose(asset,face)
    face=face or self.face
    local layer=self.faces[face] or {face=face,mode="tile",tileU=4,tileV=4}
    layer.asset=asset
    self.faces[face]=layer
    self.status=nil
end

local function image(bytes)
    local source=love.image.newImageData(love.filesystem.newFileData(bytes,"texture.png"))
    local w,h=source:getDimensions()
    local scale=math.min(1,Texture.maxSize/math.max(w,h))
    local dw,dh=math.max(1,math.floor(w*scale+.5)),math.max(1,math.floor(h*scale+.5))
    local out=love.image.newImageData(dw,dh,"rgba8")
    out:mapPixel(function(x,y)
        return source:getPixel(math.floor((x+.5)*w/dw),math.floor((y+.5)*h/dh))
    end)
    return dw,dh,Wire.bytes(out:getString())
end

function Surface:import(studio,path)
    if self.loading then return end
    if #self.assets>=Texture.maxAssets then self.status="Remove an unused imported texture to make room.";return end
    if path=="" then self.status="Enter a PNG file path or drop a PNG onto Studio.";return end
    self.loading=true
    local face=self.face
    self.status="Importing texture…"
    studio.backend:call("textureFile",{path=path},function(file,err)
        self.loading=false
        if studio.modal~=self then return end
        if not Wire.isBytes(file) then self.status=err or "Studio could not read this image.";return end
        local ok,w,h,pixels=pcall(image,file.data)
        if not ok then self.status="This PNG could not be decoded.";return end
        local name=(path:match("([^/\\]+)$") or ""):gsub("%.[Pp][Nn][Gg]$","")
        if #name>64 or name=="" or not utf8.len(name) or name:find("%c") then name="Imported texture" end
        local asset={id=self.makeID(),name=name,width=w,height=h,pixels=pixels}
        self.assets[#self.assets+1]=asset
        self.path=""
        self:choose(asset.id,face)
        self.offset=math.max(0,#Texture.ids+#self.assets-8)
    end)
end

function Surface:removeAsset(studio,id)
    for _,layer in pairs(self.faces) do
        if layer.asset==id then self.status="Clear the faces that use this image before removing it.";return end
    end
    for _,part in ipairs(studio.scene.objects) do
        if part~=self.part then
            for _,layer in ipairs(part.textures or {}) do
                if layer.asset==id then self.status="Another part uses this image.";return end
            end
        end
    end
    for i,asset in ipairs(self.assets) do
        if asset.id==id then table.remove(self.assets,i);self.status=nil;return end
    end
end

function Surface:apply(studio)
    local layers=Wire.array()
    for face=0,#Texture.faces-1 do
        if self.faces[face] then layers[#layers+1]=self.faces[face] end
    end
    self.part.textures=#layers>0 and layers or nil
    studio.scene.textures=self.assets
    studio.modal=nil
    studio:checkpoint()
    studio.status="Updated textures on "..self.part.name
end

function Surface:draw(studio)
    local ui=studio.ui
    local w,h=660,528
    local x,y=ui:modal("Textures · "..self.part.name,w,h)
    local column=(w-36)/#Texture.faces
    for i,label in ipairs(Texture.faces) do
        local face=i-1
        ui:button(label,x+16+face*column,y+51,column-3,31,function()self.face=face;self.status=nil end,
            {selected=self.face==face,outline=self.faces[face]~=nil})
    end
    local layer=self.faces[self.face]
    local selection=layer and layer.asset
    local entries={}
    for _,id in ipairs(Texture.ids) do entries[#entries+1]=Texture.asset(studio.scene,id) end
    for _,asset in ipairs(self.assets) do entries[#entries+1]=asset end
    self.offset=math.max(0,math.min(self.offset,#entries-8))
    local offset=math.floor(self.offset)
    ui.rect(C.panel,x+15,y+101,214,243,4)
    for i=1,8 do
        local asset=entries[i+offset]
        if not asset then break end
        local row=y+105+(i-1)*29
        ui:row("     "..asset.name,x+19,row,205,27,function()self:choose(asset.id)end,selection==asset.id)
        local img=studio.view:textureImage(asset.id,asset)
        G.setColor(1,1,1)
        G.draw(img,x+25,row+5,0,17/img:getWidth(),17/img:getHeight())
    end
    if #entries>8 then
        ui:button("Scroll up",x+15,y+351,97,24,offset>0 and function()self.offset=math.max(0,self.offset-4)end or nil,{outline=true})
        ui:button("Scroll down",x+120,y+351,109,24,offset<#entries-8 and function()self.offset=math.min(#entries-8,self.offset+4)end or nil,{outline=true})
    end
    local px,py,pw,ph=x+248,y+101,396,140
    ui.rect({.91,.93,.91},px,py,pw,ph,4)
    if layer then
        local asset=Texture.asset({textures=self.assets},selection)
        local preview=studio.view:textureImage(selection,asset)
        local scale=math.min((pw-12)/preview:getWidth(),(ph-12)/preview:getHeight())
        G.setColor(1,1,1)
        G.draw(preview,px+(pw-preview:getWidth()*scale)*.5,py+(ph-preview:getHeight()*scale)*.5,0,scale)
        ui:button("Tile",px,y+252,96,29,function()layer.mode="tile"end,{selected=layer.mode=="tile",outline=true})
        ui:button("Fit once",px+104,y+252,98,29,function()layer.mode="fit"end,{selected=layer.mode=="fit",outline=true})
        ui:button("Clear face",px+291,y+252,105,29,function()self.faces[self.face]=nil end,{outline=true})
        if layer.mode=="tile" then
            for i,key in ipairs({"tileU","tileV"}) do
                local xx=px+(i-1)*111
                ui:text(i==1 and "Studs per tile U" or "Studs per tile V",xx,y+295,C.muted,ui.small)
                ui:field("texture-"..key,tostring(layer[key]),xx,y+310,101,26,{commit=function(text)
                    local number=tonumber(text)
                    if number and number==number then layer[key]=math.max(.25,math.min(128,number)) end
                end})
            end
        end
    else ui:text("Choose a texture for this face.",px+14,py+12,C.muted,ui.font,pw-28) end
    if #self.assets>0 then
        ui:button("Remove image…",px+240,y+351,156,24,not self.loading and function()
            studio.modal={kind="textureRemove",editor=self,offset=0}
        end or nil,{outline=true})
    end
    ui:text("Import a PNG from disk",x+15,y+388,C.ink)
    ui:field("texture-path",self.path,x+15,y+410,w-136,29,{limit=4096,live=function(v) self.path=v end})
    if self.path=="" and ui.focus~="texture-path" then ui:text("PNG file path or drop an image here",x+22,y+417,C.muted) end
    ui:button("Import",x+w-112,y+410,97,29,not self.loading and function()self:import(studio,self.path)end or nil,{outline=true})
    if self.status then ui:text(self.status,x+16,y+448,C.muted,ui.small,w-30) end
    ui:button("Cancel",x+15,y+h-41,87,30,function()studio.modal=nil;studio:refresh() end,{outline=true})
    ui:button("Apply textures",x+w-139,y+h-41,124,30,not self.loading and function()self:apply(studio)end or nil,{primary=true})
end

function Surface.removeDialog(studio,m)
    local ui=studio.ui
    local x,y=ui:modal("Remove an unused texture",420,388)
    local editor=m.editor
    local max=math.max(0,#editor.assets-10)
    m.offset=math.max(0,math.min(m.offset,max))
    for i=1,10 do
        local asset=editor.assets[math.floor(m.offset)+i]
        if not asset then break end
        ui:row(asset.name,x+13,y+51+(i-1)*27,394,26,function()
            editor:removeAsset(studio,asset.id)
            studio.modal=editor
        end)
    end
    if max>0 then
        ui:button("Up",x+15,y+347,40,28,function()m.offset=math.max(0,m.offset-4)end,{outline=true})
        ui:button("Down",x+61,y+347,57,28,function()m.offset=math.min(max,m.offset+4)end,{outline=true})
    end
    ui:button("Back",x+323,y+347,80,28,function()studio.modal=editor end,{outline=true})
end

return Surface
