#include "utils/cuda_utils.hpp"
#include "pagerank.hpp"

__global__ void
vertexPullWarpPageRank
( size_t warp_size
, size_t chunk_size
, CSR<unsigned,unsigned> *graph
, unsigned *degrees
, float *pagerank
, float *new_pagerank
)
{
    const int THREAD_ID = (blockIdx.x * blockDim.x) + threadIdx.x;
    const uint64_t vertex_count = graph->vertex_count;
    const uint64_t warpsPerBlock = blockDim.x / warp_size;

    const uint64_t WARP_ID = THREAD_ID / warp_size;
    const int W_OFF = THREAD_ID % warp_size;
    const size_t BLOCK_W_ID = threadIdx.x / warp_size;
    const size_t sharedOffset = chunk_size * BLOCK_W_ID;

    extern __shared__ unsigned MEM[];
    unsigned *myVertices = &MEM[sharedOffset + BLOCK_W_ID];

    for ( uint64_t chunkIdx = WARP_ID
        ; chunk_size * chunkIdx < vertex_count
        ; chunkIdx += warpsPerBlock * gridDim.x
        )
    {
        const size_t v_ = min(chunkIdx * chunk_size, vertex_count);
        const size_t end = min(chunk_size, (vertex_count - v_));

        memcpy_SIMD(warp_size, W_OFF, end + 1, myVertices, &graph->vertices[v_]);

        const unsigned * const rev_edges = graph->edges;
        for (int v = 0; v < end; v++) {
            float my_new_rank = 0;
            // num_nbr = incoming edges, so can't use degrees[]
            const unsigned num_nbr = myVertices[v+1] - myVertices[v];
            const unsigned *nbrs = &rev_edges[myVertices[v]];
            for (int i = W_OFF; i < num_nbr; i += warp_size) {
                int their_num_nbr = degrees[nbrs[i]];
                my_new_rank += pagerank[nbrs[i]] / their_num_nbr;
            }
            atomicAdd(&new_pagerank[v_ + v], my_new_rank);
        }
    }
}
