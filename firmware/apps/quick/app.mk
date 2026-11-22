# quick: the 50 quick-subset images, embedded in the firmware.
GEN_SRC += $(OUT)/images.c
$(OUT)/images.c: tools/gen_data.py ../model/artifacts/quick_subset.npz | $(OUT)
	$(PYTHON) tools/gen_data.py images $(OUT) quick
