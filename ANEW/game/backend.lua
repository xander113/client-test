local ffi=require("ffi")
local socket=require("socket")
local Wire=require("wire")
local Backend={}
Backend.__index=Backend

local platform=love.system.getOS()
local function entropy()
    local bytes=ffi.new("unsigned char[32]")
    if platform=="Windows" then
        ffi.cdef[[int32_t BCryptGenRandom(void*, unsigned char*, unsigned long, unsigned long);]]
        assert(ffi.load("bcrypt").BCryptGenRandom(nil,bytes,32,2)==0,"The OS random generator is unavailable.")
        return ffi.string(bytes,32)
    elseif platform=="OS X" then
        ffi.cdef[[void arc4random_buf(void*,size_t);]]
        ffi.C.arc4random_buf(bytes,32)
        return ffi.string(bytes,32)
    else
        local source=assert(io.open("/dev/urandom","rb"))
        local value=source:read(32)
        source:close()
        return value
    end
end

local function spawnWindows(args)
    ffi.cdef[[
        typedef struct {
            uint32_t cb; uint16_t *lpReserved, *lpDesktop, *lpTitle;
            uint32_t dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            uint16_t wShowWindow, cbReserved2; uint8_t *lpReserved2; void *hStdInput, *hStdOutput, *hStdError;
        } POT_STARTUPINFO;
        typedef struct {void *hProcess, *hThread; uint32_t dwProcessId, dwThreadId;} POT_PROCESSINFO;
        int MultiByteToWideChar(unsigned int, uint32_t, const char*, int, uint16_t*, int);
        int CreateProcessW(const uint16_t*, uint16_t*, void*, void*, int, uint32_t, void*, const uint16_t*, POT_STARTUPINFO*, POT_PROCESSINFO*);
        int CloseHandle(void*);
        uint32_t WaitForSingleObject(void*,uint32_t);
    ]]
    local function wide(text)
        local count=ffi.C.MultiByteToWideChar(65001,0,text,-1,nil,0)
        assert(count>0,"Invalid runtime path.")
        local buf=ffi.new("uint16_t[?]",count)
        assert(ffi.C.MultiByteToWideChar(65001,0,text,-1,buf,count)>0,"Invalid runtime path.")
        return buf
    end
    local command={}
    for i,value in ipairs(args) do
        assert(not value:find('"',1,true),"Invalid Windows runtime path.")
        command[i]='"'..value:gsub("(\\+)$","%1%1")..'"'
    end
    local info,start=ffi.new("POT_PROCESSINFO[1]"),ffi.new("POT_STARTUPINFO[1]")
    start[0].cb=ffi.sizeof(start[0])
    assert(ffi.C.CreateProcessW(wide(args[1]),wide(table.concat(command," ")),nil,nil,0,0x08000000,nil,nil,start,info)~=0,
        "Pot could not launch its Luau runtime.")
    ffi.C.CloseHandle(info[0].hThread)
    return {
        finished=function() return ffi.C.WaitForSingleObject(info[0].hProcess,0)==0 end,
        release=function() ffi.C.CloseHandle(info[0].hProcess) end,
    }
end

local function spawnPosix(args)
    ffi.cdef[[
        int posix_spawn(int*,const char*,const void*,const void*,char *const[],char *const[]);
        int waitpid(int,int*,int);
        extern char **environ;
        char ***_NSGetEnviron(void);
    ]]
    local environ=platform=="OS X" and ffi.C._NSGetEnviron()[0] or ffi.C.environ
    local argv=ffi.new("char *[?]",#args+1)
    for i,arg in ipairs(args) do argv[i-1]=ffi.cast("char*",arg) end
    local pid=ffi.new("int[1]")
    assert(ffi.C.posix_spawn(pid,args[1],nil,nil,argv,environ)==0,"Pot could not launch its Luau runtime.")
    return {finished=function() return ffi.C.waitpid(pid[0],nil,1)~=0 end,release=function() end}
end

local function resources()
    local override=os.getenv("POT_RESOURCES")
    if override and override~="" then return override end
    local base=love.filesystem.getSourceBaseDirectory():gsub("\\","/")
    if platform=="OS X" then
        ffi.cdef[[int _NSGetExecutablePath(char*,uint32_t*);]]
        local max=ffi.new("uint32_t[1]",8192)
        local path=ffi.new("char[8192]")
        assert(ffi.C._NSGetExecutablePath(path,max)==0,"Pot could not find its app resources.")
        return assert(ffi.string(path):match("^(.*)/MacOS/[^/]+$")).."/Resources"
    end
    return base
end

function Backend.new(event)
    local root=resources()
    local listener=assert(socket.bind("127.0.0.1",0))
    listener:settimeout(0)
    local _,port=listener:getsockname()
    local bytes=entropy()
    local token=bytes:gsub(".",function(c) return ("%02x"):format(c:byte()) end)
    local binary=platform=="Windows" and "lune.exe" or (jit.arch=="arm64" and "lune-arm64" or "lune-x64")
    local dataDir=os.getenv("POT_LOCAL_DATA_DIR")
    if not dataDir or dataDir=="" then
        local config=platform=="Linux" and os.getenv("XDG_CONFIG_HOME") or nil
        dataDir=(config or love.filesystem.getAppdataDirectory()).."/Pot/worlds"
    end
    local spawn=platform=="Windows" and spawnWindows or spawnPosix
    local runtime=spawn({root.."/"..binary,"run",root.."/luau/main.luau","desktop",root.."/luau",
        ("%d"):format(port),token,dataDir})
    return setmetatable({listener=listener,token=token,process=runtime,event=event,requests={},
        incoming="",outgoing="",seq=0,started=love.timer.getTime(),verified=false},Backend)
end

function Backend:call(action,params,respond)
    if self.fault then
        if respond then respond(nil,self.fault) end
        return
    end
    local p=params or {}
    p.action=action
    if respond then
        self.seq=self.seq+1
        p.id=self.seq
        self.requests[p.id]={fn=respond, deadline=love.timer.getTime()+14}
    end
    local ok,bytes=pcall(Wire.frame,p)
    if not ok or #self.outgoing+#bytes>Wire.limit*2 then
        if p.id then self.requests[p.id]=nil; respond(nil,"The runtime request is too large or busy.") end
        return
    end
    self.outgoing=self.outgoing..bytes
end

function Backend:fail(message)
    self.fault=message
    if self.channel then self.channel:close(); self.channel=nil end
    if self.listener then self.listener:close(); self.listener=nil end
    local pending=self.requests
    self.requests={}
    for _,request in pairs(pending) do request.fn(nil,message) end
end

function Backend:pump()
    if self.fault then return end
    local now=love.timer.getTime()
    if self.process.finished() then self:fail("The Luau runtime stopped."); return end
    if not self.channel then
        self.channel=self.listener:accept()
        if self.channel then self.channel:settimeout(0)
        elseif now-self.started>5 then self:fail("The Luau runtime could not connect."); return end
    end
    if self.channel then
        while true do
            local data,err,part=self.channel:receive(65536)
            self.incoming=self.incoming..(data or part or "")
            if #self.incoming>Wire.limit*2 then self:fail("The runtime sent too much data."); return end
            if not data then
                if err=="closed" then self:fail("The Luau connection closed."); return end
                break
            end
        end
        while #self.incoming>=4 do
            local valid,size=pcall(Wire.size,self.incoming:sub(1,4))
            if not valid then self:fail("Invalid runtime packet."); return end
            if #self.incoming<size+4 then break end
            local ok,p=pcall(Wire.decode,self.incoming:sub(5,4+size))
            self.incoming=self.incoming:sub(5+size)
            if not ok or type(p)~="table" then self:fail("Invalid runtime packet."); return end
            if not self.verified then
                if p.hello~=self.token then self:fail("The Luau runtime could not be verified."); return end
                self.verified=true
                self.listener:close(); self.listener=nil
            elseif p.event then self.event(p.event)
            elseif p.id then
                local request=self.requests[p.id]
                self.requests[p.id]=nil
                if request then request.fn(p.value,p.error) end
            end
        end
        if self.verified and #self.outgoing>0 then
            local sent,err,partial=self.channel:send(self.outgoing)
            self.outgoing=self.outgoing:sub((sent or partial or 0)+1)
            if err=="closed" then self:fail("The Luau connection closed."); return end
        end
    end
    for id,request in pairs(self.requests) do
        if now>request.deadline then self.requests[id]=nil; request.fn(nil,"The Pot runtime timed out.") end
    end
end

function Backend:close()
    if self.channel then self.channel:close() end
    if self.listener then self.listener:close() end
    self.process.release()
end

return Backend
