-- Original primitive meshes shared by the native viewport and the thumbnail renderer.
local M={}
local function v(x,y,z, nx,ny,nz) return {x,y,z,nx,ny,nz} end
local function quad(t,a,b,c,d)
    t[#t+1]={a,b,c}; t[#t+1]={a,c,d}
end
local function box()
    local t={}
    for i=1,3 do
        for _,face in ipairs({-1,1}) do
            local vertices={}
            for j,p in ipairs({{-.5,-.5},{.5,-.5},{.5,.5},{-.5,.5}}) do
                local q={0,0,0,0,0,0}
                q[i],q[i+3]=face*.5,face
                q[i%3+1],q[(i+1)%3+1]=p[1],p[2]
                vertices[j]=q
            end
            quad(t,vertices[1],vertices[2],vertices[3],vertices[4])
        end
    end
    return t
end
local function sphere(n,m)
    local t,rows={},{}
    for y=0,m do
        local row={}
        rows[y]=row
        local phi=(y/m-.5)*math.pi
        for x=0,n-1 do
            local theta=2*math.pi*x/n
            local nx,ny,nz=math.cos(theta)*math.cos(phi),math.sin(phi),math.sin(theta)*math.cos(phi)
            row[x]=v(nx*.5,ny*.5,nz*.5,nx,ny,nz)
            if y>0 and x>0 then quad(t,rows[y-1][x-1],rows[y-1][x],row[x],row[x-1]) end
        end
        if y>0 then quad(t,rows[y-1][n-1],rows[y-1][0],row[0],row[n-1]) end
    end
    return t
end
local function cylinder(n)
    local t={}
    for i=0,n-1 do
        local a,b=2*math.pi*i/n,2*math.pi*(i+1)/n
        local x,z,X,Z=math.cos(a),math.sin(a),math.cos(b),math.sin(b)
        quad(t,v(x*.5,-.5,z*.5,x,0,z),v(X*.5,-.5,Z*.5,X,0,Z),v(X*.5,.5,Z*.5,X,0,Z),v(x*.5,.5,z*.5,x,0,z))
        for _,y in ipairs({-.5,.5}) do
            t[#t+1]={v(0,y,0,0,y*2,0),v(x*.5,y,z*.5,0,y*2,0),v(X*.5,y,Z*.5,0,y*2,0)}
        end
    end
    return t
end
M.box,M.sphere,M.cylinder=box(),sphere(16,10),cylinder(20)
function M.dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
function M.cross(a,b) return {a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]} end
function M.unit(a)
    local d=math.sqrt(M.dot(a,a))
    return {a[1]/d,a[2]/d,a[3]/d}
end
function M.rotate(r,x,y,z)
    return {r[1][1]*x+r[2][1]*y+r[3][1]*z,r[1][2]*x+r[2][2]*y+r[3][2]*z,r[1][3]*x+r[2][3]*y+r[3][3]*z}
end
function M.rgb(hex)
    local n=tonumber(hex:sub(2),16)
    return math.floor(n/65536)/255,math.floor(n/256)%256/255,n%256/255
end
return M
