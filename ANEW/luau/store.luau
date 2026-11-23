local fs=require("@lune/fs")
local Demo=require("./demo")
local Place=require("./place")
local Wire=require("./wire")
local serde=require("@lune/serde")

local Store={}
function Store.new(root,dir)
    local stock,memory={},{}
    for _,id in ipairs(Demo.ids) do stock[id]=Demo.load(root,id) end
    if dir and dir~="" then
        fs.writeDir(dir)
    else dir=nil end
    local api={}
    local updating=false
    local function path(id,ext) return dir.."/world-"..id..ext end
    local function saved(id)
        if not Place.id(id) then return nil end
        if not dir then return memory[id] end
        for _,ext in ipairs({".pot",".json"}) do
            local p=path(id,ext)
            if fs.isFile(p) then
                local value=Place.load(p)
                assert(value.id==id,"World ID and filename differ.")
                return value
            end
        end
    end
    local function ids()
        if not dir then
            local out={}; for id in pairs(memory) do out[id]=true end
            return out
        end
        local out={}
        for _,file in ipairs(fs.readDir(dir)) do
            local id=file:match("^world%-([a-z0-9%-]+)%.pot$") or file:match("^world%-([a-z0-9%-]+)%.json$")
            if Place.id(id) then out[id]=true end
        end
        return out
    end
    local function change(f)
        assert(not updating,"Another library update is running. Try again.")
        updating=true
        local ok,value=pcall(f)
        updating=false
        if not ok then error(value,0) end
        return value
    end
    function api.load(id) return saved(id) or stock[id] end
    function api.published(id) return saved(id) end
    function api.sample() return Place.validate(stock["terrace-park"]) end
    function api.list(onlyPublished)
        local out=Wire.array()
        local seen={}
        local function add(project,published)
            out[#out+1]={id=project.id,name=project.name,description=project.description,published=published}
            seen[project.id]=true
        end
        if not onlyPublished then
            for _,id in ipairs(Demo.ids) do
                local ok,v=pcall(saved,id)
                add(ok and v or stock[id],not not (ok and v))
            end
        end
        local ordered={}
        for id in pairs(ids()) do ordered[#ordered+1]=id end
        table.sort(ordered)
        for _,id in ipairs(ordered) do
            if not seen[id] then
                local ok,p=pcall(saved,id)
                if ok and p then add(p,true) end
                if #out>=128 then break end
            end
        end
        return out
    end
    function api.publish(project)
        local p=Place.wire(project)
        Place.programs(p)
        return change(function()
            local known,n=ids(),0
            for _ in pairs(known) do n+=1 end
            assert(known[p.id] or n<125,"The world library is full.")
            if dir then Place.save(path(p.id,".pot"),p)
            else memory[p.id]=p end
            return { id=p.id }
        end)
    end
    function api.remove(id)
        assert(Place.id(id),"Invalid world ID.")
        return change(function()
            assert(saved(id),"World is not published.")
            if dir then
                for _,ext in ipairs({".json",".pot"}) do
                    local p=path(id,ext)
                    if fs.isFile(p) then fs.removeFile(p) end
                end
            else memory[id]=nil end
            return true
        end)
    end
    return api
end
function Store.revision(p)
    local _,blob=Place.wire(p)
    return serde.hash("sha256",blob)
end
return Store
