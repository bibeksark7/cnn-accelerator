# demo: the board demo of spec 13.8 (preloaded images, software CNN for the speedup).
APP_SRC += common/cnn_sw.c
GEN_SRC += $(OUT)/net_params.c $(OUT)/labels.c
$(OUT)/net_params.c: tools/gen_data.py ../model/artifacts/params.npz | $(OUT)
	$(PYTHON) tools/gen_data.py params $(OUT)
$(OUT)/labels.c: tools/gen_data.py ../model/artifacts/mem/demo.json | $(OUT)
	$(PYTHON) tools/gen_data.py labels $(OUT)
