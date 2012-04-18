MWServer = {}

--- Create a new MWServer object
function MWServer:new()
	obj = {
		chunks = {},
		xchunks = {},
		protectedFunctions = {},
		protectedEnvironments = {},
		baseEnv = {}
	}
	setmetatable( obj, self )
	self.__index = self

	obj:init()

	return obj
end

--- Initialise a new MWServer object
function MWServer:init()
	self.baseEnv = self:newEnvironment()
	for funcName, func in pairs( self ) do
		if type(func) == 'function' then
			self.protectedFunctions[func] = true
		end
	end
	self.protectedEnvironments[_G] = true
end

--- Serve requests until exit is requested
function MWServer:execute()
	self:dispatch( nil )
	self:debug( 'MWServer:execute: returning' )
end

--- Call a PHP function
-- Raise an error if the PHP handler requests it. May return any number
-- of values.
--
-- @param id The function ID, specified by a registerLibrary message
-- @param args The function arguments
-- @return The return values from the PHP function
function MWServer:call( id, args )
	local result = self:dispatch( {
		op = 'call',
		id = id,
		args = args
	} )
	if result.op == 'return' then
		return unpack( result.values )
	elseif result.op == 'error' then
		-- Raise an error in the actual user code that called the function
		-- The level is 3 since our immediate caller is a closure
		error( result.value, 3 )
	else
		self:internalError( 'MWServer:call: unexpected result op' )
	end
end

--- Handle a "call" message from PHP. Call the relevant function.
--
-- @param message The message from PHP
-- @return A response message to send back to PHP
function MWServer:handleCall( message )
	local result = { pcall( self.chunks[message.id], unpack( message.args ) ) }
	if (result[1]) then
		table.remove( result, 1 )
		return {
			op = 'return',
			values = result
		}
	else
		return {
			op = 'error',
			value = result[2]
		}
	end
end

--- Handle a "loadString" message from PHP. 
-- Load the function and return a chunk ID.
--
-- @param message The message from PHP
-- @return A response message to send back to PHP
function MWServer:handleLoadString( message )
	if string.find( message.text, '\27Lua', 1, true ) then
		return {
			op = 'error',
			value = 'cannot load code with a Lua binary chunk marker escape sequence in it'
		}
	end
	local chunk, errorMsg = loadstring( message.text, message.chunkName )
	if chunk then
		setfenv( chunk, self.baseEnv )
		local id = self:addChunk( chunk )
		return {
			op = 'return',
			values = {id}
		}
	else
		return {
			op = 'error',
			value = errorMsg
		}
	end
end

--- Add a function value to the list of tracked chunks and return its associated ID.
-- Adding a chunk allows it to be referred to in messages from PHP.
--
-- @param chunk The function value
-- @return The chunk ID
function MWServer:addChunk( chunk )
	local id = #self.chunks + 1
	self.chunks[id] = chunk
	self.xchunks[chunk] = id
	return id
end

--- Handle a "registerLibrary" message from PHP.
-- Add the relevant functions to the base environment.
--
-- @param message The message from PHP
-- @return The response message
function MWServer:handleRegisterLibrary( message )
	local startPos = 1
	local component
	if not self.baseEnv[message.name] then
		self.baseEnv[message.name] = {}
	end
	local t = self.baseEnv[message.name]

	for name, id in pairs( message.functions ) do
		t[name] = function( ... )
			return self:call( id, { ... } )
		end
		-- Protect the function against setfenv()
		self.protectedFunctions[t[name]] = true
	end
	
	return {
		op = 'return',
		values = {}
	}
end

--- Handle a "getStatus" message from PHP
--
-- @param message The request message
-- @return The response message
function MWServer:handleGetStatus( message )
	local nullRet = {
		op = 'return',
		values = {}
	}
	local file = io.open( '/proc/self/stat' )
	if not file then
		return nullRet
	end
	local s = file:read('*a')
	file:close()
	local t = {}
	for token in string.gmatch(s, '[^ ]+') do
		t[#t + 1] = token
	end
	if #t < 22 then
		return nullRet
	end
	return {
		op = 'return',
		values = {{
			pid = tonumber(t[1]),
			time = tonumber(t[14]) + tonumber(t[15]) + tonumber(t[16]) + tonumber(t[17]),
			vsize = tonumber(t[23]),
		}}
	}
end

--- The main request/response loop
--
-- Send a request message and return its matching reply message. Handle any 
-- intervening requests (i.e. re-entrant calls) by dispatching them to the
-- relevant handler function.
--
-- The request message may optionally be omitted, to listen for request messages
-- without first sending a request of its own. Such a dispatch() call will 
-- continue running until termination is requested by PHP. Typically, PHP does 
-- this with a SIGTERM signal.
--
-- @param msgToPhp The message to send to PHP. Optional.
-- @return The matching response message
function MWServer:dispatch( msgToPhp )
	if msgToPhp then
		self:sendMessage( msgToPhp )
	end
	while true do
		local msgFromPhp = self:receiveMessage()
		local msgToPhp
		local op = msgFromPhp.op
		if op == 'return' or op == 'error' then
			return msgFromPhp
		elseif op == 'call' then
			msgToPhp = self:handleCall( msgFromPhp )
			self:sendMessage( msgToPhp )
		elseif op == 'loadString' then
			msgToPhp = self:handleLoadString( msgFromPhp )
			self:sendMessage( msgToPhp )
		elseif op == 'registerLibrary' then
			msgToPhp = self:handleRegisterLibrary( msgFromPhp )
			self:sendMessage( msgToPhp )
		elseif op == 'getStatus' then
			msgToPhp = self:handleGetStatus( msgFromPhp )
			self:sendMessage( msgToPhp )
		elseif op == 'quit' then
			self:debug( 'MWServer:dispatch: quit message received' )
			os.exit(0)
		else
			self:internalError( "Invalid message operation" )
		end
	end
end

--- Write a message to the debug output stream.
-- Some day this may be configurable, currently it just unconditionally writes
-- the message to stderr. The PHP host will redirect those errors to /dev/null
-- by default, but it can be configured to send them to a file.
--
-- @param s The message
function MWServer:debug( s )
	if ( type(s) == 'string' ) then
		io.stderr:write( s .. '\n' )
	else
		io.stderr:write( self:serialize( s ) .. '\n' )
	end
end

--- Raise an internal error
-- Write a message to stderr and then exit with a failure status. This should 
-- be called for errors which cannot be allowed to be caught with pcall(). 
--
-- This must be used for protocol errors, or indeed any error from a context 
-- where a dispatch() call lies between the error source and a possible pcall()
-- handler. If dispatch() were terminated by a regular error() call, the 
-- resulting protocol violation could lead to a deadlock.
--
-- @param msg The error message
function MWServer:internalError( msg )
	io.stderr:write( debug.traceback( msg ) .. '\n' )
	os.exit( 1 )
end

--- Raise an I/O error
-- Helper function for errors from the io and file modules, which may optionally
-- return an informative error message as their second return value.
function MWServer:ioError( header, info )
	if type( info) == 'string' then
		self:internalError( header .. ': ' .. info )
	else
		self:internalError( header )
	end
end

--- Send a message to PHP
-- @param msg The message table
function MWServer:sendMessage( msg )
	if not msg.op then
		self:internalError( "MWServer:sendMessage: invalid message", 2 )
	end
	self:debug('TX ==> ' .. msg.op)
	local encMsg = self:encodeMessage( msg )
	local success, errorMsg = io.stdout:write( encMsg )
	if not success then
		self:ioError( 'Write error', errorMsg )
	end
	io.stdout:flush()
end

--- Wait for a message from PHP and then decode and return it as a table
-- @return The received message
function MWServer:receiveMessage()
	-- Read the header
	local header, errorMsg = io.stdin:read( 16 )
	if header == nil and errorMsg == nil then
		-- End of file on stdin, exit gracefully
		os.exit(0)
	end

	if not header or #header ~= 16 then
		self:ioError( 'Read error', errorMsg )
	end
	local length = self:decodeHeader( header )

	-- Read the body
	local body, errorMsg = io.stdin:read( length )
	if not body then
		self:ioError( 'Read error', errorMsg )
	end
	if #body ~= length then
		self:ioError( 'Read error', errorMsg )
	end

	-- Unserialize it
	msg = self:unserialize( body )
	self:debug('RX <== ' .. msg.op)
	if msg.op == 'error' then
		self:debug( 'Error: ' .. tostring( msg.value ) )
	end
	return msg
end

--- Encode a message for sending to PHP
function MWServer:encodeMessage( message )
	local serialized = self:serialize( message )
	local length = #serialized
	local check = length * 2 - 1
	return string.format( '%08x%08x%s', length, check, serialized )
end

--- Convert a value to a string suitable for passing to PHP's unserialize().
--
-- @param var The value.
function MWServer:serialize( var )
	local done = {}
	local int_min = -2147483648
	local int_max = 2147483647

	local function isInteger( var )
		return type(var) == 'number'
			and math.floor( var ) == var 
			and var >= int_min 
			and var <= int_max
	end

	local function recursiveEncode( var, level )
		local t = type( var )
		if t == 'nil' then
			return 'N;'
		elseif t == 'number' then
			if isInteger(var) then
				return 'i:' .. var .. ';'
			else
				return 'd:' .. var .. ';'
			end
		elseif t == 'string' then
			return 's:' .. string.len( var ) .. ':"' .. var .. '";'
		elseif t == 'boolean' then
			if var then
				return 'b:1;'
			else
				return 'b:0;'
			end
		elseif t == 'table' then
			if done[var] then
				error("Cannot pass circular reference to PHP")
			end
			done[var] = true
			local buf = { '' }
			local tmpString
			local numElements = 0
			for key, value in pairs(var) do
				if (isInteger(key)) then
					buf[#buf + 1] = 'i:' .. key .. ';'
				else
					tmpString = tostring( key )
					buf[#buf + 1] = recursiveEncode( tostring( key ), level + 1 )
				end
				buf[#buf + 1] = recursiveEncode( value, level + 1 )
				numElements = numElements + 1
			end
			buf[1] = 'a:' .. numElements .. ':{'
			buf[#buf + 1] = '}'
			return table.concat(buf)
		elseif t == 'function' then
			local id
			if self.xchunks[var] then
				id = self.xchunks[var]
			else
				id = self:addChunk(var)
			end
			return 'O:42:"Scribunto_LuaStandaloneInterpreterFunction":1:{s:2:"id";i:' .. id .. ';}'
		elseif t == 'thread' then
			error("Cannot pass thread to PHP")
		elseif t == 'userdata' then
			error("Cannot pass userdata to PHP")
		else
			error("Cannot pass unrecognised type to PHP")
		end
	end

	return recursiveEncode( var, 0 )
end

--- Convert a Lua expression string to its corresponding value. 
-- Convert any references of the form chunk[id] to the corresponding function
-- values.
function MWServer:unserialize( text )
	local func = loadstring( 'return ' .. text )
	if not func then
		self:internalError( "MWServer:unserialize: invalid chunk" )
	end
	-- Don't waste JIT cache space by storing every message in it
	if jit then
		jit.off( func )
	end
	setfenv( func, { chunks = self.chunks } )
	return func()
end

--- Decode a message header.
-- @param header The header string
-- @return The body length
function MWServer:decodeHeader( header )
	local length = string.sub( header, 1, 8 )
	local check = string.sub( header, 9, 16 )
	if not string.match( length, '^%x+$' ) or not string.match( check, '^%x+$' ) then
		self:internalError( "Error decoding message header: " .. length .. '/' .. check )
	end
	length = tonumber( length, 16 )
	check = tonumber( check, 16 )
	if length * 2 - 1 ~= check then
		self:internalError( "Error decoding message header" )
	end
	return length
end

--- Create a table to be used as a restricted environment, based on the current 
-- global environment.
--
-- @return The environment table
function MWServer:newEnvironment()
	local allowedGlobals = {
		-- base
		"assert",
		"error",
		"getmetatable",
		"ipairs",
		"next",
		"pairs",
		"pcall",
		"rawequal",
		"rawget",
		"rawset",
		"select",
		"setmetatable",
		"tonumber",
		"type",
		"unpack",
		"xpcall",
		"_VERSION",
		-- libs
		"string",
		"table",
		"math"
	}

	local env = {}
	local i
	for i = 1, #allowedGlobals do
		env[allowedGlobals[i]] = mw.clone( _G[allowedGlobals[i]] )
	end

	env._G = env
	env.tostring = function( val )
		return self:tostring( val )
	end
	env.string.dump = nil
	env.setfenv, env.getfenv = mw.makeProtectedEnvFuncs(
		self.protectedEnvironments, self.protectedFunctions )
	return env
end

--- An implementation of tostring() which does not expose pointers.
function MWServer:tostring(val)
	local mt = getmetatable( val )
	if mt and mt.__tostring then
		return mt.__tostring(val)
	end
	local typeName = type(val)
	local nonPointerTypes = {number = true, string = true, boolean = true, ['nil'] = true}
	if nonPointerTypes[typeName] then
		return tostring(val)
	else
		return typeName
	end
end

return MWServer
