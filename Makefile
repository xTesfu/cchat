all: *.erl lib/*.erl
	make -C lib
	erl -make

run_tests: all
	erl -noshell -eval "eunit:test(test_client), halt()"

MAKE_FILES = Makefile Emakefile
LIB_FILES = lib/*.erl
MAIN_FILES = $(MAKE_FILES) $(LIB_FILES)

TEMP_FILES = /tmp/CCHAT_MAIN_FILES
TEMP_SOLUTION = _tempSolution
ALL_SUBMISSIONS = _submissions
SUBMISSION_FILE = submission.tgz

ifdef GROUP
	SUBMISSION_DIR = $(ALL_SUBMISSIONS)/group$(GROUP)
else
	SUBMISSION_DIR = $(TEMP_FILES)
endif

clean:
	make -C lib clean
	rm -f *.beam *.dump
	rm -rf $(TEMP_FILES) $(TEMP_SOLUTION)

lab: $(SUBMISSION_DIR)/*.erl $(MAIN_FILES)
	rm -rf $(TEMP_SOLUTION)
	mkdir $(TEMP_SOLUTION)
	cp $(SUBMISSION_DIR)/*.erl $(TEMP_SOLUTION)
	cp -r $(MAKE_FILES) $(TEMP_SOLUTION)
	cp -r lib $(TEMP_SOLUTION)
	make -C $(TEMP_SOLUTION) 

tar: $(SUBMISSION_FILE)
	rm -rf $(TEMP_FILES)
	mkdir $(TEMP_FILES)
	tar -xzvf $(SUBMISSION_FILE) -C $(TEMP_FILES)
	make lab

lab_clean:
	rm -rf $(TEMP_SOLUTION)

lab_tests: lab
	make -C $(TEMP_SOLUTION) run_tests

tar_tests: tar
	make -C $(TEMP_SOLUTION) run_tests
