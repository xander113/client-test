local net=require("@lune/net")
local fs=require("@lune/fs")
local task=require("@lune/task")
local stdio=require("@lune/stdio")
local process=require("@lune/process")
local Wire=require("./wire")
local Place=require("./place")
local Script=require("./scripting")
local Room=require("./room")
local Store=require("./store")
local Network=require("./network")

local env=process.env
local mode,root=process.args[1],process.args[2]
assert(root and fs.isDir(root.."/samples"),"Set the Pot runtime source directory.")

local function desktop()
    local stream=net.tcp.connect("127.0.0.1",assert(tonumber(process.args[3])))
    stream:write(Wire.frame({hello=process.args[4]}))
    local store=Store.new(root,env.POT_LOCAL_DATA_DIR or process.args[5])
    local preview=Network.previewer()
    local remote,networkMode=nil,"local"
    if env.POT_API_ENDPOINT and env.POT_API_ENDPOINT~="" then
        local ok,value=pcall(function()
            local backend=Network.remote(env.POT_API_ENDPOINT,env.POT_API_READ_TOKEN,env.POT_API_WRITE_TOKEN)
            Network.within(2,backend.list)
            return backend
        end)
        if ok then remote,networkMode=value,"hosted"
        else stdio.ewrite("Pot is using the local library.\n") end
    end
    local alive,current=true,nil
    local outgoing,busy={},false
    local function stop()
        local old=current
        current=nil
        if old and old.socket then task.defer(function() pcall(function() old.socket:close() end) end) end
    end
    local function send(packet)
        if not alive then return end
        if #outgoing>=64 then
            if packet.event and packet.event.type=="state" then return end
            alive=false
            stream:close()
            return
        end
        outgoing[#outgoing+1]=Wire.frame(packet)
        if busy then return end
        busy=true
        task.defer(function()
            while alive and #outgoing>0 do
                local bytes=table.remove(outgoing,1)
                if not pcall(function() stream:write(bytes) end) then
                    alive=false
                    stop()
                    pcall(function() stream:close() end)
                end
            end
            busy=false
        end)
    end
    local function exact(n)
        local chunks={}
        while n>0 do
            local s=stream:read(n)
            if not s or #s==0 then return nil end
            chunks[#chunks+1]=s
            n-=#s
        end
        return table.concat(chunks)
    end
    local function localSession(p)
        assert(p,"World not found.")
        local r=Room.create(p)
        local actor=Room.add(r)
        stop()
        current={room=r,player=actor}
        send({event={type="welcome",id=actor.id}})
        Room.step(r)
        send({event=Room.snapshot(r)})
        return true
    end
    local function remoteSession(id)
        stop()
        local anchor={}
        current=anchor
        local session=remote.join(id)
        if current~=anchor then session.socket:close(); return false end
        current=session
        send({event=session.welcome})
        task.spawn(function()
            pcall(function()
                while alive and current==session do
                    local raw=Network.within(15,function() return session.socket:next() end)
                    if not raw then break end
                    local e=Wire.decode(raw,64*1024)
                    if e.type=="state" and type(e.players)=="table" and #e.players<=24 and type(e.effects)=="table" and #e.effects<=400 then
                        for _,p in ipairs(e.players) do
                            assert(Place.id(p.id) and #p.name<=80 and Place.color(p.color)
                                and Place.number(p.x,-320,320) and Place.number(p.y,-40,390)
                                and Place.number(p.z,-320,320) and Place.number(p.yaw,-math.pi,math.pi))
                        end
                        for _,fx in ipairs(e.effects) do
                            assert(Place.id(fx.id) and Place.color(fx.color) and type(fx.solid)=="boolean"
                                and type(fx.visible)=="boolean" and (not fx.pulse or Place.color(fx.pulse)))
                        end
                        send({event=e})
                    end
                end
            end)
            if current==session then
                stop()
                send({event={type="closed",message="Session ended."}})
            end
        end)
        return true
    end
    local function ownLoad(id)
        assert(Place.id(id),"Invalid world ID.")
        return assert(if remote then remote.load(id) else store.load(id),"World not found.")
    end
    local function act(c)
        local a,id=c.action,c.world
        if a=="mode" then return networkMode
        elseif a=="worlds" then return if remote then remote.list() else store.list()
        elseif a=="load" then return ownLoad(id)
        elseif a=="thumbnail" then return Wire.bytes(if remote then remote.preview(id) else preview(ownLoad(id)))
        elseif a=="sample" then return store.sample()
        elseif a=="open" then return Place.load(c.path)
        elseif a=="save" then Place.save(c.path,c.scene); return true
        elseif a=="publish" then return if remote then remote.publish(c.scene) else store.publish(c.scene)
        elseif a=="published" then return if remote then remote.managed() else store.list(true)
        elseif a=="openPublished" then return assert(if remote then remote.published(id) else store.published(id),"Published world not found.")
        elseif a=="unpublish" then return if remote then remote.remove(id) else store.remove(id)
        elseif a=="script" then Script.compile(c.source); return true
        elseif a=="solo" then return localSession(ownLoad(id))
        elseif a=="playtest" then return localSession(Place.validate(c.scene))
        elseif a=="join" then return if remote then remoteSession(id) else localSession(ownLoad(id))
        else error("Unknown Pot action.",0) end
    end
    local function input(c)
        local s=current
        if not s then return end
        if s.room then
            if c.action=="input" then Room.input(s.room,s.player,c.input)
            else Room.press(s.room,s.player,c.part) end
        elseif s.socket then
            if c.action=="press" then
                task.defer(function() pcall(function() s.socket:send(Wire.encode({type="press",part=c.part}),true) end) end)
            elseif type(c.input)=="table" then
                s.input=c.input
                if not s.sending then
                    s.sending=true
                    task.defer(function()
                        while s.input and current==s do
                            local motion=s.input
                            s.input=nil
                            motion.type="input"
                            if not pcall(function() s.socket:send(Wire.encode(motion),true) end) then break end
                        end
                        s.sending=false
                    end)
                end
            end
        end
    end
    task.spawn(function()
        local elapsed,last,ticks=0,os.clock(),0
        while alive do
            task.wait(1/60)
            local now=os.clock()
            elapsed+=math.min(.12,now-last)
            last=now
            while elapsed>=1/60 do
                elapsed-=1/60
                ticks+=1
                if current and current.room then
                    local r=current.room
                    Room.step(r)
                    if ticks%3==0 and (r.dirty or ticks%60==0) then send({event=Room.snapshot(r)}) end
                end
            end
        end
    end)
    local pending=0
    while alive do
        local header=exact(4)
        if not header then break end
        local body=exact(Wire.size(header))
        if not body then break end
        local c=Wire.decode(body)
        if c.action=="input" or c.action=="press" then input(c)
        elseif c.action=="leave" then stop(); if c.id then send({id=c.id,value=true}) end
        elseif pending<12 then
            pending+=1
            task.defer(function()
                local ok,result=pcall(act,c)
                pending-=1
                if ok then send({id=c.id,value=result})
                else send({id=c.id,error=tostring(result):gsub("^.-:%d+: ",""):sub(1,400)}) end
            end)
        else send({id=c.id,error="Pot is busy."}) end
    end
    alive=false
    stop()
    stream:close()
    process.exit(0)
end

if mode=="desktop" then
    desktop()
elseif mode=="worlds" then
    local service=Network.serve(Store.new(root,env.POT_WORLD_DATA_DIR),{
        host=env.POT_WORLD_HOST or "127.0.0.1",port=tonumber(env.POT_WORLD_PORT or "4831"),
        read=env.POT_WORLD_READ_TOKEN,write=env.POT_WORLD_WRITE_TOKEN,
        renderURL=env.POT_RENDER_ENDPOINT,renderToken=env.POT_RENDER_TOKEN,
    })
    print("Pot Worlds listening on "..service.ip..":"..service.port)
elseif mode=="render" then
    local service=Network.render(env.POT_RENDER_HOST or "127.0.0.1",tonumber(env.POT_RENDER_PORT or "4812"),env.POT_RENDER_TOKEN)
    print("PotRenderService listening on "..service.ip..":"..service.port)
else error("Use desktop, worlds or render.") end
