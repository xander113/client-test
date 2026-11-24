local net=require("@lune/net")
local task=require("@lune/task")
local Wire=require("./wire")
local Place=require("./place")

local Hosting={}
function Hosting.new(options,within)
    local id=options.id
    assert(Place.id(id) and #id<=40,"Set a valid POT_WORKER_ID.")
    local token=options.token
    assert(type(token)=="string" and #token==64 and token:match("^[0-9a-f]+$"),"Set the worker control credential.")
    local limit=options.limit
    assert(Place.number(limit,1,1024) and limit%1==0,"Invalid game worker capacity.")
    local url=assert(options.url,"Set POT_CONTROL_URL."):gsub("/+$","")
    assert(url:match("^https?://[^%s@?#]+$"),"Invalid game-worker control URL.")
    local base=url.."/v3/internal/workers/"..id.."/"
    local generation=Place.serial()
    local control={limit=limit}
    local function call(action,value)
        value.generation=generation
        local result=within(5,function()
            return net.request({
                url=base..action,method="POST",headers={Authorization="Bearer "..token,["Content-Type"]=Wire.mime},
                body=Wire.encode(value),
            })
        end)
        local media=result.headers["content-type"] or result.headers["Content-Type"]
        if type(media)=="table" then media=media[1] end
        assert(result.ok and type(media)=="string" and media:match("^[^;]+" )==Wire.mime and #result.body<=Wire.limit,
            "The Pot control plane refused this operation.")
        return Wire.decode(result.body)
    end
    function control.redeem(hello)
        assert(type(hello.ticket)=="string" and #hello.ticket==64 and hello.ticket:match("^[0-9a-f]+$"),
            "Join through the Pot service.")
        local grant=call("redeem",{ticket=hello.ticket})
        assert(Place.id(grant.server) and Place.id(grant.admission) and grant.world==hello.world
            and Place.number(grant.capacity,1,24) and Wire.isBytes(grant.project)
            and type(grant.revision)=="string" and #grant.revision==64,"Invalid game-worker grant.")
        return grant
    end
    function control.release(admission)
        task.defer(function() pcall(call,"release",{admission=admission}) end)
    end
    function control.monitor(active,close)
        task.defer(function()
            local last=os.clock()
            while true do
                local leases=Wire.array()
                for id in pairs(active) do leases[#leases+1]=id end
                local ok,reply=pcall(call,"heartbeat",{limit=limit,leases=leases})
                if ok and type(reply.leases)=="table" then
                    last=os.clock()
                    local kept={}
                    for _,id in ipairs(reply.leases) do kept[id]=true end
                    for _,id in ipairs(leases) do
                        if active[id] and not kept[id] then task.defer(close,active[id],1008) end
                    end
                elseif os.clock()-last>45 then
                    for _,socket in pairs(active) do task.defer(close,socket,1012) end
                end
                task.wait(4)
            end
        end)
    end
    return control
end
return Hosting
