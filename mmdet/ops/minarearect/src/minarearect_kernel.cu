// Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.
#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>

#include <THC/THC.h>
#include <THC/THCDeviceUtils.cuh>

#include <vector>
//#include <iostream>
#include <algorithm>
#include <math.h>
#include <stdio.h>
//using namespace std;
#define maxn 100

const float eps=1E-8;

int const threadsPerBlock = 256; //sizeof(unsigned long long) * 8;

__device__ inline int sig(float d){
    return int(d>eps)-int(d<-eps);
}

struct Point{
    float x,y;
    __device__ Point(){}
    __device__ Point(float x,float y):x(x),y(y){}
};

__device__ inline bool point_same(Point& a, Point& b){
    return sig(a.x - b.x) == 0 && sig(a.y - b.y) == 0;
}

__device__ inline void swap1(Point* a, Point* b){
    Point temp;
    temp.x = a->x;
    temp.y = a->y;

    a->x = b->x;
    a->y = b->y;

    b->x = temp.x;
    b->y = temp.y;
}
__device__ inline float cross(Point o,Point a,Point b){
    return(a.x-o.x)*(b.y-o.y)-(b.x-o.x)*(a.y-o.y);
}

__device__ inline float dis(Point a,Point b){
	return (a.x-b.x)*(a.x-b.x)+(a.y-b.y)*(a.y-b.y);
}
__device__ inline void minBoundingRect(Point *ps, int n_points, float *minbox)
{
    float convex_points[2][maxn];
    for(int j = 0; j < n_points; j++)
    {
        convex_points[0][j] = ps[j].x;
    }
    for(int j = 0; j < n_points; j++)
    {
        convex_points[1][j] = ps[j].y;
    }

    Point edges[maxn];
    float edges_angles[maxn];
    float unique_angles[maxn];
    float pi = 3.1415926;
    int n_edges = n_points - 1;
    int n_unique = 0;
    int unique_flag = 0;

    for(int i = 0; i < n_edges; i++)
    {
        edges[i].x = ps[i + 1].x - ps[i].x;
        edges[i].y = ps[i + 1].y - ps[i].y;
    }
    for(int i = 0; i < n_edges; i++)
    {
        edges_angles[i] = atan2((double)edges[i].y, (double)edges[i].x);
        if(edges_angles[i] >= 0)
        {
            edges_angles[i] = fmod((double)edges_angles[i], (double)pi / 2);
        }
        else
        {
            edges_angles[i] = edges_angles[i] - (int)(edges_angles[i] / (pi / 2) - 1) * (pi / 2);
        }
    }
    unique_angles[0] = edges_angles[0];
    n_unique += 1;
    for(int i = 1; i < n_edges; i++)
    {
        for(int j = 0; j < n_unique; j++)
        {
            if(edges_angles[i] == unique_angles[j])
            {
                unique_flag += 1;
            }
        }
        if(unique_flag == 0)
        {
            unique_angles[n_unique] = edges_angles[i];
            n_unique += 1;
            unique_flag = 0;
        }
        else
        {
            unique_flag = 0;
        }
    }

    float minarea = 1e12;
    for(int i = 0; i < n_unique; i++)
    {
        float R[2][2];
        float rot_points[2][maxn];
        R[0][0] = cos(unique_angles[i]);
        R[0][1] = cos(unique_angles[i] - pi / 2);
        R[1][0] = cos(unique_angles[i] + pi / 2);
        R[1][1] = cos(unique_angles[i]);
        //R x Points
        for (int m = 0; m < 2; m++)
        {
            for (int n = 0; n < n_points; n++)
            {
                    float sum = 0.0;
                    for (int k = 0; k < 2; k++)
                    {
                        sum = sum + R[m][k] * convex_points[k][n];
                    }
                    rot_points[m][n] = sum;
            }
        }

        //xmin;
        float xmin, ymin,xmax, ymax;
        xmin = 1e12;
        for(int j = 0; j < n_points; j++)
        {
            if(isinf(rot_points[0][j]) || isnan(rot_points[0][j]))
            {
                continue;
            }
            else
            {
                if(rot_points[0][j] < xmin)
                {
                    xmin = rot_points[0][j];
                }
            }
        }
        //ymin
        ymin = 1e12;
        for(int j = 0; j < n_points; j++)
        {
            if(isinf(rot_points[1][j]) || isnan(rot_points[1][j]))
            {
                continue;
            }
            else
            {
                if(rot_points[1][j] < ymin)
                {
                    ymin = rot_points[1][j];
                }
            }
        }
        //xmax
        xmax = -1e12;
        for(int j = 0; j < n_points; j++)
        {
            if(isinf(rot_points[0][j]) || isnan(rot_points[0][j]))
            {
                continue;
            }
            else
            {
                if(rot_points[0][j] > xmax)
                {
                    xmax = rot_points[0][j];
                }
            }
        }
        //ymax
        ymax = -1e12;
        for(int j = 0; j < n_points; j++)
        {
            if(isinf(rot_points[1][j]) || isnan(rot_points[1][j]))
            {
                continue;
            }
            else
            {
                if(rot_points[1][j] > ymax)
                {
                    ymax = rot_points[1][j];
                }
            }
        }
        float area = (xmax - xmin) * (ymax - ymin);
        if(area < minarea)
        {
            minarea = area;
            minbox[0] = unique_angles[i];
            minbox[1] = xmin;
            minbox[2] = ymin;
            minbox[3] = xmax;
            minbox[4] = ymax;
        }
    }
}


// convex_find and get the polygen_index_box_index
__device__ inline void Jarvis_and_index(Point *in_poly, int &n_poly, int *points_to_convex_ind)
{
    int n_input = n_poly;
    Point input_poly[100];
    for(int i = 0; i < n_input; i++)
    {
        input_poly[i].x = in_poly[i].x;
        input_poly[i].y = in_poly[i].y;
    }
    Point p_max, p_k;
    int max_index, k_index;
    int Stack[100], top1, top2;
    //float sign;
    double sign;
    Point right_point[50], left_point[50];

    for(int i = 0; i < n_poly; i++)
    {
		if(in_poly[i].y < in_poly[0].y || in_poly[i].y == in_poly[0].y && in_poly[i].x < in_poly[0].x)
		{
		    Point *j = &(in_poly[0]);
		    Point *k = &(in_poly[i]);
		    swap1(j, k);
		}
		if(i == 0)
		{
			p_max = in_poly[0];
			max_index = 0;
		}
		if(in_poly[i].y > p_max.y || in_poly[i].y == p_max.y && in_poly[i].x > p_max.x)
		{
			p_max = in_poly[i];
			max_index = i;
		}
    }
    if(max_index == 0){
        max_index = 1;
        p_max = in_poly[max_index];
    }

    k_index = 0, Stack[0] = 0, top1 = 0;
    while(k_index != max_index)
    {

        p_k = p_max;
        k_index = max_index;
        for(int i = 1; i < n_poly; i++)
        {
                

                

            sign = (
                        ((double)in_poly[i].x - (double)in_poly[Stack[top1]].x) * ((double)p_k.y - (double)in_poly[Stack[top1]].y) -
                        ((double)p_k.x - (double)in_poly[Stack[top1]].x) * ((double)in_poly[i].y - (double)in_poly[Stack[top1]].y)
                    );
            if(
                (sign > 0) || ((sign == 0) && (dis(in_poly[Stack[top1]], in_poly[i]) > dis(in_poly[Stack[top1]], p_k)))
                )
            {
                p_k = in_poly[i];
                k_index = i;
            }
        }
        top1++;
        Stack[top1] = k_index;
    }

    for(int i = 0; i <= top1; i++)
    {
        right_point[i] = in_poly[Stack[i]];
    }

    k_index = 0, Stack[0] = 0, top2 = 0;

    while(k_index != max_index)
    {
        p_k = p_max;
        k_index = max_index;
        for(int i = 1; i < n_poly; i++)
        {

            sign = (
                        ((double)in_poly[i].x - (double)in_poly[Stack[top2]].x) * ((double)p_k.y - (double)in_poly[Stack[top2]].y) -
                        ((double)p_k.x - (double)in_poly[Stack[top2]].x) * ((double)in_poly[i].y - (double)in_poly[Stack[top2]].y)
                    );
                    
            if(
                (sign < 0) ||
                (sign == 0) && (dis(in_poly[Stack[top2]], in_poly[i]) > dis(in_poly[Stack[top2]], p_k)))
            {
                p_k = in_poly[i];
                k_index = i;
            }
        }
        top2++;
        Stack[top2] = k_index;
    }

    for(int i = top2 - 1; i >= 0; i--)
    {
        left_point[i] = in_poly[Stack[i]];
    }

    for(int i = 0; i < top1 + top2; i++){
        if(i <= top1)
        {
            in_poly[i] = right_point[i];
        }
        else
        {
            in_poly[i] = left_point[top2 -(i - top1)];
        }
    }
    n_poly = top1 + top2;
    for(int i = 0; i < n_poly; i++)
    {
        for(int j = 0; j < n_input; j++)
        {
            if(point_same(in_poly[i], input_poly[j]))
            {
                points_to_convex_ind[i] = j;
                break;
            }
        }
    }
}

__device__ inline void Findminbox(float const * const p, float * minpoints) {
    Point ps1[maxn];
    Point convex[maxn];
    float pi = 3.1415926;
    for(int i = 0; i < 40; i++)
    {
        convex[i].x = p[i * 2];
        convex[i].y = p[i * 2 + 1];
    }
    int n_convex = 40;
    int points_to_convex_ind[40] = {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1};
    Jarvis_and_index(convex, n_convex, points_to_convex_ind);
    int n1 = n_convex;
    for(int i = 0; i < n1; i++)
    {
        ps1[i].x = convex[i].x;
        ps1[i].y = convex[i].y;
    }
    ps1[n1].x = convex[0].x;
    ps1[n1].y = convex[0].y;
    
    float minbbox[5] = {0};
    minBoundingRect(ps1, n1 + 1, minbbox);
    float angle = minbbox[0];
    float xmin = minbbox[1];
    float ymin = minbbox[2];
    float xmax = minbbox[3];
    float ymax = minbbox[4];
    float R[2][2];

    R[0][0] = cos(angle);
    R[0][1] = cos(angle - pi / 2);
    R[1][0] = cos(angle + pi / 2);
    R[1][1] = cos(angle);

    float temp[1][2];
    float points[1][2];
    points[0][0] = xmax;
    points[0][1] = ymin;
    for (int m = 0; m < 1; m++)
    {
        for (int n = 0; n < 2; n++)
        {
                float sum = 0.0;
                for (int k = 0; k < 2; k++)
                {
                    sum = sum + points[m][k] * R[k][n];
                }
                temp[m][n] = sum;
        }
    }
    minpoints[0] = temp[0][0];
    minpoints[1] = temp[0][1];

    points[0][0] = xmin;
    points[0][1] = ymin;
    for (int m = 0; m < 1; m++)
    {
        for (int n = 0; n < 2; n++)
        {
                float sum = 0.0;
                for (int k = 0; k < 2; k++)
                {
                    sum = sum + points[m][k] * R[k][n];
                }
                temp[m][n] = sum;
        }
    }

    minpoints[2] = temp[0][0];
    minpoints[3] = temp[0][1];

    points[0][0] = xmin;
    points[0][1] = ymax;
    for (int m = 0; m < 1; m++)
    {
        for (int n = 0; n < 2; n++)
        {
                float sum = 0.0;
                for (int k = 0; k < 2; k++)
                {
                    sum = sum + points[m][k] * R[k][n];
                }
                temp[m][n] = sum;
        }
    }

    minpoints[4] = temp[0][0];
    minpoints[5] = temp[0][1];


    points[0][0] = xmax;
    points[0][1] = ymax;
    for (int m = 0; m < 1; m++)
    {
        for (int n = 0; n < 2; n++)
        {
                float sum = 0.0;
                for (int k = 0; k < 2; k++)
                {
                    sum = sum + points[m][k] * R[k][n];
                }
                temp[m][n] = sum;
        }
    }

    minpoints[6] = temp[0][0];
    minpoints[7] = temp[0][1];  

}


__global__ void minareabbox_kernel(const int ex_n_boxes, 
                                   const float *ex_boxes, 
                                   float* minbox){
  const int ex_start = blockIdx.x;
  const int ex_size = min(ex_n_boxes - ex_start * threadsPerBlock, threadsPerBlock);

  if (threadIdx.x < ex_size) {
    const int cur_box_idx = threadsPerBlock * ex_start + threadIdx.x;
    const float *cur_box = ex_boxes + cur_box_idx * 80;
    float *cur_min_box = minbox + cur_box_idx * 8;
    Findminbox(cur_box, cur_min_box);
  }
}

// should be N x 8 tensor
at::Tensor minareabbox_cuda(const at::Tensor ex_boxes) {
    using scalar_t = float;
    AT_ASSERTM(ex_boxes.type().is_cuda(), "ex_boxes must be a CUDA tensor");
    int ex_boxes_num = ex_boxes.size(0);
    
    const int ex_blocks = THCCeilDiv(ex_boxes_num, threadsPerBlock);
    scalar_t* ex_boxes_dev = ex_boxes.data<scalar_t>();
    
    const int size = ex_boxes_num * 8 * sizeof(float);
    THCState *state = at::globalContext().lazyInitCUDA(); // TODO replace with getTHCState
    
    float* minbox_dev = NULL;    
    minbox_dev = (float*) THCudaMalloc(state, ex_boxes_num * 8 * sizeof(float));

    dim3 blocks(ex_blocks);
    dim3 threads(threadsPerBlock);
    minareabbox_kernel<<<blocks, threads>>>(ex_boxes_num,
                                            ex_boxes_dev,
                                            minbox_dev);
    std::vector<float> minbox_host(ex_boxes_num * 8);
    THCudaCheck(cudaMemcpy(&minbox_host[0],
                          minbox_dev,
                          sizeof(float) * ex_boxes_num * 8,
                          cudaMemcpyDeviceToHost));
                          
    at::Tensor minbox = at::empty(ex_boxes_num * 8, ex_boxes.options().dtype(at::kFloat).device(at::kCPU));

    float* minbox_out = minbox.data<float>();
    for(int i = 0; i < ex_boxes_num * 8; i++)
    {
        minbox_out[i] = minbox_host[i];
    }
    THCudaFree(state, minbox_dev);
    // TODO improve this part
    return minbox.to(ex_boxes.device());
}
