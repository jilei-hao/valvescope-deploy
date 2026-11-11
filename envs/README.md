# envs/

Conda environment files that belong to the deployment rather than to one
component. Each is named in `environments.map`.

## handler.yml — the worker's environment

Python 3.10.19, torch 2.5.1+cu121, VTK 9.3.1, SimpleITK 2.2.1 and the CUDA 12.1
compiler and headers. Every package has an exact version; conda packages also
have their exact build.

Captured on Ludwig on 2026-11-11 from the developer environment `segflow4d`, then
**rebuilt from this file** in a separate Miniconda and compared: the conda
packages are identical (name, version, build); the pip packages are identical
apart from the additions listed in the file's last block.

It is assembled, not a raw export, because the raw exports do not rebuild. They
are kept in `handler.export/` so the next capture can be diffed against them:

| File | What it is | Why it is not enough |
|---|---|---|
| `conda-env-export.yml` | `conda env export -n segflow4d` | its pip section drops 23 installed packages (vtk, itk-*, matplotlib, nibabel, scikit-image, picsl-*), and names three that no index serves |
| `conda-env-export.from-history.yml` | `conda env export --from-history` | python and the three CUDA toolkit packages only |
| `pip-freeze.txt` | `pip freeze` in that environment | the true pip list; `fireants` points at a local directory that no longer exists |

Three packages are deliberately absent from `handler.yml`. They are pinned
components in `versions.lock` and are installed after the environment exists,
always with `--no-deps`:

| Package | How |
|---|---|
| `fireants`, `fireants_fused_ops` | `install/build-fireants.sh` from the `FireANTs` checkout; the CUDA extension is compiled on the server (needs `g++-12` on Ubuntu 24.04) |
| `segflow4d` | `pip install --no-deps -e` |
| `avrp-handler` | `pip install --no-deps -e` |

`pip check` runs after each, so a component that starts needing something this
file lacks fails its install step instead of failing at run time.

### Re-capturing

1. `conda env export -n <env>`, the same with `--from-history`, and `pip freeze`
   into `handler.export/`.
2. Carry the changes into `handler.yml` by hand (conda lines from the full
   export, pip lines from the freeze).
3. Prove it: `conda env create` from the file in a scratch Miniconda, run
   `install/build-fireants.sh`, install the two components, `pip check`, and
   import torch (with `cuda.is_available()`), vtk, SimpleITK, fireants,
   segflow4d and `src.main`.

On the lab network, pip needs `PIP_CERT=/etc/ssl/certs/ca-certificates.crt`
(`VS_CA_BUNDLE` in `deploy.env`): the firewall re-signs `download.pytorch.org`.
