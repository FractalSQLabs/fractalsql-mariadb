# fractalsql-mariadb: repo-root Makefile.
#
# The extension itself builds with `make -C service` or ./build.sh --
# see service/Makefile and service/README.md.
#
# What's left here is unrelated: the bench targets, which assume the
# extension is already installed against a reachable MariaDB server and
# just measure it. See bench/README.md.

PYTHON ?= python3
BENCH_ARGS ?=

.PHONY: bench bench-vector

bench:
	$(PYTHON) bench/data_gen.py --with-native-vector $(BENCH_ARGS)
	$(PYTHON) bench/head_to_head.py $(BENCH_ARGS)

bench-vector:
	$(PYTHON) bench/data_gen.py --with-native-vector $(BENCH_ARGS)
	$(PYTHON) bench/vector_type_head_to_head.py $(BENCH_ARGS)
