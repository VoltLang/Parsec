// Copyright © 2017, Bernard Helyer.  All rights reserved.
// Copyright © 2017, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module parsec.ir.templates;

import parsec.ir.base;
import parsec.ir.context;
import parsec.ir.type;
import parsec.ir.toplevel;
import parsec.ir.declaration;


enum TemplateKind
{
	Struct,
	Class,
	Union,
	Interface,
	Function
}

/*!
 * Creates a concrete instance of a template.
 *
 * Example:
 *   struct Foo = Bar!i32
 *   fn Foo = Bar!(size_t*, i16)
 *
 * @ingroup irNode irTemplate
 */
class TemplateInstance : Node
{
public:
	TemplateKind kind;
	string name;
	Node[] arguments;  // Either a Type or an Exp.
	bool explicitMixin;
	string[] names;  // Set by the lifter.

public:
	this()
	{
		super(NodeType.TemplateInstance);
	}

	this(TemplateInstance old)
	{
		super(NodeType.TemplateInstance, old);
		this.kind = old.kind;
		this.name = old.name;
		version (Volt) {
			this.arguments = new old.arguments[0 .. $];
			this.names = new old.names[0 .. $];
		} else {
			this.arguments = old.arguments.dup;
			this.names = old.names.dup;
		}
	}
}

class TemplateDefinition : Node
{
public:
	struct Parameter
	{
		Type type;  // Optional, only for value parameters.
		string name;
	}

public:
	TemplateKind kind;
	string name;
	Parameter[] parameters;
	TypeReference[] typeReferences;  //!< Filled in by the gatherer.
	/*!
	 * Only one of these fields will be non-null, depending on kind.
	 * @{
	 */
	Struct _struct;
	Union _union;
	_Interface _interface;
	Class _class;
	Function _function;
	//! @}

public:
	this()
	{
		super(NodeType.TemplateDefinition);
	}

	this(TemplateDefinition old)
	{
		super(NodeType.TemplateDefinition, old);
		this.kind = old.kind;
		this.name = old.name;
		version (Volt) {
			this.parameters = new old.parameters[0 .. $];
		} else {
			this.parameters = old.parameters.dup;
		}
		this._struct = old._struct;
		this._union = old._union;
		this._interface = old._interface;
		this._class = old._class;
		this._function = old._function;
	}
}
