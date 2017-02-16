// Copyright © 2013-2017, Bernard Helyer.  All rights reserved.
// Copyright © 2013-2017, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/parsec/license.d (BOOST ver. 1.0).
module parsec.errors;

import core.exception : Exception;
import watt.text.format : format;


/**
 * Returns a panic exception.
 */
fn panic(msg: string) Exception
{
	return new Exception(msg);
}
