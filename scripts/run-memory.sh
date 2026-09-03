#!/bin/sh
# Run the cl-llm memory image: one long-lived SBCL holding one memory
# store, served over SWANK on loopback for cl-mcp-server's remote-*
# tools.  docs/agent-memory.md, "Running a memory image".
#
# graph-db stores are single-process: nothing else may hold the store
# while this runs, and the image refuses a store left dirty.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"

export CL_LLM_MEMORY_STORE="${CL_LLM_MEMORY_STORE:-$HOME/.cl-llm-memory/working/}"
export CL_LLM_MEMORY_SYSTEM="${CL_LLM_MEMORY_SYSTEM:-$HOME/.cl-llm-memory/system/}"
export CL_LLM_MEMORY_GRAPH="${CL_LLM_MEMORY_GRAPH:-cl-llm-memory}"
export CL_LLM_MEMORY_SWANK_PORT="${CL_LLM_MEMORY_SWANK_PORT:-4008}"
export CL_LLM_MEMORY_PRODUCER="${CL_LLM_MEMORY_PRODUCER:-claude-code/$(hostname -s)}"
export CL_LLM_MEMORY_BUFFER_POOL="${CL_LLM_MEMORY_BUFFER_POOL:-2000}"

exec sbcl --dynamic-space-size "${CL_LLM_MEMORY_HEAP_MB:-4096}" \
     --disable-debugger --load "$REPO/scripts/memory-image.lisp"
