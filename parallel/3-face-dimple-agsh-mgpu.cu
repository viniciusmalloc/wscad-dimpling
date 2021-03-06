#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>
#include <omp.h>

#define C 4
#define THREADS 1024 // 2^10
#define MAX 100
#define MAXS MAX* MAX
#define COMB_MAX (MAX * (MAX - 1) * (MAX - 2) * (MAX - 3)) / 24

#define gpuErrChk(ans)                        \
    {                                         \
        gpuAssert((ans), __FILE__, __LINE__); \
    }
inline void gpuAssert(cudaError_t code, char* file, int line, bool abort = true)
{
    if (code != cudaSuccess) {
        fprintf(stderr, "GPUassert: %s %s %d\n", cudaGetErrorString(code),
            file, line);
        if (abort)
            getchar();
    }
}

using namespace std;

/*
    sz          ---> Adjacency matrix dimension (1D)
    comb        ---> Number of combinations of an instance
    graph       ---> Adjacency matrix itself
    seeds       ---> Set of seeds
    resFaces    ---> Set of triangular faces for the output
*/
struct Node {
    int sz, comb;
    int graph[MAXS], seeds[C * COMB_MAX], resFaces[6 * MAX];
};

/*
    numFaces    ---> Number of triangular faces
    remaining   ---> Number of remaining vertices
    tmpMax      ---> Max value obtained for a seed
    F           ---> Set of triangular faces
    V           ---> Set of remaining vertices
*/
struct Params {
    int *numFaces, *remaining, *tmpMax;
    int *F, *V;
};

/*
    SIZE        ---> Number of vertices
    COMB        ---> Number of combinations
    R           ---> Output graph for a possible solution
    F           ---> Set of triangular faces of an instance
    qtd         ---> Number of possible 4-cliques
*/
int SIZE, COMB, GPU_CNT = 1;
int R[MAXS], F[8 * MAX], numComb[MAX];
int qtd = 0;

Node* N;

//-----------------------------------------------------------------------------
// Mac OSX
#ifdef __MACH__
#include <mach/clock.h>
#include <mach/mach.h>
#endif

/*
    Prints elapsed time.
    */
void printElapsedTime(double start, double stop)
{
    double elapsed = stop - start;
    printf("Elapsed time: %.3lfs.\n", elapsed);
}
//-----------------------------------------------------------------------------
/*  
    Gets clock time.
    */
void current_utc_time(struct timespec* ts)
{
#ifdef __MACH__ // OS X does not have clock_gettime, use clock_get_time
    clock_serv_t cclock;
    mach_timespec_t mts;
    host_get_clock_service(mach_host_self(), CALENDAR_CLOCK, &cclock);
    clock_get_time(cclock, &mts);
    mach_port_deallocate(mach_task_self(), cclock);
    ts->tv_sec = mts.tv_sec;
    ts->tv_nsec = mts.tv_nsec;
#else
    clock_gettime(CLOCK_REALTIME, ts);
#endif
}
//-----------------------------------------------------------------------------
double getTime()
{
    timespec ts;
    current_utc_time(&ts);
    return double(ts.tv_sec) + double(ts.tv_nsec) / 1e9;
}
//-----------------------------------------------------------------------------
/*
    t   ---> thread index
    Generates a list of vertices which are not on the initial planar graph.
    */
__device__ void generateVertexList(Node* devN, Params* devP, int t, int offset)
{
    int sz = devN->sz, comb = devN->comb;

    int va = devN->seeds[(t + offset) * 4],
        vb = devN->seeds[(t + offset) * 4 + 1],
        vc = devN->seeds[(t + offset) * 4 + 2],
        vd = devN->seeds[(t + offset) * 4 + 3];
    for (int i = 0; i < sz; ++i) {
        if (i == va || i == vb || i == vc || i == vd)
            devP->V[t + i * comb] = -1;
        else
            devP->V[t + i * comb] = i;
    }
}
//-----------------------------------------------------------------------------
/*
    Returns the weight of the planar graph so far.
*/
__device__ void generateFaceList(Node* devN, Params* devP, int graph[], int t,
    int offset)
{
    int sz = devN->sz, comb = devN->comb;

    int va = devN->seeds[(t + offset) * 4],
        vb = devN->seeds[(t + offset) * 4 + 1],
        vc = devN->seeds[(t + offset) * 4 + 2],
        vd = devN->seeds[(t + offset) * 4 + 3];

    // Generate the first triangle of the output graph
    devP->F[t + (devP->numFaces[t] * 3) * comb] = va;
    devP->F[t + (devP->numFaces[t] * 3 + 1) * comb] = vb;
    devP->F[t + ((devP->numFaces[t]++) * 3 + 2) * comb] = vc;

    // Generate the next 3 possible faces
    devP->F[t + (devP->numFaces[t] * 3) * comb] = va;
    devP->F[t + (devP->numFaces[t] * 3 + 1) * comb] = vb;
    devP->F[t + ((devP->numFaces[t]++) * 3 + 2) * comb] = vd;

    devP->F[t + (devP->numFaces[t] * 3) * comb] = va;
    devP->F[t + (devP->numFaces[t] * 3 + 1) * comb] = vc;
    devP->F[t + ((devP->numFaces[t]++) * 3 + 2) * comb] = vd;

    devP->F[t + (devP->numFaces[t] * 3) * comb] = vb;
    devP->F[t + (devP->numFaces[t] * 3 + 1) * comb] = vc;
    devP->F[t + ((devP->numFaces[t]++) * 3 + 2) * comb] = vd;

    int res = graph[va * sz + vb] + graph[va * sz + vc] + graph[vb * sz + vc];
    res += graph[va * sz + vd] + graph[vb * sz + vd] + graph[vc * sz + vd];
    devP->tmpMax[t] = res;
}
//-----------------------------------------------------------------------------
/*
    Inserts a new vertex, 3 new triangular faces
    and removes the face from the list.
    */
__device__ int faceDimple(Node* devN, Params* devP, int graph[], int new_vertex,
    int f, int t)
{
    int sz = devN->sz, comb = devN->comb;

    // Remove the chosen face and insert a new one
    int va = devP->F[t + (f * 3) * comb],
        vb = devP->F[t + (f * 3 + 1) * comb],
        vc = devP->F[t + (f * 3 + 2) * comb];

    devP->F[t + (f * 3) * comb] = new_vertex,
                          devP->F[t + (f * 3 + 1) * comb] = va,
                          devP->F[t + (f * 3 + 2) * comb] = vb;

    // Insert the other two possible faces
    devP->F[t + (devP->numFaces[t] * 3) * comb] = new_vertex;
    devP->F[t + (devP->numFaces[t] * 3 + 1) * comb] = va;
    devP->F[t + ((devP->numFaces[t]++) * 3 + 2) * comb] = vc;

    devP->F[t + (devP->numFaces[t] * 3) * comb] = new_vertex;
    devP->F[t + (devP->numFaces[t] * 3 + 1) * comb] = vb;
    devP->F[t + ((devP->numFaces[t]++) * 3 + 2) * comb] = vc;

    int resp = graph[va + sz * new_vertex] + graph[vb + sz * new_vertex]
        + graph[vc + sz * new_vertex];

    return resp;
}
//-----------------------------------------------------------------------------
/*
    Returns the vertex having the maximum gain
    inserting within a face.
    */
__device__ int maxGainFace(Node* devN, Params* devP, int graph[], int* f, int t)
{
    int sz = devN->sz, comb = devN->comb;
    int gain = -1, vertex = -1;

    int numFaces = devP->numFaces[t];
    // Iterate through the remaining vertices
    for (int new_vertex = 0; new_vertex < sz; ++new_vertex) {
        if (devP->V[t + new_vertex * comb] == -1)
            continue;
        // Test the dimple on each face
        for (int i = 0; i < numFaces; ++i) {
            int va = devP->F[t + (i * 3) * comb],
                vb = devP->F[t + (i * 3 + 1) * comb],
                vc = devP->F[t + (i * 3 + 2) * comb];
            int tmpGain = graph[va + sz * new_vertex] + graph[vb + sz * new_vertex]
                + graph[vc + sz * new_vertex];
            if (tmpGain > gain) {
                gain = tmpGain;
                *f = i;
                vertex = new_vertex;
            }
        }
    }
    return vertex;
}
//-----------------------------------------------------------------------------
__device__ void dimpling(Node* devN, Params* devP, int graph[], int t)
{
    int comb = devN->comb;
    while (devP->remaining[t]) {
        int f = -1;
        int vertex = maxGainFace(devN, devP, graph, &f, t);
        devP->V[t + vertex * comb] = -1;
        devP->tmpMax[t] += faceDimple(devN, devP, graph, vertex, f, t);
        devP->remaining[t]--;
    }
}
//-----------------------------------------------------------------------------
__device__ void copyGraph(Node* devN, Params* devP, int t)
{
    int numFaces = devP->numFaces[t], comb = devN->comb;
    for (int i = 0; i < numFaces; ++i) {
        int va = devP->F[t + (i * 3) * comb],
            vb = devP->F[t + (i * 3 + 1) * comb],
            vc = devP->F[t + (i * 3 + 2) * comb];
        devN->resFaces[i * 3] = va,
                           devN->resFaces[i * 3 + 1] = vb,
                           devN->resFaces[i * 3 + 2] = vc;
    }
}
//-----------------------------------------------------------------------------
__device__ void initializeDevice(Params* devP, int sz, int t)
{
    devP->numFaces[t] = 0;
    devP->tmpMax[t] = -1;
    devP->remaining[t] = sz - 4;
}
//-----------------------------------------------------------------------------
__global__ void solve(Node* devN, Params devP, int* respMax, int offset)
{
    int x = blockDim.x * blockIdx.x + threadIdx.x;
    int sz = devN->sz, comb = devN->comb;
    extern __shared__ int graph[];

    for (int i = threadIdx.x; i < sz * sz; i += blockDim.x)
        graph[i] = devN->graph[i];
    __syncthreads();

    if (x < comb) {
        initializeDevice(&devP, sz, x);
        generateVertexList(devN, &devP, x, offset);
        generateFaceList(devN, &devP, graph, x, offset);
        dimpling(devN, &devP, graph, x);
        atomicMax(respMax, devP.tmpMax[x]);
        __syncthreads();

        if (devP.tmpMax[x] == *respMax)
            copyGraph(devN, &devP, x);
        __syncthreads();
    }
}
//-----------------------------------------------------------------------------
int prepareEnvironment()
{
    int finalResp = -1, pos = -1;

#pragma omp parallel for num_threads(GPU_CNT)
    for (int gpu_id = 0; gpu_id < GPU_CNT; gpu_id++) {
        cudaSetDevice(gpu_id);
        int range = (int)ceil(COMB / (double)GPU_CNT);
        int comb = ((gpu_id + 1) * range > COMB ? COMB - gpu_id * range : range);
        int offset = gpu_id * range;
        N->comb = comb;

        int resp = -1, *tmpResp;
        gpuErrChk(cudaMalloc((void**)&tmpResp, sizeof(int)));
        gpuErrChk(cudaMemcpy(tmpResp, &resp, sizeof(int), cudaMemcpyHostToDevice));

        Node* devN;
        Params devP;

        size_t sz = 3 * range * sizeof(int) + SIZE * range * sizeof(int)
            + (6 * SIZE) * range * sizeof(int);

        printf("Using %d MBytes in Kernel %d\n", (sz + sizeof(Node)) / (1 << 20), gpu_id);

        gpuErrChk(cudaMalloc((void**)&devN, sizeof(Node)));
        gpuErrChk(cudaMemcpy(devN, N, sizeof(Node), cudaMemcpyHostToDevice));

        gpuErrChk(cudaMalloc((void**)&devP.numFaces, comb * sizeof(int)));
        gpuErrChk(cudaMalloc((void**)&devP.remaining, comb * sizeof(int)));
        gpuErrChk(cudaMalloc((void**)&devP.tmpMax, comb * sizeof(int)));
        gpuErrChk(cudaMalloc((void**)&devP.F, 6 * SIZE * comb * sizeof(int)));
        gpuErrChk(cudaMalloc((void**)&devP.V, SIZE * comb * sizeof(int)));

        dim3 blocks(comb / THREADS + 1, 1);
        dim3 threads(THREADS, 1);

        printf("Kernel %d launched with %d blocks, each w/ %d threads\n",
            gpu_id + 1, range / THREADS + 1, THREADS);
        solve<<<blocks, threads, SIZE * SIZE * sizeof(int)>>>(devN, devP, tmpResp, offset);
        gpuErrChk(cudaDeviceSynchronize());

        // Copy back the maximum weight and the set of faces
        // which gave this result
        gpuErrChk(cudaMemcpy(&resp, tmpResp, sizeof(int), cudaMemcpyDeviceToHost));
        printf("Kernel finished.\nLocal maximum found in Kernel %d: %d\n",
            gpu_id + 1, resp);
        printf("Copying results...\n");

#pragma omp critical
        {
            if (resp > finalResp) {
                finalResp = resp;
                pos = gpu_id;
            }
        }

        if (pos == gpu_id)
            gpuErrChk(cudaMemcpy(&F, devN->resFaces, 6 * MAX * sizeof(int),
                cudaMemcpyDeviceToHost));

        printf("Freeing memory...\n");
        gpuErrChk(cudaFree(devN));
        gpuErrChk(cudaFree(devP.numFaces));
        gpuErrChk(cudaFree(devP.remaining));
        gpuErrChk(cudaFree(devP.tmpMax));
        gpuErrChk(cudaFree(devP.F));
        gpuErrChk(cudaFree(devP.V));
        gpuErrChk(cudaDeviceReset());
    }

    return finalResp;
}
//-----------------------------------------------------------------------------
/*
    C      ---> Size of the combination
    index  ---> Current index in data[]
    data[] ---> Temporary array to store a current combination
    i      ---> Index of current element in vertices[]
*/
void combineUntil(int index, int* data, int i)
{
    if (index == C) {
        for (int j = 0; j < C; ++j)
            N->seeds[qtd * C + j] = data[j];
        qtd++;
        return;
    }

    if (i >= SIZE)
        return;

    data[index] = i;
    combineUntil(index + 1, data, i + 1);
    combineUntil(index, data, i + 1);
}
//-----------------------------------------------------------------------------
void combine()
{
    int data[C];
    combineUntil(0, data, 0);
}
//-----------------------------------------------------------------------------
/*
    Defines the number of combinations.
    */
void sizeDefinitions()
{
    for (int i = 4; i <= MAX; ++i) {
        int resp = 1;
        for (int j = i - 3; j <= i; ++j)
            resp *= j;
        resp /= 24;
        numComb[i - 1] = resp;
    }
}
//-----------------------------------------------------------------------------
void initialize()
{
    for (int i = 0; i < SIZE; ++i) {
        for (int j = i + 1; j < SIZE; ++j)
            R[i * SIZE + j] = R[j * SIZE + i] = -1;
        R[i * SIZE + i] = -1;
    }
}
//-----------------------------------------------------------------------------
void readInput()
{
    int x;
    scanf("%d", &SIZE);
    COMB = numComb[SIZE - 1];

    N = (Node*)malloc(sizeof(Node));
    N->sz = SIZE;

    for (int i = 0; i < SIZE; ++i) {
        for (int j = i + 1; j < SIZE; ++j) {
            scanf("%d", &x);
            N->graph[i * SIZE + j] = x;
            N->graph[j * SIZE + i] = x;
        }
        N->graph[i * SIZE + i] = -1;
    }
}
//-----------------------------------------------------------------------------
int main(int argv, char** argc)
{
    sizeDefinitions();
    // Reads the input, which is given by the size of a graph and its weighted
    // edges. The given graph should be a complete graph.
    readInput();
    initialize();
    // Generate 4-clique seeds, given the number of vertices
    combine();

    if (argv == 2)
        cudaSetDevice(atoi(argc[1]));
    else if (argv == 3) {
        GPU_CNT = atoi(argc[2]);
        int d;
        cudaGetDeviceCount(&d);
        if (GPU_CNT > d)
            GPU_CNT = d;
    }

    double start = getTime();
    int respMax = prepareEnvironment();
    double stop = getTime();

    //reconstruct the graph given the regions of the graph
    for (int i = 0; i < 2 * SIZE; ++i) {
        int va = F[i * 3], vb = F[i * 3 + 1], vc = F[i * 3 + 2];
        if (va == vb && vb == vc)
            continue;
        R[va * SIZE + vb] = R[vb * SIZE + va] = N->graph[va * SIZE + vb];
        R[va * SIZE + vc] = R[vc * SIZE + va] = N->graph[va * SIZE + vc];
        R[vb * SIZE + vc] = R[vc * SIZE + vb] = N->graph[vb * SIZE + vc];
    }

    printf("Printing generated graph:\n");
    for (int i = 0; i < SIZE; ++i) {
        for (int j = i + 1; j < SIZE; ++j)
            printf("%d ", R[i * SIZE + j]);
        printf("\n");
    }

    printElapsedTime(start, stop);
    printf("Maximum weight found: %d\n", respMax);
    free(N);

    return 0;
}
