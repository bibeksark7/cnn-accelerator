# bench: software CNN vs accelerator (spec 13.9) on the first BENCH_IMAGES quick-subset images.
BENCH_IMAGES ?= 2
APP_SRC += common/cnn_sw.c
GEN_SRC += $(OUT)/images.c $(OUT)/net_params.c
$(OUT)/images.c: tools/gen_data.py ../model/artifacts/quick_subset.npz | $(OUT)
	$(PYTHON) tools/gen_data.py images $(OUT) quick $(BENCH_IMAGES)
$(OUT)/net_params.c: tools/gen_data.py ../model/artifacts/params.npz | $(OUT)
	$(PYTHON) tools/gen_data.py params $(OUT)
