#include <ATen/AccumulateType.h>
#include <ATen/native/Pool.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/CUDAApplyUtils.cuh>
#include <ATen/cuda/detail/TensorInfo.cuh>
#include <ATen/cuda/detail/IndexUtils.cuh>
#include <ATen/cuda/detail/KernelUtils.h>
#include <THC/THCNumerics.cuh>
#include <c10/macros/Macros.h>


namespace at {
namespace native {
namespace {

__device__ inline int min(int a, int b) {
  return a <= b ? a : b;
}

template <typename scalar_t>
__global__ static void max_pool3d_with_indices_single_out_frame(
  scalar_t* inputData,
  PackedTensorAccessor<scalar_t, 4> output,
  PackedTensorAccessor<int64_t, 4> indices,
  int itime, int iheight, int iwidth,
  int kT, int kH, int kW,
  int dT, int dH, int dW,
  int pT, int pH, int pW,
  int dilationT, int dilationH, int dilationW,
  int offsetZ)
{
  int oColumn = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow    = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame  = (blockIdx.z + offsetZ) % output.size(1); // output frame/time
  int slice   = (blockIdx.z + offsetZ) / output.size(1); // output slice/feature

  if (oRow < output.size(2) && oColumn < output.size(3))
  {
    int tStart = oFrame  * dT - pT;
    int hStart = oRow    * dH - pH;
    int wStart = oColumn * dW - pW;
    int tEnd = min(tStart + (kT - 1) * dilationT + 1, itime);
    int hEnd = min(hStart + (kH - 1) * dilationH + 1, iheight);
    int wEnd = min(wStart + (kW - 1) * dilationW + 1, iwidth);

    while(tStart < 0)
      tStart += dilationT;
    while(hStart < 0)
      hStart += dilationH;
    while(wStart < 0)
      wStart += dilationW;

    int maxIndex =  tStart * iheight * iwidth + hStart * iwidth + wStart;
    inputData += slice * itime * iheight * iwidth;

    scalar_t max = at::numeric_limits<scalar_t>::lower_bound(); // -Infinity

    for (int t = tStart; t < tEnd; t += dilationT)
    {
      for (int h = hStart; h < hEnd; h += dilationH)
      {
        for (int w = wStart; w < wEnd; w += dilationW)
        {
          int index = t * iheight * iwidth + h * iwidth + w;
          scalar_t val = inputData[index];

          if ((max < val) || THCNumerics<scalar_t>::isnan(val))
          {
            max = val;
            maxIndex = index;
          }
        }
      }
    }

    output[slice][oFrame][oRow][oColumn] = max;
    indices[slice][oFrame][oRow][oColumn] = maxIndex;
  }
}

template <int KERNEL_WIDTH, typename scalar_t>
__global__ static void max_pool3d_with_indices_single_out_frame(
  scalar_t* inputData,
  PackedTensorAccessor<scalar_t, 4> output,
  PackedTensorAccessor<int64_t, 4> indices,
  int itime, int iheight, int iwidth,
  int kT, int kH,
  int dT, int dH, int dW,
  int pT, int pH, int pW,
  int dilationT, int dilationH, int dilationW,
  int offsetZ)
{
  int oColumn = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow    = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame  = (blockIdx.z + offsetZ) % output.size(1); // output frame/time
  int slice   = (blockIdx.z + offsetZ) / output.size(1); // output slice/feature

  if (oRow < output.size(2) && oColumn < output.size(3))
  {
    int tStart = oFrame  * dT - pT;
    int hStart = oRow    * dH - pH;
    int wStart = oColumn * dW - pW;
    int tEnd = min(tStart + (kT - 1) * dilationT + 1, itime);
    int hEnd = min(hStart + (kH - 1) * dilationH + 1, iheight);
    int wEnd = min(wStart + (KERNEL_WIDTH - 1) * dilationW + 1, iwidth);

    while(tStart < 0)
      tStart += dilationT;
    while(hStart < 0)
      hStart += dilationH;
    while(wStart < 0)
      wStart += dilationW;

    int index = 0;
    int maxIndex = -1;

    scalar_t max = THCNumerics<scalar_t>::min();

    for (int t = tStart; t < tEnd; t += dilationT)
    {
      for (int h = hStart; h < hEnd; h += dilationH)
      {
        for (int w = wStart; w < wEnd; w += dilationW)
        {
          index = t * iheight * iwidth + h * iwidth + w;
          scalar_t val = inputData[slice * itime * iheight * iwidth + index];

          if (max < val)
          {
            max = val;
            maxIndex = index;
          }
        }
      }
    }

    output[slice][oFrame][oRow][oColumn] = max;
    indices[slice][oFrame][oRow][oColumn] = maxIndex;
  }
}

#define UPDATE_OUTPUT_KERNEL_WIDTH(KW) case KW:           \
  max_pool3d_with_indices_single_out_frame<KW>            \
  <<<grid, block, 0, at::cuda::getCurrentCUDAStream()>>>( \
    input_data,                                           \
    output.packed_accessor<scalar_t, 4>(),                \
    indices.packed_accessor<int64_t, 4>(),                \
    itime, iheight, iwidth,                               \
    kT, kH,                                               \
    dT, dH, dW,                                           \
    pT, pH, pW,                                           \
    dilationT, dilationH, dilationW, offsetZ);            \
    break

template <typename scalar_t>
void max_pool3d_with_indices_out_frame(
  scalar_t* input_data,
  const Tensor& output,
  const Tensor& indices,
  int totalZ,
  int itime, int iheight, int iwidth,
  int otime, int oheight, int owidth,
  int kT, int kH, int kW,
  int dT, int dH, int dW,
  int pT, int pH, int pW,
  int dilationT, int dilationH, int dilationW)
{
  int offsetZ = 0;
  dim3 block(32, 8);

  while (totalZ > 0) {
    dim3 grid(cuda::ATenCeilDiv(owidth, static_cast<int>(block.x)),
              cuda::ATenCeilDiv(oheight, static_cast<int>(block.y)),
              totalZ > 65535 ? 65535 : totalZ);

    switch (kW) {
      UPDATE_OUTPUT_KERNEL_WIDTH(1);
      UPDATE_OUTPUT_KERNEL_WIDTH(2);
      UPDATE_OUTPUT_KERNEL_WIDTH(3);
      UPDATE_OUTPUT_KERNEL_WIDTH(4);
      UPDATE_OUTPUT_KERNEL_WIDTH(5);
      UPDATE_OUTPUT_KERNEL_WIDTH(6);
      UPDATE_OUTPUT_KERNEL_WIDTH(7);
    default:
      max_pool3d_with_indices_single_out_frame
        <<<grid, block, 0, at::cuda::getCurrentCUDAStream()>>>(
           input_data,
           output.packed_accessor<scalar_t, 4>(),
           indices.packed_accessor<int64_t, 4>(),
           itime, iheight, iwidth,
           kT, kH, kW,
           dT, dH, dW,
           pT, pH, pW,
           dilationT, dilationH, dilationW,
           offsetZ);
    }

    TORCH_CHECK(cudaGetLastError() == cudaSuccess,
      "max_pool3d_backward_out_cuda_frame failed with error code ",
      cudaGetLastError());

    totalZ -= 65535;
    offsetZ += 65535;
  }
}

#undef UPDATE_OUTPUT_KERNEL_WIDTH

template <typename scalar_t>
__global__ static void max_pool3d_with_indices_backward_single_out_frame(
  scalar_t *gradInputData,
  PackedTensorAccessor<scalar_t, 4> gradOutput,
  PackedTensorAccessor<int64_t, 4> indices,
  int itime, int iheight, int iwidth,
  int dT, int dH, int dW,
  int pT, int pH, int pW,
  int dilationT, int dilationH, int dilationW,
  int offsetZ)
{
  int oColumn = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow    = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame  = (blockIdx.z + offsetZ) % gradOutput.size(1); // output frame/time
  int slice   = (blockIdx.z + offsetZ) / gradOutput.size(1); // output slice/feature

  if (oRow < gradOutput.size(2) && oColumn < gradOutput.size(3))
  {
    int maxIndex = indices[slice][oFrame][oRow][oColumn];
    if (maxIndex != -1) {
      atomicAdd(&gradInputData[slice * itime * iheight * iwidth + maxIndex],
                gradOutput[slice][oFrame][oRow][oColumn]);
    }
  }
}

template <typename scalar_t>
void max_pool3d_with_indices_backward_out_frame(
  scalar_t *gradInputData,
  const Tensor& gradOutput,
  const Tensor& indices,
  int64_t totalZ,
  int itime, int iheight, int iwidth,
  int oheight, int owidth,
  int dT, int dH, int dW,
  int pT, int pH, int pW,
  int dilationT, int dilationH, int dilationW)
{
  int offsetZ = 0;
  dim3 block(32, 8);

  while (totalZ > 0) {
    dim3 grid(cuda::ATenCeilDiv(owidth, static_cast<int>(block.x)),
              cuda::ATenCeilDiv(oheight, static_cast<int>(block.y)),
              totalZ > 65535 ? 65535 : totalZ);

    max_pool3d_with_indices_backward_single_out_frame
      <<<grid, block, 0, at::cuda::getCurrentCUDAStream()>>>(
        gradInputData,
        gradOutput.packed_accessor<scalar_t, 4>(),
        indices.packed_accessor<int64_t, 4>(),
        itime, iheight, iwidth,
        dT, dH, dW,
        pT, pH, pW,
        dilationT, dilationH, dilationW,
        offsetZ);

    TORCH_CHECK(cudaGetLastError() == cudaSuccess,
      "max_pool3d_with_indices_backward_out_frame failed with error code ",
      cudaGetLastError());

    totalZ -= 65535;
    offsetZ += 65535;
  }
}

void max_pool3d_with_indices_out_cuda_template(
           Tensor& output,
           Tensor& indices,
           const Tensor& input,
           IntArrayRef kernel_size,
           IntArrayRef stride,
           IntArrayRef padding,
           IntArrayRef dilation,
           bool ceil_mode)
{
  TensorArg output_arg{ output, "output", 1 };
  TensorArg indices_arg{ indices, "indices", 2 };
  TensorArg input_arg{ input, "input", 3 };

  checkAllSameGPU("max_pool3d_with_indices_out_cuda",
                  {output_arg, indices_arg, input_arg});

  // #20866, #22032: Guarantee this for the official C++ API?
  TORCH_CHECK((kernel_size.size() == 1 || kernel_size.size() == 3) &&
              (stride.empty() || stride.size() == 3) &&
              (padding.size() == 1 || padding.size() == 3) &&
              (dilation.size() == 1 || dilation.size() == 3),
    "max_pool3d_with_indices: internal error: all IntArrayRef sizes must be 3");

  TORCH_CHECK((input.ndimension() == 4 || input.ndimension() == 5),
    "non-empty 4D or 5D (batch mode) tensor expected for input");

  const int kT = safe_downcast<int, int64_t>(kernel_size[0]);
  const int kH = kernel_size.size() == 1 ? kT : safe_downcast<int, int64_t>(kernel_size[1]);
  const int kW = kernel_size.size() == 1 ? kT : safe_downcast<int, int64_t>(kernel_size[2]);

  const int dT = stride.empty() ? kT : safe_downcast<int, int64_t>(stride[0]);
  const int dH = stride.empty() ? kH : safe_downcast<int, int64_t>(stride[1]);
  const int dW = stride.empty() ? kW : safe_downcast<int, int64_t>(stride[2]);

  const int pT = safe_downcast<int, int64_t>(padding[0]);
  const int pH = padding.size() == 1 ? pT : safe_downcast<int, int64_t>(padding[1]);
  const int pW = padding.size() == 1 ? pT : safe_downcast<int, int64_t>(padding[2]);

  const int dilationT = safe_downcast<int, int64_t>(dilation[0]);
  const int dilationH = dilation.size() == 1 ? dilationT : safe_downcast<int, int64_t>(dilation[1]);
  const int dilationW = dilation.size() == 1 ? dilationT : safe_downcast<int, int64_t>(dilation[2]);

  const int64_t nbatch = input.ndimension() == 5 ? input.size(-5) : 1;
  const int64_t nslices = input.size(-4);
  const int64_t itime = input.size(-3);
  const int64_t iheight = input.size(-2);
  const int64_t iwidth = input.size(-1);

  const int64_t otime = pooling_output_shape<int64_t>(itime, kT, pT, dT, dilationT, ceil_mode);
  const int64_t oheight = pooling_output_shape<int64_t>(iheight, kH, pH, dH, dilationH, ceil_mode);
  const int64_t owidth = pooling_output_shape<int64_t>(iwidth, kW, pW, dW, dilationW, ceil_mode);

  pool3d_shape_check(
    input,
    nslices,
    kT, kH, kW,
    dT, dH, dW,
    pT, pH, pW,
    dilationT, dilationH, dilationW,
    itime, iheight, iwidth,
    otime, oheight, owidth);

  if (input.ndimension() == 4) {
    output.resize_({ nslices, otime, oheight, owidth});
    indices.resize_({nslices, otime, oheight, owidth});
  }
  else {
    output.resize_({nbatch, nslices, otime, oheight, owidth});
    indices.resize_({nbatch, nslices, otime, oheight, owidth});
  }

  Tensor work_input = input.contiguous();
  Tensor work_output = output;
  Tensor work_indices = indices;
  if (input.ndimension() == 5) {
    // Collapse batch and feature dimensions.
    work_input = work_input.reshape({nbatch * nslices, itime, iheight, iwidth});
    work_output = work_output.reshape({nbatch * nslices, otime, oheight, owidth});
    work_indices = work_indices.reshape({nbatch * nslices, otime, oheight, owidth});
  }

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(
    input.scalar_type(),
    "max_pool3d_with_indices_out_frame",
    [&]{
      scalar_t *input_data = work_input.data<scalar_t>();
      int64_t totalZ = otime * nslices * nbatch;

      max_pool3d_with_indices_out_frame(
        input_data, work_output, work_indices,
        totalZ,
        itime, iheight, iwidth,
        otime, oheight, owidth,
        kT, kH, kW,
        dT, dH, dW,
        pT, pH, pW,
        dilationT, dilationH, dilationW);
    }
  );
}

void max_pool3d_with_indices_backward_out_cuda_template(
           Tensor& gradInput,
           const Tensor& gradOutput,
           const Tensor& input,
           const Tensor& indices,
           IntArrayRef kernel_size,
           IntArrayRef stride,
           IntArrayRef padding,
           IntArrayRef dilation,
           bool ceil_mode)
{
  TensorArg gradInput_arg{ gradInput, "gradInput", 1 };
  TensorArg gradOutput_arg{ gradOutput, "gradOutput", 2 };
  TensorArg input_arg{ input, "input", 3 };
  TensorArg indices_arg{ indices, "indices", 4 };

  checkAllSameGPU("max_pool3d_with_indices_backward_out_cuda",
                  {gradInput_arg, gradOutput_arg, input_arg, indices_arg});

  // #20866, #22032: Guarantee this for the official C++ API?
  TORCH_CHECK((kernel_size.size() == 1 || kernel_size.size() == 3) &&
              (stride.empty() || stride.size() == 3) &&
              (padding.size() == 1 || padding.size() == 3) &&
              (dilation.size() == 1 || dilation.size() == 3),
    "max_pool3d_with_indices: internal error: all IntArrayRef sizes must be 3");

  TORCH_CHECK((input.ndimension() == 4 || input.ndimension() == 5),
    "non-empty 4D or 5D (batch mode) tensor expected for input");

  TORCH_CHECK((gradOutput.ndimension() == 4 || gradOutput.ndimension() == 5),
    "non-empty 4D or 5D (batch mode) tensor expected for gradOutput");

  // Resize and initialize result tensor.
  gradInput.resize_as_(input);
  gradInput.zero_();

  const int kT = safe_downcast<int, int64_t>(kernel_size[0]);
  const int kH = kernel_size.size() == 1 ? kT : safe_downcast<int, int64_t>(kernel_size[1]);
  const int kW = kernel_size.size() == 1 ? kT : safe_downcast<int, int64_t>(kernel_size[2]);

  const int dT = stride.empty() ? kT : safe_downcast<int, int64_t>(stride[0]);
  const int dH = stride.empty() ? kH : safe_downcast<int, int64_t>(stride[1]);
  const int dW = stride.empty() ? kW : safe_downcast<int, int64_t>(stride[2]);

  const int pT = safe_downcast<int, int64_t>(padding[0]);
  const int pH = padding.size() == 1 ? pT : safe_downcast<int, int64_t>(padding[1]);
  const int pW = padding.size() == 1 ? pT : safe_downcast<int, int64_t>(padding[2]);

  const int dilationT = safe_downcast<int, int64_t>(dilation[0]);
  const int dilationH = dilation.size() == 1 ? dilationT : safe_downcast<int, int64_t>(dilation[1]);
  const int dilationW = dilation.size() == 1 ? dilationT : safe_downcast<int, int64_t>(dilation[2]);

  const int64_t nbatch = input.ndimension() == 5 ? input.size(-5) : 1;
  const int64_t nslices = input.size(-4);

  const int64_t otime = gradOutput.size(-3);
  const int64_t oheight = gradOutput.size(-2);
  const int64_t owidth = gradOutput.size(-1);

  const int64_t itime = gradInput.size(-3);
  const int64_t iheight = gradInput.size(-2);
  const int64_t iwidth = gradInput.size(-1);

  max_pool3d_backward_shape_check(
    input,
    gradOutput,
    indices,
    nslices,
    kT, kH, kW,
    dT, dH, dW,
    pT, pH, pW,
    dilationT, dilationH, dilationW,
    itime, iheight, iwidth,
    otime, oheight, owidth);

  Tensor work_grad_input = gradInput;
  Tensor work_grad_output = gradOutput.contiguous();
  Tensor work_indices = indices.contiguous();

  if (input.ndimension() == 5) {
      // Collapse batch and feature dimensions.
      work_grad_input = work_grad_input.reshape({nbatch * nslices, itime, iheight, iwidth});
      work_grad_output = work_grad_output.reshape({nbatch * nslices, otime, oheight, owidth});
      work_indices = work_indices.reshape({nbatch * nslices, otime, oheight, owidth});
  }

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(input.scalar_type(),
    "max_pool3d_with_indices_backward_out_frame",
    [&] {
      const int64_t totalZ = otime * nslices * nbatch;
      scalar_t *grad_input_data = work_grad_input.data<scalar_t>();

      max_pool3d_with_indices_backward_out_frame(
        grad_input_data, work_grad_output, work_indices,
        totalZ,
        itime, iheight, iwidth,
        owidth, oheight,
        dT, dH, dW,
        pT, pH, pW,
        dilationT, dilationH, dilationW);
    }
  );
}

} // namespace

std::tuple<Tensor&, Tensor&> max_pool3d_with_indices_out_cuda(
  Tensor& output,
  Tensor& indices,
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  IntArrayRef dilation,
  bool ceil_mode)
{
  max_pool3d_with_indices_out_cuda_template(
    output,
    indices,
    input,
    kernel_size,
    stride,
    padding,
    dilation,
    ceil_mode);
  return std::tuple<Tensor&, Tensor&>(output, indices);
}

std::tuple<Tensor, Tensor> max_pool3d_with_indices_cuda(
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  IntArrayRef dilation,
  bool ceil_mode)
{
  Tensor output = at::empty({0}, input.options());
  Tensor indices = at::empty({0}, input.options().dtype(kLong));
  max_pool3d_with_indices_out_cuda_template(
    output,
    indices,
    input,
    kernel_size,
    stride,
    padding,
    dilation,
    ceil_mode);
  return std::tuple<Tensor, Tensor>(output, indices);
}

Tensor& max_pool3d_with_indices_backward_out_cuda(
  Tensor& gradInput,
  const Tensor& gradOutput,
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  IntArrayRef dilation,
  bool ceil_mode,
  const Tensor& indices)
{
  max_pool3d_with_indices_backward_out_cuda_template(
    gradInput,
    gradOutput,
    input,
    indices,
    kernel_size,
    stride,
    padding,
    dilation,
    ceil_mode);
  return gradInput;
}

Tensor max_pool3d_with_indices_backward_cuda(
  const Tensor& gradOutput,
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  IntArrayRef dilation,
  bool ceil_mode,
  const Tensor& indices)
{
  auto gradInput = at::zeros_like(input);
  max_pool3d_with_indices_backward_out_cuda_template(
    gradInput,
    gradOutput,
    input,
    indices,
    kernel_size,
    stride,
    padding,
    dilation,
    ceil_mode);
  return gradInput;
}

} // at::native
} // at
