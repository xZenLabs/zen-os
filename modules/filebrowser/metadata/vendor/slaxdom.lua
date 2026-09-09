-- Optional parser that creates a flat DOM from parsing
local SLAXML = require("modules/filebrowser/metadata/vendor/slaxml")
function SLAXML:dom(xml,opts)
	if not opts then opts={} end
	local rich = not opts.simple
	local push, pop = table.insert, table.remove
	local doc = {type="document", name="#doc", kids={}}
	local current,stack = doc, {doc}
	local builder = SLAXML:parser{
		startElement = function(name,nsURI,nsPrefix)
			local el = { type="element", name=name, kids={}, el=rich and {} or nil, attr={}, nsURI=nsURI, nsPrefix=nsPrefix, parent=rich and current or nil }
			if current==doc then
				if doc.root then error(("Encountered element '%s' when the document already has a root '%s' element"):format(name,doc.root.name)) end
				doc.root = rich and el or nil
			end
			push(current.kids,el)
			if current.el then push(current.el,el) end
			current = el
			push(stack,el)
		end,
		attribute = function(name,value,nsURI,nsPrefix)
			if not current or current.type~="element" then error(("Encountered an attribute %s=%s but I wasn't inside an element"):format(name,value)) end
			local attr = {type='attribute',name=name,nsURI=nsURI,nsPrefix=nsPrefix,value=value,parent=rich and current or nil}
			if rich then current.attr[name] = value end
			push(current.attr,attr)
		end,
		closeElement = function(name)
			if current.name~=name or current.type~="element" then error(("Received a close element notification for '%s' but was inside a '%s' %s"):format(name,current.name,current.type)) end
			pop(stack)
			current = stack[#stack]
		end,
		text = function(value,cdata)
			-- documents may only have text node children that are whitespace: https://www.w3.org/TR/xml/#NT-Misc
			if current.type=='document' and not value:find('^%s+$') then error(("Document has non-whitespace text at root: '%s'"):format(value:gsub('[\r\n\t]',{['\r']='\\r', ['\n']='\\n', ['\t']='\\t'}))) end
			push(current.kids,{type='text',name='#text',cdata=cdata and true or nil,value=value,parent=rich and current or nil})
		end,
		comment = function(value)
			push(current.kids,{type='comment',name='#comment',value=value,parent=rich and current or nil})
		end,
		pi = function(name,value)
			push(current.kids,{type='pi',name=name,value=value,parent=rich and current or nil})
		end
	}
	builder:parse(xml,opts)
	return doc
end

local escmap = {["<"]="&lt;", [">"]="&gt;", ["&"]="&amp;", ['"']="&quot;", ["'"]="&apos;"}
local function esc(s) return s:gsub('[<>&"]', escmap) end

-- opts.indent: number of spaces, or string
function SLAXML:xml(root_node,opts)
	opts = opts or {}
	local out = {}
	local tab = opts.indent and (type(opts.indent)=="number" and string.rep(" ",opts.indent) or opts.indent) or ""
	local ser = {}
	local omit = {}
	if opts.omit then for _i,s in ipairs(opts.omit) do omit[s]=true end end

	function ser.document(n)
		for _i,kid in ipairs(n.kids) do
			if ser[kid.type] then ser[kid.type](kid,0) end
		end
	end

	function ser.pi(n,depth)
		depth = depth or 0
		table.insert(out, tab:rep(depth)..'<?'..n.name..' '..n.value..'?>')
	end

	function ser.element(n,depth)
		if n.nsURI and omit[n.nsURI] then return end
		depth = depth or 0
		local indent = tab:rep(depth)
		local name = n.nsPrefix and n.nsPrefix..':'..n.name or n.name
		local result = indent..'<'..name
		if n.attr and n.attr[1] then
			local sorted = n.attr
			if opts.sort then
				sorted = {}
				for i,a in ipairs(n.attr) do sorted[i]=a end
				table.sort(sorted,function(a,b)
					if a.nsPrefix and b.nsPrefix then
						return a.nsPrefix==b.nsPrefix and a.name<b.name or a.nsPrefix<b.nsPrefix
					elseif not (a.nsPrefix or b.nsPrefix) then
						return a.name<b.name
					elseif b.nsPrefix then
						return true
					else
						return false
					end
				end)
			end

			local attrs = {}
			for _i,a in ipairs(sorted) do
				if (not a.nsURI or not omit[a.nsURI]) and not (omit[a.value] and a.name:find('^xmlns:')) then
					attrs[#attrs+1] = ' '..(a.nsPrefix and (a.nsPrefix..':') or '')..a.name..'="'..esc(a.value)..'"'
				end
			end
			result = result..table.concat(attrs,'')
		end
		result = result .. (n.kids and n.kids[1] and '>' or '/>')
		table.insert(out, result)
		if n.kids and n.kids[1] then
			for _i,kid in ipairs(n.kids) do
				if ser[kid.type] then ser[kid.type](kid,depth+1) end
			end
			table.insert(out, indent..'</'..name..'>')
		end
	end

	function ser.text(n,depth)
		if n.cdata then
			table.insert(out, tab:rep(depth)..'<![CDATA['..n.value..']]>')
		else
			table.insert(out, tab:rep(depth)..esc(n.value))
		end
	end

	function ser.comment(n,depth)
		table.insert(out, tab:rep(depth)..'<!--'..n.value..'-->')
	end

	ser[root_node.type](root_node,0)

	return table.concat(out, opts.indent and '\n' or '')
end

return SLAXML
