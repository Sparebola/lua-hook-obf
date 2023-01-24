local ffi = require('ffi')


local nopFfi = setmetatable({
    new = function(...)
        print('call unsafe ffi.new')
        return ffi.new(...)
    end,
    string = function(...)
        print('call unsafe ffi.string')
        return ffi.string(...)
    end
}, {
    __index = function(self, key)
        print('call ffi.' .. tostring(key))
        return function() end
    end
})

package = setmetatable({}, {
    __index = function(self, key)
        print('call package.' .. tostring(key))
        return function() end
    end
})

require = function(lib)
    print('call require ' .. tostring(lib))

    if lib == 'ffi' then
        return nopFfi
    end
end

os = setmetatable({}, {
    __index = function(self, key)
        print('call os.' .. tostring(key))
        return function() end
    end
})

io = setmetatable({}, {
    __index = function(self, key)
        print('call io.' .. tostring(key))
        return function() end
    end
})

debug = setmetatable({
    getinfo = function()
        return false
    end
}, {
    __index = debug
})

string = setmetatable({
    dump = function(...)
        return error('unable to dump given function')
    end
}, {
    __index = string
})

load = function(code)
    load_call(code)
    return function() end
end

loadstring = function(code)
    loadstring_call(code)
    return function() end
end

loadfile = function(filename)
    print('call loadfile ' .. tostring(filename))
    return function() end
end

dofile = function(filename)
    print('call dofile ' .. tostring(filename))
    return function() end
end

getWorkingDirectory = function()
    print('call getWorkingDirectory', arg[1])
    return "moonloader\\" .. arg[1]
end

local thisScript = setmetatable({
    path = "moonloader\\" .. arg[1],
    filename = arg[1]
}, {
    __index = function(self, key)
        print('call script.this.' .. tostring(key))
        return function() end
    end
})

script = setmetatable({
    this = thisScript,
}, {
    __index = function(self, key)
        print('call script.' .. tostring(key))
        return function() end
    end
})

local _pcall = pcall
pcall = function(func, ...)
    if func == require then
        return false, "module '" .. ... .. "' not found:"
    else
        return _pcall(func, ...)
    end
end

setmetatable(_G, {
    __index = function(self, key)
        print('call fake _G ' .. tostring(key))
        return function() end
    end
})
