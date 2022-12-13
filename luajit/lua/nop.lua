local ffi = require('ffi')


local nopFfi = setmetatable({
    new = function (...)
        print('call unsafe ffi.new')
        return ffi.new(...)
    end,
    string = function (...)
        print('call unsafe ffi.string')
        return ffi.string(...)
    end
}, {
    __index = function(self, key)
        print('call ffi.' .. key)
        return function() end
    end
})

package = setmetatable({}, {
    __index = function(self, key)
        print('call package.' .. key)
        return function() end 
    end
})

require = function (lib)
	print('call require ' .. lib)

	if lib == 'ffi' then
		return nopFfi
	end
end

os = setmetatable({}, {
    __index = function(self, key)
        print('call os.' .. key)
        return function() end 
    end
})

io = setmetatable({}, {
    __index = function(self, key)
        print('call io.' .. key)
        return function() end 
    end
})

debug = setmetatable({
    getinfo = function ()
        return false
    end
}, {
    __index = debug
})

string = setmetatable({
    dump = function ()
        return error()
    end
}, {
    __index = string
})

load = function(code)
    load_call(code)
	return function () end
end

loadstring = function(code)
    loadstring_call(code)
	return function () end
end

loadfile = function(filename)
    print('call loadfile ' .. filename)
	return function () end
end

dofile = function(filename)
    print('call dofile ' .. filename)
	return function () end
end

setmetatable(_G, {
    __index = function (self, key)
        print('call ' .. key)
        return function () end
    end
})