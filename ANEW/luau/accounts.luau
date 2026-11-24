local fs=require("@lune/fs")
local serde=require("@lune/serde")
local Place=require("./place")
local Wire=require("./wire")

local Accounts={}
local limit=4096
local balanceLimit=9000000000000
local lookFields={"skin","shirt","pants","visor"}
local defaultLook={skin="#dbccad",shirt="#31a963",pants="#354648",visor="#1e403c"}

local function reject(status,message) error({status=status,message=message},0) end
local function token(value) return type(value)=="string" and #value==64 and value:match("^[0-9a-f]+$")~=nil end
local function digest(value) return serde.hash("sha256",value) end

function Accounts.look(value)
    if type(value)~="table" then return nil end
    local result={}
    for _,field in ipairs(lookFields) do
        if not Place.color(value[field]) then return nil end
        result[field]=value[field]:lower()
    end
    return result
end

local function record(path)
    local info=fs.metadata(path)
    assert(info.exists and info.kind=="file" and info.size<=limit,"Invalid account file.")
    return Wire.decode(fs.readFile(path),limit)
end

local function commit(path,value,replace)
    local temp=path..".tmp-"..Place.serial()
    local ok,reason=pcall(function()
        fs.writeFile(temp,Wire.encode(value))
        fs.move(temp,path,replace)
    end)
    if not ok then
        if fs.isFile(temp) then fs.removeFile(temp) end
        error(reason,0)
    end
end

function Accounts.new(directory)
    local profiles,secrets,ledgers={},{},{}
    local busy=false
    local api={}
    local function profilePath(id) return directory.."/account-"..id..".pot-account" end
    local function ledgerPath(id) return directory.."/currency-"..id end
    if directory and directory~="" then
        fs.writeDir(directory)
        for _,name in ipairs(fs.readDir(directory)) do
            local id=name:match("^account%-([a-z0-9%-]+)%.pot%-account$")
            if Place.id(id) then
                local p=record(profilePath(id))
                assert(p.id==id and Place.text(p.displayName,24,true) and Accounts.look(p.look)
                    and token(p.digest) and not secrets[p.digest],"Invalid stored account.")
                profiles[id],secrets[p.digest]=p,id
            end
        end
    else directory=nil end

    local function locked(fn)
        if busy then reject(409,"The account store is in use. Retry the request.") end
        busy=true
        local ok,result=pcall(fn)
        busy=false
        if not ok then error(result,0) end
        return result
    end

    local function requireProfile(id)
        local p=profiles[id]
        if not p then reject(404,"Account not found.") end
        return p
    end

    local function ledger(id)
        if ledgers[id] then return ledgers[id] end
        local result={balance=0,sequence=0,operations={}}
        if directory then
            local path=ledgerPath(id)
            if fs.isDir(path) then
                local ordered={}
                for _,name in ipairs(fs.readDir(path)) do
                    local operation=name:match("^operation%-([a-z0-9%-]+)%.pot%-op$")
                    if Place.id(operation) then
                        local entry=record(path.."/"..name)
                        assert(entry.operation==operation and Place.number(entry.sequence,1,9007199254740991)
                            and entry.sequence%1==0 and Place.number(entry.delta,-1000000000,1000000000)
                            and entry.delta%1==0 and entry.delta~=0,"Invalid currency operation file.")
                        ordered[#ordered+1]=entry
                    end
                end
                table.sort(ordered,function(a,b)return a.sequence<b.sequence end)
                for index,entry in ipairs(ordered) do
                    assert(entry.sequence==index and entry.balance==result.balance+entry.delta
                        and Place.number(entry.balance,0,balanceLimit),"Invalid currency ledger.")
                    result.balance,result.sequence=entry.balance,index
                    result.operations[entry.operation]=entry
                end
            end
        end
        ledgers[id]=result
        return result
    end

    local function profile(p)
        return {id=p.id,displayName=p.displayName,look=table.clone(p.look),balance=ledger(p.id).balance}
    end

    local function store(p,previous)
        if directory then commit(profilePath(p.id),p,previous~=nil) end
        if previous then secrets[previous.digest]=nil end
        profiles[p.id],secrets[p.digest]=p,p.id
    end

    function api.identify(credential)
        if token(credential) then return secrets[digest(credential)] end
    end

    function api.avatar(id)
        local p=profiles[id]
        if p then return {displayName=p.displayName,look=table.clone(p.look)} end
    end

    function api.get(id)
        return locked(function() return profile(requireProfile(id)) end)
    end

    function api.provision(id,value)
        if not Place.id(id) or type(value)~="table" or value.balance~=nil then
            reject(400,"Use an account ID and profile fields. Currency has its own route.")
        end
        return locked(function()
            local old=profiles[id]
            local name=if value.displayName~=nil then value.displayName else old and old.displayName
            local look=if value.look~=nil then Accounts.look(value.look) else old and old.look or defaultLook
            if not Place.text(name,24,true) or #name>80 or not look then reject(400,"Invalid display name or appearance.") end
            if value.credential~=nil and not token(value.credential) then reject(400,"Supply a 64-character hex account credential.") end
            local hash=if value.credential then digest(value.credential) else old and old.digest
            if not hash then reject(400,"A new account requires a credential.") end
            if secrets[hash] and secrets[hash]~=id then reject(409,"The credential belongs to another account.") end
            local p={id=id,displayName=name,look=table.clone(look),digest=hash}
            local view=profile(p)
            store(p,old)
            return view
        end)
    end

    function api.setLook(id,value)
        local look=Accounts.look(value)
        if not look then reject(400,"Supply skin, shirt, pants and visor as #rrggbb colors.") end
        return locked(function()
            local old=requireProfile(id)
            local p={id=id,displayName=old.displayName,look=look,digest=old.digest}
            local view=profile(p)
            store(p,old)
            return view
        end)
    end

    function api.adjust(id,operation,delta)
        if not Place.id(operation) or not Place.number(delta,-1000000000,1000000000) or delta%1~=0 or delta==0 then
            reject(400,"Use a unique operation ID and a nonzero integer currency delta.")
        end
        return locked(function()
            requireProfile(id)
            local current=ledger(id)
            local earlier=current.operations[operation]
            if earlier then
                if earlier.delta~=delta then reject(409,"This operation ID was already used with a different amount.") end
                return table.clone(earlier)
            end
            local balance=current.balance+delta
            if balance<0 then reject(409,"Insufficient balance.") end
            if balance>balanceLimit then reject(409,"The resulting balance exceeds the supported range.") end
            local nextOp={operation=operation,delta=delta,balance=balance,sequence=current.sequence+1}
            if directory then
                local path=ledgerPath(id)
                fs.writeDir(path)
                commit(path.."/operation-"..operation..".pot-op",nextOp,false)
            end
            current.balance,current.sequence=balance,nextOp.sequence
            current.operations[operation]=nextOp
            return table.clone(nextOp)
        end)
    end
    return api
end

return Accounts
