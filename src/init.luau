--!strict
-- Services
-- Packages
local Option = require("@wally/Option")
-- Modules
-- Types
type Option<V> = Option.Option<V>
type JSONValue = string | number | boolean | { [string]: JSONValue } | { JSONValue }
type TraceInfo = {
	Source: string,
	LineNumber: number,
	Function: {
		Name: string,
		ParameterCount: number,
		IsVariadic: number,
		Reference: (...unknown) -> ...unknown,
	},
}

export type ErrorDisplayFormat = "Full" | "Log" | "Header" | "Trace" | "Body" | "JSON"
type ErrorImpl<T, D> = {
	__index: ErrorImpl<T, D>,
	__tostring: (self: Error<T, D>) -> string,
	is: (self: Error<T, D>, t: T) -> boolean,
	display: (self: Error<T, D>, fmt: ErrorDisplayFormat) -> string,
}

type ErrorStruct<T, D> = {
	_Type: T,
	_Title: Option<string>,
	_Description: Option<string>,
	_Body: Option<D>,
	_Trace: Option<{ TraceInfo }>,
}
export type Error<T, D> = typeof(setmetatable({} :: ErrorStruct<T, D>, {} :: ErrorImpl<T, D>))

type ErrorBuilderImpl<T, D> = {
	__index: ErrorBuilderImpl<T, D>,
	title: (self: ErrorBuilder<T, D>, title: string) -> ErrorBuilder<T, D>,
	description: (self: ErrorBuilder<T, D>, desc: string) -> ErrorBuilder<T, D>,
	body: (self: ErrorBuilder<T, D>, body: D) -> ErrorBuilder<T, D>,
	trace: (self: ErrorBuilder<T, D>, trace: { TraceInfo }) -> ErrorBuilder<T, D>,
	build: (self: ErrorBuilder<T, D>) -> Error<T, D>,
}
export type ErrorBuilder<T, D> = typeof(setmetatable({} :: ErrorStruct<T, D>, {} :: ErrorBuilderImpl<T, D>))

-- Constants
local INFO_OPTIONS = "slnaf"
-- Variables
-- References
-- Private Functions

function getTraceInfo(level: number): Option<TraceInfo>
	local source, number, fnName, paramCount, isVariadic, ref = debug.info(level, INFO_OPTIONS)
	if source == nil then
		return Option.none()
	end
	local out = {
		Source = source,
		LineNumber = number,
		Function = {
			Name = fnName,
			ParameterCount = paramCount,
			IsVariadic = isVariadic,
			Reference = ref,
		},
	}
	table.freeze(out.Function)
	table.freeze(out)
	return Option.some(out)
end
function dumpTrace(offset: number): { TraceInfo }
	local index = 1 + offset
	local out = {}
	local trace = getTraceInfo(index)
	while trace:isSome() do
		out[index - offset] = trace:unwrap()
		index += 1
		trace = getTraceInfo(index)
	end
	return out
end
function newErrorStruct<T, D>(
	errorType: T,
	title: Option<string>,
	desc: Option<string>,
	body: Option<D>,
	trace: Option<{ TraceInfo }>
): ErrorStruct<T, D>
	return {
		_Title = title,
		_Type = errorType,
		_Description = desc,
		_Body = body,
		_Trace = trace,
	}
end

-- Class
local ErrorImpl = {} :: ErrorImpl<unknown, unknown>
ErrorImpl.__index = ErrorImpl

function asJson(value: JSONValue | unknown, log: { [any]: true? }?): string
	log = log or {}
	assert(log, `bad log`)
	if type(value) == "string" then
		return '"' .. value:gsub('"', '\\"') .. '"'
	elseif type(value) == "number" then
		if value ~= value then
			return '"NaN"'
		elseif math.abs(value) == math.huge then
			return '"Inf"'
		end
		return tostring(value)
	elseif type(value) == "boolean" then
		return tostring(value)
	elseif type(value) == "table" then
		if log[value] then
			return '"<circular>"'
		end
		log[value] = true
		local meta = getmetatable(value :: any)
		if meta and meta.__tostring and meta ~= ErrorImpl then
			return `"{tostring(value)}"`
		end
		local out = {}
		local isArray = true
		local keyCount = 0
		for k, v in pairs(value :: any) do
			keyCount += 1
			if type(k) ~= "number" then
				isArray = false
				break
			end
		end
		if #(value :: any) == keyCount and isArray then
			for _, v in ipairs(value :: any) do
				table.insert(out, asJson(v, log))
			end
			return "[" .. table.concat(out, ",") .. "]"
		else
			for k, v in pairs(value :: any) do
				if typeof(v) == "table" and v["unwrap"] and (v["_state"] == "S" or v["_state"] == "N") then
					local vOpt: Option<unknown> = v
					if vOpt:isSome() then
						table.insert(out, asJson(tostring(k), log) .. ": " .. asJson(vOpt:unwrap(), log))
					else
						table.insert(out, asJson(tostring(k), log) .. ": null")
					end
					continue
				end
				table.insert(out, asJson(tostring(k), log) .. ":" .. asJson(v, log))
			end
			return "{" .. table.concat(out, ",") .. "}"
		end
	else
		return `"{tostring(value)}"`
	end
end

function ErrorImpl:__tostring()
	return self:display("Full")
end

function ErrorImpl:is(t: unknown): boolean
	return self._Type == t
end

function ErrorImpl:display(fmt: ErrorDisplayFormat): string
	if fmt == "JSON" then
		return asJson(self)
	end

	if fmt == "Log" then
		return self._Trace:match(function(traceList)
			if traceList[1] then
				local trace = traceList[1]
				return `{trace.Source}({trace.LineNumber}): {self._Type}`
			end
			return `{self._Type}`
		end, function()
			return `{self._Type}`
		end)
	end

	local header: string = self._Title:match(function(title)
		return self._Description:match(function(desc)
			return `[{self._Type}]: {title}\n\t{desc}`
		end, function()
			return `[{self._Type}]: {title}`
		end)
	end, function()
		return self._Description:match(function(desc)
			return `[{self._Type}]\n\t{desc}`
		end, function()
			return `[{self._Type}]`
		end)
	end)

	local bodyStr: Option<string> = Option.none()

	if fmt == "Body" or fmt == "Full" then
		bodyStr = self._Body:match(function(body)
			return Option.some(asJson(body))
		end, function()
			return Option.none()
		end)
	end

	local traceStr: Option<string> = Option.none()
	if fmt == "Trace" or fmt == "Full" then
		traceStr = self._Trace:match(function(traceList)
			local array = {}
			for _, trace in ipairs(traceList) do
				table.insert(
					array,
					`\t{trace.Source}{if trace.Function.Name:len() > 0 then "/" .. trace.Function.Name else ""}({trace.LineNumber})`
				)
			end
			return Option.some(table.concat(array, "\n"))
		end, function()
			return Option.none()
		end)
	end

	return bodyStr:match(function(body)
		return traceStr:match(function(trace)
			return `{header}\n\t{body}\n{trace}`
		end, function()
			return `{header}\n\t{body}`
		end)
	end, function()
		return traceStr:match(function(trace)
			return `{header}\n{trace}`
		end, function()
			return `{header}`
		end)
	end)
end

function newError<T, D>(
	errorType: T,
	title: Option<string>,
	desc: Option<string>,
	body: Option<D>,
	trace: Option<{ TraceInfo }>
): Error<T, D>
	local out: Error<T, D> =
		setmetatable(newErrorStruct(errorType, title, desc, body, trace), ErrorImpl) :: any
	table.freeze(out)
	return out
end

-- Builder class
local ErrorBuilder = {} :: ErrorBuilderImpl<unknown, unknown>
ErrorBuilder.__index = ErrorBuilder

function newErrorBuilder<T, D>(
	errorType: T,
	title: Option<string>,
	desc: Option<string>,
	body: Option<D>,
	trace: Option<{ TraceInfo }>
): ErrorBuilder<T, D>
	local out: ErrorBuilder<T, D> =
		setmetatable(newErrorStruct(errorType, title, desc, body, trace), ErrorBuilder) :: any
	table.freeze(out)
	return out
end

function ErrorBuilder:title(title: string)
	return newErrorBuilder(self._Type, Option.some(title), self._Description, self._Body, self._Trace)
end

function ErrorBuilder:description(desc: string)
	return newErrorBuilder(self._Type, self._Title, Option.some(desc), self._Body, self._Trace)
end

function ErrorBuilder:body(body: unknown)
	return newErrorBuilder(self._Type, self._Title, self._Description, Option.some(body), self._Trace)
end

function ErrorBuilder:trace(trace: { TraceInfo })
	return newErrorBuilder(self._Type, self._Title, self._Description, self._Body, Option.some(trace))
end

function ErrorBuilder:build()
	return newError(self._Type, self._Title, self._Description, self._Body, self._Trace)
end

return {
	new = function<T, D>(errorType: T): ErrorBuilder<T, D>
		return newErrorBuilder(
			errorType :: T,
			Option.none(),
			Option.none(),
			Option.none(),
			Option.some(dumpTrace(3))
		)
	end,
	trace = function(offset: number?): { TraceInfo }
		return dumpTrace(offset or 3)
	end :: ((number) -> { TraceInfo }) & (() -> { TraceInfo }),
}
