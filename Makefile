# gross make file that will eventually be replaced

OCAMLC = ocamlc
OCAMLOPT = ocamlopt

SRC = src
SOURCES = $(SRC)/types.ml $(SRC)/hasher.ml $(SRC)/reader.ml \
          $(SRC)/capabilities.ml $(SRC)/primitives.ml $(SRC)/evaluator.ml \
          $(SRC)/cache.ml $(SRC)/repl.ml $(SRC)/main.ml

.PHONY: all clean run repl native

all: pp

pp: $(SOURCES)
	cd $(SRC) && rm -f *.cm* && \
	$(OCAMLC) -c types.ml && \
	$(OCAMLC) -c hasher.ml && \
	$(OCAMLC) -c reader.ml && \
	$(OCAMLC) -c capabilities.ml && \
	$(OCAMLC) -c primitives.ml && \
	$(OCAMLC) -c evaluator.ml && \
	$(OCAMLC) -c cache.ml && \
	$(OCAMLC) -c repl.ml && \
	$(OCAMLC) -c main.ml && \
	$(OCAMLC) -o ../pp types.cmo hasher.cmo reader.cmo capabilities.cmo primitives.cmo evaluator.cmo cache.cmo repl.cmo main.cmo

native:
	cd $(SRC) && rm -f *.cm* *.cmx *.o && \
	$(OCAMLOPT) -c types.ml && \
	$(OCAMLOPT) -c hasher.ml && \
	$(OCAMLOPT) -c reader.ml && \
	$(OCAMLOPT) -c capabilities.ml && \
	$(OCAMLOPT) -c primitives.ml && \
	$(OCAMLOPT) -c evaluator.ml && \
	$(OCAMLOPT) -c cache.ml && \
	$(OCAMLOPT) -c repl.ml && \
	$(OCAMLOPT) -c main.ml && \
	$(OCAMLOPT) -o ../pp-native types.cmx hasher.cmx reader.cmx capabilities.cmx primitives.cmx evaluator.cmx cache.cmx repl.cmx main.cmx

run: pp
	./pp

repl: pp
	./pp

clean:
	rm -f $(SRC)/*.cm* $(SRC)/*.o pp pp-native
