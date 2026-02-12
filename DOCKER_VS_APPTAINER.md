# Docker vs Apptainer: What Changed

## Summary

The original mle-bench used **Docker** for containerization, which is not available on most HPC clusters. We've adapted it to use **Apptainer** (formerly Singularity), which is the standard containerization tool on HPC systems.

## Key Differences

### Container Technology

| Aspect | Docker (Original) | Apptainer (HPC) |
|--------|-------------------|-----------------|
| **Privilege** | Requires root/daemon | Runs as regular user |
| **Runtime** | Docker daemon | Direct container execution |
| **Images** | Docker images | SIF (Singularity Image Format) |
| **Build** | `docker build` | `apptainer build` |
| **Run** | `docker run` | `apptainer run/exec` |
| **Network** | Docker networks | Host network by default |
| **Storage** | Docker volumes | Bind mounts |

### Execution Model

#### Docker (Original)
```python
# agents/run.py
import docker
client = docker.DockerClient()
container = client.containers.run(image, ...)
container.exec_run(cmd)
```

#### Apptainer (HPC)
```bash
# scripts_hpc/slurm_aide_qwen.sh
apptainer exec --nv \
    --bind /data:/home/data \
    aide-qwen.sif \
    bash /home/agent/start.sh
```

## Architecture Comparison

### Original Docker Architecture
```
┌──────────────────────────────────────┐
│   Host (with Docker daemon)          │
│                                      │
│  ┌─────────────────────────────┐   │
│  │  Docker Container           │   │
│  │  ┌──────────────────────┐   │   │
│  │  │  Grading Server      │   │   │
│  │  │  (port 5000)         │   │   │
│  │  └──────────────────────┘   │   │
│  │  ┌──────────────────────┐   │   │
│  │  │  AIDE Agent          │   │   │
│  │  │  - Uses OpenAI API   │   │   │
│  │  └──────────────────────┘   │   │
│  └─────────────────────────────┘   │
└──────────────────────────────────────┘
```

### New Apptainer Architecture
```
┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐
│   CPU Node         │  │   GPU Node         │  │   Same GPU Node    │
│                    │  │                    │  │                    │
│ ┌────────────────┐ │  │ ┌────────────────┐ │  │ ┌────────────────┐ │
│ │ Apptainer      │ │  │ │ Apptainer      │ │  │ │ Apptainer      │ │
│ │ Container      │ │  │ │ Container      │ │  │ │ Container      │ │
│ │ ┌────────────┐ │ │  │ │ ┌────────────┐ │ │  │ │ ┌────────────┐ │ │
│ │ │ Grading    │ │ │  │ │ │ vLLM       │ │ │  │ │ │ AIDE Agent │ │ │
│ │ │ Server     │◀┼─┼──┼─┤ │ Server     │◀┼─┼──┼─┤ │            │ │ │
│ │ │ (port 5000)│ │ │  │ │ │ (port 8000)│ │ │  │ │ │ localhost: │ │ │
│ │ └────────────┘ │ │  │ │ └────────────┘ │ │  │ │ │ 8000       │ │ │
│ └────────────────┘ │  │ └────────────────┘ │  │ └────────────────┘ │
└────────────────────┘  └────────────────────┘  └────────────────────┘
  SLURM Job #1           SLURM Job #2            SLURM Job #3
                                                 (same node as Job #2)
```

## File Changes

### Modified Files

1. **Container Definitions**
   - Old: `agents/aide/Dockerfile`
   - New: `containers/aide-qwen.def`

2. **Execution Scripts**
   - Old: `agents/run.py` (Python with Docker API)
   - New: `scripts_hpc/slurm_aide_qwen.sh` (Bash with Apptainer)

3. **Build Process**
   - Old: `docker build -t aide .`
   - New: `apptainer build aide-qwen.sif aide-qwen.def`

### New Files Created

```
containers/
├── aide-qwen.def                  # AIDE container for Apptainer
├── qwen3-30b-vllm.def            # vLLM container for 30B model
├── qwen3-80b-vllm.def            # vLLM container for 80B model
├── build_containers.sh            # Build script for vLLM
├── launch_vllm_servers.sh         # Local launch script
└── *_vllm_*.sh                    # Management scripts

scripts_hpc/
├── slurm_aide_qwen.sh            # AIDE with Qwen on SLURM
├── slurm_vllm_qwen30b.sh         # vLLM 30B on SLURM
├── slurm_vllm_qwen80b.sh         # vLLM 80B on SLURM
├── run_aide_qwen_workflow.sh     # Complete workflow orchestration
└── slurm_grading_server.sh       # (Already existed)

Documentation/
├── AIDE_QWEN_COMPLETE_GUIDE.md   # Complete guide
├── QUICKSTART_QWEN.md             # Quick start guide
└── DOCKER_VS_APPTAINER.md         # This file
```

## Workflow Comparison

### Docker Workflow (Original)

```bash
# 1. Build Docker image
docker build -t aide:latest -f agents/aide/Dockerfile .

# 2. Run with Python script
python run_agent.py --agent aide --competition spaceship-titanic

# Behind the scenes (agents/run.py):
# - Creates Docker container
# - Mounts volumes
# - Executes agent command
# - Extracts results
# - Cleans up container
```

### Apptainer Workflow (HPC)

```bash
# 1. Build Apptainer containers (one-time)
cd containers
./build_containers.sh                    # vLLM servers
apptainer build aide-qwen.sif aide-qwen.def  # AIDE agent

# 2. Run complete workflow
scripts_hpc/run_aide_qwen_workflow.sh spaceship-titanic 30b

# Behind the scenes:
# - Submits grading server job (CPU node)
# - Submits vLLM server job (GPU node)
# - Submits AIDE job (same GPU node as vLLM)
# - All communicate via network
```

## API Integration Changes

### Original: Direct OpenAI API

```yaml
# agents/aide/config.yaml
aide:
  kwargs:
    agent.code.model: gpt-4o-2024-08-06
  env_vars:
    OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
```

### New: Local vLLM with OpenAI-Compatible API

```yaml
# agents/aide/config.yaml
aide/qwen3-30b:
  kwargs:
    agent.code.model: qwen3-30b
    agent.code.api_base: http://localhost:8000/v1
  env_vars:
    OPENAI_API_KEY: "dummy-key"
```

## Networking Changes

### Docker
- **Internal network**: Containers can communicate via Docker network names
- **Port mapping**: Explicit port mapping required (`-p 5000:5000`)
- **DNS**: Docker provides built-in DNS for container names

### Apptainer
- **Host network**: Containers use host networking by default
- **localhost**: Services on same node use `localhost:<port>`
- **Cross-node**: Services on different nodes use `<hostname>:<port>`

**Critical Requirement**: AIDE and vLLM must run on the **same physical node** to use `localhost:8000`.

## Storage and Bind Mounts

### Docker Volumes
```bash
docker run -v /host/path:/container/path ...
```

### Apptainer Bind Mounts
```bash
apptainer exec --bind /host/path:/container/path ...
```

**Key difference**: Apptainer requires explicit bind mounts for each directory.

## Security and Privileges

### Docker
- Requires root or docker group membership
- Daemon runs as root
- Potential security concerns on multi-user systems

### Apptainer
- Runs as regular user
- No daemon required
- Designed for HPC multi-user environments
- Better isolation and security

## GPU Access

### Docker
```bash
docker run --gpus all ...
```

Requires:
- NVIDIA Docker runtime
- nvidia-docker2 package

### Apptainer
```bash
apptainer exec --nv ...
```

Requires:
- NVIDIA drivers on host
- `--nv` flag (simpler, no special runtime)

## Build Process Comparison

### Docker Build
```dockerfile
# Dockerfile
FROM nvidia/cuda:11.8.0-runtime-ubuntu22.04
RUN apt-get update && ...
COPY . /app
```

```bash
docker build -t myimage .
```

### Apptainer Build
```singularity
# container.def
Bootstrap: docker
From: nvidia/cuda:11.8.0-runtime-ubuntu22.04

%post
    apt-get update && ...

%files
    file.txt /app/file.txt
```

```bash
apptainer build myimage.sif container.def
```

**Key difference**: Apptainer uses definition files (`.def`) similar to Dockerfiles but with different sections (`%post`, `%files`, `%environment`).

## Why This Change Was Necessary

1. **HPC Standard**: Most HPC clusters don't allow Docker due to security concerns
2. **No Root Required**: Apptainer doesn't need privileged access
3. **Better Integration**: Apptainer integrates with SLURM and HPC schedulers
4. **Shared Resources**: Better support for shared filesystems (like Lustre, GPFS)
5. **Performance**: Optimized for HPC workloads

## Migration Checklist

If migrating from Docker to Apptainer:

- [x] Convert Dockerfile to `.def` format
- [x] Replace Docker API calls with Apptainer CLI
- [x] Update volume mounts to bind mounts
- [x] Handle networking (ensure same-node for localhost)
- [x] Update environment variable passing
- [x] Modify build scripts
- [x] Update documentation
- [x] Test on HPC cluster

## Common Issues and Solutions

### Issue: "Cannot connect to Docker daemon"
**Cause**: HPC clusters don't run Docker daemon  
**Solution**: Use Apptainer instead

### Issue: "Permission denied" when building
**Cause**: Apptainer build may need privileges  
**Solution**: Use `--fakeroot` flag or `--remote`

### Issue: AIDE can't reach vLLM at localhost:8000
**Cause**: Jobs running on different nodes  
**Solution**: Force same node with `--nodelist=$VLLM_NODE`

### Issue: GPU not available in container
**Cause**: Missing `--nv` flag  
**Solution**: Always use `apptainer exec --nv` for GPU access

## Performance Comparison

| Aspect | Docker | Apptainer |
|--------|---------|-----------|
| **Startup Time** | ~1-2s | ~0.5-1s |
| **Overhead** | Minimal | Near-native |
| **GPU Performance** | Native | Native |
| **I/O Performance** | Good | Excellent (direct filesystem) |
| **Multi-tenancy** | Limited | Excellent |

## Conclusion

The migration from Docker to Apptainer enables:
- ✅ Running on HPC clusters without special privileges
- ✅ Better integration with SLURM and resource managers
- ✅ Improved security in multi-user environments
- ✅ Native performance with HPC storage systems
- ✅ Use of local Qwen models via vLLM

The new architecture maintains all functionality while being HPC-native and more flexible for research workflows.
