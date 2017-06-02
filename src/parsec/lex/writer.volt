// Copyright © 2011, Jakob Ovrum.  All rights reserved.
// Copyright © 2010-2017, Bernard Helyer.  All rights reserved.
// Copyright © 2012-2017, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/parsec/license.d (BOOST ver. 1.0).
module parsec.lex.writer;

import parsec.lex.token : Token, TokenType;
import parsec.lex.source : Source;
import parsec.lex.error;


/*!
 * Small container class for tokens, used by the lexer to write tokens to.
 */
final class TokenWriter
{
public:
	LexerError[] errors;

private:
	mSource: Source;
	mLength: size_t;
	mTokens: Token[];


public:
	/*!
	 * Create a new TokenWriter and initialize
	 * the first token to TokenType.Begin.
	 */
	this(source: Source)
	{
		this.mSource = source;
		initTokenArray();
	}

	/*!
	 * Return the current source.
	 *
	 * Side-effects:
	 *   None.
	 */
	@property fn source() Source
	{
		return mSource;
	}

	/*!
	 * Add the
	 * Return the last added token.
	 *
	 * Side-effects:
	 *   None.
	 */
	fn addToken(token: Token) void
	in {
		assert(token !is null);
	}
	body {
		if (mTokens.length <= mLength) {
			auto tokens = new Token[](mLength * 2 + 3);
			tokens[0 .. mLength] = mTokens[];
			mTokens = tokens;
		}

		mTokens[mLength++] = token;
		token.loc.length = cast(u32)token.value.length;
	}

	/*!
	 * Remove the last token from the token list.
	 * No checking is performed, assumes you _know_ that you can remove a token.
	 *
	 * Side-effects:
	 *   mTokens is shortened by one.
	 */
	fn pop() void
	in {
		assert(mLength > 0);
	}
	body {
		mTokens[--mLength] = null;
	}

	/*!
	 * Return the last added token.
	 *
	 * Side-effects:
	 *   None.
	 */
	@property fn lastAdded() Token
	in {
		assert(mLength > 0);
	}
	body {
		return mTokens[mLength - 1];
	}

	/*!
	 * Returns this writer's tokens.
	 *
	 * TODO: Currently this function will leave the writer in a bit of a
	 *       odd state. Since it resets the tokens but not the source.
	 *
	 * Side-effects:
	 *   Remove all tokens from this writer, and reinitializes the writer.
	 */
	fn getTokens() Token[]
	{
		auto ret = new Token[](mLength);
		ret[] = mTokens[0 .. mLength];
		initTokenArray();
		return ret;
	}


private:
	/*!
	 * Create a Begin token add set the token array
	 * to single array only containing it.
	 *
	 * Side-effects:
	 *   mTokens is replaced, current source is left untouched.
	 */
	fn initTokenArray()
	{
		auto start = new Token();
		start.type = TokenType.Begin;
		start.value = "START";

		// Reset the token array
		mTokens = new Token[](1);
		mTokens[0] = start;
		mLength = 1;
	}
}
