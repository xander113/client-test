local net=require("@lune/net")
local task=require("@lune/task")
local Wire=require("./wire")
local Place=require("./place")
local Room=require("./room")
local Store=require("./store")
local Thumbnail=require("./thumbnail")
local Network={}

local function endpoint(raw)
    local scheme,host,path=raw:match("^(https?)://([^/%s]+)([^%s]*)$")
    assert(scheme and not (host:find("[@?#]") or path:find("[?#]")), "Invalid Pot endpoint.")
    local address=host:match("^(.-):%d+$") or host
    assert(scheme=="https" or address=="127.0.0.1" or address=="localhost" or address=="[::1]",
        "Hosted Pot endpoints require HTTPS.")
    return (scheme.."://"..host..path):gsub("/+$","")
end

function Network.within(seconds,fn)
    local thread=coroutine.running()
    local done=false
    local worker=task.defer(function()
        local ok,value=pcall(fn)
        if not done then done=true; task.defer(thread,ok,value) end
    end)
    local timer=task.delay(seconds,function()
        if not done then
            done=true
            pcall(task.cancel,worker)
            task.defer(thread,false,"The Pot service timed out.")
        end
    end)
    local ok,value=coroutine.yield()
    pcall(task.cancel,timer)
    if not ok then error(value,0) end
    return value
end

local function equal(a,b)
    if type(a)~="string" or type(b)~="string" or #a~=#b or #a>512 or #b==0 then return false end
    local difference=0
    for i=1,#a do difference=bit32.bor(difference,bit32.bxor(a:byte(i),b:byte(i))) end
    return difference==0
end

local function credential(request)
    return (request.headers.authorization or request.headers.Authorization or ""):match("^Bearer (%S+)$")
end
local function reply(code,value,media)
    return {status=code,headers={["Content-Type"]=media or Wire.mime,["Cache-Control"]="no-store",
        ["X-Content-Type-Options"]="nosniff"},body=if media then value else Wire.encode(value)}
end
local function fail(code,message) return reply(code,{message=message}) end
local function close(socket,code) pcall(function() socket:close(code or 1000) end) end

local function request(url,verb,token,data,media,max)
    local headers={}
    if token and token~="" then headers.Authorization="Bearer "..token end
    if data then headers["Content-Type"]=Wire.mime end
    local res=Network.within(8,function()
        return net.request({url=url,method=verb,headers=headers,body=data})
    end)
    if res.statusCode==401 or res.statusCode==403 then error("Publishing or library access is required.",0) end
    assert(res.ok,"The Pot service returned status "..res.statusCode..".")
    local kind=res.headers["content-type"] or res.headers["Content-Type"]
    if type(kind)=="table" then kind=kind[1] end
    assert(type(kind)=="string" and kind:match("^[^;]+")==media,"Unexpected Pot service response.")
    assert(#res.body<=max,"The Pot service response is too large.")
    if media=="image/png" then
        assert(res.body:sub(1,8)=="\137PNG\13\10\26\10","The service did not return a PNG.")
        return res.body
    end
    return Wire.decode(res.body,max)
end

function Network.remote(url,read,write)
    local base=endpoint(url)
    local function action(verb,path,key,body,media)
        return request(base..path,verb,key,body,media or Wire.mime,media and 1024*1024 or Place.limit)
    end
    local function check(id)
        assert(Place.id(id),"Invalid world ID.")
        return id
    end
    local function token()
        assert(write and write~="","Set a Studio publishing credential for this endpoint.")
        return write
    end
    local function list(key,path)
        local items=action("GET",path,key)
        assert(type(items)=="table" and #items<=128,"Invalid catalog.")
        for _,item in ipairs(items) do
            assert(Place.id(item.id) and type(item.name)=="string" and #item.name<=320
                and type(item.description)=="string" and #item.description<=1600,"Invalid catalog entry.")
        end
        return items
    end
    return {
        list=function() return list(read,"/v3/worlds") end,
        load=function(id)
            local value=Place.validate(action("GET","/v3/worlds/"..check(id),read))
            assert(value.id==id,"The service returned a different world.")
            return value
        end,
        spawns=function(id) return action("GET","/v3/worlds/"..check(id).."/spawns",read) end,
        preview=function(id) return action("GET","/v3/worlds/"..check(id).."/thumbnail",read,nil,"image/png") end,
        managed=function() return list(token(),"/v3/published") end,
        published=function(id)
            local value=Place.validate(action("GET","/v3/published/"..check(id),token()))
            assert(value.id==id,"The service returned a different world.")
            return value
        end,
        publish=function(p)
            local clean,data=Place.wire(p)
            Place.programs(clean)
            return action("PUT","/v3/worlds/"..clean.id,token(),data)
        end,
        remove=function(id) return action("DELETE","/v3/worlds/"..check(id),token()) end,
        join=function(id)
            check(id)
            local ws=Network.within(6,function() return net.socket(base:gsub("^http","ws").."/v3/session") end)
            local ok,welcome=pcall(function()
                ws:send(Wire.encode({type="join",world=id,credential=read or ""}),true)
                local e=Wire.decode(Network.within(6,function() return ws:next() end),2048)
                assert(e.type=="welcome" and Place.id(e.id) and (e.allowReset==nil or type(e.allowReset)=="boolean"),
                    "The server did not start a Pot session.")
                return e
            end)
            if not ok then close(ws); error("Session access denied or unavailable.",0) end
            return {socket=ws,welcome=welcome}
        end,
    }
end

function Network.previewer(url,token)
    local base=if url and url~="" then endpoint(url) else nil
    local cache,order,jobs={},{},0
    return function(place)
        local key=Store.revision(place)
        if cache[key] then return cache[key] end
        assert(jobs<2,"Thumbnail workers are busy.")
        jobs+=1
        local ok,png=pcall(function()
            if base then
                local _,data=Place.wire(place)
                return request(base.."/v3/render","POST",token,data,"image/png",1024*1024)
            end
            return Thumbnail.render(place)
        end)
        jobs-=1
        if not ok then error(png,0) end
        if not cache[key] then
            cache[key]=png
            order[#order+1]=key
            if #order>24 then cache[table.remove(order,1)]=nil end
        end
        return png
    end
end

function Network.render(host,port,token)
    assert(host=="127.0.0.1" or host=="localhost" or host=="::1" or (token and token~=""),
        "A non-loopback renderer needs an access token.")
    local preview=Network.previewer()
    return net.serve(port,{address=host,handleRequest=function(req)
        if req.path=="/healthz" and req.method=="GET" then return reply(200,{service="PotRenderService",status="ok"}) end
        if token and token~="" and not equal(credential(req),token) then return fail(401,"Access denied.") end
        if req.path~="/v3/render" or req.method~="POST" then return fail(404,"Unknown render route.") end
        if #req.body>Place.limit then return fail(413,"Binary place is too large.") end
        local ok,p=pcall(function() return Place.validate(Wire.decode(req.body,Place.limit)) end)
        if not ok then return fail(400,"Invalid binary place.") end
        local pass,png=pcall(preview,p)
        return if pass then reply(200,png,"image/png") else fail(503,"Thumbnail renderer unavailable.")
    end})
end

function Network.serve(store,options)
    local rooms,users={},0
    local preview=Network.previewer(options.renderURL,options.renderToken)
    local function reader(key) return not options.read or options.read=="" or equal(key,options.read) or equal(key,options.write) end
    local function writer(key) return equal(key,options.write) end
    local function reload(id)
        local r=rooms[id]
        rooms[id]=nil
        if r then for socket in pairs(r.peers) do task.defer(close,socket,1012) end end
    end
    local function handle(req)
        local method,path,key=req.method,req.path,credential(req)
        if method=="GET" and path=="/healthz" then return reply(200,{service="Pot Worlds",status="ok"}) end
        if method=="GET" and path=="/v3/worlds" then
            return if reader(key) then reply(200,store.list()) else fail(401,"Access denied.")
        end
        if method=="GET" and path=="/v3/published" then
            return if writer(key) then reply(200,store.list(true)) else fail(401,"Publishing access is required.")
        end
        local managed=path:match("^/v3/published/([a-z0-9%-]+)$")
        local id=path:match("^/v3/worlds/([a-z0-9%-]+)$")
        local image=path:match("^/v3/worlds/([a-z0-9%-]+)/thumbnail$")
        local spawns=path:match("^/v3/worlds/([a-z0-9%-]+)/spawns$")
        if managed and method=="GET" then
            if not writer(key) then return fail(401,"Publishing access is required.") end
            local p=store.published(managed)
            return if p then reply(200,p) else fail(404,"Published world not found.")
        end
        if id and (method=="PUT" or method=="DELETE") then
            if not writer(key) then return fail(401,"Publishing access is required.") end
            if method=="DELETE" then
                if not store.published(id) then return fail(404,"Published world not found.") end
                store.remove(id)
                reload(id)
                return reply(200,true)
            end
            if #req.body>Place.limit then return fail(413,"Binary place is too large.") end
            local p=Place.validate(Wire.decode(req.body,Place.limit))
            if p.id~=id then return fail(400,"World IDs differ.") end
            local result=store.publish(p)
            reload(id)
            return reply(200,result)
        end
        if method=="GET" and (id or image or spawns) then
            if not reader(key) then return fail(401,"Access denied.") end
            local p=store.load(id or image or spawns)
            if not p then return fail(404,"World not found.") end
            if spawns then return reply(200,Place.spawnInfo(p)) end
            return if id then reply(200,p) else reply(200,preview(p),"image/png")
        end
        return fail(404,"Unknown Pot route.")
    end
    local service=net.serve(options.port,{address=options.host,handleRequest=function(req)
        local ok,result=pcall(handle,req)
        return if ok then result else fail(400,"The Pot operation could not be completed.")
    end,handleWebSocket=function(socket)
        if users>=128 then close(socket,1013); return end
        users+=1
        local r,p,id
        pcall(function()
            local raw=Network.within(5,function() return socket:next() end)
            local hello=Wire.decode(raw,2048)
            assert(type(hello)=="table" and hello.type=="join" and Place.id(hello.world) and reader(hello.credential))
            id=hello.world
            local place=assert(store.load(id))
            local revision=Store.revision(place)
            r=rooms[id]
            if r and r.revision~=revision then reload(id); r=nil end
            if not r then r={sim=Room.create(place),peers={},n=0,revision=revision}; rooms[id]=r end
            assert(r.n<24)
            p=Room.add(r.sim)
            r.n+=1
            socket:send(Wire.encode({type="welcome",id=p.id,allowReset=r.sim.allowReset}),true)
            r.peers[socket]={busy=false}
            local budget,last=40,os.clock()
            while rooms[id]==r do
                local data=socket:next()
                if not data then break end
                local packet=Wire.decode(data,512)
                local now=os.clock()
                budget=math.min(40,budget+(now-last)*40)
                last=now
                if budget<1 then break end
                budget-=1
                if packet.type=="press" then Room.press(r.sim,p,packet.part)
                elseif packet.type=="reset" then
                    local ok,message=Room.reset(r.sim,p)
                    socket:send(Wire.encode({type="resetResult",ok=ok,message=message}),true)
                elseif packet.type~="input" or not Room.input(r.sim,p,packet) then break end
            end
        end)
        if p then
            r.peers[socket]=nil
            Room.leave(r.sim,p)
            r.n-=1
            if r.n==0 and rooms[id]==r then rooms[id]=nil end
        end
        users-=1
        close(socket)
    end})
    task.spawn(function()
        local tick,last,remainder=0,os.clock(),0
        while true do
            task.wait(1/60)
            local now=os.clock()
            remainder+=math.min(.12,now-last)
            last=now
            while remainder>=1/60 do
                remainder-=1/60
                tick+=1
                for _,r in pairs(rooms) do
                    Room.step(r.sim)
                    if tick%3==0 and (r.sim.dirty or tick%60==0) then
                        local blob=Wire.encode(Room.snapshot(r.sim))
                        for socket,p in pairs(r.peers) do
                            if not p.busy then
                                p.busy=true
                                task.defer(function()
                                    local ok=pcall(function() socket:send(blob,true) end)
                                    p.busy=false
                                    if not ok then close(socket,1001) end
                                end)
                            end
                        end
                    end
                end
            end
        end
    end)
    return service
end
return Network
