#!/bin/sh
# Run the cl-llm memory image: one long-lived SBCL holding one memory
# store, served over SWANK on loopback for cl-mcp-server's remote-*
# tools and, on CL_LLM_MEMORY_MCP_PORT, as an MCP listener that agents
# reach through scripts/memory-mcp-client.lisp.  Set the port empty to
# run without the listener.  docs/agent-memory.md, "Running a memory
# image".
#
# graph-db stores are single-process: nothing else may hold the store
# while this runs, and the image refuses a store left dirty.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"

export CL_LLM_MEMORY_STORE="${CL_LLM_MEMORY_STORE:-$HOME/.cl-llm-memory/working/}"
export CL_LLM_MEMORY_SYSTEM="${CL_LLM_MEMORY_SYSTEM:-$HOME/.cl-llm-memory/system/}"
export CL_LLM_MEMORY_CLOCK="${CL_LLM_MEMORY_CLOCK:-$HOME/.cl-llm-memory/clock/}"
export CL_LLM_MEMORY_GRAPH="${CL_LLM_MEMORY_GRAPH:-cl-llm-memory}"
export CL_LLM_MEMORY_SWANK_PORT="${CL_LLM_MEMORY_SWANK_PORT:-4008}"
export CL_LLM_MEMORY_PRODUCER="${CL_LLM_MEMORY_PRODUCER:-claude-code/$(hostname -s)}"
export CL_LLM_MEMORY_BUFFER_POOL="${CL_LLM_MEMORY_BUFFER_POOL:-2000}"
# No colon: an EMPTY port turns the listener off, only unset defaults (#75).
export CL_LLM_MEMORY_MCP_PORT="${CL_LLM_MEMORY_MCP_PORT-4009}"
export CL_LLM_MEMORY_MCP_BIND="${CL_LLM_MEMORY_MCP_BIND:-127.0.0.1}"
export CL_LLM_MEMORY_PRINCIPALS="${CL_LLM_MEMORY_PRINCIPALS:-$HOME/.cl-llm-memory/principals.sexp}"
export CL_LLM_MEMORY_IDENTITY="${CL_LLM_MEMORY_IDENTITY:-secret}"
export CL_LLM_MEMORY_QUERY_TOOL="${CL_LLM_MEMORY_QUERY_TOOL:-}"
export CL_LLM_MEMORY_K="${CL_LLM_MEMORY_K:-5}"
export CL_LLM_MEMORY_MAX_ROWS="${CL_LLM_MEMORY_MAX_ROWS:-50}"
# The tested tree is this checkout unless the caller names others.
export CL_LLM_ASDF_REGISTRY="${CL_LLM_ASDF_REGISTRY:-$REPO/}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

exec sbcl --dynamic-space-size "${CL_LLM_MEMORY_HEAP_MB:-4096}" \
     --disable-debugger --load "$REPO/scripts/memory-image.lisp"
