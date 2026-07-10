# Convenience Makefile. The real build is dune.
# Use `opam exec -- dune build` directly if `dune` is not on PATH.
DUNE ?= opam exec -- dune
PP = _build/default/src/main.exe

.PHONY: all pp clean run repl native fuzz test cap-test

all: pp

pp:
	$(DUNE) build
	@ln -sf $(PP) pp

run: pp
	./pp

repl: pp
	./pp

native:
	$(DUNE) build --profile release
	@ln -sf _build/default/src/main.exe pp-native

# differential fuzzer (tools/fuzz.ml, OCaml stdlib + unix only)
fuzz: pp tools/fuzz.ml
	ocamlc -I +unix unix.cma -I tools -o fuzz tools/fuzz.ml

test: pp
	@for f in tests/001-eval-apply-test.pp tests/002-list-test.pp tests/003-print-deep-test.pp tests/004-type-test.pp tests/005-island-test.pp tests/006-config-test.pp tests/007-phase0-laws.pp; do \
		./pp --bytecode $$f > /tmp/bc.out 2>&1; ./pp $$f > /tmp/tw.out 2>&1; \
		diff /tmp/bc.out /tmp/tw.out || { echo "MISMATCH in $$f"; exit 1; }; \
		echo "ok $$f"; \
	done

cap-test: pp
	@echo "--- capability adversarial suite ---"
	PP=./pp tests/capability-adversarial.sh

clean:
	$(DUNE) clean
	rm -f pp pp-native fuzz
