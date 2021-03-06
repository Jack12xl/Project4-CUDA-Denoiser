#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#include <device_launch_parameters.h>
#include "cfg.h"

#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err) {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file) {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
    getchar();
#  endif
    exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
        int iter, glm::vec3* image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int) (pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int) (pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int) (pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

__host__ __device__ glm::vec2 signNotZero(glm::vec2 v) {
    return glm::vec2(
        v.x >= 0.0f ? 1.0f : -1.0f,
        v.y >= 0.0f ? 1.0f : -1.0f);
}

__host__ __device__ glm::vec3 oct_to_float32_3(glm::vec2 e) {  
    glm::vec3 v = glm::vec3(e.x, e.y, 1.0f - abs(e.x) - abs(e.y));
    if (v.z < 0.000001) {
        glm::vec2 v_xy = (glm::vec2(1.0f) - glm::abs(glm::vec2(v.y, v.x)));
        glm::vec2 sign_xy =  signNotZero(glm::vec2(v.x, v.y));
        v.x = v_xy.x * sign_xy.x;
        v.y = v_xy.y * sign_xy.y;
    }
    return glm::normalize(v);
}

__host__ __device__ glm::vec2 float32_3_to_oct(glm::vec3 v) {
    glm::vec2 p = glm::vec2(v.x, v.y) * (1.0f / (abs(v.x) + abs(v.y) + abs(v.z) + 0.001f));
    glm::vec2 out = (v.z <= 0.0f) ? (signNotZero(p) * (glm::vec2(1.0f) - glm::abs(glm::vec2(p.y, p.x)))) : p;
    return out;
}

__global__ void gbufferToPBO(uchar4* pbo, glm::ivec2 resolution, GBufferPixel* gBuffer, int show_idx) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        if (show_idx == 1) {
            float timeToIntersect = gBuffer[index].t * 255.0;

            pbo[index].w = 0;
            pbo[index].x = timeToIntersect;
            pbo[index].y = timeToIntersect;
            pbo[index].z = timeToIntersect;
        }
        else if (show_idx == 2) {
            // map from [-1, 1] to [0, 256]
#if oct_encode
            glm::vec3 fake_normal = (oct_to_float32_3(gBuffer[index].normal) + glm::vec3(1.0f)) * 0.5f * 255.0f;
#else
            glm::vec3 fake_normal = (gBuffer[index].normal + glm::vec3(1.0f)) * 0.5f * 255.0f;
#endif
            pbo[index].w = 0;
            pbo[index].x = fake_normal.x;
            pbo[index].y = fake_normal.y;
            pbo[index].z = fake_normal.z;
            /*pbo[index].x = 254.0f;
            pbo[index].y = 0.0f;
            pbo[index].z = 0.0f;*/
        }
        else if (show_idx == 3) {
#if buffer_depth
            float cur_depth = glm::clamp(gBuffer[index].depth, 0.1f, 30.0f);
            cur_depth *= 8.5f;
            pbo[index].w = 0;
            pbo[index].x = cur_depth;
            pbo[index].y = cur_depth;
            pbo[index].z = cur_depth;

#else
            glm::vec3 world_p = glm::clamp(gBuffer[index].world_p, glm::vec3(0.0f), glm::vec3(30.0f));
            // 255 / 30 = 8.5f
            world_p *= 8.5f;
            pbo[index].w = 0;
            pbo[index].x = world_p.x;
            pbo[index].y = world_p.y;
            pbo[index].z = world_p.z;
#endif
            
        }
        else if (show_idx == 4) {
            glm::vec3 originColor = 255.0f * gBuffer[index].originColor;
            pbo[index].x = originColor.x;
            pbo[index].y = originColor.y;
            pbo[index].z = originColor.z;
        }
        
    }
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
static GBufferPixel* dev_gBuffer = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...
static glm::vec3* dev_denoised_image = NULL;
static glm::vec3* dev_image_buf = NULL;
static glm::vec3* dev_image_sum = NULL;

const float w_0 = 3.0f / 8.0f;
const float w_1 = 1.0f / 2.0f / 8.0f;
const float w_2 = 1.0f / 8.0f / 16.0f;

static float normal_var = 1.0f;
static float position_var = 1.0f;
static float origin_color_var = 1.0f;
static float depth_var = 1.0f;

#if matrix_free
static float host_filter_w[] = { w_0, w_1, w_2};
#else
static float host_filter_w[] = 
{ 
    w_2, w_2, w_2, w_2, w_2,
    w_2, w_1, w_1, w_1, w_2,
    w_2, w_1, w_0, w_1, w_2,
    w_2, w_1, w_1, w_1, w_2.
    w_2, w_2, w_2, w_2, w_2
 };
#endif
static float* dev_filter_w = NULL;



void pathtraceInit(Scene *scene) {
    hst_scene = scene;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

  	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

  	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
  	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
  	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
  	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

    cudaMalloc(&dev_gBuffer, pixelcount * sizeof(GBufferPixel));

    // TODO: initialize any extra device memeory you need
    cudaMalloc(&dev_denoised_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_denoised_image, 0, pixelcount * sizeof(glm::vec3));

    cudaMalloc(&dev_image_buf, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image_buf, 0, pixelcount * sizeof(glm::vec3));

    cudaMalloc(&dev_image_sum, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image_sum, 0, pixelcount * sizeof(glm::vec3));
    
#if matrix_free
    cudaMalloc(&dev_filter_w, 3 * sizeof(float));
    cudaMemcpy(dev_filter_w, host_filter_w, 3 * sizeof(float), cudaMemcpyHostToDevice);
#else
    cudaMalloc(&dev_filter_w, 25 * sizeof(float));
    cudaMemcpy(dev_filter_w, host_filter_w, 25 * sizeof(float), cudaMemcpyHostToDevice);
#endif
    
    checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
    cudaFree(dev_image);  // no-op if dev_image is null
  	cudaFree(dev_paths);
  	cudaFree(dev_geoms);
  	cudaFree(dev_materials);
  	cudaFree(dev_intersections);
    cudaFree(dev_gBuffer);
    // TODO: clean up any extra device memory you created
    cudaFree(dev_denoised_image);
    cudaFree(dev_image_buf);
    cudaFree(dev_image_sum);
    cudaFree(dev_filter_w);
    checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment & segment = pathSegments[index];

		segment.ray.origin = cam.position;
        segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
			);

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment * pathSegments
	, Geom * geoms
	, int geoms_size
	, ShadeableIntersection * intersections
	)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom & geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
		}
	}
}

__global__ void shadeSimpleMaterials (
  int iter
  , int num_paths
	, ShadeableIntersection * shadeableIntersections
	, PathSegment * pathSegments
	, Material * materials
	)
{
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < num_paths)
  {
    ShadeableIntersection intersection = shadeableIntersections[idx];
    PathSegment segment = pathSegments[idx];
    if (segment.remainingBounces == 0) {
      return;
    }

    if (intersection.t > 0.0f) { // if the intersection exists...
      segment.remainingBounces--;
      // Set up the RNG
      thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, segment.remainingBounces);

      Material material = materials[intersection.materialId];
      glm::vec3 materialColor = material.color;

      // If the material indicates that the object was a light, "light" the ray
      if (material.emittance > 0.0f) {
        segment.color *= (materialColor * material.emittance);
        segment.remainingBounces = 0;
      }
      else {
        segment.color *= materialColor;
        glm::vec3 intersectPos = intersection.t * segment.ray.direction + segment.ray.origin;
        scatterRay(segment, intersectPos, intersection.surfaceNormal, material, rng);
      }
    // If there was no intersection, color the ray black.
    // Lots of renderers use 4 channel color, RGBA, where A = alpha, often
    // used for opacity, in which case they can indicate "no opacity".
    // This can be useful for post-processing and image compositing.
    } else {
      segment.color = glm::vec3(0.0f);
      segment.remainingBounces = 0;
    }

    pathSegments[idx] = segment;
  }
}

__global__ void generateGBuffer (
  int num_paths,
  ShadeableIntersection* shadeableIntersections,
	PathSegment* pathSegments,
  GBufferPixel* gBuffer,
    float z_eye) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < num_paths)
  {
    gBuffer[idx].t = shadeableIntersections[idx].t;
#if oct_encode
    gBuffer[idx].normal = float32_3_to_oct(shadeableIntersections[idx].surfaceNormal);
#else
    gBuffer[idx].normal = shadeableIntersections[idx].surfaceNormal;
#endif
    
    // position
    glm::vec3 hit_pos = getPointOnRay(
        pathSegments[idx].ray,
        shadeableIntersections[idx].t
    );
#if buffer_depth
    gBuffer[idx].depth = abs(hit_pos.z - z_eye);
#else
    gBuffer[idx].world_p = hit_pos;
#endif
    
  }
}

__global__ void generateGBufferSub(
    int num_paths,
    ShadeableIntersection* shadeableIntersections,
    PathSegment* pathSegments,
    GBufferPixel* gBuffer) {
    /// <summary>
    /// store the first color
    /// </summary>
    /// <param name="num_paths"></param>
    /// <param name="shadeableIntersections"></param>
    /// <param name="pathSegments"></param>
    /// <param name="gBuffer"></param>
    /// <returns></returns>
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < num_paths)
    {
        // color
        gBuffer[idx].originColor = pathSegments[idx].color;
    }
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(int frame, int iter) {
    const int traceDepth = hst_scene->state.traceDepth;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

    ///////////////////////////////////////////////////////////////////////////

    // Pathtracing Recap:
    // * Initialize array of path rays (using rays that come out of the camera)
    //   * You can pass the Camera object to that kernel.
    //   * Each path ray must carry at minimum a (ray, color) pair,
    //   * where color starts as the multiplicative identity, white = (1, 1, 1).
    //   * This has already been done for you.
    // * NEW: For the first depth, generate geometry buffers (gbuffers)
    // * For each depth:
    //   * Compute an intersection in the scene for each path ray.
    //     A very naive version of this has been implemented for you, but feel
    //     free to add more primitives and/or a better algorithm.
    //     Currently, intersection distance is recorded as a parametric distance,
    //     t, or a "distance along the ray." t = -1.0 indicates no intersection.
    //     * Color is attenuated (multiplied) by reflections off of any object
    //   * Stream compact away all of the terminated paths.
    //     You may use either your implementation or `thrust::remove_if` or its
    //     cousins.
    //     * Note that you can't really use a 2D kernel launch any more - switch
    //       to 1D.
    //   * Shade the rays that intersected something or didn't bottom out.
    //     That is, color the ray by performing a color computation according
    //     to the shader, then generate a new ray to continue the ray path.
    //     We recommend just updating the ray's PathSegment in place.
    //     Note that this step may come before or after stream compaction,
    //     since some shaders you write may also cause a path to terminate.
    // * Finally:
    //     * if not denoising, add this iteration's results to the image
    //     * TODO: if denoising, run kernels that take both the raw pathtraced result and the gbuffer, and put the result in the "pbo" from opengl

	generateRayFromCamera <<<blocksPerGrid2d, blockSize2d >>>(cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

  // Empty gbuffer
  cudaMemset(dev_gBuffer, 0, pixelcount * sizeof(GBufferPixel));

	// clean shading chunks
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

  bool iterationComplete = false;
	while (!iterationComplete) {

	// tracing
	dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
	computeIntersections <<<numblocksPathSegmentTracing, blockSize1d>>> (
		depth
		, num_paths
		, dev_paths
		, dev_geoms
		, hst_scene->geoms.size()
		, dev_intersections
		);
	checkCUDAError("trace one bounce");
	cudaDeviceSynchronize();

    if (depth == 0) {
        generateGBuffer << <numblocksPathSegmentTracing, blockSize1d >> > (num_paths, dev_intersections, dev_paths, dev_gBuffer, cam.position.z);
    }

  shadeSimpleMaterials<<<numblocksPathSegmentTracing, blockSize1d>>> (
    iter,
    num_paths,
    dev_intersections,
    dev_paths,
    dev_materials
  );

  if (depth == 0) {
      generateGBufferSub << <numblocksPathSegmentTracing, blockSize1d >> > (num_paths, dev_intersections, dev_paths, dev_gBuffer);
  }

  getVariance(dev_gBuffer);
  depth++;
  

  iterationComplete = depth == traceDepth;
	}

  // Assemble this iteration and apply it to the image
  dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather<<<numBlocksPixels, blockSize1d>>>(num_paths, dev_image, dev_paths);

    ///////////////////////////////////////////////////////////////////////////

    // CHECKITOUT: use dev_image as reference if you want to implement saving denoised images.
    // Otherwise, screenshots are also acceptable.
    // Retrieve image from GPU
    cudaMemcpy(hst_scene->state.image.data(), dev_image,
            pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
    checkCUDAError("pathtrace");
}

// CHECKITOUT: this kernel "post-processes" the gbuffer/gbuffers into something that you can visualize for debugging.
void showGBuffer(uchar4* pbo, const int& show_idx) {
    const Camera &cam = hst_scene->state.camera;
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    // CHECKITOUT: process the gbuffer results and send them to OpenGL buffer for visualization
    gbufferToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, dev_gBuffer, show_idx);
}

void showImage(uchar4* pbo, int iter, bool if_deNoise) {
const Camera &cam = hst_scene->state.camera;
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    // Send results to OpenGL buffer for rendering
    if (if_deNoise) {
        sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_denoised_image);
    }
    else {
        sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);
    }
    
}

__host__ __device__
int getIndex(const int& x, const int& y, const int& res_x) {
    return x + y * res_x;
}

__global__ void SubStep_A_Trous(
    int iteration,
    bool final_step,
    glm::ivec2 resolution,
    float* filter_w,
    GBufferPixel* gBuffer,
    float normal_var,
    float position_var,
    float color_var,
    float depth_var,
    glm::vec3* image,
    glm::vec3* image_buf,
    glm::vec3* image_final
) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int step_size = 1 << iteration;
        int index = getIndex(x, y, resolution.x);
#if matrix_free
        //image_buf[index] = glm::vec3(0.0f);
        float normalization_factor_k = 0;
        for (int half_filter_size = 0; half_filter_size < 3; half_filter_size++) {
            // for each round, 3 round in total
            float cur_filter_w = filter_w[half_filter_size];
            // Convolve
            
#if edge_avoid

#if oct_encode
            glm::vec3 p_normal = oct_to_float32_3(gBuffer[index].normal);
#else
            glm::vec3 p_normal = gBuffer[index].normal;

#endif
            
#if buffer_depth
            float p_depth = gBuffer[index].depth;
#else
            glm::vec3 p_position = gBuffer[index].world_p;
#endif
            
            glm::vec3 p_color = gBuffer[index].originColor;
#endif
            for (int i = -half_filter_size; i <= half_filter_size; i++) {
                for (int j = -half_filter_size; j <= half_filter_size; j++) {
                    if (abs(i) >= half_filter_size || abs(j) >= half_filter_size) {
                        int cur_x = x + step_size * i;
                        int cur_y = y + step_size * j;
                        // boundary condition
                        cur_x = (cur_x < 0 || cur_x >= resolution.x) ? x - step_size * i : cur_x;
                        cur_y = (cur_y < 0 || cur_y >= resolution.y) ? y - step_size * j : cur_y;

                        int cur_index = getIndex(cur_x, cur_y, resolution.x);

                        
#if edge_avoid

#if oct_encode
                        glm::vec3 q_normal = oct_to_float32_3(gBuffer[cur_index].normal);
#else
                        glm::vec3 q_normal = gBuffer[cur_index].normal;
#endif
                        
#if buffer_depth
                        float q_depth =gBuffer[cur_index].depth;
#else
                        glm::vec3 q_position = gBuffer[cur_index].world_p;
#endif

                        
                        glm::vec3 q_color = gBuffer[cur_index].originColor;

                        float w_n = expf(-glm::length(q_normal - p_normal) / normal_var);
#if buffer_depth
                        float w_p = expf( - abs(q_depth - p_depth) / depth_var );
#else
                        float w_p = expf(-glm::length(q_position - p_position) / position_var);
#endif
                        
                        float w_c = expf(-glm::length(q_color - p_color) / color_var);
                        float w_pq = w_n * w_p * w_c;

                        normalization_factor_k += w_pq * cur_filter_w;
                        image_buf[index] += w_pq * cur_filter_w * image[cur_index];
#else
                        image_buf[index] += cur_filter_w * image[cur_index];
#endif
                        
                    }
                }
            }


        }
#if edge_avoid
        image_buf[index] /= normalization_factor_k;
#endif
        
       
#else
        // I haven't implemented matrix version
        int x_offset = -2, y_offset = -2;
        for (int pix = 0; pix < 25; pix++) {

        }
#endif // matrix_free
        __syncthreads();
        
        // Subtract and Reconstruct 
        if (!final_step) {
            image_final[index] += image_buf[index] - image[index];
        }
        else {
            image_final[index] += image_buf[index];
        }
        // 
    }
    

}

void deNoise(
    const int& iteration,
    const float& ui_normalWeight,
    const float& ui_positionWeight,
    const float& ui_colorWeight) {
    const Camera& cam = hst_scene->state.camera;
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
        (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
        (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    int pixelcount = cam.resolution.x * cam.resolution.y;
    cudaMemcpy(dev_denoised_image, dev_image,
        pixelcount * sizeof(glm::vec3), cudaMemcpyHostToHost);
    cudaMemset(dev_image_sum, 0, pixelcount * sizeof(glm::vec3));
    // A-Trous here
    for (int i = 0; i < iteration; i ++) {
        //const int& step_size = 1 << i;
        bool final_step = ( i == (iteration - 1) );
        SubStep_A_Trous << <blocksPerGrid2d, blockSize2d >>>(
            i,
            final_step,
            cam.resolution,
            dev_filter_w,

            dev_gBuffer,
            normal_var/ui_normalWeight,
            position_var/ ui_positionWeight,
            origin_color_var/ ui_colorWeight,
            depth_var/ ui_positionWeight,

            dev_denoised_image,
            dev_image_buf,
            dev_image_sum);
        std::swap(dev_denoised_image, dev_image_buf);
        cudaMemset(dev_image_buf, 0, pixelcount * sizeof(glm::vec3));
        if (final_step) {
            //std::swap(dev_denoised_image, dev_image_sum);
        } 
    }
}

void test_oct() {
    glm::vec3 a = glm::vec3(-1.0f, 0.0f, 0.0f);
    glm::vec2 oct_a = float32_3_to_oct(a);
    glm::vec3 out_a = oct_to_float32_3(oct_a);
    std::cout << "a" << a.x;
}

void getVariance(const GBufferPixel* dev_gBuffer) {
    const Camera& cam = hst_scene->state.camera;
    int pixelcount = cam.resolution.x * cam.resolution.y;

    GBufferPixel* host_gBuffer = new GBufferPixel[pixelcount];
    cudaMemcpy(host_gBuffer, dev_gBuffer, pixelcount * sizeof(GBufferPixel), cudaMemcpyDeviceToHost);

    glm::vec3 normal_mean,  color_mean;

#if buffer_depth
    float depth_mean = 0.0f;
#else
    glm::vec3 position_mean;
#endif
    
    for (int i = 0; i < pixelcount; i++) {
#if oct_encode
        normal_mean += oct_to_float32_3(host_gBuffer[i].normal);
#else
        normal_mean += host_gBuffer[i].normal;
#endif

#if buffer_depth
        depth_mean += host_gBuffer[i].depth;
#else
        position_mean += host_gBuffer[i].world_p;
#endif
        
        color_mean += host_gBuffer[i].originColor;
    }
    normal_mean /= (float)pixelcount;
#if buffer_depth
    depth_mean /= (float)pixelcount;
#else
    position_mean /= (float)pixelcount;
#endif
    
    color_mean /= (float)pixelcount;

    for (int i = 0; i < pixelcount; i++) {
#if oct_encode
        normal_var += glm::length(normal_mean - oct_to_float32_3(host_gBuffer[i].normal));
#else
        normal_var += glm::length(normal_mean - host_gBuffer[i].normal);
#endif
        
#if buffer_depth
        depth_var += abs(depth_mean - host_gBuffer[i].depth);
#else
        position_var += glm::length(position_mean - host_gBuffer[i].world_p);
#endif
        
        origin_color_var += glm::length(color_mean - host_gBuffer[i].originColor);
    }

    normal_var /= pixelcount - 1;
    position_var /= pixelcount - 1;
    origin_color_var /= pixelcount - 1;

    delete(host_gBuffer);
}