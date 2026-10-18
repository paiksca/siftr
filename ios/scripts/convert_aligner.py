"""Convert facebook/wav2vec2-base-960h to Core ML for on-device word alignment.

Usage: python scripts/convert_aligner.py <output dir>
Writes Aligner.mlpackage (10 s of 16 kHz audio in, CTC logits out) and aligner_vocab.json.
"""
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor

SECONDS = 10
SAMPLES = 16000 * SECONDS

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
name = "facebook/wav2vec2-base-960h"
processor = Wav2Vec2Processor.from_pretrained(name)
model = Wav2Vec2ForCTC.from_pretrained(name, attn_implementation="eager").eval()


class Logits(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, audio):
        return self.m(audio).logits


example = torch.zeros(1, SAMPLES)
traced = torch.jit.trace(Logits(model), example)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="audio", shape=(1, SAMPLES), dtype=np.float32)],
    outputs=[ct.TensorType(name="logits", dtype=np.float32)],
    minimum_deployment_target=ct.target.iOS18,
    compute_precision=ct.precision.FLOAT16,
    # The Neural Engine compiler hung for over ten minutes on this model, so load it on CPU and GPU.
    compute_units=ct.ComputeUnit.CPU_AND_GPU,
)
# 8-bit weights halve the size, which matters inside an app extension's memory limit.
config = ct.optimize.coreml.OptimizationConfig(
    global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric"))
mlmodel = ct.optimize.coreml.linear_quantize_weights(mlmodel, config=config)
mlmodel.short_description = "wav2vec2-base-960h CTC logits for 10 s of normalized 16 kHz audio"
mlmodel.save(str(out / "Aligner.mlpackage"))

vocab = processor.tokenizer.get_vocab()
(out / "aligner_vocab.json").write_text(json.dumps(vocab))

# Check the converted model against PyTorch on real-looking input.
x = np.random.default_rng(0).standard_normal((1, SAMPLES)).astype(np.float32) * 0.1
x = (x - x.mean()) / (x.std() + 1e-7)
ref = model(torch.tensor(x)).logits.detach().numpy()
got = mlmodel.predict({"audio": x})["logits"]
agree = (ref.argmax(-1) == got.argmax(-1)).mean()
print(f"frames {got.shape[1]}, argmax agreement with PyTorch {agree:.1%}")
