# models/

One `<name>.files` per measured model in `models.manifest`: every file in the
model directory, one per line, tab-separated — `size  sha256-or-dash  path`.
Written by `scripts/model-manifest.sh`; read by `scripts/verify-models.sh`.
Do not edit by hand. Empty until the models are measured on the lab box.
