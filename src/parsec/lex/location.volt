// Copyright © 2011, Jakob Ovrum.  All rights reserved.
// Copyright © 2010-2017, Bernard Helyer.  All rights reserved.
// Copyright © 2012-2017, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/parsec/license.volt (BOOST ver. 1.0).
module parsec.lex.location;

import watt.text.sink : Sink, StringSink;
import watt.text.format : format;


/**
 * Struct representing a location in a source file.
 */
struct Location
{
public:
	filename: string;
	line: u32;
	column: u32;
	length: u32;


public:
	fn toString() string
	{
		sink: StringSink;
		this.toString(sink.sink);
		return sink.toString();
	}

	fn toString(sink: Sink)
	{
		format(sink, "%s:%s:%s", filename, line, column);
	}

	/**
	 * Difference between two locations.
	 * end - begin == begin ... end
	 * @see difference
	 */
	fn opSub(ref begin: Location) Location
	{
		return difference(ref this, ref begin, ref begin);
	}

	/**
	 * Difference between two locations.
	 * end - begin == begin ... end
	 * On mismatch of filename or if begin is after
	 * end _default is returned.
	 */
	static fn difference(ref end: Location, ref begin: Location,
	                     ref def: Location) Location
	{
		if (begin.filename != end.filename ||
		    begin.line > end.line) {
			return def;
		}

		Location loc;
		loc.filename = begin.filename;
		loc.line = begin.line;
		loc.column = begin.column;

		if (end.line != begin.line) {
			loc.length = u32.max; // End of line.
		} else {
			assert(begin.column <= end.column);
			loc.length = end.column + end.length - begin.column;
		}

		return loc;
	}

	fn spanTo(ref end: Location)
	{
		if (line <= end.line && column < end.column) {
			this = end - this;
		}
	}
}
