#!/bin/sh
# The cl-llm memory as a stdio MCP server, one process per client
# session: `claude mcp add --scope user memory -- <this script>`.
# docs/agent-memory.md, "The memory as an MCP server".
#
# graph-db stores are single-process: if a memory image (or another
# session's solo server) holds the store, this exits 1 with a message
# on stderr and never starts the handshake.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"

export CL_LLM_MEMORY_STORE="${CL_LLM_MEMORY_STORE:-$HOME/.cl-llm-memory/working/}"
export CL_LLM_MEMORY_SYSTEM="${CL_LLM_MEMORY_SYSTEM:-$HOME/.cl-llm-memory/system/}"
export CL_LLM_MEMORY_CLOCK="${CL_LLM_MEMORY_CLOCK:-$HOME/.cl-llm-memory/clock/}"
export CL_LLM_MEMORY_GRAPH="${CL_LLM_MEMORY_GRAPH:-cl-llm-memory}"
export CL_LLM_MEMORY_PRODUCER="${CL_LLM_MEMORY_PRODUCER:-claude-code/$(hostname -s)}"
export CL_LLM_MEMORY_BUFFER_POOL="${CL_LLM_MEMORY_BUFFER_POOL:-2000}"
export CL_LLM_MEMORY_SCOPE="${CL_LLM_MEMORY_SCOPE:-}"
export CL_LLM_MEMORY_WRITE="${CL_LLM_MEMORY_WRITE:-}"
export CL_LLM_MEMORY_QUERY_TOOL="${CL_LLM_MEMORY_QUERY_TOOL:-}"
# The tested tree is this checkout unless the caller names others.
export CL_LLM_ASDF_REGISTRY="${CL_LLM_ASDF_REGISTRY:-$REPO/}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

exec sbcl --dynamic-space-size "${CL_LLM_MEMORY_HEAP_MB:-4096}" \
     --script "$REPO/scripts/memory-mcp.lisp"
