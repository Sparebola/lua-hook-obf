----------------------------------------------------------------------------
-- LuaJIT bytecode listing module.
--
-- Copyright (C) 2005-2017 Mike Pall. All rights reserved.
-- Released under the MIT license. See Copyright Notice in luajit.h
----------------------------------------------------------------------------
--
-- This module lists the bytecode of a Lua function. If it's loaded by -jbc
-- it hooks into the parser and lists all functions of a chunk as they
-- are parsed.
--
-- Example usage:
--
--   luajit -jbc -e 'local x=0; for i=1,1e6 do x=x+i end; print(x)'
--   luajit -jbc=- foo.lua
--   luajit -jbc=foo.list foo.lua
--
-- Default output is to stderr. To redirect the output to a file, pass a
-- filename as an argument (use '-' for stdout) or set the environment
-- variable LUAJIT_LISTFILE. The file is overwritten every time the module
-- is started.
--
-- This module can also be used programmatically:
--
--   local bc = require("jit.bc")
--
--   local function foo() print("hello") end
--
--   bc.dump(foo)           --> -- BYTECODE -- [...]
--   print(bc.line(foo, 2)) --> 0002    KSTR     1   1      ; "hello"
--
--   local out = {
--     -- Do something with each line:
--     write = function(t, ...) io.write(...) end,
--     close = function(t) end,
--     flush = function(t) end,
--   }
--   bc.dump(foo, out)
--
------------------------------------------------------------------------------

-- Cache some library functions and objects.
local jit = require("jit")
assert(jit.version_num == 20100, "LuaJIT core/library version mismatch")
local jutil = require("jit.util")
local vmdef = require("jit.vmdef")
local bit = require("bit")
local sub, gsub, format = string.sub, string.gsub, string.format
local byte, band, shr = string.byte, bit.band, bit.rshift
local funcinfo, funcbc, funck = jutil.funcinfo, jutil.funcbc, jutil.funck
local funcuvname = jutil.funcuvname
local bcnames = vmdef.bcnames
local stdout, stderr = io.stdout, io.stderr
local sf, proto, protos = nil, 0, {}

------------------------------------------------------------------------------

local function uleb128_int(data, pos)
  pos = pos or 1
  local bytes = {}
  for i = pos, #data do
      table.insert(bytes, data[i]:byte())
      if data[i]:byte() < 0x80 then break end
  end
  local result = 0
  for i = #bytes, 2, -1 do
      result = (result + bytes[i] - 1) * 0x80
  end
  result = result + bytes[1]
  return result, #bytes
end

local function printf(text, ...)
  return print(string.format(text, ...))
end

-- local _funck = funck
-- local funck = function (...)
--   local res = _funck(...)
--   print(res)
--   return res or function ()
    
--   end
-- end

-- LuaJIT class
local Lua = {}
function Lua:new(path, checkIfIsCompiled, checkForVersion)
    local public = {}

    public.loaded = false
    public.path = ""
    public.data = {}

    function public:init(path, checkIfIsCompiled, checkForVersion)
        self.loaded = false
        if not path then return end
        local fh = io.open(path, "rb")
        if not fh then return end
        local data = fh:read("*all")
        fh:close()
        if not data then return end
        if checkIfIsCompiled and checkIfIsCompiled ~= 0 and data:sub(1, 3) ~= "\x1B\x4C\x4A" then return end
        if checkForVersion ~= "" and type(checkForVersion) == "string" and data:sub(4, 4) ~= checkForVersion then return end
        if checkForVersion ~= 0 and type(checkForVersion) == "number" and data:sub(4, 4):byte() ~= checkForVersion then return end
        self.path = path
        self.data = {}
        for i = 1, #data do table.insert(self.data, data:sub(i, i)) end
        self.loaded = true
        return true
    end

    function public:isCompiled()
        if not self.loaded then return end
        return string.format("%s%s%s", unpack(self.data, 1, 3)) == "\x1B\x4C\x4A"
    end

    function public:version()
        if not self.loaded then return end
        return self.data[4]:byte()
    end

    function public:protos()
        if not self.loaded then return end
        local protos = {}
        local i = 6
        repeat
            local proto, next = self:pinfo(i)
            table.insert(protos, proto)
            i = i + next
        until self.data[i] == "\x00" or i >= #self.data
        return protos
    end

    function public:pinfo(pos)
        if not self.loaded then return end
        local size, count = uleb128_int(self.data, pos)
        local proto = {
            ["pos"] = pos,
            ["size"] = size,
            ["fullsize"] = size + count,
            ["flags"] = self.data[pos + count],
            ["params"] = self.data[pos + count + 1],
            ["framesize"] = self.data[pos + count + 2],
            ["numuv"] = self.data[pos + count + 3]
        }
        pos = pos + count + 4
        proto.numkgc, count = uleb128_int(self.data, pos)
        pos = pos + count
        proto.numkn, count = uleb128_int(self.data, pos)
        pos = pos + count
        proto.numbc, count = uleb128_int(self.data, pos)
        proto.ins = pos + count
        return proto, proto.fullsize
    end

    function public:save()
        if not self.loaded then return end
        local fh = io.open(self.path, "wb")
        for k, v in pairs(self.data) do fh:write(v) end
        fh:close()
    end

    public:init(path, checkIfIsCompiled, checkForVersion)
    setmetatable(public, self)
    self.__index = self
    return public
end

local function ctlsub(c)
  if c == "\n" then return "\\n"
  elseif c == "\r" then return "\\r"
  elseif c == "\t" then return "\\t"
  else return format("\\%03d", byte(c))
  end
end

-- Return one bytecode line.
local function bcline(func, pc, prefix)
  local ins, m = funcbc(func, pc)
  if not ins then return end
  local ma, mb, mc = band(m, 7), band(m, 15*8), band(m, 15*128)
  local a = band(shr(ins, 8), 0xff)
  local oidx = 6*band(ins, 0xff)
  local op = sub(bcnames, oidx+1, oidx+6)
  local s = ""
  if sf and #protos > 0 then
    s = format("%08X  %04X %s %02X:%-6s %3s ",
      protos[proto].ins - 1 + ((pc - 1) * 4), (pc - 1) * 4, prefix or "  ", band(ins, 0xff), op, ma == 0 and "" or a)
  else
    s = format("%04d %s %-6s %3s ",
      pc, prefix or "  ", op, ma == 0 and "" or a)
  end
  local d = shr(ins, 16)
  if mc == 13*128 then -- BCMjump
    return sf and format("%s=> %04X\n", s, ((pc+d-0x7fff) - 1) * 4) or format("%s=> %04d\n", s, pc+d-0x7fff)
  end
  if mb ~= 0 then
    d = band(d, 0xff)
  elseif mc == 0 then
    return s.."\n"
  end
  local kc
  if mc == 10*128 then -- BCMstr
    local kcc = funck(func, -d-1)
    -- kc = funck(func, -d-1)
    -- kc = format(#kc > 40 and '"%.40s"~' or '"%s"', gsub(kc, "%c", ctlsub))
    if sf then
      kc = format('"%s"', kcc)
    elseif kc then
      kc = format('"%s"', kcc:gsub("\n", "\\n"):gsub("\t", "\\t"))
    end
  elseif mc == 9*128 then -- BCMnum
    kc = funck(func, d)
    if kc then
      if op == "TSETM " then kc = kc - 2^52 end
    end
  elseif mc == 12*128 then -- BCMfunc
    local kcc = funck(func, -d-1)
    if not kcc or type(kcc) == "string" then
      kc = 'invalid opcode'
    else
	  if type(funcinfo) == 'function' and type(kcc) == 'function' then
		  local fi = funcinfo(kcc)
		  if type(fi) == 'table' or type(fi) == 'userdata' then
			  if fi.ffid then
				kc = vmdef.ffnames[fi.ffid]
			  else
				kc = fi.loc
			  end
			 end
		end
    end
  elseif mc == 5*128 then -- BCMuv
    kc = funcuvname(func, d)
  end
  if ma == 5 then -- BCMuv
    local ka = funcuvname(func, a)
    if ka then
      if kc then kc = ka.." ; "..kc else kc = ka end
    else
      kc = 'invalid opcode'
    end
  end
  if mb ~= 0 then
    local b = shr(ins, 24)
    if kc then return format("%s%3d %3d  ; %s\n", s, b, d, kc) end
    return format("%s%3d %3d\n", s, b, d)
  end
  if kc then return format("%s%3d      ; %s\n", s, d, kc) end
  if mc == 7*128 and d > 32767 then d = d - 65536 end -- BCMlits
  return format("%s%3d\n", s, d)
end

-- Collect branch targets of a function.
local function bctargets(func)
  local target = {}
  for pc=1,1000000000 do
    local ins, m = funcbc(func, pc)
    if not ins then break end
    if band(m, 15*128) == 13*128 then target[pc+shr(ins, 16)-0x7fff] = true end
  end
  return target
end

-- Dump bytecode instructions of a function.
local function bcdump(func, out, all, filename)
  if not sf and type(filename) == "string" and #filename > 0 then
    sf = Lua:new(filename, true, 2)
    for i, proto in pairs(sf:protos()) do table.insert(protos, proto) end
    out:write(format("-- Source: %s\n", filename))
    out:write("-- Compiler version: 2.1\n")
    out:write(format("-- Flags: 0x%X\n\n", sf.data[5]:byte()))
  end
  if not out then out = stdout end
  local fi = funcinfo(func)
  if all and fi.children then
    for n=-1,-1000000000,-1 do
      local k = funck(func, n)
      if not k then break end
      if type(k) == "proto" then bcdump(k, out, true) end
    end
  end
  if sf and #protos > 0 then
    proto = proto + 1
    local pinfo = protos[proto]
    out:write(format("-- Proto #%d -- pos: 0x%X, size: 0x%X, fullsize: 0x%X, flags: 0x%X, params: %d, framesize: 0x%X, numuv: %d, numkgc: %d, numkn: %d, numbc: %d, ins: 0x%X\n",
      proto, pinfo.pos - 1, pinfo.size, pinfo.fullsize, pinfo.flags:byte(), pinfo.params:byte(), pinfo.framesize:byte(), pinfo.numuv:byte(),
      pinfo.numkgc, pinfo.numkn, pinfo.numbc, pinfo.ins - 1))
  else
    out:write(format("-- BYTECODE -- %s-%d\n", fi.loc, fi.lastlinedefined))
  end
  local target = bctargets(func)
  for pc=1,1000000000 do
    local s = bcline(func, pc, target[pc] and "=>")
    if not s then break end
    out:write(s)
  end
  out:write("\n")
  out:flush()
end

------------------------------------------------------------------------------

-- Active flag and output file handle.
local active, out

-- List handler.
local function h_list(func)
  return bcdump(func, out)
end

-- Detach list handler.
local function bclistoff()
  if active then
    active = false
    jit.attach(h_list)
    if out and out ~= stdout and out ~= stderr then out:close() end
    out = nil
  end
end

-- Open the output file and attach list handler.
local function bcliston(outfile)
  if active then bclistoff() end
  if not outfile then outfile = os.getenv("LUAJIT_LISTFILE") end
  if outfile then
    out = outfile == "-" and stdout or assert(io.open(outfile, "w"))
  else
    out = stderr
  end
  jit.attach(h_list, "bc")
  active = true
end

-- Public module functions.
return {
  line = bcline,
  dump = bcdump,
  targets = bctargets,
  on = bcliston,
  off = bclistoff,
  start = bcliston -- For -j command line option.
}

