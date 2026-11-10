# envs/

Conda environment files that belong to the deployment rather than to one
component. Each is named in `environments.map`.

Nothing is here yet. `handler.yml` (the worker's environment: Python 3.10, torch,
VTK, FireANTs, segflow4d's dependencies) has to be exported from the working
environment on the lab box and proven to rebuild there before it is committed.
