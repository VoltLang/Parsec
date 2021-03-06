// Copyright © 2012, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module parsec.parser.expression;
// Most of these can pass through to a lower function, see the IR.

import watt.conv : toInt, toUlong, toFloat, toDouble;
import watt.text.utf : decode;

import ir = parsec.ir.ir;
import intir = parsec.parser.intir;
import parsec.ir.copy;
import parsec.ir.util;

import parsec.exceptions;
import parsec.errors;
import parsec.lex.location;
import parsec.lex.token : TokenType;
import parsec.parser.base;
import parsec.parser.declaration;
import parsec.util.string;


ParseStatus parseExp(ParserStream ps, out ir.Exp exp)
{
	intir.AssignExp aexp;
	auto succeeded = parseAssignExp(ps, out aexp);
	if (!succeeded) {
		return parseFailed(ps, ir.NodeType.BinOp);
	}
	succeeded = assignToExp(ps, aexp, out exp);
	if (!succeeded) {
		return parseFailed(ps, ir.NodeType.BinOp);
	}
	return Succeeded;
}

ParseStatus assignToExp(ParserStream ps, intir.AssignExp assign, out ir.Exp exp)
{
	if (assign.op == ir.BinOp.Op.None) {
		ternaryToExp(ps, assign.left, out exp);
		return Succeeded;
	}
	assert(assign.right !is null);
	auto bop = new ir.BinOp();
	bop.loc = assign.loc;
	bop.op = assign.op;
	auto succeeded = ternaryToExp(ps, assign.left, out bop.left);
	if (!succeeded) {
		return parseFailed(ps, bop);
	}
	succeeded = assignToExp(ps, assign.right, out bop.right);
	if (!succeeded) {
		return parseFailed(ps, bop);
	}
	exp = bop;
	return Succeeded;
}

ParseStatus ternaryToExp(ParserStream ps, intir.TernaryExp tern, out ir.Exp exp)
{
	if (tern.ifTrue !is null) {
		auto newTern = new ir.Ternary();
		newTern.loc = tern.loc;
		auto succeeded = binexpToExp(ps, tern.condition, out newTern.condition);
		if (!succeeded) {
			return parseFailed(ps, newTern);
		}
		succeeded = ternaryToExp(ps, tern.ifTrue, out newTern.ifTrue);
		if (!succeeded) {
			return parseFailed(ps, newTern);
		}
		succeeded = ternaryToExp(ps, tern.ifFalse, out newTern.ifFalse);
		if (!succeeded) {
			return parseFailed(ps, newTern);
		}
		exp = newTern;
	} else {
		auto succeeded = binexpToExp(ps, tern.condition, out exp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Ternary);
		}
	}
	return Succeeded;
}

class ExpOrOp
{
	intir.UnaryExp exp;
	ir.BinOp.Op op;
	ir.BinOp bin;

	this(intir.UnaryExp exp)
	{
		this.exp = exp;
	}

	this(ir.BinOp.Op op)
	{
		this.op = op;
	}

	@property bool isExp()
	{
		return exp !is null;
	}
}

ExpOrOp[] gatherExps(intir.BinExp bin)
{
	ExpOrOp[] list;
	while (bin.op != ir.BinOp.Op.None) {
		list ~= new ExpOrOp(bin.left);
		list ~= new ExpOrOp(bin.op);
		bin = bin.right;
	}
	list ~= new ExpOrOp(bin.left);
	return list;
}

ParseStatus binexpToExp(ParserStream ps, intir.BinExp bin, out ir.Exp exp)
{
	// Ladies and gentlemen, Mr. Edsger Dijkstra's shunting-yard algorithm! (polite applause)

	ExpOrOp[] tokens = gatherExps(bin);
	ExpOrOp[] output;
	ir.BinOp.Op[] stack;

	// While there are tokens to be read.
	while (tokens.length > 0) {
		// Read a token.
		auto token = tokens[0];
		tokens = tokens[1 .. $];

		if (token.isExp) {
			// If the token is an expression, add it to the output queue.
			output ~= new ExpOrOp(token.exp);
		} else {
			// If the token is an operator
			auto op1 = token.op;
			// While there is an operator token on the top of the stack
			while (stack.length > 0) {
				// and op1 is left associative and its precedence is <= op2.
				if ((intir.isLeftAssociative(op1) && intir.getPrecedence(op1) <= intir.getPrecedence(stack[0])) || 
					(intir.getPrecedence(op1) < intir.getPrecedence(stack[0]))) {
				// or op1 has precedence < op2) {
					// pop op2 off the stack
					auto op2 = stack[0];
					stack = stack[1 .. $];
					// and onto the output queue.
					output ~= new ExpOrOp(op2); 
				} else {
					break;
				}
			}
			// Push op1 onto the stack.
			stack = op1 ~ stack;
		}
	}

	// When there are no more tokens to read:
	// While there are still operator tokens on the stack.
	while (stack.length > 0) {
		// Pop the operator onto the output queue.
		output ~= new ExpOrOp(stack[0]);
		stack = stack[1 .. $];
	}

	ir.Exp[] expstack;
	while (output.length > 0) {
		if (output[0].isExp) {
			ir.Exp uexp;
			auto succeeded = unaryToExp(ps, output[0].exp, out uexp);
			if (!succeeded) {
				return parseFailed(ps, ir.NodeType.BinOp);
			}
			expstack = uexp ~ expstack;
		} else {
			assert(expstack.length >= 2);
			auto binout = new ir.BinOp();
			binout.loc = expstack[0].loc;
			binout.left = expstack[1];
			binout.right = expstack[0];
			binout.op = output[0].op;
			expstack = expstack[2 .. $];
			expstack = binout ~ expstack;
		}
		output = output[1 .. $];
	}
	assert(expstack.length == 1);
	exp = expstack[0];
	return Succeeded;
}

ParseStatus unaryToExp(ParserStream ps, intir.UnaryExp unary, out ir.Exp exp)
{
	if (unary.runExp !is null) {
		exp = unary.runExp;
		return Succeeded;
	}
	if (unary.op == ir.Unary.Op.None) {
		auto succeeded = postfixToExp(ps, ref unary.loc, out exp, unary.postExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
	} else if (unary.op == ir.Unary.Op.Cast) {
		auto u = new ir.Unary();
		u.loc = unary.castExp.loc;
		u.op = unary.op;
		auto succeeded = unaryToExp(ps, unary.castExp.unaryExp, out u.value);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		u.type = unary.castExp.type;
		exp = u;
	} else if (unary.op == ir.Unary.Op.New) {
		auto u = new ir.Unary();
		u.loc = unary.newExp.loc;
		u.op = unary.op;
		u.type = unary.newExp.type;
		u.hasArgumentList = unary.newExp.hasArgumentList;
		foreach (arg; unary.newExp.argumentList) {
			ir.Exp e;
			auto succeeded = assignToExp(ps, arg, out e);
			if (!succeeded) {
				return parseFailed(ps, u);
			}
			u.argumentList ~= e;
		}
		exp = u;
	} else if (unary.op == ir.Unary.Op.Dup) {
		auto u = new ir.Unary();
		void transformDollar(ref ir.Exp rexp)
		{
			auto bop = cast(ir.BinOp)rexp;
			if (bop !is null) {
				transformDollar(ref bop.left);
				transformDollar(ref bop.right);
				return;
			}
			auto constant = cast(ir.Constant) rexp;
			if (constant is null || constant._string != "$") {
				return;
			}
			rexp = buildPostfixIdentifier(ref rexp.loc, u.value, "length");
		}
		u.loc = unary.dupExp.loc;
		u.op = unary.op;
		auto succeeded = postfixToExp(ps, ref unary.loc, out u.value, unary.dupExp.name);
		auto pfix = cast(ir.Postfix)u.value;
		if (!succeeded || pfix is null) {
			return parseFailed(ps, u);
		}
		u.value = pfix.child;

		u.fullShorthand = unary.dupExp.shorthand;
		succeeded = assignToExp(ps, unary.dupExp.beginning, out u.dupBeginning);
		if (!succeeded) {
			return parseFailed(ps, u);
		}
		succeeded = assignToExp(ps, unary.dupExp.end, out u.dupEnd);
		if (!succeeded) {
			return parseFailed(ps, u);
		}
		transformDollar(ref u.dupBeginning);
		transformDollar(ref u.dupEnd);
		exp = u;
	} else {
		auto u = new ir.Unary();
		u.loc = unary.loc;
		u.op = unary.op;
		auto succeeded = unaryToExp(ps, unary.unaryExp, out u.value);
		if (!succeeded) {
			return parseFailed(ps, u);
		}
		exp = u;
	}
	return Succeeded;
}

ParseStatus postfixToExp(ParserStream ps, ref in Location loc, out ir.Exp exp, intir.PostfixExp postfix, ir.Exp seed = null)
{
	if (seed is null) {
		auto succeeded = primaryToExp(ps, postfix.primary, out seed);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
	}
	if (postfix.op == ir.Postfix.Op.None) {
		exp = seed;
	} else {
		auto p = new ir.Postfix();
		p.loc = loc;
		p.op = postfix.op;
		p.child = seed;
		p.argumentLabels = postfix.labels;
		if (p.op == ir.Postfix.Op.Identifier) {
			assert(postfix.identifier !is null);
			p.identifier = postfix.identifier;
		} else foreach (arg; postfix.arguments) {
			ir.Exp parg;
			auto succeeded = assignToExp(ps, arg, out parg);
			if (!succeeded) {
				return parseFailed(ps, ir.NodeType.Postfix);
			}
			p.arguments ~= parg;
			ir.Postfix.TagKind r;
			if (arg.taggedRef) {
				r = ir.Postfix.TagKind.Ref;
			} else if (arg.taggedOut) {
				r = ir.Postfix.TagKind.Out;
			} else {
				r = ir.Postfix.TagKind.None;
			}
			p.argumentTags ~= r;
		}
		ir.Exp theExp;
		auto succeeded = postfixToExp(ps, ref loc, out theExp, postfix.postfix, p);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
		exp = theExp;
	}
	return Succeeded;
}

// Given 'FFFFFFFFi32', return the suffix, or an empty string.
private string getHexTypeSuffix(string s, out bool error)
{
	if (s.length < 2) {
		return "";
	}
	for (size_t i = 0; i < s.length; ++i) {
		if ((s[i] == 'u' || s[i] == 'i') && i < s.length - 1) {
			if (s[i-1] != '_') {
				error = true;
				return "";
			}
			return s[i .. $];
		}
	}
	return "";
}

ParseStatus primaryToExp(ParserStream ps, intir.PrimaryExp primary, out ir.Exp exp)
{
	switch (primary.op) {
	case intir.PrimaryExp.Type.Identifier:
	case intir.PrimaryExp.Type.DotIdentifier:
		auto i = new ir.IdentifierExp();
		i.globalLookup = primary.op == intir.PrimaryExp.Type.DotIdentifier;
		i.value = primary._string;
		exp = i;
		break;
	case intir.PrimaryExp.Type.This:
		auto i = new ir.IdentifierExp();
		i.value = "this";
		exp = i;
		break;
	case intir.PrimaryExp.Type.Super:
		auto i = new ir.IdentifierExp();
		i.value = "super";
		exp = i;
		break;
	case intir.PrimaryExp.Type.Null:
		auto c = new ir.Constant();
		c.u._pointer = null;
		c.type = new ir.NullType();
		c.isNull = true;
		c.type.loc = primary.loc;
		exp = c;
		break;
	case intir.PrimaryExp.Type.Dollar:
		auto c = new ir.Constant();
		c._string = "$";
		c.type = new ir.PrimitiveType(ir.PrimitiveType.Kind.Uint);
		c.type.loc = primary.loc;
		exp = c;
		break;
	case intir.PrimaryExp.Type.True:
		auto c = new ir.Constant();
		c.u._bool = true;
		c.type = new ir.PrimitiveType(ir.PrimitiveType.Kind.Bool);
		c.type.loc = primary.loc;
		exp = c;
		break;
	case intir.PrimaryExp.Type.False:
		auto c = new ir.Constant();
		c.u._bool = false;
		c.type = new ir.PrimitiveType(ir.PrimitiveType.Kind.Bool);
		c.type.loc = primary.loc;
		exp = c;
		break;
	case intir.PrimaryExp.Type.Typeid:
		auto ti = new ir.Typeid();
		if (primary.exp !is null) {
			ti.exp = primary.exp;
		} else {
			ti.type = primary.type;
		}
		exp = ti;
		break;
	case intir.PrimaryExp.Type.StringLiteral:
		auto c = new ir.Constant();
		c._string = primary._string;
		// c.type = immutable(char)[]
		auto atype = buildArrayType(ref primary.loc, buildPrimitiveType(ref primary.loc, ir.PrimitiveType.Kind.Char));
		atype.base.isImmutable = true;
		c.type = atype;
		assert((c._string[$-1] == '"' || c._string[$-1] == '`') && c._string.length >= 2);
		if (c._string[0] == '`' || c._string[0] == 'r') {
			int start = c._string[0] == '`' ? 1 : 2;
			c.arrayData = cast(immutable(void)[]) c._string[cast(size_t)start .. $-1];
		} else {
			c.arrayData = unescapeString(ref primary.loc, c._string[1 .. $-1]);
		}
		exp = c;
		break;
	case intir.PrimaryExp.Type.CharLiteral:
		auto c = new ir.Constant();
		c._string = primary._string;
		c.type = new ir.PrimitiveType(ir.PrimitiveType.Kind.Char);
		c.type.loc = primary.loc;
		assert(c._string[$-1] == '\'' && c._string.length >= 3);
		c.arrayData = unescapeString(ref primary.loc, c._string[1 .. $-1]);
		if (c.arrayData.length > 1) {
			c.type = new ir.PrimitiveType(ir.PrimitiveType.Kind.Dchar);
			c.type.loc = primary.loc;
			auto str = cast(string) c.arrayData;
			size_t index;
			c.u._ulong = decode(str, ref index);
		}
		exp = c;
		break;
	case intir.PrimaryExp.Type.FloatLiteral:
		auto c = new ir.Constant();
		auto base = ir.PrimitiveType.Kind.Double;
		c._string = primary._string;
		while (c._string[$-1] == 'f' || c._string[$-1] == 'F' ||
			   c._string[$-1] == 'L') {
			if (c._string[$-1] == 'f' || c._string[$-1] == 'F') {
				base = ir.PrimitiveType.Kind.Float;
			} else if (c._string[$-1] == 'L') {
				base = ir.PrimitiveType.Kind.Double;
			}
			c._string = c._string[0 .. $-1];
		}
		if (base == ir.PrimitiveType.Kind.Float) {
			c.u._float = toFloat(removeUnderscores(c._string));
		} else {
			c.u._double = toDouble(removeUnderscores(c._string));
		}
		if (primary.type !is null) {
			c.type = primary.type;
		} else {
			c.type = new ir.PrimitiveType(base);
			c.type.loc = primary.loc;
		}
		exp = c;
		break;
	case intir.PrimaryExp.Type.IntegerLiteral:
		auto c = new ir.Constant();
		c.loc = primary.loc;
		c._string = primary._string;
		auto base = ir.PrimitiveType.Kind.Int;
		bool explicitBase;

		// If there are any suffixes, change the type to match.
		while (c._string[$-1] == 'u' ||
		       c._string[$-1] == 'U' ||
		       c._string[$-1] == 'L') {
			if (c._string[$-1] == 'u' || c._string[$-1] == 'U') {
				explicitBase = true;
				if (base == ir.PrimitiveType.Kind.Long) {
					base = ir.PrimitiveType.Kind.Ulong;
				} else {
					base = ir.PrimitiveType.Kind.Uint;
				}
			} else if (c._string[$-1] == 'L') {
				explicitBase = true;
				if (base == ir.PrimitiveType.Kind.Uint) {
					base = ir.PrimitiveType.Kind.Ulong;
				} else {
					base = ir.PrimitiveType.Kind.Long;
				}
			}
			c._string = c._string[0 .. $-1];
		}

		if (c._string.length > 2 && (c._string[0 .. 2] == "0x" || c._string[0 .. 2] == "0b")) {
			auto prefix = c._string[0 .. 2];
			c._string = c._string[2 .. $];
			bool hex = prefix == "0x";
			if (hex && explicitBase) {
				warningOldStyleHexTypeSuffix(ref c.loc, ps.settings);
			}
			bool error;
			auto typeSuffix = getHexTypeSuffix(c._string, out error);
			if (error) {
				return invalidIntegerLiteral(ps, ref c.loc);
			}
			if (typeSuffix.length > 0) {
				c._string = c._string[0 .. $ - typeSuffix.length];
				explicitBase = true;
			}
			switch (typeSuffix) {
			case "i8":
				base = ir.PrimitiveType.Kind.Byte;
				break;
			case "i16":
				base = ir.PrimitiveType.Kind.Short;
				break;
			case "i32":
				base = ir.PrimitiveType.Kind.Int;
				break;
			case "i64":
				base = ir.PrimitiveType.Kind.Long;
				break;
			case "u8":
				base = ir.PrimitiveType.Kind.Ubyte;
				break;
			case "u16":
				base = ir.PrimitiveType.Kind.Ushort;
				break;
			case "u32":
				base = ir.PrimitiveType.Kind.Uint;
				break;
			case "u64":
				base = ir.PrimitiveType.Kind.Ulong;
				break;
			case "":
				break;
			default:
				return invalidIntegerLiteral(ps, c.loc);
			}
			auto v = toUlong(removeUnderscores(c._string), hex ? 16 : 2);
			if (!explicitBase) {
				if (v <= int.max) {
					base = ir.PrimitiveType.Kind.Int;
				} else if (v <= uint.max) {
					base = ir.PrimitiveType.Kind.Uint;
				} else if (v <= long.max) {
					base = ir.PrimitiveType.Kind.Long;
				} else {
					base = ir.PrimitiveType.Kind.Ulong;
				}
			}
			c.u._ulong = v;
		} else {
			// Checking should have been done in the lexer.
			auto v = toUlong(removeUnderscores(c._string));

			switch (base) with (ir.PrimitiveType.Kind) {
			case Int:
				if (v <= int.max) {
					c.u._int = cast(int)v;
				} else if (!explicitBase) {
					c.u._long = cast(long)v;
				} else {
					return invalidIntegerLiteral(ps, c.loc);
				}
				break;
			case Uint:
				if (v <= uint.max) {
					c.u._uint = cast(uint)v;
				} else if (!explicitBase) {
					c.u._ulong = v;
				} else {
					return invalidIntegerLiteral(ps, c.loc);
				}
				break;
			case Long:
				if (v <= long.max) {
					c.u._long = cast(long)v;
				} else {
					return invalidIntegerLiteral(ps, c.loc);
				}
				break;
			case Ulong:
				c.u._ulong = v;
				break;
			default:
				assert(false);
			}
		}
		c._string = "";
		if (primary.type !is null) {
			c.type = primary.type;
		} else {
			c.type = new ir.PrimitiveType(base);
			c.type.loc = primary.loc;
		}
		exp = c;
		break;
	case intir.PrimaryExp.Type.ParenExp:
		assert(primary.tlargs.length == 1);
		auto succeeded = assignToExp(ps, primary.tlargs[0], out exp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Invalid);
		}
		break;
	case intir.PrimaryExp.Type.ArrayLiteral:
		auto c = new ir.ArrayLiteral();
		foreach (arg; primary.arguments) {
			ir.Exp e;
			auto succeeded = assignToExp(ps, arg, out e);
			if (!succeeded) {
				return parseFailed(ps, c);
			}
			c.exps ~= e;
		}
		exp = c;
		break;
	case intir.PrimaryExp.Type.AssocArrayLiteral:
		auto c = new ir.AssocArray();
		for (size_t i = 0; i < primary.keys.length; ++i) {
			ir.Exp k, v;
			auto succeeded = assignToExp(ps, primary.keys[i], out k);
			if (!succeeded) {
				return parseFailed(ps, c);
			}
			succeeded = assignToExp(ps, primary.arguments[i], out v);
			if (!succeeded) {
				return parseFailed(ps, c);
			}
			c.pairs ~= new ir.AAPair(k, v);
			c.pairs[$-1].loc = primary.keys[i].loc;
		}
		exp = c;
		break;
	case intir.PrimaryExp.Type.Assert:
		auto c = new ir.Assert();
		auto succeeded = assignToExp(ps, primary.arguments[0], out c.condition);
		if (!succeeded) {
			return parseFailed(ps, c);
		}
		if (primary.arguments.length >= 2) {
			succeeded = assignToExp(ps, primary.arguments[1], out c.message);
			if (!succeeded) {
				return parseFailed(ps, c);
			}
		}
		exp = c;
		break;
	case intir.PrimaryExp.Type.Import:
		auto c = new ir.StringImport();
		auto succeeded = assignToExp(ps, primary.arguments[0], out c.filename);
		if (!succeeded) {
			return parseFailed(ps, c);
		}
		exp = c;
		break;
	case intir.PrimaryExp.Type.Is:
		exp = primary.isExp;
		return Succeeded;
	case intir.PrimaryExp.Type.FunctionLiteral:
		exp = primary.functionLiteral;
		return Succeeded;
	case intir.PrimaryExp.Type.StructLiteral:
		auto lit = new ir.StructLiteral();
		foreach (bexp; primary.arguments) {
			ir.Exp e;
			auto succeeded = assignToExp(ps, bexp, out e);
			if (!succeeded) {
				return parseFailed(ps, lit);
			}
			lit.exps ~= e;
		}
		exp = lit;
		break;
	case intir.PrimaryExp.Type.Type:
		auto te = new ir.TypeExp();
		te.type = primary.type;
		te.loc = primary.loc;
		auto pfix = new ir.Postfix();
		pfix.op = ir.Postfix.Op.Identifier;
		pfix.child = te;
		pfix.identifier = new ir.Identifier();
		pfix.identifier.loc = primary.loc;
		pfix.identifier.value = primary._string;
		exp = pfix;
		break;
	case intir.PrimaryExp.Type.FunctionName:
		exp = new ir.TokenExp(ir.TokenExp.Type.Function);
		break;
	case intir.PrimaryExp.Type.PrettyFunctionName:
		exp = new ir.TokenExp(ir.TokenExp.Type.PrettyFunction);
		break;
	case intir.PrimaryExp.Type.File:
		exp = new ir.TokenExp(ir.TokenExp.Type.File);
		break;
	case intir.PrimaryExp.Type.Line:
		exp = new ir.TokenExp(ir.TokenExp.Type.Line);
		break;
	case intir.PrimaryExp.Type.Location:
		exp = new ir.TokenExp(ir.TokenExp.Type.Location);
		break;
	case intir.PrimaryExp.Type.VaArg:
		exp = primary.vaexp;
		break;
	default:
		return parsePanic(ps, primary.loc, ir.NodeType.Invalid, "unhandled primary expression.");
	}

	exp.loc = primary.loc;
	return Succeeded;
}

private ParseStatus _parseArgumentList(ParserStream ps, out intir.AssignExp[] pexps, TokenType endChar = TokenType.CloseParen)
{
	while (ps.peek.type != endChar) {
		if (ps.peek.type == TokenType.End) {
			return parseExpected(ps, ps.peek.loc, ir.NodeType.Postfix, "end of argument list");
		}
		intir.AssignExp e;
		auto succeeded = parseAssignExp(ps, out e);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
		pexps ~= e;
		if (ps.peek.type != endChar) {
			succeeded = match(ps, ir.NodeType.Postfix, TokenType.Comma);
			if (!succeeded) {
				return succeeded;
			}
		}
	}

	return Succeeded;
}

private ParseStatus _parseArgumentList(ParserStream ps, out intir.AssignExp[] pexps, ref string[] labels, TokenType endChar = TokenType.CloseParen)
{
	while (ps.peek.type != endChar) {
		if (ps.peek.type == TokenType.End) {
			return unexpectedToken(ps, ir.NodeType.Postfix);
		}
		if (ps.peek.type == TokenType.Identifier && ps.lookahead(1).type == TokenType.Colon) {
			auto ident = ps.get();
			labels ~= ident.value;
			if (ps != TokenType.Colon) {
				return unexpectedToken(ps, ir.NodeType.Postfix);
			}
			ps.get();
		}
		intir.AssignExp e;
		auto succeeded = parseAssignExp(ps, out e);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
		pexps ~= e;
		if (ps.peek.type != endChar) {
			if (ps != TokenType.Comma) {
				return unexpectedToken(ps, ir.NodeType.Postfix);
			}
			ps.get();
		}
	}

	if (labels.length != 0 && labels.length != pexps.length) {
		// TODO the loc should be better
		return allArgumentsMustBeLabelled(ps, ps.peek.loc);
	}

	return Succeeded;
}

// Parse an argument list from ps. Will end with ps.peek == endChar.
ParseStatus parseArgumentList(ParserStream ps, out ir.Exp[] outexps, TokenType endChar = TokenType.CloseParen)
{
	intir.AssignExp[] pexps;
	auto succeeded = _parseArgumentList(ps, out pexps, out endChar);
	if (!succeeded) {
		return parseFailed(ps, ir.NodeType.Postfix);
	}

	foreach (exp; pexps) {
		ir.Exp e;
		succeeded = assignToExp(ps, exp, out e);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
		outexps ~= e;
	}
	assert(pexps.length == outexps.length);

	return Succeeded;
}

ParseStatus parseIsExp(ParserStream ps, out ir.IsExp ie)
{
	ie = new ir.IsExp();
	ie.loc = ps.peek.loc;

	auto succeeded = match(ps, ir.NodeType.IsExp, [TokenType.Is, TokenType.OpenParen]);
	if (!succeeded) {
		return succeeded;
	}
	succeeded = parseType(ps, out ie.type);
	if (!succeeded) {
		return parseFailed(ps, ie);
	}

	do switch (ps.peek.type) with (TokenType) {
		case CloseParen:
			break;
		case Identifier:
			succeeded = parseType(ps, out ie.specType);
			if (!succeeded) {
				return parseFailed(ps, ie);
			}
			ie.specialisation = ir.IsExp.Specialisation.Type;
			return match(ps, ie, TokenType.CloseParen);
		case Colon:
			if (ie.compType != ir.IsExp.Comparison.None) {
				return parseExpected(ps, ps.peek.loc, ir.NodeType.Identifier, "is expression");
			}
			ps.get();
			ie.compType = ir.IsExp.Comparison.Implicit;
			break;
		case DoubleAssign:
			if (ie.compType != ir.IsExp.Comparison.None) {
				return parseExpected(ps, ps.peek.loc, ir.NodeType.Identifier, "is expression");
			}
			ps.get();
			ie.compType = ir.IsExp.Comparison.Exact;
			break;
		default:
			if (ie.compType == ir.IsExp.Comparison.None) {
				return parseExpected(ps, ps.peek.loc, ir.NodeType.Identifier, "'==' or ':'");
			}
			switch (ps.peek.type) {
			case Struct, Union, Class, Enum, Interface, Function,
				 Delegate, Super, Const, Immutable, Inout, Shared,
				 Return:
				if (ps.lookahead(1).type != CloseParen) {
					goto default;
				}
				ie.specialisation = cast(ir.IsExp.Specialisation) ps.peek.type;
				ps.get();
				break;
			default:
				ie.specialisation = ir.IsExp.Specialisation.Type;
				succeeded = parseType(ps, out ie.specType);
				if (!succeeded) {
					return parseFailed(ps, ie);
				}
				break;
			}
			break;
	} while (ps.peek.type != TokenType.CloseParen);
	return match(ps, ie, TokenType.CloseParen);
}

ParseStatus parseFunctionLiteral(ParserStream ps, out ir.FunctionLiteral fl)
{
	fl = new ir.FunctionLiteral();
	fl.loc = ps.peek.loc;

	switch (ps.peek.type) {
	case TokenType.Function:
		ps.get();
		fl.isDelegate = false;
		break;
	case TokenType.Delegate:
		ps.get();
		fl.isDelegate = true;
		break;
	case TokenType.Identifier:
		fl.isDelegate = true;
		auto nameTok = ps.get();
		fl.singleLambdaParam = nameTok.value;
		auto succeeded = match(ps, ir.NodeType.Function, [TokenType.Assign, TokenType.Greater]);
		if (!succeeded) {
			return succeeded;
		}
		succeeded = parseExp(ps, out fl.lambdaExp);
		if (!succeeded) {
			return parseFailed(ps, fl);
		}
		return Succeeded;
	default:
		fl.isDelegate = true;
		break;
	}

	if (ps.peek.type != TokenType.OpenParen) {
		auto succeeded = parseType(ps, out fl.returnType);
		if (!succeeded) {
			return parseFailed(ps, fl);
		}
	}

	if (ps != TokenType.OpenParen) {
		return unexpectedToken(ps, fl);
	}
	ps.get();
	while (ps.peek.type != TokenType.CloseParen) {
		auto param = new ir.FunctionParameter();
		param.loc = ps.peek.loc;
		auto succeeded = parseType(ps, out param.type);
		if (!succeeded) {
			return parseFailed(ps, fl);
		}
		if (ps.peek.type == TokenType.Identifier) {
			auto nameTok = ps.get();
			param.name = nameTok.value;
		}
		fl.params ~= param;
		if (ps != TokenType.Comma) {
			return unexpectedToken(ps, fl);
		}
		ps.get();
	}
	ps.get();  // CloseParen

	if (ps.peek.type == TokenType.Assign) {
		if (!fl.isDelegate || fl.returnType !is null) {
			parseExpected(ps, ps.peek.loc, fl, "lambda expression");
			ps.neverIgnoreError = true;
			return Failed;
		}
		auto succeeded = match(ps, ir.NodeType.Function, [TokenType.Assign, TokenType.Greater]);
		if (!succeeded) {
			return succeeded;
		}
		succeeded = parseExp(ps, out fl.lambdaExp);
		if (!succeeded) {
			return parseFailed(ps, fl);
		}
		return Succeeded;
	} else {
		auto succeeded = parseBlock(ps, out fl.block);
		if (!succeeded) {
			return parseFailed(ps, fl);
		}
		return Succeeded;
	}
}

/*!* ugly intir stuff ***/

ParseStatus parseAssignExp(ParserStream ps, out intir.AssignExp exp)
{
	exp = new intir.AssignExp();
	exp.taggedRef = matchIf(ps, TokenType.Ref);
	if (!exp.taggedRef) {
		exp.taggedOut = matchIf(ps, TokenType.Out);
	}
	auto origin = ps.peek.loc;
	auto succeeded = parseTernaryExp(ps, out exp.left);
	if (!succeeded) {
		return parseFailed(ps, ir.NodeType.BinOp);
	}
	switch (ps.peek.type) {
	case TokenType.Assign:
		exp.op = ir.BinOp.Op.Assign; break;
	case TokenType.PlusAssign:
		exp.op = ir.BinOp.Op.AddAssign; break;
	case TokenType.DashAssign:
		exp.op = ir.BinOp.Op.SubAssign; break;
	case TokenType.AsterixAssign:
		exp.op = ir.BinOp.Op.MulAssign; break;
	case TokenType.SlashAssign:
		exp.op = ir.BinOp.Op.DivAssign; break;
	case TokenType.PercentAssign:
		exp.op = ir.BinOp.Op.ModAssign; break;
	case TokenType.AmpersandAssign:
		exp.op = ir.BinOp.Op.AndAssign; break;
	case TokenType.PipeAssign:
		exp.op = ir.BinOp.Op.OrAssign; break;
	case TokenType.CaretAssign:
		exp.op = ir.BinOp.Op.XorAssign; break;
	case TokenType.TildeAssign:
		exp.op = ir.BinOp.Op.CatAssign; break;
	case TokenType.DoubleLessAssign:
		exp.op = ir.BinOp.Op.LSAssign; break;
	case TokenType.DoubleGreaterAssign:
		exp.op = ir.BinOp.Op.SRSAssign; break;
	case TokenType.TripleGreaterAssign:
		exp.op = ir.BinOp.Op.RSAssign; break;
	case TokenType.DoubleCaretAssign:
		exp.op = ir.BinOp.Op.PowAssign; break;
	default:
		exp.op = ir.BinOp.Op.None; break;
	}
	if (exp.op != ir.BinOp.Op.None) {
		ps.get();
		succeeded = parseAssignExp(ps, out exp.right);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.BinOp);
		}
	}
	exp.loc = ps.peek.loc - origin;
	return Succeeded;
}

ParseStatus parseTernaryExp(ParserStream ps, out intir.TernaryExp exp)
{
	exp = new intir.TernaryExp();
	auto origin = ps.peek.loc;
	auto succeeded = parseBinExp(ps, out exp.condition);
	if (!succeeded) {
		return parseFailed(ps, ir.NodeType.Ternary);
	}
	if (ps.peek.type == TokenType.QuestionMark) {
		ps.get();
		exp.isTernary = true;
		succeeded = parseTernaryExp(ps, out exp.ifTrue);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Ternary);
		}
		if (ps != TokenType.Colon) {
			return unexpectedToken(ps, ir.NodeType.Ternary);
		}
		ps.get();
		succeeded = parseTernaryExp(ps, out exp.ifFalse);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Ternary);
		}
	}
	exp.loc = ps.peek.loc - origin;

	return Succeeded;
}

ParseStatus parseBinExp(ParserStream ps, out intir.BinExp exp)
{
	exp = new intir.BinExp();
	exp.loc = ps.peek.loc;
	auto succeeded = parseUnaryExp(ps, out exp.left);
	if (!succeeded) {
		return parseFailed(ps, ir.NodeType.BinOp);
	}

	switch (ps.peek.type) {
	case TokenType.Bang:
		if (ps.lookahead(1).type == TokenType.Is) {
			ps.get();
			exp.op = ir.BinOp.Op.NotIs;
		} else if (ps.lookahead(1).type == TokenType.In) {
			ps.get();
			exp.op = ir.BinOp.Op.NotIn;
		} else {
			goto default;
		}
		break;
	case TokenType.DoublePipe:
		exp.op = ir.BinOp.Op.OrOr; break;
	case TokenType.DoubleAmpersand:
		exp.op = ir.BinOp.Op.AndAnd; break;
	case TokenType.Pipe:
		exp.op = ir.BinOp.Op.Or; break;
	case TokenType.Caret:
		exp.op = ir.BinOp.Op.Xor; break;
	case TokenType.Ampersand:
		exp.op = ir.BinOp.Op.And; break;
	case TokenType.Is:
		exp.op = ir.BinOp.Op.Is; break;
	case TokenType.In:
		exp.op = ir.BinOp.Op.In; break;
	case TokenType.Less:
		exp.op = ir.BinOp.Op.Less; break;
	case TokenType.LessAssign:
		exp.op = ir.BinOp.Op.LessEqual; break;
	case TokenType.Greater:
		exp.op = ir.BinOp.Op.Greater; break;
	case TokenType.GreaterAssign:
		exp.op = ir.BinOp.Op.GreaterEqual; break;
	case TokenType.DoubleLess:
		exp.op = ir.BinOp.Op.LS; break;
	case TokenType.DoubleGreater:
		exp.op = ir.BinOp.Op.SRS; break;
	case TokenType.TripleGreater:
		exp.op = ir.BinOp.Op.RS; break;
	case TokenType.Plus:
		exp.op = ir.BinOp.Op.Add; break;
	case TokenType.Dash:
		exp.op = ir.BinOp.Op.Sub; break;
	case TokenType.Tilde:
		exp.op = ir.BinOp.Op.Cat; break;
	case TokenType.Slash:
		exp.op = ir.BinOp.Op.Div; break;
	case TokenType.Asterix:
		exp.op = ir.BinOp.Op.Mul; break;
	case TokenType.Percent:
		exp.op = ir.BinOp.Op.Mod; break;
	case TokenType.DoubleCaret:
		exp.op = ir.BinOp.Op.Pow; break;
	case TokenType.DoubleAssign:
		exp.op = ir.BinOp.Op.Equal; break;
	case TokenType.BangAssign:
		exp.op = ir.BinOp.Op.NotEqual; break;
	default:
		exp.op = ir.BinOp.Op.None; break;
	}
	if (exp.op != ir.BinOp.Op.None) {
		ps.get();
		succeeded = parseBinExp(ps, out exp.right);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.BinOp);
		}
	}

	exp.loc.spanTo(ref ps.previous.loc);
	return Succeeded;
}

ParseStatus parseUnaryExp(ParserStream ps, out intir.UnaryExp exp)
{
	exp = new intir.UnaryExp();
	auto origin = ps.peek.loc;
	switch (ps.peek.type) {
	case TokenType.Ampersand:
		ps.get();
		exp.op = ir.Unary.Op.AddrOf;
		auto succeeded = parseUnaryExp(ps, out exp.unaryExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		break;
	case TokenType.DoublePlus:
		ps.get();
		exp.op = ir.Unary.Op.Increment;
		auto succeeded = parseUnaryExp(ps, out exp.unaryExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		break;
	case TokenType.DoubleDash:
		ps.get();
		exp.op = ir.Unary.Op.Decrement;
		auto succeeded = parseUnaryExp(ps, out exp.unaryExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		break;
	case TokenType.Asterix:
		ps.get();
		exp.op = ir.Unary.Op.Dereference;
		auto succeeded = parseUnaryExp(ps, out exp.unaryExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		break;
	case TokenType.Dash:
		ps.get();
		exp.op = ir.Unary.Op.Minus;
		auto succeeded = parseUnaryExp(ps, out exp.unaryExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		break;
	case TokenType.Plus:
		ps.get();
		exp.op = ir.Unary.Op.Plus;
		auto succeeded = parseUnaryExp(ps, out exp.unaryExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		break;
	case TokenType.Bang:
		ps.get();
		exp.op = ir.Unary.Op.Not;
		auto succeeded = parseUnaryExp(ps, out exp.unaryExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		break;
	case TokenType.Tilde:
		ps.get();
		exp.op = ir.Unary.Op.Complement;
		auto succeeded = parseUnaryExp(ps, out exp.unaryExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		break;
	case TokenType.Cast:
		exp.op = ir.Unary.Op.Cast;
		auto succeeded = parseCastExp(ps, out exp.castExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		break;
	case TokenType.New:
		auto succeeded = parseNewOrDup(ps, ref exp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		break;
	case TokenType.HashRun:
		auto succeeded = parseRunExp(ps, out exp.runExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		break;
	default:
		auto succeeded = parsePostfixExp(ps, out exp.postExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
	}
	exp.loc = ps.peek.loc - origin;

	return Succeeded;
}

intir.PostfixExp getLastSlice(intir.PostfixExp pe)
{
	intir.PostfixExp current = pe, old;
	do {
		old = current;
		current = current.postfix;
	} while (current !is null && current.op != ir.Postfix.Op.None);
	if (old is null || old.op != ir.Postfix.Op.Slice) {
		return null;
	}
	return old;
}

ParseStatus parseNewOrDup(ParserStream ps, ref intir.UnaryExp exp)
{
	auto mark = ps.save();

	bool parseNew = true;
	auto succeeded = match(ps, ir.NodeType.Unary, TokenType.New);
	if (!succeeded) {
		return succeeded;
	}
	intir.PostfixExp dummy;
	succeeded = parsePostfixExp(ps, out dummy, true);
	auto lastSlice = getLastSlice(dummy);
	if (succeeded && lastSlice !is null) {
		parseNew = false;
	}
	ps.restore(mark);

	if (parseNew) {
		exp.op = ir.Unary.Op.New;
		succeeded = parseNewExp(ps, out exp.newExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
	} else {
		exp.op = ir.Unary.Op.Dup;
		succeeded = parseDupExp(ps, 0, out exp.dupExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
	}

	return Succeeded;
}

// Wrap a PrimaryExp in a TernaryExp.
private intir.AssignExp toAssign(intir.PrimaryExp exp)
{
	auto t = new intir.AssignExp();
	t.loc = exp.loc;
	t.left = new intir.TernaryExp();
	t.left.loc = exp.loc;
	t.left.condition = new intir.BinExp();
	t.left.condition.loc = exp.loc;
	t.left.condition.left = new intir.UnaryExp();
	t.left.condition.left.loc = exp.loc;
	t.left.condition.left.postExp = new intir.PostfixExp();
	t.left.condition.left.postExp.loc = exp.loc;
	t.left.condition.left.postExp.primary = exp;
	return t;
}

ParseStatus parseDupExp(ParserStream ps, int doubleDotDepth, out intir.DupExp dupExp)
{
	auto succeeded = checkToken(ps, ir.NodeType.Unary, TokenType.New);
	if (!succeeded) {
		return succeeded;
	}
	auto start = ps.get();

	dupExp = new intir.DupExp();
	succeeded = parsePostfixExp(ps, out dupExp.name, true);
	if (!succeeded) {
		return parseFailed(ps, ir.NodeType.Postfix);
	}
	auto slice = getLastSlice(dupExp.name);
	if (slice is null) {
		return parseFailed(ps, ir.NodeType.Postfix);
	}
	if (dupExp.name.arguments.length == 0) {
		auto beginning = new intir.PrimaryExp();
		beginning.loc = ps.peek.loc;
		beginning._string = "0";
		beginning.op = intir.PrimaryExp.Type.IntegerLiteral;
		auto end = new intir.PrimaryExp();
		end.loc = ps.peek.loc;
		end.op = intir.PrimaryExp.Type.Dollar;
		dupExp.beginning = toAssign(beginning);
		dupExp.end = toAssign(end);
		dupExp.shorthand = true;
	} else if (slice.arguments.length == 2) {
		// new foo[a..b];
		dupExp.beginning = slice.arguments[0];
		dupExp.end = slice.arguments[1];
	} else {
		return parseFailed(ps, ir.NodeType.Postfix);
	}
	return Succeeded;
}

ParseStatus parseNewExp(ParserStream ps, out intir.NewExp newExp)
{
	Token start;
	auto succeeded = match(ps, ir.NodeType.Unary, TokenType.New, out start);
	if (!succeeded) {
		return succeeded;
	}

	newExp = new intir.NewExp();
	if (ps.peek.type == TokenType.Auto) {
		auto at = new ir.AutoType();
		at.loc = ps.peek.loc;
		ps.get();
		newExp.type = at;
	} else {
		succeeded = parseType(ps, out newExp.type);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
	}

	if (matchIf(ps, TokenType.OpenParen)) {
		newExp.hasArgumentList = true;
		succeeded = _parseArgumentList(ps, out newExp.argumentList);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Unary);
		}
		succeeded = match(ps, ir.NodeType.Unary, TokenType.CloseParen);
		if (!succeeded) {
			return succeeded;
		}
	}

	newExp.loc = ps.peek.loc - start.loc;
	return Succeeded;
}

ParseStatus parseCastExp(ParserStream ps, out intir.CastExp exp)
{
	if (ps != [TokenType.Cast, TokenType.OpenParen]) {
		return unexpectedToken(ps, ir.NodeType.Unary);
	}
	auto start = ps.get();
	ps.get();

	exp = new intir.CastExp();
	auto succeeded = parseType(ps, out exp.type);
	if (!succeeded) {
		return parseFailed(ps, ir.NodeType.Unary);
	}

	Token stop;
	succeeded = match(ps, ir.NodeType.Unary, TokenType.CloseParen, out stop);
	if (!succeeded) {
		return succeeded;
	}
	exp.loc = stop.loc - start.loc;

	succeeded = parseUnaryExp(ps, out exp.unaryExp);
	if (!succeeded) {
		return parseFailed(ps, ir.NodeType.Unary);
	}

	return Succeeded;
}

ParseStatus parsePostfixExp(ParserStream ps, out intir.PostfixExp exp, bool disableNoDoubleDotSlice=false, int depth=0)
{
	depth++;
	exp = new intir.PostfixExp();
	auto origin = ps.peek.loc;
	if (depth == 1) {
		auto succeeded = parsePrimaryExp(ps, out exp.primary);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
	}

	switch (ps.peek.type) {
	case TokenType.Dot:
		ps.get();
		auto twoAhead = ps.lookahead(2).type;
		if (ps.lookahead(1).type == TokenType.Bang &&
			twoAhead != TokenType.Is && twoAhead != TokenType.Assign) {
			auto succeeded = parseExp(ps, out exp.templateInstance);
			if (!succeeded) {
				return parseFailed(ps, ir.NodeType.Postfix);
			}
			break;
		}
		auto succeeded = parseIdentifier(ps, out exp.identifier);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
		exp.op = ir.Postfix.Op.Identifier;
		succeeded = parsePostfixExp(ps, out exp.postfix, disableNoDoubleDotSlice, depth);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
		break;
	case TokenType.DoublePlus:
		ps.get();
		exp.op = ir.Postfix.Op.Increment;
		auto succeeded = parsePostfixExp(ps, out exp.postfix, disableNoDoubleDotSlice, depth);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
		break;
	case TokenType.DoubleDash:
		ps.get();
		exp.op = ir.Postfix.Op.Decrement;
		auto succeeded = parsePostfixExp(ps, out exp.postfix, disableNoDoubleDotSlice, depth);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
		break;
	case TokenType.OpenParen:
		ps.get();
		auto succeeded = _parseArgumentList(ps, out exp.arguments, ref exp.labels);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
		succeeded = match(ps, ir.NodeType.Postfix, TokenType.CloseParen);
		if (!succeeded) {
			return succeeded;
		}
		exp.op = ir.Postfix.Op.Call;
		succeeded = parsePostfixExp(ps, out exp.postfix, disableNoDoubleDotSlice, depth);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
		break;
	case TokenType.OpenBracket:
		ps.get();
		if ((!disableNoDoubleDotSlice && ps == TokenType.CloseBracket) ||
		    ps == [TokenType.DoubleDot, TokenType.CloseBracket]) {
		    	if (ps == TokenType.DoubleDot) {
				ps.get();
			}
			exp.op = ir.Postfix.Op.Slice;
		} else {
			intir.AssignExp e;
			auto succeeded = parseAssignExp(ps, out e);
			if (!succeeded) {
				return parseFailed(ps, ir.NodeType.Postfix);
			}
			exp.arguments ~= e;
			if (ps.peek.type == TokenType.DoubleDot) {
				exp.op = ir.Postfix.Op.Slice;
				ps.get();
				succeeded = parseAssignExp(ps, out e);
				if (!succeeded) {
					return parseFailed(ps, ir.NodeType.Postfix);
				}
				exp.arguments ~= e;
			} else {
				exp.op = ir.Postfix.Op.Index;
				if (ps.peek.type == TokenType.Comma) {
					ps.get();
				}
				intir.AssignExp[] aexps;
				succeeded = _parseArgumentList(ps, out aexps, TokenType.CloseBracket);
				exp.arguments ~= aexps;
				if (!succeeded) {
					return parseFailed(ps, ir.NodeType.Postfix);
				}
			}
		}
		auto succeeded = match(ps, ir.NodeType.Postfix, TokenType.CloseBracket);
		if (!succeeded) {
			return succeeded;
		}
		succeeded = parsePostfixExp(ps, out exp.postfix, disableNoDoubleDotSlice, depth);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Postfix);
		}
		break;
	default:
		break;
	}

	return Succeeded;
}

ParseStatus parsePrimaryExp(ParserStream ps, out intir.PrimaryExp exp)
{
	exp = new intir.PrimaryExp();
	auto origin = ps.peek.loc;
	switch (ps.peek.type) {
	case TokenType.Identifier:
		if (ps == [TokenType.Identifier, TokenType.Assign, TokenType.Greater]) {
			goto case TokenType.Delegate;
		}
		auto token = ps.get();
		exp._string = token.value;
		exp.op = intir.PrimaryExp.Type.Identifier;
		break;
	case TokenType.Dot:
		ps.get();
		Token token;  // token
		auto succeeded = match(ps, ir.NodeType.IdentifierExp, TokenType.Identifier, out token);
		if (!succeeded) {
			return succeeded;
		}
		exp._string = token.value;
		exp.op = intir.PrimaryExp.Type.DotIdentifier;
		break;
	case TokenType.This:
		ps.get();
		exp.op = intir.PrimaryExp.Type.This;
		break;
	case TokenType.Super:
		ps.get();
		exp.op = intir.PrimaryExp.Type.Super;
		break;
	case TokenType.Null:
		ps.get();
		exp.op = intir.PrimaryExp.Type.Null;
		break;
	case TokenType.True:
		ps.get();
		exp.op = intir.PrimaryExp.Type.True;
		break;
	case TokenType.False:
		ps.get();
		exp.op = intir.PrimaryExp.Type.False;
		break;
	case TokenType.Dollar:
		ps.get();
		exp.op = intir.PrimaryExp.Type.Dollar;
		break;
	case TokenType.IntegerLiteral:
		auto token = ps.get();
		exp._string = token.value;
		exp.op = intir.PrimaryExp.Type.IntegerLiteral;
		break;
	case TokenType.FloatLiteral:
		auto token = ps.get();
		exp._string = token.value;
		exp.op = intir.PrimaryExp.Type.FloatLiteral;
		break;
	case TokenType.StringLiteral:
		auto token = ps.get();
		exp._string = token.value;
		exp.op = intir.PrimaryExp.Type.StringLiteral;
		break;
	case TokenType.__File__:
		auto token = ps.get();
		exp.op = intir.PrimaryExp.Type.File;
		break;
	case TokenType.__Line__:
		auto token = ps.get();
		exp.op = intir.PrimaryExp.Type.Line;
		break;
	case TokenType.__Function__:
		auto token = ps.get();
		exp.op = intir.PrimaryExp.Type.FunctionName;
		break;
	case TokenType.__Pretty_Function__:
		auto token = ps.get();
		exp.op = intir.PrimaryExp.Type.PrettyFunctionName;
		break;
	case TokenType.__Location__:
		auto token = ps.get();
		exp.op = intir.PrimaryExp.Type.Location;
		break;
	case TokenType.CharacterLiteral:
		auto token = ps.get();
		exp._string = token.value;
		exp.op = intir.PrimaryExp.Type.CharLiteral;
		break;
	case TokenType.Assert:
		ps.get();
		auto succeeded = match(ps, ir.NodeType.Assert, TokenType.OpenParen);
		if (!succeeded) {
			return succeeded;
		}
		intir.AssignExp e;
		succeeded = parseAssignExp(ps, out e);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Assert);
		}
		exp.arguments ~= e;
		if (ps.peek.type == TokenType.Comma) {
			ps.get();
			succeeded = parseAssignExp(ps, out e);
			if (!succeeded) {
				return parseFailed(ps, ir.NodeType.Assert);
			}
			exp.arguments ~= e;
		}
		succeeded = match(ps, ir.NodeType.Assert, TokenType.CloseParen);
		if (!succeeded) {
			return succeeded;
		}
		exp.op = intir.PrimaryExp.Type.Assert;
		break;
	case TokenType.Import:
		ps.get();
		auto succeeded = match(ps, ir.NodeType.StringImport, TokenType.OpenParen);
		if (!succeeded) {
			return succeeded;
		}
		intir.AssignExp e;
		succeeded = parseAssignExp(ps, out e);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.StringImport);
		}
		exp.arguments ~= e;
		succeeded = match(ps, ir.NodeType.StringImport, TokenType.CloseParen);
		if (!succeeded) {
			return succeeded;
		}
		exp.op = intir.PrimaryExp.Type.Import;
		break;
	case TokenType.OpenBracket:
		size_t i;
		bool isAA;
		while (ps.lookahead(i).type != TokenType.CloseBracket) {
			if (ps.lookahead(i).type == TokenType.Colon) {
				isAA = true;
			}
			i++;
			if (ps.lookahead(i).type == TokenType.Comma ||
				ps.lookahead(i).type == TokenType.End) {
				break;
			}
		}
		if (!isAA) {
			ps.get();
			intir.AssignExp[] aexps;
			auto succeeded = _parseArgumentList(ps, out aexps, TokenType.CloseBracket);
			exp.arguments ~= aexps;
			if (!succeeded) {
				return parseFailed(ps, ir.NodeType.ArrayLiteral);
			}
			succeeded = match(ps, ir.NodeType.ArrayLiteral, TokenType.CloseBracket);
			if (!succeeded) {
				return succeeded;
			}
			exp.op = intir.PrimaryExp.Type.ArrayLiteral;
		} else {
			ps.get();
			while (ps.peek.type != TokenType.CloseBracket) {
				intir.AssignExp e;
				auto succeeded = parseAssignExp(ps, out e);
				if (!succeeded) {
					return parseFailed(ps, ir.NodeType.ArrayLiteral);
				}
				exp.keys ~= e;
				succeeded = match(ps, ir.NodeType.AssocArray, TokenType.Colon);
				if (!succeeded) {
					return succeeded;
				}
				succeeded = parseAssignExp(ps, out e);
				if (!succeeded) {
					return parseFailed(ps, ir.NodeType.ArrayLiteral);
				}
				exp.arguments ~= e;
				matchIf(ps, TokenType.Comma);
			}
			auto succeeded = match(ps, ir.NodeType.AssocArray, TokenType.CloseBracket);
			if (!succeeded) {
				return succeeded;
			}
			assert(exp.keys.length == exp.arguments.length);
			exp.op = intir.PrimaryExp.Type.AssocArrayLiteral;
		}
		break;
	case TokenType.OpenParen:
		if (isFunctionLiteral(ps)) {
			goto case TokenType.Delegate;
		}
		ps.get();
		if (isUnambiguouslyParenType(ps)) {
			exp.op = intir.PrimaryExp.Type.Type;
			auto succeeded = parseType(ps, out exp.type);
			if (!succeeded) {
				return parseFailed(ps, ir.NodeType.TypeExp);
			}
			succeeded = match(ps, ir.NodeType.TypeExp, [TokenType.CloseParen, TokenType.Dot]);
			if (!succeeded) {
				return succeeded;
			}
			if (matchIf(ps, TokenType.Typeid)) {
				exp.op = intir.PrimaryExp.Type.Typeid;
			} else {
				Token nameTok;
				succeeded = match(ps, ir.NodeType.TypeExp, TokenType.Identifier, out nameTok);
				if (!succeeded) {
					return succeeded;
				}
				exp._string = nameTok.value;
			}
			break;
		}
		intir.AssignExp e;
		auto succeeded = parseAssignExp(ps, out e);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.TypeExp);
		}
		exp.tlargs ~= e;
		succeeded = match(ps, ir.NodeType.Invalid, TokenType.CloseParen);
		if (!succeeded) {
			return succeeded;
		}
		exp.op = intir.PrimaryExp.Type.ParenExp;
		break;
	case TokenType.Bool, TokenType.Ubyte, TokenType.Byte,
		 TokenType.Short, TokenType.Ushort,
		 TokenType.Int, TokenType.Uint, TokenType.Long,
		 TokenType.Ulong, TokenType.Void, TokenType.Float,
		 TokenType.Double, TokenType.Real, TokenType.Char,
		 TokenType.Wchar, TokenType.Dchar, TokenType.I8,
		 TokenType.I16, TokenType.I32, TokenType.I64,
		 TokenType.U8, TokenType.U16, TokenType.U32, TokenType.U64,
		 TokenType.F32, TokenType.F64:
		auto type = parsePrimitiveType(ps);
		if (matchIf(ps, TokenType.OpenParen)) {
			// Primitive type construction. e.g. `i32(32)`
			auto succeeded = parsePrimaryExp(ps, out exp);
			if (!succeeded) {
				return succeeded;
			}
			if (exp.type !is null) {
				return parseFailed(ps, ir.NodeType.TypeExp);
			}
			exp.type = type;
			succeeded = match(ps, ir.NodeType.Constant, TokenType.CloseParen);
			if (!succeeded) {
				return succeeded;
			}
			break;
		}
		exp.op = intir.PrimaryExp.Type.Type;
		exp.type = type;
		auto succeeded = match(ps, ir.NodeType.Constant, TokenType.Dot);
		if (!succeeded) {
			return succeeded;
		}
		if (matchIf(ps, TokenType.Typeid)) {
			exp.op = intir.PrimaryExp.Type.Typeid;
		} else {
			Token nameTok;
			succeeded = match(ps, ir.NodeType.Constant, TokenType.Identifier, out nameTok);
			if (!succeeded) {
				return succeeded;
			}
			exp._string = nameTok.value;
		}
		break;
	case TokenType.OpenBrace:
		ps.get();
		exp.op = intir.PrimaryExp.Type.StructLiteral;
		while (ps.peek.type != TokenType.CloseBrace) {
			intir.AssignExp e;
			auto succeeded = parseAssignExp(ps, out e);
			if (!succeeded) {
				return parseFailed(ps, ir.NodeType.StructLiteral);
			}
			exp.arguments ~= e;
			matchIf(ps, TokenType.Comma);
		}
		auto succeeded = match(ps, ir.NodeType.StructLiteral, TokenType.CloseBrace);
		if (!succeeded) {
			return succeeded;
		}
		break;
	case TokenType.Typeid:
		ps.get();
		exp.op = intir.PrimaryExp.Type.Typeid;
		auto succeeded = match(ps, ir.NodeType.Typeid, TokenType.OpenParen);
		if (!succeeded) {
			return succeeded;
		}
		auto mark = ps.save();
		succeeded = parseExp(ps, out exp.exp);
		if (!succeeded) {
			if (ps.neverIgnoreError) {
				return Failed;
			}
			ps.restore(mark);
			ps.resetErrors();
			succeeded = parseType(ps, out exp.type);
			if (!succeeded) {
				return parseFailed(ps, ir.NodeType.Typeid);
			}
		}
		succeeded = match(ps, ir.NodeType.Typeid, TokenType.CloseParen);
		if (!succeeded) {
			return succeeded;
		}
		break;
	case TokenType.Is:
		exp.op = intir.PrimaryExp.Type.Is;
		auto succeeded = parseIsExp(ps, out exp.isExp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.BinOp);
		}
		break;
	case TokenType.Function, TokenType.Delegate:
		exp.op = intir.PrimaryExp.Type.FunctionLiteral;
		auto succeeded = parseFunctionLiteral(ps, out exp.functionLiteral);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.FunctionLiteral);
		}
		break;
	case TokenType.VaArg:
		exp.op = intir.PrimaryExp.Type.VaArg;
		auto succeeded = parseVaArgExp(ps, out exp.vaexp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Function);
		}
		break;
	case TokenType.In:
		parseExpected(ps, ps.peek.loc, ir.NodeType.Identifier, "primary expression");
		ps.neverIgnoreError = true;
		return Failed;
	default:
		auto mark = ps.save();
		auto succeeded = parseFunctionLiteral(ps, out exp.functionLiteral);
		if (!succeeded) {
			ps.restore(mark);
			// The dreaded "expected primary expression" error.
			return unexpectedToken(ps, ir.NodeType.Invalid);
		}
		exp.op = intir.PrimaryExp.Type.FunctionLiteral;
		break;
	}

	exp.loc = ps.peek.loc - origin;

	if (ps == [TokenType.Dot, TokenType.Typeid] && exp.op != intir.PrimaryExp.Type.Typeid) {
		ps.get();
		ps.get();
		auto succeeded = primaryToExp(ps, exp, out exp.exp);
		if (!succeeded) {
			return parseFailed(ps, ir.NodeType.Typeid);
		}
		exp.op = intir.PrimaryExp.Type.Typeid;
		assert(exp.type is null);
	}
	
	return Succeeded;
}

ParseStatus parseVaArgExp(ParserStream ps, out ir.VaArgExp vaexp)
{
	vaexp = new ir.VaArgExp();
	vaexp.loc = ps.peek.loc;
	auto succeeded = match(ps, ir.NodeType.VaArgExp, [TokenType.VaArg, TokenType.Bang]);
	if (!succeeded) {
		return succeeded;
	}
	bool paren = matchIf(ps, TokenType.OpenParen);
	succeeded = parseType(ps, out vaexp.type);
	if (!succeeded) {
		return parseFailed(ps, vaexp);
	}
	if (paren) {
		succeeded = match(ps, ir.NodeType.VaArgExp, TokenType.CloseParen);
		if (!succeeded) {
			return succeeded;
		}
	}
	succeeded = match(ps, ir.NodeType.VaArgExp, TokenType.OpenParen);
	if (!succeeded) {
		return succeeded;
	}
	succeeded = parseExp(ps, out vaexp.arg);
	if (!succeeded) {
		return parseFailed(ps, vaexp);
	}
	succeeded = match(ps, ir.NodeType.VaArgExp, TokenType.CloseParen);
	if (!succeeded) {
		return succeeded;
	}
	return Succeeded;
}

ParseStatus parseRunExp(ParserStream ps, out ir.RunExp runexp)
{
	runexp = new ir.RunExp();
	runexp.loc = ps.peek.loc;
	auto succeeded = match(ps, ir.NodeType.RunExp, TokenType.HashRun);
	if (!succeeded) {
		return succeeded;
	}
	succeeded = parseExp(ps, out runexp.child);
	if (!succeeded) {
		return parseFailed(ps, runexp);
	}
	return Succeeded;
}

bool isUnambiguouslyParenType(ParserStream ps)
{
	switch (ps.peek.type) with (TokenType) {
	case Bool, Byte, Short, Int, Long,
		 Char, Ubyte, Ushort, Uint, Ulong,
		 Dchar, Wchar, Void:
		return true;
	default:
		return false;
	}
}

// Returns: true if the ParserStream is at a function literal.
bool isFunctionLiteral(ParserStream ps)
{
	if (ps.peek.type == TokenType.Function || ps.peek.type == TokenType.Delegate) {
		return true;
	}
	auto mark = ps.save();
	if (ps.peek.type != TokenType.OpenParen) {
		ir.Type tmp;
		return parseType(ps, out tmp) == Succeeded;
	}

	assert(ps.peek.type == TokenType.OpenParen);
	int parenDepth;
	while (!(parenDepth == 0 && ps.peek.type == TokenType.CloseParen)) {
		ps.get();
		if (ps.peek.type == TokenType.OpenParen) {
			parenDepth++;
		}
		if (ps.peek.type == TokenType.CloseParen && parenDepth > 0) {
			parenDepth--;
		}
	}
	ps.get();  // Eat the close paren.

	if (ps.peek.type == TokenType.OpenBrace) {
		ps.restore(mark);
		return true;
	} else if (ps == [TokenType.Assign, TokenType.Greater]) {
		ps.restore(mark);
		return true;
	} else {
		ps.restore(mark);
		return false;
	}
}
