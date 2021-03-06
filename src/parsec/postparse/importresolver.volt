// Copyright © 2012-2016, Jakob Bornecrantz.  All rights reserved.
// Copyright © 2012-2016, Bernard Helyer.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module parsec.postparse.importresolver;

import watt.text.format : format;

import ir = parsec.ir.ir;
import parsec.ir.util;

import parsec.errors;
import parsec.interfaces;
import parsec.visitor.visitor;
import parsec.visitor.scopemanager;
import gatherer = parsec.postparse.gatherer;


/*!
 * Resolves imports on a single module.
 *
 * @ingroup passes passLang
 */
class ImportResolver : ScopeManager, Pass
{
private:
	LanguagePass lp;
	ir.Module mModule;


public:
	this(LanguagePass lp)
	{
		this.lp = lp;
	}


	/*
	 *
	 * Pass functions.
	 *
	 */

	override void transform(ir.Module m)
	{
		assert(mModule is null);

		mModule = m;
		accept(m, this);
		mModule = null;
	}

	override void close()
	{
	}


	/*
	 *
	 * Visitor and our functions.
	 *
	 */

	override Status enter(ir.Import i)
	{
		if (current !is mModule.myScope) {
			//throw makeNonTopLevelImport(i.location);
			return Continue;
		}

		if (i.isStatic && i.access != ir.Access.Private) {
			//throw makeExpected(i.location, 
			//	format("static import '%s' to be private", i.name));
			return Continue;
		}

		//auto mod = lp.getModule(i.name);
		if (/*mod*/lp is null) {
			//throw makeCannotImport(i, i);
			return Continue;
		}
		/+
		if (mod.isAnonymous) {
			//throw makeCannotImportAnonymous(i, i);
			return Continue;
		}
		i.targetModule = mod;

		if (i.aliases.length > 0) {
			// import a : b, c OR import a = b : c, d;
			handleAliases(mod, i);
		} else if (i.bind !is null) {
			// import a = b;
			handleRebind(mod, i);
		} else {
			// static import a; OR import a;
			handleRegularAndStatic(mod, i);
		}
		+/

		return ContinueParent;
	}

	/*!
	 * Takes a import that maps the module to a symbol in the current scope.
	 *
	 * import a = b;
	 */
	void handleRebind(ir.Module mod, ir.Import i)
	{
		// TODO We should not use mod.myScope here,
		// but intead link directly to the module.
		gatherer.addScope(mod);
		assert(mod.myScope !is null);

		auto store = current.addScope(i, mod.myScope, i.bind.value);
		store.importBindAccess = i.access;
	}

	/*!
	 * Handles a import with symbol aliases.
	 *
	 * import a : b, c;
	 * import a = b : c, d;
	 */
	void handleAliases(ir.Module mod, ir.Import i)
	{
		auto bindScope = current;
		if (i.bind !is null) {
			bindScope = buildOrReturnScope(bindScope, i.bind, i.bind.value);
		} else {
			assert(current is mModule.myScope);
		}

		foreach (ii, _alias; i.aliases) {
			ir.Alias a;

			if (_alias[1] is null) {
				a = buildAlias(ref _alias[0].loc, _alias[0].value, _alias[0].value);
			} else {
				a = buildAliasSmart(ref _alias[0].loc, _alias[0].value, _alias[1]);
			}

			// Setup where we should look.
			a.lookScope = null;
			a.lookModule = mod;
			a.store = bindScope.addAlias(a, a.name);
			a.store.importBindAccess = i.access;
		}
	}

	/*!
	 * Most common imports.
	 *
	 * import a;
	 * static import a;
	 */
	void handleRegularAndStatic(ir.Module mod, ir.Import i)
	{
		// TODO We should not use mod.myScope here,
		// but intead link directly to the module.
		gatherer.addScope(mod);
		assert(mod.myScope !is null);

		// Where we add the module binding.
		ir.Scope parent = mModule.myScope;

		// Build the chain of scopes for the import.
		// import 'foo.bar.pkg'.mod;
		foreach (ident; i.name.identifiers[0 .. $-1]) {
			parent = buildOrReturnScope(parent, ident, ident.value);
		}

		// Build the final level.
		// import foo.bar.pkg.'mod';
		auto store = parent.getStore(i.name.identifiers[$-1].value);
		if (store !is null) {
			if (i.isStatic && store.myScope !is mod.myScope) {
				//throw makeExpected(i.location, "unique module");
				return;
			}
		} else {
			parent.addScope(i, mod.myScope, i.name.identifiers[$-1].value);
		}

		// Add the module to the list of imported modules.
		if (!i.isStatic) {
			mModule.myScope.importedModules ~= mod;
			mModule.myScope.importedAccess ~= i.access;
		}
	}

	/*!
	 * Used for adding in scopes from static imports
	 */
	ir.Scope buildOrReturnScope(ir.Scope parent, ir.Node node, string name)
	{
		auto store = parent.getStore(name);
		if (store !is null) {
			// TODO Better error checking here,
			// we could be adding to aggregates here.
			if (store.myScope is null) {
			//	throw makeExpected(node.location, "scope");
				return parent;
			}
			return store.myScope;
		} else {
			auto s = new ir.Scope(parent, node, name, parent.nestedDepth);
			parent.addScope(node, s, name);
			parent = s;
		}
		return parent;
	}
}
