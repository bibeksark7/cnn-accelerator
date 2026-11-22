# demo: the board demo of spec 13.8 (preloaded images, software CNN for the speedup).
APP_SRC += common/cnn_sw.c
GEN_SRC += $(OUT)/net_params.c $(OUT)/labels.c
$(OUT)/net_params.c: tools/gen_data.py ../model/artifacts/params.npz | $(OUT)
	$(PYTHON) tools/gen_data.py params $(OUT)
$(OUT)/labels.c: tools/gen_data.py ../model/artifacts/mem/demo.json | $(OUT)
	$(PYTHON) tools/gen_data.py labels $(OUT)
# ACCEL_WAIT_CYCLES=<n> overrides accel_wait's limit (accel.h), e.g. to test the timeout path.
# The stamp changes whenever the value does, so a rebuild with another value recompiles.
ACCEL_WAIT_CYCLES ?=
ifneq ($(ACCEL_WAIT_CYCLES),)
CFLAGS += -DACCEL_WAIT_CYCLES=$(ACCEL_WAIT_CYCLES)u
endif
$(OUT)/wait_cycles.stamp: FORCE | $(OUT)
	@echo '$(ACCEL_WAIT_CYCLES)' | cmp -s - $@ || echo '$(ACCEL_WAIT_CYCLES)' > $@
$(OUT)/$(APP).elf: $(OUT)/wait_cycles.stamp
FORCE:
.PHONY: FORCE
