all: lex.erl grm.erl

lex.erl: lex.xrl
	erl -eval "leex:file(lex), init:stop()" -noshell

grm.erl: grm.yrl
	erl -eval "yecc:file(grm), init:stop()" -noshell

clean:
	rm -f lex.erl grm.erl
