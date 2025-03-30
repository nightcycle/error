--!strict
-- Services
-- Packages
local Option = require("@wally/Option")
-- Modules
-- Types
type Option<V> = Option.Option<V>
export type JSONValue = string | number | boolean | { [string]: JSONValue } | { JSONValue }
export type TraceInfo = {
	Source: string,
	LineNumber: number,
	Function: {
		Name: string,
		ParameterCount: number,
		IsVariadic: number,
		Reference: (...unknown) -> ...unknown,
	},
}

export type ErrorDisplayFormat = "Full" | "Log" | "Header" | "Trace" | "Body" | "JSON" | "PrettyJSON"
type ErrorImpl<T, D> = {
	__index: ErrorImpl<T, D>,
	__tostring: (self: any) -> string,
	is: (self: any, t: T) -> boolean,
	display: (self: any, fmt: ErrorDisplayFormat) -> string,
}

type ErrorStruct<T, D> = {
	Type: T,
	Title: Option<string>,
	Description: Option<string>,
	Body: Option<D>,
	Trace: Option<{ TraceInfo }>,
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
local DEFAULT_MAX_TRACE = 16
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
function dumpTrace(offset: number, maxTrace: number): { TraceInfo }
	local index = 1 + offset
	local out = {}
	local trace = getTraceInfo(index)
	while trace:isSome() do
		out[index - offset] = trace:unwrap()
		index += 1
		if index > maxTrace then
			break
		end
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
		Title = title,
		Type = errorType,
		Description = desc,
		Body = body,
		Trace = trace,
	}
end

-- Class
local ErrorImpl = {} :: ErrorImpl<unknown, unknown>
ErrorImpl.__index = ErrorImpl

function toJson(
	value: JSONValue | unknown,
	indent: number?,
	initialIndent: number?,
	log: { [any]: true? }?
): string
	log = log or {}
	assert(log, `bad log`)
	initialIndent = initialIndent or 0
	assert(initialIndent, `bad initialIndent`)
	indent = indent or 0
	assert(indent, `bad indent`)
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
		local meta: { [any]: any? }? = nil
		pcall(function()
			meta = getmetatable(value :: any)
		end)
		if meta and rawget(meta, "__tostring") ~= nil and meta ~= ErrorImpl then
			local str: string?
			local tostringSuccess, _ = pcall(function()
				str = tostring(value)
			end)
			if tostringSuccess then
				return `"{str}"`
			end
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
				table.insert(out, toJson(v, indent, initialIndent + indent, log))
			end
			if indent ~= 0 then
				if #out == 0 then
					return "[]"
				end
				local msg = "["
				for i, row in ipairs(out) do
					msg ..= "\n" .. string.rep(" ", initialIndent + indent) .. row
					if i ~= #out then
						msg ..= ","
					end
				end
				msg ..= "\n" .. string.rep(" ", initialIndent) .. "]"
				return msg
			else
				return "[" .. table.concat(out, ",") .. "]"
			end
		else
			for k, v in pairs(value :: any) do
				if Option.isOption(v) then
					local vOpt: Option<unknown> = v
					if vOpt:isSome() then
						table.insert(
							out,
							toJson(tostring(k), indent, initialIndent + indent, log)
								.. ": "
								.. toJson(vOpt:unwrap(), indent, initialIndent + indent, log)
						)
					else
						table.insert(
							out,
							toJson(tostring(k), indent, initialIndent + indent, log) .. ": null"
						)
					end
					continue
				end
				table.insert(
					out,
					toJson(tostring(k), indent, initialIndent + indent, log)
						.. ": "
						.. toJson(v, indent, initialIndent + indent, log)
				)
			end
			if indent ~= 0 then
				if #out == 0 then
					return "{}"
				end
				local msg = "{"
				for i, row in ipairs(out) do
					msg ..= "\n" .. string.rep(" ", initialIndent + indent) .. row
					if i ~= #out then
						msg ..= ","
					end
				end
				msg ..= "\n" .. string.rep(" ", initialIndent) .. "}"
				return msg
			else
				return "{" .. table.concat(out, ",") .. "}"
			end
		end
	else
		return `"{tostring(value)}"`
	end
end

function ErrorImpl:__tostring()
	return self:display("Full")
end

function ErrorImpl:is(t: unknown): boolean
	return self.Type == t
end

function ErrorImpl:display(fmt: ErrorDisplayFormat): string
	if fmt == "JSON" then
		return toJson(self)
	end
	if fmt == "PrettyJSON" then
		return toJson(self, 4)
	end

	if fmt == "Log" then
		return self.Trace:match(function(traceList)
			if traceList[1] then
				local trace = traceList[1]
				return `{trace.Source}({trace.LineNumber}): {self.Type}`
			end
			return `{self.Type}`
		end, function()
			return `{self.Type}`
		end)
	end

	local header: string = self.Title:match(function(title)
		return self.Description:match(function(desc)
			return `[{self.Type}]: {title}\n\t{desc}`
		end, function()
			return `[{self.Type}]: {title}`
		end)
	end, function()
		return self.Description:match(function(desc)
			return `[{self.Type}]\n\t{desc}`
		end, function()
			return `[{self.Type}]`
		end)
	end)

	local bodyStr: Option<string> = Option.none()

	if fmt == "Body" or fmt == "Full" then
		bodyStr = self.Body:match(function(body)
			return Option.some(toJson(body))
		end, function()
			return Option.none()
		end)
	end

	local traceStr: Option<string> = Option.none()
	if fmt == "Trace" or fmt == "Full" then
		traceStr = self.Trace:match(function(traceList)
			local array = {}
			for _, trace in ipairs(traceList) do
				table.insert(
					array,
					`\t{trace.Source}{if trace.Function.Name:len() > 0
						then "/" .. tostring(trace.Function.Name)
						else ""}({trace.LineNumber})`
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
	return newErrorBuilder(self.Type, Option.some(title), self.Description, self.Body, self.Trace)
end

function ErrorBuilder:description(desc: string)
	return newErrorBuilder(self.Type, self.Title, Option.some(desc), self.Body, self.Trace)
end

function ErrorBuilder:body(body: unknown)
	return newErrorBuilder(self.Type, self.Title, self.Description, Option.some(body), self.Trace)
end

function ErrorBuilder:trace(trace: { TraceInfo })
	if not table.isfrozen(trace) then
		trace = table.clone(trace)
		table.freeze(trace)
	end
	return newErrorBuilder(self.Type, self.Title, self.Description, self.Body, Option.some(trace))
end

function ErrorBuilder:build()
	return newError(self.Type, self.Title, self.Description, self.Body, self.Trace)
end

return {
	new = function<T, D>(errorType: T): ErrorBuilder<T, D>
		return newErrorBuilder(
			errorType :: T,
			Option.none(),
			Option.none(),
			Option.none(),
			Option.some(dumpTrace(3, DEFAULT_MAX_TRACE))
		)
	end,
	isErr = function(value: unknown?): boolean
		if typeof(value) == "table" then
			return getmetatable(value :: any) == ErrorImpl
		end
		return false
	end,
	trace = function(offset: number?, maxTrace: number): { TraceInfo }
		return dumpTrace(3 + (offset or 0), maxTrace or DEFAULT_MAX_TRACE)
	end :: ((number) -> { TraceInfo }) & (() -> { TraceInfo }) & ((offset: number, maxTrace: number) -> { TraceInfo }),
	displayAsJson = toJson :: ((unknown) -> string) & ((unknown, number) -> string),
}
