#include "bfs.hpp"

template<typename BFSVariant>
__global__ void
edgeListBfs(EdgeList<unsigned> *graph, int *levels, int depth)
{
    uint64_t size = graph->edge_count;
    BFSVariant bfs;
    int newDepth = depth + 1;

    for (uint64_t idx = blockIdx.x * blockDim.x + threadIdx.x;
         idx < size && levels[graph->inEdges[idx]] == depth;
         idx += blockDim.x * gridDim.x)
    {
        if (atomicMin(&levels[graph->outEdges[idx]], newDepth) > newDepth) {
            bfs.update();
        }
    }
    bfs.finalise();
}

#ifndef __APPLE__
template __global__ void
edgeListBfs<Reduction<normal>>(EdgeList<unsigned> *, int *, int);

template __global__ void
edgeListBfs<Reduction<bulk>>(EdgeList<unsigned> *, int *, int);

template __global__ void
edgeListBfs<Reduction<warpreduce>>(EdgeList<unsigned> *, int *, int);

template __global__ void
edgeListBfs<Reduction<blockreduce>>(EdgeList<unsigned> *, int *, int);
#endif
