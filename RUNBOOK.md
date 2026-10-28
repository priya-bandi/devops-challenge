# EO/IR Stack v1.4.2 — Field Runbook

Line numbers refer to the **original** files as received.

## 1. Flaws found and fixed

| # | File : line | Root cause | Fix |
|---|---|---|---|
| 1 | `models/manifest.json:10` | `sha256` did not match the shipped engine → worker `checksum_valid=false` → API 503 forever | Engine provenance confirmed, manifest re-baselined to the real hash. CI `verify-artifacts` job and `package_airgap.sh` now **block** any mismatch |
| 2 | `models/manifest.json:4` | Claimed `x86_64_and_aarch64_jetpack5`; engine header is TensorRT 8.6 / SM 8.7 (Jetson Orin only) | Manifest declares `aarch64`, `jetson_orin`, `sm_87`, TRT `8.6` (see §3) |
| 3 | `vision_api/app.py:9,34,39,48` | One-shot startup latch: if the worker was not ready the instant the API booted, API stayed 503 forever (startup race) | Latch removed; worker readiness checked on every `/health` and `/detect` request |
| 4 | `vision_api/app.py:6` + `docker-compose.yml:34` | `WORKER_URL=http://localhost:9001` — wrong host (localhost is the API's own container) and wrong port | `http://inference_worker:9000` (service DNS) |
| 5 | `docker-compose.yml:42-43` | API only on `edge_dmz`; worker and DB only on internal `sensor_backplane` → no route | API joins both networks; worker + DB stay internal-only |
| 6 | `docker-compose.yml:22` | Healthcheck `echo … \|\| exit 0` always passes, so a dead/corrupt worker shows healthy | Real probe of `/status` via `healthcheck.py` (HTTP 200 only); `interval 5s × retries 2` → unhealthy in ≤ 15 s |
| 7 | `docker-compose.yml:39-41` | `depends_on` without conditions = start order only, not readiness | `condition: service_healthy` on worker and Postgres (`pg_isready` healthcheck added) |
| 8 | `docker-compose.yml:5-7,36` | Production DB password hardcoded and committed | Moved to uncommitted `.env` (`${VAR:?}` fails fast if missing); `.env.example` committed. **Password must be rotated** — it is in git history |
| 9 | `docker-compose.yml:20` | Unused `AWS_SECRET_ACCESS_KEY` committed | Removed; key must be revoked |
| 10 | `docker-compose.yml:8-9` | Postgres published on host `5432` | Port removed; DB reachable only on the internal network |
| 11 | `docker-compose.yml:14,30` / `3` | Two untagged `build: .` images; floating `postgres:15-alpine` | One image `eoir-stack:${IMAGE_TAG}` shared by both services; Postgres pinned `15.10-alpine` |
| 12 | `docker-compose.yml` (all services) | Root, writable FS, all capabilities, no restart policy | `user 10001`, `read_only`, `tmpfs /tmp`, `cap_drop: ALL`, `no-new-privileges`, `init`, `restart: unless-stopped` |
| 13 | `Dockerfile:1,5` | Full `python:3.11` + build tools/vim/git ≈ 1 GB+ | Multi-stage on `python:3.11-slim-bookworm`, no extra packages (≈ 150 MB, CI fails > 220 MB) |
| 14 | `Dockerfile:7` | `COPY .` pulled in `.git`, tests, secrets, CI files | Explicit `COPY` of runtime dirs + `.dockerignore` |
| 15 | `Dockerfile` (no `USER`), `:8` | Runs as root; model files were `0770 root` so a non-root user could not read them | Files root-owned `0644`, dirs `0755`, `USER 10001:10001` |
| 16 | `inference_worker/worker.py:9,25-31` | TRT cache written inside `models/` → fails on read-only / non-root / checksummed artifact dir | Cache in `/tmp/trt_cache` (tmpfs); `models/` mounted `:ro` |
| 17 | `ci.yml:18` | `\|\| true` hid failing tests | Removed; tests gate the pipeline |
| 18 | `ci.yml:20` | Build had no `needs:` — ran even when tests failed | `build` needs `test` + `verify-artifacts`; `promote` needs `build` |
| 19 | `ci.yml:26` | Mutable `:latest` tag | Immutable `<version>-<git sha7>`; push refuses to overwrite an existing tag; digest recorded |
| 20 | `ci.yml:27-29` | "Promotion" was an `echo` — nothing verified | Smoke test (health, detect, corrupt-engine → unhealthy ≤ 15 s), size + non-root policy, protected `site-release` environment |

Note: if the worker process dies, its container exits and `restart: unless-stopped` brings it back; the API reports `degraded`/503 meanwhile. The healthcheck covers the hung or corrupted case.

## 2. Field rollback — bad `eo_detector_fp16.engine` (target ≤ 15 min)

| T+ | Action |
|---|---|
| 0-3 | **Detect.** `docker compose -p eoir-stack ps` shows `inference_worker (unhealthy)`; `/health` → 503. Confirm: `docker compose -p eoir-stack logs --tail 50 inference_worker` (`checksum valid=False` or load error) |
| 3-5 | **Decide.** Engine at fault → roll back the model. Do not debug in the field |
| 5-7 | **Quarantine.** `cd /opt/eoir-stack/current && mkdir -p /opt/eoir-stack/quarantine/$(date +%s) && cp models/eo_detector_fp16.engine models/manifest.json /opt/eoir-stack/quarantine/<ts>/` |
| 7-10 | **Restore last good pair.** Engine and manifest always move **together**: `cp /opt/eoir-stack/previous/models/{eo_detector_fp16.engine,manifest.json} models/` (no `previous` yet → take both from the last-known-good bundle on the transfer media), then verify: `sha256sum models/eo_detector_fp16.engine` equals `"sha256"` in `models/manifest.json` |
| 10-12 | **Restart worker only.** `docker compose -p eoir-stack --env-file /opt/eoir-stack/.env restart inference_worker` (API needs no restart — it re-checks per request) |
| 12-14 | **Verify.** `ps` shows `healthy`; `curl -fsS localhost:8000/health` → `worker_ready:true`; `curl -fsS localhost:8000/api/v1/detect` → 200 |
| 14-15 | **Record.** Log time, operator, both hashes; attach quarantined files to a defect for the lab |

If the whole release is bad (not just the engine): `./deploy_airgap.sh` already auto-rolls back on failed health; manually, redeploy the previous bundle: `./deploy_airgap.sh /media/release_v<prev>.tar.gz`.

## 3. Preventing CUDA / TensorRT drift (x86_64 lab ↔ aarch64 Jetson Orin)

- **A TensorRT engine is not portable.** It is bound to GPU SM, TensorRT version, CUDA and driver. The shipped engine is TRT 8.6 / SM 8.7 → valid on Orin only. The lab server can never validate it by running it.
- **Ship ONNX as the source artifact; build the engine on the target class.** `trtexec --onnx=model.onnx --fp16 --saveEngine=…` runs on a reference Orin with the **same pinned JetPack/L4T** as the field units. One engine per target, never "multi-arch".
- **Pin the runtime stack.** Jetson image: `nvcr.io/nvidia/l4t-tensorrt:<exact tag>` matched to the JetPack version; x86 lab: `nvcr.io/nvidia/tensorrt:<exact tag>` with the same TRT major.minor. Pin by digest; build `linux/arm64` with `docker buildx`.
- **Manifest is the contract.** Per-target manifest records `target_arch`, `gpu_sm`, `tensorrt_version`, CUDA, L4T/JetPack and `sha256`. CI rejects a manifest whose fields do not match the build profile.
- **Refuse to run on mismatch.** Worker compares manifest `gpu_sm`/TRT to the device at startup and fails its health check if they differ; `deploy_airgap.sh` refuses a bundle whose `arch` differs from the host.
- **One bundle per architecture** (`release_v1.4.2-arm64.tar.gz`), each with its own `SHA256SUMS`, smoke-tested on real target hardware before it leaves the lab.
