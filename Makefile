# gross make file that will eventually be replaced

OCAMLC = ocamlc
OCAMLOPT = ocamlopt

SRC = src
SOURCES = $(SRC)/types.ml $(SRC)/hasher.ml $(SRC)/reader.ml \
          $(SRC)/capabilities.ml $(SRC)/island.ml $(SRC)/primitives.ml \
          $(SRC)/evaluator.ml $(SRC)/bytecode.ml $(SRC)/compiler.ml \
          $(SRC)/vm.ml $(SRC)/cache.ml $(SRC)/repl.ml $(SRC)/main.ml

.PHONY: all clean run repl native

all: pp

pp: $(SOURCES)
	cd $(SRC) && rm -f *.cm* && \
	$(OCAMLC) -c types.ml && \
	$(OCAMLC) -c hasher.ml && \
	$(OCAMLC) -c reader.ml && \
	$(OCAMLC) -c capabilities.ml && \
	$(OCAMLC) -c island.ml && \
	$(OCAMLC) -c primitives.ml && \
	$(OCAMLC) -c evaluator.ml && \
	$(OCAMLC) -c bytecode.ml && \
	$(OCAMLC) -c compiler.ml && \
	$(OCAMLC) -c vm.ml && \
	$(OCAMLC) -c cache.ml && \
	$(OCAMLC) -c repl.ml && \
	$(OCAMLC) -c main.ml && \
	$(OCAMLC) -o ../pp types.cmo hasher.cmo reader.cmo capabilities.cmo island.cmo primitives.cmo evaluator.cmo bytecode.cmo compiler.cmo vm.cmo cache.cmo repl.cmo main.cmo

native:
	cd $(SRC) && rm -f *.cm* *.cmx *.o && \
	$(OCAMLOPT) -c types.ml && \
	$(OCAMLOPT) -c hasher.ml && \
	$(OCAMLOPT) -c reader.ml && \
	$(OCAMLOPT) -c capabilities.ml && \
	$(OCAMLOPT) -c island.ml && \
	$(OCAMLOPT) -c primitives.ml && \
	$(OCAMLOPT) -c evaluator.ml && \
	$(OCAMLOPT) -c bytecode.ml && \
	$(OCAMLOPT) -c compiler.ml && \
	$(OCAMLOPT) -c vm.ml && \
	$(OCAMLOPT) -c cache.ml && \
	$(OCAMLOPT) -c repl.ml && \
	$(OCAMLOPT) -c main.ml && \
	$(OCAMLOPT) -o ../pp-native types.cmx hasher.cmx reader.cmx capabilities.cmx island.cmx primitives.cmx evaluator.cmx bytecode.cmx compiler.cmx vm.cmx cache.cmx repl.cmx main.cmx

run: pp
	./pp

repl: pp
	./pp

test: pp
	@for f in tests/001-eval-apply-test.pp tests/002-list-test.pp tests/003-print-deep-test.pp tests/006-config-test.pp; do \
		./pp --bytecode $$f > /tmp/bc.out 2>&1; ./pp $$f > /tmp/tw.out 2>&1; \
		diff /tmp/bc.out /tmp/tw.out || (echo "MISMATCH in $$f"; exit 1); \
		echo "ok $$f"; \
	done

selfhost-test: pp
	./pp --bytecode src/pc.pp > /dev/null
	./pp --bytecode -e '(do (load "src/pc.pp") (def bc (compile-program (read-string (slurp "examples/factorial.pp")))) (ppc-run bc []))'

clean:
	rm -f $(SRC)/*.cm* $(SRC)/*.o pp pp-native
