//
// Copyright (c) 2020 Idiap Research Institute, http://www.idiap.ch/
// Written by Angelos Katharopoulos <angelos.katharopoulos@idiap.ch>
//

#include <limits>
#include <functional>

#include <torch/extension.h>


typedef torch::PackedTensorAccessor32<float, 4, torch::RestrictPtrTraits> float4_accessor;
typedef torch::PackedTensorAccessor32<float, 3, torch::RestrictPtrTraits> float3_accessor;
typedef torch::PackedTensorAccessor32<float, 2, torch::RestrictPtrTraits> float2_accessor;
typedef torch::PackedTensorAccessor32<long, 1, torch::RestrictPtrTraits> long_accessor;


inline int ceildiv(int a, int b) {
    return (a + b - 1)/b;
}

template <typename copy_implementation>
__global__ void sliding_dot_copy_kernel(
    copy_implementation copy,
    float3_accessor buffer,
    float3_accessor output,
    int local_context,
    int l_start,
    int s_start,
    int buffer_dim12,
    int buffer_dim2
) {
    copy(
        buffer,
        output,
        local_context,
        l_start,
        s_start,
        buffer_dim12,
        buffer_dim2
    );
}

/**
 * Multiply every A_i with every B_j iff |i-j| < local_context/2.
 *
 * The strategy is to compute the local products in blocks and keep the GPU
 * busy and then select the valid results from all the intermediate ones.
 *
 * The naming means that both arguments span the full sequences, namely both A
 * and B are the global matrices.
 *
 * Arguments
 * ---------
 *     A: (N, L, E)
 *     B: (N, L, E)
 *     out: (N, L, local_context)
 */
template <int a_blocks=64, typename CopyImplementation>
void sliding_dot(
    CopyImplementation copy_implementation,
    torch::Tensor A,
    torch::Tensor B,
    torch::Tensor out,
    int local_context
) {
    int N = A.size(0);
    int L = A.size(1);

    // Save the intermediate results in here
    auto buffer = A.new_zeros({N, a_blocks, a_blocks+local_context});

    for (int l=0; l<L; l+=a_blocks) {
        // Compute the sizes of the sub problems to be computed in this
        // block iteration
        int s_start = std::max(0, l-local_context/2);
        int s_end = std::min(L, l-local_context/2+local_context+a_blocks);
        int n_b = s_end-s_start;
        int n_a = std::min(L-l, a_blocks);

        // Compute the dot products
        auto buff = buffer.narrow(1, 0, n_a).narrow(2, 0, n_b);
        at::matmul_out(
            buff,
            A.narrow(1, l, n_a),
            B.narrow(1, s_start, n_b).transpose(1, 2)
        );

        // Select the correct results from the buffer
        const int threads = 1024;
        int blocks = ceildiv(buff.numel(), threads);
        sliding_dot_copy_kernel<<<blocks, threads>>>(
            copy_implementation,
            buff.packed_accessor32<float, 3, torch::RestrictPtrTraits>(),
            out.packed_accessor32<float, 3, torch::RestrictPtrTraits>(),
            local_context,
            l,
            s_start,
            buff.size(1)*buff.size(2),
            buff.size(2)
        );
    }
}


/**
 * This copy implementation simply copies the appropriate values from the
 * buffer and adds the corresponding value from the attention mask.
 */
struct masked_lp_copy
{
    float2_accessor attn_mask;
    long_accessor key_lengths;

    masked_lp_copy(float2_accessor _attn_mask, long_accessor _key_lengths) :
        attn_mask(_attn_mask), key_lengths(_key_lengths)
        {}

    __device__ void operator()(
        float3_accessor buffer,
        float3_accessor output,
        int local_context,
        int l_start,
        int s_start,
        int buffer_dim12,
        int buffer_dim2
    ) {
        int idx = blockIdx.x*blockDim.x + threadIdx.x;
        int n = idx / buffer_dim12;
        idx = idx - n*buffer_dim12;
        int l_offset = idx / buffer_dim2;
        idx = idx - l_offset*buffer_dim2;
        int s_offset = idx;

        if (n >= buffer.size(0)) {
            return;
        }

        int l = l_start + l_offset;
        int s = s_start + s_offset;
        int k = s - l + local_context/2;

        if (k < 0 || k >= local_context) {
            return;
        }

        output[n][l][k] = buffer[n][l_offset][s_offset] + attn_mask[l][s];
    }

    static masked_lp_copy factory(
        torch::Tensor attn_mask,
        torch::Tensor key_lengths
    ) {
        return masked_lp_copy(
            attn_mask.packed_accessor32<float, 2, torch::RestrictPtrTraits>(),
            key_lengths.packed_accessor32<long, 1, torch::RestrictPtrTraits>()
        );
    }
};


/**
 * The simplest copy implementation just copies the values if they are within
 * bounds.
 */
struct lp_copy
{
    __device__ void operator()(
        float3_accessor buffer,
        float3_accessor output,
        int local_context,
        int l_start,
        int s_start,
        int buffer_dim12,
        int buffer_dim2
    ) {
        int idx = blockIdx.x*blockDim.x + threadIdx.x;
        int n = idx / buffer_dim12;
        idx = idx - n*buffer_dim12;
        int l_offset = idx / buffer_dim2;
        idx = idx - l_offset*buffer_dim2;
        int s_offset = idx;

        if (n >= buffer.size(0)) {
            return;
        }

        int l = l_start + l_offset;
        int s = s_start + s_offset;
        int k = s - l + local_context/2;

        if (k < 0 || k >= local_context) {
            return;
        }

        output[n][l][k] = buffer[n][l_offset][s_offset];
    }
};


template <int LB=32, int KB=32, int EB=32>
__global__ void local_copy_scaled(
    float4_accessor factors,
    float4_accessor values,
    float4_accessor output,
    dim3 strides
) {
    int idx = blockIdx.x;
    int n = idx / strides.x;
    idx -= n*strides.x;
    int h = idx / strides.y;
    idx -= h*strides.y;
    int lblock = idx / strides.z;
    idx -= lblock*strides.z;
    int eblock = idx;

    int local_context = factors.size(3);

    int l_local = threadIdx.x / EB;
    int e_local = threadIdx.x - l_local*EB;
    int l = lblock * LB + l_local;
    int e = eblock * EB + e_local;

    if (n > factors.size(0)) {
        return;
    }

    extern __shared__ float shared_mem[];
    float * s_factors = shared_mem;
    float * s_values = s_factors + LB*KB;

    for (int k=0; k<local_context; k+=KB) {
        // Load the data in shared mem
        int s1 = l - local_context/2 + k;
        int s2 = s1 + LB;
        int scurrent = s1 + e_local;
        if (l < factors.size(2) && k + e_local < local_context && scurrent >= 0 && scurrent < values.size(2)) {
            s_factors[l_local*KB + e_local] = factors[n][h][l][k + e_local];
        } else {
            s_factors[l_local*KB + e_local] = 0;
        }
        if (e < values.size(3) && s1 >=0 && s1 < values.size(2)) {
            s_values[l_local*EB + e_local] = values[n][h][s1][e];
        } else {
            s_values[l_local*EB + e_local] = 0;
        }
        if (e < values.size(3) && s2 >=0 && s2 < values.size(2)) {
            s_values[(l_local+LB)*EB + e_local] = values[n][h][s2][e];
        } else {
            s_values[(l_local+LB)*EB + e_local] = 0;
        }
        __syncthreads();

        // Do the dot product
        float result = 0;
        #pragma unroll
        for (int k_local=0; k_local<KB; k_local++) {
            result += s_factors[l_local*KB + k_local] * s_values[(k_local + l_local)*EB + e_local];
        }
        if (l < factors.size(2) && e < values.size(3)) {
            output[n][h][l][e] += result;
        }
        __syncthreads();
    }
}


struct IncreasingLK
{
    inline __device__
    int operator()(int k, int e_local, int local_context) {
        return k+e_local;
    }
};
struct ReverseLK
{
    inline __device__
    int operator()(int k, int e_local, int local_context) {
        return local_context-k-e_local-1;
    }
};


template <typename lk_policy_type, int LB=32, int KB=32, int EB=32>
__global__ void local_copy_scaled_transpose(
    float4_accessor factors,
    float4_accessor values,
    float4_accessor output,
    dim3 strides,
    lk_policy_type lk_policy
) {
    int idx = blockIdx.x;
    int n = idx / strides.x;
    idx -= n*strides.x;
    int h = idx / strides.y;
    idx -= h*strides.y;
    int sblock = idx / strides.z;
    idx -= sblock*strides.z;
    int eblock = idx;

    int local_context = factors.size(3);

    int s_local = threadIdx.x / EB;
    int e_local = threadIdx.x - s_local*EB;
    int s = sblock * LB + s_local;
    int e = eblock * EB + e_local;

    if (n > factors.size(0)) {
        return;
    }

    extern __shared__ float shared_mem[];
    float * s_factors = shared_mem;
    float * s_values = s_factors + LB*KB;

    for (int k=0; k<local_context; k+=KB) {
        // Load the data in shared mem
        int l = s - (local_context-1)/2 + k;
        int l2 = l + LB;
        // load the values
        if (l >= 0 && l < factors.size(2) && e < values.size(3)) {
            s_values[s_local*EB + e_local] = values[n][h][l][e];
        } else {
            s_values[s_local*EB + e_local] = 0;
        }
        if (l2 >= 0 && l2 < factors.size(2) && e < values.size(3)) {
            s_values[(s_local + LB)*EB + e_local] = values[n][h][l2][e];
        } else {
            s_values[(s_local + LB)*EB + e_local] = 0;
        }

        // load factors
        int lcurrent = l+e_local;
        int kcurrent = k+e_local;
        if (lcurrent >= 0 && lcurrent < factors.size(2) && kcurrent < local_context) {
            int t = lk_policy(k, e_local, local_context);
            s_factors[s_local*KB + e_local] = factors[n][h][l+e_local][t];
        } else {
            s_factors[s_local*KB + e_local] = 0;
        }
        __syncthreads();

        // Do the dot product
        float result = 0;
        #pragma unroll
        for (int k_local=0; k_local<KB; k_local++) {
            result += s_values[(s_local+k_local)*EB + e_local] * s_factors[s_local*KB + k_local];
        }

        if (s < values.size(2) && e < values.size(3)) {
            output[n][h][s][e] += result;
        }
        __syncthreads();
    }
}


torch::Tensor local_dot_product(
    const torch::Tensor queries,
    const torch::Tensor keys,
    const torch::Tensor attn_mask,
    const torch::Tensor key_lengths,
    int local_context
) {
    // Extract some shapes
    int N = queries.size(0);
    int H = queries.size(1);
    int L = queries.size(2);
    int S = keys.size(2);
    int E = queries.size(3);

    // Allocate space for the output
    auto output = queries.new_full(
        {N, H, L, local_context},
        -std::numeric_limits<float>::infinity()
    );

    sliding_dot(
        masked_lp_copy::factory(attn_mask, key_lengths),
        queries.view({N*H, L, E}),
        keys.view({N*H, L, E}),
        output.view({N*H, L, local_context}),
        local_context
    );

    return output;
}


std::tuple<torch::Tensor, torch::Tensor> local_dot_backward(
    const torch::Tensor queries,
    const torch::Tensor keys,
    const torch::Tensor key_lengths,
    const torch::Tensor grad,
    int local_context
) {
    // Extract some shapes
    int N = grad.size(0);
    int H = grad.size(1);
    int L = grad.size(2);
    int K = grad.size(3);
    int E = keys.size(3);

    // Allocate space for the output
    auto grad_queries = torch::zeros_like(queries);
    auto grad_keys = torch::zeros_like(keys);

    const int threads = 32*32;
    int lblocks = ceildiv(L, 32);
    int eblocks = ceildiv(E, 32);
    int blocks = N * H * lblocks * eblocks;
    int shared_mem = 32*32 * 3 * sizeof(float);
    dim3 strides(
        H*lblocks*eblocks,
        lblocks*eblocks,
        eblocks
    );

    local_copy_scaled<<<blocks, threads, shared_mem>>>(
        grad.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
        keys.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
        grad_queries.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
        strides
    );
    local_copy_scaled_transpose<<<blocks, threads, shared_mem>>>(
        grad.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
        queries.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
        grad_keys.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
        strides,
        IncreasingLK()
    );

    return std::make_tuple(grad_queries, grad_keys);
}


torch::Tensor local_weighted_average(
    const torch::Tensor attention,
    const torch::Tensor values
) {
    // Extract some shapes
    int N = attention.size(0);
    int H = attention.size(1);
    int L = attention.size(2);
    int K = attention.size(3);
    int E = values.size(3);

    // Allocate space for the output
    auto output = torch::zeros_like(values);

    const int threads = 32*32;
    int lblocks = ceildiv(L, 32);
    int eblocks = ceildiv(E, 32);
    int blocks = N * H * lblocks * eblocks;
    int shared_mem = 32*32 * 3 * sizeof(float);
    dim3 strides(
        H*lblocks*eblocks,
        lblocks*eblocks,
        eblocks
    );

    local_copy_scaled<<<blocks, threads, shared_mem>>>(
        attention.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
        values.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
        output.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
        strides
    );

    return output;
}


std::tuple<torch::Tensor, torch::Tensor> local_weighted_average_backward(
    const torch::Tensor attention,
    const torch::Tensor values,
    const torch::Tensor grad
) {
    // Extract some shapes
    int N = attention.size(0);
    int H = attention.size(1);
    int L = attention.size(2);
    int local_context = attention.size(3);
    int S = values.size(2);
    int E = values.size(3);

    // Allocate space for the output
    auto grad_attention = torch::zeros_like(attention);
    auto grad_values = torch::zeros_like(values);

    // Compute the gradient wrt to the values
    {
        const int threads = 32*32;
        int lblocks = ceildiv(L, 32);
        int eblocks = ceildiv(E, 32);
        int blocks = N * H * lblocks * eblocks;
        int shared_mem = 32*32 * 3 * sizeof(float);
        dim3 strides(
            H*lblocks*eblocks,
            lblocks*eblocks,
            eblocks
        );

        local_copy_scaled_transpose<<<blocks, threads, shared_mem>>>(
            attention.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
            grad.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
            grad_values.packed_accessor32<float, 4, torch::RestrictPtrTraits>(),
            strides,
            ReverseLK()
        );
    }

    // Compute the gradient wrt to the attention
    sliding_dot(
        lp_copy(),
        grad.view({N*H, L, E}),
        values.view({N*H, L, E}),
        grad_attention.view({N*H, L, local_context}),
        local_context
    );

    return std::make_tuple(grad_attention, grad_values);
}


PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
    m.def(
        "local_dot_product",
        &local_dot_product,
        "Compute the product of Q and K for a small context around each Q"
    );
    m.def(
        "local_dot_backward",
        &local_dot_backward,
        "Compute the gradient of local_dot_product"
    );
    m.def(
        "local_weighted_average",
        &local_weighted_average,
        "Perform the weighted average of V for a small context around each Q"
    );
    m.def(
        "local_weighted_average_backward",
        &local_weighted_average_backward,
        "Compute the gradient of the local weighted average"
    );
}
