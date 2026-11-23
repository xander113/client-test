local G=love.graphics
local Mesh=require("geometry")
local View={}
View.__index=View
local pi=math.pi
local axisColors={{.84,.22,.20},{.07,.62,.23},{.16,.43,.82}}
local clamp=function(v,a,b)return math.min(b,math.max(a,v))end
local len=function(a,b)return math.sqrt(a*a+b*b)end
local boxEdges={{1,2},{1,3},{1,5},{2,4},{2,6},{3,4},{3,7},{4,8},{5,6},{5,7},{6,8},{7,8}}
local axisNames={"X","Y","Z"}
local function add(a,b,scale) return {a[1]+b[1]*scale,a[2]+b[2]*scale,a[3]+b[3]*scale} end
local function sub(a,b)return{a[1]-b[1],a[2]-b[2],a[3]-b[3]}end
local function plain(v)return unpack(v)end
local function lerp(a,b,t)return a+(b-a)*t end
local function snap(v,n) return n and math.floor(v/n+.5)*n or v end
local function wrap(n)return (n+180)%360-180 end
local function basis(r)
    local x,y,z=math.rad(r[1]),math.rad(r[2]),math.rad(r[3])
    local a,b,c,d,e,f=math.cos(x),math.sin(x),math.cos(y),math.sin(y),math.cos(z),math.sin(z)
    return {{c*e,a*f+b*e*d,b*f-a*e*d},{-c*f,a*e-b*f*d,b*e+a*f*d},{d,-b*c,a*c}}
end
local function rotationFromBasis(r)
    local y=math.asin(clamp(r[3][1],-1,1))
    local x,z
    if math.abs(r[3][1])<.99999 then
        x,z=math.atan2(-r[3][2],r[3][3]),math.atan2(-r[2][1],r[1][1])
    else x,z=math.atan2(r[2][3],r[2][2]),0 end
    return {math.deg(x),math.deg(y),math.deg(z)}
end
local function rotated(rotation,axis,angle,localAxes)
    local original=basis(rotation)
    local delta={0,0,0}; delta[axis]=angle
    local turn=basis(delta)
    if localAxes then original,turn=turn,original end
    return rotationFromBasis({Mesh.rotate(turn,plain(original[1])),Mesh.rotate(turn,plain(original[2])),Mesh.rotate(turn,plain(original[3]))})
end

local vertexShader=[[
uniform vec3 eye;
uniform vec3 eyeRight;
uniform vec3 eyeUp;
uniform vec3 eyeForward;
uniform vec2 lens;
uniform vec3 offset;
uniform vec3 axisU;
uniform vec3 axisV;
uniform vec3 axisW;
uniform vec3 dimensions;
attribute vec3 VertexNormal;
varying vec3 surfaceNormal;
varying float distanceFromCamera;

vec4 position(mat4 matrix, vec4 position) {
    vec3 p = position.xyz * dimensions;
    vec3 location = offset + axisU*p.x + axisV*p.y + axisW*p.z - eye;
    vec3 n = VertexNormal / dimensions;
    surfaceNormal = axisU*n.x + axisV*n.y + axisW*n.z;
    float z = dot(location, eyeForward);
    distanceFromCamera = z;
    return vec4(dot(location,eyeRight)*lens.x, -dot(location,eyeUp)*lens.y, z*1.0005-.18, z);
}
]]
local pixelShader=[[
varying vec3 surfaceNormal;
varying float distanceFromCamera;
uniform float shine;
vec4 effect(vec4 color, Image sampleImage, vec2 uv, vec2 screen) {
    vec3 n=normalize(surfaceNormal);
    float l=0.64+0.40*max(0.0,dot(n,normalize(vec3(-.42,.86,.55))));
    vec3 lit=mix(color.rgb*l, min(color.rgb*1.28+vec3(.1),vec3(1)),shine);
    return vec4(mix(lit,vec3(.84,.92,.97),clamp((distanceFromCamera-45.0)/360.0,0.0,.7)),1.0);
}
]]

local function graphics()
    local shader=G.newShader(pixelShader,vertexShader)
    local meshes={}
    for _,kind in ipairs({"box","sphere","cylinder"}) do
        local vertices={}
        for _,triangle in ipairs(Mesh[kind]) do
            for i=1,3 do vertices[#vertices+1]=triangle[i] end
        end
        meshes[kind]=G.newMesh({{"VertexPosition","float",3},{"VertexNormal","float",3}},vertices,"triangles","static")
    end
    return shader,meshes
end

function View.new(change,select,press)
    local shader,models=graphics()
    return setmetatable({shader=shader,models=models,objects={},parts={},actors={},effects={},
        yaw=.72,pitch=.48,distance=45,target={0,0,0},goal=nil,tool="select",snap=.5,angle=15,
        playing=false,interaction=nil,change=change,select=select,press=press,
        renderScale=1,maxCanvas=G.getSystemLimits().texturesize},View)
end

function View:set(scene)
    self.scene=scene
    self.objects=scene.objects
    self.parts={}
    for _,object in ipairs(scene.objects) do self.parts[object.id]=object end
end

function View:frame(id,orientation,instant)
    local object=self.parts[id]
    local min,max={250,250,250},{-250,-40,-250}
    if object then
        for i=1,3 do min[i]=object.position[i]-object.size[i]/2; max[i]=object.position[i]+object.size[i]/2 end
    else
        for _,o in ipairs(self.objects) do
            for i=1,3 do min[i]=math.min(min[i],o.position[i]-o.size[i]/2); max[i]=math.max(max[i],o.position[i]+o.size[i]/2) end
        end
        if #self.objects==0 then min,max={-4,-2,-4},{4,2,4} end
    end
    local point,rad={},0
    for i=1,3 do point[i]=(min[i]+max[i])/2; rad=rad+(max[i]-min[i])^2 end
    local distance=math.max(4, math.sqrt(rad)*1.10)
    if orientation=="top" then self.yaw,self.pitch=0,pi/2-.018
    elseif orientation=="front" then self.yaw,self.pitch=0,.02
    elseif orientation=="right" then self.yaw,self.pitch=pi/2,.02
    elseif orientation=="perspective" then self.yaw,self.pitch=.72,.48 end
    if instant then self.target,self.distance=point,distance else self.goal={point,distance} end
end

function View:play(on)
    if self.playing==on then return end
    self.goal=nil
    if on then
        self.editor={self.yaw,self.pitch,self.distance,self.target}
        self.yaw,self.pitch,self.distance=0,.34,6.5
        self.actors,self.effects={},{}
        self.localID,self.interaction,self.allowReset=nil,nil,nil
    elseif self.editor then
        self.yaw,self.pitch,self.distance,self.target=unpack(self.editor)
        self.actors,self.effects={},{}
        self.interaction=nil
    end
    self.playing=on
    self.drag=nil
end

function View:state(event)
    if event.type=="welcome" then self.localID,self.allowReset=event.id,event.allowReset; return end
    if event.type~="state" then return end
    local seen,overrides={},{}
    for _,fx in ipairs(event.effects or {}) do overrides[fx.id]=fx end
    self.effects=overrides
    for _,p in ipairs(event.players) do
        seen[p.id]=true
        local a=self.actors[p.id]
        if not a or a.life~=p.life then
            a={at={p.x,p.y,p.z},yaw=p.yaw,phase=0,swing=0,life=p.life}
            self.actors[p.id]=a
            if p.life and p.id==self.localID then self.yaw=p.yaw end
        end
        a.goal,a.heading,a.color,a.name={p.x,p.y,p.z},p.yaw,p.color,p.name
        if p.id==self.localID then self.interaction=p.interaction end
    end
    for id in pairs(self.actors) do if not seen[id] then self.actors[id]=nil end end
end

function View:camera(x,y,w,h)
    self.x,self.y,self.w,self.h=x,y,w,h
    local target=self.target
    local actor=self.actors[self.localID]
    if self.playing then
        if actor then target={actor.at[1],actor.at[2]+1.04,actor.at[3]}
        elseif self.scene then
            local spawn=self.scene.spawn
            target={spawn.x,spawn.y+1.04,spawn.z}
        end
    end
    local angle,pitch=self.yaw,self.pitch
    local offset={math.sin(angle)*math.cos(pitch),math.sin(pitch),math.cos(angle)*math.cos(pitch)}
    self.eye=add(target,offset,self.distance)
    self.forward={-offset[1],-offset[2],-offset[3]}
    self.right=Mesh.unit(Mesh.cross(self.forward,{0,1,0}))
    self.up=Mesh.cross(self.right,self.forward)
    self.lensY=self.playing and 1.86 or 2.4
    self.lensX=self.lensY*h/w
end

function View:project(point)
    local difference=sub(point,self.eye)
    local depth=Mesh.dot(difference,self.forward)
    if depth<.09 then return nil end
    return self.x+self.w*.5*(1+Mesh.dot(difference,self.right)*self.lensX/depth),
        self.y+self.h*.5*(1-Mesh.dot(difference,self.up)*self.lensY/depth),depth
end

function View:mesh(kind,at,size,rgb,rotation,shine)
    local shader=self.shader
    shader:send("offset",at)
    shader:send("dimensions",size)
    shader:send("axisU",rotation[1])
    shader:send("axisV",rotation[2])
    shader:send("axisW",rotation[3])
    shader:send("shine",shine or 0)
    G.setColor(plain(rgb))
    G.draw(self.models[kind])
end

function View:avatar(a)
    local heading=basis({0,math.deg(a.yaw),0})
    local function block(at,size,color,pitch)
        local rotation=heading
        if pitch then
            local turn=basis({pitch,0,0})
            at=add(at,turn[2],-size[2]*.5)
            rotation={heading[1],Mesh.rotate(heading,plain(turn[2])),Mesh.rotate(heading,plain(turn[3]))}
        end
        self:mesh("box",add(a.at,Mesh.rotate(heading,plain(at)),1),size,color,rotation,0)
    end
    local swatch={Mesh.rgb(a.color)}
    local jacket={swatch[1]*.84+.06,swatch[2]*.84+.08,swatch[3]*.84+.07}
    local sleeve={jacket[1]*.70+.12,jacket[2]*.70+.12,jacket[3]*.70+.13}
    local trousers={.17,.24,.24}
    local swing=math.sin(a.phase)*a.swing
    block({0,.903,0},{.594,.598,.315},jacket)
    block({0,1.412,0},{.461,.414,.424},{.86,.82,.72})
    block({-.436,1.189,0},{.252,.597,.30},sleeve,swing)
    block({.436,1.189,0},{.252,.597,.30},sleeve,-swing)
    block({-.150,.604,0},{.284,.604,.312},trousers,-swing)
    block({.150,.604,0},{.284,.604,.312},trousers,swing)
    block({0,1.442,-.217},{.342,.107,.016},{.14,.25,.24})
    block({.134,1.026,-.163},{.094,.045,.015},{.92,.97,.84})
end

function View:axes(object)
    if self.tool=="scale" or self.localAxes then return basis(object.rotation) end
    return {{1,0,0},{0,1,0},{0,0,1}}
end

function View:handles(object)
    local x,y,z=self:project(object.position)
    if not x then return {} end
    local unit=z*.19
    local axes=self:axes(object)
    local handles={}
    for i=1,3 do
        local handle={axis=i,x=x,y=y,unit=unit,basis=axes}
        if self.tool=="rotate" then
            handle.points={}
            for n=0,48 do
                local angle=n/48*2*pi
                local point=add(add(object.position,axes[i%3+1],math.cos(angle)*unit),axes[(i+1)%3+1],math.sin(angle)*unit)
                local px,py=self:project(point)
                if px then handle.points[#handle.points+1]=px; handle.points[#handle.points+1]=py end
            end
        else
            handle.ex,handle.ey=self:project(add(object.position,axes[i],unit))
        end
        handles[#handles+1]=handle
    end
    return handles
end

function View:outline(object)
    local corners={}
    local o=basis(object.rotation)
    for i=0,7 do
        local x=(i%2-.5)*object.size[1]
        local y=(math.floor(i/2)%2-.5)*object.size[2]
        local z=(math.floor(i/4)%2-.5)*object.size[3]
        corners[i+1]={self:project(add(object.position,Mesh.rotate(o,x,y,z),1))}
    end
    G.setLineWidth(1.5); G.setColor(.035,.5,.18,.94)
    for _,edge in ipairs(boxEdges) do
        local a,b=corners[edge[1]],corners[edge[2]]
        if a[1] and b[1] then G.line(a[1],a[2],b[1],b[2]) end
    end
    if self.tool=="select" then return end
    G.setLineWidth(2)
    for _,handle in ipairs(self:handles(object)) do
        G.setColor(axisColors[handle.axis])
        if handle.points and #handle.points>4 then G.line(handle.points)
        elseif handle.ex then
            G.line(handle.x,handle.y,handle.ex,handle.ey)
            if self.tool=="scale" then G.rectangle("fill",handle.ex-4,handle.ey-4,8,8)
            else G.circle("fill",handle.ex,handle.ey,4.5) end
            G.print(axisNames[handle.axis],handle.ex+5,handle.ey-8)
        end
    end
end

function View:draw(x,y,w,h)
    if w<10 or h<10 then return end
    self:camera(x,y,w,h)
    w,h=math.floor(w),math.floor(h)
    local scale=math.min(self.renderScale,self.maxCanvas/w,self.maxCanvas/h)
    local pixelW,pixelH=math.floor(w*scale),math.floor(h*scale)
    if not self.canvas or self.canvas:getWidth()~=pixelW or self.canvas:getHeight()~=pixelH then
        if self.canvas then self.canvas:release() end
        self.canvas=G.newCanvas(pixelW,pixelH,{dpiscale=1})
    end
    G.setCanvas({self.canvas,depth=true})
    G.clear(.84,.92,.97,1,true,true)
    G.setDepthMode("less",true)
    G.setShader(self.shader)
    self.shader:send("eye",self.eye)
    self.shader:send("eyeRight",self.right)
    self.shader:send("eyeUp",self.up)
    self.shader:send("eyeForward",self.forward)
    self.shader:send("lens",{self.lensX,self.lensY})
    for _,o in ipairs(self.objects) do
        local fx=self.effects[o.id]
        if not fx or fx.visible then
            local color=fx and (fx.pulse or fx.color) or o.color
            local pulse=fx and fx.pulse and .52+math.sin(love.timer.getTime()*8)*.38 or 0
            if o.kind=="spawn" and not self.playing then
                color=o.enabled and "#64ba80" or "#88938b"
                pulse=.16
            end
            self:mesh(o.kind=="spawn" and "box" or o.kind,o.position,o.size,{Mesh.rgb(color)},basis(o.rotation),pulse)
        end
    end
    for _,a in pairs(self.actors) do if self.playing then self:avatar(a) end end
    G.setShader()
    G.setDepthMode()
    G.setCanvas()
    G.setColor(1,1,1); G.draw(self.canvas,x,y,0,w/pixelW,h/pixelH)
    G.setScissor(x,y,w,h)
    local object=not self.playing and self.selected and self.parts[self.selected]
    if object then self:outline(object) end
    if self.playing then
        for id,actor in pairs(self.actors) do
            if id~=self.localID then
                local ax,ay,depth=self:project({actor.at[1],actor.at[2]+1.88,actor.at[3]})
                if ax and depth<34 then
                    local font=G.getFont()
                    local width=font:getWidth(actor.name)+14
                    G.setColor(.09,.17,.14,.83); G.rectangle("fill",ax-width/2,ay-17,width,18,3)
                    G.setColor(1,1,1); G.print(actor.name,ax-width/2+7,ay-16)
                end
            end
        end
    end
    G.setScissor()
end

function View:update(dt)
    local t=1-math.exp(-dt*18)
    for _,a in pairs(self.actors) do
        local x,z=a.at[1],a.at[3]
        for i=1,3 do a.at[i]=lerp(a.at[i],a.goal[i],t) end
        local speed=len(a.at[1]-x,a.at[3]-z)/math.max(dt,.001)
        a.yaw=a.yaw+((a.heading-a.yaw+pi)%(2*pi)-pi)*t
        a.phase=a.phase+dt*10
        a.swing=lerp(a.swing,clamp(speed*6,0,34),t)
    end
    if self.goal then
        self.distance=lerp(self.distance,self.goal[2],t)
        for i=1,3 do self.target[i]=lerp(self.target[i],self.goal[1][i],t) end
    end
    if self.drag and self.drag.button==2 and not self.playing and self.forward then
        local key=love.keyboard.isDown
        local speed=dt*13
        self.target=add(self.target,self.forward,(key("w") and speed or 0)-(key("s") and speed or 0))
        self.target=add(self.target,self.right,(key("d") and speed or 0)-(key("a") and speed or 0))
        self.target[2]=self.target[2]+(key("e") and speed or 0)-(key("q") and speed or 0)
    end
end

function View:area(x,y)
    return self.w and x>=self.x and y>=self.y and x<self.x+self.w and y<self.y+self.h
end

local function segment(x,y,a,b,c,d)
    local u,v=c-a,d-b
    local t=clamp(((x-a)*u+(y-b)*v)/math.max(.0001,u*u+v*v),0,1)
    return len(x-a-u*t,y-b-v*t)
end

function View:pick(x,y)
    local direction=add(add(self.forward,self.right,((x-self.x)/self.w*2-1)/self.lensX),self.up,(1-(y-self.y)/self.h*2)/self.lensY)
    local closest,hit=math.huge,nil
    for _,o in ipairs(self.objects) do
        local fx=self.effects[o.id]
        if not fx or fx.visible then
            local axes=basis(o.rotation)
            local from=sub(self.eye,o.position)
            local lo,hi=0,closest
            for i=1,3 do
                local origin,step=Mesh.dot(from,axes[i]),Mesh.dot(direction,axes[i])
                local half=o.size[i]/2
                if math.abs(step)<1e-6 then
                    if math.abs(origin)>half then hi=-1; break end
                else
                    local a,b=(-half-origin)/step,(half-origin)/step
                    lo=math.max(lo,math.min(a,b)); hi=math.min(hi,math.max(a,b))
                end
            end
            if hi>=lo then closest,hit=lo,o.id end
        end
    end
    return hit
end

function View:mousepressed(x,y,button)
    if not self:area(x,y) then return false end
    self.goal=nil
    local d={x=x,y=y,button=button,moved=false}
    self.drag=d
    local object=self.selected and self.parts[self.selected]
    if self.playing or button~=1 or not object or self.tool=="select" then return true end
    local best,chosen=8,nil
    for _,h in ipairs(self:handles(object)) do
        local distance=math.huge
        if h.points then
            for i=1,#h.points-2,2 do distance=math.min(distance,segment(x,y,h.points[i],h.points[i+1],h.points[i+2],h.points[i+3])) end
        elseif h.ex then
            distance=segment(x,y,h.x+(h.ex-h.x)*.34,h.y+(h.ey-h.y)*.34,h.ex,h.ey)
        end
        if distance<best then best,chosen=distance,h end
    end
    if chosen then
        d.handle=chosen
        d.object=object
        d.original={position={plain(object.position)},size={plain(object.size)},rotation={plain(object.rotation)}}
    end
    return true
end

function View:mousemoved(x,y,dx,dy)
    local d=self.drag
    if not d then return end
    if len(x-d.x,y-d.y)>3 then d.moved=true end
    local h=d.handle
    if h and d.moved then
        if self.tool=="rotate" then
            local amount=math.deg(math.atan2(y-h.y,x-h.x)-math.atan2(d.y-h.y,d.x-h.x))
            d.object.rotation=rotated(d.original.rotation,h.axis,snap(wrap(amount),self.angle),self.localAxes)
        else
            local u,v=h.ex-h.x,h.ey-h.y
            local units=((x-d.x)*u+(y-d.y)*v)*h.unit/math.max(.001,u*u+v*v)
            if self.tool=="translate" then
                local offset=add(d.original.position,h.basis[h.axis],snap(units,self.snap))
                d.object.position={clamp(offset[1],-250,250),clamp(offset[2],-40,250),clamp(offset[3],-250,250)}
            else
                local size={plain(d.original.size)}
                size[h.axis]=clamp(snap(size[h.axis]+units*2,self.snap),.1,128)
                d.object.size=size
            end
        end
    elseif d.button==3 and not self.playing and self.right then
        self.target=add(add(self.target,self.right,-dx*self.distance*.0018),self.up,dy*self.distance*.0018)
    elseif d.moved and (d.button==1 or d.button==2) then
        self.yaw=self.yaw-dx*.007
        self.pitch=clamp(self.pitch+dy*.006,-1.50,1.54)
    end
end

function View:mousereleased(x,y)
    local d=self.drag
    self.drag=nil
    if not d then return end
    if d.handle then
        if d.moved and self.change then self.change(d.object,d.original) end
    elseif not d.moved and d.button==1 then
        local hit=self:pick(x,y)
        if self.playing then
            if hit and hit==self.interaction and self.press then self.press(hit) end
        elseif self.select then self.select(hit) end
    end
end

function View:cancel()
    local d=self.drag
    self.drag=nil
    if d and d.handle then
        for k,v in pairs(d.original) do d.object[k]=v end
        return true
    end
end

function View:wheel(n)
    self.goal=nil
    self.distance=clamp(self.distance*math.exp(-n*.10),self.playing and 2 or 2.6,self.playing and 14 or 380)
end

return View
