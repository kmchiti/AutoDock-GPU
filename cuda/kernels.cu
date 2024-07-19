/*

AutoDock-GPU, an OpenCL implementation of AutoDock 4.2 running a Lamarckian Genetic Algorithm
Copyright (C) 2017 TU Darmstadt, Embedded Systems and Applications Group, Germany. All rights reserved.
For some of the code, Copyright (C) 2019 Computational Structural Biology Center, the Scripps Research Institute.

AutoDock is a Trade Mark of the Scripps Research Institute.

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

*/


#include <cstdint>
#include <cassert>
#include "defines.h"
#include "calcenergy.h"
#include "GpuData.h"

__device__ inline uint64_t llitoulli(int64_t l)
{
	uint64_t u;
	asm("mov.b64    %0, %1;" : "=l"(u) : "l"(l));
	return u;
}

__device__ inline int64_t ullitolli(uint64_t u)
{
	int64_t l;
	asm("mov.b64    %0, %1;" : "=l"(l) : "l"(u));
	return l;
}


#define WARPMINIMUMEXCHANGE(tgx, v0, k0, mask) \
	{ \
		float v1    = v0; \
		int k1      = k0; \
		int otgx    = tgx ^ mask; \
		float v2    = __shfl_sync(0xffffffff, v0, otgx); \
		int k2      = __shfl_sync(0xffffffff, k0, otgx); \
		int flag    = ((v1 < v2) ^ (tgx > otgx)) && (v1 != v2); \
		k0          = flag ? k1 : k2; \
		v0          = flag ? v1 : v2; \
	}

#define WARPMINIMUM2(tgx, v0, k0) \
	WARPMINIMUMEXCHANGE(tgx, v0, k0, 1) \
	WARPMINIMUMEXCHANGE(tgx, v0, k0, 2) \
	WARPMINIMUMEXCHANGE(tgx, v0, k0, 4) \
	WARPMINIMUMEXCHANGE(tgx, v0, k0, 8) \
	WARPMINIMUMEXCHANGE(tgx, v0, k0, 16)

#define REDUCEINTEGERSUM(value, pAccumulator) \
	if (threadIdx.x == 0) \
	{ \
		*pAccumulator = 0; \
	} \
	__threadfence(); \
	__syncthreads(); \
	if (__any_sync(0xffffffff, value != 0)) \
	{ \
		uint32_t tgx            = threadIdx.x & cData.warpmask; \
		value                  += __shfl_sync(0xffffffff, value, tgx ^ 1); \
		value                  += __shfl_sync(0xffffffff, value, tgx ^ 2); \
		value                  += __shfl_sync(0xffffffff, value, tgx ^ 4); \
		value                  += __shfl_sync(0xffffffff, value, tgx ^ 8); \
		value                  += __shfl_sync(0xffffffff, value, tgx ^ 16); \
		if (tgx == 0) \
		{ \
			atomicAdd(pAccumulator, value); \
		} \
	} \
	__threadfence(); \
	__syncthreads(); \
	value = *pAccumulator; \
	__syncthreads();

#define ATOMICADDI32(pAccumulator, value) atomicAdd(pAccumulator, (value))
#define ATOMICSUBI32(pAccumulator, value) atomicAdd(pAccumulator, -(value))
#define ATOMICADDF32(pAccumulator, value) atomicAdd(pAccumulator, (value))
#define ATOMICSUBF32(pAccumulator, value) atomicAdd(pAccumulator, -(value))

#ifdef USE_NVTENSOR
/* Begin: Reduction using tensor units */

// Implementation based on M.Sc. thesis by Gabin Schieffer at KTH:
// "Accelerating a Molecular Docking Application by Leveraging Modern Heterogeneous Computing Systemx"
// https://www.diva-portal.org/smash/get/diva2:1786161/FULLTEXT01.pdf

	#ifdef USE_TCEC
	/*
	* WMMA Extension for single precision matmul using Tensor Cores
	* and error correction technique (TCEC)
	* https://github.com/wmmae/wmma_extension/blob/main/docs/mma_f32.md
	*/
	#include <wmma_extension/tcec/tcec.hpp>

	using tf32 = nvcuda::wmma::precision::tf32;
	#endif

/*
 * Tensor Cores
 * https://developer.nvidia.com/blog/programming-tensor-cores-cuda-9
 *
 * Don't forget to compile specifying the architecture, e.g., sm_86.
 * For AutoDock-GPU, this can be done via the TARGETS option.
 * make DEVICE=GPU TESTLS=ad NUMWI=64 TARGETS=86 test
 * https://stackoverflow.com/a/53634598/1616865
 */
#include <mma.h>
using namespace nvcuda;

#define TILE_SIZE (16 * 16)

constexpr int rowscols_M = 16;	// Number of rows (or cols) in the M dimension
constexpr int rowscols_N = 16;	// Number of rows (or cols) in the N dimension
constexpr int rowscols_K = 16;	// Number of rows (or cols) in the K dimension

#ifdef USE_TCEC
__device__ void fill_Q(float *Q_data) {
#endif

	#ifdef USE_TCEC
	float I4[16] = {
		1.0f, 0.0f, 0.0f, 0.0f,
		0.0f, 1.0f, 0.0f, 0.0f,
		0.0f, 0.0f, 1.0f, 0.0f,
		0.0f, 0.0f, 0.0f, 1.0f
	};
	#endif

	/*
	// Naive implementation: a single thread fills data in
	if (threadIdx.x == 0) {
		for (uint i = 0; i < 4; i++) {	// How many rows (of 4x4 blocks) are there in matrix A?
			for (uint j = 0; j < 4; j++) {	// How many cols (of 4x4 blocks) are there in matrix A?
				for (uint ii = 0; ii < 4; ii++) {
					for (uint jj = 0; jj < 4; jj++) {
						Q_data[4*i + 64*j + ii + 16*jj] = I4 [4*ii + jj];
					}
				}
			}
		}
	}
	*/

	// Slightly improved multi-threaded implementation
	for (uint i = threadIdx.x; i < 4; i+=blockDim.x) {	// How many rows (of 4x4 blocks) are there in matrix A?
		for (uint j = 0; j < 4; j++) {	// How many cols (of 4x4 blocks) are there in matrix A?
			for (uint ii = 0; ii < 4; ii++) {
				for (uint jj = 0; jj < 4; jj++) {
					Q_data[4*i + 64*j + ii + 16*jj] = I4 [4*ii + jj];
				}
			}
		}
	}

	/*
	// Further improved multi-threaded implementation
	// (It didn't provide significant performance improvements -> commented out)
	// Fusing two outer loops into a single one
	// To do that: coeffs = 4i + 64j
	constexpr uint coeffs [16] = {0, 64, 128, 192, 4, 68, 132, 196, 8, 72, 136, 200, 12, 76, 140, 204};
	for (uint k = threadIdx.x; k < 16; k+=blockDim.x) {
		for (uint ii = 0; ii < 4; ii++) {
			for (uint jj = 0; jj < 4; jj++) {
				Q_data[coeffs[k] + ii + 16*jj] = I4 [4*ii + jj];
			}
		}	
	}
	*/

	/*
	// Enable this block to print matrix values
	if (blockIdx.x == 0 && threadIdx.x == 0) {
		printf("\nQ_data");
		for (uint i = 0; i < 16 * 16; i++) {
			if ((i % 16) == 0) {printf("\n[Row %u]: ", i/16);}
			printf(" %2.2f ", Q_data[i]);
		}
		printf("\n");
    }
	*/
}

#ifdef USE_TCEC
__device__ void reduce_via_tensor_units(float *data_to_be_reduced) {
#endif
	__syncthreads();

	if (threadIdx.x <= 31) { // Only one warp performs reduction
		#ifdef USE_TCEC
		__shared__ __align__ (256) float Q_data[TILE_SIZE];
		#endif

		fill_Q(Q_data);

		#ifdef USE_TCEC
		__shared__ __align__ (256) float tmp[TILE_SIZE];
		#endif

		// Declaring and filling fragments - Those are *not* shared

		#ifdef USE_TCEC
		mtk::wmma::tcec::fragment<wmma::matrix_b, rowscols_M, rowscols_N, rowscols_K, tf32, wmma::col_major> frag_P;
		mtk::wmma::tcec::fragment<wmma::accumulator, rowscols_M, rowscols_N, rowscols_K, tf32> frag_V;
		#endif

		#ifdef USE_TCEC
		mtk::wmma::tcec::fragment<wmma::matrix_a, rowscols_M, rowscols_N, rowscols_K, tf32, wmma::col_major> frag_Q;
		mtk::wmma::tcec::fragment<wmma::matrix_b, rowscols_M, rowscols_N, rowscols_K, tf32, wmma::col_major> frag_W;
		mtk::wmma::tcec::fragment<wmma::accumulator, rowscols_M, rowscols_N, rowscols_K, tf32> frag_C;
		#endif

		#ifdef USE_TCEC
		mtk::wmma::tcec::fill_fragment(frag_P, 1.0f); // P: only ones
		mtk::wmma::tcec::fill_fragment(frag_V, 0.0f); // Output: initialize to zeros
		mtk::wmma::tcec::fill_fragment(frag_C, 0.0f); // Final result
		mtk::wmma::tcec::load_matrix_sync(frag_Q, Q_data, 16);
		#endif

		// 1. Accumulate the values: V <- AP + V
		for(uint i = 0; i < (4 * NUM_OF_THREADS_PER_BLOCK)/TILE_SIZE; i++){
			const unsigned int offset = i * TILE_SIZE;

			#ifdef USE_TCEC
			mtk::wmma::tcec::fragment<wmma::matrix_a, rowscols_M, rowscols_N, rowscols_K, tf32, wmma::col_major> frag_A;
			mtk::wmma::tcec::load_matrix_sync(frag_A, data_to_be_reduced + offset, 16);
			mtk::wmma::tcec::mma_sync(frag_V, frag_A, frag_P, frag_V);
			#endif
		}

		// W <- V (required since we need V as a "wmma::matrix_b")
		#ifdef USE_TCEC
		mtk::wmma::tcec::store_matrix_sync(tmp, frag_V, 16, wmma::mem_col_major);
		mtk::wmma::tcec::load_matrix_sync(frag_W, tmp, 16);
		#endif

		// 2. Perform line sum: C <- QW + C (zero)
		#ifdef USE_TCEC
		mtk::wmma::tcec::mma_sync(frag_C, frag_Q, frag_W, frag_C);
		#endif

		// 3. Store result in shared memory
		#ifdef USE_TCEC
		mtk::wmma::tcec::store_matrix_sync(data_to_be_reduced, frag_C, 16, wmma::mem_col_major);
		#endif
	}

	__syncthreads();
}

/* End: Reduction using tensor units */
#endif

#define REDUCEFLOATSUM(value, pAccumulator) \
	if (threadIdx.x == 0) \
	{ \
		*pAccumulator = 0; \
	} \
	__threadfence(); \
	__syncthreads(); \
	if (__any_sync(0xffffffff, value != 0.0f)) \
	{ \
		uint32_t tgx            = threadIdx.x & cData.warpmask; \
		value                  += __shfl_sync(0xffffffff, value, tgx ^ 1); \
		value                  += __shfl_sync(0xffffffff, value, tgx ^ 2); \
		value                  += __shfl_sync(0xffffffff, value, tgx ^ 4); \
		value                  += __shfl_sync(0xffffffff, value, tgx ^ 8); \
		value                  += __shfl_sync(0xffffffff, value, tgx ^ 16); \
		if (tgx == 0) \
		{ \
			atomicAdd(pAccumulator, value); \
		} \
	} \
	__threadfence(); \
	__syncthreads(); \
	value = (float)(*pAccumulator); \
	__syncthreads();



static __constant__ GpuData cData;
static GpuData cpuData;

void SetKernelsGpuData(GpuData* pData)
{
	cudaError_t status;
	status = cudaMemcpyToSymbol(cData, pData, sizeof(GpuData));
	RTERROR(status, "SetKernelsGpuData copy to cData failed");
	memcpy(&cpuData, pData, sizeof(GpuData));
}

void GetKernelsGpuData(GpuData* pData)
{
	cudaError_t status;
	status = cudaMemcpyFromSymbol(pData, cData, sizeof(GpuData));
	RTERROR(status, "GetKernelsGpuData copy From cData failed");
}


// Kernel files
#include "calcenergy.cu"
#include "calcMergeEneGra.cu"
#include "auxiliary_genetic.cu"
#include "kernel1.cu"
#include "kernel2.cu"
#include "kernel3.cu"
#include "kernel4.cu"
#include "kernel_ad.cu"
#include "kernel_adam.cu"
