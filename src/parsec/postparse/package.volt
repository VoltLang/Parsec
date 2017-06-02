// Copyright © 2017, Bernard Helyer.  All rights reserved.
// See copyright notice in src/parsec/license.d (BOOST ver. 1.0).
module parsec.postparse;

import parsec.interfaces;
import ir = parsec.ir.ir;

import parsec.postparse.attribremoval;
import parsec.postparse.condremoval;
import parsec.postparse.gatherer;
import parsec.postparse.importresolver;
import parsec.postparse.scopereplacer;

private global passes: Pass[];

global this()
{
	target := new TargetInfo();
	passes ~= new ScopeReplacer();
	passes ~= new AttribRemoval(target);
	passes ~= new Gatherer(true);
	passes ~= new ImportResolver(null);
}


fn postParse(mod: ir.Module)
{
	foreach (pass; passes) {
		pass.transform(mod);
	}
}
