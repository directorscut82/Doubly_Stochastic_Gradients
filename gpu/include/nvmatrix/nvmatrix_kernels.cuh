/* 
 * Copyright (c) 2011, Alex Krizhevsky (akrizhevsky@gmail.com)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * 
 * - Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
 * EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#ifndef NVMATRIX_KERNEL_H_
#define NVMATRIX_KERNEL_H_

#include <curand_kernel.h>

#if defined(_WIN64) || defined(_WIN32)
#define uint unsigned int
#endif

#define NUM_BLOCKS_MAX                      65535

#define NUM_RND_BLOCKS                      96
#define NUM_RND_THREADS_PER_BLOCK           128
#define NUM_RND_STREAMS                     (NUM_RND_BLOCKS * NUM_RND_THREADS_PER_BLOCK)

/*
 * Default grid/block sizes for the various functions.
 */
#define ADD_BLOCK_SIZE                      16

#define NUM_TILE_BLOCKS                     4096
#define NUM_TILE_THREADS_PER_BLOCK          512

#define ELTWISE_THREADS_X                   32
#define ELTWISE_THREADS_Y                   8

#define NUM_SUM_COLS_THREADS_PER_BLOCK      256

#define AGG_SHORT_ROWS_THREADS_X            32
#define AGG_SHORT_ROWS_THREADS_Y            8
#define AGG_SHORT_ROWS_LOOPS_Y              32

#define DP_BLOCKSIZE                        512
#define CPUSUM_MAX                          4096

#define ADD_VEC_THREADS_X                   64
#define ADD_VEC_THREADS_Y                   4

#ifndef DIVUP
#define DIVUP(x, y) (((x) + (y) - 1) / (y))
#endif

#define MYMAX(a, b) ((a) > (b) ? (a) : (b))

#ifndef MUL24 // legacy
#define MUL24(x,y) ((x) * (y))
#endif

#define AWR_NUM_THREADS           256
#define WARP_SIZE                 32
#define AWR_NUM_WARPS             AWR_NUM_THREADS / WARP_SIZE 
#define AWR_LOG_NUM_THREADS       8
#define LOG_WARP_SIZE             5
#define AWR_LOG_NUM_WARPS         3

__global__ void kTile(const float* src, float* tgt, const uint srcWidth, const uint srcHeight, const uint tgtWidth, const uint tgtHeight);
__global__ void kDotProduct_r(float* a, float* b, float* target, const uint numCols, const uint numElements);
__global__ void kSetupCurand(curandState *state, unsigned long long seed);
__global__ void kRowPermute(const float* mat, const float* perm_idx, float* const target, const uint with, const uint height, const uint matStride, const uint tgtStride);

/*
 * For now this is supported only for arrays with the same transposedness.
 */
template<class Op>
__global__ void kEltwiseTernaryOp(const float* a, const float* b, const float* c, float* const dest,
                                  const uint height, const uint width, uint strideA, const uint strideB, const uint strideC,
                                  const uint strideDest, Op op) {
    const uint idxX = blockIdx.x * ELTWISE_THREADS_X + threadIdx.x;
    const uint idxY = blockIdx.y * ELTWISE_THREADS_Y + threadIdx.y;

    for (uint y = idxY; y < height; y += gridDim.y * ELTWISE_THREADS_Y) {
        for (uint x = idxX; x < width; x += gridDim.x * ELTWISE_THREADS_X) {
            dest[y * strideDest + x] = op(a[y * strideA + x], b[y * strideB + x], c[y * strideC + x]);
        }
    }
}

/*
 * dest here is assumed to be "not transposed" -- height and width correspond to it.
 * b is assumed to be transposed.
 * a can be either transposed or not -- depending on parameter.
 * 
 * Performs dest := op(a, b)
 */
template<class Op, bool checkBounds, bool aTrans, bool reverse>
__global__ void kEltwiseBinaryOpTrans(const float* a, const float* b, float* const dest,
                             const uint height, const uint width,
                             const uint strideA, const uint strideB, const uint strideDest, Op op) {

    __shared__ float shmem[ELTWISE_THREADS_X][ELTWISE_THREADS_X + 1];

    // x here because that's how much work we do
    for (uint by = ELTWISE_THREADS_X * blockIdx.y; by < height; by += ELTWISE_THREADS_X * gridDim.y) {
        for (uint bx = ELTWISE_THREADS_X * blockIdx.x; bx < width; bx += ELTWISE_THREADS_X * gridDim.x) {
            const uint readX = by + threadIdx.x;
            const uint readY = bx + threadIdx.y;

            for (uint y = 0; y < ELTWISE_THREADS_X; y+= ELTWISE_THREADS_Y) {
                if (!checkBounds || (readX < height && readY + y < width)) {
                    if (aTrans) {
                        shmem[threadIdx.x][threadIdx.y + y] = reverse ? op(b[(readY+y) * strideB + readX], a[(readY+y) * strideA + readX])
                                                                      : op(a[(readY+y) * strideA + readX], b[(readY+y) * strideB + readX]);
                    } else {
                        shmem[threadIdx.x][threadIdx.y + y] = b[(readY+y) * strideB + readX];
                    }
                }
            }
            __syncthreads();

            const uint writeX = bx + threadIdx.x;
            const uint writeY = by + threadIdx.y;

            for (uint y = 0; y < ELTWISE_THREADS_X; y+= ELTWISE_THREADS_Y) {
                if(!checkBounds || (writeX < width && writeY + y < height)) {
                    if (aTrans) {
                        dest[(writeY + y) * strideDest + writeX] = shmem[threadIdx.y + y][threadIdx.x];
                    } else {
                        dest[(writeY + y) * strideDest + writeX] = reverse ? op(shmem[threadIdx.y + y][threadIdx.x], a[(writeY + y) * strideA + writeX])
                                                                           : op(a[(writeY + y) * strideA + writeX], shmem[threadIdx.y + y][threadIdx.x]);
                    }
                }
            }
            __syncthreads();
        }
    }
}
template<class Op>
__global__ void kEltwiseBinaryOp(const float* a, const float* b, float* const dest, const uint height, const uint width,
                             const uint strideA, const uint strideB, const uint strideDest, Op op) {
    const uint idxX = blockIdx.x * ELTWISE_THREADS_X + threadIdx.x;
    const uint idxY = blockIdx.y * ELTWISE_THREADS_Y + threadIdx.y;

    for (uint y = idxY; y < height; y += gridDim.y * ELTWISE_THREADS_Y) {
        for (uint x = idxX; x < width; x += gridDim.x * ELTWISE_THREADS_X) {
            dest[y * strideDest + x] = op(a[y * strideA + x], b[y * strideB + x]);
        }
    }
}

/*
 * dest here is assumed to be "not transposed" -- height and width correspond to it.
 */
template<class Op, bool checkBounds>
__global__ void kEltwiseUnaryOpTrans(const float* a, float* const dest,
                                     const uint height, const uint width,
                                     const uint strideA, const uint strideDest, Op op) {

    __shared__ float shmem[ELTWISE_THREADS_X][ELTWISE_THREADS_X + 1];

    for (uint by = ELTWISE_THREADS_X * blockIdx.y; by < height; by += ELTWISE_THREADS_X * gridDim.y) {
        for (uint bx = ELTWISE_THREADS_X * blockIdx.x; bx < width; bx += ELTWISE_THREADS_X * gridDim.x) {
            const uint readX = by + threadIdx.x;
            const uint readY = bx + threadIdx.y;
            for (uint y = 0; y < ELTWISE_THREADS_X; y+= ELTWISE_THREADS_Y) {
                if (!checkBounds || (readX < height && readY + y < width)) {
                    shmem[threadIdx.x][threadIdx.y + y] = op(a[(readY + y) * strideA + readX]);
                }
            }
            __syncthreads();

            const uint writeX = bx + threadIdx.x;
            const uint writeY = by + threadIdx.y;
            for (uint y = 0; y < ELTWISE_THREADS_X; y+= ELTWISE_THREADS_Y) {
                if(!checkBounds || (writeX < width && writeY + y < height)) {
                    dest[(writeY + y) * strideDest + writeX] = shmem[threadIdx.y + y][threadIdx.x];

                }
            }
            __syncthreads();
        }
    }
}

template<class Op>
__global__ void kEltwiseUnaryOp(const float* a, float* const dest, const uint height, const uint width,
                                const uint strideA, const uint strideDest, Op op) {
    const uint idxX = blockIdx.x * ELTWISE_THREADS_X + threadIdx.x;
    const uint idxY = blockIdx.y * ELTWISE_THREADS_Y + threadIdx.y;

    for (uint y = idxY; y < height; y += gridDim.y * ELTWISE_THREADS_Y) {
        for (uint x = idxX; x < width; x += gridDim.x * ELTWISE_THREADS_X) {
            dest[y * strideDest + x] = op(a[y * strideA + x]);
        }
    }
}

/*
 * Matrix in ROW-MAJOR order!
 */
template <class Op>
__global__ void kRowVectorOp(const float* mat, const float* vec, float* const tgtMat, const uint width, const uint height,
                             const uint matStride, const uint tgtStride, Op op) {
    __shared__ float shVec[ADD_VEC_THREADS_X];
    const uint bx = ADD_VEC_THREADS_X * blockIdx.x;
    const uint by = ADD_VEC_THREADS_Y * blockIdx.y;

    for (uint x = bx; x < width; x += gridDim.x * ADD_VEC_THREADS_X) {
        __syncthreads();
        if (x + threadIdx.x < width && threadIdx.y == 0) {
            shVec[threadIdx.x] = vec[x + threadIdx.x];
        }
        __syncthreads();

        if (x + threadIdx.x < width) {
            for (uint y = by + threadIdx.y; y < height; y += gridDim.y * ADD_VEC_THREADS_Y) {
                tgtMat[y * tgtStride + x + threadIdx.x] = op(mat[y * matStride + x + threadIdx.x], shVec[threadIdx.x]);
            }
        }
    }
}

/*
 * Matrix in ROW-MAJOR order!
 */
template <class Op>
__global__ void kColVectorOp(const float* mat, const float* vec, float* const tgtMat,
                             const uint width, const uint height,
                             const uint matStride, const uint tgtStride, Op op) {
    __shared__ float shVec[ADD_VEC_THREADS_Y];
    const uint by = ADD_VEC_THREADS_Y * blockIdx.y;
    const uint bx = ADD_VEC_THREADS_X * blockIdx.x;
//    const uint matIdx = (by + threadIdx.y) * matStride + bx + threadIdx.x;
//    const uint tgtIdx = (by + threadIdx.y) * tgtStride + bx + threadIdx.x;
    const uint tidx = ADD_VEC_THREADS_X * threadIdx.y + threadIdx.x;

    for (uint y = by; y < height; y += gridDim.y * ADD_VEC_THREADS_Y) {
        __syncthreads();
        if (y + tidx < height && tidx < ADD_VEC_THREADS_Y) {
            shVec[tidx] = vec[y + tidx];
        }
        __syncthreads();

        if (y + threadIdx.y < height) {
            for (uint x = bx + threadIdx.x; x < width; x += gridDim.x * ADD_VEC_THREADS_X) {
                tgtMat[(y+threadIdx.y) * tgtStride + x] = op(mat[(y+threadIdx.y) * matStride + x], shVec[threadIdx.y]);
            }
        }
    }
}

/*
 * This one gets coalesced reads but computes only a partial sum which
 * must either be summed again (recursively) or summed on the host.
 */
template<class Agg, class BinaryOp, int blockSize>
__global__ void kAggRows(const float* mat, float* matSum, const uint width, const uint height, const uint sumWidth, Agg agg, BinaryOp op) {
    const int idxX = blockIdx.x * blockSize*2 + threadIdx.x;

    __shared__ float accum[blockSize*2];

    matSum += blockIdx.y * sumWidth + blockIdx.x;
    /*
     * Here it's important to make sure that all threads in a block call __syncthreads,
     * so I have even the redundant threads (for which idxX >= width) enter this loop
     * just so that they may call __syncthreads at the appropriate times.
     */
    mat += width * blockIdx.y + idxX;

    accum[threadIdx.x] = agg.getBaseValue();
    accum[threadIdx.x + blockSize] = agg.getBaseValue();
    for (uint idxY = blockIdx.y; idxY < height; idxY += gridDim.y) {
        if (idxX < width) {
            accum[threadIdx.x] = mat[0];
            if(idxX + blockSize < width)
                accum[threadIdx.x + blockSize] = mat[blockSize];
        }
        if (blockSize >= 512) {
            __syncthreads();
            if (threadIdx.x < 512)
                accum[threadIdx.x] = agg(accum[threadIdx.x], accum[threadIdx.x + 512]);
        }
        if (blockSize >= 256) {
            __syncthreads();
            if (threadIdx.x < 256)
                accum[threadIdx.x] = agg(accum[threadIdx.x],accum[threadIdx.x + 256]);
        }
        if (blockSize >= 128) {
            __syncthreads();
            if (threadIdx.x < 128)
                accum[threadIdx.x] = agg(accum[threadIdx.x],accum[threadIdx.x + 128]);
        }
        if (blockSize >= 64) {
            __syncthreads();
            if (threadIdx.x < 64)
                accum[threadIdx.x] = agg(accum[threadIdx.x],accum[threadIdx.x + 64]);
        }

        __syncthreads();
        volatile float* myAccum = &accum[threadIdx.x];
        if (threadIdx.x < 32) { // executed only by first warp
            myAccum[0] = agg(myAccum[0], myAccum[32]);
            myAccum[0] = agg(myAccum[0], myAccum[16]);
            myAccum[0] = agg(myAccum[0], myAccum[8]);
            myAccum[0] = agg(myAccum[0], myAccum[4]);
            myAccum[0] = agg(myAccum[0], myAccum[2]);
            myAccum[0] = agg(myAccum[0], myAccum[1]);
        }

        if (threadIdx.x == 0) {
            matSum[0] = op(matSum[0], myAccum[0]);
            matSum += gridDim.y * sumWidth;
        }
        __syncthreads();
        mat += width * gridDim.y;
    }
}

template<class Agg, class BinaryOp>
__global__ void kAggRows_wholerow(const float* mat, float* matSum, const uint width, const uint height, Agg agg, BinaryOp op) {
    const int tidx = threadIdx.x;

    __shared__ float accum[AWR_NUM_THREADS];
    volatile float* vMyAccum = &accum[tidx];
    float* myAccum = &accum[tidx];
    
    matSum += blockIdx.y;
    mat += width * blockIdx.y;

    for (uint idxY = blockIdx.y; idxY < height; idxY += gridDim.y) {
        myAccum[0] = agg.getBaseValue();
        for (uint x = tidx; x < width; x += AWR_NUM_THREADS) {
            myAccum[0] = agg(myAccum[0], mat[x]);
        }
        #pragma unroll
        for (uint i = AWR_LOG_NUM_THREADS - 1; i > LOG_WARP_SIZE; i--) {
            const uint d = 1 << i;
            __syncthreads();
            if (tidx < d) {
                myAccum[0] = agg(myAccum[0], myAccum[d]);
            }
        }
        __syncthreads();
        if (tidx < WARP_SIZE) {
            #pragma unroll
            for (int i = LOG_WARP_SIZE; i >= 0; i--) {
                const uint d = 1 << i;
                vMyAccum[0] = agg(vMyAccum[0], vMyAccum[d]);
            }

            if (tidx == 0) {
                matSum[0] = op(matSum[0], vMyAccum[0]);
                matSum += gridDim.y;
            }
        }
        __syncthreads();
        mat += width * gridDim.y;
    }
}

/*
 * Implements multiscan idea from http://www.moderngpu.com
 * Not really useful for pure reductions but neat nonetheless.
 */
template<class Agg, class BinaryOp>
__global__ void kAggRows_wholerow_nosync(const float* mat, float* matSum, const uint width, const uint height,
                                         Agg agg, BinaryOp op) {
    const uint tidx = threadIdx.x;
    const uint warpIdx = tidx / WARP_SIZE;
    const uint tidxInWarp = tidx % WARP_SIZE;
    
    __shared__ float accum[(WARP_SIZE + 1) * AWR_NUM_WARPS + WARP_SIZE/2];
    __shared__ float finalAccum[AWR_NUM_WARPS + AWR_NUM_WARPS / 2];

    float* myAccum = &accum[warpIdx * (WARP_SIZE + 1) + tidxInWarp];
    volatile float* vMyAccum = &accum[warpIdx * (WARP_SIZE + 1) + tidxInWarp];
    matSum += blockIdx.y;
    mat += width * blockIdx.y;

    for (uint idxY = blockIdx.y; idxY < height; idxY += gridDim.y) {
        float rAccum = agg.getBaseValue(); // cache in register, a bit faster than shmem
        for (uint x = tidx; x < width; x += AWR_NUM_THREADS) {
            rAccum = agg(rAccum, mat[x]);
        }
        myAccum[0] = rAccum;
        
        // Each warp does a reduction that doesn't require synchronizatoin
        #pragma unroll
        for (uint i = 0; i < LOG_WARP_SIZE; i++) {
            const uint d = 1 << i;
            vMyAccum[0] = agg(vMyAccum[0], vMyAccum[d]);
        }
        __syncthreads();
        // The warps write their results
        if (tidx < AWR_NUM_WARPS) {
            volatile float* vMyFinalAccum = &finalAccum[tidx];
            vMyFinalAccum[0] = accum[tidx * (WARP_SIZE + 1)];
            #pragma unroll
            for (uint i = 0; i < AWR_LOG_NUM_WARPS; i++) {
                const uint d = 1 << i;
                vMyFinalAccum[0] = agg(vMyFinalAccum[0], vMyFinalAccum[d]);
            }
            if (tidx == 0) {
                matSum[0] = op(matSum[0], vMyFinalAccum[0]);
                matSum += gridDim.y;
            }
        }
        __syncthreads();

        mat += width * gridDim.y;
    }
}

/*
 * To be used when the rows are <= 64.
 *
 * TODO: try to reduce reg usage. i think this can be made faster too.
 */
//#define AGG_SHORT_ROWS_LOOPS_X  4
template <class Agg, class BinaryOp, int LOOPS_X, int THREADS_X>
__global__ void kAggShortRows(const float* mat, float* matSum, const uint width, const uint height, Agg agg, BinaryOp op) {
    const uint shmemX = THREADS_X + 1;
    __shared__ float shmem[AGG_SHORT_ROWS_THREADS_Y*shmemX];

    const uint tidx = threadIdx.y * THREADS_X + threadIdx.x;
    const uint ty = LOOPS_X == 1 ? tidx / width : threadIdx.y; // when loops==1, width is gonna be smaller than block x dim
    const uint tx = LOOPS_X == 1 ? tidx % width : threadIdx.x;
    const uint bidx = blockIdx.y * gridDim.x + blockIdx.x;
    const uint blockRowIdx = bidx * AGG_SHORT_ROWS_LOOPS_Y * AGG_SHORT_ROWS_THREADS_Y;
    float* shmemWrite = shmem + MUL24(ty, shmemX) + tx;
    matSum += blockRowIdx + tidx;
//    shmem[MUL24(threadIdx.y, shmemX) + threadIdx.x] = 0;
    mat += width * blockRowIdx + MUL24(ty, width) + tx;
    float* shmemWriteZeros = &shmem[MUL24(threadIdx.y,shmemX) + threadIdx.x];

    bool doAgg = tidx < AGG_SHORT_ROWS_THREADS_Y ;

    if (blockRowIdx < height) {
#pragma unroll
        for (uint y = 0; y < AGG_SHORT_ROWS_LOOPS_Y*AGG_SHORT_ROWS_THREADS_Y; y += AGG_SHORT_ROWS_THREADS_Y) {
            doAgg &= tidx + y + blockRowIdx < height;
            const bool heightIdxOK = ty < AGG_SHORT_ROWS_THREADS_Y && ty + y + blockRowIdx < height;

            shmemWriteZeros[0] = agg.getBaseValue();
            __syncthreads();
#pragma unroll
            for(uint x = 0; x < LOOPS_X * THREADS_X; x+= THREADS_X) {
//                __syncthreads();
                if (heightIdxOK && x + tx < width) {
                    shmemWrite[0] = agg(mat[x], shmemWrite[0]);
                }
            }
            __syncthreads();
            if (doAgg) {
                /*
                 * I tried doing this final sum as a 4-step reduction, with 8 threads
                 * per warp participating. It was slightly slower.
                 */
                float accum = agg.getBaseValue();
                float* shmemRead = shmem + MUL24(tidx, shmemX);
                // this loops too much if the rows are really short :(
#pragma unroll
                for (uint i = 0; i < THREADS_X; i++) {
                    accum = agg(accum, shmemRead[0]);
                    shmemRead++;
                }
                matSum[0] = op(matSum[0], accum);
                matSum += AGG_SHORT_ROWS_THREADS_Y;
            }
            __syncthreads();
            mat += width * AGG_SHORT_ROWS_THREADS_Y;
        }
    }
}

template <class Agg, class BinaryOp>
__global__ void kAggShortRows2(const float* mat, float* matSum, const uint width, const uint height, Agg agg, BinaryOp op) {
    const uint shmemX = AGG_SHORT_ROWS_THREADS_X + 1;
    __shared__ float shmem[AGG_SHORT_ROWS_THREADS_Y*shmemX];
    const uint LOOPS_X = DIVUP(width, AGG_SHORT_ROWS_THREADS_X);
    const uint tidx = threadIdx.y * AGG_SHORT_ROWS_THREADS_X + threadIdx.x;

    const uint bidx = blockIdx.y * gridDim.x + blockIdx.x;
    const uint blockRowIdx = bidx * AGG_SHORT_ROWS_LOOPS_Y * AGG_SHORT_ROWS_THREADS_Y;

    float* shmemWrite = shmem + MUL24(threadIdx.y, shmemX) + threadIdx.x;
    matSum += blockRowIdx + tidx;
//    shmem[MUL24(threadIdx.y, shmemX) + threadIdx.x] = 0;
    mat += width * blockRowIdx + MUL24(threadIdx.y, width) + threadIdx.x;

    bool doAgg = tidx < AGG_SHORT_ROWS_THREADS_Y;
    if(blockRowIdx < height) {
        for (uint y = 0; y < AGG_SHORT_ROWS_LOOPS_Y*AGG_SHORT_ROWS_THREADS_Y; y += AGG_SHORT_ROWS_THREADS_Y) {
            doAgg &= tidx + y + blockRowIdx < height;
            const bool heightIdxOK = threadIdx.y + y + blockRowIdx < height;
            float accum = agg.getBaseValue();
            shmemWrite[0] = agg.getBaseValue();

            for(uint x = 0; x < LOOPS_X * AGG_SHORT_ROWS_THREADS_X; x+= AGG_SHORT_ROWS_THREADS_X) {
//                __syncthreads();
                if (heightIdxOK && x + threadIdx.x < width) {
                    shmemWrite[0] = agg(mat[x], shmemWrite[0]);
                }
            }

            __syncthreads();
            if (doAgg) {
                float* shmemRead = shmem + MUL24(tidx, shmemX);

#pragma unroll
                for (uint i = 0; i < AGG_SHORT_ROWS_THREADS_X; i++) {
                    accum = agg(accum, shmemRead[0]);
                    shmemRead++;
                }

                matSum[0] = op(matSum[0], accum);
                matSum += AGG_SHORT_ROWS_THREADS_Y;
            }
            __syncthreads();
            mat += width * AGG_SHORT_ROWS_THREADS_Y;
        }
    }
}

/*
 * Bad when there are few columns.
 */
template <class Agg, class BinaryOp>
__global__ void kDumbAggCols(const float* mat, float* const vec, const uint width, const uint height, Agg agg, BinaryOp op) {
    const uint idx = blockIdx.x * blockDim.x + threadIdx.x;
    mat += idx;
    if (idx < width) {
        float mx = *mat;
        mat += width;
        for (uint j = 1; j < height; j++) {
            mx = agg(*mat, mx);
            mat += width;
        }
        vec[idx] = op(vec[idx], mx);
    }
}

template <class Agg>
__global__ void kTotalAgg(const float* a, float* const target, const uint numCols, const uint numElements, Agg agg) {
    __shared__ float shmem[DP_BLOCKSIZE];
    uint eidx = DP_BLOCKSIZE * blockIdx.x + threadIdx.x;
    shmem[threadIdx.x] = agg.getBaseValue();
    if (eidx < numCols) {
        for (; eidx < numElements; eidx += numCols) {
            shmem[threadIdx.x] = agg(shmem[threadIdx.x], a[eidx]);
        }
    }
    __syncthreads();
    if (threadIdx.x < 256) {
        shmem[threadIdx.x] = agg(shmem[threadIdx.x], shmem[threadIdx.x + 256]);
    }
    __syncthreads();
    if (threadIdx.x < 128) {
        shmem[threadIdx.x] = agg(shmem[threadIdx.x], shmem[threadIdx.x + 128]);
    }
    __syncthreads();
    if (threadIdx.x < 64) {
        shmem[threadIdx.x] = agg(shmem[threadIdx.x], shmem[threadIdx.x + 64]);
    }
    __syncthreads();
    if (threadIdx.x < 32) {
        volatile float* mysh = &shmem[threadIdx.x];
        *mysh = agg(*mysh, mysh[32]);
        *mysh = agg(*mysh, mysh[16]);
        *mysh = agg(*mysh, mysh[8]);
        *mysh = agg(*mysh, mysh[4]);
        *mysh = agg(*mysh, mysh[2]);
        *mysh = agg(*mysh, mysh[1]);
        if (threadIdx.x == 0) {
            target[blockIdx.x] = *mysh;
        }
    }
}

class AddGaussianUnaryRandomizer {
private:
    const float stdev;
public:
    AddGaussianUnaryRandomizer(float _stdev) : stdev(_stdev) {
    }
    __device__ inline float operator ()(float data, curandState* state) {
        return data + stdev * curand_normal(state);
    }
};

class BinarizeUnaryRandomizer {
public:
    __device__ inline float operator ()(float data, curandState* state) {
        return data > curand_uniform(state);
    }
};

class UniformUnaryRandomizer {
public:
    __device__ inline float operator ()(float data, curandState* state) {
        return curand_uniform(state);
    }
};

class GaussianUnaryRandomizer {
private:
    const float mean, stdev;
public:
    GaussianUnaryRandomizer(float _mean, float _stdev) : mean(_mean), stdev(_stdev) {
    }
    __device__ inline float operator ()(float data, curandState* state) {
        return mean + stdev * curand_normal(state);
    }
};

class ChisquareUnaryRandomizer {
private:
    const float alpha;
public:
    ChisquareUnaryRandomizer(float _degree) : alpha(_degree / 2.0) {
    }
    __device__ float operator ()(float data, curandState* state) {
      float x, v, u;
      float d = alpha - 1.0 / 3.0;
      float c = (1.0 / 3.0) / sqrt (d);

      while (1){
          do {
              x = curand_normal(state);
              v = 1.0 + c * x;
          } while (v <= 0);

          v = v * v * v;
          u = curand_uniform(state);

          if (u < 1 - 0.0331 * x * x * x * x) 
              break;

          if (log (u) < 0.5 * x * x + d * (1 - v + log (v)))
              break;
      }
      // scale by 2.0 to get chisquare
      return 2.0 * (d * v);
    }
};

template <bool var>
class AddGaussianBinaryRandomizer {
public:
    __device__ inline float operator ()(float data, float stdev, curandState* state) {
        return data + (var ? stdev : 1) * stdev * curand_normal(state);
    }
};

class GaussianBinaryRandomizer {
public:
    __device__ inline float operator ()(float data, float stdev, curandState* state) {
        return stdev * curand_normal(state);
    }
};

template<class Randomizer>
__global__ void kUnaryRandomize(float* data, float* targets, curandState* state, const uint numElements, Randomizer rnd) {
    const uint tidx = NUM_RND_THREADS_PER_BLOCK * blockIdx.x + threadIdx.x;
    curandState localState = state[tidx];

    for (uint i = tidx; i < numElements; i += NUM_RND_STREAMS) {
        targets[i] = rnd(data[i], &localState);
    }
    state[tidx] = localState;
}

template<class Randomizer>
__global__ void kBinaryRandomize(float* data, float* data2, float* targets, curandState* state, const uint numElements, Randomizer rnd) {
    const uint tidx = NUM_RND_THREADS_PER_BLOCK * blockIdx.x + threadIdx.x;
    curandState localState = state[tidx];

    for (uint i = tidx; i < numElements; i += NUM_RND_STREAMS) {
        targets[i] = rnd(data[i], data2[i], &localState);
    }
    state[tidx] = localState;
}

#endif /* NVMATRIX_KERNEL_H_ */
