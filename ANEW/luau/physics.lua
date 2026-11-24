local Physics={
    walkSpeed=16,jumpHeight=7.2,gravity=196.2,maxSpeed=64,maxJump=32,
    radius=.30,height=1.65,stepHeight=.45,
}

local function axisData(rotation,half)
    local horizontal=math.sqrt(math.max(0,1-rotation[2]^2))
    local extent=half+Physics.radius*horizontal
    return {rotation[1]/extent,rotation[2]/extent,rotation[3]/extent}
end

function Physics.collider(part,rotation,lo,hi)
    return {
        lo=lo,hi=hi,position=part.position,kind=part.kind,
        x=axisData(rotation[1],part.size[1]*.5),
        y=axisData(rotation[2],part.size[2]*.5),
        z=axisData(rotation[3],part.size[3]*.5),
    }
end

local function slab(low,high,o,d)
    if math.abs(d)<1e-8 then
        if math.abs(o)>1 then return nil end
        return low,high
    end
    local a,b=(-1-o)/d,(1-o)/d
    low,high=math.max(low,math.min(a,b)),math.min(high,math.max(a,b))
    if low<=high then return low,high end
end

local function radial(low,high,a,b,c)
    if a<1e-12 then
        if c<=0 then return low,high end
        return nil
    end
    local k=b*b-a*c
    if k<0 then return nil end
    local root=math.sqrt(k)
    low,high=math.max(low,(-b-root)/a),math.min(high,(-b+root)/a)
    if low<=high then return low,high end
end

-- Intersect an upright character's footprint with the rotated primitive along its vertical slice.
function Physics.span(b,x,z)
    local radius=Physics.radius
    if x<=b.lo[1]-radius or x>=b.hi[1]+radius or z<=b.lo[3]-radius or z>=b.hi[3]+radius then return nil end
    local position=b.position
    local wx,wz=x-position[1],z-position[3]
    local X,Y,Z=b.x,b.y,b.z
    local ox,oy,oz=wx*X[1]+wz*X[3],wx*Y[1]+wz*Y[3],wx*Z[1]+wz*Z[3]
    local dx,dy,dz=X[2],Y[2],Z[2]
    local low,high=b.lo[2]-position[2]-radius,b.hi[2]-position[2]+radius
    if b.kind=="sphere" then
        low,high=radial(low,high,dx*dx+dy*dy+dz*dz,ox*dx+oy*dy+oz*dz,ox*ox+oy*oy+oz*oz-1)
    else
        low,high=slab(low,high,oy,dy)
        if low and b.kind=="cylinder" then
            low,high=radial(low,high,dx*dx+dz*dz,ox*dx+oz*dz,ox*ox+oz*oz-1)
        elseif low then
            low,high=slab(low,high,ox,dx)
            if low then low,high=slab(low,high,oz,dz) end
        end
    end
    if low then return low+position[2],high+position[2] end
end

return Physics
