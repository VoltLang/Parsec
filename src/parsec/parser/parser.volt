// Copyright © 2012, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module parsec.parser.parser;

import watt.io.std : writefln;
import watt.text.format : format;

import parsec.lex.location : Location;
import parsec.lex.lexer : lex;
import parsec.lex.token : TokenType, tokenToString;
import parsec.lex.source : Source;

import ir = parsec.ir.ir;

import parsec.arg : Settings;
import parsec.errors : makeError, panic;
import parsec.interfaces : Frontend;
import parsec.parser.base : ParseStatus, ParserStream, ParserPanic, NodeSink;
import parsec.parser.toplevel : parseModule;
import parsec.parser.statements : parseStatement;


private void checkError(ParserStream ps, ParseStatus status)
{
	if (status) {
		return;
	}

	auto e = ps.parserErrors[0];
	auto msg = e.errorMessage();
	auto p = cast(ParserPanic)e;

	void addExtraInfo() {
		msg = format("%s (peek:%s)", msg, ps.peek.value);
		foreach (err; ps.parserErrors) {
			msg = format("%s\n%s: %s (from %s:%s)",
			              msg, err.loc.toString(),
			              err.errorMessage(),
			              err.raiseFile, err.raiseLine);
		}
	}

	if (p !is null) {
		addExtraInfo();
		throw panic(ref e.loc, msg, e.raiseFile, e.raiseLine);
	} else {
		debug addExtraInfo();
		throw makeError(ref e.loc, msg, e.raiseFile, e.raiseLine);
	}
}

class Parser : Frontend
{
public:
	bool dumpLex;
	Settings settings;

public:
	this(Settings settings)
	{
		this.settings = settings;
	}

	override ir.Module parseNewFile(string source, string filename)
	{
		auto src = new Source(source, filename);
		src.skipScriptLine();

		auto ps = new ParserStream(lex(src), settings);
		if (dumpLex) {
			doDumpLex(ps);
		}

		ps.get(); // Skip, stream already checks for Begin.

		ir.Module mod;
		checkError(ps, parseModule(ps, out mod));
		return mod;
	}

	override ir.Node[] parseStatements(string source, Location loc)
	{
		auto src = new Source(source, loc.filename);
		src.changeCurrentLocation(loc.filename, loc.line);

		auto ps = new ParserStream(lex(src), settings);
		if (dumpLex) {
			doDumpLex(ps);
		}

		ps.get(); // Skip, stream already checks for Begin.

		auto sink = new NodeSink();
		while (ps.peek.type != TokenType.End) {
			checkError(ps, parseStatement(ps, sink.push));
		}
		return sink.array;
	}

	override void close()
	{

	}

protected:
	void doDumpLex(ParserStream ps)
	{
		/+
		writefln("Dumping lexing:");

		// Skip first begin
		ps.get();

		ir.Token t;
		while((t = ps.get()).type != TokenType.End) {
			string l = t.loc.toString();
			string tStr = t.type.tokenToString();
			string v = t.value;
			writefln("%s %s \"%s\"", l, tStr, v);
		}

		writefln("");

		ps.initTokenArray();+/
		assert(false);
	}
}
