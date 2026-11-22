# bench: software CNN vs accelerator (spec 13.9) on the first BENCH_IMAGES quick-subset images.
BENCH_IMAGES ?= 2
APP_SRC += common/cnn_sw.c
GEN_SRC += $(OUT)/images.c $(OUT)/net_params.c
# The image count is an input of images.c: the stamp changes whenever BENCH_IMAGES does, so a
# rebuild with another count regenerates the images (BUG-018).
$(OUT)/bench_images.stamp: FORCE | $(OUT)
	@echo '$(BENCH_IMAGES)' | cmp -s - $@ || echo '$(BENCH_IMAGES)' > $@
$(OUT)/images.c: tools/gen_data.py ../model/artifacts/quick_subset.npz $(OUT)/bench_images.stamp | $(OUT)
	$(PYTHON) tools/gen_data.py images $(OUT) quick $(BENCH_IMAGES)
$(OUT)/net_params.c: tools/gen_data.py ../model/artifacts/params.npz | $(OUT)
	$(PYTHON) tools/gen_data.py params $(OUT)
FORCE:
.PHONY: FORCE
